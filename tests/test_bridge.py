import importlib.util
import io
import json
import os
import queue
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("host", ROOT / "Bridge/host.py")
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.03)
    raise AssertionError("Timed out")


class FramingTests(unittest.TestCase):
    def test_unicode_and_multiple_messages(self):
        stream = io.BytesIO()
        host.write_message(stream, {"title": "Music 🎵"})
        host.write_message(stream, {"type": "refresh"})
        stream.seek(0)
        self.assertEqual(host.read_message(stream), {"title": "Music 🎵"})
        self.assertEqual(host.read_message(stream), {"type": "refresh"})
        self.assertIsNone(host.read_message(stream))

    def test_invalid_frames(self):
        for frame in [b"\x01", struct.pack("=I", 5) + b"{}", struct.pack("=I", 0), struct.pack("=I", host.MAX_MESSAGE + 1)]:
            with self.subTest(frame=frame), self.assertRaises((ValueError, EOFError)):
                host.read_message(io.BytesIO(frame))

    def test_fragmented_reads(self):
        class Fragmented(io.BytesIO):
            def read(self, count):
                return super().read(min(count, 1))
        stream = io.BytesIO()
        host.write_message(stream, {"ok": True})
        self.assertEqual(host.read_message(Fragmented(stream.getvalue())), {"ok": True})


class WatcherTests(unittest.TestCase):
    @unittest.skipUnless(hasattr(select, "kqueue"), "Requires macOS/BSD filesystem notifications")
    def test_atomic_replacements_wake_an_idle_loop(self):
        with tempfile.TemporaryDirectory() as temp:
            inbox = queue.Queue()
            watcher = host.DirectoryWatcher(Path(temp), inbox)
            try:
                self.assertTrue(watcher.active)
                path = Path(temp) / "command.json"
                for revision in range(3):
                    watcher.pending.clear()
                    host.atomic_json(path, {"revision": revision})
                    self.assertEqual(inbox.get(timeout=0.75), {})
            finally:
                watcher.close()
            self.assertFalse(watcher.active)

    @unittest.skipUnless(hasattr(select, "kqueue"), "Requires kqueue")
    def test_watcher_setup_failure_allows_polling_fallback_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(host.select, "kqueue", side_effect=OSError("Unavailable")):
            watcher = host.DirectoryWatcher(Path(temp), queue.Queue())
            self.assertFalse(watcher.active)
            watcher.close()


class IntegrationTests(unittest.TestCase):
    def test_snapshot_command_ack_and_disconnect(self):
        with tempfile.TemporaryDirectory() as temp:
            env = {**os.environ, "HOME": temp, "PYTHONDONTWRITEBYTECODE": "1"}
            process = subprocess.Popen([sys.executable, str(ROOT / "Bridge/host.py")], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0])
                self.assertEqual(host.read_message(process.stdout), {"type": "refresh"})
                bridge = Path(temp) / "Library/Application Support/SoundShelf/Bridge"
                source = {"id": "paused-player", "playing": False}
                host.write_message(process.stdin, {"type": "snapshot", "revision": 7, "sources": [source], "microphones": [{"id": "tab:10:doc", "state": "disabled"}]})
                state = wait_for(lambda: next(bridge.glob("state-*.json"), None))
                self.assertEqual(json.loads(state.read_text())["sources"], [source])
                self.assertEqual(json.loads(state.read_text())["revision"], 7)
                self.assertEqual(json.loads(state.read_text())["microphones"][0]["state"], "disabled")
                self.assertEqual(bridge.stat().st_mode & 0o777, 0o700)
                connection = state.stem.removeprefix("state-")
                request = str(uuid.uuid4()).upper()
                command_file = bridge / f"command-{connection}-{request}.json"
                host.atomic_json(command_file, {"requestId": request, "createdAt": time.time(), "action": "play", "id": "paused-player"})
                self.assertTrue(select.select([process.stdout], [], [], 5)[0])
                message = host.read_message(process.stdout)
                self.assertEqual(message["type"], "command")
                self.assertEqual(message["requestId"], request)
                self.assertEqual(message["action"], "play")
                host.write_message(process.stdin, {"type": "result", "requestId": request, "error": "Autoplay blocked"})
                result_file = bridge / f"result-{request}.json"
                wait_for(result_file.exists)
                self.assertEqual(json.loads(result_file.read_text())["error"], "Autoplay blocked")
                self.assertFalse(command_file.exists())
                mic_request = str(uuid.uuid4())
                mic_file = bridge / f"command-{connection}-{mic_request}.json"
                host.atomic_json(mic_file, {"requestId": mic_request, "createdAt": time.time(),
                                           "action": "microphone", "value": 1, "id": "tab:10:doc"})
                self.assertTrue(select.select([process.stdout], [], [], 5)[0])
                mic_message = host.read_message(process.stdout)
                self.assertEqual(mic_message["action"], "microphone")
                self.assertEqual(mic_message["value"], 1)
                host.write_message(process.stdin, {"type": "result", "requestId": mic_request,
                                                   "ok": True, "source": {"id": "tab:10:doc", "state": "disabled"}})
                mic_result = bridge / f"result-{mic_request}.json"
                wait_for(mic_result.exists)
                self.assertEqual(json.loads(mic_result.read_text())["source"]["state"], "disabled")
                process.stdin.close()
                process.wait(timeout=5)
                self.assertEqual(process.returncode, 0, process.stderr.read().decode())
                self.assertFalse(state.exists())
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()
                if not process.stdin.closed:
                    process.stdin.close()

    def test_installer_registration_and_preserving_profiles(self):
        with tempfile.TemporaryDirectory() as temp:
            env = {**os.environ, "HOME": temp}
            for extension_id in ["a" * 32, "b" * 32]:
                subprocess.run([sys.executable, str(ROOT / "scripts/install-bridge.py"), extension_id], env=env, check=True, capture_output=True)
            manifest = Path(temp) / "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.soundshelf.bridge.json"
            body = json.loads(manifest.read_text())
            self.assertEqual(len(body["allowed_origins"]), 2)
            self.assertTrue(os.access(body["path"], os.X_OK))
            # Launch the installed shell wrapper; it must preserve native framing.
            run = subprocess.run([body["path"]], input=b"", capture_output=True, env=env, timeout=5, check=True)
            self.assertEqual(host.read_message(io.BytesIO(run.stdout)), {"type": "refresh"})


if __name__ == "__main__":
    unittest.main()
