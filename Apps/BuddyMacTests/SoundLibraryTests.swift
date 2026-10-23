import AVFoundation
import Foundation
import Testing

// SAFETY: every test uses temporary directories and a throwaway UserDefaults suite. Nothing here may touch
// ~/Library/Application Support/Buddy or UserDefaults.standard.

/// A fresh temporary directory (created) that tests fill with sound files.
private func tempDirectory(_ label: String = "sounds") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("buddy-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func touch(_ name: String, in directory: URL) {
    try! Data("x".utf8).write(to: directory.appendingPathComponent(name))
}

/// A valid, silent 16-bit mono WAV of `frames` samples, so a real `AVAudioPlayer` can load it.
private func silentWav(frames: Int = 441) -> Data {
    func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) } }
    func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    let dataSize = UInt32(frames * 2)
    var bytes: [UInt8] = Array("RIFF".utf8) + le32(36 + dataSize) + Array("WAVE".utf8)
    bytes += Array("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(44_100) + le32(88_200) + le16(2) + le16(16)
    bytes += Array("data".utf8) + le32(dataSize) + [UInt8](repeating: 0, count: frames * 2)
    return Data(bytes)
}

private func defaultsSuite(_ label: String) -> (UserDefaults, String) {
    let name = "buddy-test-sound-\(label)-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

@Suite struct SoundLibraryTests {
    /// Under `BUDDY_HOME` (a test setup or a safe manual run) the sounds folder is inside it, like every other support
    /// path, so such a run never reads the real one. Only paths are computed here; nothing is read.
    @Test func theSoundsFolderFollowsBuddyHome() {
        let home = "/tmp/buddy-home-\(UUID().uuidString.prefix(8))"
        #expect(SoundPlayer.defaultOverrideDirectory(environment: ["BUDDY_HOME": home]).path == "\(home)/Sounds")
        let real = URL.applicationSupportDirectory.appendingPathComponent("Buddy/Sounds", isDirectory: true).path
        #expect(SoundPlayer.defaultOverrideDirectory(environment: [:]).path == real)
        #expect(SoundPlayer.defaultOverrideDirectory(environment: ["BUDDY_HOME": ""]).path == real)
    }

    @Test func overrideBeatsBundled() {
        let bundled = tempDirectory("bundled"), override = tempDirectory("override")
        touch("finish.wav", in: bundled)
        touch("finish.m4a", in: override)
        let url = SoundLibrary.resolve(cue: .finish, bundled: bundled, override: override)
        #expect(url?.standardizedFileURL == override.appendingPathComponent("finish.m4a").standardizedFileURL)
    }

    @Test func bundledIsUsedWithoutAnOverride() {
        let bundled = tempDirectory("bundled"), override = tempDirectory("override")
        touch("approval.wav", in: bundled)
        let url = SoundLibrary.resolve(cue: .approval, bundled: bundled, override: override)
        #expect(url?.standardizedFileURL == bundled.appendingPathComponent("approval.wav").standardizedFileURL)
    }

    @Test func allThreeExtensionsAreRecognised() {
        let override = tempDirectory("override"), bundled = tempDirectory("bundled")
        touch("peek.wav", in: override)
        touch("open.caf", in: override)
        touch("close.m4a", in: override)
        for (cue, ext) in [(SoundCue.peek, "wav"), (.open, "caf"), (.close, "m4a")] {
            let url = SoundLibrary.resolve(cue: cue, bundled: bundled, override: override)
            #expect(url?.lastPathComponent == "\(cue.rawValue).\(ext)")
        }
    }

    @Test func theSwitchCueIsLookedUpAsSwitch() {
        let bundled = tempDirectory("bundled"), override = tempDirectory("override")
        touch("switch.wav", in: override)
        #expect(SoundLibrary.resolve(cue: .switchSession, bundled: bundled, override: override)?.lastPathComponent == "switch.wav")
    }

    @Test func missingSoundResolvesToNil() {
        let bundled = tempDirectory("bundled"), override = tempDirectory("override")
        touch("finish.wav", in: bundled)
        #expect(SoundLibrary.resolve(cue: .error, bundled: bundled, override: override) == nil)
    }

    @Test func missingFoldersAreEmpty() {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-gone-\(UUID().uuidString)")
        #expect(SoundLibrary.resolve(cue: .finish, bundled: gone, override: gone) == nil)
        #expect(SoundLibrary.customCount(override: gone) == 0)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func otherExtensionsAndUnknownNamesAreIgnored() {
        let bundled = tempDirectory("bundled"), override = tempDirectory("override")
        touch("finish.mp3", in: override)
        touch("finish.txt", in: override)
        touch("finish", in: override)
        touch("whoosh.wav", in: override)
        #expect(SoundLibrary.resolve(cue: .finish, bundled: bundled, override: override) == nil)
        #expect(SoundLibrary.customCount(override: override) == 0)
    }

    @Test func aFolderNamedLikeACueIsNotASound() {
        let bundled = tempDirectory("bundled"), override = tempDirectory("override")
        try! FileManager.default.createDirectory(
            at: override.appendingPathComponent("finish.wav"), withIntermediateDirectories: true)
        #expect(SoundLibrary.resolve(cue: .finish, bundled: bundled, override: override) == nil)
        #expect(SoundLibrary.customCount(override: override) == 0)
    }

    @Test func customCountCountsOnlyCueNamedFiles() {
        let override = tempDirectory("override")
        touch("finish.wav", in: override)
        touch("approval.m4a", in: override)
        touch("switch.caf", in: override)
        touch("notes.txt", in: override)
        touch("whoosh.wav", in: override)
        #expect(SoundLibrary.customCount(override: override) == 3)
    }

    @Test func aCueWithTwoFilesCountsOnce() {
        let override = tempDirectory("override")
        touch("finish.wav", in: override)
        touch("finish.m4a", in: override)
        #expect(SoundLibrary.customCount(override: override) == 1)
    }
}

/// The committed bundled set (`Resources/sounds`), found from this source file because the tests are not hosted by the
/// app. The release script separately checks that the built app carries these exact files.
@Suite struct BundledSoundSetTests {
    private static let soundsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("BuddyMac/Resources/sounds", isDirectory: true)

    @Test func bundledSetComplete() throws {
        let block = Self.soundsDirectory.appendingPathComponent("block", isDirectory: true)
        let sources = try String(contentsOf: Self.soundsDirectory.appendingPathComponent("SOURCES.md"), encoding: .utf8)
        let lines = sources.components(separatedBy: .newlines)
        for cue in SoundCue.allCases {
            let name = "\(cue.rawValue).wav"
            let url = block.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(name) is missing from sounds/block")
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            #expect(seconds > 0 && seconds < 1.5, "\(name) is \(seconds) s, expected under 1.5 s")
            #expect(lines.contains { $0.contains(name) && $0.contains("CC0") }, "\(name) has no CC0 line in SOURCES.md")
        }
    }
}

@MainActor
@Suite struct SoundPlayerTests {
    private struct Fixture {
        let player: SoundPlayer
        let defaults: UserDefaults
        let suite: String
        let soundsRoot: URL
        let override: URL
    }

    /// `block` is the registered character's sound folder, so bundled files go under `soundsRoot/block`.
    private func fixture(muted: Bool? = nil, volume: Float? = nil, withBundled cues: [SoundCue] = []) -> Fixture {
        let (defaults, suite) = defaultsSuite("player")
        if let muted { defaults.set(muted, forKey: SoundPlayer.mutedKey) }
        if let volume { defaults.set(volume, forKey: SoundPlayer.volumeKey) }
        let root = tempDirectory("root")
        let block = root.appendingPathComponent("block", isDirectory: true)
        try! FileManager.default.createDirectory(at: block, withIntermediateDirectories: true)
        for cue in cues { try! silentWav().write(to: block.appendingPathComponent("\(cue.rawValue).wav")) }
        // The override folder does not exist yet, as on a fresh install.
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-override-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let player = SoundPlayer(defaults: defaults, soundsRoot: root, overrideDirectory: override)
        return Fixture(player: player, defaults: defaults, suite: suite, soundsRoot: root, override: override)
    }

    @Test func defaultsAreUnmutedAtFortyPercent() {
        let f = fixture()
        #expect(f.player.isMuted == false)
        #expect(f.player.volume == 0.4)
    }

    @Test func muteAndVolumePersistAcrossPlayers() {
        let f = fixture()
        f.player.isMuted = true
        f.player.volume = 0.75
        #expect(f.defaults.bool(forKey: "sound.muted") == true)
        #expect(f.defaults.float(forKey: "sound.volume") == 0.75)
        let again = SoundPlayer(defaults: f.defaults, soundsRoot: f.soundsRoot, overrideDirectory: f.override)
        #expect(again.isMuted)
        #expect(again.volume == 0.75)
    }

    @Test func volumeClampsToZeroThroughOne() {
        let f = fixture()
        f.player.volume = 1.5
        #expect(f.player.volume == 1)
        f.player.volume = -0.2
        #expect(f.player.volume == 0)
        // A stored out-of-range value is clamped on load too.
        let loaded = fixture(volume: 7)
        #expect(loaded.player.volume == 1)
    }

    /// Muting or unmuting (the island, ⌃⌥M or Settings) ticks while the sound is on: before muting, after unmuting.
    @Test func togglingMuteTicksEitherWay() {
        let on = fixture(volume: 0, withBundled: [.tick])
        on.player.setMuted(true)
        #expect(on.player.isMuted)
        #expect(on.player.pooledPlayerCount(for: .tick) == 3)

        let off = fixture(muted: true, volume: 0, withBundled: [.tick])
        off.player.setMuted(false)
        #expect(!off.player.isMuted)
        #expect(off.player.pooledPlayerCount(for: .tick) == 3)

        // Setting what is already set does nothing.
        let same = fixture(muted: true, volume: 0, withBundled: [.tick])
        same.player.setMuted(true)
        #expect(same.player.pooledPlayerCount(for: .tick) == 0)
    }

    @Test func mutedPlayDoesNothing() {
        let f = fixture(muted: true, volume: 0, withBundled: [.finish])
        f.player.play(.finish)
        #expect(f.player.pooledPlayerCount(for: .finish) == 0)
    }

    @Test func playBuildsAPoolOfThreeForTheCue() {
        let f = fixture(volume: 0, withBundled: [.finish])
        f.player.play(.finish)
        #expect(f.player.pooledPlayerCount(for: .finish) == 3)
        #expect(f.player.pooledPlayerCount(for: .error) == 0)
        // Playing again reuses the pool.
        f.player.play(.finish)
        #expect(f.player.pooledPlayerCount(for: .finish) == 3)
    }

    @Test func aCueWithoutAFileIsSilentAndMakesNoPool() {
        let f = fixture(volume: 0)
        f.player.play(.finish)
        #expect(f.player.pooledPlayerCount(for: .finish) == 0)
    }

    @Test func volumeAppliesToEveryPooledPlayer() {
        let f = fixture(volume: 0, withBundled: [.finish])
        f.player.play(.finish)
        #expect(f.player.pooledVolumes(for: .finish) == [0, 0, 0])
        f.player.volume = 0.6
        #expect(f.player.pooledVolumes(for: .finish) == [0.6, 0.6, 0.6])
    }

    @Test func reloadDropsCachedPlayersAndPicksUpNewOverrides() throws {
        let f = fixture(volume: 0, withBundled: [.finish])
        f.player.play(.finish)
        #expect(f.player.pooledPlayerCount(for: .finish) == 3)
        #expect(f.player.customCount == 0)

        try FileManager.default.createDirectory(at: f.override, withIntermediateDirectories: true)
        try silentWav(frames: 882).write(to: f.override.appendingPathComponent("finish.wav"))
        f.player.reload()
        #expect(f.player.pooledPlayerCount(for: .finish) == 0)
        #expect(f.player.customCount == 1)

        f.player.play(.finish)
        #expect(f.player.pooledPlayerCount(for: .finish) == 3)
        #expect(f.player.resolvedURL(for: .finish)?.deletingLastPathComponent().standardizedFileURL
            == f.override.standardizedFileURL)
    }

    @Test func aCorruptOverrideFallsBackToTheBundledFile() throws {
        let f = fixture(volume: 0, withBundled: [.finish])
        try FileManager.default.createDirectory(at: f.override, withIntermediateDirectories: true)
        try Data((0..<256).map { _ in UInt8.random(in: 0...255) }).write(to: f.override.appendingPathComponent("finish.wav"))
        f.player.reload()
        f.player.play(.finish)
        #expect(f.player.pooledPlayerCount(for: .finish) == 3)
        #expect(f.player.pooledURL(for: .finish)?.standardizedFileURL
            == f.soundsRoot.appendingPathComponent("block/finish.wav").standardizedFileURL)
    }

    @Test func aValidOverrideStillBeatsTheBundledFile() throws {
        let f = fixture(volume: 0, withBundled: [.finish])
        try FileManager.default.createDirectory(at: f.override, withIntermediateDirectories: true)
        try silentWav(frames: 882).write(to: f.override.appendingPathComponent("finish.wav"))
        f.player.reload()
        f.player.play(.finish)
        #expect(f.player.pooledURL(for: .finish)?.standardizedFileURL
            == f.override.appendingPathComponent("finish.wav").standardizedFileURL)
    }

    @Test func aCorruptOverrideWithNoBundledFileIsSilent() throws {
        let f = fixture(volume: 0)
        try FileManager.default.createDirectory(at: f.override, withIntermediateDirectories: true)
        try Data("not audio".utf8).write(to: f.override.appendingPathComponent("finish.wav"))
        f.player.play(.finish)
        #expect(f.player.pooledPlayerCount(for: .finish) == 0)
    }

    @Test func thePlayerNeverCreatesTheOverrideFolderButOpeningDoes() {
        let f = fixture(volume: 0, withBundled: [.finish])
        f.player.play(.finish)
        f.player.reload()
        _ = f.player.customCount
        #expect(!FileManager.default.fileExists(atPath: f.override.path))
        f.player.ensureOverrideFolder()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: f.override.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func defaultOverrideFolderIsUnderApplicationSupportBuddy() {
        #expect(SoundPlayer.defaultOverrideDirectory(environment: [:]).path.hasSuffix("Library/Application Support/Buddy/Sounds"))
    }

    @Test func customCountTextReadsNaturally() {
        #expect(SoundPlayer.customCountText(0) == "0 custom sounds in use")
        #expect(SoundPlayer.customCountText(1) == "1 custom sound in use")
        #expect(SoundPlayer.customCountText(5) == "5 custom sounds in use")
    }
}
