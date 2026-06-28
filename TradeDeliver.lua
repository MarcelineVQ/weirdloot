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
    LibStub, ChatThrottleLib.
    LibStub is used to publish/version the library; ChatThrottleLib paces whispers
    so a burst can't get you disconnected. (Addon-message sync, if ever added, should
    use the host addon's shared WeirdComm channel, not a private transport.)

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
          autoCancel (bool) decline (and whisper) UNSOLICITED incoming trades --
                    ones a partner opens with us. Trades the loot master STARTS
                    (the global InitiateTrade: right-click -> Trade, /trade) are
                    always allowed. Runtime-only (not persisted), resets each
                    session; flip it with SetAutoCancel.

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

local MAJOR, MINOR = "TradeDeliver-1.0", 2

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

-- Whole-trade failure messages the server emits via UI_INFO_MESSAGE when an accept is rejected,
-- mapped to a plain-language cause for the payout summary. We note the most recent one during an open
-- window so an item that was placed but pulled back out (the ML removing a rejected item and re-
-- accepting the rest) is reported with WHY it didn't go.
--
-- Both unique-count messages map to the same cause on purpose: on this client the pair is emitted
-- BACKWARDS (handing over a unique the recipient already owns shows the giver "You have too many..."
-- and the recipient "Your trade partner has too many..."), so we can't trust which side a message
-- names. We key off either and report a single, direction-agnostic reason rather than echo the
-- client's (here misleading) text. Fallback strings keep the set populated if a client build is
-- missing a constant at load.
-- Each cause carries two phrasings: `ml` for the loot master's local summary and `them` (second
-- person), read as the tail of the recipient whisper "Trade failed, <them>: [items]".
local UNIQUE_CAUSE = { ml = "recipient can't hold another of a unique item", them = "you already hold one (or more) unique" }
local TRADE_FAIL_REASON = {
    [ERR_TRADE_TARGET_MAX_COUNT_EXCEEDED or "Your trade partner has too many of a unique item."] = UNIQUE_CAUSE,
    [ERR_TRADE_MAX_COUNT_EXCEEDED or "You have too many of a unique item."] = UNIQUE_CAUSE,
    [ERR_TRADE_TARGET_BAG_FULL or "Trade failed, target doesn't have enough space."] = { ml = "recipient's bags are full", them = "your bags are full" },
    [ERR_TRADE_BAG_FULL or "Trade failed, you don't have enough space."] = { ml = "your bags are full", them = "my bags are full" },
    [ERR_TRADE_TARGET_DEAD or "You can't trade with dead players."] = { ml = "recipient is dead", them = "you were dead" },
}

-- The soulbound-trade eligibility rejection. A BoP copy is only tradeable to players the SERVER recorded
-- as eligible to loot THAT kill, and the client exposes no way to read that per-instance list, so we
-- cannot pick the right copy up front. With duplicate tradeable copies (e.g. two of the same token) the
-- server bounces an ineligible copy back out of the trade slot with this RED error; we react by placing
-- the NEXT copy into the freed slot. Kept OUT of TRADE_FAIL_REASON on purpose: a bounce we recover from
-- by retrying must not set a trade-wide failure. TAPLIST_CAUSE phrases the both-sides message sent the
-- moment the retry loop runs out of eligible copies (during the open trade), not at close.
local TAPLIST_MSG = ERR_TRADE_NOT_ON_TAPLIST or "You may only trade bound items to players that were originally eligible to loot the item."
local TAPLIST_CAUSE = { ml = "no copy this player was eligible to loot", them = "you weren't eligible for the item when the boss died" }

-- A trade the local player OPENS can fail before any window appears. When it does, the InitiateTrade
-- hook already armed selfInitiated, so we must disarm it or a failed open would leak "self-initiated"
-- onto the next (possibly incoming) trade. Every such failure announces itself immediately:
--   * too far / dead / self -> a UI_ERROR_MESSAGE equal to one of these globals
--   * BUSY / already trading -> ERR_PLAYER_BUSY_S over CHAT_MSG_SYSTEM (there is NO ERR_TRADE_BUSY)
-- Keyed on the client's own global strings (with English fallbacks) so the match is locale-independent.
local INITIATE_FAIL_MSG = {
    [ERR_TRADE_TOO_FAR or "Trade target is too far away."] = true,
    [ERR_TRADE_TARGET_DEAD or "You can't trade with dead players."] = true,
    [ERR_TRADE_SELF or "You can't trade with yourself."] = true,
}
-- ERR_PLAYER_BUSY_S carries the target name ("%s is busy right now."), so match it as an anchored
-- pattern: escape the literal text, then turn the (escaped) %s placeholder into a name wildcard.
local PLAYER_BUSY_PATTERN = "^" .. ((ERR_PLAYER_BUSY_S or "%s is busy right now.")
    :gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    :gsub("%%%%s", ".-")) .. "$"

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

-- same link-list capping for a list of held-back items ({ {it=, qty=}, ... }); capped tighter than
-- listOwed because the whisper wraps it in a sentence. Names every item that fits, then "+N more".
local function listHeldBack(items, maxLen)
    maxLen = maxLen or 150
    local parts, used, shown = {}, 0, 0
    for _, u in ipairs(items) do
        local label = ((u.qty or 1) > 1 and (u.qty .. "x ") or "") .. itemDisplay(u.it)
        if shown > 0 and used + #label + 2 > maxLen then break end
        parts[#parts + 1] = label
        used = used + #label + 2
        shown = shown + 1
    end
    local s = table.concat(parts, ", ")
    local extra = #items - shown
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

-- Is `link` a PURE Unique item -- the "carry only one" limit that triggers the trade rejection we
-- report? That is distinct from Unique-Equipped (only one EQUIPPED, but you may carry several, which
-- never triggers it) and from the counted Unique (%d) forms. 3.3.5a exposes none of this via
-- GetItemInfo, so we scan the item's tooltip for a BARE ITEM_UNIQUE line, rejecting the -Equipped and
-- counted variants. Used to narrow which held-back item could actually be the dupe.
local UNIQUE_LINE = ITEM_UNIQUE or "Unique"
local UNIQUE_EQUIP_LINE = ITEM_UNIQUE_EQUIPPABLE or "Unique-Equipped"
local function isPureUnique(link)
    if not link then return false end
    local tip = scanner()
    tip:ClearLines()
    tip:SetHyperlink(link)
    for i = 2, tip:NumLines() do
        local fs = _G["TradeDeliverScanTipTextLeft" .. i]
        local txt = fs and fs:GetText()
        if txt == UNIQUE_EQUIP_LINE then return false end   -- unique-equipped: not our rejection
        if txt == UNIQUE_LINE then return true end          -- bare "Unique": carry-one
    end
    return false
end

-- Is this bag item bound to us right now? A held, non-BoE item shows the left-side ITEM_SOULBOUND
-- line. Paired with tradeWindowSeconds this tells a PERMANENTLY-bound copy (no window line AND
-- soulbound) apart from a freely-tradeable one (no window line, not soulbound) -- they look identical
-- by window alone, because an expired BoP-trade window drops the same tooltip line a freebie never had.
local SOULBOUND_LINE = ITEM_SOULBOUND or "Soulbound"
local function isSoulbound(bag, slot)
    local tip = scanner()
    tip:ClearLines()
    tip:SetBagItem(bag, slot)
    for i = 2, tip:NumLines() do
        local fs = _G["TradeDeliverScanTipTextLeft" .. i]
        if fs and fs:GetText() == SOULBOUND_LINE then return true end
    end
    return false
end

-- snapshot every bag stack of itemID up front, with stack size, trade-window seconds, and whether the
-- copy is tradeable AT ALL: { {bag, slot, count, window, tradeable}, ... }. Taken before any moves so
-- we never re-read a slot we have started emptying. window is nil for non-windowed items.
local function collectStacks(itemID)
    local stacks = {}
    for bag = 0, 4 do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            if GetContainerItemID(bag, slot) == itemID then
                local _, c = GetContainerItemInfo(bag, slot)
                local win = tradeWindowSeconds(bag, slot)
                stacks[#stacks + 1] = {
                    bag = bag, slot = slot, count = c or 1,
                    window = win,
                    -- Tradeable NOW if it still shows a soulbound-trade window line, or is not bound at
                    -- all (BoE / freely tradeable). A bound copy whose window lapsed reads window==nil
                    -- (the line is gone) exactly like a freebie, so the soulbound check is what keeps a
                    -- permanently-bound copy from ever being handed over. (Mirrors Session.lua's
                    -- eligible-loot rule; a future pass may centralize both.)
                    tradeable = (win ~= nil) or (not isSoulbound(bag, slot)),
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
        -- Never select a copy we cannot actually trade (a soulbound item whose trade window lapsed).
        -- The server would reject it, and placing it is the "handed out an item with no trade duration"
        -- bug. Excluded here so such a copy is never planned or placed; the owe simply stays unfilled.
        if st.tradeable ~= false then
            pool[#pool + 1] = { bag = st.bag, slot = st.slot, count = st.count, window = st.window }
        end
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
    e._onDelivered = config.onDelivered or function() end  -- (player, itemId, count) on trade complete
    e._log = config.log or function() end                  -- (ev, data) trade-flow trace (optional)
    e.isActive = config.isActive                           -- optional () -> bool; false => automated trade mgmt OFF
    -- autoCancel is a runtime flag (default OFF), not persisted. When ON, every UNSOLICITED incoming
    -- trade (one a partner opens with us) is declined immediately, regardless of payout state or whether
    -- the partner is owed; a trade the loot master STARTS (detected via the InitiateTrade hook) is never
    -- declined. Kept out of db on purpose so it defaults to allow-all each session; the loot master can
    -- flip it via the toggle.
    e.autoCancel = (config.autoCancel == true)

    -- Payout mode is ON by default for every engine lifetime. Owes added while no session
    -- is active don't auto-whisper (no owes exist), so defaulting on is safe and matches what
    -- the loot master almost always wants: the first session-start of a /reload is already armed.
    -- An explicit Pause Payout flips this off until the next /reload (it's runtime-only).
    e.payoutActive = true
    e.pending = nil         -- { key, placed = { {it, qty}, ... } }  consumed on complete
    e.fillState = nil       -- { key, name, plan, destBags, waiting }
    e.fillGen = 0           -- invalidates stale settle/fallback timers

    e.frame = CreateFrame("Frame")
    e.frame:RegisterEvent("TRADE_SHOW")
    e.frame:RegisterEvent("TRADE_CLOSED")
    e.frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
    e.frame:RegisterEvent("BAG_UPDATE")
    e.frame:RegisterEvent("UI_INFO_MESSAGE")    -- carries the yellow "Trade complete." info message
    e.frame:RegisterEvent("UI_ERROR_MESSAGE")   -- red trade-rejection errors (unique/bags/dead) + initiate failures
    e.frame:RegisterEvent("CHAT_MSG_SYSTEM")    -- the ONLY signal a self-initiated trade failed on a BUSY target
    -- TRADE_CLOSED is watched ONLY to flip the tradeOpen flag. It must NOT touch `pending`,
    -- which a successful trade still needs in _onTradeComplete (TRADE_CLOSED fires around the
    -- same time as ERR_TRADE_COMPLETE); `pending` is cleared fresh on each TRADE_SHOW instead.
    e.frame:SetScript("OnEvent", function(_, event, arg1, arg2)
        if event == "TRADE_SHOW" then
            e.tradeOpen = true
            e.placedSnapshot = nil      -- fresh per trade
            e.lastTradeError = nil      -- fresh per trade
            e:_trace("SHOW")
            e:_onTradeShow()
        elseif event == "TRADE_CLOSED" then
            e.tradeOpen = false
            TradeDeliver._selfInitiated = nil   -- safety: never carry a self-initiated arm past a closed window
            e:_trace(("CLOSED pending=%s err=%s"):format(e.pending and "Y" or "N", e.lastTradeError and "Y" or "N"))
            e:_onTradeClosed()
        elseif event == "TRADE_ACCEPT_UPDATE" then
            -- both sides accepted: capture what WE placed before the window clears. This is the
            -- agreed transfer the trade settles against (auto-fill AND manual hand-trade), so an
            -- item the ML pulled back out before re-accepting is never miscredited as delivered.
            e:_trace(("ACCEPT a1=%s a2=%s"):format(tostring(arg1), tostring(arg2)))
            if arg1 == 1 and arg2 == 1 then e:_snapshotPlacedItems() end
        elseif event == "BAG_UPDATE" then
            e:_onBagUpdate(arg1)
        elseif event == "UI_INFO_MESSAGE" then
            if arg1 == ERR_TRADE_COMPLETE then        -- the yellow "Trade complete." info line
                e:_trace("UIINFO complete")
                e:_onTradeComplete()
            end
        elseif event == "UI_ERROR_MESSAGE" then
            -- Trade rejections are RED error messages, not info. They can land just AFTER TRADE_CLOSED,
            -- so capture ungated: _noteTradeError is content-filtered (only known trade-failure strings
            -- match), which can't false-positive on the many unrelated UI_ERROR_MESSAGE lines.
            if e.pending or e.tradeOpen then e:_trace("UIERR [" .. tostring(arg1) .. "]") end
            -- A taplist bounce is recoverable (try the next duplicate copy), so it routes to its own
            -- retry handler rather than _noteTradeError, which would mark the whole trade failed even
            -- when a later copy succeeds. Only exhaustion sets a cause, inside _onTaplistReject.
            if arg1 == TAPLIST_MSG and e.pending then
                e:_onTaplistReject()
            else
                e:_noteTradeError(arg1)
            end
            -- A self-initiate that failed (too far / dead / self) never opens a window; disarm so it
            -- cannot leak "self-initiated" onto the next (possibly incoming) trade.
            if arg1 and INITIATE_FAIL_MSG[arg1] then TradeDeliver._selfInitiated = nil end
        elseif event == "CHAT_MSG_SYSTEM" then
            -- The busy/already-trading failure announces itself ONLY here (ERR_PLAYER_BUSY_S), never as a
            -- UI_ERROR. Cheap guard: only pattern-match while a self-initiate is actually armed.
            if TradeDeliver._selfInitiated and arg1 and arg1:find(PLAYER_BUSY_PATTERN) then
                TradeDeliver._selfInitiated = nil
            end
        end
    end)

    -- The discriminator for "Incoming Trades: OFF". ChromieCraft does NOT fire TRADE_REQUEST to the
    -- recipient, so an incoming and a self-opened trade are identical at TRADE_SHOW by events alone.
    -- The global InitiateTrade is called only when the LOCAL player opens a trade (right-click -> Trade,
    -- /trade), never for an incoming one. Arm a flag here; _onTradeShow consumes it. A failed open is
    -- disarmed by its error (UI_ERROR for too-far/dead/self, CHAT_MSG_SYSTEM for busy) or TRADE_CLOSED.
    if _G.hooksecurefunc and not TradeDeliver._initiateHooked then
        TradeDeliver._initiateHooked = true
        _G.hooksecurefunc("InitiateTrade", function() TradeDeliver._selfInitiated = true end)
    end

    return e
end

-- compact event trace; a no-op unless `/wl debug on`. Lets one real trade reveal the exact event
-- order + raw rejection text, so the failure handling is matched to the client, not guessed.
function Engine:_trace(what) self._log("td-ev", { id = what }) end

-- ---- throttled comms ----------------------------------------------------
function Engine:_whisper(target, text)
    local ctl = _G.ChatThrottleLib
    if ctl then
        ctl:SendChatMessage("ALERT", self.prefix, "[" .. self.name .. "] " .. text, "WHISPER", nil, target)
    else
        SendChatMessage("[" .. self.name .. "] " .. text, "WHISPER", nil, target)
    end
end

-- addon-channel send; unused stub for a future sync layer. If TradeDeliver ever needs raid sync,
-- route it through the addon's shared WeirdComm channel (one pacer for the whole addon), not a
-- private transport.
function Engine:SendComm(text, distribution, target)
    SendAddonMessage(self.prefix, text, distribution or "RAID", target)
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
        -- Retry queue for this item: the WINDOWED tradeable copies we did NOT pick. If the server
        -- bounces a chosen copy as taplist-ineligible, _tryNextCopy places one of these into the freed
        -- slot. Only windowed (BoP-tradeable) copies can ever trip the eligibility rule, so non-windowed
        -- mats never build (or consume) a queue. Shared by reference across this item's whole placements
        -- and popped soonest-to-expire first; `winByKey` marks which chosen slots are windowed.
        local usedKeys, winByKey, alts = {}, {}, {}
        for _, st in ipairs(rec.stacks) do winByKey[st.bag * 100 + st.slot] = st.window end
        for _, s in ipairs(sel) do usedKeys[s.bag * 100 + s.slot] = true end
        for _, st in ipairs(rec.stacks) do
            local k = st.bag * 100 + st.slot
            if st.window ~= nil and st.tradeable ~= false and not usedKeys[k] then
                alts[#alts + 1] = { bag = st.bag, slot = st.slot, id = it.id, window = st.window }
            end
        end
        table.sort(alts, function(a, b) return (a.window or math.huge) < (b.window or math.huge) end)
        for _, s in ipairs(sel) do
            if #plan >= MAX_SLOTS then capped = true break end
            if s.whole then
                local windowed = winByKey[s.bag * 100 + s.slot] ~= nil
                plan[#plan + 1] = { bag = s.bag, slot = s.slot, qty = s.take, it = it,
                                    alternates = windowed and alts or nil }
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
        -- tslot + alternates ride along so _onTaplistReject can spot which placement bounced (its trade
        -- slot goes empty) and drop the next eligible copy into that same freed slot.
        placed[#placed + 1] = { it = p.it, qty = p.qty, bag = p.bag, slot = p.slot,
                                tslot = tslot, alternates = p.alternates }
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
    self._log("td-fill", { placed = #placed, key = s.key })
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
local TAPLIST_SETTLE = 0.20  -- let the eviction packet clear our trade slot before scanning to retry

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

-- True while a trade window is open (TRADE_SHOW..TRADE_CLOSED). The loot reconcile reads this
-- to avoid writing off an owed copy as "removed" when the bag decrease is actually the trade in
-- progress; the trade-complete callback records it as delivered instead.
function Engine:IsTradeOpen()
    return self.tradeOpen == true
end

function Engine:_onTradeShow()
    self.pending = nil
    self.fillState = nil
    self._taplistInformed = false           -- per-window: set when exhaustion already told both sides
    self.fillGen = self.fillGen + 1        -- cancel any settle/fallback from a prior window
    local partner = baseName(UnitName("NPC"))
    if not partner then return end

    -- ACTIVE-ML-ONLY gate. Automated payout (and the incoming-trade decline) must never run for a
    -- non-ML: only the loot master holds and hands out owed loot. The owe ledger PERSISTS in saved
    -- vars and autoCancel is runtime state, so without this a raider who was the ML earlier -- or holds
    -- any stale owe -- would auto-fill a trade with someone else's owed loot. Hard-block it here.
    -- FUTURE ML WORK: real mid-raid ML-swap handling (handing off / forgiving owes and authority when
    -- the loot master changes) will revisit this gate. For now the rule is simply: not the active ML
    -- means do nothing at all on a trade.
    if self.isActive and not self.isActive() then return end

    local entry, key = self:_owedFor(partner, false)
    self._log("td-show", { partner = partner, payoutActive = self.payoutActive and true or false, owed = entry and #entry.items or 0 })

    -- A trade the loot master OPENED (InitiateTrade armed selfInitiated) bypasses autoCancel; the toggle
    -- declines only UNSOLICITED incoming trades. Consume the arm so it never carries to the next trade.
    local selfInitiated = TradeDeliver._selfInitiated and true or false
    TradeDeliver._selfInitiated = nil

    if self.autoCancel and not selfInitiated then
        self._dbg(partner .. " trade declined (Incoming Trades is off)")
        self:_whisper(partner, "Trades are closed right now - trade declined.")
        CloseTrade()
        return
    end

    if not self.payoutActive then
        if entry and #entry.items > 0 then
            self._print(partner .. " is owed " .. #entry.items .. " item(s). Fill the trade or use payout.")
        end
        return
    end

    if entry and #entry.items > 0 then
        self:_deliverOpenTrade(partner, key, entry)
    end
end

-- On-demand fill of the currently-open trade for whoever it's with, independent of
-- payout mode. This is what a manual "fill this trade from the loot ledger" button
-- calls, so manual delivery routes through the same engine as auto-payout instead of
-- hand-placing items. Idempotent: if a fill is already in flight for this trade
-- (e.g. auto-payout already started it), it's a no-op. Returns ok, reason.
function Engine:FillOpenTrade()
    if self.isActive and not self.isActive() then return false, "Only the active loot master can fill trades." end
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

-- Capture the items we have placed in the trade window (slots 1..6; slot 7 is "won't be traded").
-- Read at accept time because the window may be cleared by the time the trade completes.
local MAX_TRADE_SLOTS = 6
function Engine:_snapshotPlacedItems()
    local partner = baseName(UnitName("NPC"))
    local items = {}
    for slot = 1, MAX_TRADE_SLOTS do
        local link = GetTradePlayerItemLink and GetTradePlayerItemLink(slot)
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then
            local count = 1
            if GetTradePlayerItemInfo then
                local _, _, qty = GetTradePlayerItemInfo(slot)
                count = qty or 1
            end
            items[#items + 1] = { id = id, count = count }
        end
    end
    self.placedSnapshot = { partner = partner, items = items }
    self:_trace(("SNAPSHOT partner=%s n=%d"):format(tostring(partner), #items))
end

-- A hand-trade the engine did not auto-fill: reconcile what we placed against the partner's owed
-- ledger and report each match through the SAME _onDelivered path as auto-payout, so the loot core
-- records the delivery and the owe clears.
function Engine:_recordManualDelivery()
    local snap = self.placedSnapshot
    self.placedSnapshot = nil
    if not snap or not snap.partner then return end
    local entry, key = self:_owedFor(snap.partner, false)
    if not entry then return end
    local total = 0
    for _, placed in ipairs(snap.items) do
        local remaining = placed.count
        for _, it in ipairs(entry.items) do
            if remaining <= 0 then break end
            if it.id == placed.id and (it.count or 0) > 0 then
                local qty = math.min(remaining, it.count)
                it.count = it.count - qty
                remaining = remaining - qty
                total = total + qty
                self._onDelivered(entry.name, it.id, qty)
            end
        end
    end
    for i = #entry.items, 1, -1 do
        if (entry.items[i].count or 0) <= 0 then table.remove(entry.items, i) end
    end
    if total > 0 then
        self._print(("recorded %d hand-delivered item(s) to %s; %d entry(ies) still owed"):format(total, entry.name, #entry.items))
    end
    if #entry.items == 0 then self.db.owed[key] = nil end
end

-- note a whole-trade rejection cause seen during an open window (e.g. the recipient already holds a
-- unique we placed). Kept until the next TRADE_SHOW; attached to any placed-but-undelivered item.
function Engine:_noteTradeError(msg)
    local reason = msg and TRADE_FAIL_REASON[msg]
    if reason then           -- trace/store only on a match; UI_ERROR_MESSAGE fires constantly otherwise
        self.lastTradeError = reason
        self:_trace("NOTE_ERR [" .. tostring(msg) .. "]")
        self._dbg("trade error noted: " .. msg .. " -> " .. reason.ml)
    end
end

-- The server bounced one or more BoP copies out of the trade window: the partner was not on that
-- instance's eligible-looter list. The error does not name the item, so we find each bounced placement
-- by residency -- its trade slot now reads empty -- and place the next eligible copy into that same slot
-- (PickupContainerItem/ClickTradeButton are not hardware-gated, so this runs from the event handler).
-- Re-armed naturally: a replacement that is ALSO ineligible bounces and fires this again. Only when a
-- placement runs out of copies do we mark it exhausted and attach TAPLIST_CAUSE so the close/complete
-- path reports it; the owe stays on the ledger (a future eligible copy could still fill it).
function Engine:_onTaplistReject()
    local p = self.pending
    if not p then return end
    -- The eviction (our trade slot going empty) rides a SEPARATE server packet that can land a frame
    -- after this error, so a synchronous GetTradePlayerItemLink can still show the bounced copy resident.
    -- Defer the scan+retry a beat so the slot has actually cleared. Coalesced by generation: repeated
    -- taplist errors (e.g. the replacement is also ineligible) collapse to one pending scan.
    local gen = (self._taplistGen or 0) + 1
    self._taplistGen = gen
    after(TAPLIST_SETTLE, function()
        if self.pending == p and self._taplistGen == gen then self:_retryBouncedCopies(p) end
    end)
end

-- Scan every windowed placement; any whose trade slot is now empty was bounced, so place its next
-- eligible copy. Logs td-taplist per placement (resident? how many alternates left) so a real trade
-- reveals whether a miss is a residency-timing issue or a missing alternate.
function Engine:_retryBouncedCopies(p)
    for i, pl in ipairs(p.placed) do
        local link = pl.tslot and GetTradePlayerItemLink and GetTradePlayerItemLink(pl.tslot)
        self._log("td-taplist", { i = i, itemId = pl.it.id, tslot = pl.tslot,
                                  resident = link and true or false,
                                  alts = pl.alternates and #pl.alternates or -1 })
        if pl.alternates and not pl.exhausted and pl.tslot and not link then
            self:_tryNextCopy(pl)
        end
    end
end

-- Place the next untried eligible copy for a bounced placement into its freed trade slot. Each alternate
-- is verified to still hold the expected item id (a prior bounce returns its copy to the bags, which in
-- the rare case could shift a slot), skipping any that no longer match. Exhausts when the queue is empty.
function Engine:_tryNextCopy(pl)
    -- We were called because a copy just bounced out of the slot, so one more copy was skipped on the way
    -- to an eligible one. Counted until a replacement settles (or we exhaust); reported to the ML on
    -- delivery so they know how many ineligible copies were burned through.
    pl.skipped = (pl.skipped or 0) + 1
    local alts = pl.alternates
    while alts and #alts > 0 do
        local alt = table.remove(alts, 1)
        if GetContainerItemID(alt.bag, alt.slot) == pl.it.id then
            ClearCursor()
            PickupContainerItem(alt.bag, alt.slot)
            ClickTradeButton(pl.tslot)
            pl.bag, pl.slot = alt.bag, alt.slot
            self._log("td-retry", { itemId = pl.it.id, tslot = pl.tslot, left = #alts })
            self._dbg(("eligibility bounce: trying another copy of %s (%d left)"):format(itemDisplay(pl.it), #alts))
            return
        end
    end
    -- No eligible copy remains: tell the ML and the raider RIGHT NOW, the moment we know this slot won't
    -- fill, rather than waiting for the trade to close/complete. The owe is kept (a future eligible copy
    -- could still fill it).
    pl.exhausted = true
    self._log("td-exhausted", { itemId = pl.it.id })
    self._dbg(("no eligible copy of %s left for this player"):format(itemDisplay(pl.it)))
    self:_informTaplistExhausted(pl)
end

-- Immediate both-sides notification when a placement runs out of eligible copies, fired during the open
-- trade as soon as the retry loop exhausts. Sets _taplistInformed so the close-time _finishReport does not
-- re-nudge the same owe with a futile "open another trade" (re-opening can't make an ineligible copy go).
function Engine:_informTaplistExhausted(pl)
    local key = self.pending and self.pending.key
    local entry = key and self.db.owed[key]
    local name = (entry and entry.name) or baseName(UnitName("NPC")) or "?"
    self._print(("couldn't trade %s to %s: %s"):format(itemDisplay(pl.it), name, TAPLIST_CAUSE.ml))
    self:_whisper(name, ("Trade failed, %s: %s"):format(TAPLIST_CAUSE.them, itemDisplay(pl.it)))
    self._taplistInformed = true
end

-- Per-itemId counts of what was ACTUALLY in the trade window at accept time -- the agreed transfer.
-- This is what a completed trade really moved, which can be LESS than what we placed if the ML pulled
-- an item back out (a rejected unique) and re-accepted the rest. Falls back to the placed plan only
-- if no accept snapshot was captured, so a missed TRADE_ACCEPT_UPDATE never loses a real delivery.
function Engine:_deliveredCounts(p)
    local snap = self.placedSnapshot
    local counts = {}
    if snap and snap.items and (not snap.partner or snap.partner:lower() == p.key) then
        for _, it in ipairs(snap.items) do
            counts[it.id] = (counts[it.id] or 0) + (it.count or 1)
        end
        return counts
    end
    for _, pl in ipairs(p.placed) do          -- no usable snapshot: trust the placement (legacy)
        counts[pl.it.id] = (counts[pl.it.id] or 0) + pl.qty
    end
    return counts
end

-- Could this held-back item be the dupe that triggered a unique rejection? Only PURE Unique items can.
-- Split out as a method so the cause-narrowing is testable without a live tooltip.
function Engine:_isPureUnique(it)
    return isPureUnique(it and it.link)
end

function Engine:_onTradeComplete()
    local p = self.pending
    self.pending = nil
    self._log("td-complete", { pending = p and true or false, snapshot = self.placedSnapshot and true or false })
    if not p then
        -- no auto-fill in flight: this was a manual hand-trade. Record it from the snapshot.
        self:_recordManualDelivery()
        return
    end
    local entry = self.db.owed[p.key]
    if not entry then return end

    -- Settle against what the window actually held at accept time, not what we placed. If the ML
    -- removed an item before re-accepting (a unique the recipient already has rejects the whole
    -- trade), crediting p.placed would mark a never-delivered item delivered and drop its owe.
    -- Credit each placed item only up to the amount the snapshot confirms moved; the rest stays owed.
    local delivered = self:_deliveredCounts(p)
    local total, undelivered = 0, {}
    for _, pl in ipairs(p.placed) do
        local avail = delivered[pl.it.id] or 0
        local credit = math.min(pl.qty, avail)
        if credit > 0 then
            delivered[pl.it.id] = avail - credit
            pl.it.count = (pl.it.count or 1) - credit
            total = total + credit
            self._onDelivered(entry.name, pl.it.id, credit)   -- core records where it went
            -- Only when THIS placement settled on an eligible copy (not an exhausted one credited
            -- fungibly from another slot's delivery) does the skip count describe a real burn-through.
            if pl.skipped and pl.skipped > 0 and not pl.exhausted then
                self._print(("skipped %d ineligible cop%s of %s before trading one to %s"):format(
                    pl.skipped, pl.skipped == 1 and "y" or "ies", itemDisplay(pl.it), entry.name))
            end
        end
        if credit < pl.qty then
            undelivered[#undelivered + 1] = { it = pl.it, qty = pl.qty - credit }
        end
    end
    for i = #entry.items, 1, -1 do
        if (entry.items[i].count or 0) <= 0 then table.remove(entry.items, i) end
    end

    self:_finishReport(entry, p.key, total, undelivered)
end

-- Report a finished trade's outcome and tidy the ledger. `undelivered` is the list of {it, qty} that
-- did NOT transfer (empty on a clean trade; everything placed on an aborted one). Shared by the
-- completion path (partial deliveries) and the abort path (a rejection that closed the window).
function Engine:_finishReport(entry, key, total, undelivered)
    -- informed: we have already whispered the recipient WHY an item was held back, so skip the generic
    -- "open another trade" nudge below (re-opening can't fix a rejection -- it would just fail again).
    -- A taplist exhaustion this window already told both sides immediately, so it starts informed.
    local informed = self._taplistInformed or false
    if #undelivered > 0 then
        local parts = {}
        for _, u in ipairs(undelivered) do parts[#parts + 1] = u.qty .. "x " .. itemDisplay(u.it) end
        local list = table.concat(parts, ", ")
        local cause = self.lastTradeError

        if not cause then
            -- held back with no captured cause (e.g. the ML pulled an item by hand): just report the fact.
            self._print(("delivered %d to %s; %d still owed, not traded: %s"):format(
                total, entry.name, #entry.items, list))
        else
            -- attribute the failure. Only the unique ("has too many") case names items, as a hint at
            -- WHICH unique the recipient already holds -- and only PURE Unique ones can be the dupe
            -- (Unique-Equipped never trips it). Trade-wide causes (bags full / dead) apply to the whole
            -- trade, so naming items adds nothing; just state the reason.
            local whisperText
            if cause == UNIQUE_CAUSE then
                local candidates = {}
                for _, u in ipairs(undelivered) do
                    if self:_isPureUnique(u.it) then candidates[#candidates + 1] = u end
                end
                local pool = (#candidates > 0) and candidates or undelivered
                whisperText = ("Trade failed, %s: %s"):format(cause.them, listHeldBack(pool))
            else
                whisperText = "Trade failed, " .. cause.them
            end
            self._print(("delivered %d to %s; %d still owed, not traded: %s (%s)"):format(
                total, entry.name, #entry.items, list, cause.ml))
            self:_whisper(entry.name, whisperText)
            informed = true
        end
    else
        self._print(("delivered %d item(s) to %s; %d entry(ies) still owed"):format(total, entry.name, #entry.items))
    end

    if #entry.items == 0 then
        self.db.owed[key] = nil
    elseif self.payoutActive and not informed then
        self:_whisper(entry.name, "Still owed: " .. listOwed(entry) .. " - open another trade with me.")
    end
end

-- A trade window closed. If an auto-fill is still pending AND we captured a failure cause, the trade
-- was rejected and never completed (a successful trade clears `pending` in _onTradeComplete first),
-- so ERR_TRADE_COMPLETE will never fire to report it. Confirm after a short delay -- TRADE_CLOSED can
-- edge out ERR_TRADE_COMPLETE on a success -- then report the aborted trade so a unique/bag rejection
-- that closes the window still informs the ML and recipient instead of failing silently. A plain
-- cancel (no captured cause) stays silent.
-- Arm a deferred decision whenever a trade closes with an auto-fill still pending. We do NOT require
-- the failure cause to be known yet: the rejection error is a RED UI_ERROR_MESSAGE that can land just
-- after TRADE_CLOSED, so we wait a beat for it. After the delay: a completion will have cleared
-- `pending` (defused); a captured cause means a real rejection (report + inform); neither means a
-- plain cancel (clear quietly, no noise).
function Engine:_onTradeClosed()
    local p = self.pending
    if not p then return end
    self:_trace("ABORT-armed")
    after(0.5, function()
        if self.pending ~= p then self:_trace("ABORT-defused"); return end   -- a completion beat us
        self.pending = nil
        if self.lastTradeError then self:_onTradeAborted(p)
        else self:_trace("ABORT-cancel") end                                 -- plain cancel: stay quiet
    end)
end

-- An auto-filled trade closed on a rejection without completing: nothing transferred, so everything we
-- placed is still owed. Report it (and inform the recipient) via the same path as a partial completion.
function Engine:_onTradeAborted(p)
    local entry = self.db.owed[p.key]
    if not entry then return end
    self:_trace("ABORT-fired")
    self._log("td-abort", { key = p.key, cause = self.lastTradeError and self.lastTradeError.ml or nil })
    local undelivered = {}
    for _, pl in ipairs(p.placed) do undelivered[#undelivered + 1] = { it = pl.it, qty = pl.qty } end
    self:_finishReport(entry, p.key, 0, undelivered)
end
