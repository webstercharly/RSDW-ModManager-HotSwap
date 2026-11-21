# Agent entry point

This repository is the **Hot Swap** module for the RSDW Mod Manager. It installs as
`RSDWModManager/Modules/HotSwap` and contains no shell code.

Before changing code, read the Mod Manager repository's `AGENTS.md`,
`README.md` (module contract), `.agent/SKILLS.md` and
`Docs/KnowledgeBase/`. The same crash rules and evidence gates apply here.

Module rules:

- Keep everything the module needs inside `Modules/HotSwap/`: services, assets and
  the manifest. Add that folder to `package.path` at the top of `module.lua`.
- Do not edit or copy shell files. If the shell needs to change, change it in the
  Mod Manager repository and update the module contract there.
- `start(state)` must be idempotent; it runs again after every Reload Mods.
- Hot Swap never generates or drops items and never rolls a failed batch back. Preset apply is idempotent.

- Parse every changed Lua file (`npx luaparse <file>`) and validate every changed
  JSON file. Never tick a `Docs/TEST_PLAN.md` box until the behaviour is confirmed
  inside Dragonwilds.
- Update `HANDOFF.md` before ending a session: objective, next step, files changed,
  tests run, live results (kept separate from static checks) and open risks.
