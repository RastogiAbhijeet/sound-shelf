# Setup guide

[README](../README.md) · [Compatibility](compatibility.md) · [Usage](usage.md)

## Prerequisites

Use a Mac with macOS 13 or later and a Swift 5.9 or newer toolchain. The browser bridge uses Python 3.8+ standard-library APIs. Node.js 18+ is needed only for the JavaScript test runner. See the compatibility matrix for what has actually been verified.

Check your environment:

```sh
sw_vers
uname -m
xcode-select -p
swift --version
python3 --version
```

If developer tools are missing, run `xcode-select --install` and finish Apple’s installer. If `swift --version` is older than 5.9, select a compatible newer developer toolchain before building. Install Python separately if needed; do not assume macOS includes a suitable Python. No `pip install` or `npm install` is required.

## Clone and build

Clone [RastogiAbhijeet/sound-shelf](https://github.com/RastogiAbhijeet/sound-shelf) over HTTPS, then build and launch:

```sh
git clone https://github.com/RastogiAbhijeet/sound-shelf.git
cd sound-shelf
sh scripts/build-app.sh
open dist/SoundShelf.app
```

If you already have GitHub SSH access configured, you can use `git clone git@github.com:RastogiAbhijeet/sound-shelf.git` instead of the HTTPS clone command. Then run the same `cd`, build, and launch commands above.

To contribute through your own fork, [fork the repository](https://github.com/RastogiAbhijeet/sound-shelf/fork), copy your fork’s clone URL from **Code**, and use that URL in the clone command instead. A fork is optional for installation.

The script creates `dist/SoundShelf.app` for the build machine’s architecture and signs it ad hoc. It does not install anything system-wide. Click the wave ring in the menu bar; there is no Dock icon. You can copy the app to `~/Applications` or `/Applications` using Finder. Quit an older running copy before opening the replacement. No login item or launch agent is installed.

This is a source-build workflow, not a signed/notarized download workflow. Do not disable Gatekeeper globally to launch a distributed build. The bundle includes setup documentation and the companion under `Contents/Resources` (Finder → Show Package Contents).

## Connect a browser

1. Choose a browser/profile and open its extensions page:

   | Browser | Extensions page | Installer argument |
   | --- | --- | --- |
   | Chrome | `chrome://extensions` | `chrome` |
   | Brave | `brave://extensions` | `brave` |
   | Edge | `edge://extensions` | `edge` |
   | Chromium | `chrome://extensions` | `chromium` |

2. Enable **Developer mode**, select **Load unpacked**, and choose the checkout’s `BrowserExtension` directory. Keep that directory at a stable path. Alternatively, use a stable installed app’s `Contents/Resources/BrowserExtension` directory.
3. Copy the extension’s 32-letter ID from that page. From the repository root, replacing `YOUR_EXTENSION_ID`:

   ```sh
   python3 scripts/install-bridge.py YOUR_EXTENSION_ID --browser chrome
   ```

   When using the bundled files instead, run the same command from `SoundShelf.app/Contents/Resources`. Choose the correct browser argument. Repeat for every browser/profile and its actual ID; the installer preserves previously registered IDs for that browser. It does not require `sudo`.
4. Open the companion’s toolbar popup and click **Reconnect**. Confirm **Connected**. Existing tabs are scanned; reload a media tab if necessary.
5. Open SoundShelf’s panel and verify a supported player appears. Click its title to focus that exact tab.

The installer copies the host to `~/Library/Application Support/SoundShelf/NativeHost` and registers `com.soundshelf.bridge.json` under the selected browser’s `NativeMessagingHosts` directory in your user Library. Runtime bridge data lives in `~/Library/Application Support/SoundShelf/Bridge`. The launcher records the Python executable used for installation: rerun the installer if that Python is removed or moved.

## Connect Spotify and Music

Start the player. SoundShelf connects automatically and macOS may ask for Automation access. Allow only the integrations you want. Use **Connect Spotify & Music** in SoundShelf’s right-click menu to disable or reconnect them. If denied, review System Settings → Privacy & Security → Automation. Disabled integration is remembered.

## Verify setup

Start with a disposable test tab, not a live call:

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

From the repository root, visit `http://127.0.0.1:8765/tests/media-fixture.html`. Expect one row for the two loaded players. Open it in another tab and expect a separate row. Check play/pause, volume, tab silence/restore, title focus, and removal after closing a tab. Stop the test server with Ctrl-C. A real site may behave differently; see [usage limitations](usage.md#coverage-and-limits).

Google Meet mic control needs a live call with recognized English controls and remains conditional. Use a separate test call and confirm the actual Meet state before relying on it; a grey mic means unknown or unsupported. SoundShelf does not provide a universal microphone kill switch.

## Update

1. Restore SoundShelf-owned master sound mutes and quit the running app.
2. Update your checkout (preserve local changes), rebuild, and replace any copied app.
3. Rerun the bridge installer for each connected browser/profile.
4. Reload the extension on each profile’s extensions page, then click **Reconnect**.
5. Launch the rebuilt app and repeat a short fixture check. Reload existing tabs if needed.

Keeping the extension directory stable avoids unnecessary ID changes. Restart does not automatically unmute microphones; use the call’s own control after restarting if needed.

## Troubleshoot

| Symptom | Check |
| --- | --- |
| Build fails before compiling | Verify Swift 5.9+, selected developer tools, and OS requirements. Capture the first error. |
| No Dock icon | Expected: find the wave ring in the menu bar. |
| Companion is disconnected | Check browser argument and ID; rerun installer with a working Python, reload extension, reconnect. |
| A tab is missing | Use HTTP/HTTPS, reload it, or start its player once. Browser-internal pages and some custom players are unsupported. |
| Spotify/Music is absent | Start the app, enable the integration, and check Automation permission. |
| Mic is grey | State is unverified or adapter unsupported; use the call’s own controls. |
| Mac silence fails | Some fixed-volume devices expose neither mute nor volume. See usage limitations. |

Read-only output-device diagnostic:

```sh
dist/SoundShelf.app/Contents/MacOS/SoundShelf --diagnose
```

Review diagnostics before sharing: device names and local metadata may be personal. The optional [incoming-call diagnostic](call-audio-diagnostic.md) has a separate macOS 14.2+ requirement.

## Uninstall

Restore master sound mutes and any microphone state you want restored, then quit SoundShelf. Remove the companion from every profile. Unregister each browser using its actual extension ID:

```sh
python3 scripts/install-bridge.py YOUR_EXTENSION_ID --browser chrome --uninstall
```

**This removes the entire host registration for that browser, including all registered profile IDs**, not just the supplied ID. Other browser registrations remain. After unregistering every browser, delete the app and `~/Library/Application Support/SoundShelf` through Finder if you no longer need its local data. Delete the checkout only if you no longer need its source or unpacked extension. There is no background service to unload.
