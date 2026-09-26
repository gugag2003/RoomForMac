# RoomForMac — Implementation Roadmap

**Spec:** `docs/superpowers/specs/2026-09-25-roomformac-design.md`

**Status (2026-09-26):** Plan 1 is built on `main`, and its CI run is blocked by Actions billing. The recommended MVP scope, the remaining steps and prompts for the next sessions are in `docs/superpowers/plans/2026-09-26-mvp-handoff.md`.

The spec spans six largely independent subsystems. Each plan below ends with working, tested software, and each is written **after the previous one lands**, so it can use real names discovered on the way — the spikes in spec §14 answer questions that later plans depend on (exact Liquid Glass APIs, TCC attribution, the Polar API).

| # | Plan | Delivers | Spec | Depends on | Spikes |
|---|------|----------|------|------------|--------|
| 1 | **Engine** — `2026-09-25-plan-1-engine.md` | Pinned + patched Mole, reproducible universal engine build, `MoleEngine` Swift package (runner, typed events, services), engine CI | §3.1, §4.1–4.4, §4.6, §10, §13 (engine) | — | — |
| 2 | App shell, design system, onboarding & permissions | XcodeGen app with sidebar, backdrops, glass components, onboarding for every approval in §6, Settings → Permissions | §3.2–3.3, §5.6, §6, §11 | 1 | S1, S2, S5 (signing half) |
| 3 | Smart Clean, Uninstaller, Status, menu-bar extra | The cleanup flows on top of `MoleEngine` | §5.1, §5.2, §5.4, §5.5, §10 | 1, 2 | — |
| 4 | Terrain | Bubble disk explorer | §5.3 | 1, 2 | — |
| 5 | Monetization & analytics | `Licensing` + `Telemetry` packages, allowance ledger and gate, paywall, Supabase functions, Polar | §7, §8, §9 | 2, 3 | S4 |
| 6 | Distribution | Stable self-signed signing, DMG, Sparkle, release workflow, site | §12 | 2 | S5 (updates half) |
| 7 | Admin-level cleanup | System items behind the native authorization prompt | §4.5 | 3 | S3 |

## Decisions made while planning (confirm with the product owner)

Research into Mole V1.56.0 for Plan 1 surfaced four places where the spec's wording cannot be met as written. The plans implement the closest safe behaviour:

1. **Uninstaller leftovers are listed, not individually deselectable (v1).** Mole's uninstall performs app-level side effects that cannot be scoped per file (Homebrew `--zap`, `defaults` domain deletion, launch-agent unloading, ByHost plists discovered at removal time). v1 selects per app and shows every leftover with its size before confirmation (spec §5.2 said "checkboxes").
2. **Smart Clean offers only path-based items (v1).** Cleanups that run a tool instead of deleting a previewed path — Homebrew cleanup/autoremove, npm/pip/uv/corepack/conda/bun/Go tool caches, stopping leaked automation browsers — have no per-path preview, so they cannot honour an exact selection. The engine skips them whenever a selection is active. Unavailable iOS simulators *are* offered: they are deleted one by one through `simctl`.
3. **No administrator access until Plan 7.** Mole asks for passwords with its own "Mole"-titled AppleScript dialog. Until spike S3 picks a native mechanism, the engine runs with `MOLE_NO_AUTH=1` plus a failing `sudo` shim, so system-level items do not appear and Homebrew-cask or root-owned apps are marked "needs your password" in the Uninstaller.
4. **Real-output parser coverage comes from the engine integration suite** that CI runs on every push against the freshly built engine, instead of checked-in recorded fixtures (spec §13). Unit tests use exact inline samples of the protocol.
