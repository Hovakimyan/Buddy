import Foundation

/// Finds the file for a cue: the user's sounds folder first, then the bundled set. Missing folders are empty.
struct SoundLibrary {
    /// Audio formats a cue file may have, in lookup order.
    static let extensions = ["wav", "caf", "m4a"]

    static func resolve(cue: SoundCue, bundled: URL, override: URL) -> URL? {
        candidates(cue: cue, bundled: bundled, override: override).first
    }

    /// Every file that could play the cue, best first: the user's, then the bundled one. The player falls through
    /// to the next when a file cannot be loaded.
    static func candidates(cue: SoundCue, bundled: URL, override: URL) -> [URL] {
        [file(for: cue, in: override), file(for: cue, in: bundled)].compactMap { $0 }
    }

    /// How many cues the user's folder replaces. Files that are not named like a cue do not count.
    static func customCount(override: URL) -> Int {
        SoundCue.allCases.filter { file(for: $0, in: override) != nil }.count
    }

    private static func file(for cue: SoundCue, in directory: URL) -> URL? {
        for ext in extensions {
            let url = directory.appendingPathComponent("\(cue.rawValue).\(ext)")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return url
            }
        }
        return nil
    }
}
