import Foundation
import OpenStackClient
import Logging

// MARK: - TaskRegistry (MCP Tasks shim, Path C)
//
// A non-conformant, server-scoped task store for long-running waits. It is an
// actor (reference type, Sendable) that lives for the whole server — created
// once alongside the `ToolCallLimiter` in `CloudWiring` and shared by every
// per-identity `ToolRegistry`. Because it is keyed by token id internally, one
// shared actor serves all identities while keeping each token's tasks private
// to it (project isolation by construction, matching the rest of the server).
//
// This is NOT the 2026-07-28 SEP-2663 MCP Tasks protocol — it is our own
// task-handle surface built on the existing `Waiter`. A task is a background
// poll of one resource; it is submitted (`submit`), polled (`status`), and
// cancelled (`cancel`) by the client via the `os_task_*` tools.
//
// Lifecycle of a `TaskEntry`:
//   submitted -> running -> (succeeded | failed | timed_out)
//                                    ^
//                 any non-terminal -> cancelled
// A task's background `Task<Void, Never>` does the actual polling by reusing
// `Waiter.wait`. We store it so `cancel` can stop it; when it finishes we write
// the terminal state + result. The entry itself is reaped after `reapAfter`
// once terminal, so the store can't grow unbounded from fire-and-forget use.

/// The observable state of a shim task.
public enum TaskState: String, Sendable, Codable {
    case submitted
    case running
    case succeeded
    case failed
    case timedOut
    case cancelled
}

public struct TaskEntry: Sendable {
    public let taskID: String
    public let tokenID: String
    public let resource: String
    public let resourceID: String
    public let region: String
    /// State observed by the submit (before the background poll started).
    public var state: TaskState
    /// Last non-empty status string seen by the background poll.
    public var lastStatus: String?
    /// Elapsed seconds at last update (rounded to 0.1s).
    public var elapsedSeconds: Double?
    /// Poll count at last update.
    public var polls: Int?
    /// Terminal result payload (the `Waiter.wait` outcome dict) once done.
    public var result: [String: JSONValue]?
    /// A one-line human message (e.g. the timeout error text) when failed.
    public var message: String?
    /// When the task became terminal (for reaping). nil = still running.
    public var terminalAt: Date?
}

public actor TaskRegistry {
    /// Keyed by token id -> task id -> entry. The background task handles are
    /// kept separately (they are not Sendable across the actor boundary in a
    /// stored-property-friendly way) by task id.
    private var tasks: [String: [String: TaskEntry]] = [:]
    private var handles: [String: Task<Void, Never>] = [:]   // keyed by taskID
    private var tokenOfTask: [String: String] = [:]          // taskID -> tokenID
    private let reapAfter: TimeInterval
    private let logger: Logger

    public init(reapAfter: TimeInterval = 600, logger: Logger = Logger(label: "substation-mcp-tasks")) {
        self.reapAfter = reapAfter
        self.logger = logger
    }

    /// Process-wide default store. The serve path overrides this with a
    /// server-scoped instance; tests and ad-hoc registries use the shared one.
    public static let shared = TaskRegistry()

    // MARK: submit

    /// Register a new task. The caller is responsible for spawning the
    /// background poll; this only allocates the id + entry.
    public func submit(tokenID: String, resource: String, resourceID: String, region: String) -> String {
        let id = "task-\(UUID().uuidString.lowercased())"
        var entry = TaskEntry(
            taskID: id,
            tokenID: tokenID,
            resource: resource,
            resourceID: resourceID,
            region: region,
            state: .submitted,
            lastStatus: nil,
            elapsedSeconds: nil,
            polls: nil,
            result: nil,
            message: nil,
            terminalAt: nil
        )
        entry.state = .running
        tasks[tokenID, default: [:]][id] = entry
        tokenOfTask[id] = tokenID
        return id
    }

    /// Attach the background poll handle for a submitted task.
    public func attachHandle(_ handle: Task<Void, Never>, for taskID: String) {
        handles[taskID] = handle
    }

    // MARK: status

    /// Look up a task for `tokenID`. Returns nil when the task is unknown or
    /// belongs to a different token (indistinguishable on purpose — no
    /// existence leak across identities).
    public func status(tokenID: String, taskID: String) -> TaskEntry? {
        // Reap any terminal entries that have exceeded their TTL before
        // answering, so the store stays bounded.
        reap()
        guard let entry = tasks[tokenID]?[taskID] else { return nil }
        return entry
    }

    // MARK: cancel

    /// Cancel a running task for `tokenID`. Returns the post-cancel state
    /// (.cancelled) or nil if the task is unknown/foreign or already terminal.
    @discardableResult
    public func cancel(tokenID: String, taskID: String) -> TaskState? {
        reap()
        guard let entry = tasks[tokenID]?[taskID], !isTerminal(entry.state) else { return nil }
        handles[taskID]?.cancel()
        handles[taskID] = nil
        var updated = entry
        updated.state = .cancelled
        updated.terminalAt = Date()
        updated.message = "Task cancelled by client."
        tasks[tokenID]?[taskID] = updated
        return .cancelled
    }

    /// Mark a task terminal with its result (called by the background poll
    /// when `Waiter.wait` returns or throws). No-op if already terminal
    /// (e.g. it was cancelled in the meantime).
    public func complete(
        tokenID: String,
        taskID: String,
        state: TaskState,
        lastStatus: String?,
        elapsedSeconds: Double?,
        polls: Int?,
        result: [String: JSONValue]?,
        message: String?
    ) {
        guard var entry = tasks[tokenID]?[taskID], !isTerminal(entry.state) else { return }
        entry.state = state
        entry.lastStatus = lastStatus ?? entry.lastStatus
        entry.elapsedSeconds = elapsedSeconds ?? entry.elapsedSeconds
        entry.polls = polls ?? entry.polls
        entry.result = result
        entry.message = message
        entry.terminalAt = Date()
        tasks[tokenID]?[taskID] = entry
        handles[taskID] = nil
        logger.debug("task \(taskID) (\(entry.resource) \(entry.resourceID)) -> \(state.rawValue)",
            metadata: ["token": .string(tokenID)])
    }

    // MARK: internals

    private func isTerminal(_ state: TaskState) -> Bool {
        switch state {
        case .succeeded, .failed, .timedOut, .cancelled: return true
        case .submitted, .running: return false
        }
    }

    /// Drop terminal entries older than `reapAfter` across all tokens.
    private func reap() {
        let now = Date()
        for (tokenID, var byID) in tasks {
            let expired = byID.filter { e in
                guard let t = e.value.terminalAt, isTerminal(e.value.state) else { return false }
                return now.timeIntervalSince(t) > reapAfter
            }
            guard !expired.isEmpty else { continue }
            for e in expired {
                byID[e.key] = nil
                handles[e.key] = nil
                tokenOfTask[e.key] = nil
            }
            tasks[tokenID] = byID
        }
    }
}
