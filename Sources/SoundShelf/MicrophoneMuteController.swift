import Foundation
import Combine

/// A session-owned group mute. Unknown sources and pre-existing mutes are excluded.
/// Restart intentionally leaves microphones muted rather than enabling them.
final class MicrophoneMuteController: ObservableObject {
    @Published private(set) var isMuted = false
    @Published private(set) var isBusy = false
    private let model: MediaModel
    private var owned: [String: MicrophoneSource] = [:]
    private var attempted: Set<String> = []
    private var timer: Timer?

    init(model: MediaModel, startTimer: Bool = true) {
        self.model = model
        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }
    deinit { timer?.invalidate() }

    var canMute: Bool {
        model.microphoneSources.contains { $0.controllable && $0.state == .enabled }
    }
    private func identity(_ source: MicrophoneSource) -> String {
        source.id + ":" + (source.browser?.id ?? "")
    }
    func toggle() {
        guard !isBusy, model.busyMicrophoneIDs.isEmpty else { return }
        if isMuted { restore() }
        else {
            guard canMute else { return }
            attempted = []
            isMuted = true
            refresh()
        }
    }
    func refresh() {
        guard isMuted, !isBusy else { return }
        let targets = model.microphoneSources.filter {
            $0.controllable && $0.state == .enabled && !attempted.contains(identity($0)) &&
                !model.busyMicrophoneIDs.contains($0.id)
        }
        guard !targets.isEmpty else { return }
        isBusy = true
        var remaining = targets.count
        for source in targets {
            let key = identity(source)
            attempted.insert(key)
            // A failed acknowledgement may follow a successful mute. Retain the
            // original state for an explicit restore, never an automatic unmute.
            owned[key] = source
            model.microphoneCommand(source, muted: true) { [weak self] success in
                guard let self else { return }
                if !success && self.model.error == nil { self.model.error = "A microphone did not confirm mute. Check the call." }
                remaining -= 1
                if remaining == 0 { self.isBusy = false }
            }
        }
    }
    private func restore() {
        let live = Dictionary(uniqueKeysWithValues: model.microphoneSources.map { (identity($0), $0) })
        owned = owned.filter { live[$0.key] != nil }
        let targets = owned.keys.compactMap { live[$0] }.filter { $0.controllable && $0.state != .unknown }
        guard !targets.isEmpty else {
            finishRestore()
            return
        }
        isBusy = true
        var remaining = targets.count
        for source in targets {
            let key = identity(source)
            model.microphoneCommand(source, muted: false) { [weak self] success in
                guard let self else { return }
                if success { self.owned.removeValue(forKey: key) }
                remaining -= 1
                if remaining == 0 {
                    self.isBusy = false
                    self.finishRestore()
                }
            }
        }
    }
    private func finishRestore() {
        isMuted = !owned.isEmpty
        if isMuted && model.error == nil { model.error = "Some microphones could not be restored. Open the call and try again." }
        if !isMuted { attempted = [] }
    }
}
