import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// MediaPlayerManager owns the shared AVPlayer used by the headless
/// `MediaPlayer.*` bridge functions and by the `video_player` element
/// renderer. Only one source plays at a time: starting a new source (from
/// PHP or from an element surface) replaces the current one, so facade
/// calls (pause / resume / seek / volume / status) always drive whatever
/// is currently playing.
///
/// Fires "NativePHP\MediaPlayer\Events\PlaybackEnded" / "...\PlaybackError"
/// through `LaravelBridge.shared.send` — the same event-dispatch mechanism
/// the microphone plugin uses for MicrophoneRecorded.
final class MediaPlayerManager: NSObject {
    static let shared = MediaPlayerManager()

    /// Posted on the main thread whenever the shared slot changes hands —
    /// adopted, released, stopped, replaced. Surfaces reassess on it, so
    /// one that lost the slot to a neighbour can take it back the moment
    /// the neighbour lets go, even if its own geometry never changes again.
    static let slotDidChange = Notification.Name("NativePHP.MediaPlayer.slotDidChange")

    private(set) var player: AVPlayer?
    private(set) var source: String?
    private(set) var state: String = "idle"

    private var shouldLoop = false
    /// False while `player` belongs to a `video_player` surface (adopted via
    /// `adopt(player:)`): teardown then pauses and lets go instead of
    /// stripping the surface's item.
    private var ownsPlayer = true
    /// The slot is empty because PHP asked (`stop()`), not because a
    /// surface let go. Surfaces must not quietly resume after that; a
    /// threshold crossing (or `play()`) starts things again.
    private var stoppedByFacade = false
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var interruptionObserver: NSObjectProtocol?
    private var shouldResumeAfterInterruption = false
    private var nowPlayingTitle: String?
    private var nowPlayingArtist: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var artworkGeneration = 0

    private override init() {
        super.init()
        configureRemoteCommands()
        observeAudioInterruptions()
    }

    // MARK: - Playback control

    /// Start (or replace) playback. Returns false when the source can't be
    /// resolved to a URL or the player can't be created.
    @discardableResult
    func play(
        source: String,
        loop: Bool,
        volume: Float,
        title: String? = nil,
        artist: String? = nil,
        artwork: String? = nil
    ) -> Bool {
        guard let player = preparePlayer(source: source, loop: loop, muted: false, autoplay: true) else {
            return false
        }

        player.volume = max(0, min(1, volume))
        nowPlayingTitle = title?.isEmpty == false ? title : nil
        nowPlayingArtist = artist?.isEmpty == false ? artist : nil
        loadArtwork(from: artwork)
        updateNowPlayingInfo()

        return true
    }

    /// Create the shared player for a source without necessarily starting it.
    /// Used by both `play()` and the `video_player` element renderer — the
    /// renderer adopts the returned player as its surface's player so the PHP
    /// facade keeps controlling on-screen playback.
    ///
    /// If the shared player already holds this source it is returned as-is
    /// (so multiple renders of the same element don't restart playback).
    func preparePlayer(source: String, loop: Bool, muted: Bool, autoplay: Bool) -> AVPlayer? {
        if let existing = player, self.source == source {
            existing.isMuted = muted
            return existing
        }

        guard let url = Self.resolveURL(source) else {
            print("🎬 MediaPlayer: could not resolve source \(source)")
            dispatchError(source: source, message: "Could not resolve source URL")
            return nil
        }

        teardown()
        configureAudioSession()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted

        self.player = player
        self.source = source
        self.shouldLoop = loop
        self.ownsPlayer = true
        self.stoppedByFacade = false

        observe(item: item)

        if autoplay {
            player.play()
            state = "playing"
        } else {
            state = "paused"
        }

        notifySlotChanged()

        return player
    }

    /// Adopt a surface-owned player (a `video_player` inside a paged
    /// container) as the shared playback. Any previous playback is paused
    /// and released; the facade then drives this player until another one
    /// is adopted or `release(player:)` drops it.
    func adopt(player: AVPlayer, source: String, loop: Bool, autoplay: Bool) {
        if self.player === player {
            shouldLoop = loop
            if autoplay, state != "playing" {
                player.play()
                state = "playing"
            }
            return
        }

        teardown()
        configureAudioSession()

        self.player = player
        self.source = source
        self.shouldLoop = loop
        self.ownsPlayer = false
        self.stoppedByFacade = false

        if let item = player.currentItem {
            observe(item: item)
        }

        if autoplay {
            player.play()
            state = "playing"
        } else {
            state = "paused"
        }

        notifySlotChanged()
    }

    /// True when `player` is the surface the facade currently drives.
    func isAdopted(_ player: AVPlayer) -> Bool {
        self.player === player
    }

    /// True when a surface still mostly on screen may take the shared
    /// slot without crossing a threshold: nothing holds it (no adopted
    /// surface, no headless playback) and it was not emptied by an
    /// explicit `stop()`.
    var isReclaimable: Bool {
        player == nil && !stoppedByFacade
    }

    /// Drop `player` if it is the adopted one — its page left the screen
    /// or its surface is going away. Other players are untouched.
    func release(player: AVPlayer) {
        guard isAdopted(player) else { return }
        teardown()
        state = "idle"
        notifySlotChanged()
    }

    func pause() {
        guard let player = player, state == "playing" else { return }
        player.pause()
        state = "paused"
        updateNowPlayingInfo()
    }

    func resume() {
        guard let player = player else { return }
        if state == "ended" {
            player.seek(to: .zero)
        }
        player.play()
        state = "playing"
        updateNowPlayingInfo()
    }

    func stop() {
        teardown()
        state = "idle"
        stoppedByFacade = true
        notifySlotChanged()
    }

    func seek(to seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if state == "ended" {
            state = "paused"
        }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateNowPlayingInfo()
            }
        }
    }

    func setVolume(_ volume: Float) {
        player?.volume = max(0, min(1, volume))
    }

    func getStatus() -> [String: Any] {
        var position = 0.0
        var duration = 0.0

        if let player = player {
            let current = player.currentTime().seconds
            if current.isFinite {
                position = current
            }
            if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite {
                duration = itemDuration
            }
        }

        return [
            "state": state,
            "position": position,
            "duration": duration,
            "source": source ?? "",
        ]
    }

    private func notifySlotChanged() {
        NotificationCenter.default.post(name: Self.slotDidChange, object: self)
    }

    // MARK: - Now Playing & remote commands

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()

        commands.playCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            guard let self = self, self.player != nil else {
                return .noActionableNowPlayingItem
            }
            DispatchQueue.main.async { self.resume() }
            return .success
        }

        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.player != nil else {
                return .noActionableNowPlayingItem
            }
            DispatchQueue.main.async { self.pause() }
            return .success
        }

        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.player != nil else {
                return .noActionableNowPlayingItem
            }
            DispatchQueue.main.async {
                self.state == "playing" ? self.pause() : self.resume()
            }
            return .success
        }

        commands.skipForwardCommand.isEnabled = true
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else {
                return .noActionableNowPlayingItem
            }
            let position = player.currentTime().seconds
            DispatchQueue.main.async { self.seek(to: (position.isFinite ? position : 0) + 15) }
            return .success
        }

        commands.skipBackwardCommand.isEnabled = true
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.player else {
                return .noActionableNowPlayingItem
            }
            let position = player.currentTime().seconds
            DispatchQueue.main.async { self.seek(to: max(0, (position.isFinite ? position : 0) - 15)) }
            return .success
        }

        commands.changePlaybackPositionCommand.isEnabled = true
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  self.player != nil,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .noActionableNowPlayingItem
            }
            DispatchQueue.main.async { self.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let player = player, let source = source, ownsPlayer else { return }

        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle ?? Self.fallbackTitle(for: source),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position.isFinite ? max(0, position) : 0,
            MPNowPlayingInfoPropertyPlaybackRate: state == "playing" ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: source,
        ]

        if let artist = nowPlayingArtist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = state == "playing" ? .playing : .paused
    }

    private func loadArtwork(from artwork: String?) {
        artworkGeneration += 1
        let generation = artworkGeneration
        nowPlayingArtwork = nil

        guard let artwork = artwork,
              !artwork.isEmpty,
              let url = Self.resolveURL(artwork) else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
            let mediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

            DispatchQueue.main.async {
                guard let self = self, self.artworkGeneration == generation else { return }
                self.nowPlayingArtwork = mediaArtwork
                self.updateNowPlayingInfo()
            }
        }
    }

    private static func fallbackTitle(for source: String) -> String {
        guard let url = resolveURL(source), !url.lastPathComponent.isEmpty else { return source }
        let filename = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
        return filename.flatMap { $0.isEmpty ? nil : $0 } ?? source
    }

    private func clearNowPlayingInfo() {
        artworkGeneration += 1
        nowPlayingTitle = nil
        nowPlayingArtist = nil
        nowPlayingArtwork = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    // MARK: - Audio interruptions

    private func observeAudioInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            shouldResumeAfterInterruption = state == "playing"
            pause()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if shouldResumeAfterInterruption, options.contains(.shouldResume) {
                activateAudioSession()
                resume()
            }
            shouldResumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    // MARK: - Helpers

    /// Set the playback audio session category before playing (mirrors the
    /// microphone plugin's use of AVAudioSession.sharedInstance()).
    private var audioSessionConfigured = false

    func configureAudioSession() {
        // Once per process: re-activating the session on every adoption
        // (each page of a feed) is a visible hitch for the player already
        // rendering.
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            activateAudioSession()
        } catch {
            print("🎬 MediaPlayer: failed to configure audio session: \(error.localizedDescription)")
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("🎬 MediaPlayer: failed to activate audio session: \(error.localizedDescription)")
        }
    }

    /// Resolve a source string (http(s) URL, file:// URL, or bare file path)
    /// to a playable URL.
    static func resolveURL(_ source: String) -> URL? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("file://") {
            return URL(string: source)
        }

        if source.hasPrefix("/") {
            return URL(fileURLWithPath: source)
        }

        return URL(string: source)
    }

    // MARK: - Observation & events

    private func observe(item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleEnded()
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.handleError(message: error?.localizedDescription ?? "Playback failed")
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .failed {
                    self?.handleError(message: item.error?.localizedDescription ?? "Failed to load media")
                } else if item.status == .readyToPlay {
                    self?.updateNowPlayingInfo()
                }
            }
        }

        if let player = player {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                queue: .main
            ) { [weak self] _ in
                self?.updateNowPlayingInfo()
            }
        }
    }

    private func handleEnded() {
        if shouldLoop {
            player?.seek(to: .zero)
            player?.play()
            return
        }

        state = "ended"
        updateNowPlayingInfo()

        let payload: [String: Any] = ["source": source ?? ""]
        print("📤 Dispatching PlaybackEnded with source=\(source ?? "nil")")
        LaravelBridge.shared.send?("NativePHP\\MediaPlayer\\Events\\PlaybackEnded", payload)
    }

    private func handleError(message: String) {
        state = "error"
        updateNowPlayingInfo()
        dispatchError(source: source ?? "", message: message)
    }

    private func dispatchError(source: String, message: String) {
        let payload: [String: Any] = [
            "source": source,
            "message": message,
        ]
        print("📤 Dispatching PlaybackError with source=\(source), message=\(message)")
        LaravelBridge.shared.send?("NativePHP\\MediaPlayer\\Events\\PlaybackError", payload)
    }

    private func teardown() {
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failObserver = failObserver {
            NotificationCenter.default.removeObserver(failObserver)
        }
        endObserver = nil
        failObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil

        if let timeObserver = timeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        player?.pause()
        if ownsPlayer {
            player?.replaceCurrentItem(with: nil)
        }
        player = nil
        source = nil
        shouldLoop = false
        ownsPlayer = true
        shouldResumeAfterInterruption = false
        clearNowPlayingInfo()
    }
}
