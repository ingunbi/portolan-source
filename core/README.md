# core

The shared Swift rules engine, data tools and format-research notes of **Portolan**.
The macOS, iPad and Android clients in this repository all use this one package.

| path | |
|---|---|
| `Sources/PortolanCore` | the game rules: world, sailing, trade, towns, battles, story scripts, saves (no UI) |
| `Sources/PortolanEngine` | the rules as a child process: one JSON command per line in, one JSON reply per line out (the Android app runs it) |
| `Sources/PortolanValidate`, `PortolanReplay`, `PortolanSaveProbe` | data checker, diagnostics replayer, save-file probe |
| `tools/` | decoders and extractors that build `assets/` from your copy of the game; `make_icon.py` draws the app icon |
| `docs/RE_NOTES.md`, `docs/re/` | how the original program works (formats, formulas, addresses) |
| `Tests/` | 296 tests; 259 of them read the game data and are **skipped** when `core/assets/` is missing |

## Build and test (from this folder)

Needs Swift 5.9+.

```bash
swift build
swift test        # without assets/, the data-dependent tests are skipped, not failed
```

## Get the game data

No game data is included; see the NOTICE in the repository root. You need your own copy of the original game.

1. Copy its `GAME` folder to `core/original/GAME` (Korean DOS edition; nothing is modified).
2. Install the Python packages once, then build `core/assets/`:

```bash
python3 -m venv .venv && .venv/bin/pip install capstone numpy scipy
PYTHON=.venv/bin/python tools/build_assets.sh        # about a minute
```

`SKIP_MUSIC=1` leaves out the music (rendering it needs macOS's `afconvert`). In a clean-checkout test every file except
the music (`.m4a` encoder output) matched a previous build of the same data byte for byte.
`assets/` is derived from the original game: never commit it or ship it.

A few tests deliberately corrupt a *copy* of `assets/` to check the validator. They resolve a symlinked `assets/`
first, but keep a real copy of your data somewhere else anyway.
