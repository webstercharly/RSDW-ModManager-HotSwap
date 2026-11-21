# RSDW Mod Manager: Hot Swap

A drop-in module for RSDW Mod Manager (RuneScape:
Dragonwilds, UE4SS). Colour-coded combat equipment swaps with configurable
hotkeys.

## Install

1. Install the Mod Manager first (see its README).
2. Copy the `Modules/HotSwap` folder from this repository into
   `RSDWLoadoutManager/Modules/`.
3. Press **RELOAD MODS** in the manager, or restart the game.

Your swaps are saved to `%LOCALAPPDATA%\RSDWLoadoutManager\gear-swaps.json`
(with rolling backups), so updating the module never replaces them.

## Use

Open `HOT SWAP` in the manager. It can check carried gear, capture equipped gear
into a numbered preset, apply or toggle it, and clear a preset with two-step
confirmation. Each preset row shows its binding and item count; selecting one
fills its number and shows an equipment preview such as
`Equipment (5 shown, +6 more)`.

Actions: **Apply**, **Capture Current**, **Set Key**, **Set Slot**,
**Remove Slot**, **Clear**.

- Apply is idempotent. It runs a preflight, dispatches only the changed slots,
  and verifies the whole replicated target. Pressing the same binding again
  keeps that preset applied.
- To change one piece of gear without recapturing, equip the replacement and use
  `swap number + slot 0-11` with **Set Slot**.
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
