import Foundation

private final class MicrophoneGroupFixture {
    let directory: URL
    let model: MediaModel
    let group: MicrophoneMuteController

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = MediaModel(bridgeURL: directory, startTimer: false, nativePlayersEnabled: false, discoverNativeMicrophones: false)
        group = MicrophoneMuteController(model: model, startTimer: false)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func mic(_ tab: Int = 10, state: MicrophoneState = .enabled, document: String = "doc") -> BrowserMicrophone {
        BrowserMicrophone(id: "tab:\(tab):\(document)", tabId: tab, frameId: 0, title: "Google Meet", subtitle: "Call",
            capability: state == .unknown ? "unavailable" : "app-control", state: state, controllable: state != .unknown)
    }
    func snapshot(_ microphones: [BrowserMicrophone], profile: String = "alpha", revision: Int = 1) throws {
        let microphones = try JSONSerialization.jsonObject(with: JSONEncoder().encode(microphones))
        let body: [String: Any] = ["updatedAt": Date().timeIntervalSince1970, "revision": revision, "microphones": microphones,
            "sources": [["id": "tab:10:doc", "tabId": 10, "frameId": 0, "title": "Sound", "site": "example.test",
                         "playing": true, "ready": false, "muted": false, "volume": 1]]]
        try JSONSerialization.data(withJSONObject: body).write(to: directory.appendingPathComponent("state-\(profile).json"), options: .atomic)
    }
    func commands(value: Int? = nil) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("command-") }
            .map { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as! [String: Any] }
            .filter { value == nil || $0["value"] as? Int == value }
    }
    func acknowledge(_ command: [String: Any], state: MicrophoneState, revision: Int, error: String? = nil) throws {
        let source = mic(command["tabId"] as! Int, state: state)
        var body: [String: Any] = ["ok": true, "revision": revision,
            "source": try JSONSerialization.jsonObject(with: JSONEncoder().encode(source))]
        if let error { body["error"] = error }
        try JSONSerialization.data(withJSONObject: body).write(to: directory.appendingPathComponent("result-\(command["requestId"] as! String).json"), options: .atomic)
    }
}

func runMicrophoneMuteTests() throws -> Int {
    do {
        let f = try MicrophoneGroupFixture()
        try f.snapshot([f.mic(), f.mic(11, state: .disabled), f.mic(12, state: .unknown)])
        try f.snapshot([f.mic()], profile: "beta")
        f.model.refreshBridge()
        f.group.toggle()
        f.group.toggle()
        let mutes = try f.commands(value: 1)
        precondition(mutes.count == 2 && f.group.isBusy && f.model.busySourceIDs.isEmpty)
        precondition(mutes.allSatisfy { $0["tabId"] as? Int == 10 && $0["action"] as? String == "microphone" })
        try f.snapshot([f.mic(state: .disabled), f.mic(11, state: .disabled), f.mic(12, state: .unknown)], revision: 2)
        try f.snapshot([f.mic(state: .disabled)], profile: "beta", revision: 2)
        for command in mutes { try f.acknowledge(command, state: .disabled, revision: 2) }
        f.model.refreshBridge()
        precondition(f.group.isMuted && !f.group.isBusy)
        f.group.toggle()
        let restores = try f.commands(value: 0)
        precondition(restores.count == 2 && restores.allSatisfy { $0["tabId"] as? Int == 10 })
        try f.snapshot([f.mic(), f.mic(11, state: .disabled), f.mic(12, state: .unknown)], revision: 3)
        try f.snapshot([f.mic()], profile: "beta", revision: 3)
        for command in restores { try f.acknowledge(command, state: .enabled, revision: 3) }
        f.model.refreshBridge()
        precondition(!f.group.isMuted && !f.group.isBusy)
        precondition(f.model.microphoneSources.first { $0.browser?.tabId == 11 }?.state == .disabled)
        precondition(f.model.sources.allSatisfy { $0.playing && $0.muted == false })
        print("PASS: group mic mute preserves pre-existing/unknown mics, profiles, and sound controls")
    }
    do {
        let f = try MicrophoneGroupFixture()
        try f.snapshot([f.mic()])
        f.model.refreshBridge()
        f.group.toggle()
        try f.snapshot([f.mic(state: .disabled)], revision: 2)
        try f.acknowledge(try f.commands(value: 1)[0], state: .disabled, revision: 2, error: "Mute acknowledgement failed")
        f.model.refreshBridge()
        precondition(f.group.isMuted && !f.group.isBusy && f.model.error != nil)
        f.group.toggle()
        let failedRestore = try f.commands(value: 0)[0]
        try f.acknowledge(failedRestore, state: .disabled, revision: 2, error: "Restore failed")
        f.model.refreshBridge()
        precondition(f.group.isMuted && !f.group.isBusy)
        f.group.toggle()
        let retry = try f.commands(value: 0).first { $0["requestId"] as? String != failedRestore["requestId"] as? String }!
        try f.snapshot([f.mic()], revision: 3)
        try f.acknowledge(retry, state: .enabled, revision: 3)
        f.model.refreshBridge()
        precondition(!f.group.isMuted && !f.group.isBusy)
        print("PASS: failed group commands retain explicit restore ownership and allow retry")
    }
    do {
        let f = try MicrophoneGroupFixture()
        try f.snapshot([f.mic()])
        f.model.refreshBridge()
        f.group.toggle()
        try f.snapshot([f.mic(state: .disabled)], revision: 2)
        try f.acknowledge(try f.commands(value: 1)[0], state: .disabled, revision: 2)
        f.model.refreshBridge()
        try f.snapshot([f.mic(document: "replacement")], revision: 3)
        f.model.refreshBridge()
        f.group.toggle()
        let commandsAfterNavigation = try f.commands(value: 0)
        precondition(!f.group.isMuted && commandsAfterNavigation.isEmpty)
        precondition(f.model.microphoneSources[0].state == .enabled)
        print("PASS: group restore cannot enable a replacement document")
    }
    do {
        let f = try MicrophoneGroupFixture()
        try f.snapshot([f.mic()])
        f.model.refreshBridge()
        f.group.toggle()
        try f.snapshot([f.mic(state: .disabled)], revision: 2)
        try f.acknowledge(try f.commands(value: 1)[0], state: .disabled, revision: 2)
        f.model.refreshBridge()
        try f.snapshot([f.mic(state: .disabled), f.mic(20), f.mic(21, state: .unknown)], revision: 3)
        f.model.refreshBridge()
        f.group.refresh()
        f.group.refresh()
        let newCommands = try f.commands(value: 1).filter { $0["tabId"] as? Int == 20 }
        precondition(newCommands.count == 1 && f.group.isBusy)
        let allCommands = try f.commands()
        precondition(allCommands.allSatisfy { $0["tabId"] as? Int != 21 })
        print("PASS: active group mute includes new supported mics once and skips unknown sources")
    }
    do {
        let f = try MicrophoneGroupFixture()
        try f.snapshot([f.mic()])
        f.model.refreshBridge()
        f.group.toggle()
        try f.acknowledge(try f.commands(value: 1)[0], state: .enabled, revision: 2)
        f.model.refreshBridge()
        precondition(f.group.isMuted && !f.group.isBusy && f.model.error != nil)
        // Restore is an explicit desired state, not a blind toggle: a microphone
        // already enabled needs no new command and must not be muted by accident.
        f.group.toggle()
        let restores = try f.commands(value: 0)
        precondition(!f.group.isMuted && restores.isEmpty)
        precondition(f.model.microphoneSources[0].state == .enabled)
        print("PASS: unverified mic acknowledgements fail and restoring an enabled mic never toggles it")
    }
    return 5
}
