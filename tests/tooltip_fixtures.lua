-- Authoritative item-tooltip captures from ChromieCraft (WotLK 3.3.5a), recorded in-game on
-- 2026-06-27 via a throwaway dump in the eligible-loot bag scan (Session:BuildTradeableEpicCounts).
-- Each entry is the verbatim left-side tooltip lines of a held item, plus the tradeability the addon
-- must derive from them. Use these in tests so soulbound / trade-window / BoE detection runs against
-- REAL strings, not invented ones -- the trade-window wording in particular ("...with players that
-- were also eligible to loot this item for the next X.") is the long WotLK form, not the short global.
--
-- The decisive cases: an EXPIRED BoP copy (the 2h window lapsed) keeps "Soulbound" but DROPS the trade
-- window line, reading identically to a freebie by window alone -- so the soulbound line is what marks
-- it untradeable. 40629 and 43346 each appear BOTH expired and in-window (real duplicate copies in one
-- bag), which is the root cause of the "reload fixed the payout" bug.
--
-- Fields: name, id, link, lines[], soulbound, boe, window (remaining seconds or nil), tradeable.

return {
    {
        name = "Reins of the Twilight Drake (expired BoP -> permanently bound)",
        id = 43954,
        link = "|cffa335ee|Hitem:43954:0:0:0:0:0:0:0:80|h[Reins of the Twilight Drake]|h|r",
        lines = {
            "Reins of the Twilight Drake", "Soulbound", "Unique", "Mount",
            "Requires Level 70", "Requires Riding (300)",
            "Use: Teaches you how to summon this mount.  Can only be summoned in Outland or Northrend.  This is a very fast mount.",
        },
        soulbound = true, boe = false, window = nil, tradeable = false,
    },
    {
        name = "Large Satchel of Spoils (expired BoP, container)",
        id = 43346,
        link = "|cffa335ee|Hitem:43346:0:0:0:0:0:0:0:80|h[Large Satchel of Spoils]|h|r",
        lines = { "Large Satchel of Spoils", "Soulbound", "<Right Click to Open>" },
        soulbound = true, boe = false, window = nil, tradeable = false,
    },
    {
        name = "Gauntlets of the Lost Protector (expired BoP, tier token)",
        id = 40629,
        link = "|cffa335ee|Hitem:40629:0:0:0:0:0:0:0:80|h[Gauntlets of the Lost Protector]|h|r",
        lines = {
            "Gauntlets of the Lost Protector", "Soulbound",
            "Classes: Warrior, Hunter, Shaman", "Requires Level 80",
        },
        soulbound = true, boe = false, window = nil, tradeable = false,
    },
    {
        name = "Gauntlets of the Lost Protector (SAME item, in-window 39m -- the duplicate copy)",
        id = 40629,
        link = "|cffa335ee|Hitem:40629:0:0:0:0:0:0:0:80|h[Gauntlets of the Lost Protector]|h|r",
        lines = {
            "Gauntlets of the Lost Protector", "Soulbound",
            "Classes: Warrior, Hunter, Shaman", "Requires Level 80", "",
            "You may trade this item with players that were also eligible to loot this item for the next 39 min.", "",
        },
        soulbound = true, boe = false, window = 2340, tradeable = true,
    },
    {
        name = "Staff of Restraint (in-window BoP, 3m)",
        id = 40455,
        link = "|cffa335ee|Hitem:40455:0:0:0:0:0:0:0:80|h[Staff of Restraint]|h|r",
        lines = {
            "Staff of Restraint", "Soulbound", "Two-Hand", "287 - 548 Damage",
            "(130.5 damage per second)", "+85 Stamina", "+108 Intellect", "+84 Spirit",
            "Durability 120 / 120", "Requires Level 80", "Item Level 213",
            "Equip: Improves critical strike rating by 68.", "Equip: Increases spell power by 461.", "",
            "You may trade this item with players that were also eligible to loot this item for the next 3 min.", "",
        },
        soulbound = true, boe = false, window = 180, tradeable = true,
    },
    {
        name = "Fury of the Five Flights (in-window BoP, 2h, Unique)",
        id = 40431,
        link = "|cffa335ee|Hitem:40431:0:0:0:0:0:0:0:80|h[Fury of the Five Flights]|h|r",
        lines = {
            "Fury of the Five Flights", "Soulbound", "Unique", "Trinket",
            "Requires Level 80", "Item Level 213",
            "Equip: Each time you deal melee or ranged damage to an opponent, you gain 16 attack power for the next 10 sec, stacking up to 20 times.", "",
            "You may trade this item with players that were also eligible to loot this item for the next 2 hrs.", "",
        },
        soulbound = true, boe = false, window = 7200, tradeable = true,
    },
    {
        name = "Wyrmrest Band (in-window BoP, 2h, Unique-Equipped)",
        id = 40433,
        link = "|cffa335ee|Hitem:40433:0:0:0:0:0:0:0:80|h[Wyrmrest Band]|h|r",
        lines = {
            "Wyrmrest Band", "Soulbound", "Unique-Equipped", "Finger",
            "+41 Stamina", "+40 Intellect", "Requires Level 80", "Item Level 213",
            "Equip: Improves haste rating by 32.", "Equip: Increases spell power by 67.",
            "Equip: Restores 20 mana per 5 sec.", "",
            "You may trade this item with players that were also eligible to loot this item for the next 2 hrs.", "",
        },
        soulbound = true, boe = false, window = 7200, tradeable = true,
    },
    {
        name = "Mantle of the Eternal Sentinel (BoE, never bound -> freely tradeable)",
        id = 40439,
        link = "|cffa335ee|Hitem:40439:0:0:0:0:0:0:0:80|h[Mantle of the Eternal Sentinel]|h|r",
        lines = {
            "Mantle of the Eternal Sentinel", "Binds when equipped", "Shoulder", "434 Armor",
            "+45 Stamina", "+56 Intellect", "Durability 70 / 70", "Requires Level 80", "Item Level 213",
            "Equip: Improves critical strike rating by 61.", "Equip: Improves haste rating by 32.",
            "Equip: Increases spell power by 91.",
        },
        soulbound = false, boe = true, window = nil, tradeable = true,
    },
}
