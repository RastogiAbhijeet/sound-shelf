import AppKit
import Combine
import Foundation
import Darwin

struct MediaSource: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let playing: Bool
    let ready: Bool
    let volume: Double?
    let muted: Bool?
    var displayName: String? = nil
    var supportsPlayback: Bool = true
    var connection: String? = nil
    var browserSource: BrowserSource? = nil
    var nativeApp: String? = nil
}

struct BrowserSource: Codable, Equatable {
    let id: String
    let tabId: Int
    let frameId: Int
    let title: String
    let site: String
    let playing: Bool
    let ready: Bool
    let volume: Double
    let muted: Bool
    var supportsPlayback: Bool? = nil
    var siteName: String? = nil
    var tabTitle: String? = nil
}

extension BrowserSource {
    /// Legacy companions report elements. Keep one row per connection + tab, never by title.
    static func grouped(_ elements: [BrowserSource], preferred: [Int: String] = [:]) -> [BrowserSource] {
        Dictionary(grouping: elements, by: \.tabId).values.compactMap { items in
            guard let player = items.sorted(by: {
                if $0.playing != $1.playing { return $0.playing }
                let a = $0.id == preferred[$0.tabId], b = $1.id == preferred[$1.tabId]
                if a != b { return a }
                if ($0.frameId == 0) != ($1.frameId == 0) { return $0.frameId == 0 }
                return $0.id < $1.id
            }).first else { return nil }
            let active = items.filter(\.playing)
            let audible = active.isEmpty ? [player] : active
            return BrowserSource(id: player.id, tabId: player.tabId, frameId: player.frameId,
                title: player.title, site: player.site, playing: !active.isEmpty,
                ready: items.allSatisfy(\.ready), volume: player.volume,
                muted: audible.allSatisfy { $0.muted || $0.volume == 0 }, supportsPlayback: player.supportsPlayback, siteName: player.siteName, tabTitle: player.tabTitle)
        }.sorted { $0.tabId < $1.tabId }
    }

    var displayName: String {
        let host = site.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return "Browser tab" }
        let labels = host.split(separator: ".").map(String.init)
        let sharedSuffixes: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac"]
        let suffixCount = labels.count > 2 && labels.last?.count == 2 && sharedSuffixes.contains(labels[labels.count - 2]) ? 2 : 1
        let brand = labels.count > suffixCount ? labels[labels.count - suffixCount - 1] : host
        let known = ["youtube": "YouTube", "spotify": "Spotify", "discord": "Discord",
                     "amazon": "Amazon", "dellstore": "Dell Store"]
        if host == "meet.google.com" { return "Google Meet" }
        if let name = known[brand] { return name }
        if let name = siteName?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), !name.isEmpty {
            return String(name.prefix(80))
        }
        if host.contains(":") || labels.allSatisfy({ Int($0) != nil }) { return host }
        return brand.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }

    func row(connection: String) -> MediaSource {
        let currentTitle = tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return MediaSource(id: "\(connection):tab:\(tabId)", title: currentTitle.isEmpty ? title : currentTitle,
            subtitle: "\(site) · Browser tab", playing: playing, ready: ready, volume: volume, muted: muted,
            displayName: displayName, supportsPlayback: supportsPlayback ?? true, connection: connection, browserSource: self)
    }
}

enum MicrophoneState: String, Codable { case unknown, enabled, disabled }

struct BrowserMicrophone: Codable, Equatable {
    let id: String
    let tabId: Int
    let frameId: Int
    let title: String
    let subtitle: String
    let capability: String
    let state: MicrophoneState
    let controllable: Bool

    func row(connection: String) -> MicrophoneSource {
        let available = capability == "app-control" && controllable && state != .unknown
        return MicrophoneSource(id: "\(connection):tab:\(tabId)", title: title, subtitle: subtitle,
            state: available ? state : .unknown, capability: capability, controllable: available,
            connection: connection, browser: self)
    }
}

struct MicrophoneSource: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    var state: MicrophoneState
    let capability: String
    var controllable: Bool
    var connection: String? = nil
    var browser: BrowserMicrophone? = nil
    var nativeApp: String? = nil

    var unavailable: MicrophoneSource {
        var copy = self
        copy.state = .unknown
        copy.controllable = false
        return copy
    }
}

struct BridgeSnapshot: Decodable {
    let updatedAt: Double
    let sources: [BrowserSource]
    let microphones: [BrowserMicrophone]?
    let revision: Int?

    private enum CodingKeys: String, CodingKey { case updatedAt, sources, microphones, revision }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try values.decode(Double.self, forKey: .updatedAt)
        sources = try values.decode([BrowserSource].self, forKey: .sources)
        revision = try? values.decode(Int.self, forKey: .revision)
        // An incompatible optional mic payload must never remove sound controls.
        microphones = try? values.decode([BrowserMicrophone].self, forKey: .microphones)
    }
}

final class MediaModel: ObservableObject {
    @Published var sources: [MediaSource] = []
    @Published private(set) var microphoneSources: [MicrophoneSource] = []
    @Published private(set) var busyMicrophoneIDs: Set<String> = []
    @Published var browserCount = 0
    @Published var error: String?
    @Published private(set) var busySourceIDs: Set<String> = []
    @Published var nativeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(nativeEnabled, forKey: "nativePlayers")
            if nativeEnabled { pollNative() } else { nativeSources = []; refreshBridge() }
        }
    }
    private let discoverNativeMicrophones: Bool
    private var nativeSources: [MediaSource] = []
    private var timer: Timer?
    private var bridgeWatcher: DispatchSourceFileSystemObject?
    private var ticks = 0
    private var nativeBusy = false
    private var nativeVolumesBeforeMute: [String: Double] = [:]
    private struct PendingControl {
        let sourceID: String
        let connection: String
        let started: Date
        let locksControls: Bool
        let completion: ((Bool) -> Void)?
        var microphone = false
        var documentID: String? = nil
        var expectedMicrophoneState: MicrophoneState? = nil
    }
    private var pending: [String: PendingControl] = [:]
    private var missingMicrophoneConnections: [String: Date] = [:]
    private var preferredBrowserPlayers: [String: [Int: String]] = [:]
    private let nativeQueue = DispatchQueue(label: "SoundShelf.native")
    private let bridge: URL

    init(bridgeURL: URL? = nil, startTimer: Bool = true, nativePlayersEnabled: Bool? = nil, discoverNativeMicrophones: Bool = true) {
        self.discoverNativeMicrophones = discoverNativeMicrophones
        bridge = bridgeURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SoundShelf/Bridge", isDirectory: true)
        // Discover open music apps without requiring a hidden setup toggle first.
        // An explicit opt-out remains respected; an unset preference connects automatically.
        nativeEnabled = nativePlayersEnabled ?? (UserDefaults.standard.object(forKey: "nativePlayers") as? Bool) ?? true
        if startTimer { watchBridge() }
        refreshBridge()
        if nativeEnabled { pollNative() }
        guard startTimer else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ticks += 1
            // Events handle the fast path. Maintenance recovers missed events,
            // expires disconnected state, and checks command timeouts.
            if self.bridgeWatcher == nil { self.watchBridge() }
            if self.ticks % 4 == 0 || self.bridgeWatcher == nil { self.refreshBridge() }
            if self.ticks % 4 == 0, self.nativeEnabled { self.pollNative() }
        }
    }

    deinit {
        timer?.invalidate()
        bridgeWatcher?.cancel()
    }

    private func watchBridge() {
        guard bridgeWatcher == nil else { return }
        try? FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(bridge.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        // Watch the directory: atomic JSON writes replace the file's inode.
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke], queue: .main)
        watcher.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.bridgeWatcher?.data ?? []
            if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                self.bridgeWatcher?.cancel()
                self.bridgeWatcher = nil
            }
            self.refreshBridge()
        }
        watcher.setCancelHandler { close(descriptor) }
        bridgeWatcher = watcher
        watcher.resume()
    }

    func refreshBridge() {
        let files = (try? FileManager.default.contentsOfDirectory(at: bridge, includingPropertiesForKeys: nil)) ?? []
        var browserSources: [MediaSource] = []
        var microphones: [MicrophoneSource] = []
        var liveConnections: Set<String> = []
        var connections = 0
        var revisions: [String: Int] = [:]
        for file in files where file.lastPathComponent.hasPrefix("state-") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(BridgeSnapshot.self, from: data), abs(Date().timeIntervalSince1970 - state.updatedAt) < 15 else { continue }
            connections += 1
            let connection = String(file.deletingPathExtension().lastPathComponent.dropFirst(6))
            liveConnections.insert(connection)
            missingMicrophoneConnections.removeValue(forKey: connection)
            if let reported = state.microphones {
                microphones += reported.map { $0.row(connection: connection) }
            } else {
                microphones += microphoneSources.filter { $0.connection == connection }.map { $0.unavailable }
            }
            revisions[connection] = state.revision
            let grouped = BrowserSource.grouped(state.sources, preferred: preferredBrowserPlayers[connection] ?? [:])
            preferredBrowserPlayers[connection] = Dictionary(uniqueKeysWithValues: grouped.map { ($0.tabId, $0.id) })
            browserSources += grouped.map { $0.row(connection: connection) }
        }
        // A disconnected integration retains its discovered rows as unknown. An
        // authoritative connected snapshot removes closed/navigated call sources.
        microphones += microphoneSources.filter { source in
            guard let connection = source.connection, !liveConnections.contains(connection) else { return false }
            let missingSince = missingMicrophoneConnections[connection] ?? Date()
            missingMicrophoneConnections[connection] = missingSince
            // Host restarts allocate a fresh connection ID. Retain unavailable
            // rows briefly without ever merging identities across profiles.
            return Date().timeIntervalSince(missingSince) < 60
        }.map { $0.unavailable }
        let retainedConnections = Set(microphones.compactMap(\.connection))
        missingMicrophoneConnections = missingMicrophoneConnections.filter { retainedConnections.contains($0.key) }
        let running = discoverNativeMicrophones ? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) : []
        for (app, label) in [("com.hnc.Discord", "Discord"), ("us.zoom.xos", "Zoom"),
                             ("com.microsoft.teams2", "Microsoft Teams"), ("com.apple.FaceTime", "FaceTime"),
                             ("net.whatsapp.WhatsApp", "WhatsApp"), ("com.tinyspeck.slackmacgap", "Slack")] where running.contains(app) {
            microphones.append(MicrophoneSource(id: app, title: label, subtitle: "App running · mic status unavailable",
                state: .unknown, capability: "unavailable", controllable: false, nativeApp: app))
        }
        if browserCount != connections { browserCount = connections }
        let now = Date()
        var completedSourceIDs: Set<String> = []
        var completedMicrophoneIDs: Set<String> = []
        var completions: [() -> Void] = []
        for (id, control) in pending {
            let result = bridge.appendingPathComponent("result-\(id).json")
            if let data = try? Data(contentsOf: result), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let message = body["error"] as? String { error = message }
                else if control.microphone,
                        (revisions[control.connection] ?? -1) <= (body["revision"] as? Int ?? -1),
                        let value = body["source"], let data = try? JSONSerialization.data(withJSONObject: value),
                        let fresh = try? JSONDecoder().decode(BrowserMicrophone.self, from: data),
                        fresh.id == control.documentID,
                        let index = microphones.firstIndex(where: { $0.id == control.sourceID && $0.browser?.id == fresh.id }) {
                    microphones[index] = fresh.row(connection: control.connection)
                }
                else if !control.microphone, control.locksControls,
                        (revisions[control.connection] ?? -1) <= (body["revision"] as? Int ?? -1),
                        let value = body["source"], let data = try? JSONSerialization.data(withJSONObject: value),
                        let source = try? JSONDecoder().decode(BrowserSource.self, from: data) {
                    // ACK carries the authoritative post-command state. Apply it before unlocking.
                    let row = source.row(connection: control.connection)
                    if row.id == control.sourceID, let index = browserSources.firstIndex(where: { $0.id == row.id }) {
                        browserSources[index] = row
                    }
                }
                if control.microphone { completedMicrophoneIDs.insert(control.sourceID) }
                else if control.locksControls { completedSourceIDs.insert(control.sourceID) }
                let verifiedMicrophone = !control.microphone || microphones.contains { source in
                    source.id == control.sourceID && source.browser?.id == control.documentID &&
                    source.controllable && source.state == control.expectedMicrophoneState
                }
                let success = body["error"] == nil && body["ok"] as? Bool == true && verifiedMicrophone
                completions.append { control.completion?(success) }
                try? FileManager.default.removeItem(at: result)
                pending.removeValue(forKey: id)
            } else if now.timeIntervalSince(control.started) > 12 {
                if control.microphone { completedMicrophoneIDs.insert(control.sourceID) }
                else if control.locksControls { completedSourceIDs.insert(control.sourceID) }
                pending.removeValue(forKey: id)
                completions.append { control.completion?(false) }
                if control.microphone, let index = microphones.firstIndex(where: { $0.id == control.sourceID }) {
                    microphones[index] = microphones[index].unavailable
                }
                error = control.microphone ? "Microphone did not respond. Open the call and check its state." : "Player did not respond. Reconnect the browser companion or open the tab and try again."
            }
        }
        let refreshed = (browserSources + nativeSources).sorted { $0.id < $1.id }
        if sources != refreshed { sources = refreshed }
        let refreshedMicrophones = microphones.sorted { $0.id < $1.id }
        if microphoneSources != refreshedMicrophones { microphoneSources = refreshedMicrophones }
        busyMicrophoneIDs.subtract(completedMicrophoneIDs)
        if !completedSourceIDs.isEmpty { busySourceIDs.subtract(completedSourceIDs) }
        completions.forEach { $0() }
    }

    func command(_ source: MediaSource, action: String, value: Double? = nil, tabOnly: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard let source = sources.first(where: { $0.id == source.id }) else { completion?(false); return }
        guard action == "focus" || !busySourceIDs.contains(source.id) else { completion?(false); return }
        if let app = source.nativeApp {
            if action == "focus" {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else {
                    error = "This app is no longer available."; completion?(false); return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, failure in
                    DispatchQueue.main.async {
                        if let failure { self.error = failure.localizedDescription }
                        completion?(failure == nil)
                    }
                }
                return
            }
            let statement: String
            switch action {
            case "play": statement = "play"
            case "pause": statement = "pause"
            case "volume": statement = "set sound volume to \(Int(min(1, max(0, value ?? 0)) * 100))"
            case "mute":
                if value == 1 {
                    if let volume = source.volume, volume > 0 { nativeVolumesBeforeMute[app] = volume }
                    statement = "set sound volume to 0"
                } else {
                    let restore = nativeVolumesBeforeMute[app] ?? 0.5
                    statement = "set sound volume to \(Int(restore * 100))"
                }
            default: completion?(false); return
            }
            busySourceIDs.insert(source.id)
            nativeQueue.async {
                let result = Self.appleScript("tell application id \"\(app)\" to \(statement)")
                let refreshed = result.error == nil ? Self.readNativePlayer(app: app, label: app == "com.spotify.client" ? "Spotify" : "Music") : (source: nil, error: result.error)
                DispatchQueue.main.async {
                    if let message = refreshed.error { self.error = message }
                    if self.nativeEnabled, let fresh = refreshed.source {
                        self.nativeSources.removeAll { $0.id == fresh.id }
                        self.nativeSources.append(fresh)
                    }
                    self.refreshBridge()
                    self.busySourceIDs.remove(source.id)
                    completion?(refreshed.error == nil && refreshed.source != nil)
                }
            }
            return
        }
        guard let connection = source.connection, let browser = source.browserSource else { completion?(false); return }
        let id = UUID().uuidString
        var payload: [String: Any] = ["requestId": id, "id": browser.id, "tabId": browser.tabId, "frameId": browser.frameId, "action": action, "createdAt": Date().timeIntervalSince1970]
        if let value { payload["value"] = value }
        if tabOnly { payload["tabOnly"] = true }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: bridge.appendingPathComponent("command-\(connection)-\(id).json"), options: .atomic)
            pending[id] = PendingControl(sourceID: source.id, connection: connection, started: Date(), locksControls: action != "focus", completion: completion)
            if action != "focus" { busySourceIDs.insert(source.id) }
        } catch { self.error = "Browser bridge unavailable: \(error.localizedDescription)"; completion?(false) }
    }

    func microphoneCommand(_ requested: MicrophoneSource, focus: Bool = false, muted: Bool? = nil,
                           completion: ((Bool) -> Void)? = nil) {
        guard let source = microphoneSources.first(where: { $0.id == requested.id }),
              source.browser?.id == requested.browser?.id else { completion?(false); return }
        if let app = source.nativeApp, focus {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { completion?(false); return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async { completion?(error == nil) }
            }
            return
        }
        guard let connection = source.connection, let browser = source.browser,
              focus || (source.controllable && source.state != .unknown && !busyMicrophoneIDs.contains(source.id)) else {
            completion?(false); return
        }
        let desiredMuted = muted ?? (source.state == .enabled)
        let desiredState: MicrophoneState = desiredMuted ? .disabled : .enabled
        if !focus && source.state == desiredState { completion?(true); return }
        let id = UUID().uuidString
        let payload: [String: Any] = ["requestId": id, "id": browser.id, "tabId": browser.tabId,
            "frameId": browser.frameId, "action": focus ? "focus" : "microphone", "microphoneSource": true,
            "value": desiredMuted ? 1 : 0, "createdAt": Date().timeIntervalSince1970]
        do {
            try JSONSerialization.data(withJSONObject: payload).write(to: bridge.appendingPathComponent("command-\(connection)-\(id).json"), options: .atomic)
            pending[id] = PendingControl(sourceID: source.id, connection: connection, started: Date(),
                locksControls: false, completion: completion, microphone: !focus, documentID: browser.id,
                expectedMicrophoneState: focus ? nil : desiredState)
            if !focus { busyMicrophoneIDs.insert(source.id) }
        } catch {
            self.error = "Microphone bridge unavailable: \(error.localizedDescription)"
            completion?(false)
        }
    }

    private func pollNative() {
        guard !nativeBusy, nativeEnabled else { return }
        nativeBusy = true
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        nativeQueue.async {
            var players: [MediaSource] = []
            var failure: String?
            for (app, label) in [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")] where running.contains(app) {
                let result = Self.readNativePlayer(app: app, label: label)
                if let message = result.error { failure = message }
                if let player = result.source { players.append(player) }
            }
            let resultPlayers = players
            let resultFailure = failure
            DispatchQueue.main.async {
                self.nativeBusy = false
                guard self.nativeEnabled else { return }
                // A poll started before a command must not overwrite that command's pending row.
                self.nativeSources = resultPlayers.filter { !self.busySourceIDs.contains($0.id) }
                    + self.nativeSources.filter { self.busySourceIDs.contains($0.id) }
                if let resultFailure { self.error = resultFailure }
                self.refreshBridge()
            }
        }
    }

    private static func readNativePlayer(app: String, label: String) -> (source: MediaSource?, error: String?) {
        let script = """
        tell application id "\(app)"
            set trackTitle to "No track loaded"
            set trackArtist to ""
            try
                set trackTitle to name of current track
                set trackArtist to artist of current track
            end try
            set p to player state as text
            set v to sound volume as text
            return trackTitle & ASCII character 31 & trackArtist & ASCII character 31 & p & ASCII character 31 & v
        end tell
        """
        let result = appleScript(script)
        if let message = result.error { return (nil, "\(label): \(message)") }
        let parts = result.output.trimmingCharacters(in: .newlines).components(separatedBy: String(UnicodeScalar(31)))
        guard parts.count == 4 else { return (nil, "Could not read \(label) playback state.") }
        return (MediaSource(id: app, title: parts[0], subtitle: parts[1].isEmpty ? label : "\(parts[1]) · \(label)", playing: parts[2] == "playing", ready: parts[2] == "stopped", volume: Double(parts[3]).map { $0 / 100 }, muted: Double(parts[3]).map { $0 == 0 }, displayName: label, nativeApp: app), nil)
    }

    private static func appleScript(_ script: String) -> (output: String, error: String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        task.standardOutput = out; task.standardError = err
        do {
            try task.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (String(decoding: data, as: UTF8.self), task.terminationStatus == 0 ? nil : String(decoding: errors, as: UTF8.self))
        } catch { return ("", error.localizedDescription) }
    }

    func openGuide() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/README.md")
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("README.md")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: bundled.path) ? bundled : local)
    }
}
