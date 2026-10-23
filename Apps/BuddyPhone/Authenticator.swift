import Foundation
import LocalAuthentication

/// Proves a human is holding the unlocked phone. Every Allow asks again; nothing is cached.
protocol Authenticating: Sendable {
    /// True only when the user passed Face ID / Touch ID or entered the device passcode. A cancel, a failure
    /// and "no passcode set" are all false: the caller then sends nothing.
    func authenticate(reason: String) async -> Bool
}

/// Face ID or Touch ID, falling back to the device passcode (`.deviceOwnerAuthentication`).
struct LocalAuthenticator: Authenticating {
    func authenticate(reason: String) async -> Bool {
        // A fresh context per prompt: no reuse of an earlier successful evaluation.
        let context = LAContext()
        var availability: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availability) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
