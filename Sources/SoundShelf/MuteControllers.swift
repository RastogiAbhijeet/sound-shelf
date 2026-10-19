import Foundation
import Combine
import CoreAudio

/// Saves only players this switch muted, leaving existing individual mutes alone.
final class ShelfMuteController: ObservableObject {
    @Published private(set) var isMuted = false
    @Published private(set) var isBusy = false
    private let model: MediaModel
    private let setMuted: (MediaSource, Bool, @escaping (Bool) -> Void) -> Void
    private var restore: [String: MediaSource] = [:]
    private var attempted: Set<String> = []
    private var timer: Timer?

    init(model: MediaModel, startTimer: Bool = true,
         setMuted: ((MediaSource, Bool, @escaping (Bool) -> Void) -> Void)? = nil) {
        self.model = model
        self.setMuted = setMuted ?? { source, muted, completion in
            model.command(source, action: "mute", value: muted ? 1 : 0, tabOnly: true, completion: completion)
        }
        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    private func identity(_ source: MediaSource) -> String {
        source.id + ":" + (source.browserSource?.id ?? source.nativeApp ?? "")
    }

    func toggle() {
        guard !isBusy, model.busySourceIDs.isEmpty else { return }
        if isMuted {
            let targets = model.sources.filter { restore[identity($0)] != nil }
            run(targets, muting: false)
        } else {
            attempted = []
            isMuted = true
            refresh()
        }
    }

    func refresh() {
        guard isMuted, !isBusy else { return }
        let targets = model.sources.filter {
            $0.muted == false && !attempted.contains(identity($0)) && !model.busySourceIDs.contains($0.id)
        }
        if !targets.isEmpty { run(targets, muting: true) }
    }

    private func finishRestoration() {
        let live = Set(model.sources.map(identity))
        // Hidden native apps may still be muted, including while reconnection is polling.
        // Release their ownership only after a successful restore acknowledgement.
        restore = restore.filter { live.contains($0.key) || $0.value.nativeApp != nil }
        isMuted = !restore.isEmpty
        if !isMuted { attempted = [] }
        if restore.values.contains(where: { $0.nativeApp != nil && (!model.nativeEnabled || !live.contains(identity($0))) }) {
            model.error = "Reconnect Spotify & Music and reopen the player if needed, then restore SoundShelf audio before restarting."
        }
    }

    private func run(_ targets: [MediaSource], muting: Bool) {
        guard !targets.isEmpty else {
            if !muting { finishRestoration() }
            return
        }
        isBusy = true
        var remaining = targets.count
        for source in targets {
            let key = identity(source)
            if muting {
                attempted.insert(key)
                // Retain on failure too: a timeout can occur after mute reached the player.
                restore[key] = source
            }
            setMuted(source, muting) { [weak self] success in
                guard let self else { return }
                if !muting && success { self.restore.removeValue(forKey: key) }
                remaining -= 1
                if remaining == 0 {
                    if !muting {
                        self.finishRestoration()
                    }
                    self.isBusy = false
                }
            }
        }
    }
}

struct MacMuteProperty: Hashable {
    let device: AudioDeviceID
    let uid: String
    let selector: AudioObjectPropertySelector
    let element: UInt32
    let name: String
}

protocol MacMuteHardware {
    func controls(strict: Bool) throws -> [MacMuteProperty]
    func value(_ control: MacMuteProperty) throws -> Float32
    func set(_ control: MacMuteProperty, value: Float32) throws
}

struct CoreAudioMuteHardware: MacMuteHardware {
    private let audio: AudioController

    init(audio: AudioController = AudioController()) { self.audio = audio }
    private func failure(_ name: String) -> NSError {
        NSError(domain: "SoundShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not silence or restore \(name)."])
    }

    func controls(strict: Bool) throws -> [MacMuteProperty] {
        audio.refresh()
        if let error = audio.error { throw NSError(domain: "SoundShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        var controls: [MacMuteProperty] = []
        for device in audio.devices {
            var uid: Unmanaged<CFString>?
            guard audio.read(device.id, audio.address(kAudioDevicePropertyDeviceUID), into: &uid), let uid else {
                if strict { throw failure(device.name) }; continue
            }
            let identifier = uid.takeRetainedValue() as String
            func writable(_ selector: UInt32, _ element: UInt32) -> Bool {
                var property = audio.address(selector, scope: kAudioDevicePropertyScopeOutput, element: element)
                var settable: DarwinBoolean = false
                return AudioObjectHasProperty(device.id, &property) && AudioObjectIsPropertySettable(device.id, &property, &settable) == noErr && settable.boolValue
            }
            let channels = audio.channelCount(device.id)
            let elements: [UInt32] = channels > 0 ? Array(1...channels) : []
            var selected: (UInt32, [UInt32])?
            for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                if writable(selector, 0) { selected = (selector, [0]); break }
                if !elements.isEmpty && elements.allSatisfy({ writable(selector, $0) }) { selected = (selector, elements); break }
            }
            guard let (selector, chosen) = selected else {
                if !strict { continue }
                throw NSError(domain: "SoundShelf", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(device.name) cannot be silenced by SoundShelf. Use its own volume control."])
            }
            controls += chosen.map { MacMuteProperty(device: device.id, uid: identifier, selector: selector, element: $0, name: device.name) }
        }
        if strict && controls.isEmpty { throw failure("Mac audio outputs") }
        return controls
    }

    func value(_ control: MacMuteProperty) throws -> Float32 {
        let property = audio.address(control.selector, scope: kAudioDevicePropertyScopeOutput, element: control.element)
        if control.selector == kAudioDevicePropertyMute {
            var value: UInt32 = 0
            guard audio.read(control.device, property, into: &value) else { throw failure(control.name) }
            return Float32(value)
        }
        var value: Float32 = 0
        guard audio.read(control.device, property, into: &value) else { throw failure(control.name) }
        return value
    }

    func set(_ control: MacMuteProperty, value: Float32) throws {
        var property = audio.address(control.selector, scope: kAudioDevicePropertyScopeOutput, element: control.element)
        let status: OSStatus
        if control.selector == kAudioDevicePropertyMute {
            var scalar = UInt32(value)
            status = AudioObjectSetPropertyData(control.device, &property, 0, nil, 4, &scalar)
        } else {
            var scalar = value
            status = AudioObjectSetPropertyData(control.device, &property, 0, nil, 4, &scalar)
        }
        guard status == noErr else { throw failure(control.name) }
    }
}

final class MacMuteController: ObservableObject {
    @Published private(set) var isMuted = false
    @Published var error: String?
    private let hardware: MacMuteHardware
    private var restore: [MacMuteProperty: Float32] = [:]
    private var timer: Timer?

    init(hardware: MacMuteHardware = CoreAudioMuteHardware(), startTimer: Bool = true) {
        self.hardware = hardware
        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    func toggle() {
        error = nil
        if isMuted { unmute() } else { mute() }
    }

    private func mute() {
        do {
            let controls = try hardware.controls(strict: true)
            // Read everything before writing, so unsupported hardware cannot cause a partial mute.
            let values = try controls.map { ($0, try hardware.value($0)) }
            for (control, value) in values {
                let muted: Float32 = control.selector == kAudioDevicePropertyMute ? 1 : 0
                if value != muted {
                    restore[control] = value
                    try hardware.set(control, value: muted)
                }
            }
            isMuted = true
        } catch {
            self.error = error.localizedDescription
            unmute()
        }
    }

    private func unmute() {
        do {
            let live = Set(try hardware.controls(strict: false))
            for (control, value) in restore {
                // Device IDs can be reused; the UID must match before restoring.
                if live.contains(control) {
                    do { try hardware.set(control, value: value) }
                    catch { self.error = error.localizedDescription; continue }
                }
                restore.removeValue(forKey: control)
            }
        } catch { self.error = error.localizedDescription }
        isMuted = !restore.isEmpty
    }

    func refresh() {
        guard isMuted else { return }
        do {
            let live = try hardware.controls(strict: true)
            // Include outputs connected while the master mute is on.
            for control in live where restore[control] == nil {
                let value = try hardware.value(control)
                let muted: Float32 = control.selector == kAudioDevicePropertyMute ? 1 : 0
                if value != muted {
                    restore[control] = value
                    try hardware.set(control, value: muted)
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}
