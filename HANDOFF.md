# Handoff

## Gear editor and backpack picker (26 November 2026)

- Hot Swap 0.1.3 adds compact paged preset rows and a two-page editor for all
  12 equipment slots. A slot can capture currently equipped gear or choose a
  compatible item from the backpack without equipping or generating anything.
- Backpack selection is character-bound and revalidated immediately before the
  preset document is saved. Two-handed/right-hand and shield/left-hand conflicts
  are rejected or resolved inside the preset only.
- The public module retains its own `gear-swaps.json` registration, hotkey
  poller and idempotent lifecycle; it does not depend on private shortcut or
  cheat services. Static checks are recorded below; live checks remain open.

## Baseline (Hot Swap 0.1.0-dev)

- Active objective: live validation in Dragonwilds with the Mod Manager shell.
- Exact next step: install the module, work through `Docs/TEST_PLAN.md`, and
  record observed results here.

### Static validation done

- All Lua files in `Modules/HotSwap/` parse (luaparse, Lua 5.3 grammar) and
  every `require("rlm_*")` resolves against the shell or this folder.
- The module registers its own `gear_swaps` document through `store.register`
  (file `gear-swaps.json`, same name and schema as before the split).
- `start` / `stop` / `shutdown`: `start` is idempotent (swap service, one-time
  status listener, key poller); `stop` is a no-op so a reload leaves the poller
  running; `shutdown` stops the poller and swap service.

### Live results

- None recorded for this layout.

### Risks

- The poller now starts from the module's `start` hook rather than the shell
  bootstrap. Order matches the old one but has not been run in game.
