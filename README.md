# SoundShelf

**Your Mac’s media and call controls, together in the menu bar.**

SoundShelf is a native macOS app with separate **Sound** and **Mic** lists. See media that is playing, paused, or loaded and ready; control supported players; and jump straight to an app or browser tab.

## What it does

- Play/pause, silence/restore, and adjust volume for supported browser media, Spotify, and Music.
- Keep paused players visible, with separate entries for browser tabs and profiles.
- Silence Mac outputs or all SoundShelf players, then restore the states owned by that session.
- Show call sources separately. Google Meet microphone control is conditional on verified English call controls; Discord and native call apps currently provide discovery only.
- Run locally without an account, network service, or third-party runtime packages.

This is an early, source-built app. It uses ad hoc signing and is not a notarized release. It is not a universal per-app audio mixer. Microphone state describes the application’s setting, not proof of hardware capture or transmission. Restore master sound mutes before quitting; ownership is held in memory for the current session.

## Get started

Requires **macOS 13+** and **Swift 5.9+** through Apple’s developer tools. Browser integration also needs **Python 3.8+** and the unpacked companion extension. These are declared/code-level requirements, not a claim that every combination has been tested; see the [compatibility matrix](docs/compatibility.md).

Clone [RastogiAbhijeet/sound-shelf](https://github.com/RastogiAbhijeet/sound-shelf), then build and launch:

```sh
git clone https://github.com/RastogiAbhijeet/sound-shelf.git
cd sound-shelf
sh scripts/build-app.sh
open dist/SoundShelf.app
```

Look for the wave ring in the menu bar; there is no Dock icon. Right-click it for setup, restart, and quit. Running Spotify and Music connect through macOS Automation permission. Browser tabs need the additional [browser setup steps](docs/setup.md#connect-a-browser).

**[Full setup guide](docs/setup.md)** · **[Usage and limitations](docs/usage.md)** · **[macOS and browser compatibility](docs/compatibility.md)**

## Set it up with your agent

Clone the repository using the commands above and open the `sound-shelf` folder in your coding agent. If you plan to contribute, [fork the repository](https://github.com/RastogiAbhijeet/sound-shelf/fork) and clone your fork instead. Give your agent this prompt:

> Set up SoundShelf from this checkout on my Mac. Read AGENTS.md and docs/setup.md first. Check my OS and toolchain, build the app, and help me connect my chosen browser/profile. Ask me for the extension ID after I load the unpacked extension. Verify the connection and a media fixture, explain any manual steps, and report what was actually tested. Do not change my live call or microphone state to test setup.

The [agent instructions](AGENTS.md) cover prerequisites, installation boundaries, and verification. You can clone upstream directly if you do not plan to contribute; a fork is optional.

## Privacy and permissions

The companion can inspect HTTP/HTTPS pages and frames to discover media and supported call controls. Media metadata and commands pass through native messaging and files in `~/Library/Application Support/SoundShelf`. SoundShelf does not record audio or send this data to a network service. There is no network listener. Incognito is excluded unless you explicitly enable the extension there; if enabled, metadata uses the same local bridge.

Spotify and Music control requires Automation permission. SoundShelf does not request microphone capture permission. See the [setup guide](docs/setup.md) for installation paths and removal, and [security guidance](SECURITY.md) before sharing diagnostics.

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for architecture, tests, and bug-report details. Compatibility reports are especially useful: include the OS version, CPU architecture, browser/version, and the exact controls tested.

Maintainers: use the [release checklist](docs/releasing.md) before publishing a release. The [microphone adapter notes](docs/microphone-feasibility.md) describe its current limits.

## License

[MIT](LICENSE) © 2026 Abhijeet Rastogi.
