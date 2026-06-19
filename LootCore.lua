-- LootCore: the single owner of loot identity, group-roll responses, top-N resolution, and
-- per-copy disposition. See LOOTCORE_DESIGN.md for rationale. This module is intentionally
-- pure: no frames, no SendCommMessage, no GetContainerItemInfo. Consumers feed it counts and
-- read its projections by stable id. That boundary is the whole point.
--
-- Identity is the numeric ITEM ID, never the link or name. Item links embed a localized name
-- and client-specific data, so the same item can present different links/names across clients.
-- The caller parses the itemId out of the bag link and feeds counts keyed by itemId; the core
-- stores only itemId. Consumers render name/link/icon on demand from itemId (GetItemInfo), and
-- sync carries itemId so every client renders its own localized name.
--
-- Distribution model (decided): ONE roll per item, top-N winners (upstream's UX). A Lot is the
-- rollable unit (one per itemId group, holding the single group-level response set under a
-- stable id), and on Resolve the resolver's ordered winners are frozen onto per-copy AWARDS
-- that each track their own delivery.
--
-- Step 1 (this file): the standalone core plus self-checks. No consumer is wired in yet.
-- Winner-picking is delegated through an injected resolver so the core has zero dependency on
-- the rest of the addon and can be verified with a plain Lua interpreter.

local addonName, addon = ...
if type(addon) ~= "table" then addon = WeirdLoot or {} end

local LootCore = {}

-- Lot states. A lot is "open" (can still absorb new copies / be surfaced) while in
-- new/idle/pending/skipped; rolling and resolved are committed.
local STATE = {
    NEW      = "new",      -- fresh loot this session; auto-surfaced to the ML
    IDLE     = "idle",     -- present but not fresh (or unlocked); listed, not auto-surfaced
    PENDING  = "pending",  -- a Start Roll / Skip popup is up
    ROLLING  = "rolling",  -- broadcast to the raid, collecting responses
    RESOLVED = "resolved", -- rolled; awards frozen (each award then disposes independently)
    SKIPPED  = "skipped",  -- ML dismissed; resurfaces next pass (a snooze, not a decision)
}
-- Per-copy award (disposition) states, set at resolve and after.
local AWARD = {
    OWED      = "owed",      -- won by a non-ML player, awaiting delivery
    RESOLVED  = "resolved",  -- self-win or no-winner: ML already holds this copy
    DELIVERED = "delivered", -- terminal: traded to recipient, recorded
    REMOVED   = "removed",   -- terminal: left bags with no delivery reported
}
LootCore.STATE = STATE
LootCore.AWARD = AWARD

local function isOpen(lot)
    return not lot.removed and (lot.state == STATE.NEW or lot.state == STATE.IDLE
        or lot.state == STATE.PENDING or lot.state == STATE.SKIPPED)
end

local function awardIsLive(a)
    return a.state == AWARD.OWED or a.state == AWARD.RESOLVED
end

-- How many physical copies of this lot are still in the ML's bags (live).
local function liveCount(lot)
    if lot.removed then return 0 end
    if lot.awards then
        local n = 0
        for i = 1, #lot.awards do if awardIsLive(lot.awards[i]) then n = n + 1 end end
        return n
    end
    return lot.count or 0
end

local function lotLive(lot)
    return not lot.removed and liveCount(lot) > 0
end

local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepcopy(v) end
    return out
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
function LootCore.New()
    local self = setmetatable({}, { __index = LootCore })
    self.lots = {}       -- id -> Lot (the authoritative map)
    self.order = {}      -- array of lot ids in mint order (drives List/Log ordering)
    self.seq = 0         -- monotonic; lot ids come from here and are NEVER reused
    self.handlers = {}   -- event name -> array of callbacks
    self._resolver = nil -- injected: function(lot) -> { winners = {orderedKeys}, ... }
    self._mlKey = nil    -- normalized key of the master looter
    return self
end

-- wiring set by consumers (kept out of the core's logic so it stays pure)
function LootCore:SetResolver(fn) self._resolver = fn end
function LootCore:SetML(playerKey) self._mlKey = playerKey end
function LootCore:IsML(playerKey) return self._mlKey ~= nil and playerKey == self._mlKey end

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
function LootCore:On(event, handler)
    local list = self.handlers[event]
    if not list then list = {}; self.handlers[event] = list end
    list[#list + 1] = handler
end

function LootCore:emit(event, ...)
    local list = self.handlers[event]
    if not list then return end
    for i = 1, #list do list[i](...) end
end

-- ---------------------------------------------------------------------------
-- internal helpers (everything keyed by numeric itemId)
-- ---------------------------------------------------------------------------
local function readEligible(entry)
    -- an eligible entry is either a bare count or { count = N }.
    if type(entry) == "number" then return entry end
    if type(entry) == "table" then return entry.count or 0 end
    return 0
end

function LootCore:lotsForItem(itemId)
    local out = {}
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lot.itemId == itemId then out[#out + 1] = lot end
    end
    return out
end

function LootCore:openLotForItem(itemId)
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lot.itemId == itemId and isOpen(lot) then return lot end
    end
    return nil
end

function LootCore:liveCountForItem(itemId)
    local total = 0
    local lots = self:lotsForItem(itemId)
    for i = 1, #lots do total = total + liveCount(lots[i]) end
    return total
end

function LootCore:mint(itemId, count, fresh)
    self.seq = self.seq + 1
    local lot = {
        id = "L:" .. self.seq,
        itemId = itemId, -- the ONLY identity; name/link rendered on demand from this
        state = fresh and STATE.NEW or STATE.IDLE,
        count = count,
        responses = {},
        awards = nil,
        record = nil,
    }
    self.lots[lot.id] = lot
    self.order[#self.order + 1] = lot.id
    self:emit("lotAdded", lot)
    return lot
end

-- ---------------------------------------------------------------------------
-- reconciliation: bag reality -> ledger  [ML only]
--   eligible    : itemId -> count (or itemId -> { count = N })
--   freshLinks  : set of itemIds that just increased this bag delta (itemId -> true)
-- ---------------------------------------------------------------------------
function LootCore:Reconcile(eligible, freshLinks)
    eligible = eligible or {}
    freshLinks = freshLinks or {}
    local changed = false

    for itemId, entry in pairs(eligible) do
        if self:reconcileItem(itemId, readEligible(entry), freshLinks[itemId] and true or false) then
            changed = true
        end
    end

    -- items present in the ledger but no longer eligible at all -> drain to zero
    local seen = {}
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lotLive(lot) and not seen[lot.itemId] then
            seen[lot.itemId] = true
            if eligible[lot.itemId] == nil then
                if self:reconcileItem(lot.itemId, 0, false) then changed = true end
            end
        end
    end

    if changed then self:emit("ledgerChanged") end
end

function LootCore:reconcileItem(itemId, want, fresh)
    local live = self:liveCountForItem(itemId)
    if want == live then return false end

    if want > live then
        local diff = want - live
        local open = self:openLotForItem(itemId)
        if open and not open.awards then
            open.count = open.count + diff
            if fresh and open.state == STATE.SKIPPED then open.state = STATE.NEW end
        else
            self:mint(itemId, diff, fresh)
        end
        return true
    end

    -- want < live: copies left the bags. Retire least-committed first, never a rolling lot.
    self:retireFromItem(itemId, live - want)
    return true
end

-- Retire `n` live copies for an itemId, least-committed first:
--   open-lot copies (idle/new/skipped/pending) > resolved no-winner awards > owed awards.
-- A rolling lot is mid-decision and is never touched.
function LootCore:retireFromItem(itemId, n)
    local remaining = n

    -- 1. shrink the open lot's pre-roll count
    local open = self:openLotForItem(itemId)
    if open and not open.awards and remaining > 0 then
        local take = math.min(remaining, open.count)
        open.count = open.count - take
        remaining = remaining - take
        if open.count <= 0 then open.removed = true end
    end

    -- 2. retire awards from resolved lots: no-winner (ML's own) before owed
    if remaining > 0 then
        local live = {}
        local lots = self:lotsForItem(itemId)
        for _, lot in ipairs(lots) do
            if lot.awards then
                for _, a in ipairs(lot.awards) do
                    if awardIsLive(a) then live[#live + 1] = a end
                end
            end
        end
        table.sort(live, function(x, y)
            local rx = x.state == AWARD.RESOLVED and 1 or 2
            local ry = y.state == AWARD.RESOLVED and 1 or 2
            return rx < ry
        end)
        for i = 1, remaining do
            local a = live[i]
            if not a then break end
            a.state = AWARD.REMOVED -- left bags, disposition unknown
        end
    end
end

-- ---------------------------------------------------------------------------
-- lifecycle commands (ML)
-- ---------------------------------------------------------------------------
function LootCore:Surface(id)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state == STATE.NEW or lot.state == STATE.IDLE or lot.state == STATE.SKIPPED then
        lot.state = STATE.PENDING
        self:emit("ledgerChanged")
        return true
    end
    return false
end

function LootCore:Skip(id)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state == STATE.PENDING then
        lot.state = STATE.SKIPPED
        self:emit("ledgerChanged")
        return true
    end
    return false
end

function LootCore:StartRoll(id)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state == STATE.PENDING then
        lot.state = STATE.ROLLING
        lot.responses = {} -- a roll always starts from a clean slate for THIS lot
        self:emit("ledgerChanged")
        return true
    end
    return false
end

function LootCore:Cancel(id)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state == STATE.ROLLING then
        lot.state = STATE.PENDING
        self:emit("ledgerChanged")
        return true
    end
    return false
end

-- Record one player's response (opaque value; in the addon a tier string). Allowed on any
-- non-resolved lot so the loot tab can pre-seed responses before a live roll begins.
function LootCore:SetResponse(id, player, value)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state == STATE.RESOLVED or lot.removed then return false end
    lot.responses[player] = value
    return true
end

function LootCore:GetResponse(id, player)
    local lot = self.lots[id]; if not lot then return nil end
    return lot.responses[player]
end

-- Resolve delegates winner-picking to the injected resolver, handing it exactly THIS lot's
-- responses by stable id. The resolver returns an ORDERED winners list (top-N already applied
-- to the lot's count). The core freezes those onto per-copy awards.
function LootCore:Resolve(id)
    local lot = self.lots[id]; if not lot then return nil end
    local record = self._resolver and self._resolver(lot) or {}
    local winners = record.winners
    if not winners and record.winner then winners = { record.winner } end
    winners = winners or {}

    lot.record = record
    lot.awards = {}
    for i = 1, lot.count do
        local w = winners[i]
        local award = { winner = w or nil }
        if w and not self:IsML(w) then
            award.state = AWARD.OWED
        else
            award.state = AWARD.RESOLVED -- self-win or no winner: ML already holds it
        end
        lot.awards[i] = award
    end
    lot.state = STATE.RESOLVED
    self:emit("lotResolved", lot)
    self:emit("ledgerChanged")
    return record
end

-- resolved -> idle, dropping awards/responses so the lot can be re-rolled.
function LootCore:Unlock(id)
    local lot = self.lots[id]; if not lot then return false end
    if lot.state ~= STATE.RESOLVED then return false end
    local live = liveCount(lot)
    lot.state = STATE.IDLE
    lot.count = live > 0 and live or lot.count
    lot.awards = nil
    lot.responses = {}
    lot.record = nil
    self:emit("lotUnlocked", lot)
    self:emit("ledgerChanged")
    return true
end

function LootCore:UnlockAll()
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lot.state == STATE.RESOLVED then self:Unlock(lot.id) end
    end
end

-- Mark one owed award delivered. Low-level: by lot id + award index.
function LootCore:MarkDelivered(id, awardIndex, recipient, when)
    local lot = self.lots[id]; if not lot or not lot.awards then return false end
    local a = lot.awards[awardIndex]
    if not a or a.state ~= AWARD.OWED then return false end
    a.state = AWARD.DELIVERED
    a.recipient = recipient or a.winner
    a.deliveredAt = when
    self:emit("lotDelivered", lot, a)
    self:emit("ledgerChanged")
    return true
end

-- The path TradeDeliver uses: a trade to `player` for `itemId` completed. Marks the oldest
-- matching owed award delivered (FIFO over that player's owed copies of the item).
function LootCore:MarkDeliveredFor(player, itemId, when)
    for i = 1, #self.order do
        local lot = self.lots[self.order[i]]
        if lot and lot.awards and (itemId == nil or lot.itemId == itemId) then
            for idx = 1, #lot.awards do
                local a = lot.awards[idx]
                if a.state == AWARD.OWED and a.winner == player then
                    return self:MarkDelivered(lot.id, idx, player, when)
                end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------
function LootCore:Get(id) return self.lots[id] end
function LootCore:State(id) local l = self.lots[id]; return l and l.state or nil end
function LootCore:IsResolved(id) local l = self.lots[id]; return l ~= nil and l.state == STATE.RESOLVED end
function LootCore:LiveCount(id) local l = self.lots[id]; return l and liveCount(l) or 0 end

function LootCore:Surfaceable() -- lots awaiting the ML's Start Roll / Skip
    local out = {}
    for i = 1, #self.order do
        local l = self.lots[self.order[i]]
        if l and (l.state == STATE.NEW or l.state == STATE.SKIPPED) and lotLive(l) then
            out[#out + 1] = l
        end
    end
    return out
end

function LootCore:List() -- live lots, mint order (the loot-tab projection)
    local out = {}
    for i = 1, #self.order do
        local l = self.lots[self.order[i]]
        if l and lotLive(l) then out[#out + 1] = l end
    end
    return out
end

function LootCore:Resolved() -- lots that have been rolled (the results-tab projection)
    local out = {}
    for i = 1, #self.order do
        local l = self.lots[self.order[i]]
        if l and l.state == STATE.RESOLVED then out[#out + 1] = l end
    end
    return out
end

function LootCore:Log() return self:Resolved() end -- session loot history (awards carry disposition)

-- ---------------------------------------------------------------------------
-- sync (core owns the snapshot shape; Comm owns the wire)
-- ---------------------------------------------------------------------------
function LootCore:Serialize()
    local lots = {}
    for i = 1, #self.order do
        local l = self.lots[self.order[i]]
        if l then lots[#lots + 1] = deepcopy(l) end
    end
    return { seq = self.seq, lots = lots }
end

function LootCore:ApplyRemote(snapshot)
    self.lots = {}
    self.order = {}
    self.seq = snapshot and snapshot.seq or 0
    if snapshot and snapshot.lots then
        for i = 1, #snapshot.lots do
            local l = deepcopy(snapshot.lots[i])
            self.lots[l.id] = l
            self.order[#self.order + 1] = l.id
        end
    end
    self:emit("ledgerChanged")
end

-- ---------------------------------------------------------------------------
-- self-checks: exercise the design doc's walkthroughs and invariants with a plain
-- interpreter (luajit, 5.1 semantics). Run from the addon dir with:
--   luajit -e "local f=loadfile('LootCore.lua'); f('WeirdLoot', {}); WeirdLoot.LootCore.RunSelfChecks(true)"
-- Item ids below are arbitrary numbers standing in for parsed link itemIds.
-- ---------------------------------------------------------------------------
function LootCore.RunSelfChecks(verbose)
    local pass, fail = 0, 0
    local function ok(cond, label)
        if cond then pass = pass + 1; if verbose then print("  PASS " .. label) end
        else fail = fail + 1; print("  FAIL " .. label) end
    end
    -- fake resolver: active (non-pass) responses ranked by their numeric .roll, top `count` win.
    local function topN(lot)
        local ranked = {}
        for player, v in pairs(lot.responses) do
            if type(v) == "table" and v.tier ~= "pass" then ranked[#ranked + 1] = { player = player, roll = v.roll or 0 } end
        end
        table.sort(ranked, function(a, b) return a.roll > b.roll end)
        local winners = {}
        for i = 1, math.min(lot.count, #ranked) do winners[i] = ranked[i].player end
        return { winners = winners }
    end
    local function resp(t, r) return { tier = t, roll = r } end

    -- 1. mint: preexisting -> idle, fresh -> new
    do
        local c = LootCore.New()
        c:Reconcile({ [101] = 1 }, {})
        c:Reconcile({ [101] = 1, [102] = 1 }, { [102] = true })
        ok(c:openLotForItem(101).state == STATE.IDLE, "mint preexisting -> idle")
        ok(c:openLotForItem(102).state == STATE.NEW, "mint fresh -> new")
    end

    -- 2. a second copy before any roll GROWS the open lot (not a new lot)
    do
        local c = LootCore.New()
        c:Reconcile({ [200] = 1 }, { [200] = true })
        c:Reconcile({ [200] = 2 }, { [200] = true })
        ok(#c:lotsForItem(200) == 1, "pre-roll duplicate grows existing lot")
        ok(c:openLotForItem(200).count == 2, "open lot count == 2")
    end

    -- 3. a duplicate dropping AFTER the lot resolved mints a NEW lot (fresh id + responses)
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [300] = 1 }, { [300] = true })
        local first = c:openLotForItem(300)
        c:Surface(first.id); c:StartRoll(first.id)
        c:SetResponse(first.id, "ML", resp("ms", 50))
        c:Resolve(first.id)
        ok(c:State(first.id) == STATE.RESOLVED, "first lot resolved")
        c:Reconcile({ [300] = 2 }, { [300] = true }) -- one already-held + one fresh
        ok(#c:lotsForItem(300) == 2, "post-resolve duplicate mints a NEW lot")
        local newLot = c:openLotForItem(300)
        ok(newLot and newLot.id ~= first.id and newLot.state == STATE.NEW, "new lot is fresh with its own id")
        ok(next(newLot.responses) == nil, "new lot has empty responses (no bleed)")
    end

    -- 4. StartRoll clears responses for the lot
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [400] = 1 }, { [400] = true })
        local id = c:openLotForItem(400).id
        c:SetResponse(id, "Bob", resp("ms", 10)) -- pre-roll loot-tab response
        c:Surface(id); c:StartRoll(id)
        ok(next(c:Get(id).responses) == nil, "StartRoll clears prior responses")
    end

    -- 5. top-N resolve: 2 copies, 3 rollers -> top 2 win one each, 3rd gets nothing
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [500] = 2 }, { [500] = true })
        local id = c:openLotForItem(500).id
        ok(c:Get(id).count == 2, "lot count 2")
        c:Surface(id); c:StartRoll(id)
        c:SetResponse(id, "Bob", resp("ms", 90))
        c:SetResponse(id, "Amy", resp("ms", 70))
        c:SetResponse(id, "Cy", resp("ms", 30))
        c:Resolve(id)
        local lot = c:Get(id)
        ok(#lot.awards == 2, "two awards for a 2x lot")
        ok(lot.awards[1].winner == "Bob" and lot.awards[2].winner == "Amy", "top 2 distinct rollers win")
        ok(lot.awards[1].state == AWARD.OWED and lot.awards[2].state == AWARD.OWED, "non-ML wins are owed")
    end

    -- 6. fewer rollers than copies: surplus copies resolve with no winner (ML keeps them)
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [600] = 2 }, { [600] = true })
        local id = c:openLotForItem(600).id
        c:Surface(id); c:StartRoll(id)
        c:SetResponse(id, "Bob", resp("ms", 90))
        c:Resolve(id)
        local lot = c:Get(id)
        ok(lot.awards[1].winner == "Bob" and lot.awards[1].state == AWARD.OWED, "the roller wins one copy (owed)")
        ok(lot.awards[2].winner == nil and lot.awards[2].state == AWARD.RESOLVED, "surplus copy has no winner, ML holds it")
    end

    -- 7. self-win stays resolved; non-ML win delivers via FIFO helper; both in the log
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [700] = 1 }, { [700] = true })
        local id = c:openLotForItem(700).id
        c:Surface(id); c:StartRoll(id); c:SetResponse(id, "ML", resp("ms", 80)); c:Resolve(id)
        ok(c:Get(id).awards[1].state == AWARD.RESOLVED, "self-win stays resolved (ML holds it)")
        c:Reconcile({ [701] = 1 }, { [701] = true })
        local eid = c:openLotForItem(701).id
        c:Surface(eid); c:StartRoll(eid); c:SetResponse(eid, "Bob", resp("ms", 80)); c:Resolve(eid)
        ok(c:MarkDeliveredFor("Bob", 701), "MarkDeliveredFor marks the owed copy delivered")
        ok(c:Get(eid).awards[1].state == AWARD.DELIVERED, "award is delivered")
        ok(#c:Log() == 2, "both rolled lots appear in the log")
    end

    -- 8. reconcile retire: drop a copy -> least-committed first, rolling never touched
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [800] = 1, [801] = 1 }, { [800] = true, [801] = true })
        local fid = c:openLotForItem(800).id
        c:Surface(fid); c:StartRoll(fid)         -- 800 is rolling (protected)
        c:Reconcile({ [800] = 1 }, {})           -- 801 gone entirely
        ok(c:State(fid) == STATE.ROLLING, "rolling lot survives reconcile")
        ok(not lotLive(c:openLotForItem(801) or {}), "the un-rolled (new) lot was retired")
    end

    -- 9. ids never reused after retire + re-drop
    do
        local c = LootCore.New()
        c:Reconcile({ [900] = 1 }, { [900] = true })
        local id1 = c:openLotForItem(900).id
        c:Reconcile({}, {})                       -- 900 gone -> retired
        ok(not lotLive(c:Get(id1)), "vanished un-rolled lot retired")
        c:Reconcile({ [900] = 1 }, { [900] = true })
        local id2 = c:openLotForItem(900).id
        ok(id1 ~= id2, "re-dropped lot gets a brand new id (no reuse)")
    end

    -- 10. serialize / applyRemote round-trip mirrors state exactly
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [1000] = 2 }, { [1000] = true })
        local id = c:openLotForItem(1000).id
        c:Surface(id); c:StartRoll(id)
        c:SetResponse(id, "Bob", resp("ms", 90)); c:SetResponse(id, "Amy", resp("ms", 50))
        c:Resolve(id)
        local mirror = LootCore.New()
        mirror:ApplyRemote(c:Serialize())
        ok(mirror.seq == c.seq, "seq mirrored")
        ok(mirror:State(id) == STATE.RESOLVED, "state mirrored")
        ok(mirror:Get(id).awards[1].winner == "Bob", "award winner mirrored")
        ok(mirror:Get(id).itemId == 1000, "itemId mirrored")
        ok(#mirror:List() == #c:List(), "live list count mirrored")
    end

    -- 11. unlock retracts a resolved lot back to idle for a re-roll
    do
        local c = LootCore.New(); c:SetResolver(topN); c:SetML("ML")
        c:Reconcile({ [1100] = 1 }, { [1100] = true })
        local id = c:openLotForItem(1100).id
        c:Surface(id); c:StartRoll(id); c:SetResponse(id, "Bob", resp("ms", 60)); c:Resolve(id)
        ok(c:State(id) == STATE.RESOLVED, "resolved before unlock")
        c:Unlock(id)
        ok(c:State(id) == STATE.IDLE and c:Get(id).awards == nil, "unlock -> idle, awards cleared")
        ok(next(c:Get(id).responses) == nil, "unlock clears responses")
    end

    print(string.format("LootCore self-checks: %d passed, %d failed", pass, fail))
    return fail == 0
end

-- register the live instance on the addon namespace
addon.lootCore = LootCore.New()
addon.LootCore = LootCore -- the prototype/factory, for tests and New()
if not WeirdLoot then WeirdLoot = addon end
WeirdLoot.lootCore = addon.lootCore
WeirdLoot.LootCore = LootCore

return LootCore
