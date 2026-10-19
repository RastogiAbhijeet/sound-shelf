import Foundation
import Combine

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
private func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}
private func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value, "Expected false", file: file, line: line)
}
private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "MediaModelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required value"]) }
    return value
}

final class MediaModelTests {
    private var directory: URL!

    func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func player(_ id: String = "tab:10:doc", tab: Int = 10, playing: Bool = false) -> BrowserSource {
        BrowserSource(id: id, tabId: tab, frameId: 0, title: "Same title", site: "youtube.com",
            playing: playing, ready: false, volume: 1, muted: false)
    }
    private func writeState(_ sources: [BrowserSource], connection: String = "connection", revision: Int = 1) throws {
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sources))
        try write(["sources": values, "updatedAt": Date().timeIntervalSince1970, "revision": revision], name: "state-\(connection).json")
    }
    private func write(_ body: [String: Any], name: String) throws {
        try JSONSerialization.data(withJSONObject: body).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private func commands() throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("command-") }
            .map { try require(JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any]) }
    }
    private func model() -> MediaModel { MediaModel(bridgeURL: directory, startTimer: false, nativePlayersEnabled: false, discoverNativeMicrophones: false) }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 0.75) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        expectTrue(condition())
    }

    func testFileEventsUpdateRowsAndAcknowledgeBeforeTheFallbackPoll() throws {
        try writeState([player()])
        let state = MediaModel(bridgeURL: directory, nativePlayersEnabled: false)
        try writeState([player(playing: true)], revision: 2)
        waitUntil { state.sources.first?.playing == true }
        var playingAtCompletion: Bool?
        state.command(try require(state.sources.first), action: "pause") { _ in
            playingAtCompletion = state.sources.first?.playing
        }
        let id = try require(commands().first?["requestId"] as? String)
        let source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(player()))
        try writeState([player()], revision: 3)
        try write(["ok": true, "source": source, "revision": 3], name: "result-\(id).json")
        waitUntil { state.busySourceIDs.isEmpty }
        expectEqual(playingAtCompletion, false)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("state-connection.json"))
        waitUntil { state.sources.isEmpty && state.browserCount == 0 }
    }

    func testUnchangedSnapshotsDoNotRepublishRows() throws {
        try writeState([player()])
        let state = model()
        var publications = 0
        let observation = state.$sources.sink { _ in publications += 1 }
        defer { observation.cancel() }
        try writeState([player()], revision: 2)
        state.refreshBridge()
        expectEqual(publications, 1)
        try writeState([player(playing: true)], revision: 3)
        state.refreshBridge()
        expectEqual(publications, 2)
    }

    func testFileWatcherRecoversAfterBridgeDirectoryReplacement() throws {
        try writeState([player()])
        let state = MediaModel(bridgeURL: directory, nativePlayersEnabled: false)
        let moved = directory.appendingPathExtension("old")
        try FileManager.default.moveItem(at: directory, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeState([player(playing: true)], revision: 2)
        waitUntil { state.sources.first?.playing == true }
        let rearm = Date().addingTimeInterval(1.2)
        waitUntil({ Date() >= rearm }, timeout: 2)
        try writeState([player()], revision: 3)
        waitUntil { state.sources.first?.playing == false }
    }

    func testLegacyElementsCollapseByTabWithoutMergingOtherProfiles() throws {
        try writeState([player("hidden"), player("main", playing: true), player("other", tab: 11)])
        try writeState([player("profile-two")], connection: "other-profile")
        let state = model()
        expectEqual(state.sources.count, 3)
        let primary = try require(state.sources.first { $0.id == "connection:tab:10" })
        expectTrue(primary.playing)
        expectEqual(primary.browserSource?.id, "main")
        try writeState([player("hidden"), player("main"), player("other", tab: 11)])
        state.refreshBridge()
        expectEqual(state.sources.first { $0.id == primary.id }?.browserSource?.id, "main")
    }

    func testVolumeTargetsOnlyRequestedProfileAndUsesAcknowledgedState() throws {
        try writeState([player(), player("other-tab", tab: 11)])
        try writeState([player()], connection: "second-profile")
        let state = model()
        let row = try require(state.sources.first { $0.id == "connection:tab:10" })
        var completed: Bool?
        state.setVolume(row, value: 0.27) { completed = $0 }
        let command = try require(commands().first)
        expectEqual(try commands().count, 1)
        expectEqual(command["action"] as? String, "volume")
        expectEqual(command["value"] as? Double, 0.27)
        expectEqual(command["tabId"] as? Int, 10)
        expectEqual(command["id"] as? String, row.browserSource?.id)
        expectEqual(state.busySourceIDs, [row.id])
        expectEqual(row.volume, 1)
        let fresh = BrowserSource(id: "tab:10:doc", tabId: 10, frameId: 0, title: "Same title",
            site: "youtube.com", playing: false, ready: false, volume: 0.27, muted: false)
        let source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh))
        let request = try require(command["requestId"] as? String)
        try write(["ok": true, "source": source, "revision": 2], name: "result-\(request).json")
        state.refreshBridge()
        expectEqual(completed, true)
        expectEqual(state.sources.first { $0.id == row.id }?.volume, 0.27)
        expectTrue(state.sources.filter { $0.id != row.id }.allSatisfy { $0.volume == 1 })
        expectTrue(state.busySourceIDs.isEmpty)
    }

    func testVolumeRejectsCallsInvalidValuesAndReplacementPlayers() throws {
        let call = BrowserSource(id: "call", tabId: 11, frameId: 0, title: "Meet", site: "meet.google.com",
            playing: true, ready: false, volume: 1, muted: false, supportsPlayback: false)
        try writeState([player(), call])
        let state = model()
        let row = try require(state.sources.first { $0.browserSource?.tabId == 10 })
        let callRow = try require(state.sources.first { $0.browserSource?.tabId == 11 })
        expectFalse(callRow.supportsVolume)
        state.setVolume(callRow, value: 0.5)
        state.setVolume(row, value: .nan)
        state.setVolume(row, value: .infinity)
        expectEqual(try commands().count, 0)
        try writeState([player("replacement"), call], revision: 2)
        state.refreshBridge()
        state.setVolume(row, value: 0.5)
        expectEqual(try commands().count, 0)
        let replacement = try require(state.sources.first { $0.browserSource?.tabId == 10 })
        state.setVolume(replacement, value: 2)
        expectEqual(try commands().first?["value"] as? Double, 1)
    }

    func testRapidClicksAreBlockedUntilFreshAcknowledgement() throws {
        try writeState([player()])
        let state = model()
        let row = try require(state.sources.first)
        state.command(row, action: "play")
        state.command(row, action: "play")
        state.command(row, action: "mute", value: 1)
        let commands = try commands()
        expectEqual(commands.count, 1)
        expectTrue(state.busySourceIDs.contains(row.id))
        let id = try require(commands.first?["requestId"] as? String)
        let source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(player(playing: true)))
        try write(["ok": true, "source": source, "revision": 2], name: "result-\(id).json")
        var stateAtUnlock: Bool?
        let observation = state.$busySourceIDs.sink { busy in
            if busy.isEmpty { stateAtUnlock = state.sources.first?.playing }
        }
        defer { observation.cancel() }
        state.refreshBridge()
        expectEqual(stateAtUnlock, true)
        expectTrue(try require(state.sources.first).playing)
        expectFalse(state.busySourceIDs.contains(row.id))
        state.command(try require(state.sources.first), action: "pause")
        expectEqual(try self.commands().count, 2)
    }

    func testFocusAcknowledgementDoesNotUnlockPendingPlayback() throws {
        try writeState([player()])
        let state = model()
        let row = try require(state.sources.first)
        state.command(row, action: "play")
        state.command(row, action: "focus")
        let id = try require(commands().first { $0["action"] as? String == "focus" }?["requestId"] as? String)
        try write(["ok": true], name: "result-\(id).json")
        state.refreshBridge()
        expectTrue(state.busySourceIDs.contains(row.id))
    }

    func testLateAcknowledgementCannotOverwriteANewerSnapshot() throws {
        try writeState([player()])
        let state = model()
        let row = try require(state.sources.first)
        state.command(row, action: "play")
        let id = try require(commands().first?["requestId"] as? String)
        try writeState([player(playing: false)], revision: 3)
        let source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(player(playing: true)))
        try write(["ok": true, "source": source, "revision": 2], name: "result-\(id).json")
        state.refreshBridge()
        expectFalse(try require(state.sources.first).playing)
        expectFalse(state.busySourceIDs.contains(row.id))
    }

    func testFocusResultCannotChangePlaybackState() throws {
        try writeState([player()])
        let state = model()
        let row = try require(state.sources.first)
        state.command(row, action: "focus")
        let id = try require(commands().first?["requestId"] as? String)
        let source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(player(playing: true)))
        try write(["ok": true, "source": source, "revision": 2], name: "result-\(id).json")
        state.refreshBridge()
        expectFalse(try require(state.sources.first).playing)
    }

    func testFailedCommandReleasesControlsAndShowsError() throws {
        try writeState([player()])
        let state = model()
        let row = try require(state.sources.first)
        state.command(row, action: "play")
        let id = try require(commands().first?["requestId"] as? String)
        try write(["error": "Autoplay blocked"], name: "result-\(id).json")
        state.refreshBridge()
        expectTrue(state.busySourceIDs.isEmpty)
        expectEqual(state.error, "Autoplay blocked")
        expectFalse(try require(state.sources.first).playing)
    }
    func testShelfMuteRestoresOnlyOwnedMutesAndWaitsForAcknowledgement() throws {
        let active = player()
        let silent = BrowserSource(id: "tab:11:doc", tabId: 11, frameId: 0, title: "Already muted", site: "test", playing: false, ready: true, volume: 1, muted: true)
        try writeState([active, silent])
        let state = model()
        let master = ShelfMuteController(model: state, startTimer: false)
        master.toggle()
        expectTrue(master.isMuted && master.isBusy)
        master.toggle() // A second click must not race the first command.
        expectEqual(try commands().count, 1)
        let command = try require(commands().first)
        expectEqual(command["tabId"] as? Int, 10)
        expectEqual(command["value"] as? Double, 1)
        expectEqual(command["tabOnly"] as? Bool, true)
        let id = try require(command["requestId"] as? String)
        try write(["ok": true], name: "result-\(id).json")
        state.refreshBridge()
        expectFalse(master.isBusy)
        master.toggle()
        expectTrue(master.isBusy)
        let unmute = try require(commands().first { $0["value"] as? Double == 0 })
        expectEqual(unmute["tabId"] as? Int, 10)
        let unmuteID = try require(unmute["requestId"] as? String)
        try write(["error": "Disconnected"], name: "result-\(unmuteID).json")
        state.refreshBridge()
        expectTrue(master.isMuted) // Keep restore available after failure.
        master.toggle()
        let retry = try require(commands().last { $0["value"] as? Double == 0 && $0["requestId"] as? String != unmuteID })
        let retryID = try require(retry["requestId"] as? String)
        try write(["ok": true], name: "result-\(retryID).json")
        state.refreshBridge()
        expectFalse(master.isMuted || master.isBusy)
    }

    func testDisabledNativeIntegrationPreservesOwnedMuteAndBlocksRestart() throws {
        let state = model()
        let oldPreference = UserDefaults.standard.object(forKey: "nativePlayers")
        defer {
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: "nativePlayers") }
            else { UserDefaults.standard.removeObject(forKey: "nativePlayers") }
        }
        let source = MediaSource(id: "native:spotify", title: "Spotify", subtitle: "", playing: true,
                                 ready: false, volume: 0.7, muted: false, nativeApp: "com.spotify.client")
        state.sources = [source]
        var volume = 0.7
        var pendingMute: ((Bool) -> Void)?
        let master = ShelfMuteController(model: state, startTimer: false, setMuted: { _, muted, completion in
            if muted { volume = 0; pendingMute = completion }
            else { volume = 0.7; completion(true) }
        })
        master.toggle()
        expectTrue(master.isBusy)
        // Disable while the mute acknowledgement is still pending.
        state.nativeEnabled = false
        expectTrue(state.sources.isEmpty)
        pendingMute?(true)
        master.toggle()
        expectTrue(master.isMuted && !master.isBusy)
        expectEqual(volume, 0)
        expectTrue(state.error?.contains("Reconnect Spotify & Music") == true)
        let restart = AppRestartController(launch: { _ in preconditionFailure("Must not launch with unrestored audio") },
                                           terminate: { preconditionFailure("Must not terminate with unrestored audio") })
        restart.restart(model: state, shelfMute: master, macMute: MacMuteController(startTimer: false))
        expectFalse(restart.isRestarting)
        expectTrue(master.isMuted)
        // Simulate the native row returning without launching or querying a real player.
        state.sources = [source]
        master.toggle()
        expectFalse(master.isMuted || master.isBusy)
        expectEqual(volume, 0.7)
    }

    func testShelfMuteDoesNotUnmuteANavigatedTab() throws {
        try writeState([player()])
        let state = model()
        let master = ShelfMuteController(model: state, startTimer: false)
        master.toggle()
        let id = try require(commands().first?["requestId"] as? String)
        try write(["ok": true], name: "result-\(id).json")
        state.refreshBridge()
        try writeState([player("tab:10:replacement")], revision: 2)
        state.refreshBridge()
        master.toggle()
        expectFalse(master.isMuted)
        expectEqual(try commands().count, 1)
    }

    func testMalformedOptionalMicrophonesCannotBreakSoundDiscovery() throws {
        let sources = try JSONSerialization.jsonObject(with: JSONEncoder().encode([player()]))
        try write(["updatedAt": Date().timeIntervalSince1970, "sources": sources,
                   "microphones": [["state": "future-state"]]], name: "state-connection.json")
        let state = model()
        expectEqual(state.sources.count, 1)
        expectTrue(state.microphoneSources.isEmpty)
    }

    func testBrowserNamesAreFriendlyForNewSitesAndTrackCurrentTabTitles() throws {
        for (host, expected) in [("www.amazon.in", "Amazon"), ("www.dellstore.com", "Dell Store"),
                                 ("www.youtube.com", "YouTube"), ("www.fresh-shop.co.uk", "Fresh Shop")] {
            let source = BrowserSource(id: "tab:10:doc", tabId: 10, frameId: 0,
                title: "Old player label", site: host, playing: false, ready: true, volume: 1, muted: false)
            expectEqual(source.row(connection: "profile").displayName, expected)
        }
        var source = BrowserSource(id: "tab:10:doc", tabId: 10, frameId: 0,
            title: "Old player label", site: "fresh-shop.example", playing: false, ready: true, volume: 1, muted: false)
        source.siteName = "  Fresh   Shop  "
        source.tabTitle = "Current product title"
        expectEqual(source.row(connection: "profile").displayName, "Fresh Shop")
        expectEqual(source.row(connection: "profile").title, "Current product title")
        try writeState([source])
        let state = model()
        let id = try require(state.sources.first).id
        source.tabTitle = "New product title"
        try writeState([source], revision: 2)
        state.refreshBridge()
        expectEqual(state.sources.first?.id, id)
        expectEqual(state.sources.first?.title, "New product title")
        expectFalse(try require(state.sources.first).playing)
    }

    private func microphone(_ document: String = "tab:10:doc", state: MicrophoneState = .enabled,
                            controllable: Bool = true) -> BrowserMicrophone {
        BrowserMicrophone(id: document, tabId: 10, frameId: 0, title: "Google Meet", subtitle: "Call",
            capability: controllable ? "app-control" : "unavailable", state: state, controllable: controllable)
    }
    private func writeMicrophones(_ microphones: [BrowserMicrophone], connection: String = "connection", revision: Int = 1) throws {
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(microphones))
        try write(["sources": [], "microphones": values, "updatedAt": Date().timeIntervalSince1970,
                   "revision": revision], name: "state-\(connection).json")
    }
    func testMicrophonesAreIndependentAndProfilesStaySeparate() throws {
        try writeMicrophones([microphone()])
        try writeMicrophones([microphone(state: .disabled)], connection: "second-profile")
        let state = model()
        expectTrue(state.sources.isEmpty)
        expectEqual(state.microphoneSources.count, 2)
        let row = try require(state.microphoneSources.first)
        state.microphoneCommand(row)
        state.microphoneCommand(row)
        expectEqual(try commands().count, 1)
        expectTrue(state.busySourceIDs.isEmpty)
        expectTrue(state.busyMicrophoneIDs.contains(row.id))
        let command = try require(commands().first)
        expectEqual(command["action"] as? String, "microphone")
        expectEqual(command["value"] as? Int, 1)
        let request = try require(command["requestId"] as? String)
        let fresh = try JSONSerialization.jsonObject(with: JSONEncoder().encode(microphone(state: .disabled)))
        try write(["ok": true, "source": fresh, "revision": 2], name: "result-\(request).json")
        state.refreshBridge()
        expectEqual(state.microphoneSources.first?.state, .disabled)
        expectTrue(state.busyMicrophoneIDs.isEmpty)
        expectTrue(state.sources.isEmpty)
    }
    func testUnknownMicAndDisconnectedIntegrationsStayGrey() throws {
        try writeMicrophones([microphone(state: .unknown)])
        let state = model()
        let row = try require(state.microphoneSources.first)
        expectFalse(row.controllable)
        state.microphoneCommand(row)
        expectTrue(try commands().isEmpty)
        try writeMicrophones([microphone()], revision: 2)
        state.refreshBridge()
        expectTrue(try require(state.microphoneSources.first).controllable)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("state-connection.json"))
        state.refreshBridge()
        expectEqual(state.microphoneSources.first?.state, .unknown)
        expectFalse(try require(state.microphoneSources.first).controllable)
        try writeMicrophones([], revision: 3)
        state.refreshBridge()
        expectTrue(state.microphoneSources.isEmpty)
    }
    func testMicFocusDoesNotUnlockPendingControlOrChangeState() throws {
        try writeMicrophones([microphone()])
        let state = model()
        let row = try require(state.microphoneSources.first)
        state.microphoneCommand(row)
        state.microphoneCommand(row, focus: true)
        let focus = try require(commands().first { $0["action"] as? String == "focus" })
        let request = try require(focus["requestId"] as? String)
        try write(["ok": true], name: "result-\(request).json")
        state.refreshBridge()
        expectTrue(state.busyMicrophoneIDs.contains(row.id))
        expectEqual(state.microphoneSources.first?.state, .enabled)
    }
    func testLateMicAcknowledgementCannotChangeReplacementDocument() throws {
        try writeMicrophones([microphone()])
        let state = model()
        let row = try require(state.microphoneSources.first)
        state.microphoneCommand(row)
        let request = try require(commands().first?["requestId"] as? String)
        try writeMicrophones([microphone("tab:10:replacement")], revision: 3)
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(microphone(state: .disabled)))
        try write(["ok": true, "source": old, "revision": 4], name: "result-\(request).json")
        state.refreshBridge()
        expectEqual(state.microphoneSources.first?.state, .enabled)
        expectEqual(state.microphoneSources.first?.browser?.id, "tab:10:replacement")
        expectTrue(state.busyMicrophoneIDs.isEmpty)
        state.microphoneCommand(row)
        expectEqual(try commands().count, 1)
    }
    func testMicrophoneFailureReleasesOnlyItsOwnControls() throws {
        try writeMicrophones([microphone()])
        let state = model()
        state.microphoneCommand(try require(state.microphoneSources.first))
        let request = try require(commands().first?["requestId"] as? String)
        try writeMicrophones([microphone(state: .disabled)], revision: 2)
        try write(["error": "Call rejected change"], name: "result-\(request).json")
        state.refreshBridge()
        expectTrue(state.busyMicrophoneIDs.isEmpty)
        expectEqual(state.error, "Call rejected change")
        expectEqual(state.microphoneSources.first?.state, .disabled)
    }

}

@main
struct RegressionRunner {
    static func main() throws {
        let tests: [(String, (MediaModelTests) throws -> Void)] = [
            ("volume is isolated by tab and profile and waits for acknowledged state", { try $0.testVolumeTargetsOnlyRequestedProfileAndUsesAcknowledgedState() }),
            ("volume rejects calls, invalid values, and replacement players", { try $0.testVolumeRejectsCallsInvalidValuesAndReplacementPlayers() }),
            ("new sites get friendly names and tab titles update without changing identity", { try $0.testBrowserNamesAreFriendlyForNewSitesAndTrackCurrentTabTitles() }),
            ("incompatible optional mic payload preserves sound", { try $0.testMalformedOptionalMicrophonesCannotBreakSoundDiscovery() }),
            ("mic-only rows, profiles, pending commands and acknowledgements", { try $0.testMicrophonesAreIndependentAndProfilesStaySeparate() }),
            ("unknown and disconnected microphones remain grey", { try $0.testUnknownMicAndDisconnectedIntegrationsStayGrey() }),
            ("mic focus leaves pending controls and state unchanged", { try $0.testMicFocusDoesNotUnlockPendingControlOrChangeState() }),
            ("late mic acknowledgements cannot change replacement documents", { try $0.testLateMicAcknowledgementCannotChangeReplacementDocument() }),
            ("mic failures refresh actual state and release controls", { try $0.testMicrophoneFailureReleasesOnlyItsOwnControls() }),
            ("file events update rows and acknowledgements before fallback polling", { try $0.testFileEventsUpdateRowsAndAcknowledgeBeforeTheFallbackPoll() }),
            ("unchanged snapshots do not redraw rows", { try $0.testUnchangedSnapshotsDoNotRepublishRows() }),
            ("file watcher recovers after directory replacement", { try $0.testFileWatcherRecoversAfterBridgeDirectoryReplacement() }),
            ("legacy duplicates, tab identity, and Chrome profiles", { try $0.testLegacyElementsCollapseByTabWithoutMergingOtherProfiles() }),
            ("rapid clicks and authoritative command state", { try $0.testRapidClicksAreBlockedUntilFreshAcknowledgement() }),
            ("focus cannot unlock a pending playback command", { try $0.testFocusAcknowledgementDoesNotUnlockPendingPlayback() }),
            ("late acknowledgements cannot overwrite newer state", { try $0.testLateAcknowledgementCannotOverwriteANewerSnapshot() }),
            ("focus results cannot change playback", { try $0.testFocusResultCannotChangePlaybackState() }),
            ("failed commands release controls and report errors", { try $0.testFailedCommandReleasesControlsAndShowsError() }),
            ("Shelf master mute ownership, acknowledgements, and retry", { try $0.testShelfMuteRestoresOnlyOwnedMutesAndWaitsForAcknowledgement() }),
            ("disabled native integration retains owned mute and blocks restart", { try $0.testDisabledNativeIntegrationPreservesOwnedMuteAndBlocksRestart() }),
            ("Shelf mute cannot unmute a replacement page", { try $0.testShelfMuteDoesNotUnmuteANavigatedTab() })
        ]
        for (name, run) in tests {
            let test = MediaModelTests()
            try test.setUpWithError()
            defer { try? test.tearDownWithError() }
            try run(test)
            print("PASS: \(name)")
        }
        runMuteTests()
        let restartTests = try runAppRestartTests()
        let microphoneTests = try runMicrophoneMuteTests()
        print("\(tests.count + 6 + restartTests + microphoneTests) native regression tests passed.")
    }
}
