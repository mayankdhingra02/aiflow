import Foundation

/// The shared secret that proves a local client is the companion Aiflow expects.
///
/// The bridge listens on loopback, but loopback is not an authorization boundary: any process
/// running as this user could otherwise connect, read the pending approval's request id out of
/// a snapshot, and answer it. The token closes that hole while keeping the transport local.
///
/// The value is never logged, never placed in an event, and never written anywhere but its own
/// user-only file.
enum BridgeToken {
    static let fileName = "bridge-token"

    static func defaultFileURL() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Aiflow/\(fileName)")
    }

    /// Loads the token, creating it on first use. Returns nil only if it cannot be persisted,
    /// in which case the bridge refuses to serve rather than accepting anyone.
    @discardableResult
    static func loadOrCreate(at url: URL = defaultFileURL()) -> String? {
        if let existing = load(at: url) { return existing }

        let token = generate()
        return write(token, to: url) ? token : nil
    }

    static func load(at url: URL = defaultFileURL()) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// 32 bytes of cryptographic randomness, hex encoded.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandom should not fail; fall back to the system RNG rather than a weak value.
            bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the token readable and writable by this user only (0600).
    @discardableResult
    static func write(_ token: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(token.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Length-independent, constant-time comparison, so a wrong token reveals nothing about
    /// the expected one through timing.
    static func matches(_ candidate: String, expected: String) -> Bool {
        let a = Array(candidate.utf8)
        let b = Array(expected.utf8)
        guard !b.isEmpty else { return false }

        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}
