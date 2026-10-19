import Foundation
import CoreAudio

private final class RestartMuteHardware: MacMuteHardware {
    let control = MacMuteProperty(device: 1, uid: "restart-test", selector: kAudioDevicePropertyVolumeScalar, element: 0, name: "Test")
    var volume: Float32 = 0.6
    func controls(strict: Bool) throws -> [MacMuteProperty] { [control] }
    func value(_ control: MacMuteProperty) throws -> Float32 { volume }
    func set(_ control: MacMuteProperty, value: Float32) throws { volume = value }
}

func runAppRestartTests() throws -> Int {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = MediaModel(bridgeURL: directory, startTimer: false, nativePlayersEnabled: false, discoverNativeMicrophones: false)
    let shelf = ShelfMuteController(model: model, startTimer: false)
    let hardware = RestartMuteHardware()
    let mac = MacMuteController(hardware: hardware, startTimer: false)
    do {
        var launches = 0, terminations = 0
        var reply: ((Error?) -> Void)?
        let restart = AppRestartController(launch: { launches += 1; reply = $0 }, terminate: { terminations += 1 })
        restart.restart(model: model, shelfMute: shelf, macMute: mac)
        restart.restart(model: model, shelfMute: shelf, macMute: mac)
        precondition(launches == 1 && terminations == 0 && restart.isRestarting)
        reply?(nil)
        precondition(terminations == 1)
        print("PASS: restart launches once and terminates only after replacement confirmation")
    }
    do {
        var terminations = 0
        let restart = AppRestartController(launch: { $0(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Launch failed"])) },
                                           terminate: { terminations += 1 })
        restart.restart(model: model, shelfMute: shelf, macMute: mac)
        precondition(terminations == 0 && !restart.isRestarting && model.error?.contains("Launch failed") == true)
        print("PASS: failed restart keeps the original app running and exposes the error")
    }
    do {
        mac.toggle()
        precondition(mac.isMuted && hardware.volume == 0)
        var launches = 0
        let restart = AppRestartController(launch: { reply in
            precondition(!mac.isMuted && hardware.volume == 0.6)
            launches += 1
            reply(nil)
        }, terminate: {})
        restart.restart(model: model, shelfMute: shelf, macMute: mac)
        precondition(launches == 1)
        print("PASS: restart restores session-owned Mac output volume before launching")
    }
    do {
        func write(_ value: [String: Any], name: String) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        func snapshot(muted: Bool, revision: Int) throws {
            try write(["updatedAt": Date().timeIntervalSince1970, "revision": revision,
                "sources": [["id": "tab:1:document", "tabId": 1, "frameId": 0, "title": "Player", "site": "test.example",
                             "playing": false, "ready": false, "volume": 1, "muted": muted]]], name: "state-test.json")
        }
        func acknowledge(value: Int) throws {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix("command-") {
                let command = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                if command["value"] as? Int == value {
                    try write(["ok": true], name: "result-\(command["requestId"] as! String).json")
                }
            }
        }
        try snapshot(muted: false, revision: 1)
        model.refreshBridge()
        shelf.toggle()
        try snapshot(muted: true, revision: 2)
        try acknowledge(value: 1)
        model.refreshBridge()
        precondition(shelf.isMuted && !shelf.isBusy)
        var launches = 0
        let restart = AppRestartController(launch: { reply in
            precondition(!shelf.isMuted && !shelf.isBusy)
            launches += 1
            reply(nil)
        }, terminate: {})
        restart.restart(model: model, shelfMute: shelf, macMute: mac)
        precondition(launches == 0 && shelf.isBusy)
        try snapshot(muted: false, revision: 3)
        try acknowledge(value: 0)
        model.refreshBridge()
        let deadline = Date().addingTimeInterval(1)
        while launches == 0 && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        precondition(launches == 1)
        print("PASS: restart waits for authoritative SoundShelf unmute acknowledgements")
    }
    return 4
}
