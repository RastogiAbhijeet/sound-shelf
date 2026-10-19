# Open-source release checklist

## Before making the repository public

- [x] Add README, setup, usage, compatibility, contribution, and agent documentation.
- [x] Add the maintainer-selected MIT license.
- [ ] Review the full Git history as well as tracked files for credentials, private URLs, personal metadata, and accidentally committed diagnostics. Rotate any exposed credentials; deletion from the latest commit alone is insufficient.
- [ ] Confirm rights to distribute code, logos, screenshots, and other assets under the stated license, including any required third-party notices.
- [ ] Set repository description/topics and verify the default branch and fork/clone instructions against the final repository URL.
- [ ] Enable a private vulnerability reporting channel and update SECURITY.md with the verified route.
- [ ] Add a current, sanitized screenshot or short demo. Existing design previews are not evidence of the current UI.

## Before tagging a release

- [ ] Run the four checks in CONTRIBUTING.md from a clean checkout.
- [ ] Test fresh setup, upgrade, reconnect, and uninstall in a disposable browser profile.
- [ ] Record manual OS/architecture/browser results in compatibility.md, including Automation permissions and output-device behavior.
- [ ] Verify Google Meet behavior in an agreed test call; retain conditional/experimental labels until supported by evidence.
- [ ] Check session-owned mute restoration, restart, disconnects, and permission-denial behavior.
- [ ] Review app version/build in scripts/build-app.sh and companion version in BrowserExtension/manifest.json. Document required companion/bridge upgrades; their versions need not match numerically.
- [ ] Write release notes covering changes, limitations, and tested configurations.
- [ ] Decide whether to publish source only or distribute binaries. For binaries, establish Developer ID signing/notarization, architecture coverage, checksums, and a clean-machine install check. Current script produces only an ad hoc signed host-architecture build.
- [ ] Consider macOS CI for Python, Node, Swift regression tests and bundle builds. Add it once runner/toolchain requirements are verified; do not badge unconfigured CI as passing.

Documentation and a successful local build do not complete this checklist. Publishing the repository or release is a separate maintainer action.
