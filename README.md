# RoomForMac

A calm, native macOS cleaner — Smart Clean, Uninstaller, the Terrain disk explorer and live Status — built on the open-source [Mole](https://github.com/tw93/mole) engine.

> Status: in development. Design: `docs/superpowers/specs/2026-09-25-roomformac-design.md`.

## Requirements

- macOS 26 or later, Xcode 26 or later
- Homebrew tools: `brew bundle --file Brewfile`

## Building the engine

```bash
git submodule update --init
scripts/build-engine.sh        # → build/engine
bats scripts/tests             # engine build checks
```

## Changing the engine patches

```bash
scripts/mole-patches.sh start  # build/mole-work: pinned Mole with every patch applied as a commit
# edit, then: scripts/mole-patches.sh test tests/<file>.bats ; commit inside build/mole-work
scripts/mole-patches.sh export # rewrite patches/mole/*.patch
```

The host protocol is documented in `docs/engine-protocol.md`.

## License

GPL-3.0 — see `LICENSE` and `NOTICE`. RoomForMac is an independent project, not affiliated with or endorsed by Mole.
