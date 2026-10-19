# Microphone integration feasibility

Checked against this repository on 19 October 2026. Tests establish adapter contracts;
no authenticated production call was joined, recorded, or changed during development.
Live service compatibility still needs the manual checks below.

| Integration | Discovery | Actual mute observation | Control | Attach to existing call |
| --- | --- | --- | --- | --- |
| Google Meet web, English controls | Room URL, independently of media players | Conditional: one visible in-call Leave call button and one microphone button; `data-is-muted` and the action label must agree | Conditional: click the app's own button, then require its verified state to match the explicit request | Yes when the DOM contract is present; no access to existing track objects is needed |
| Discord web | `/channels/` pages are candidates, including text-only views | Unverified: self-mute alone cannot establish effective state under server mute, deafen or push-to-talk | Disabled, grey | Candidate discovery works after injection; control unsupported |
| Native Discord, Zoom, Teams, FaceTime, WhatsApp, Slack | Running app bundle identity only; does not establish an active call | Unverified | Disabled, grey | Running-app discovery only |
| Other websites/apps | No mic adapter | Unknown | Unsupported | Unsupported |

## Evidence and chosen boundary

- The existing `content.js` discovers HTML audio/video elements. Those are playback
  sources, not a catalogue of microphone captures. `background.js` previously
  refused to construct a tab row without a primary player. `host.py` transports
  metadata and commands; it has no microphone observation capability.
- Chrome content scripts can inspect and click shared DOM controls while remaining
  in the isolated world: https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts
- Track `enabled`, source `muted`, and application mute are separate concepts:
  https://www.w3.org/TR/mediacapture-streams/
  Permission grants, output audibility and track activity are not used as mic state.
- Existing native automation covers Spotify/Music playback and output volume only.
  The locally installed Discord bundle has no `.sdef`/`.scriptSuite` adapter contract.
  No general native input-control adapter was established. Apple documents
  AVAudioApplication input mute for the application itself, which does not establish
  a supported way to control arbitrary call apps:
  https://developer.apple.com/documentation/avfaudio/avaudioapplication
- A page-world getUserMedia hook was deliberately not shipped: attachment to
  already-created streams, processed/cloned/replaced tracks, complete frame coverage,
  independently disabled tracks, and synchronization with application mute were not
  established. SoundShelf never touches tracks or invokes capture APIs.

## Meet adapter contract

The room path must match `/xxx-xxxx-xxx` on `meet.google.com`. The content script
requires a unique visible `Leave call` control and a unique visible microphone
control. The microphone control must have `data-is-muted="true"` paired with
`Turn on microphone`, or `data-is-muted="false"` paired with `Turn off microphone`.
An optional parenthesized shortcut suffix is allowed. Disabled controls, other
locales, missing attributes, conflicting signals and duplicate controls are grey.
These selectors are a conditional adapter contract, not a Google-supported API.
Future markup changes should fail closed to grey and require revalidation.

SoundShelf delegates the change to Meet's call-wide control rather than selectively
changing a media track. This lets the app own its track/frame semantics; SoundShelf
never saves/restores track flags, clears unrelated mutes, clicks a deafen button,
or sends a keyboard shortcut. Independent track flags therefore remain outside
SoundShelf's control. This does not prove every internal Meet audio pipeline;
a green icon reports the verified **application microphone setting**, not capture,
transmission, permission, speech activity, or hardware availability.

Commands are explicit desired states, so a state change between observation and
execution does not cause an extra toggle. Acknowledgement waits up to 1.8 seconds
for the verified app state. Rapid commands are blocked in the Swift model and
adapter and serialized by tab in the worker. Failures trigger a fresh inspection.
No retry automatically clicks again. Commands and acknowledgements remain bound
to the originating browser connection and current tab/frame document.

The worker reports at most one mic row per tab. Additional reported mic frames
make coverage uncertain and disable the tab's mic control. Mic observations expire
after 12 seconds without a fresh content report. Extension disconnection preserves
previously discovered rows as grey in the app for up to 60 seconds after snapshot expiry; the next
connected snapshot for the same connection removes closed or navigated sources. Host restarts allocate a fresh connection ID, so old grey rows may briefly coexist with new rows until that grace period expires; they are never merged across profiles. Running native candidates
are labelled as such and removed when the app exits.

## Call sound output

A fresh, visible in-call Leave call control establishes call context separately
from mic state. Active Meet calls get a sound-only row even when their audio
pipeline exposes no qualifying HTML media player. Silence/restore uses Chrome's
tab mute flag across all frames and Web Audio. That flag is the authoritative
speaker state; a locally muted self-preview is not treated as muted call output.
Call restore never clears media-element mutes or changes microphone state, and
play/pause/volume commands are rejected for these call-only rows. Call context
expires with the frame observation and is cleared when the integration disappears.

## Validation

Automated coverage lives in `tests/browser.test.cjs`, `tests/test_bridge.py`, and
`tests/Swift/MediaModelTests.swift`. Browser tests exercise the real adapter code
against controlled DOM objects, the content-to-worker protocol, mic-only rows,
app-side changes, mixed frames, failed commands, no sound mutation, exact-tab
focus, stale documents and command serialization. Swift tests cover profiles,
unknown state, disconnected retention, pending mic commands, focus, late ACKs and
failures. These tests do not substitute for the real-service check below.

Light/dark panel renders with representative data are in `design/previews/`.
They are visual QA fixtures, not screenshots of a production call.

## Live-service verification checklist

1. Reinstall the bundled bridge, reload the extension in each connected profile,
   and reconnect. Injection into eligible already-open pages is attempted during
   extension bootstrap. Reload the call tab if injection is restricted or missing;
   no permission should be requested merely to list a source.
2. In an English Google Meet call, compare the panel with Meet's own microphone
   button. Test both directions from both interfaces. No change should affect
   speaker mute, playback or the footer controls.
3. Connect SoundShelf after the call is already running. Repeat with a mic-only
   call, two tabs, two Chrome profiles, and an embedded/unknown mic report. Extra
   coverage uncertainty should be grey, never a partial tab-wide mute claim.
4. Check permission denied, missing/disabled controls, other languages, call ended,
   rapid clicks, delayed/refused state changes, navigation during a command, closed
   tabs, extension reload and native-host disconnect. Unknown conditions stay grey;
   a failed command shows an error and reads state again.
5. Check native candidates and Discord web: they remain grey and their name opens
   the exact source without changing its sound or microphone settings.

Until steps 1–4 pass on a real deployment, treat Meet compatibility as conditional.
No system-wide microphone mute or arbitrary native-app control is included.
