# Compatibility

[README](../README.md) · [Setup](setup.md)

“Declared target” means the project permits that OS version. It does **not** mean every feature has passed a manual test there. No comprehensive OS/browser/device test matrix is currently available.

## macOS

| macOS version | Project status | Verification status |
| --- | --- | --- |
| 12 and earlier | Below the app's declared minimum | Unsupported by this package |
| 13 Ventura | Declared minimum in Package.swift and the app bundle | Full manual verification outstanding |
| 14 Sonoma | Within declared deployment range | Full manual verification outstanding |
| 15 Sequoia | Within declared deployment range | Full manual verification outstanding |
| 26 Tahoe | Within declared deployment range | Full manual verification outstanding |
| Later versions | Not excluded by deployment minimum; not a forward-compatibility promise | Verify separately on each version |

The local documentation check environment on 2026-10-19 reports macOS **27.0.1 (26A434)**, **arm64**, Swift **6.4**, Python **3.14.5**, and Node.js **24.19.0**. This is the host's self-reported version, not evidence of a public OS release or a complete manual compatibility test. On this host, all 7 Python bridge tests, 51 browser fixture tests, and 34 native regression tests passed, and `sh scripts/build-app.sh` produced the ad hoc signed app. Live browser/call interaction and other OS/architecture combinations were not tested in this documentation pass. The build emitted non-fatal user-cache and developer-library search-path warnings.

## Hardware and build tools

| Component | Requirement / limitation |
| --- | --- |
| Apple silicon | Local build targets the host architecture; current verification host is arm64 |
| Intel Mac | No explicit architecture exclusion in Package.swift; build and runtime unverified |
| Universal binary / Rosetta | Not produced or validated by the build script |
| Swift | Package declares tools version 5.9; choose developer tools compatible with the host OS |
| Python | 3.8+ based on installer APIs; only the local version above is verified here |
| Node.js | 18+ for the built-in test runner; not required to run the app |
| Optional incoming-call diagnostic | Separate recent SDK and macOS 14.2+ runtime requirement; not required for normal setup |

## Browsers and native integrations

| Integration | Implementation | Limits / evidence |
| --- | --- | --- |
| Chrome | Initial target; Manifest V3 companion, native messaging | Manifest declares Chrome 106 minimum; no claim of testing every version since 106 |
| Brave, Edge, Chromium | Installer registration paths are implemented | Same companion; end-to-end verification required per browser/profile |
| Safari, Firefox | No companion implemented | Unsupported |
| Spotify, Music | Native playback, volume, and mute via Automation | Requires installed/running app and permission; verify against installed app version |
| Other native audio apps | No general playback/volume adapter | Not a universal per-app mixer |
| Google Meet | Conditional mic controls and call-tab speaker mute | Recognized English live-call UI only; deterministic tests are not live-call validation |
| Discord web / known native call apps | Discovery only | Mic state/control unavailable; running does not establish microphone use |

Browser media discovery covers qualifying HTML audio/video elements, accessible frames, and open shadow roots. Closed shadow roots, Web Audio-only media, internal browser pages, protected/custom players, and unloaded tabs are not generally supported. Google Meet call-tab silence is a special case that can cover Web Audio; it does not add general Web Audio playback or volume control.

Mac output silence depends on each device exposing writable mute or volume properties. Fixed-volume HDMI, USB, Bluetooth, aggregate, or other outputs must be checked individually; connection type alone does not establish compatibility. No output routing control is provided.

## Report a working configuration

Include `sw_vers`, `uname -m`, browser/version, app versions, output device type, and the specific checks performed: build, extension connection, discovery, playback, volume, silence/restore, restart, and optional test-call controls. Redact personal identifiers. Record failures as well as successes. See [CONTRIBUTING.md](../CONTRIBUTING.md).
