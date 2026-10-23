import Carbon.HIToolbox
import Foundation

/// What a global key combination does on the island.
enum HotkeyAction: Equatable, Hashable, Sendable {
    /// ⌃⌥M: sound on or off.
    case toggleMute
    /// ⌃⌥] and ⌃⌥[: focus the next or previous session in the list, wrapping.
    case nextSession, previousSession
    /// ⌃⌥A: open the island on the waiting card.
    case showPending
    /// Escape, only while the island is expanded: collapse it.
    case escape
    /// 1-4, only while a question is the front card: pick the option at that place.
    case pick(Int)
}

/// A key and its modifiers, as Carbon's `RegisterEventHotKey` takes them (a virtual key code and Carbon modifier
/// flags such as `controlKey`).
struct Hotkey: Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
}

/// Which keys do what, and the focus cycling, kept pure so they are unit-tested. `HotkeyCenter` is the Carbon glue.
enum Hotkeys {
    static let controlOption = UInt32(controlKey | optionKey)

    /// Registered as long as the island runs.
    static let global: [Hotkey] = [
        Hotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: controlOption),
        Hotkey(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: controlOption),
        Hotkey(keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: controlOption),
        Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: controlOption),
    ]

    /// Escape without modifiers. Taken from every other app while registered, so only while expanded.
    static let escape = Hotkey(keyCode: UInt32(kVK_Escape), modifiers: 0)

    /// 1 to 4 without modifiers, for the question card's options. Taken only while `wantsDigits`.
    static let digits: [Hotkey] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4].map {
        Hotkey(keyCode: UInt32($0), modifiers: 0)
    }

    static func action(for hotkey: Hotkey) -> HotkeyAction? {
        if hotkey == escape { return .escape }
        if let place = digits.firstIndex(of: hotkey) { return .pick(place + 1) }
        guard hotkey.modifiers == controlOption else { return nil }
        switch Int(hotkey.keyCode) {
        case kVK_ANSI_M: return .toggleMute
        case kVK_ANSI_RightBracket: return .nextSession
        case kVK_ANSI_LeftBracket: return .previousSession
        case kVK_ANSI_A: return .showPending
        default: return nil
        }
    }

    /// Whether Escape should be registered: only while the island is expanded and the pointer is on it. Escape belongs
    /// to vim and the terminal, and a waiting card can hold the island open for minutes. While the "Other..." field is
    /// open (`typing`) Escape is the field's: it closes the field.
    static func wantsEscape(mode: IslandMode, pointerInside: Bool, typing: Bool = false) -> Bool {
        mode == .expanded && pointerInside && !typing
    }

    /// Whether 1-4 should be registered: like Escape, and only while a question is the front card. While typing they
    /// are the field's.
    static func wantsDigits(mode: IslandMode, pointerInside: Bool, questionFront: Bool, typing: Bool) -> Bool {
        questionFront && wantsEscape(mode: mode, pointerInside: pointerInside, typing: typing)
    }

    /// The session after (or before) `current` in `ids`, wrapping at the ends. From no session, or one that is gone,
    /// forward starts at the first and backward at the last. Nil without sessions.
    static func cycle(_ ids: [String], from current: String?, forward: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return forward ? ids.first : ids.last }
        let next = (index + (forward ? 1 : ids.count - 1)) % ids.count
        return ids[next]
    }
}

/// Registers global hot keys with Carbon (`RegisterEventHotKey`, which needs no permission) and calls `onAction`
/// on the main thread when one is pressed. Thin on purpose: the mapping is `Hotkeys`.
@MainActor
final class HotkeyCenter {
    var onAction: (HotkeyAction) -> Void = { _ in }

    // Unsafe only so `deinit` can release them; everything else touches them on the main actor.
    nonisolated(unsafe) private var handler: EventHandlerRef?
    nonisolated(unsafe) private var registered: [Hotkey: (id: UInt32, ref: EventHotKeyRef)] = [:]
    private var nextID: UInt32 = 1
    /// "BDDY": tells Buddy's hot keys from anyone else's in the same event.
    nonisolated static let signature: OSType = 0x4244_4459

    /// Freed without `stop()`: the keys and the handler (which points at this object) must not outlive it.
    deinit {
        for entry in registered.values { UnregisterEventHotKey(entry.ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Installs the event handler; registering keys needs it. Safe to call more than once.
    func start() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(), hotkeyPressed, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Unregisters every key and removes the handler.
    func stop() {
        for hotkey in Array(registered.keys) { unregister(hotkey) }
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func register(_ hotkey: Hotkey) {
        guard handler != nil, registered[hotkey] == nil else { return }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        // Another app may own the combination already; then this key just does nothing.
        guard status == noErr, let ref else { return }
        registered[hotkey] = (id, ref)
    }

    func unregister(_ hotkey: Hotkey) {
        guard let entry = registered.removeValue(forKey: hotkey) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    func isRegistered(_ hotkey: Hotkey) -> Bool { registered[hotkey] != nil }

    fileprivate func pressed(id: UInt32) {
        guard let hotkey = registered.first(where: { $0.value.id == id })?.key,
              let action = Hotkeys.action(for: hotkey) else { return }
        onAction(action)
    }
}

/// Carbon calls this on the main thread for every hot key of the application.
private func hotkeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { center.pressed(id: id.id) }
    return noErr
}
