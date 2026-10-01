import Foundation
import Logging
import CoreMetrics
import Metrics
import Prometheus

// MARK: - Prometheus metrics (spec §12)

/// Bootstraps swift-metrics with a swift-prometheus collector so every
/// ``Counter``/``Timer``/``Meter`` created in the process is collected and
/// rendered by the shared ``MetricsCollector.registry``.
///
/// Must be called **once, before any metrics are emitted** (i.e. at serve
/// startup, before the first request) or the collector will not receive the
/// metric registrations. `MetricsSystem.bootstrap` traps on a second call, so
/// the caller must ensure it runs exactly once per process.
@discardableResult
public func bootstrapMetrics() -> PrometheusMetricsFactory {
    let factory = PrometheusMetricsFactory()
    MetricsSystem.bootstrap(factory)
    return factory
}

/// The shared collector registry that ``bootstrapMetrics`` wires the global
/// swift-metrics factory to. Read by ``MetricsCollector.render`` to produce the
/// Prometheus text exposition for `/metrics`.
public enum MetricsCollector {
    public static let registry = PrometheusMetricsFactory.defaultRegistry

    /// Render the current metrics as Prometheus text exposition.
    public static func render() -> String {
        registry.emitToString()
    }
}

/// Typed emitters for the spec §12 metric names. This is the single place the
/// rest of the codebase references metric names, so the names are pinned in one
/// file and the `/metrics` route + any test agree on them.
///
/// Metric objects are created lazily on first use (after ``bootstrapMetrics``),
/// so emitting a counter/timer registers it with the prometheus collector.
public enum OSMetrics {
    // MARK: Tool-level (emitted from ToolRegistry.dispatch)

    /// `osmcp_tool_calls_total{tool,outcome}` — one per tool call.
    public static func toolCall(tool: String, outcome: String) {
        Counter(label: "osmcp_tool_calls_total", dimensions: [("tool", tool), ("outcome", outcome)]).increment()
    }

    /// `osmcp_tool_duration_seconds{tool}` — histogram of tool-call latency.
    public static func toolDuration(tool: String, seconds: Double) {
        Timer(label: "osmcp_tool_duration_seconds", dimensions: [("tool", tool)]).recordSeconds(seconds)
    }

    // MARK: OpenStack request-level (emitted from Transport)

    /// `osmcp_openstack_requests_total{service,method,status}` — one per request.
    public static func openstackRequest(service: String, method: String, status: Int) {
        Counter(label: "osmcp_openstack_requests_total", dimensions: [
            ("service", service), ("method", method), ("status", String(status))
        ]).increment()
    }

    /// `osmcp_openstack_request_duration_seconds{service}` — histogram of latency.
    public static func openstackRequestDuration(service: String, seconds: Double) {
        Timer(label: "osmcp_openstack_request_duration_seconds", dimensions: [("service", service)]).recordSeconds(seconds)
    }

    // MARK: Sessions (emitted from the adapter's session callbacks)

    /// `osmcp_sessions_active` — gauge of live MCP sessions.
    public static func sessionStarted() {
        Meter(label: "osmcp_sessions_active").increment()
    }

    /// `osmcp_sessions_active` — gauge of live MCP sessions.
    public static func sessionEnded() {
        Meter(label: "osmcp_sessions_active").decrement()
    }

    // MARK: Auth (emitted from the FailedAuthLimiter)

    /// `osmcp_auth_failures_total{reason}` — one per failed validation.
    public static func authFailure(reason: String) {
        Counter(label: "osmcp_auth_failures_total", dimensions: [("reason", reason)]).increment()
    }

    // MARK: Cache (emitted from Cache.get)

    /// `osmcp_cache_hits_total{resource}` — one per cache hit.
    public static func cacheHit(resource: String) {
        Counter(label: "osmcp_cache_hits_total", dimensions: [("resource", resource)]).increment()
    }
}
