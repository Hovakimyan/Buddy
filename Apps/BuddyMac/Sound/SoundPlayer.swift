import AVFoundation
import AppKit
import Observation

/// Plays cues. Each cue gets a small pool of `AVAudioPlayer`s so a sound can overlap itself; players are made on the
/// first play of a cue and kept until `reload()`. Mute and volume are stored in `UserDefaults`.
///
/// The user's sounds folder is only read here, never created: `ensureOverrideFolder()` (behind "Open sounds folder")
/// is the one place that makes it.
@MainActor
@Observable
final class SoundPlayer {
    static let shared = SoundPlayer()

    static let mutedKey = "sound.muted"
    static let volumeKey = "sound.volume"
    static let defaultVolume: Float = 0.4
    static let poolSize = 3

    /// `~/Library/Application Support/Buddy/Sounds`, or `$BUDDY_HOME/Sounds` when that override is set (like the other
    /// support paths, `AppModel.Paths.standard`), so a test setup or a safe manual run never reads the real folder.
    nonisolated static func defaultOverrideDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let home = environment["BUDDY_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Sounds", isDirectory: true)
        }
        return URL.applicationSupportDirectory.appendingPathComponent("Buddy/Sounds", isDirectory: true)
    }

    /// "N custom sounds in use" for Settings.
    static func customCountText(_ count: Int) -> String {
        "\(count) custom \(count == 1 ? "sound" : "sounds") in use"
    }

    var isMuted: Bool {
        didSet { defaults.set(isMuted, forKey: Self.mutedKey) }
    }

    /// 0...1; assigning outside that range clamps.
    var volume: Float {
        didSet {
            let clamped = Self.clamp(volume)
            if clamped != volume { volume = clamped; return }
            defaults.set(volume, forKey: Self.volumeKey)
            for pool in pools.values { for player in pool.players { player.volume = volume } }
        }
    }

    /// How many cues the user's folder replaces, as of the last `reload()`.
    private(set) var customCount: Int

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let soundsRoot: URL
    @ObservationIgnored private let overrideDirectory: URL
    @ObservationIgnored private var pools: [SoundCue: Pool] = [:]
    @ObservationIgnored private var silentCues: Set<SoundCue> = []

    private struct Pool {
        var players: [AVAudioPlayer]
        var next = 0
    }

    /// - Parameters:
    ///   - soundsRoot: the folder holding one subfolder of bundled sounds per character (the app's `sounds`).
    init(
        defaults: UserDefaults = .standard,
        soundsRoot: URL = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("sounds", isDirectory: true),
        overrideDirectory: URL = SoundPlayer.defaultOverrideDirectory()
    ) {
        self.defaults = defaults
        self.soundsRoot = soundsRoot
        self.overrideDirectory = overrideDirectory
        isMuted = defaults.bool(forKey: Self.mutedKey)
        volume = (defaults.object(forKey: Self.volumeKey) as? NSNumber).map { Self.clamp($0.floatValue) }
            ?? Self.defaultVolume
        customCount = SoundLibrary.customCount(override: overrideDirectory)
    }

    /// Mutes or unmutes with a `tick` heard either way: played before muting, after unmuting. Setting the current
    /// value does nothing. The island, ⌃⌥M and Settings all mute through here.
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        if muted {
            play(.tick)
            isMuted = true
        } else {
            isMuted = false
            play(.tick)
        }
    }

    func play(_ cue: SoundCue) {
        guard !isMuted, let player = nextPlayer(for: cue) else { return }
        player.currentTime = 0
        player.volume = volume
        player.play()
    }

    /// Forgets the cached players and re-reads the sounds folder, so new, changed or removed files take effect.
    func reload() {
        pools = [:]
        silentCues = []
        customCount = SoundLibrary.customCount(override: overrideDirectory)
    }

    /// Makes the sounds folder if it is not there yet. Only "Open sounds folder" calls this.
    func ensureOverrideFolder() {
        try? FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
    }

    /// Creates the sounds folder if needed and shows it in Finder.
    func openOverrideFolder() {
        ensureOverrideFolder()
        NSWorkspace.shared.open(overrideDirectory)
    }

    // MARK: Internals

    /// The file a cue plays now: the user's, else the current character's bundled one.
    func resolvedURL(for cue: SoundCue) -> URL? { candidateURLs(for: cue).first }

    /// The user's file and the bundled one, in that order.
    private func candidateURLs(for cue: SoundCue) -> [URL] {
        let folder = CharacterRegistry.current(defaults: defaults).soundFolder
        return SoundLibrary.candidates(
            cue: cue, bundled: soundsRoot.appendingPathComponent(folder, isDirectory: true), override: overrideDirectory)
    }

    func pooledPlayerCount(for cue: SoundCue) -> Int { pools[cue]?.players.count ?? 0 }

    /// The file the cue's pooled players were loaded from (tests use it to see which source won).
    func pooledURL(for cue: SoundCue) -> URL? { pools[cue]?.players.first?.url }

    func pooledVolumes(for cue: SoundCue) -> [Float] { pools[cue]?.players.map(\.volume) ?? [] }

    /// An idle player of the cue's pool, or the oldest one when all are busy (it restarts).
    private func nextPlayer(for cue: SoundCue) -> AVAudioPlayer? {
        if pools[cue] == nil {
            guard !silentCues.contains(cue), let pool = makePool(for: cue) else {
                silentCues.insert(cue)
                return nil
            }
            pools[cue] = pool
        }
        guard var pool = pools[cue] else { return nil }
        let index = pool.players.firstIndex { !$0.isPlaying } ?? pool.next
        pool.next = (index + 1) % pool.players.count
        pools[cue] = pool
        return pool.players[index]
    }

    /// The first file that loads wins, so a broken custom file falls back to the bundled sound instead of silence.
    private func makePool(for cue: SoundCue) -> Pool? {
        for url in candidateURLs(for: cue) {
            if let pool = makePool(from: url) { return pool }
        }
        return nil
    }

    private func makePool(from url: URL) -> Pool? {
        var players: [AVAudioPlayer] = []
        for _ in 0..<Self.poolSize {
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.volume = volume
            player.prepareToPlay()
            players.append(player)
        }
        return Pool(players: players)
    }

    private static func clamp(_ value: Float) -> Float {
        value.isNaN ? defaultVolume : min(max(value, 0), 1)
    }
}
