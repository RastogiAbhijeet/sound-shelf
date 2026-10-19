# Incoming-call audio diagnostic

Build with `sh scripts/build-call-diagnostic.sh`. Requires a recent macOS SDK
with Core Audio process properties (macOS 14.2 or later at runtime).

Run from the repository root, using a fresh log filename:

```sh
.build/diagnostics/diagnose-call-audio .build/diagnostics/call-test.jsonl 900
```

The diagnostic exits after the requested duration (maximum one hour), or can be
stopped with Ctrl-C. It refuses to overwrite an existing log. Logs stay in the
ignored `.build/diagnostics` directory.

It polls Core Audio process metadata every 200 ms, recording initial state and
changes to process IDs, bundle identifiers, input/output activity, output devices,
and default media/system output routes. It emits a health heartbeat every ten
seconds. Unknown property values are null, not false. It does not create audio
taps, record audio, inspect caller information, or modify any system setting.

## Manual sequence

1. Leave the Mac idle for ten seconds to establish a baseline.
2. Receive a test call on the iPhone and allow the Mac to ring for 10–15 seconds.
3. Decline or end the call and wait ten seconds.
4. Report the approximate ringing/end times so changes can be correlated.
5. In a separate test, answer on the Mac for ten seconds, then end the call.
   Compare the ringing process with the conversation process.

Repeat during a meeting only after establishing the isolated baseline. A later,
separate test can vary macOS alert volume to determine whether ringing follows it;
this diagnostic does not change alert volume itself.

Audio IO activity does not prove that a process is producing audible sound.
An already-active process can play a ringtone without a metadata transition;
short transitions between polls can be missed. A shared process does not establish
whether individual streams can be separated. Treat correlations as candidates
for further testing, not proof of ringtone-only control. Enumeration failures are
logged explicitly and must be resolved before interpreting missing activity.
