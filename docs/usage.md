# SoundShelf usage and behavior

[README](../README.md) · [Setup](setup.md) · [Compatibility](compatibility.md)

A native macOS menu bar app for media that is **playing, paused, or loaded and ready**. Uses independent **Sound** and **Mic** lists in a 680 px panel with an opaque, appearance-aware panel and **03 · Wave ring** menu bar logo, with **play/pause** where supported and **silence/restore** beside sound sources. Click a source’s name to bring its app or exact browser tab forward. Rows stay in place when you pause. Right-click the menu bar icon or panel for Setup, Restart SoundShelf, and Quit. Hover over the icon for a hint.

## Run

Requires macOS 13+, Swift 5.9+ through Apple's developer tools (`xcode-select --install`), and Python 3.8+ for the browser bridge. See [setup](setup.md) for prerequisite checks. No third-party packages, server, or account required.

```sh
sh scripts/build-app.sh
open dist/SoundShelf.app
```

Click the wave ring in the menu bar. The app has no Dock icon. Right-click the menu bar icon or inside the panel for settings, **Restart SoundShelf**, or Quit. Restart restores master mutes owned by the current session before launching a fresh app instance; a restore/launch failure keeps the app running and shows an error. You can move `dist/SoundShelf.app` to Applications after building. The bundle includes the browser companion and setup scripts under `Contents/Resources`.

## Connect browser tabs

Chrome is the initial target. Brave, Edge, and Chromium use the same companion with their respective bridge registration. Safari and Firefox are not implemented.

1. Open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select this project's `BrowserExtension` directory. Keep that directory in a stable location.
2. Copy the extension's 32-letter ID.
3. From this project directory, run:

   ```sh
   python3 scripts/install-bridge.py YOUR_EXTENSION_ID --browser chrome
   ```

   For another browser replace `chrome` with `brave`, `edge`, or `chromium`, and load the extension in that browser. Run the installer for each browser you want to connect. It registers only the extension IDs you supply, and preserves previous IDs for additional profiles.

4. Click the companion's toolbar icon and **Reconnect**. It should show **Connected**. Open the SoundShelf menu bar panel. Existing supported tabs are scanned automatically; reload a tab if its player is missing.
5. Use play/pause and silence/restore beside each player. Click the name to focus its exact browser tab; the control buttons do not switch away. Each tab gets one sound row, even when the page creates multiple media elements. The active player is preferred, and stays selected when paused. Silent previews do not displace a paused main player; buffering and seeking do not count as playback. Clicking a title only focuses the tab and reads its current state. Pause stops all currently playing elements in that tab; Play resumes the selected player. Silence affects the entire tab. Restore sound clears tab and element mute; an element already at zero volume is restored to its remembered level or 50% if unknown. Paused entries remain until the player is removed, the tab closes, or navigation replaces the page. Loaded players with visible native controls or explicit Media Session metadata can appear before playback. Other custom/background elements enter the list only after Chrome observes sound from that document. A `src` attribute, hidden preload element, or silent autoplay banner alone does not add a page. Navigating the same tab to a silent page clears the previous player's row; it does not just rename it.

The extension needs access to HTTP/HTTPS pages to find media in background tabs and embedded frames. Metadata, playback state, and commands travel through Chrome's native messaging pipe and local files in `~/Library/Application Support/SoundShelf`. No page contents or audio recordings are collected or sent to a network service. Incognito is excluded unless you explicitly allow the extension there; if enabled, its player metadata also appears in the same local panel. There is no network listener.

## Updating an existing installation

Rebuild the app, update the installed bridge with the same installer command, and click **Reload** on SoundShelf Companion at `chrome://extensions` in each connected Chrome profile. No need to remove the extension or change its ID.

## Native apps

Running Spotify and Music apps connect automatically. macOS asks for Automation access; allow the apps you want to control. To disable or reconnect them, use **Connect Spotify & Music** in the panel’s right-click menu. An explicit disabled setting is remembered. If SoundShelf master mute owns a native player’s mute when you disable integration, reconnect Spotify & Music before restoring SoundShelf audio or restarting. Its restore state is retained while integration is disabled. If access is denied, use System Settings → Privacy & Security → Automation to change it. Disabled integration never queries those players. Other native apps need additional adapters.

For native apps, mute sets the app's volume to zero and unmute restores its previous volume for this session. If an app was already at zero when SoundShelf connected, unmute uses 50%.

Each supported Sound row has an independent **0–100% volume slider** and percentage readout. Drag and release to apply; keyboard adjustments apply after a short delay. Spotify and Music change their app volume. Browser sliders change the tab's selected HTML media player's volume, leaving other tabs and profiles alone; additional players within the same tab keep their own levels. External volume changes update the readout. Failed changes return to the observed level and show an error. Volume controls are disabled while SoundShelf master mute is active or a row command is pending. Browser mute remains separate, so adjusting volume does not unmute a silenced tab. Call rows such as Google Meet show “Volume unavailable” and retain speaker mute. Arbitrary native apps and Web Audio-only sources need additional integration. Output switching remains outside the interface.

## Microphones

The **Mic** list is independent of sound playback. Google Meet room tabs and
Discord channel pages can appear without an audio/video player. Known running
native call apps appear as candidates labelled “App running · mic status unavailable.”
An app or tab can appear in both columns; Chrome profiles remain separate.

- **Grey microphone:** unsupported, unavailable, or unknown. Disabled.
- **Red crossed microphone:** verified application microphone setting is disabled.
  Click to unmute it.
- **Green microphone:** verified application microphone setting is enabled.
  Click to mute it. This does not indicate speech, transmission, or hardware status.

An active Google Meet call also gets a **Sound** row even without a detected
HTML audio/video player. Its speaker control silences/restores the Chrome tab,
covering call audio across frames and Web Audio. It has no play/pause control.
Restoring call sound only clears tab silence; it never unmutes the local camera
preview or changes the microphone. Sound control can remain available when the
call context is verified but microphone state is unknown.

The first conditional control adapter is **Google Meet with English call controls**.
It requires a live call and agreement between the app's microphone action label and
mute attribute. It clicks Meet's own control and waits for the observed state to
confirm the change. Unknown markup, other languages, disabled controls, conflicting
signals and uncertain frame coverage stay grey. Existing calls can attach when the
controls are present; SoundShelf does not need to inspect their existing tracks.
The adapter is covered by deterministic tests but has not been verified in a live
production call in this development session. Check it against your call before
relying on it. [Feasibility and manual verification](microphone-feasibility.md)
records the exact adapter contract and limits.

The Mic footer has **Mute Microphones / Unmute Microphones**, limited to supported
sources with a verified state. It skips unknown and already-muted sources. Restore
only re-enables sources muted by that button, and never targets a replacement page
or another profile. New supported sources are included while the group mute is
active. Individual mic controls are disabled until the group is restored; opening
sources remains available. Failed restores retain the restore action for retry.
Group ownership lasts for the current app session. Restart never automatically
unmutes microphones; after restarting, use the individual call controls to unmute.

Discord web and native call apps currently provide discovery only. Their mic state
stays grey: no native mic-control API or complete Discord effective-mute observation
has been established. A running app or an open channel does not establish mic use.
Media-only apps are not added to the Mic list.

SoundShelf never requests microphone permission, starts capture, or records audio
for discovery. Microphone commands use their own pending state and leave playback,
speaker mute, **Silence Mac**, and **Silence SoundShelf** unchanged. Opening a source
changes neither playback nor mic state. On failure, the app shows an error and the
browser refreshes the observed state. Disconnected discovered sources turn grey for up to 60 seconds;
a fresh snapshot for the same connection removes closed sources.

After upgrading, rebuild the app, **rerun the bridge installer**, reload the
companion in every connected profile, and click **Reconnect**. The app bundle also
contains the updated extension and installer. Already-open tabs are reinjected
where possible; reload a call tab if its mic row is missing. No new extension
permissions are required. Call sound rows have speaker mute without play/pause.

## Silence sound output

The Sound column footer has two independent controls: **Silence Mac** (Apple logo) silences connected Mac audio outputs using Core Audio, and **Silence SoundShelf** (wave ring) silences all listed players. Click again to restore the previous state. Neither pauses playback. Already muted players and outputs stay muted. Newly discovered players and outputs are included while their master mute is active.

SoundShelf master unmute restores only tabs/apps it muted, without clearing individual media-element mutes. Reload the updated browser companion in each connected profile for this behavior. Individual row mute is disabled while SoundShelf master mute is active; play/pause and opening players remain available.

Mac mute uses hardware mute where available, otherwise saves and zeroes every output channel's volume. It restores each channel separately. Fixed-volume outputs that support neither control produce an error instead of claiming the Mac is muted. A disconnected device is not restored onto another device with a reused ID. Audio output changes are detected within one second. Restore master mutes before quitting; restoration state is kept for the current app session.

## Coverage and limits

- Browser discovery inspects standard HTML `<audio>` and `<video>` elements, including accessible embedded frames and open shadow roots. It retains paused players rather than depending on the OS Now Playing list.
- A tab that has not created or loaded a qualifying media element cannot be identified as a player. Custom players without native controls or Media Session metadata may need to produce sound once before appearing; afterward they remain listed when paused in the same document. Lazy players may need you to open the tab or click its own Play button once. Autoplay policy can reject a remote Play request; the app shows the error so you can open the tab.
- Closed shadow roots, Web Audio-only players, browser-internal pages, discarded/unloaded tabs, and custom protected players need more integration. DOM access does not guarantee control on every streaming service.
- Browser rows show the selected media element’s label or page title, not guaranteed song-level metadata. Tabs and Chrome profiles stay separate even if their titles match. Reports are checked against current Chrome document IDs and report sequence numbers, and detached or discarded pages are removed.
- Native apps are refreshed every four seconds. Browser state is reported on media changes and periodic scans. Frozen/background pages may report changes late, but their paused entries stay visible.
- Per-app output routing and arbitrary native-app volume require a separate audio processing solution and are outside this first version.
- This is a local development build with ad hoc signing, not a notarized distribution or App Store release.

## Verify

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
node --test tests/browser.test.cjs
sh scripts/test-native.sh
sh scripts/build-app.sh
```

Browser commands and acknowledgements use filesystem notifications at both ends of the local bridge. Atomic file replacement wakes the app and native host immediately; maintenance polling remains as a fallback. Commands validate the target tab's current documents, while full browser maintenance runs outside the controls' state queue. Unchanged snapshots do not redraw the player list.

Measure the local command round trip with:

```sh
python3 scripts/benchmark-bridge.py --samples 20
```

This exercises the real Swift model and Python native host in a temporary directory, with a simulated browser. It reports median and p95 time from sending a command to receiving its authoritative state. Chrome messaging, page execution, and media loading are excluded. It does not connect to or control your actual players. To compare a saved implementation, put its `MediaModel.swift` and `host.py` in a directory and pass `--baseline /path/to/directory`.

Read-only output device diagnostic: `dist/SoundShelf.app/Contents/MacOS/SoundShelf --diagnose`.

For a manual check, open `tests/media-fixture.html` through a local HTTP server (`python3 -m http.server 8765 --bind 127.0.0.1`, then visit `http://127.0.0.1:8765/tests/media-fixture.html`). It creates two loaded players with generated WAV data. They should produce one row before playback. Open the fixture in a second tab: it should produce a separate row, even with the same title. Start both players in one tab, then pause the SoundShelf row: both should stop. Play should resume only the selected player. Muting should silence the entire tab, without affecting the other tab. Test play/pause, mute/unmute, navigation, closing the tab, and disconnect/reconnect. For Spotify and Music, check that unmute restores the app's previous volume. Also test a real streaming tab: site-specific behavior varies.

## Remove

Restore session-owned master sound mutes and any desired microphone state, then quit SoundShelf and remove the browser extension. Unregister the host using the same browser argument:

```sh
python3 scripts/install-bridge.py YOUR_EXTENSION_ID --browser chrome --uninstall
```

The uninstall command removes the selected browser’s entire host registration, including IDs registered for other profiles. After unregistering every browser, you can delete `~/Library/Application Support/SoundShelf` and the app. No launch agent or login item is installed.

## Implementation references

- [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Chrome content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)
- [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
- [Chrome scripting API](https://developer.chrome.com/docs/extensions/reference/api/scripting)
