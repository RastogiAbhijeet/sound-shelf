"""Chrome native-messaging host. All state stays in the current user's account."""
import json
import os
from pathlib import Path
import queue
import select
import struct
import sys
import threading
import time
import uuid

MAX_MESSAGE = 1024 * 1024


class DirectoryWatcher:
    """Wake the message loop on atomic file replacement, using only the stdlib."""

    def __init__(self, root, inbox):
        self.stopped = threading.Event()
        self.pending = threading.Event()
        self.events = None
        self.descriptor = None
        self.thread = None
        if not hasattr(select, "kqueue"):
            return
        try:
            self.descriptor = os.open(root, getattr(os, "O_EVTONLY", os.O_RDONLY))
            self.events = select.kqueue()
            event = select.kevent(self.descriptor, filter=select.KQ_FILTER_VNODE,
                flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME | select.KQ_NOTE_REVOKE)
            self.events.control([event], 0, 0)
        except OSError:
            self.close()
            return

        def watch():
            try:
                while not self.stopped.is_set():
                    events = self.events.control([], 1, 0.5)
                    if events and not self.pending.is_set():
                        self.pending.set()
                        inbox.put({})
                    if any(event.fflags & (select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME | select.KQ_NOTE_REVOKE) for event in events):
                        return
            except OSError:
                pass  # The message loop falls back to polling if the watcher stops.

        self.thread = threading.Thread(target=watch, daemon=True)
        self.thread.start()

    @property
    def active(self):
        return self.thread is not None and self.thread.is_alive()

    def close(self):
        self.stopped.set()
        if self.thread is not None:
            self.thread.join()
        if self.events is not None:
            self.events.close()
            self.events = None
        if self.descriptor is not None:
            os.close(self.descriptor)
            self.descriptor = None


def read_exact(stream, count):
    data = bytearray()
    while len(data) < count:
        chunk = stream.read(count - len(data))
        if not chunk:
            if not data:
                return None
            raise EOFError("Truncated native message")
        data.extend(chunk)
    return bytes(data)


def read_message(stream):
    header = read_exact(stream, 4)
    if header is None:
        return None
    length = struct.unpack("=I", header)[0]
    if not 0 < length <= MAX_MESSAGE:
        raise ValueError("Invalid native message length")
    body = read_exact(stream, length)
    if body is None:
        raise EOFError("Missing native message body")
    message = json.loads(body)
    if not isinstance(message, dict):
        raise ValueError("Expected an object")
    return message


def write_message(stream, message):
    payload = json.dumps(message, ensure_ascii=False).encode("utf-8")
    stream.write(struct.pack("=I", len(payload)) + payload)
    stream.flush()


def atomic_json(path, body):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
    temp.replace(path)


def valid_request(value):
    try:
        return str(uuid.UUID(value)) == value.lower()
    except (ValueError, TypeError, AttributeError):
        return False


def run(root=None, input_stream=None, output_stream=None):
    root = root or Path.home() / "Library/Application Support/SoundShelf/Bridge"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    os.umask(0o077)
    input_stream = input_stream or sys.stdin.buffer
    output_stream = output_stream or sys.stdout.buffer
    connection = str(uuid.uuid4())
    state_file = root / f"state-{connection}.json"
    inbox = queue.Queue()
    watcher = DirectoryWatcher(root, inbox)
    outstanding = set()

    def reader():
        try:
            while True:
                message = read_message(input_stream)
                inbox.put(message)
                if message is None:
                    return
        except (OSError, ValueError, EOFError) as error:
            print(f"SoundShelf: {error}", file=sys.stderr)
            inbox.put(None)

    threading.Thread(target=reader, daemon=True).start()
    last_refresh = 0
    try:
        while True:
            now = time.time()
            if now - last_refresh >= 2:
                write_message(output_stream, {"type": "refresh"})
                last_refresh = now
                # Remove leftovers after crashed browser/app instances.
                for file in root.glob("*.json"):
                    try:
                        if now - file.stat().st_mtime > 120:
                            file.unlink(missing_ok=True)
                    except FileNotFoundError:
                        pass
            try:
                message = inbox.get(timeout=2 if watcher.active else 0.15)
            except queue.Empty:
                message = {}
            # Clear before scanning so a concurrent write schedules another pass.
            watcher.pending.clear()
            if message is None:
                return
            if message.get("type") == "snapshot" and isinstance(message.get("sources"), list):
                atomic_json(state_file, {"updatedAt": time.time(), "revision": message.get("revision"), "sources": message["sources"], "microphones": message.get("microphones", [])})
            elif message.get("type") == "result":
                request = message.get("requestId")
                if request in outstanding and valid_request(request):
                    atomic_json(root / f"result-{request}.json", message)
                    outstanding.discard(request)
            for file in root.glob(f"command-{connection}-*.json"):
                try:
                    command = json.loads(file.read_text(encoding="utf-8"))
                    request = command.get("requestId")
                    if not valid_request(request):
                        continue
                    if abs(time.time() - float(command.get("createdAt", 0))) > 12:
                        atomic_json(root / f"result-{request}.json", {"error": "Command expired. Please try again."})
                        continue
                    if command.get("action") not in {"play", "pause", "focus", "volume", "mute", "microphone"}:
                        continue
                    outstanding.add(request)
                    write_message(output_stream, {**command, "type": "command"})
                except (OSError, ValueError, TypeError, AttributeError) as error:
                    print(f"SoundShelf command: {error}", file=sys.stderr)
                finally:
                    file.unlink(missing_ok=True)
    finally:
        watcher.close()
        state_file.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        run()
    except BrokenPipeError:
        pass
