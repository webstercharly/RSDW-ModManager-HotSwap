# Handoff

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
