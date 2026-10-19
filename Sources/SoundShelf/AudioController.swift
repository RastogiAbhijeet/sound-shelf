import CoreAudio
import Foundation
import Combine

struct OutputDevice: Identifiable {
    let id: AudioDeviceID
    let name: String
    let volume: Double?
}

final class AudioController: ObservableObject {
    @Published var devices: [OutputDevice] = []
    @Published var selected: AudioDeviceID = 0
    @Published var error: String?
    private let enumerateOutputs: (() throws -> [OutputDevice])?

    init(enumerateOutputs: (() throws -> [OutputDevice])? = nil) {
        self.enumerateOutputs = enumerateOutputs
    }

    private let system = AudioObjectID(kAudioObjectSystemObject)

    func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func read<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, into value: inout T) -> Bool {
        var property = property
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer) == noErr
        }
    }

    private func volumeElements(_ id: AudioDeviceID) -> [UInt32] {
        func writable(_ element: UInt32) -> Bool {
            var property = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(id, &property) && AudioObjectIsPropertySettable(id, &property, &settable) == noErr && settable.boolValue
        }
        if writable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        let channels = channelCount(id)
        return channels > 0 ? (1...channels).filter(writable) : []
    }

    func channelCount(_ id: AudioDeviceID) -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + $1.mNumberChannels }
    }

    func refresh() {
        do {
            devices = try enumerateOutputs?() ?? readOutputs()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func readOutputs() throws -> [OutputDevice] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else {
            throw NSError(domain: "SoundShelf", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read audio outputs."])
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { throw NSError(domain: "SoundShelf", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not read audio outputs (\(status))."]) }
        _ = read(system, address(kAudioHardwarePropertyDefaultOutputDevice), into: &selected)
        return ids.compactMap { id in
            guard channelCount(id) > 0 else { return nil }
            var alive: UInt32 = 0
            guard read(id, address(kAudioDevicePropertyDeviceIsAlive), into: &alive), alive != 0 else { return nil }
            var rawName: Unmanaged<CFString>?
            let hasName = read(id, address(kAudioObjectPropertyName), into: &rawName)
            // Core Audio transfers ownership of this CF object to the caller.
            let name = hasName ? rawName.map { $0.takeRetainedValue() as String } ?? "Audio output" : "Audio output"
            let values: [Float32] = volumeElements(id).compactMap { element in
                var value: Float32 = 0
                return read(id, address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element), into: &value) ? value : nil
            }
            let volume = values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
            return OutputDevice(id: id, name: name, volume: volume)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func select(_ device: OutputDevice) {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = device.id
        let status = AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: id)), &id)
        refresh()
        if status != noErr { error = "Could not switch to \(device.name) (\(status))." }
    }

    func setVolume(_ device: OutputDevice, value: Double) {
        var writeError: String?
        for element in volumeElements(device.id) {
            var property = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            var scalar = Float32(min(1, max(0, value)))
            let status = AudioObjectSetPropertyData(device.id, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: scalar)), &scalar)
            if status != noErr { writeError = "Could not change \(device.name) volume (\(status))." }
        }
        refresh()
        if let writeError { error = writeError }
    }
}
