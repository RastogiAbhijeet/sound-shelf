import AppKit
import Combine

/// Restore session-owned output mutes before replacing the application process.
final class AppRestartController: ObservableObject {
    typealias Launcher = (@escaping (Error?) -> Void) -> Void
    @Published private(set) var isRestarting = false
    private let launch: Launcher
    private let terminate: () -> Void
    private var timer: Timer?

    init(launch: @escaping Launcher = AppRestartController.launchReplacement,
         terminate: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.launch = launch
        self.terminate = terminate
    }

    deinit { timer?.invalidate() }

    static func launchReplacement(completion: @escaping (Error?) -> Void) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            completion(NSError(domain: "SoundShelf", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Launch the built SoundShelf.app to use Restart."]))
            return
        }
        let oldPID = ProcessInfo.processInfo.processIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                completion(error ?? (app == nil || app?.processIdentifier == oldPID || app?.isTerminated == true ? NSError(domain: "SoundShelf", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The replacement app did not launch."]) : nil))
            }
        }
    }

    func restart(model: MediaModel, shelfMute: ShelfMuteController, macMute: MacMuteController) {
        guard !isRestarting else { return }
        isRestarting = true
        let deadline = Date().addingTimeInterval(20)
        var restorationRequested = false
        func fail(_ message: String) {
            timer?.invalidate()
            timer = nil
            isRestarting = false
            model.error = message
        }
        func advance() {
            guard Date() < deadline else {
                fail("Could not restart while sound controls are busy. Try again once they respond.")
                return
            }
            guard !shelfMute.isBusy, model.busySourceIDs.isEmpty else { return }
            if !restorationRequested {
                restorationRequested = true
                if macMute.isMuted { macMute.toggle() }
                guard !macMute.isMuted else {
                    fail(macMute.error ?? "Could not restore Mac audio before restarting.")
                    return
                }
                if shelfMute.isMuted { shelfMute.toggle() }
                if shelfMute.isBusy { return }
            }
            guard !shelfMute.isMuted else {
                fail(model.error ?? "Could not restore SoundShelf audio before restarting.")
                return
            }
            timer?.invalidate()
            timer = nil
            launch { error in
                if let error { fail("Could not restart SoundShelf: \(error.localizedDescription)") }
                else { self.terminate() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in advance() }
        advance()
    }
}
