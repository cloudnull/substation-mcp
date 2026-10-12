import Foundation
import Crypto

/// In-process generation of an OpenSSH public key, used when the caller omits `public_key` on
/// os_create(keypair) so the documented "omit to auto-generate" flow works on clouds (e.g.
/// Rackspace IAD3) whose Nova rejects name-only keypair creation with
/// "Invalid input ... 'public_key' is a required property".
///
/// We generate an Ed25519 key via swift-crypto's Curve25519.Signing and encode the 32-byte
/// public key into the OpenSSH wire blob:  string("ssh-ed25519") + string(32-byte pubkey).
/// That is the exact layout the OpenSSH client emits (verified against ssh-keygen output). The
/// private *seed* is returned once so the operator can persist it; we never send it to Nova.
enum SSHKeyGenerator {
    /// Generate a fresh Ed25519 key pair.
    /// - Returns: the OpenSSH public line to send to Nova, plus the private seed hex (surface once).
    static func generateEd25519() -> (publicLine: String, privateKeySeedHex: String)? {
        let priv = Curve25519.Signing.PrivateKey()
        let pubRaw = Data(priv.publicKey.rawRepresentation)
        guard pubRaw.count == 32 else { return nil }
        var blob: [UInt8] = []
        func putString(_ bytes: some Sequence<UInt8>) {
            let arr = Array(bytes)
            precondition(arr.count <= 0xFFFF, "OpenSSH string too long")
            let n = UInt32(arr.count)
            withUnsafeBytes(of: n.bigEndian) { blob.append(contentsOf: $0) }
            blob.append(contentsOf: arr)
        }
        putString("ssh-ed25519".utf8)
        putString(pubRaw)
        let b64 = Data(blob).base64EncodedString()
        let line = "ssh-ed25519 \(b64)"
        let seedHex = Data(priv.rawRepresentation).map { String(format: "%02x", $0) }.joined()
        return (line, seedHex)
    }
}
