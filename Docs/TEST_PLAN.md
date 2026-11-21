# Test plan: Hot Swap

A box is checked only after the scenario has passed in Dragonwilds. Static
validation does not count. The shell's own checks are in the Mod Manager
repository's `Docs/TEST_PLAN.md`.

## Safety gates

- Never mutate equipment when preflight cannot identify the local inventory.
- Never generate or drop an item from a swap.
- Never issue an automatic rollback batch after a failed swap.

## Gear swaps

- [ ] Presets are compact, ordered by swap number, and show binding and item count.
- [ ] An 11-item row shows only `11 ITEMS`; selecting it shows `Equipment (5 shown, +6 more)` and five visible names.
- [ ] Six actions fit without clipped labels or an unnecessary action scrollbar.
- [ ] Select Swap 1, press Set Key, then capture `SHIFT+F1` within three seconds.
- [ ] Capture and execute `MOUSE4`, `MOUSE5` and middle-mouse bindings.
- [ ] Let key capture time out and confirm the existing binding remains unchanged.
- [ ] Bind with the explicit `1 SHIFT+F1` form and unbind with selected swap + `NONE`.
- [ ] Press the same swap hotkey twice and confirm the second press is a verified no-op, not a restore.
- [ ] Swap between melee, ranged and magic while stationary.
- [ ] Swap while walking and sprinting.
- [ ] Swap while taking damage in a boss fight.
- [ ] Test one-handed weapon plus shield and two-handed weapon transitions.
- [ ] Test missing item before dispatch.
- [ ] Test a partial server rejection: keep current gear and allow retry.
- [ ] Verify no stale pending lock remains.
- [ ] Verify no continuous inventory-widget scanning or frame-time degradation.

## Lifecycle

- [ ] After a fresh start, hotkeys work with the manager closed.
- [ ] After Reload Mods, hotkeys still work and fire once per press (no duplicate poller).
- [ ] After Reload Mods, a swap result still appears in the status header (one listener, not two).
- [ ] Saved swaps in `gear-swaps.json` survive a game restart and a module update.

## Multiplayer

- [ ] Client-only mod joining a remote server.
- [ ] Host-owned server without a server-side installation.
- [ ] Server rejection and correction are reported accurately.
