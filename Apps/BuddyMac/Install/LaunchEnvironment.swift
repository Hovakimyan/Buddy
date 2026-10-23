import Foundation

/// What a run with `BUDDY_*` overrides (a safe manual run or a test setup) must not touch: the real login item and the
/// real setup-window memory. Without overrides the real ones are used.
enum LaunchEnvironment {
    static func isOverridden(_ environment: [String: String]) -> Bool {
        environment.keys.contains { $0.hasPrefix("BUDDY_") }
    }

    @MainActor
    static func loginItem(environment: [String: String]) -> any LoginItemService {
        isOverridden(environment) ? NoLoginItem() : SystemLoginItem()
    }

    @MainActor
    static func setupMemory(environment: [String: String], defaults: UserDefaults = .standard) -> any SetupMemory {
        isOverridden(environment) ? VolatileSetupMemory() : DefaultsSetupMemory(defaults: defaults)
    }
}
