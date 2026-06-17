--[[==========================================================================
  TradeDeliver-1.0
  Partner-initiated, throttled, stack-correct automated trade payout for 3.3.5a.

  WHAT IT DOES
    You keep an "owed ledger" (player -> items you should hand them). When you
    enable payout and an owed player opens a trade with you, the engine fills the
    trade window from your bags with exactly the owed amounts, optionally accepts,
    and clears delivered items from the ledger when the trade completes. It never
    opens trades itself (no InitiateTrade/TargetUnit) -- the recipient opens it.

  WHY A MODULE
    The fill machinery is fiddly (the trade window binds to the SOURCE bag stack,
    so handing over a partial amount requires physically splitting it into its own
    bag slot first; >6 owed items need multiple trades; bag space can run out; all
    chat must be throttled to avoid a disconnect). This module hides all of that
    behind a small API so any addon can drop it in and just say "I owe Bob 2 of
    item X -- deliver it when he trades me."

  DEPENDENCIES (embed alongside this file, load first)
    LibStub, CallbackHandler-1.0, ChatThrottleLib, AceComm-3.0.
    LibStub is used to publish/version the library; ChatThrottleLib paces whispers
    and AceComm paces+chunks addon messages so a burst can't get you disconnected.

  ----------------------------------------------------------------------------
  PUBLIC API
  ----------------------------------------------------------------------------
    local TradeDeliver = LibStub("TradeDeliver-1.0")

    engine = TradeDeliver:New(config)
        Create an independent delivery engine. config fields:
          db        (table, REQUIRED) where the ledger + settings persist; pass a
                    SavedVariables table to survive reloads. The engine uses
                    db.owed (the ledger).
          name      (string) label used in user-facing text. Default "TradeDeliver".
          prefix    (string) addon-message / throttle queue tag. Default = name.
          print(text)  (function) sink for local status lines. Default: chat frame
                    prefixed with name.
          debug(text)  (function) sink for verbose tracing. Default: no-op.
          autoCancel (bool) while payout is on, decline (and whisper) trades from
                    players NOT on the owed list. Default TRUE. Runtime-only (not
                    persisted), so it resets on each session; only matters during
                    payout, and you can flip it with SetAutoCancel.

    Ledger:
      engine:Owe(player, itemId, count, link) -> newTotal
          Add `count` (default 1) of itemId to player's owed list (aggregates with
          any existing entry for that item). `link` is optional, for display only.
          If payout is active, the player is whispered to come trade.
      engine:Forgive(player [, itemId]) -> removed?   remove one item, or (no
          itemId) the player's whole entry.
      engine:GetOwed([player]) -> table   live ledger (all players) or one player's
          entry { name=, items={ {id,link,count}, ... } }. Read-only by convention.
      engine:ClearOwed()                  wipe the ledger.

    Payout:
      engine:StartPayout([player]) -> nWhispered   enable auto-fill and whisper
          owed players to come trade (all, or just `player`).
      engine:StopPayout()                 disable auto-fill / auto-cancel.
      engine:IsPayoutActive() -> bool
      engine:WhisperOwed([player]) -> n   (re)whisper owed players without toggling
          payout state.
      engine:FillOpenTrade() -> ok, reason   fill the currently-open trade with
          whatever the partner is owed, on demand and regardless of payout mode.
          For a manual "fill this trade" button so manual delivery uses the same
          filler as auto-payout. No-op if a fill is already in flight (no double-fill).

    Settings:
      engine:SetAutoCancel(bool) -> bool      engine:GetAutoCancel() -> bool

    Accept is NOT automated: AcceptTrade() is hardware-event gated on 3.3.5a (only
    runs from a real click/keypress), so the engine fills the trade and the user
    clicks the stock Trade button to send. See _finalizeFill for detail.

    Utility (stateless, on the library):
      TradeDeliver:FindBagItem(nameSubstring) -> itemId, link   first bag item
          whose name contains the substring (case-insensitive); for resolving
          typed item names to ids.

  NOTES
    - Each :New() owns its own trade-event hooks and ledger, so engines are
      independent. In practice only one should run payout at a time (two engines
      filling the same trade would conflict).
    - Delivery is exact and lossless: it never hands over a wrong amount, and
      anything it can't deliver this trade (slot cap, bag space, short stock)
      stays owed for a later trade.
============================================================================]]--

local MAJOR, MINOR = "TradeDeliver-1.0", 1

local TradeDeliver
if LibStub then
    TradeDeliver = LibStub:NewLibrary(MAJOR, MINOR)
    if not TradeDeliver then return end          -- a same/newer version is loaded
else
    -- LibStub absent: degrade to a plain global, defined once
    if _G.TradeDeliver and (_G.TradeDeliver._version or 0) >= MINOR then return end
    TradeDeliver = _G.TradeDeliver or {}
    _G.TradeDeliver = TradeDeliver
end
TradeDeliver._version = MINOR

local MAX_SLOTS = MAX_TRADABLE_ITEMS or 6

-- ---------------------------------------------------------------------------
-- shared "do this in N seconds" scheduler (no C_Timer on 3.3.5a)
-- ---------------------------------------------------------------------------
local timerQueue = {}
local timerFrame = CreateFrame("Frame")
timerFrame:SetScript("OnUpdate", function(_, elapsed)
    if #timerQueue == 0 then return end
    for i = #timerQueue, 1, -1 do
        local t = timerQueue[i]
        t.left = t.left - elapsed
        if t.left <= 0 then
            table.remove(timerQueue, i)
            t.fn()
        end
    end
end)
local function after(sec, fn) timerQueue[#timerQueue + 1] = { left = sec, fn = fn } end

-- ---------------------------------------------------------------------------
-- stateless helpers
-- ---------------------------------------------------------------------------
local function baseName(n) return n and (n:match("^([^-]+)") or n) or nil end
local function itemDisplay(it) return it.link or ("item:" .. tostring(it.id)) end

-- format an owed entry's items as a link list for a whisper, capped to fit the
-- 255-char chat limit (item hyperlinks are long): "[Foo] x2, [Bar], +3 more"
local function listOwed(entry, maxLen)
    maxLen = maxLen or 200
    local parts, used, shown = {}, 0, 0
    for _, it in ipairs(entry.items) do
        local label = ((it.count or 1) > 1 and ((it.count) .. "x ") or "") .. itemDisplay(it)
        if shown > 0 and used + #label + 2 > maxLen then break end
        parts[#parts + 1] = label
        used = used + #label + 2
        shown = shown + 1
    end
    local s = table.concat(parts, ", ")
    local extra = #entry.items - shown
    if extra > 0 then s = s .. (", +%d more"):format(extra) end
    return s
end

-- ---- BoP trade-window remaining time ------------------------------------
-- 3.3.5a has no API for "is this tradeable / how long". The 2h soulbound-trade
-- window is only visible as the tooltip line BIND_TRADE_TIME_REMAINING ("You may
-- trade this item ... for the next %s."). We scan a hidden tooltip for that line
-- and parse the duration to seconds so we can deliver the soonest-to-expire first.
local scanTip
local function scanner()
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "TradeDeliverScanTip", UIParent, "GameTooltipTemplate")
        scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    end
    return scanTip
end

local TRADE_PREFIX
local function tradePrefix()
    if TRADE_PREFIX == nil then
        local s = BIND_TRADE_TIME_REMAINING or "You may trade this item"
        TRADE_PREFIX = s:match("^(.-)%%s") or s
    end
    return TRADE_PREFIX
end

-- parse a localized duration ("2 hours", "1 hr 45 min", "30 sec") to seconds
local function parseDuration(text)
    if not text then return nil end
    local secs, found = 0, false
    for num, unit in text:gmatch("(%d+)%s*(%a+)") do
        unit = unit:lower()
        if unit:find("day") then secs = secs + num * 86400; found = true
        elseif unit:find("ho") or unit == "hr" or unit == "hrs" then secs = secs + num * 3600; found = true
        elseif unit:find("min") then secs = secs + num * 60; found = true
        elseif unit:find("sec") then secs = secs + num; found = true end
    end
    return found and secs or nil
end

-- remaining trade-window seconds for a bag item, or nil if it has no window
-- (freely tradeable forever). A windowed-but-unparseable line returns 0 (urgent).
local function tradeWindowSeconds(bag, slot)
    local prefix = tradePrefix()
    if not prefix or prefix == "" then return nil end
    local tip = scanner()
    tip:ClearLines()
    tip:SetBagItem(bag, slot)
    for i = 2, tip:NumLines() do
        local fs = _G["TradeDeliverScanTipTextLeft" .. i]
        local txt = fs and fs:GetText()
        if txt and txt:find(prefix, 1, true) then
            return parseDuration(txt:sub(#prefix + 1)) or 0
        end
    end
    return nil
end

-- snapshot every bag stack of itemID up front, with stack size and trade-window
-- seconds: { {bag, slot, count, window}, ... }. Taken before any moves so we never
-- re-read a slot we have started emptying. window is nil for non-windowed items.
local function collectStacks(itemID)
    local stacks = {}
    for bag = 0, 4 do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            if GetContainerItemID(bag, slot) == itemID then
                local _, c = GetContainerItemInfo(bag, slot)
                stacks[#stacks + 1] = {
                    bag = bag, slot = slot, count = c or 1,
                    window = tradeWindowSeconds(bag, slot),
                }
            end
        end
    end
    return stacks
end

-- find an empty slot in a general (family 0) bag we have not earmarked this pass
local function findFreeSlot(usedFree)
    for bag = 0, 4 do
        local free, family = GetContainerNumFreeSlots(bag)
        if free and free > 0 and (family == nil or family == 0) then
            local n = GetContainerNumSlots(bag) or 0
            for slot = 1, n do
                local key = bag * 100 + slot
                if not usedFree[key] and not GetContainerItemID(bag, slot) then
                    return bag, slot
                end
            end
        end
    end
    return nil
end

-- Decide which bag stacks to use to deliver `need` of one item. Returns selections
-- { {bag, slot, take, whole}, ... } plus a `short` amount we could not cover.
--
-- TWO objectives, in priority order:
--   A) Hand over the SOONEST-TO-EXPIRE stacks first. BoP loot is only tradeable for
--      a limited window; if we keep an at-risk stack and give away a safe one, the
--      at-risk one can expire (bind permanently) in our bags. So window dominates.
--   B) Among equally-urgent stacks, minimize splitting -- a split fragments a stack
--      and is the one op that leaves bags messy if a trade errors. So we prefer
--      WHOLE stacks and use at most ONE split (the final remainder).
--
-- Mechanism: sort by (window ascending, then count descending), take whole stacks
-- that fit from the front, then split the remainder off the most-urgent stack still
-- larger than it. With no windows (e.g. plain mats), all windows tie and this is
-- exactly "whole stacks largest-first, one split for the remainder":
--   owed 6 from 2,2,4   -> whole 4 + whole 2            (0 splits)
--   owed 7 from 2,2,4   -> whole 4 + whole 2 + split 1  (1 split)
--   owed 6 from 18,6    -> whole 6                       (0 splits)
-- With windows, a more-urgent small stack is delivered before a safe large one even
-- if that costs a split, because not losing the item outranks bag tidiness.
local function windowOf(s) return s.window or math.huge end

local function selectStacks(stacks, need)
    local pool = {}
    for _, st in ipairs(stacks) do
        pool[#pool + 1] = { bag = st.bag, slot = st.slot, count = st.count, window = st.window }
    end
    table.sort(pool, function(a, b)
        local wa, wb = windowOf(a), windowOf(b)
        if wa ~= wb then return wa < wb end     -- soonest-to-expire first
        return a.count > b.count                -- then largest-first (fewest splits)
    end)

    local sel = {}
    for _, st in ipairs(pool) do
        if need <= 0 then break end
        if st.count <= need then
            sel[#sel + 1] = { bag = st.bag, slot = st.slot, take = st.count, whole = true }
            need = need - st.count
            st.used = true
        end
    end
    if need > 0 then
        -- remainder: one split off the most-urgent stack still larger than `need`
        -- (tiebreak smallest, to keep big safe stacks whole)
        local best
        for _, st in ipairs(pool) do
            if not st.used and st.count > need then
                if not best or windowOf(st) < windowOf(best)
                   or (windowOf(st) == windowOf(best) and st.count < best.count) then
                    best = st
                end
            end
        end
        if best then
            sel[#sel + 1] = { bag = best.bag, slot = best.slot, take = need, whole = false }
            need = 0
        end
    end
    return sel, need
end

-- library utility: first bag item whose name contains `want` (case-insensitive)
function TradeDeliver:FindBagItem(want)
    want = (want or ""):lower()
    for bag = 0, 4 do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local nm = link:match("%[(.-)%]")
                if nm and nm:lower():find(want, 1, true) then
                    return GetContainerItemID(bag, slot), link
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- engine instance
-- ---------------------------------------------------------------------------
local Engine = {}
Engine.__index = Engine

local AceComm = LibStub and LibStub("AceComm-3.0", true)

function TradeDeliver:New(config)
    config = config or {}
    assert(type(config.db) == "table", "TradeDeliver:New requires config.db (a table)")

    local e = setmetatable({}, Engine)
    e.db = config.db
    e.db.owed = e.db.owed or {}                 -- [lowerName] = { name, items={ {id,link,count} } }
    e.name = config.name or "TradeDeliver"
    e.prefix = config.prefix or e.name
    e._print = config.print or function(s) DEFAULT_CHAT_FRAME:AddMessage(e.name .. ": " .. s) end
    e._dbg = config.debug or function() end
    -- autoCancel is a runtime flag (default ON), not persisted: while payout is
    -- active, a trade from someone NOT on the owed list is declined + whispered.
    -- Kept off db on purpose so it always defaults on each session.
    e.autoCancel = (config.autoCancel ~= false)

    e.payoutActive = false
    e.pending = nil         -- { key, placed = { {it, qty}, ... } }  consumed on complete
    e.fillState = nil       -- { key, name, plan, destBags, waiting }
    e.fillGen = 0           -- invalidates stale settle/fallback timers

    if AceComm then e._comm = {}; AceComm:Embed(e._comm) end

    e.frame = CreateFrame("Frame")
    e.frame:RegisterEvent("TRADE_SHOW")
    e.frame:RegisterEvent("BAG_UPDATE")
    e.frame:RegisterEvent("UI_INFO_MESSAGE")
    -- We deliberately do NOT watch TRADE_CLOSED: on a successful trade it fires
    -- around the same time as ERR_TRADE_COMPLETE and would race-wipe the pending
    -- snapshot. `pending` is cleared fresh on each TRADE_SHOW instead.
    e.frame:SetScript("OnEvent", function(_, event, arg1)
        if event == "TRADE_SHOW" then
            e:_onTradeShow()
        elseif event == "BAG_UPDATE" then
            e:_onBagUpdate(arg1)
        elseif event == "UI_INFO_MESSAGE" and arg1 == ERR_TRADE_COMPLETE then
            e:_onTradeComplete()
        end
    end)
    return e
end

-- ---- throttled comms ----------------------------------------------------
function Engine:_whisper(target, text)
    local ctl = _G.ChatThrottleLib
    if ctl then
        ctl:SendChatMessage("ALERT", self.prefix, "[" .. self.name .. "] " .. text, "WHISPER", nil, target)
    else
        SendChatMessage("[" .. self.name .. "] " .. text, "WHISPER", nil, target)
    end
end

-- addon-channel send (throttled + chunked via AceComm); for a future sync layer
function Engine:SendComm(text, distribution, target)
    if self._comm then
        self._comm:SendCommMessage(self.prefix, text, distribution or "RAID", target, "NORMAL")
    else
        SendAddonMessage(self.prefix, text, distribution or "RAID", target)
    end
end

-- ---- ledger -------------------------------------------------------------
function Engine:_owedFor(name, create)
    local nm = baseName(name)
    if not nm then return nil end
    local key = nm:lower()
    if not self.db.owed[key] and create then
        self.db.owed[key] = { name = nm, items = {} }
    end
    return self.db.owed[key], key
end

function Engine:Owe(player, itemId, count, link)
    count = count or 1
    local entry = self:_owedFor(player, true)
    if not entry then return 0 end
    local found
    for _, it in ipairs(entry.items) do
        if it.id == itemId then found = it break end
    end
    if found then
        found.count = found.count + count
        found.link = found.link or link
    else
        found = { id = itemId, link = link, count = count }
        entry.items[#entry.items + 1] = found
    end
    if self.payoutActive then self:WhisperOwed(entry.name) end
    return found.count
end

function Engine:Forgive(player, itemId)
    local entry, key = self:_owedFor(player, false)
    if not entry then return false end
    if not itemId then
        self.db.owed[key] = nil
        return true
    end
    local removed = false
    for i = #entry.items, 1, -1 do
        if entry.items[i].id == itemId then table.remove(entry.items, i); removed = true end
    end
    if #entry.items == 0 then self.db.owed[key] = nil end
    return removed
end

function Engine:GetOwed(player)
    if player then return (self:_owedFor(player, false)) end
    return self.db.owed
end

function Engine:ClearOwed() self.db.owed = {} end

-- ---- settings -----------------------------------------------------------
function Engine:SetAutoCancel(v) self.autoCancel = v and true or false; return self.autoCancel end
function Engine:GetAutoCancel() return self.autoCancel end

-- ---- payout driver ------------------------------------------------------
function Engine:WhisperOwed(onlyName)
    local sent = 0
    for key, entry in pairs(self.db.owed) do
        if (#entry.items > 0) and (not onlyName or key == onlyName:lower()) then
            self:_whisper(entry.name, "Open a trade with me to collect: " .. listOwed(entry) .. ".")
            sent = sent + 1
        end
    end
    return sent
end

function Engine:StartPayout(player)
    self.payoutActive = true
    return self:WhisperOwed(player)
end

function Engine:StopPayout() self.payoutActive = false end
function Engine:IsPayoutActive() return self.payoutActive end

-- any outstanding owed items at all? (used to decide whether to police incoming trades)
function Engine:HasOwed()
    for _, entry in pairs(self.db.owed) do
        if entry.items and #entry.items > 0 then return true end
    end
    return false
end

-- ---- trade fill (phase 1: plan + split into dedicated slots) -------------
-- For each owed item, ask selectStacks which stacks to use, then realize that plan
-- in the bags: whole stacks trade from their source slot as-is; the single split
-- (if any) is peeled into a free bag slot so a later whole-slot trade hands over
-- exactly that amount (the trade window binds to the SOURCE stack, so a cursor
-- split would hand over the whole source stack). Capped at MAX_SLOTS entries.
--
-- Owed items are delivered SOONEST-TO-EXPIRE first (by each item's nearest bag-stack
-- trade window), so the most at-risk BoP loot takes the earliest trade slots and, if
-- more than a tradeful is owed, rides in the first trade. Items with no window sort
-- last. Stacks are collected once here and reused (tooltip scans aren't free).
function Engine:_planTrade(entry)
    local items = {}
    for idx, it in ipairs(entry.items) do
        local stacks = collectStacks(it.id)
        local win = math.huge
        for _, st in ipairs(stacks) do
            local w = st.window or math.huge
            if w < win then win = w end
        end
        items[#items + 1] = { it = it, stacks = stacks, win = win, idx = idx }
    end
    table.sort(items, function(a, b)
        if a.win ~= b.win then return a.win < b.win end
        return a.idx < b.idx                    -- stable among equal windows
    end)
    for _, rec in ipairs(items) do
        self._dbg(("deliver order: %s (window %s)"):format(
            itemDisplay(rec.it), rec.win == math.huge and "none" or (rec.win .. "s")))
    end

    local plan, usedFree, touched, blocked, capped = {}, {}, {}, {}, false
    for _, rec in ipairs(items) do
        if #plan >= MAX_SLOTS then capped = true break end
        local it = rec.it
        local sel, short = selectStacks(rec.stacks, it.count or 1)
        for _, s in ipairs(sel) do
            if #plan >= MAX_SLOTS then capped = true break end
            if s.whole then
                plan[#plan + 1] = { bag = s.bag, slot = s.slot, qty = s.take, it = it }
            else
                local fb, fs = findFreeSlot(usedFree)
                if not fb then
                    self._dbg("no free bag slot to split " .. itemDisplay(it))
                    blocked[#blocked + 1] = { it = it, amount = s.take }
                else
                    ClearCursor()
                    SplitContainerItem(s.bag, s.slot, s.take)
                    PickupContainerItem(fb, fs)
                    usedFree[fb * 100 + fs] = true
                    touched[fb] = true
                    plan[#plan + 1] = { bag = fb, slot = fs, qty = s.take, it = it }
                    self._dbg(("split %d x %s into bag %d slot %d"):format(s.take, itemDisplay(it), fb, fs))
                end
            end
        end
        if short and short > 0 then
            self._dbg(("short %d x %s (not enough in bags)"):format(short, itemDisplay(it)))
        end
    end
    if capped then
        self._dbg(("trade full at %d slots; rest goes in the next trade"):format(MAX_SLOTS))
    end
    return plan, touched, blocked
end

-- phase 2: drop each planned (now exact) bag slot into the trade window whole
function Engine:_placePlan(plan)
    local placed = {}
    for _, p in ipairs(plan) do
        local tslot = TradeFrame_GetAvailableSlot()
        if not tslot then break end
        ClearCursor()
        PickupContainerItem(p.bag, p.slot)
        ClickTradeButton(tslot)
        placed[#placed + 1] = { it = p.it, qty = p.qty }
        self._dbg(("traded %d x %s (bag %d slot %d -> trade slot %d)"):format(
            p.qty, itemDisplay(p.it), p.bag, p.slot, tslot))
    end
    return placed
end

-- NOTE on accept: we do NOT auto-accept. AcceptTrade() is hardware-event gated on
-- 3.3.5a -- it only runs when the call stack originates from a real mouse/key press,
-- so a scripted call (timer or event handler) silently no-ops while the items still
-- show in the window. PickupContainerItem/ClickTradeButton are NOT gated, which is
-- why the fill works but confirmation can't be automated. The user clicks the stock
-- Trade button (itself <OnClick function="AcceptTrade"/>) to send.
function Engine:_finalizeFill()
    local s = self.fillState
    self.fillState = nil
    if not s then return end
    local placed = self:_placePlan(s.plan)
    if #placed > 0 then
        self.pending = { key = s.key, placed = placed }
        self._print(("filled %d slot(s) for %s - click Trade to send."):format(#placed, s.name))
    else
        self._print("nothing placed for " .. s.name)
    end
end

-- Phase 2 is gated on BAG_UPDATE for the bags we split into rather than a blind
-- delay: wait until every touched bag reports, then a short settle (re-armed if
-- more relevant updates arrive), then trade the dedicated slots.
local SETTLE = 0.10        -- quiet period after the last relevant BAG_UPDATE
local FALLBACK = 1.00      -- safety net if an expected BAG_UPDATE never arrives

function Engine:_armSettle()
    self.fillGen = self.fillGen + 1
    local g = self.fillGen
    after(SETTLE, function()
        if self.fillState and self.fillGen == g then self:_finalizeFill() end
    end)
end

function Engine:_onBagUpdate(bag)
    local s = self.fillState
    if not s or not s.destBags[bag] then return end
    s.waiting[bag] = nil
    if not next(s.waiting) then self:_armSettle() end
end

-- The single filler: plan + split owed items into the OPEN trade with `partner`.
-- Used by both the automatic path (_onTradeShow while payout is active) and the
-- on-demand path (FillOpenTrade, e.g. a manual "fill this trade" button), so there
-- is only ever one piece of code stuffing the trade window -- no double-fill.
function Engine:_deliverOpenTrade(partner, key, entry)
    local plan, touched, blocked = self:_planTrade(entry)
    -- a split needs a free slot in OUR bags; if there isn't one, tell the ML
    -- (it's their own bags, not the trade slots) and the recipient why it's late
    if #blocked > 0 then
        local parts = {}
        for _, b in ipairs(blocked) do parts[#parts + 1] = b.amount .. "x " .. itemDisplay(b.it) end
        local list = table.concat(parts, ", ")
        self._print("|cffff5555My bags are full|r: can't split " .. list .. " for " .. partner
            .. ". Free a slot, then trade again.")
        self:_whisper(partner, "My bags are full - " .. list .. " delayed until I free a slot.")
    end
    if #plan == 0 then
        if #blocked == 0 then
            self._print("nothing to fill for " .. partner .. " (owed items not found in bags)")
        end
        return
    end
    local waiting = {}
    for bag in pairs(touched) do waiting[bag] = true end
    self.fillState = { key = key, name = entry.name, plan = plan, destBags = touched, waiting = waiting }

    if not next(waiting) then
        self:_armSettle()                      -- no splits; nothing to wait on
    else
        local s = self.fillState               -- safety net; phase 2 normally fires from _onBagUpdate
        after(FALLBACK, function()
            if self.fillState == s then
                self._dbg("fill fallback: expected BAG_UPDATE not seen, placing anyway")
                self:_finalizeFill()
            end
        end)
    end
end

function Engine:_onTradeShow()
    self.pending = nil
    self.fillState = nil
    self.fillGen = self.fillGen + 1        -- cancel any settle/fallback from a prior window
    local partner = baseName(UnitName("NPC"))
    if not partner then return end
    local entry, key = self:_owedFor(partner, false)

    if not self.payoutActive then
        if entry and #entry.items > 0 then
            self._print(partner .. " is owed " .. #entry.items .. " item(s). Fill the trade or use payout.")
        end
        return
    end

    if entry and #entry.items > 0 then
        self:_deliverOpenTrade(partner, key, entry)
    elseif self.autoCancel and self:HasOwed() then
        -- We only police trades while loot is still going out. This partner isn't owed
        -- anything but others are, so decline to avoid interfering with the payout.
        -- CloseTrade() is what the stock Cancel button uses to dismiss a trade we
        -- have not accepted (CancelTrade() is not a real 3.3.5a function).
        self._dbg(partner .. " is not owed anything; declining (payout in progress)")
        self:_whisper(partner, "You're not on my payout list right now - trade declined.")
        CloseTrade()
    end
    -- else: ledger is empty (nothing to hand out) -> leave the trade alone, free trades OK
end

-- On-demand fill of the currently-open trade for whoever it's with, independent of
-- payout mode. This is what a manual "fill this trade from the loot ledger" button
-- calls, so manual delivery routes through the same engine as auto-payout instead of
-- hand-placing items. Idempotent: if a fill is already in flight for this trade
-- (e.g. auto-payout already started it), it's a no-op. Returns ok, reason.
function Engine:FillOpenTrade()
    local partner = baseName(UnitName("NPC"))
    if not partner then return false, "No trade window is open." end
    if self.fillState or self.pending then return true end   -- already filling this trade
    local entry, key = self:_owedFor(partner, false)
    if not entry or #entry.items == 0 then
        return false, partner .. " is not owed anything."
    end
    self.fillGen = self.fillGen + 1
    self:_deliverOpenTrade(partner, key, entry)
    return true
end

function Engine:_onTradeComplete()
    local p = self.pending
    self.pending = nil
    if not p then return end
    local entry = self.db.owed[p.key]
    if not entry then return end
    local total = 0
    for _, pl in ipairs(p.placed) do
        pl.it.count = (pl.it.count or 1) - pl.qty
        total = total + pl.qty
    end
    for i = #entry.items, 1, -1 do
        if (entry.items[i].count or 0) <= 0 then table.remove(entry.items, i) end
    end
    self._print(("delivered %d item(s) to %s; %d entry(ies) still owed"):format(total, entry.name, #entry.items))
    if #entry.items == 0 then
        self.db.owed[p.key] = nil
    elseif self.payoutActive then
        self:_whisper(entry.name, "Still owed: " .. listOwed(entry) .. " - open another trade with me.")
    end
end
