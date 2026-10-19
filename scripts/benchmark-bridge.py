#!/usr/bin/env python3
"""Measure Swift -> real bridge -> simulated browser -> confirmed Swift state."""
import argparse
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument("--baseline", type=Path, help="Directory containing saved MediaModel.swift and host.py")
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("--samples must be positive")
    model = args.baseline / "MediaModel.swift" if args.baseline else ROOT / "Sources/SoundShelf/MediaModel.swift"
    bridge = args.baseline / "host.py" if args.baseline else ROOT / "Bridge/host.py"
    model, bridge = model.resolve(), bridge.resolve()
    binary = ROOT / ".build" / ("bridge-benchmark-baseline" if args.baseline else "bridge-benchmark")
    cache = ROOT / ".build/swift-cache"
    cache.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", str(cache),
        "-parse-as-library", str(model), str(ROOT / "tests/Swift/BridgeBenchmark.swift"), "-o", str(binary)], check=True)
    framing = runpy.run_path(str(bridge))
    with tempfile.TemporaryDirectory(prefix="soundshelf-benchmark-") as temp:
        process = subprocess.Popen([sys.executable, "-c",
            "import runpy,sys; from pathlib import Path; runpy.run_path(sys.argv[1])['run'](root=Path(sys.argv[2]))",
            str(bridge), temp], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        failures = []

        def browser():
            source = dict(id="tab:10:benchmark", tabId=10, frameId=0, title="Benchmark", site="test",
                playing=False, ready=False, volume=1, muted=False)
            revision = 0
            try:
                while (message := framing["read_message"](process.stdout)) is not None:
                    if message["type"] == "command":
                        source["playing"] = message["action"] == "play"
                        revision += 1
                    framing["write_message"](process.stdin, dict(type="snapshot", revision=revision, sources=[source]))
                    if message["type"] == "command":
                        framing["write_message"](process.stdin, dict(type="result", requestId=message["requestId"],
                            ok=True, revision=revision, source=source))
            except (OSError, ValueError, EOFError) as error:
                failures.append(str(error))

        worker = threading.Thread(target=browser, daemon=True)
        worker.start()
        try:
            deadline = time.monotonic() + 5
            while not list(Path(temp).glob("state-*.json")):
                if time.monotonic() > deadline:
                    raise RuntimeError("Bridge did not publish its initial state")
                time.sleep(0.01)
            result = subprocess.run([str(binary), temp, str(args.samples)], capture_output=True, text=True,
                check=True, timeout=args.samples * 6 + 10)
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            worker.join(timeout=1)
            diagnostics = process.stderr.read().decode()
            process.stdout.close()
            process.stderr.close()
        if failures or process.returncode:
            raise RuntimeError(f"Bridge failed: {failures} {diagnostics}")
        report = json.loads(result.stdout)
        report["measurement"] = "Real Swift model and Python bridge; simulated browser (excludes Chrome/site latency)"
        report["model_source"] = str(model)
        report["host_source"] = str(bridge)
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
