# Security and privacy

SoundShelf is an early local application. There is no published long-term security-support policy or response-time guarantee yet.

The browser companion has broad HTTP/HTTPS host access for background media and call-control discovery. Native messaging authorizes explicitly registered extension IDs. The bridge stores metadata and commands under the current user's `~/Library/Application Support/SoundShelf`; treat this as local application data, not encrypted storage. SoundShelf does not record audio or run a network listener. Enabling the extension in incognito allows its metadata into the same bridge.

Do not attach raw bridge snapshots or diagnostic logs to public reports without reviewing them. They can reveal page titles, URLs, app identifiers, device names, and local paths. Reproduce with a disposable fixture where possible.

For a potential vulnerability, use the repository's private vulnerability reporting facility if the maintainer has enabled it. If no private channel is configured, ask the maintainer to provide one without posting sensitive details publicly. Maintainers must configure and verify a private reporting channel before advertising it as available; see the [release checklist](docs/releasing.md).
