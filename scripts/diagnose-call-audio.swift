import Foundation
import CoreAudio
import AppKit

// Metadata only: no taps, audio capture, or property writes.
func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var property = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
}

func list(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
    var property = address(selector, scope)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size)
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    if size == 0 { return [] }
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    status = values.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let duration = Double(arguments[2]), duration > 0, duration <= 3600 else {
    fputs("Usage: diagnose-call-audio LOG.jsonl DURATION_SECONDS (1–3600)\n", stderr)
    exit(2)
}
guard !FileManager.default.fileExists(atPath: arguments[1]),
      FileManager.default.createFile(atPath: arguments[1], contents: nil),
      let log = FileHandle(forWritingAtPath: arguments[1]) else {
    fputs("Cannot create diagnostic log.\n", stderr)
    exit(1)
}
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var record = fields
    record["event"] = event
    record["time"] = formatter.string(from: Date())
    do {
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        try log.write(contentsOf: data)
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch {
        fputs("Diagnostic log write failed: \(error)\n", stderr)
        exit(1)
    }
}

let system = AudioObjectID(kAudioObjectSystemObject)
emit("started", ["durationSeconds": duration, "pollIntervalSeconds": 0.2,
                 "os": ProcessInfo.processInfo.operatingSystemVersionString,
                 "note": "Audio IO activity is not proof of audible sound. No audio is captured."])
let end = Date().addingTimeInterval(duration)
var previous: [AudioObjectID: NSDictionary] = [:]
var previousRoutes: NSDictionary = [:]
var lastHeartbeat = Date.distantPast
var failure: String?
while Date() < end {
    autoreleasepool {
        do {
            let ids = try list(system, kAudioHardwarePropertyProcessObjectList)
            if failure != nil { emit("enumerationRecovered"); failure = nil }
            var current: [AudioObjectID: NSDictionary] = [:]
            for id in ids {
                guard let pid = scalar(id, kAudioProcessPropertyPID, pid_t(0)) else { continue }
                let app = NSRunningApplication(processIdentifier: pid)
                let devices = try? list(id, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
                let record: [String: Any] = [
                    "objectID": id, "pid": pid,
                    "bundleID": string(id, kAudioProcessPropertyBundleID) ?? app?.bundleIdentifier ?? "unknown",
                    "name": app?.localizedName ?? "unknown",
                    "outputActive": scalar(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)).map { $0 != 0 } as Any? ?? NSNull(),
                    "inputActive": scalar(id, kAudioProcessPropertyIsRunningInput, UInt32(0)).map { $0 != 0 } as Any? ?? NSNull(),
                    "outputDevices": devices as Any? ?? NSNull()
                ]
                let snapshot = record as NSDictionary
                current[id] = snapshot
                if previous[id] != snapshot { emit(previous[id] == nil ? "processAdded" : "processChanged", record) }
            }
            for id in previous.keys where current[id] == nil {
                emit("processRemoved", previous[id] as? [String: Any] ?? ["objectID": id])
            }
            previous = current
            var routes: [String: Any] = [:]
            for (label, selector) in [("defaultOutput", kAudioHardwarePropertyDefaultOutputDevice), ("systemOutput", kAudioHardwarePropertyDefaultSystemOutputDevice)] {
                if let id = scalar(system, selector, AudioObjectID(0)) {
                    routes[label] = ["id": id, "name": string(id, kAudioObjectPropertyName) ?? "unknown"]
                }
            }
            if previousRoutes != routes as NSDictionary { emit("routesChanged", routes); previousRoutes = routes as NSDictionary }
        } catch {
            let message = String(describing: error)
            if message != failure { emit("enumerationError", ["error": message]); failure = message }
        }
        if Date().timeIntervalSince(lastHeartbeat) >= 10 {
            emit("heartbeat", ["processCount": previous.count, "healthy": failure == nil])
            lastHeartbeat = Date()
        }
    }
    Thread.sleep(forTimeInterval: 0.2)
}
emit("finished")
try log.close()
