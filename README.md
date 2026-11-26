# RSDW Mod Manager: Hot Swap

A drop-in module for RSDW Mod Manager (RuneScape:
Dragonwilds, UE4SS). Colour-coded combat equipment swaps with configurable
hotkeys.

## Install

1. Install the Mod Manager first (see its README).
2. Copy the `Modules/HotSwap` folder from this repository into
   `RSDWModManager/Modules/`.
3. Press **RELOAD MODS** in the manager, or restart the game.

Your swaps are saved to `%LOCALAPPDATA%\RSDWModManager\gear-swaps.json`
(with rolling backups), so updating the module never replaces them.

## Use

Open `HOT SWAP` in the manager. It can capture equipped gear into a numbered
preset, apply it, edit individual saved slots and clear a preset with two-step
confirmation. Each compact preset row shows its binding and item count.

Select a preset and use **Edit Gear** to compare all 12 saved/equipped slots.
**Use Equipped** captures the currently worn item for the selected slot;
**Choose from Backpack** opens a filtered item picker. Saving a two-handed
weapon clears an incompatible saved shield, and the selected backpack item is
revalidated immediately before the preset is written.

- Apply is idempotent. It runs a preflight, dispatches only the changed slots,
  and verifies the whole replicated target. Pressing the same binding again
  keeps that preset applied.
- To change one piece without recapturing, use the gear editor. The explicit
  `swap number + slot 0-11` input remains supported by **Use Equipped**.
- **Set Key**: select a swap, press the button, then press the combination within
  three seconds. Direct `1 SHIFT+F1` input and `NONE` (unbind) also work.
  Keyboard keys, `MOUSE4`, `MOUSE5` and the middle mouse button are supported.
  Defaults avoid Shift because Shift is the sprint input.
- Bindings work while the manager is closed and never consume normal movement
  input.

Swaps use the game's normal inventory-use and server paths and need no
server-side install. Multiplayer behaviour is not yet validated (see
`Docs/TEST_PLAN.md`). Hot Swap never generates or drops
items and never rolls a partial result back; if the server rejects part of a
swap your current gear stays as it is and you can press the key again.

The dispatch interval and server-verification timeout are set in the manager's
`config.txt` / Mod Menu settings (`DispatchIntervalMs`, `VerifyTimeoutSeconds`).

## Files

| File | Purpose |
|---|---|
| `Modules/HotSwap/manifest.json` | Module identity and actions. |
| `Modules/HotSwap/module.lua` | Module screen, actions, lifecycle (`start` / `shutdown`). |
| `Modules/HotSwap/rlm_swaps.lua` | Capture, preflight, dispatch, verification. |
| `Modules/HotSwap/rlm_hotkeys.lua` | Key polling and modifier handling. |

Requires the manager's shared `rlm_engine`, `rlm_inventory`, `rlm_async`,
`rlm_transaction`, `rlm_store` and `rlm_ui`.

## Licence

MIT. See `LICENSE`.
