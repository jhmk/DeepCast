import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// Episode player: speed without pitch change, chapters, resume position, media keys and
/// Now Playing (Control Center / Touch Bar / AirPods).
@MainActor
@Observable
final class PlayerModel {
    static let speeds: [Float] = [0.8, 1.0, 1.2, 1.4, 1.6, 2.0]
    static let skipBack: TimeInterval = 15
    static let skipForward: TimeInterval = 30

    private(set) var episode: Episode?
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    var rate: Float = 1.0 {
        didSet {
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
            updateNowPlaying()
        }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSavedPosition: TimeInterval = 0

    init() {
        player.defaultRate = rate
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish() }
        }
        registerRemoteCommands()
    }

    func load(_ episode: Episode) {
        guard self.episode?.id != episode.id || player.currentItem == nil else { return }
        savePosition()
        guard let url = episode.audioURL, FileManager.default.fileExists(atPath: url.path) else {
            unload()
            self.episode = episode
            return
        }
        let item = AVPlayerItem(url: url)
        // Spectral keeps voices natural at 1.4–2× (time-domain sounds metallic for speech).
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        self.episode = episode
        duration = episode.duration
        let resume = episode.playbackPosition < episode.duration - 5 ? episode.playbackPosition : 0
        seek(to: resume)
        updateNowPlaying()
    }

    /// Reload after re-rendering (same episode, new file).
    func reload(_ episode: Episode) {
        unload()
        load(episode)
    }

    func unload() {
        pause()
        player.replaceCurrentItem(with: nil)
        episode = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard player.currentItem != nil else { return }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        savePosition()
        updateNowPlaying()
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(0, duration))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func skip(by seconds: TimeInterval) { seek(to: currentTime + seconds) }

    var chapters: [ChapterMarker] { episode?.chapters ?? [] }

    var currentChapter: ChapterMarker? {
        chapters.last { $0.start <= currentTime + 0.05 }
    }

    func nextChapter() {
        if let next = chapters.first(where: { $0.start > currentTime + 0.5 }) { seek(to: next.start) }
    }

    /// Jumps to the start of the chapter, or the previous one when already near the start.
    func previousChapter() {
        guard let current = currentChapter else { return seek(to: 0) }
        if currentTime - current.start > 3 { return seek(to: current.start) }
        let previous = chapters.last { $0.start < current.start }
        seek(to: previous?.start ?? 0)
    }

    // MARK: - Private

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if abs(seconds - lastSavedPosition) > 5 { savePosition() }
    }

    private func didFinish() {
        isPlaying = false
        episode?.playbackPosition = 0
        lastSavedPosition = 0
        updateNowPlaying()
    }

    private func savePosition() {
        guard let episode, currentTime > 0 else { return }
        episode.playbackPosition = currentTime
        lastSavedPosition = currentTime
    }

    private func updateNowPlaying() {
        guard let episode else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: "DeepCast",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBack)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -Self.skipBack) }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: Self.skipForward) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }
}

/// Short previews: a single segment, a persona voice or a Fish library sample.
@MainActor
@Observable
final class PreviewPlayer {
    private(set) var playingKey: String?
    private(set) var loadingKey: String?
    private(set) var lastError: String?
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?

    init() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let finishedItem = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let current = self.player.currentItem,
                      finishedItem == ObjectIdentifier(current) else { return }
                self.playingKey = nil
            }
        }
    }

    func play(url: URL, key: String) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        playingKey = key
    }

    func stop() {
        player.pause()
        playingKey = nil
    }

    /// Renders text with the persona's current voice settings and plays it.
    func preview(text: String, persona: Persona, mode: SpeechMode, key: String, pronunciations: [String: String] = [:]) {
        stop()
        loadingKey = key
        lastError = nil
        let fishKey = mode == .fishWithAppleFallback ? KeychainStore.read(.fishAudio) : nil
        Task {
            do {
                let renderer = SpeechRenderer(mode: mode, fishAPIKey: fishKey, pronunciations: pronunciations)
                let result = try await renderer.render(text: text, persona: persona)
                lastError = result.fallbackReason.map { String(localized: "Apple-Fallback: \($0)") }
                loadingKey = nil
                play(url: result.url, key: key)
            } catch {
                loadingKey = nil
                lastError = error.localizedDescription
            }
        }
    }
}
