import Foundation

/// Exercises the real model and filesystem bridge against a simulated browser.
@main
struct BridgeBenchmark {
    static func pump(until condition: () -> Bool, timeout: TimeInterval) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        guard condition() else { throw NSError(domain: "BridgeBenchmark", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for bridge acknowledgement"]) }
    }

    static func main() throws {
        let model = MediaModel(bridgeURL: URL(fileURLWithPath: CommandLine.arguments[1]), nativePlayersEnabled: false)
        let count = Int(CommandLine.arguments[2])!
        try pump(until: { !model.sources.isEmpty }, timeout: 5)
        var samples: [Double] = []
        for index in 0..<count {
            // Vary click timing so both builds see the same mix of polling phases.
            let delay = ProcessInfo.processInfo.systemUptime + Double((index * 37) % 200 + 10) / 1000
            try pump(until: { ProcessInfo.processInfo.systemUptime >= delay }, timeout: 1)
            let row = model.sources[0]
            let expectedPlaying = !row.playing
            var acknowledged = false
            var success = false
            let started = ProcessInfo.processInfo.systemUptime
            model.command(row, action: expectedPlaying ? "play" : "pause") {
                success = $0
                acknowledged = true
            }
            try pump(until: { acknowledged }, timeout: 5)
            guard success, model.sources.first?.playing == expectedPlaying else {
                throw NSError(domain: "BridgeBenchmark", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Acknowledgement did not carry the expected state"])
            }
            samples.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        let sorted = samples.sorted()
        let result: [String: Any] = ["samples": count,
            "median_ms": (sorted[count / 2] + sorted[(count - 1) / 2]) / 2,
            "p95_ms": sorted[max(0, Int(ceil(Double(count) * 0.95)) - 1)],
            "max_ms": sorted.last!, "samples_ms": samples]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
