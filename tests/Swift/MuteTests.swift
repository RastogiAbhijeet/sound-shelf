import Foundation
import CoreAudio

private final class FakeMuteHardware: MacMuteHardware {
    var values: [MacMuteProperty: Float32] = [:]
    var failWrite: MacMuteProperty?
    var unsupported = false
    func controls(strict: Bool) throws -> [MacMuteProperty] {
        if strict && unsupported { throw NSError(domain: "test", code: 1) }
        return values.keys.sorted { $0.element < $1.element }
    }
    func value(_ control: MacMuteProperty) throws -> Float32 { values[control]! }
    func set(_ control: MacMuteProperty, value: Float32) throws {
        if failWrite == control { throw NSError(domain: "test", code: 2) }
        values[control] = value
    }
}

func runMuteTests() {
    do {
        var failing = true
        let audio = AudioController(enumerateOutputs: {
            if failing { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enumeration failed"]) }
            return []
        })
        let hardware = CoreAudioMuteHardware(audio: audio)
        do {
            _ = try hardware.controls(strict: false)
            preconditionFailure("Expected enumeration failure")
        } catch { precondition(audio.error == "Enumeration failed") }
        failing = false
        do {
            let controls = try hardware.controls(strict: false)
            precondition(controls.isEmpty)
            precondition(audio.error == nil)
        } catch { preconditionFailure("Recovered enumeration must allow restoration: \(error)") }
        failing = true
        audio.refresh()
        precondition(audio.error != nil)
        failing = false
        audio.refresh()
        precondition(audio.error == nil && audio.devices.isEmpty)
        print("PASS: Core Audio enumeration recovers after transient failures, including empty output lists")
    }
    func property(_ element: UInt32, uid: String = "built-in", mute: Bool = false) -> MacMuteProperty {
        MacMuteProperty(device: 1, uid: uid, selector: mute ? kAudioDevicePropertyMute : kAudioDevicePropertyVolumeScalar, element: element, name: "Test output")
    }
    do {
        let hw = FakeMuteHardware(), left = property(1), right = property(2), alreadySilent = property(3)
        hw.values = [left: 0.25, right: 0.75, alreadySilent: 0]
        let controller = MacMuteController(hardware: hw, startTimer: false)
        controller.toggle()
        precondition(controller.isMuted && hw.values.values.allSatisfy { $0 == 0 })
        controller.toggle()
        precondition(!controller.isMuted && hw.values == [left: 0.25, right: 0.75, alreadySilent: 0])
        print("PASS: Mac mute restores unequal channel volumes and preserves silent outputs")
    }
    do {
        let hw = FakeMuteHardware(), first = property(0, mute: true), added = property(1, uid: "headphones", mute: true)
        hw.values = [first: 0]
        let controller = MacMuteController(hardware: hw, startTimer: false)
        controller.toggle()
        hw.values[added] = 0
        controller.refresh()
        precondition(hw.values[first] == 1 && hw.values[added] == 1)
        controller.toggle()
        precondition(hw.values[first] == 0 && hw.values[added] == 0)
        print("PASS: outputs connected during Mac mute are muted and restored")
    }
    do {
        let hw = FakeMuteHardware(), old = property(0), replacement = property(0, uid: "replacement")
        hw.values = [old: 0.6]
        let controller = MacMuteController(hardware: hw, startTimer: false)
        controller.toggle()
        hw.values = [replacement: 0.9]
        controller.toggle()
        precondition(hw.values[replacement] == 0.9 && !controller.isMuted)
        print("PASS: reused device IDs cannot restore volume onto another device")
    }
    do {
        let hw = FakeMuteHardware(), left = property(1), right = property(2)
        hw.values = [left: 0.2, right: 0.8]; hw.failWrite = right
        let controller = MacMuteController(hardware: hw, startTimer: false)
        controller.toggle()
        precondition(hw.values[left] == 0.2 && controller.error != nil)
        hw.failWrite = nil
        controller.toggle()
        precondition(!controller.isMuted && hw.values[right] == 0.8)
        print("PASS: failed Mac mute rolls back and retains failed restoration for retry")
    }
    do {
        let hw = FakeMuteHardware(), output = property(1)
        hw.values = [output: 0.4]
        let controller = MacMuteController(hardware: hw, startTimer: false)
        controller.toggle()
        hw.unsupported = true
        controller.toggle()
        precondition(!controller.isMuted && hw.values[output] == 0.4)
        print("PASS: unsupported newly connected output cannot block restoring supported outputs")
    }
}
