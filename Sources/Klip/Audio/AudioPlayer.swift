import Foundation
import AVFoundation

/// Simple player to listen to saved voice notes (one at a time).
/// `playingFileName` lets the UI show the ▶/⏹ button on the item that's playing;
/// `elapsed`/`total` feed the progress bar of the row that's playing.
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()

    @Published private(set) var playingFileName: String?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var total: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var ticker: Timer?

    func isPlaying(_ fileName: String) -> Bool { playingFileName == fileName }

    /// Duration (seconds) of a local audio, without playing it. nil if it can't be read.
    static func duration(of url: URL) -> Double? {
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        return p.duration > 0 ? p.duration : nil
    }

    /// Toggles: if that file is already playing, stops it; otherwise plays it (stopping any other).
    func toggle(fileName: String) {
        if playingFileName == fileName { stop() } else { play(fileName: fileName) }
    }

    func play(fileName: String) {
        stop()
        let url = Storage.shared.audioURL(for: fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        guard p.play() else { return }
        player = p
        playingFileName = fileName
        elapsed = 0
        total = p.duration
        startTicker()
    }

    func stop() {
        stopTicker()
        player?.stop()
        player = nil
        if playingFileName != nil { playingFileName = nil }
        elapsed = 0; total = 0
    }

    /// Stops only if that file happens to be playing (e.g. when deleting it from history).
    func stopIfPlaying(_ fileName: String) {
        if playingFileName == fileName { stop() }
    }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.elapsed = p.currentTime
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        clear(if: player)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        clear(if: player)
    }

    /// Cleans up only if the one that finished is still the current player (avoids cutting off a new playback).
    private func clear(if finished: AVAudioPlayer) {
        DispatchQueue.main.async { [weak self] in
            guard let self, finished === self.player else { return }
            self.stop()
        }
    }
}
