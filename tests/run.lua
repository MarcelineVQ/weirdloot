-- Out-of-game test battery for WeirdLoot's LootCore migration.
-- Loads the REAL addon files into mocked WoW environments (one per simulated client via
-- setfenv) and drives end-to-end flows: bag reconcile, live rolls, top-N resolution,
-- the stale-roll regression, payout owes, per-copy delivery, and ML->raider snapshot sync.
--
-- Run from the addon dir:  luajit tests/run.lua
--
-- The bag/tooltip scan is monkeypatched (we inject eligible counts directly), so we never
-- need GameTooltip line scraping; everything else runs the actual addon code.

-- UI.lua is intentionally omitted: it is pure presentation and pulls in heavy FrameXML
-- (FauxScrollFrame_*, templates) irrelevant to loot accounting. The projections the tests
-- assert on (session.items / session.results) are built in Session, not UI.
local ADDON_FILES = {
    "Libs/WeirdSync-1.0/WeirdSync-1.0.lua",
    "TradeDeliver.lua", "Core.lua", "LootCore.lua", "Util.lua", "Config.lua",
    "Roster.lua", "Session.lua", "Comm.lua", "Resolver.lua", "Payout.lua",
    "LiveRoll.lua", "AutoLoot.lua",
}

-- ---------------------------------------------------------------------------
-- tiny test framework
-- ---------------------------------------------------------------------------
local pass, fail, failures = 0, 0, {}
local current = "?"
local function check(cond, label)
    if cond then pass = pass + 1
    else fail = fail + 1; failures[#failures + 1] = current .. ": " .. label; print("  FAIL " .. label) end
end
local function eq(a, b, label) check(a == b, (label or "") .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")") end
local function test(name, fn)
    current = name
    print("[" .. name .. "]")
    local ok, err = pcall(fn)
    if not ok then fail = fail + 1; failures[#failures + 1] = name .. ": ERROR " .. tostring(err); print("  ERROR " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- shared wire (AceComm transport) between simulated clients
-- ---------------------------------------------------------------------------
local WIRE = {}        -- queue of { prefix, msg, dist, target, sender }
local CLOCK = 1000     -- controllable GetTime()/time()

-- ---------------------------------------------------------------------------
-- a fake fixed item database: itemId -> name. Links embed the itemId (3.3.5 format).
-- ---------------------------------------------------------------------------
local ITEMS = {
    [40001] = "Mantle of Test", [40002] = "Helm of Test", [40003] = "Ring of Test",
    [40004] = "Token of Test",  [40005] = "Blade of Test",
}
local function linkFor(itemId) return "|cffa335ee|Hitem:" .. itemId .. ":0:0:0:0:0:0:0|h[" .. (ITEMS[itemId] or ("Item" .. itemId)) .. "]|h|r" end

-- ---------------------------------------------------------------------------
-- build a fresh mocked environment + load the addon into it
-- ---------------------------------------------------------------------------
local function makeWorld(playerName, isML)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.__onUpdates = {}    -- captured OnUpdate handlers, driven by pump()
    env.__closeTrade = 0    -- count of CloseTrade() calls (autoCancel assertions)

    -- frame mock: methods are chainable no-ops EXCEPT SetScript/GetScript (real, so we can
    -- drive OnUpdate timers + OnEvent) and NumLines (numeric, so tooltip scans don't blow up).
    local function newFrame()
        local f = { __scripts = {} }
        return setmetatable(f, { __index = function(self, k)
            if k == "SetScript" then
                return function(_, st, fn) self.__scripts[st] = fn; if st == "OnUpdate" then env.__onUpdates[self] = fn end end
            elseif k == "GetScript" then
                return function(_, st) return self.__scripts[st] end
            elseif k == "NumLines" then
                return function() return 0 end
            end
            -- WoW frame methods are CamelCase; the addon's data fields are lowercase. Return a
            -- chainable no-op for methods, but nil for an UNSET data field (e.g. frame.elapsed),
            -- so `(frame.elapsed or 0) + dt` doesn't try arithmetic on a function.
            if type(k) == "string" and k:match("^%u") then return function(s) return s end end
            return nil
        end })
    end
    env.__newFrame = newFrame

    -- deterministic-ish rng (seeded per world); resolution asserts are invariant-based anyway
    local seed = 0
    for i = 1, #playerName do seed = seed + string.byte(playerName, i) end
    local function rng(m, n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        local r = seed / 2147483648
        if m and n then return m + math.floor(r * (n - m + 1)) end
        return r
    end

    -- ---- WoW API stubs ----
    env.CreateFrame = function(_, name) local f = newFrame(); if name then env[name] = f end; return f end
    env.UIParent = newFrame()
    env.WorldFrame = newFrame()
    env.GameTooltip = newFrame()
    env.DEFAULT_CHAT_FRAME = setmetatable({ AddMessage = function() end }, { __index = function() return function() end end })
    env.GetTime = function() return CLOCK end
    env.time = function() return CLOCK end
    env.random = rng
    env.randomseed = function() end
    env.math = setmetatable({ random = rng }, { __index = math })
    env.UnitName = function(unit) if unit == "NPC" then return env.__tradePartner end return playerName end
    env.GetUnitName = function() return playerName end
    env.UnitGUID = function() return "Player-0-000000" .. tostring(#playerName) end
    env.GetRealmName = function() return "TestRealm" end
    env.UnitClass = function() return "Warrior", "WARRIOR" end
    env.GetNumRaidMembers = function() return 5 end
    env.GetNumPartyMembers = function() return 0 end
    env.GetRaidRosterInfo = function() return playerName, (isML and 2 or 0) end
    env.GetLootMethod = function() return "master", 0, 1 end
    env.IsPartyLeader = function() return isML end
    env.SendChatMessage = function() end
    env.SendAddonMessage = function() end
    env.ChatThrottleLib = { SendChatMessage = function() end }
    env.ITEM_QUALITY_COLORS = { [4] = { hex = "|cffa335ee" } }
    env.ITEM_SOULBOUND = "Soulbound"
    env.ITEM_BIND_ON_EQUIP = "Binds when equipped"
    env.ERR_TRADE_COMPLETE = "Trade complete."
    env.UI_INFO_MESSAGE = "UI_INFO_MESSAGE"
    env.MAX_TRADABLE_ITEMS = 6
    env.CloseTrade = function() env.__closeTrade = env.__closeTrade + 1 end
    env.AcceptTrade = function() end
    env.__tradePlaced = {}     -- slot -> { id, count }: what the ML hand-placed in the trade window
    env.GetTradePlayerItemLink = function(slot) local it = env.__tradePlaced[slot]; return it and linkFor(it.id) or nil end
    env.GetTradePlayerItemInfo = function(slot)
        local it = env.__tradePlaced[slot]
        if not it then return nil end
        return "Item" .. it.id, "Interface\\Icons\\inv_test", it.count or 1
    end
    env.GetItemInfo = function(idOrLink)
        local id = tonumber(idOrLink) or tonumber(string.match(tostring(idOrLink), "item:(%d+)"))
        if not id then return nil end
        local name = ITEMS[id] or ("Item" .. id)
        -- name, link, quality, ilvl, reqLevel, class, subclass, stack, equipLoc, texture, sell
        return name, linkFor(id), 4, 200, 80, "Armor", "Cloth", 1, "INVTYPE_SHOULDER", "Interface\\Icons\\inv_test", 0
    end
    -- ---- bag + trade-window model (drives the real TradeDeliver engine) ----
    env.__bags = {}                                  -- [bag] = { size=N, [slot]={id,count,link} }
    for b = 0, 4 do env.__bags[b] = { size = 16 } end
    env.__cursor = nil                               -- item held on the cursor
    env.__tradePartner = nil                         -- UnitName("NPC")
    env.__tradeSlots = 0                             -- placed trade slots this window
    env.BIND_TRADE_TIME_REMAINING = "You may trade this item with %s for %s."

    env.GetContainerNumSlots = function(bag) local B = env.__bags[bag]; return B and B.size or 0 end
    env.GetContainerItemID = function(bag, slot) local it = env.__bags[bag] and env.__bags[bag][slot]; return it and it.id or nil end
    env.GetContainerItemInfo = function(bag, slot)
        local it = env.__bags[bag] and env.__bags[bag][slot]
        if not it then return nil end
        return "Interface\\Icons\\inv_test", it.count, nil, 4   -- texture, count, locked, quality
    end
    env.GetContainerItemLink = function(bag, slot) local it = env.__bags[bag] and env.__bags[bag][slot]; return it and (it.link or linkFor(it.id)) or nil end
    env.GetContainerNumFreeSlots = function(bag)
        local B = env.__bags[bag]; if not B then return 0, 0 end
        local used = 0; for s = 1, B.size do if B[s] then used = used + 1 end end
        return B.size - used, 0
    end
    env.ClearCursor = function() env.__cursor = nil end
    env.SplitContainerItem = function(bag, slot, qty)
        local it = env.__bags[bag] and env.__bags[bag][slot]
        if not it then return end
        env.__cursor = { id = it.id, count = qty, link = it.link }
        it.count = it.count - qty
        if it.count <= 0 then env.__bags[bag][slot] = nil end
    end
    env.PickupContainerItem = function(bag, slot)
        if env.__cursor then env.__bags[bag][slot] = env.__cursor; env.__cursor = nil
        else env.__cursor = env.__bags[bag] and env.__bags[bag][slot]; if env.__bags[bag] then env.__bags[bag][slot] = nil end end
    end
    env.TradeFrame_GetAvailableSlot = function() if env.__tradeSlots >= 6 then return nil end; env.__tradeSlots = env.__tradeSlots + 1; return env.__tradeSlots end
    env.ClickTradeButton = function() env.__cursor = nil end   -- item moves into the trade window
    env.SlashCmdList = {}
    env.StaticPopupDialogs = {}
    env.StaticPopup_Show = function() return newFrame() end
    env.StaticPopup_Hide = function() end
    env.PlaySound = function() end
    env.IsInInstance = function() return false, "none" end
    env.GetInstanceInfo = function() return "none", "none" end
    env.InCombatLockdown = function() return false end

    -- ---- LibStub + libs (AceComm fake routes to the shared WIRE) ----
    local libs = {}
    local aceComm = {
        Embed = function(_, target)
            target.SendCommMessage = function(_, prefix, msg, dist, tgt, prio)
                WIRE[#WIRE + 1] = { prefix = prefix, msg = msg, dist = dist, target = tgt, sender = playerName, prio = prio }
            end
            target.RegisterComm = function() end
        end,
    }
    libs["AceComm-3.0"] = aceComm
    libs["CallbackHandler-1.0"] = { New = function() return {} end }
    local LibStub = setmetatable({
        NewLibrary = function(_, name) libs[name] = libs[name] or {}; return libs[name] end,
        GetLibrary = function(_, name) return libs[name] end,
    }, { __call = function(_, name) return libs[name] end })
    env.LibStub = LibStub

    -- ---- load the addon files into this env ----
    local private = {}
    for _, file in ipairs(ADDON_FILES) do
        local chunk = assert(loadfile(file))
        setfenv(chunk, env)
        chunk("WeirdLoot", private)
    end

    if os.getenv("WLDEBUG") then
        env.DEFAULT_CHAT_FRAME = setmetatable({ AddMessage = function(_, m) io.stderr:write(tostring(m) .. "\n") end }, { __index = function() return function() end end })
    end
    local addon = env.WeirdLoot
    addon.InitializeUI = function() end       -- UI not loaded in the harness
    addon:PLAYER_LOGIN()
    if os.getenv("WLDEBUG") then env.WeirdLootDB.payoutDebug = true end

    -- ---- force the loot-authority + scan into a deterministic test state ----
    addon.roster = addon.roster or {}
    addon.roster.isLootMaster = isML
    addon.roster.lootMasterName = "Masterlooter"
    addon.lootCore:SetML("Masterlooter")
    addon.bagSettleAt = 0                     -- bags considered settled
    addon.db.autoRoll = true

    -- inject eligible bag counts directly (skip tooltip scraping)
    addon.__bag = {}                          -- itemId -> count (test-controlled)
    local function bagLinkCounts(self)
        local out = {}
        for id, n in pairs(self.__bag) do if n > 0 then out[linkFor(id)] = n end end
        return out
    end
    addon.BuildTradeableEpicCounts = bagLinkCounts
    addon.BuildBagSnapshot = bagLinkCounts
    addon.BuildManualScanCounts = bagLinkCounts

    -- give every responder a 'main' roster profile so resolution is pure roll (no status cut).
    -- Responses are keyed by normalized (lowercase) name; the real roster maps that back to a
    -- display name, so we capitalize here to mirror that (winners come out proper-cased).
    local function cap(s) return (tostring(s):gsub("^%l", string.upper)) end
    addon.GetRosterProfile = function(_, name) return { name = cap(name), className = "Warrior", specName = "Arms", status = "main" } end
    addon.GetAttendee = function(_, name) return { name = cap(name), className = "Warrior", specName = "Arms", status = "main" } end
    addon.GetAttendees = function() return {} end

    return { addon = addon, env = env, player = playerName }
end

-- ---------------------------------------------------------------------------
-- helpers to drive a world
-- ---------------------------------------------------------------------------
local function setBag(w, itemId, count) w.addon.__bag[itemId] = count end
local function bagUpdate(w) w.addon:OnBagUpdate() end

local function startSession(w)
    w.addon:StartLootSession()
end

local function lotsFor(w, itemId) return w.addon.lootCore:lotsForItem(itemId) end
local function openLot(w, itemId) return w.addon.lootCore:openLotForItem(itemId) end

local function owedCount(w)
    local n = 0
    local owed = w.addon.payout and w.addon.payout.db and w.addon.payout.db.owed or {}
    for _, entry in pairs(owed) do for _, it in ipairs(entry.items or {}) do n = n + (it.count or 0) end end
    return n
end

-- deliver the shared wire from one world to another (raider mirror). Sync-prefix traffic goes
-- straight to the WeirdSync channel (as AceComm's prefix dispatch would in-game), honouring
-- WHISPER targeting; live-roll traffic goes through OnCommReceived.
local function flushWireTo(target, fromSender)
    local msgs = WIRE; WIRE = {}
    for _, m in ipairs(msgs) do
        if m.sender ~= target.player then
            local sender = m.sender or fromSender or "Masterlooter"
            if m.prefix == target.addon.syncPrefix and target.addon.syncChannel then
                if m.dist ~= "WHISPER" or m.target == target.player then
                    target.addon.syncChannel:OnReceive(sender, m.msg)
                end
            else
                target.addon:OnCommReceived(m.prefix, m.msg, m.dist or "RAID", sender)
            end
        end
    end
end
local function clearWire() WIRE = {} end

-- canonical "what a client should see" view of the synced ledger: every lot the ML would
-- broadcast (resolved or live, not removed), as id|itemId|state|liveCount|responses|winners.
-- The ML reads its authoritative awards/LiveCount; a raider reads the fields it received.
local function syncView(w)
    local core = w.addon.lootCore
    local isML = w.addon:IsAuthorizedLootMaster()
    local rows = {}
    for _, lot in ipairs(core:All()) do
        local live = isML and core:LiveCount(lot.id) or (lot.count or 0)
        if (not lot.removed) and (lot.state == core.STATE.RESOLVED or live > 0) then
            local resp = {}
            for k, v in pairs(lot.responses or {}) do resp[#resp + 1] = k .. "=" .. v end
            table.sort(resp)
            local winners = {}
            if isML then
                for _, a in ipairs(lot.awards or {}) do if a.winner then winners[#winners + 1] = a.winner end end
            elseif lot.record then
                for _, win in ipairs(lot.record.winners or {}) do winners[#winners + 1] = win end
            end
            rows[#rows + 1] = table.concat({ lot.id, tostring(lot.itemId), lot.state, tostring(live),
                table.concat(resp, ","), table.concat(winners, ",") }, "|")
        end
    end
    table.sort(rows)
    return table.concat(rows, "\n")
end

-- deterministic, reproducible PRNG for the fuzz sequence (independent of any world's rng)
local function makeRng(seed)
    return function(m, n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        local r = seed / 2147483648
        if m and n then return m + math.floor(r * (n - m + 1)) end
        return r
    end
end

-- physical bag (drives TradeDeliver), distinct from the eligible-count model (drives reconcile)
local function putBag(w, bag, slot, id, count) w.env.__bags[bag][slot] = { id = id, count = count, link = linkFor(id) } end
local function fillBagsExcept(w)             -- occupy every empty slot so no split target exists
    for b = 0, 4 do local B = w.env.__bags[b]; for s = 1, B.size do if not B[s] then B[s] = { id = 99999, count = 1, link = linkFor(99999) } end end end
end
local function fireEvent(w, event, arg1, arg2)
    local fr = w.addon.payout and w.addon.payout.frame
    local fn = fr and fr.__scripts and fr.__scripts.OnEvent
    if fn then fn(fr, event, arg1, arg2) end
end
local function pump(w, dt) for f, fn in pairs(w.env.__onUpdates) do fn(f, dt or 1.0) end end
local function setPartner(w, name) w.env.__tradePartner = name; w.env.__tradeSlots = 0 end

-- full trade sequence the engine reacts to: partner opens trade -> (bag updates for any splits)
-- -> settle timer fires the fill -> the trade completes.
local function runTrade(w, partner)
    setPartner(w, partner)
    fireEvent(w, "TRADE_SHOW")
    for b = 0, 4 do fireEvent(w, "BAG_UPDATE", b) end   -- satisfy any split's wait
    pump(w, 1.0)                                         -- SETTLE/FALLBACK -> finalize + place
    fireEvent(w, "UI_INFO_MESSAGE", w.env.ERR_TRADE_COMPLETE)
end

-- a manual hand-trade: partner opens, the ML drags the item in itself (no auto-fill), both accept,
-- the trade completes. Mirrors what happens when the ML trades an owed item by hand.
local function runManualTrade(w, partner, itemId, count)
    setPartner(w, partner)
    fireEvent(w, "TRADE_SHOW")
    w.env.__tradePlaced = { { id = itemId, count = count or 1 } }
    fireEvent(w, "TRADE_ACCEPT_UPDATE", 1, 1)
    fireEvent(w, "UI_INFO_MESSAGE", w.env.ERR_TRADE_COMPLETE)
    w.env.__tradePlaced = {}
end

-- resolve a single-copy lot to a non-ML winner and return its lot id (commonly-needed setup)
local function resolveOwedTo(w, itemId, winner)
    setBag(w, itemId, 1); bagUpdate(w)
    local lot = openLot(w, itemId)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, winner, "ms")
    w.addon:ResolveLiveRoll(lot.id)
    return lot.id
end

-- ===========================================================================
-- BATTERY
-- ===========================================================================

test("core self-checks (in-harness)", function()
    local w = makeWorld("Masterlooter", true)
    check(w.addon.LootCore.RunSelfChecks(false), "all core self-checks pass")
end)

test("session start baselines existing loot as idle (no auto-roll)", function()
    local w = makeWorld("Masterlooter", true)
    setBag(w, 40001, 1)             -- already carrying one before the session
    startSession(w)
    local lot = openLot(w, 40001)
    check(lot ~= nil, "baseline lot minted")
    eq(lot and lot.state, "idle", "pre-existing loot is idle, not surfaced")
    check(w.addon.lootCore:State(lot.id) ~= "pending", "not auto-surfaced")
end)

test("fresh drop mints a NEW lot and auto-surfaces (pending)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40002, 1)
    bagUpdate(w)
    local lot = openLot(w, 40002)
    check(lot ~= nil, "fresh lot minted")
    eq(lot and lot.state, "pending", "fresh drop auto-surfaced to pending")
    eq(#w.addon.session.items, 1, "projection has one item")
    eq(w.addon.session.items[1].itemId, 40002, "projection itemId from link")
end)

test("pre-roll duplicate grows the open lot (one row, quantity 2)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40002, 1); bagUpdate(w)
    setBag(w, 40002, 2); bagUpdate(w)
    eq(#lotsFor(w, 40002), 1, "still a single lot")
    eq(openLot(w, 40002).count, 2, "lot count grew to 2")
    eq(w.addon.session.items[1].quantity, 2, "projection quantity 2")
end)

test("live roll: single copy, two rollers -> one owed winner + payout", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    eq(w.addon.lootCore:State(lot.id), "rolling", "lot is rolling")
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:RegisterInterest(lot.id, "Bob", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    local L = w.addon.lootCore:Get(lot.id)
    eq(L.state, "resolved", "lot resolved")
    eq(#L.awards, 1, "one award for a 1x lot")
    eq(L.awards[1].state, "owed", "winner is owed (non-ML)")
    check(L.awards[1].winner == "Alice" or L.awards[1].winner == "Bob", "winner is one of the rollers")
    eq(owedCount(w), 1, "payout owes exactly one item")
end)

test("top-N: 2x drop, 3 rollers -> 2 distinct owed winners", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40004, 2); bagUpdate(w)
    local lot = openLot(w, 40004)
    eq(lot.count, 2, "lot count 2")
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:RegisterInterest(lot.id, "Bob", "ms")
    w.addon:RegisterInterest(lot.id, "Cara", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    local L = w.addon.lootCore:Get(lot.id)
    eq(#L.awards, 2, "two awards")
    eq(L.awards[1].state, "owed", "award 1 owed")
    eq(L.awards[2].state, "owed", "award 2 owed")
    local a, b = L.awards[1].winner, L.awards[2].winner
    check(a ~= b, "the two winners are distinct")
    local pool = { Alice = true, Bob = true, Cara = true }
    check(pool[a] and pool[b], "both winners are rollers")
    eq(owedCount(w), 2, "payout owes two items")
end)

test("top-N surplus: 2x drop, 1 roller -> 1 owed + 1 no-winner kept", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40004, 2); bagUpdate(w)
    local lot = openLot(w, 40004)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    local L = w.addon.lootCore:Get(lot.id)
    eq(#L.awards, 2, "two awards")
    eq(L.awards[1].winner, "Alice", "the sole roller wins one")
    eq(L.awards[1].state, "owed", "that copy is owed")
    eq(L.awards[2].winner, nil, "surplus copy has no winner")
    eq(L.awards[2].state, "resolved", "ML keeps the surplus copy")
    eq(owedCount(w), 1, "payout owes only the won copy")
end)

test("self-win stays resolved, not owed (no payout)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40003, 1); bagUpdate(w)
    local lot = openLot(w, 40003)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Masterlooter", "ms")  -- the ML rolls and is the only roller
    w.addon:ResolveLiveRoll(lot.id)
    local L = w.addon.lootCore:Get(lot.id)
    eq(L.awards[1].winner, "Masterlooter", "ML won")
    eq(L.awards[1].state, "resolved", "self-win is resolved, not owed")
    eq(owedCount(w), 0, "no payout owed for self-win")
end)

test("stale-roll regression: re-drop after resolve is a fresh lot, no bleed", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40001, 1); bagUpdate(w)
    local lot1 = openLot(w, 40001)
    w.addon:StartLiveRoll(lot1.id)
    w.addon:RegisterInterest(lot1.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot1.id)
    local first = w.addon.lootCore:Get(lot1.id)
    eq(first.state, "resolved", "first lot resolved")
    local firstWinner = first.awards[1].winner
    -- winner keeps it; a NEW identical copy drops (bag now shows 2 of the item)
    setBag(w, 40001, 2); bagUpdate(w)
    eq(#lotsFor(w, 40001), 2, "a NEW lot is minted, not the resolved one reused")
    local fresh = openLot(w, 40001)
    check(fresh.id ~= lot1.id, "fresh lot has a new id")
    eq(next(fresh.responses), nil, "fresh lot has empty responses (no stale bleed)")
    eq(w.addon.lootCore:Get(lot1.id).awards[1].winner, firstWinner, "original award is untouched")
end)

test("unlock retracts the owe (payout forgive)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    eq(owedCount(w), 1, "owed before unlock")
    w.addon.lootCore:Unlock(lot.id)
    eq(owedCount(w), 0, "unlock forgave the owe")
    eq(w.addon.lootCore:State(lot.id), "idle", "lot back to idle for reroll")
end)

test("delivery records per-copy disposition", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:RegisterInterest(lot.id, "Alice", "ms")
    w.addon:ResolveLiveRoll(lot.id)
    local ok = w.addon.lootCore:MarkDeliveredFor("Alice", 40005, CLOCK)
    check(ok, "MarkDeliveredFor succeeded")
    eq(w.addon.lootCore:Get(lot.id).awards[1].state, "delivered", "award marked delivered")
    eq(w.addon.lootCore:Get(lot.id).awards[1].recipient, "Alice", "recipient recorded")
end)

test("expired trade window: a re-scan drops a now-untradeable item still sitting in bags", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    eq(w.addon.lootCore:LiveCount(lot.id), 1, "tradeable initially")
    -- the 2h window expires: the item is still in bags but the scan no longer counts it, and NO
    -- bag event fires. The periodic / on-open reconcile must drop it.
    setBag(w, 40005, 0)
    w.addon:ReconcileLootNow()
    eq(w.addon.lootCore:LiveCount(lot.id), 0, "re-scan retired the expired item from the eligible set")
end)

test("Start Roll refuses an item whose every copy's trade window expired (not broadcast)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    setBag(w, 40005, 0)                          -- window expired, no bag event
    w.addon:StartLiveRoll(lot.id)                -- must reconcile + refuse
    check(w.addon.lootCore:State(lot.id) ~= "rolling", "expired item was not put up for roll")
    eq(w.addon.lootCore:LiveCount(lot.id), 0, "expired item retired, not rolled")
end)

test("Start Roll respects per-copy windows: rolls the tradeable copy when a duplicate expired", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 2); bagUpdate(w)            -- two copies, both tradeable
    local lot = openLot(w, 40005)
    eq(lot.count, 2, "lot has both copies")
    setBag(w, 40005, 1)                          -- ONE window expires (no bag event), one still good
    w.addon:StartLiveRoll(lot.id)                -- reconcile shrinks to 1, then rolls it
    eq(w.addon.lootCore:State(lot.id), "rolling", "still rolls: a tradeable copy remains")
    eq(w.addon.lootCore:LiveCount(lot.id), 1, "rolls only the still-tradeable copy")
end)

test("reconcile retire: item leaves bags -> lot retired", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40002, 1); bagUpdate(w)
    local lot = openLot(w, 40002)
    check(w.addon.lootCore:State(lot.id) ~= nil, "lot exists")
    setBag(w, 40002, 0); bagUpdate(w)
    eq(w.addon.lootCore:LiveCount(lot.id), 0, "lot retired when item left bags")
end)

test("itemId identity: two different links, same itemId, collapse to one lot", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    -- two bag entries that resolve to the same itemId via different link strings
    w.addon.BuildTradeableEpicCounts = function()
        return {
            ["|cffa335ee|Hitem:40001:0:0:0|h[Mantle]|h|r"] = 1,
            ["|cffFFFFFF|Hitem:40001:5:0:0|h[Mantle of the Bear]|h|r"] = 1,
        }
    end
    bagUpdate(w)
    eq(#lotsFor(w, 40001), 1, "one lot for the shared itemId")
    eq(openLot(w, 40001).count, 2, "both copies counted into it")
end)

test("comm sync: ML snapshot mirrors onto a raider", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, 40004, 2); bagUpdate(ml)
    local lot = openLot(ml, 40004)
    ml.addon:StartLiveRoll(lot.id)
    ml.addon:RegisterInterest(lot.id, "Alice", "ms")
    ml.addon:RegisterInterest(lot.id, "Bob", "ms")
    ml.addon:ResolveLiveRoll(lot.id)
    -- force one clean full snapshot (AutoBroadcastSession is debounced on a frozen clock here)
    clearWire()
    ml.addon:BroadcastSession()
    flushWireTo(raider)
    local rl = raider.addon.lootCore:Get(lot.id)
    check(rl ~= nil, "raider mirrored the lot by id")
    eq(rl and rl.itemId, 40004, "raider lot itemId matches")
    eq(rl and rl.state, "resolved", "raider sees it resolved")
    eq(#raider.addon.session.results, 1, "raider results projection has the lot")
    local mlRes = ml.addon.session.results[1]
    local rRes = raider.addon.session.results[1]
    eq(rRes.winnersText, mlRes.winnersText, "raider winners match the ML's")
end)

test("raider pick whispers the ML and is applied", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, 40005, 1); bagUpdate(ml)
    local lot = openLot(ml, 40005)
    ml.addon:StartLiveRoll(lot.id)
    ml.addon:BroadcastSession()        -- raider first syncs the session (SNAP_BEGIN sets context), as on join
    flushWireTo(raider)                -- raider gets the DROP + delta + full snapshot
    -- raider records a loot-tab response -> routed to ML as a SELECTION whisper
    raider.addon:SetPlayerResponse(lot.id, "Raidertwo", "ms")
    flushWireTo(ml)                     -- ML receives the SELECTION
    local L = ml.addon.lootCore:Get(lot.id)
    check(L.responses["raidertwo"] ~= nil, "ML recorded the raider's pick on the lot")
end)

test("delta sync: a single change sends a LOTD delta, not a full snapshot", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, 40006, 1); bagUpdate(ml)
    local lot = openLot(ml, 40006)
    ml.addon:BroadcastSession()          -- baseline: full snapshot
    flushWireTo(raider)
    check(raider.addon.lootCore:Get(lot.id) ~= nil, "raider has the lot after baseline snapshot")

    -- a single state change must delta-sync (D), never a full snapshot (SB) burst
    clearWire()
    ml.addon:StartLiveRoll(lot.id)
    local SEP = string.char(30)
    local snaps, deltas = 0, 0
    for _, m in ipairs(WIRE) do
        local cmd = string.match(m.msg, "^[^|" .. SEP .. "]+")
        if cmd == "SB" then snaps = snaps + 1 end
        if cmd == "D" then deltas = deltas + 1 end
    end
    eq(snaps, 0, "no full snapshot emitted for a single change")
    check(deltas >= 1, "a delta (D) was sent")

    flushWireTo(raider)
    eq(raider.addon.lootCore:Get(lot.id).state, "rolling", "raider mirrored the delta (now rolling)")
end)

test("delta fuzz: a delta-synced raider always equals the ML across random operations", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    ml.addon:BroadcastSession(); flushWireTo(raider)      -- initial baseline
    local rng = makeRng(20260619)
    local items = { 40001, 40002, 40003, 40004, 40050, 40051 }
    local players = { "Alice", "Bob", "Cara", "Dan", "Eve", "Finn" }
    local tiers = { "bis", "ms", "mu", "os", "tm", "pass" }
    local bag = {}

    local function lotsByState(stateSet)
        local out = {}
        for _, lot in ipairs(ml.addon.lootCore:All()) do
            if stateSet[lot.state] and not lot.removed then out[#out + 1] = lot end
        end
        return out
    end
    local function pick(t) return #t > 0 and t[rng(1, #t)] or nil end

    local mismatch = nil
    for step = 1, 200 do
        local op = rng(1, 100)
        if op <= 32 then                                  -- drop / grow an item
            local id = items[rng(1, #items)]
            bag[id] = (bag[id] or 0) + 1
            setBag(ml, id, bag[id]); bagUpdate(ml)
        elseif op <= 45 then                              -- an item leaves bags (retire)
            local id = items[rng(1, #items)]
            if (bag[id] or 0) > 0 then bag[id] = bag[id] - 1; setBag(ml, id, bag[id]); bagUpdate(ml) end
        elseif op <= 60 then                              -- start a roll on a pending lot
            local lot = pick(lotsByState({ pending = true }))
            if lot then ml.addon:StartLiveRoll(lot.id) end
        elseif op <= 84 then                              -- a player responds on an open lot
            local lot = pick(lotsByState({ rolling = true, pending = true, idle = true, new = true }))
            if lot then ml.addon:SetPlayerResponse(lot.id, players[rng(1, #players)], tiers[rng(1, #tiers)]) end
        elseif op <= 94 then                              -- resolve a rolling lot
            local lot = pick(lotsByState({ rolling = true }))
            if lot then ml.addon:ResolveLiveRoll(lot.id) end
        else                                              -- unlock all resolved lots
            if #ml.addon.lootCore:Resolved() > 0 then ml.addon:UnlockAllRolls() end
        end

        ml.addon:AutoBroadcastSession()                   -- flush coalesced response dirty for the compare
        flushWireTo(raider)                               -- deliver whatever deltas/snapshots resulted
        flushWireTo(ml)                                   -- deliver any raider->ML traffic (resync requests)
        flushWireTo(raider)                               -- and any snapshot that produced
        if syncView(ml) ~= syncView(raider) then
            mismatch = string.format("step %d (op=%d)\n--- ML ---\n%s\n--- raider ---\n%s",
                step, op, syncView(ml), syncView(raider))
            break
        end
    end
    check(mismatch == nil, "raider matched ML at every step" .. (mismatch and ("\n" .. mismatch) or ""))
end)

test("rejoin mid-roll: raider restores the roll popup with the ML's remaining time", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, 40005, 1); bagUpdate(ml)
    local lot = openLot(ml, 40005)
    ml.addon:StartLiveRoll(lot.id)                 -- ML rolls; deadline = now + 20s
    local mlRoll = ml.addon.live.rolls[lot.id]
    check(mlRoll and mlRoll.deadline, "ML recorded a roll deadline")

    CLOCK = CLOCK + 6                              -- 6s elapse on the ML's roll (14s left)
    clearWire()
    ml.addon:BroadcastSession()                   -- a freshly-reloaded raider pulls the full snapshot
    flushWireTo(raider)

    local rr = raider.addon.live.rolls[lot.id]
    check(rr ~= nil, "raider restored a roll record for the rolling lot")
    check(raider.addon:HasOpenRollForLot(lot.id), "raider has an open roll popup")
    local remaining = rr and rr.deadline and (rr.deadline - CLOCK) or nil
    check(remaining ~= nil and remaining >= 13.5 and remaining <= 14.5,
        "restored countdown reflects the ML's remaining ~14s, not a fresh 20s (got " .. tostring(remaining) .. ")")
end)

test("a raider requesting sync from a session-less ML gets no phantom session", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)        -- authorized ML, but no session started
    local raider = makeWorld("Raidertwo", false)
    raider.addon:RequestSessionSync()                 -- raider asks
    flushWireTo(ml)                                    -- ML answers with an empty snapshot (epoch "")
    flushWireTo(raider)                                -- raider applies it
    eq(raider.addon.session.active, false, "raider stays session-less (empty epoch -> not active)")
    eq(#raider.addon.lootCore:All(), 0, "no lots fabricated")
end)

test("delta sync: a dropped delta is detected via rev gap and auto-resynced", function()
    clearWire()
    local ml = makeWorld("Masterlooter", true)
    local raider = makeWorld("Raidertwo", false)
    startSession(ml)
    setBag(ml, 40001, 1); bagUpdate(ml)
    local lot = openLot(ml, 40001)
    ml.addon:BroadcastSession(); flushWireTo(raider)      -- baseline; raider lastRev set
    eq(syncView(raider), syncView(ml), "synced at baseline")

    ml.addon:StartLiveRoll(lot.id)
    clearWire()                                           -- DROP this delta (simulate a lost LOTD)
    ml.addon:SetPlayerResponse(lot.id, "Alice", "ms")     -- recorded locally (coalesced, not broadcast)
    ml.addon:ResolveLiveRoll(lot.id)                      -- a state change -> a delta with a rev gap
    flushWireTo(raider)                                   -- raider sees the gap, requests a full resync
    check(raider.addon.syncChannel.pendingRequest ~= nil, "raider flagged a resync after the gap")
    flushWireTo(ml)                                       -- ML answers the sync request with a targeted snapshot
    flushWireTo(raider)                                   -- raider applies it
    eq(syncView(raider), syncView(ml), "raider converged to ML truth after gap + resync")
end)

-- ===========================================================================
-- TRADE ENGINE (drives the real TradeDeliver fill/complete machinery)
-- ===========================================================================

test("trade engine: owed player trades -> item delivered, disposition recorded", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    eq(owedCount(w), 1, "Alice owed 1")
    putBag(w, 0, 1, 40005, 1)                  -- the won item sits in the ML's bags
    w.addon.payout:StartPayout()
    runTrade(w, "Alice")
    eq(owedCount(w), 0, "owe cleared after the trade completes")
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "delivered", "award delivered through the engine")
    eq(w.addon.lootCore:Get(lotId).awards[1].recipient, "Alice", "recipient recorded")
end)

test("manual hand-trade of an owed item records the delivery (not just auto-fill)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")     -- Alice owed 1x 40005 from a resolved roll
    eq(owedCount(w), 1, "owed before the hand-trade")
    runManualTrade(w, "Alice", 40005, 1)               -- ML drags the item in by hand (no StartPayout)
    eq(owedCount(w), 0, "owe cleared by the hand-trade")
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "delivered", "core recorded the award delivered")
    eq(w.addon.lootCore:Get(lotId).awards[1].recipient, "Alice", "recipient recorded")
end)

test("manual hand-trade of a NON-owed item delivers nothing (no phantom)", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    resolveOwedTo(w, 40005, "Alice")                   -- Alice owed 40005
    runManualTrade(w, "Alice", 40004, 1)               -- but we hand her a different item
    eq(owedCount(w), 1, "owe for 40005 untouched by trading an unrelated item")
end)

test("trade engine: short stock delivers what it can, rest stays owed", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Alice", 40005, 2, linkFor(40005))   -- owed 2
    putBag(w, 0, 1, 40005, 1)                                -- only 1 in bags
    w.addon.payout:StartPayout()
    runTrade(w, "Alice")
    eq(owedCount(w), 1, "1 of 2 delivered; 1 still owed")
end)

test("trade engine: more than 6 owed items cap at one trade's 6 slots", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    for i = 1, 7 do
        w.addon.payout:Owe("Alice", 41000 + i, 1, linkFor(41000 + i))
        putBag(w, 0, i, 41000 + i, 1)
    end
    eq(owedCount(w), 7, "7 owed up front")
    w.addon.payout:StartPayout()
    runTrade(w, "Alice")
    eq(owedCount(w), 1, "6 delivered this trade, 1 remains (slot cap)")
end)

test("trade engine: full bags block a required split; item stays owed", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Alice", 40005, 1, linkFor(40005))   -- owed 1
    putBag(w, 0, 1, 40005, 3)                                -- only a stack of 3 (a split is needed)
    fillBagsExcept(w)                                         -- no free slot to split into
    w.addon.payout:StartPayout()
    runTrade(w, "Alice")
    eq(owedCount(w), 1, "couldn't split into full bags -> nothing delivered, still owed")
end)

test("trade engine: split delivery works when a free slot exists", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Alice", 40005, 1, linkFor(40005))   -- owed 1
    putBag(w, 0, 1, 40005, 3)                                -- a stack of 3, free slots available
    w.addon.payout:StartPayout()
    runTrade(w, "Alice")
    eq(owedCount(w), 0, "split off 1 and delivered it")
end)

test("trade engine: declines a non-owed player's trade during payout", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    w.addon.payout:Owe("Alice", 40005, 1, linkFor(40005))   -- someone is owed
    w.addon.payout:StartPayout()
    setPartner(w, "Bob")                                     -- Bob is NOT owed
    fireEvent(w, "TRADE_SHOW")
    check(w.env.__closeTrade >= 1, "non-owed trade declined (CloseTrade called)")
    eq(owedCount(w), 1, "Alice still owed; nothing handed to Bob")
end)

-- ===========================================================================
-- ADVERSARIAL / FAILURE-MODE cases (where things break, by design or as a known gap)
-- ===========================================================================

test("trade in progress: an owed copy leaving bags is protected; delivery is recorded", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    -- a payout trade window is open (the ML is handing the item to Alice)
    w.addon.payout.tradeOpen = true
    -- BAG_UPDATE reconciles BEFORE the trade-complete callback (the old race order)
    setBag(w, 40005, 0); bagUpdate(w)
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "owed", "owed copy NOT written off while a trade is open")
    check(w.addon.lootCore:MarkDeliveredFor("Alice", 40005), "trade-complete still records the delivery")
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "delivered", "copy recorded delivered, not removed")
end)

test("no trade open: an owed copy genuinely leaving bags is recorded removed", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    -- no trade window: the item really left (destroyed / mailed), so removal is correct
    setBag(w, 40005, 0); bagUpdate(w)
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "removed", "with no trade open, the copy is removed")
end)

test("guard: a response on a resolved lot is rejected", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    check(not w.addon.lootCore:SetResponse(lotId, "bob", "ms"), "core refuses to mutate a resolved lot")
end)

test("guard: a rolling lot is never retired on a mid-roll bag-count drop", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40004, 2); bagUpdate(w)
    local lot = openLot(w, 40004)
    w.addon:StartLiveRoll(lot.id)                 -- count 2, rolling
    setBag(w, 40004, 1); bagUpdate(w)             -- a copy leaves mid-roll
    eq(w.addon.lootCore:State(lot.id), "rolling", "still rolling, not retired")
    eq(w.addon.lootCore:Get(lot.id).count, 2, "count not shrunk under an active roll")
end)

test("guard: MarkDeliveredFor with the wrong player or item is a no-op", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    check(not w.addon.lootCore:MarkDeliveredFor("Nobody", 40005), "wrong player -> false")
    check(not w.addon.lootCore:MarkDeliveredFor("Alice", 99999), "wrong item -> false")
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "owed", "award still owed")
end)

test("guard: reconcile retires an un-rolled copy before an owed one", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")   -- owed copy held in bags
    setBag(w, 40005, 2); bagUpdate(w)                -- a fresh copy drops alongside it
    local fresh = openLot(w, 40005)
    check(fresh and fresh.id ~= lotId, "a separate fresh lot exists")
    setBag(w, 40005, 1); bagUpdate(w)                -- drop one: the un-rolled one should go
    eq(w.addon.lootCore:LiveCount(fresh.id), 0, "the un-rolled fresh copy was retired")
    eq(w.addon.lootCore:Get(lotId).awards[1].state, "owed", "the owed copy was preserved")
end)

test("guard: a stray snapshot line without an SB is ignored (no crash)", function()
    local w = makeWorld("Raidertwo", false)
    local SEP = string.char(30)
    -- an SE (snapshot entry) arriving with no preceding SB must be dropped, not staged.
    local stray = table.concat({ "SE", "L", "s", "L:1", "40005", "pending", "1" }, SEP)
    local ok = pcall(function() w.addon.syncChannel:OnReceive("Masterlooter", stray) end)
    check(ok, "stray snapshot line handled without error")
    eq(#w.addon.lootCore:All(), 0, "nothing staged into the ledger")
end)

test("guard: a roll with no responders resolves to no winner and no owe", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    setBag(w, 40005, 1); bagUpdate(w)
    local lot = openLot(w, 40005)
    w.addon:StartLiveRoll(lot.id)
    w.addon:ResolveLiveRoll(lot.id)                  -- nobody rolled
    eq(w.addon.lootCore:Get(lot.id).awards[1].winner, nil, "no winner")
    eq(w.addon.lootCore:Get(lot.id).awards[1].state, "resolved", "ML keeps it")
    eq(owedCount(w), 0, "no owe created")
end)

test("guard: unlock + reroll retracts the owe and re-creates it for the new winner", function()
    local w = makeWorld("Masterlooter", true)
    startSession(w)
    local lotId = resolveOwedTo(w, 40005, "Alice")
    eq(owedCount(w), 1, "owed after first resolve")
    w.addon.lootCore:Unlock(lotId)
    eq(owedCount(w), 0, "owe retracted on unlock")
    w.addon:StartLiveRoll(lotId)
    w.addon:RegisterInterest(lotId, "Bob", "ms")
    w.addon:ResolveLiveRoll(lotId)
    eq(owedCount(w), 1, "re-owed after reroll")
end)

-- ===========================================================================
-- 25-man message-load report (opt-in: WLLOAD=1). Reveals the real outgoing message
-- count/bytes of a full raid loot session WITHOUT testing in-game, by tallying the mocked
-- wire and modelling ChatThrottleLib (MAX_CPS=800, 40B/msg overhead, 245B chunk size).
-- ===========================================================================
local function loadReport()
    local PREFIX = "WeirdLoot"
    local MAXLEN, CPS, OVERHEAD = 254 - #PREFIX, 800, 40

    -- summarize WIRE (and clear it): logical msgs, physical chunks, CTL bytes, drain seconds.
    local function drain(label)
        local byCmd, byPrio = {}, { ALERT = 0, BULK = 0 }
        local logical, chunks, bytes = 0, 0, 0
        for _, m in ipairs(WIRE) do
            local cmd = string.match(m.msg, "^[^|" .. string.char(30) .. "]+") or "?"
            byCmd[cmd] = (byCmd[cmd] or 0) + 1
            local prio = m.prio or "BULK"
            byPrio[prio] = (byPrio[prio] or 0) + 1
            local c = math.max(1, math.ceil(#m.msg / MAXLEN))
            logical = logical + 1; chunks = chunks + c; bytes = bytes + #m.msg + c * OVERHEAD
        end
        WIRE = {}
        return { label = label, logical = logical, chunks = chunks, bytes = bytes,
                 secs = bytes / CPS, byCmd = byCmd, byPrio = byPrio }
    end
    local function line(r)
        local parts = {}
        for k, v in pairs(r.byCmd) do parts[#parts + 1] = k .. ":" .. v end
        table.sort(parts)
        return string.format("  %-22s %4d msg  %4d chunks  %6dB  %5.1fs drain  [A:%d B:%d]  %s",
            r.label, r.logical, r.chunks, r.bytes, r.secs, r.byPrio.ALERT or 0, r.byPrio.BULK or 0, table.concat(parts, " "))
    end

    local ml = makeWorld("Masterlooter", true)
    startSession(ml)
    local attendees = {}
    for i = 1, 25 do attendees[i] = { name = "Raider" .. i, className = "Warrior", specName = "Arms", status = "main" } end
    ml.addon.session.attendees = attendees
    ml.addon.GetAttendees = function() return attendees end

    print("")
    print("=== 25-man comm load report (delta sync) ===")

    -- cost of ONE full snapshot at this roster size (the old per-change unit)
    clearWire(); ml.addon:BroadcastSession()
    print(line(drain("one full snapshot")))

    -- representative single operations (delta path)
    clearWire(); setBag(ml, 40001, 1); bagUpdate(ml)
    print(line(drain("one fresh drop")))
    local lot = openLot(ml, 40001)
    clearWire(); ml.addon:StartLiveRoll(lot.id)
    print(line(drain("one Start Roll")))
    clearWire(); ml.addon:SetPlayerResponse(lot.id, "Raider5", "ms")
    print(line(drain("one raider response")))
    clearWire(); ml.addon:ResolveLiveRoll(lot.id)
    print(line(drain("one resolve")))

    -- a full session: 12 items (2 of them x2), each rolled by 12 of 25 raiders
    clearWire()
    local items = { 40001, 40002, 40003, 40004, 40005, 40006, 40007, 40008, 40009, 40010, 40011, 40012 }
    for idx, id in ipairs(items) do
        local qty = (idx <= 2) and 2 or 1
        setBag(ml, id, qty); bagUpdate(ml)
        local lt = openLot(ml, id)
        if lt then
            ml.addon:StartLiveRoll(lt.id)
            for r = 1, 12 do ml.addon:SetPlayerResponse(lt.id, "Raider" .. r, (r % 5 == 0) and "bis" or "ms") end
            ml.addon:ResolveLiveRoll(lt.id)
        end
    end
    local sess = drain("full session (12 items)")
    print(line(sess))
    print(string.format("  -> old model (full snapshot per change) would be ~%d state-changes x one-snapshot.",
        12 * 3))
    print("")
end
if os.getenv("WLLOAD") then loadReport() end

-- ===========================================================================
print("")
print(string.format("=== WeirdLoot battery: %d passed, %d failed ===", pass, fail))
if fail > 0 then
    print("FAILURES:")
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
end
