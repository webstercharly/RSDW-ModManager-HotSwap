"""Public Hot Swap editor and lifecycle regressions."""

import unittest
from pathlib import Path

try:
    from lupa.lua54 import LuaRuntime
except ImportError:
    LuaRuntime = None


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipIf(LuaRuntime is None, "lupa is not installed")
class HotSwapUiTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            r"""
            document = { swaps = { {
                id = 1, name = "Melee", color = "#E04F4F",
                equipment = {
                    { slot = 7, asset = "ITEM_Sword_T1_Bronze", label = "Bronze sword" },
                    { slot = 8, asset = "ITEM_Shield_T1_Wood", label = "Wood shield" },
                },
            } } }
            package.loaded.rlm_store = {
                register = function() return true end,
                get = function(kind) assert(kind == "gear_swaps"); return document end,
                save = function(kind) assert(kind == "gear_swaps"); return true end,
            }
            local backpack_item = {
                slot = 7, asset = "ITEM_Greatsword_T2_Iron", identity = "greatsword",
                label = "Iron greatsword",
            }
            package.loaded.rlm_inventory = {
                equipment_slot_name = function(slot) return "Slot " .. slot end,
                same_item = function(left, right)
                    return left and right and left.asset == right.asset
                end,
                snapshot = function()
                    return { equipment = {
                        { slot = 7, asset = "ITEM_Sword_T1_Bronze", label = "Bronze sword" },
                        { slot = 8, asset = "ITEM_Shield_T1_Wood", label = "Wood shield" },
                    } }
                end,
                backpack_gear = function(slot, accepts, character, wanted)
                    assert(slot == 7 and accepts(backpack_item.asset))
                    if wanted then return backpack_item end
                    return { backpack_item }, nil, "character"
                end,
            }
            package.loaded.rlm_swaps = {
                apply = function(id) return id == 1, "Applied" end,
                start = function() started = true end,
                stop = function() stopped = true end,
                on_status = function() wired = true end,
            }
            package.loaded.rlm_hotkeys = {
                start = function() hotkeys_started = true; return true end,
                stop = function() hotkeys_stopped = true; return true end,
            }
            package.loaded.rlm_ui = { report_status = function() end, is_open = function() return false end }
            context = {
                documents = { gear_swaps = document }, uiActionViews = true,
                config = { MenuKey = "F7" },
            }
            """
        )
        body = (ROOT / "Modules/HotSwap/module.lua").read_text(encoding="utf-8")
        self.module = self.lua.eval(
            "function(body, name) return assert(load(body, name, 't'))() end"
        )(body, "@Modules/HotSwap/module.lua")

    def test_editor_saves_backpack_two_hander_and_clears_offhand(self):
        self.assertTrue(self.module.run_action(self.lua.globals().context, "edit", "1")[0])
        self.assertFalse(self.module.select_row(None, "slot:7"))
        self.assertTrue(self.module.run_action(self.lua.globals().context, "open-backpack", "")[0])
        self.assertFalse(self.module.select_row(None, "backpack:item:1"))
        ok, message = self.module.run_action(
            self.lua.globals().context, "save-backpack-item", ""
        )
        self.assertTrue(ok)
        self.assertIn("Left hand cleared", message)
        equipment = self.lua.globals().document["swaps"][1]["equipment"]
        self.assertEqual(1, len(list(equipment.values())))
        self.assertEqual("ITEM_Greatsword_T2_Iron", equipment[1]["asset"])

    def test_lifecycle_remains_idempotent(self):
        self.assertTrue(self.module.start(self.lua.globals().context))
        self.assertTrue(self.lua.globals().started)
        self.assertTrue(self.lua.globals().hotkeys_started)
        self.assertTrue(self.module.stop())
        self.assertTrue(self.module.shutdown())
        self.assertTrue(self.lua.globals().stopped)
        self.assertTrue(self.lua.globals().hotkeys_stopped)


if __name__ == "__main__":
    unittest.main()
