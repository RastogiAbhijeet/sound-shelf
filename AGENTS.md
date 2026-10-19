# Working on SoundShelf

## When asked to set up a fork or clone

Read `README.md`, `docs/setup.md`, and `docs/compatibility.md`. Work from the checkout root. A fork is optional for installation; use the user's selected fork for contributions.

1. Inspect `git status --short`; preserve existing edits. Check `sw_vers`, `uname -m`, `xcode-select -p`, `swift --version`, and `python3 --version`. Report missing tools; do not assume a compatible Python ships with macOS.
2. Build with `sh scripts/build-app.sh`. It writes `.build/` and `dist/`, uses the current architecture, and signs ad hoc. Never claim a successful build establishes live browser, OS-matrix, or microphone compatibility.
3. Launch `dist/SoundShelf.app` when setup is requested. Explain that it lives in the menu bar. Let the user handle macOS permission dialogs.
4. Establish the desired browser/profile. Help load `BrowserExtension` unpacked from a stable directory. Obtain the real 32-letter extension ID; never invent it or authorize arbitrary extensions.
5. Run `python3 scripts/install-bridge.py EXTENSION_ID --browser BROWSER` for the selected browser. It writes user-level host registration and copies the Python bridge; no sudo is needed. Reload/reconnect and verify the popup says Connected.
6. Verify with `tests/media-fixture.html` served on loopback as described in the setup guide. Report separately: build result, automated tests run, browser connection, manual controls checked, and steps still needing the user.

Do not change live call/microphone state just to test installation. Use an explicitly agreed test call for microphone verification. Do not disable OS security controls, change unrelated settings, or delete existing bridge data as a troubleshooting shortcut. Uninstall removes the selected browser's complete host registration, including other profiles; explain this before using it.

## Development

- SwiftUI/AppKit app: `Sources/SoundShelf/`; Swift package: `Package.swift`.
- Manifest V3 companion: `BrowserExtension/`; Python native messaging host: `Bridge/host.py`.
- No third-party runtime packages. Use existing scripts, not invented package-manager commands.
- Native regression tests are standalone Swift executables via `scripts/test-native.sh`, not `swift test`.
- Run the relevant checks from `CONTRIBUTING.md`. Run build verification for Swift or packaging changes.
- Preserve separate browser/profile/document identities, authoritative command acknowledgements, and session-owned mute restoration. Unknown microphone states must remain disabled. Opening a source must not change playback or mic state.
- Keep setup, compatibility, and behavior docs aligned with code. Mark untested combinations explicitly. Do not add local metadata, browser profiles, bridge snapshots, or generated build outputs to commits.
