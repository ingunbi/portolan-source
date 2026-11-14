# Contributing

Issues and focused pull requests are welcome. State the platform, tool versions, reproduction steps and the relevant test result.

```sh
cd core && swift test
```

Use synthetic fixtures for public tests. Do not attach game archives, executable files, extracted images/audio/text/maps, original saves, screenshots containing original game art or private signing material. Asset-dependent local checks must be reported separately from asset-free tests.
The shared rules live only in core/. Keep platform changes under macos/, ipad/ or android/.
Contributions are under the MIT LICENSE; preserve provenance and separately document any third-party code. Research notes must distinguish observed behavior, static interpretation and implemented/tested behavior. Do not claim clean-room provenance or complete original-game parity without evidence.
