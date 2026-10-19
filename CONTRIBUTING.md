# Contributing

Start with [setup](docs/setup.md), [compatibility](docs/compatibility.md), and [AGENTS.md](AGENTS.md). Fork, clone, and create a focused branch. Keep unrelated edits out of your pull request.

## Architecture

The SwiftUI/AppKit menu bar app reads local bridge snapshots and queues commands. The Python native-messaging host connects browser stdin/stdout to local files. The Manifest V3 companion discovers page media and supported call controls and returns observed state. Spotify/Music use Automation; Mac output mute uses Core Audio. No external runtime dependencies are installed.

## Checks

Run from the repository root on macOS:

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
node --test tests/browser.test.cjs
sh scripts/test-native.sh
sh scripts/build-app.sh
```

Python 3.8+, Node.js 18+, and Swift 5.9+ are code-level prerequisites; use a toolchain that also supports your host OS. Native tests are standalone executables, not SwiftPM test targets. Tests use fixtures and do not establish compatibility with every live streaming site or call UI. Run the relevant suite for a focused change; run all four checks before a release.

For manual browser checks, follow [setup verification](docs/setup.md#verify-setup). For mic adapters, follow [the adapter contract](docs/microphone-feasibility.md) and use a test call. Never infer active capture from a running app or open page. An optional local bridge benchmark is documented in [usage](docs/usage.md#verify).

## Pull requests and reports

Describe the problem, resulting behavior, and checks performed. Include macOS version, architecture, developer toolchain, browser/version/profile count, affected app/site, reproduction steps, expected/actual behavior, and sanitized errors where relevant. Include screenshots for UI changes without exposing personal tabs or calls.

Keep microphone state conservative, browser identities distinct, and mute restoration limited to sources the session owns. Add regression coverage for behavior changes. Update docs when setup, permissions, supported adapters, or minimum versions change.

Do not commit `.build/`, `dist/`, local bridge state, recordings, or private diagnostics. Review security-sensitive reports using [SECURITY.md](SECURITY.md).
