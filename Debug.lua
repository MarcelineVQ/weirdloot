local addon = WeirdLoot

-- ---------------------------------------------------------------------------
-- Core trace logger
--
-- LootCore emits a structured record for every command and state transition through a
-- nil-safe sink (LootCore:SetLogger). This module wires that sink in-game and persists
-- the records to the WeirdLootDebugLog SavedVariable, so an in-game test run leaves a
-- machine-checkable trace behind. After a scenario, /reload (or log out) to flush the
-- SavedVariable, then run `luajit tests/checklog.lua <path-to-WeirdLoot.lua>` to assert
-- the trace against the core's intended behaviors.
--
-- Record shape (flat, one table per event):
--   { seq, t, ev, ... event fields }
-- ev is one of the core transitions: session, mark, reset, mint, grow, retire, shrink, remove,
--   surface, skip, startRoll, cancel, response, resolve, unlock, deliver; or the comm trace:
--   send (every outgoing message: cmd/bytes/prio), recv-snap / recv-lot / recv-gap (a raider
--   applying a full snapshot / a delta / detecting a dropped delta). The comm events make the
--   wire load (delta vs snapshot, coalescing, priority lane, drift) verifiable from the log.
-- See tests/checklog.lua for the field set each ev carries and the invariants checked.
-- ---------------------------------------------------------------------------

local DEFAULT_MAX = 5000

local function ensureLog()
    WeirdLootDebugLog = WeirdLootDebugLog or {}
    local log = WeirdLootDebugLog
    if log.enabled == nil then log.enabled = false end   -- opt-in: trace only after /wl debug on
    log.max = log.max or DEFAULT_MAX
    log.seq = log.seq or 0
    log.records = log.records or {}
    return log
end

-- Append one record. data fields are merged in flat. Tables passed in (awards,
-- priorWinners) are freshly built by the core per call, so storing them by reference is
-- safe -- the core never mutates them after emitting.
function addon:LogCoreEvent(ev, data)
    local log = WeirdLootDebugLog
    if not log or not log.enabled then return end

    log.seq = (log.seq or 0) + 1
    local rec = { seq = log.seq, t = (GetTime and GetTime()) or 0, ev = ev }
    if data then
        for k, v in pairs(data) do rec[k] = v end
    end

    local r = log.records
    r[#r + 1] = rec

    -- Ring buffer: trim in batches so we are not O(n) on every append.
    local max = log.max or DEFAULT_MAX
    if #r > max + 512 then
        local keep = {}
        local first = #r - max + 1
        for i = first, #r do keep[#keep + 1] = r[i] end
        log.records = keep
    end

    if log.verbose then
        self:Print("|cff888888[core]|r " .. ev .. (data and data.id and (" " .. tostring(data.id)) or ""))
    end
end

-- Insert a labeled marker. Use before each in-game test scenario to delimit it:
--   /wl debug mark drop-2x
function addon:MarkDebugLog(label)
    local log = ensureLog()
    if not log.enabled then return end
    self:LogCoreEvent("mark", { label = label or "" })
end

function addon:ClearDebugLog()
    local log = ensureLog()
    log.records = {}
    log.seq = 0
    self:LogCoreEvent("session", {
        reason = "clear",
        epoch = (time and time()) or 0,
        player = (UnitName and UnitName("player")) or "?",
        ml = self.lootCore and self.lootCore._mlKey or nil,
        version = (GetAddOnMetadata and GetAddOnMetadata("WeirdLoot", "Version")) or nil,
    })
end

-- Wire the core sink. Call early in PLAYER_LOGIN, before any module touches the core.
function addon:InitializeDebug()
    local log = ensureLog()
    if not self.lootCore then return end

    if log.enabled then
        self.lootCore:SetLogger(function(ev, data) addon:LogCoreEvent(ev, data) end)
    else
        self.lootCore:SetLogger(nil)
    end

    -- a fresh session marker each login so the checker can segment runs
    self:LogCoreEvent("session", {
        reason = "login",
        epoch = (time and time()) or 0,
        player = (UnitName and UnitName("player")) or "?",
        ml = self.lootCore._mlKey or nil,
        version = (GetAddOnMetadata and GetAddOnMetadata("WeirdLoot", "Version")) or nil,
    })
end

-- Fault injection (test only): swallow the next N outgoing sync messages so a delta is lost and
-- the receiver hits a real rev gap, or a whole response cycle is dropped to force a resend/give-up.
-- This wraps the WeirdSync channel's transport in the HOST rather than putting any drop logic in
-- the library. The revision still advances on a dropped send, so the receiver sees the gap.
function addon:EnsureSyncDropHook()
    local chan = self.syncChannel
    if not chan or chan.__dropHooked then return end
    chan.__dropHooked = true
    local orig = chan.SendCommMessage
    chan.SendCommMessage = function(selfChan, prefix, msg, dist, target, prio)
        if (addon._syncDropCount or 0) > 0 then
            addon._syncDropCount = addon._syncDropCount - 1
            return -- simulate a lost addon message
        end
        return orig(selfChan, prefix, msg, dist, target, prio)
    end
end

-- Routed from Core:HandleSlashCommand for "debug ..." subcommands.
function addon:HandleDebugCommand(rest)
    local log = ensureLog()
    rest = string.trim(rest or "")
    local verb, arg = string.match(rest, "^(%S+)%s*(.*)$")
    verb = verb and string.lower(verb) or ""

    if verb == "" then
        self:Print("Core debug trace (off by default; turn it on once and the setting persists). Commands:")
        self:Print("  on / off: start or stop tracing.   status: state and record count.")
        self:Print("  mark <label>: insert a marker for easier log chasing.   dump [n]: show last n records (default 12).   clear: wipe it.")
        self:Print("  sync: force a session sync.   drop <n>: (test) drop the next N sync sends.")
    elseif verb == "status" then
        local drop = self._syncDropCount or 0
        self:Print(string.format("Core debug log: %s, %d record(s), seq %d, cap %d.%s",
            log.enabled and "ON" or "OFF", #log.records, log.seq or 0, log.max or DEFAULT_MAX,
            drop > 0 and (" Dropping next " .. drop .. " sync msg(s).") or ""))
    elseif verb == "on" then
        log.enabled = true
        self:InitializeDebug()
        self:Print("Core debug log ON. /reload to flush the SavedVariable after a test.")
    elseif verb == "off" then
        log.enabled = false
        if self.lootCore then self.lootCore:SetLogger(nil) end
        self:Print("Core debug log OFF.")
    elseif verb == "clear" then
        self:ClearDebugLog()
        self:Print("Core debug log cleared.")
    elseif verb == "mark" then
        self:MarkDebugLog(arg)
        self:Print("Marked: " .. (arg ~= "" and arg or "(unlabeled)"))
    elseif verb == "drop" then
        local n = tonumber(arg) or 0
        self._syncDropCount = n
        self:EnsureSyncDropHook()
        self:Print(string.format("Sync fault injection: dropping the next %d outgoing sync message(s).", n))
    elseif verb == "sync" then
        self:RequestSessionSync()
        self:Print("Forced a session sync request.")
    elseif verb == "dump" then
        local r = log.records
        local n = math.min(#r, tonumber(arg) or 12)
        self:Print(string.format("Last %d of %d record(s):", n, #r))
        for i = #r - n + 1, #r do
            local rec = r[i]
            if rec then
                self:Print(string.format("  %d %s %s", rec.seq or 0, rec.ev or "?", rec.id or rec.label or ""))
            end
        end
    else
        self:Print("Unknown debug command '" .. verb .. "'. Type /wl debug for options.")
    end
end
