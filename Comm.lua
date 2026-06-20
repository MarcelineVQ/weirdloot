local addon = WeirdLoot
local util = addon.util

-- Is a player still in our group? Drives WeirdSync's roster-aware give-up: a targeted re-send
-- stops the moment its recipient genuinely leaves (rather than retrying a phantom).
local function isInRaid(name)
    if not name or name == "" then return false end
    local key = util:NormalizeKey(name)
    if key == util:NormalizeKey((UnitName and UnitName("player")) or "") then return true end
    local raid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    for i = 1, raid do
        local rn = GetRaidRosterInfo(i)
        if rn and util:NormalizeKey(rn) == key then return true end
    end
    local party = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    for i = 1, party do
        local pn = UnitName("party" .. i)
        if pn and util:NormalizeKey(pn) == key then return true end
    end
    return false
end

-- A lot on the wire is the tag "L" followed by the structured EncodeLot array. The tag lets a
-- mixed snapshot (meta / attendee / lot lines) be demultiplexed on apply; deltas reuse the same
-- tagged shape so one decoder serves both paths. WeirdSync treats the whole line as opaque.
local function lotLine(self, lot)
    local f = { "L" }
    for _, v in ipairs(self:EncodeLot(lot)) do f[#f + 1] = v end
    return f
end

local function decodeLotLine(self, f)
    -- strip the "L" tag -> the original EncodeLot array (field 1 sessionId, 2 id, ... 9 seq, 10 remaining)
    local lotFields = {}
    for i = 2, #f do lotFields[#lotFields + 1] = f[i] end
    return self:DecodeLot(lotFields), tonumber(lotFields[9]) or 0, tonumber(lotFields[10])
end

-- Stash the ML's roll countdown for a lot so the raider's roll-popup restore (SyncRollPopups, run
-- on ledgerChanged) can show the true remaining time. Must be set BEFORE the apply that emits
-- ledgerChanged. Kept off the core lot to keep the core free of UI/timing state.
function addon:StashRollRemaining(lot, remaining)
    self._rollRemaining = self._rollRemaining or {}
    if lot.state == self.lootCore.STATE.ROLLING and remaining then
        self._rollRemaining[lot.id] = remaining
    else
        self._rollRemaining[lot.id] = nil
    end
end

function addon:InitializeComm()
    self.comm = {}              -- live-roll comm scratch; all session-mirror state lives in the WeirdSync channel
    self.syncPrefix = "WLSYNC"  -- WeirdSync owns this prefix; the live-roll lane stays on self.prefix

    -- AceComm-3.0 owns chunking + reassembly and paces every send through ChatThrottleLib. We use
    -- it directly for the live-roll lane (DROP/WIN/CANCEL/RSP/SELECTION/NAMED_ITEMS) on self.prefix.
    local AceComm = LibStub and LibStub("AceComm-3.0", true)
    if AceComm then
        AceComm:Embed(self)
        self:RegisterComm(self.prefix, "OnCommReceived")
    else
        self:Print("AceComm-3.0 not found; raid sync disabled.")
    end

    -- The reliable session mirror is delegated to WeirdSync: it owns the revision, snapshot/delta
    -- framing, gap detection + resync, request retry, targeted-send ack, and give-up. We own only
    -- payload semantics: a snapshot/delta line is { tag, fields... } that we encode/decode here.
    local WeirdSync = LibStub and LibStub("WeirdSync-1.0", true)
    if WeirdSync then
        self.syncChannel = WeirdSync:NewChannel(self.syncPrefix, {
            isAuthority    = function() return self:IsAuthorizedLootMaster() end,
            authorityName  = function() return self:GetLootMasterName() end,
            rosterContains = function(name) return isInRaid(name) end,
            epoch          = function() return self:GetCurrentSession().id or "" end,
            buildSnapshot  = function(emit) self:SyncBuildSnapshot(emit) end,
            applySnapshot  = function(lines, ep) self:SyncApplySnapshot(lines, ep) end,
            applyLine      = function(fields) self:SyncApplyLine(fields) end,
            log            = function(ev, data) self:LogCoreEvent(ev, data) end,
        })
    else
        self:Print("WeirdSync-1.0 not found; raid sync disabled.")
    end
end

-- One logical message per call. AceComm splits anything over ~254 bytes into
-- ordered multipart chunks and throttles them; keep a single priority so the
-- session burst (SESSION_BEGIN -> ATTENDEE -> ITEM ...) stays in sequence.
-- prio: CTL lane. Session-mirror traffic (snapshots, deltas, attendees) defaults to BULK so
-- the time-sensitive live-roll lane (DROP/WIN/CANCEL/RSP -> ALERT) always preempts it. On a
-- flood-limited server the popup a raider sees must not queue behind a ledger sync.
function addon:SendLargeMessage(command, values, distribution, target, prio)
    if not self.SendCommMessage then
        return
    end
    local logical = command .. "|" .. util:JoinEncoded(values or {})
    self:SendCommMessage(self.prefix, logical, distribution, target, prio or "BULK")
    -- trace every outgoing message so the wire load (delta vs snapshot, coalescing, priority
    -- lane) is verifiable from the log: e.g. 12 picks should produce 0 sends, a roll one ALERT DROP.
    self:LogCoreEvent("send", { cmd = command, bytes = #logical, prio = prio or "BULK", dist = distribution })
end

-- responses map <-> compact string. Player keys are normalized (no '|'/':'/','/'='), so a
-- "player=tier" list joined by ',' rides safely inside one encoded field.
local function encodeResponses(responses)
    local parts = {}
    for player, tier in pairs(responses or {}) do
        parts[#parts + 1] = tostring(player) .. "=" .. tostring(tier)
    end
    return table.concat(parts, ",")
end

local function decodeResponses(str)
    local out = {}
    for pair in string.gmatch(str or "", "[^,]+") do
        local player, tier = string.match(pair, "^(.-)=(.+)$")
        if player then out[player] = tier end
    end
    return out
end

-- Render a received resolved lot's result record LOCALLY from its itemId + winner names. The
-- wire never carries rendered text or links (the core's rule): name/link/icon come from this
-- client's GetItemInfo, and summary/detail are formatted here. Winner names are the only
-- non-derivable data, so they ride the wire; everything else is local.
local function renderRemoteRecord(lotId, itemId, count, winners)
    local name, link, icon = util:ItemRender(itemId)
    name = name or link or ("item:" .. tostring(itemId))
    local qty = count or 1
    local winnersText = #winners > 0 and table.concat(winners, ", ") or "No winner"
    local summary = qty >= 2
        and string.format("%s x%d -> %s", name, qty, winnersText)
        or string.format("%s -> %s", name, winnersText)
    local lines = { "Item: " .. name .. (qty >= 2 and string.format(" x%d", qty) or ""), "", "Winner(s):" }
    if #winners == 0 then
        lines[#lines + 1] = "No winner"
    else
        for _, w in ipairs(winners) do lines[#lines + 1] = w end
    end
    return {
        itemId = lotId, realItemId = itemId,
        itemName = name, itemLink = link, itemIcon = icon, quantity = qty,
        winners = winners, winnersText = winnersText, winner = winners[1] or "No winner",
        summary = summary, detailText = table.concat(lines, "\n"), locked = true,
    }
end

-- Seconds left on a rolling lot's countdown, from the ML's authoritative roll deadline. Sent so a
-- raider restoring a roll popup shows the true time remaining (the ML closes it at the real end),
-- not a fresh full duration. "" for non-rolling lots or when no deadline is known.
function addon:RollRemaining(lot)
    if lot.state ~= self.lootCore.STATE.ROLLING then return "" end
    local roll = self.live and self.live.rolls and self.live.rolls[lot.id]
    if not roll or not roll.deadline then return "" end
    return tostring(math.max(0, roll.deadline - ((GetTime and GetTime()) or 0)))
end

-- Structured-only encoding of one lot for the wire (shared by the full snapshot and deltas):
-- ids + state + live count + responses + winner NAMES + a removed flag + roll remaining. No text.
function addon:EncodeLot(lot)
    local winners = {}
    for _, a in ipairs(lot.awards or {}) do
        if a.winner then winners[#winners + 1] = a.winner end
    end
    return {
        self:GetCurrentSession().id or "",
        lot.id,
        tostring(lot.itemId or 0),
        lot.state,
        tostring(self.lootCore:LiveCount(lot.id)),
        encodeResponses(lot.responses),
        table.concat(winners, ","),
        lot.removed and "1" or "",
        tostring(self.lootCore.seq or 0),   -- field 9: core seq (used by deltas; ignored in a full snapshot)
        self:RollRemaining(lot),            -- field 10: roll countdown seconds (rolling lots only)
    }
end

-- Rebuild a lot table (core's shape) from wire fields, rendering the record locally.
function addon:DecodeLot(fields)
    local lot = {
        id = fields[2],
        itemId = tonumber(fields[3]),
        state = fields[4],
        count = tonumber(fields[5]) or 0,
        responses = decodeResponses(fields[6]),
        removed = (fields[8] == "1") or nil,
    }
    if lot.state == self.lootCore.STATE.RESOLVED then
        local winners = {}
        for _, w in ipairs(util:Split(fields[7] or "", ",")) do
            if w ~= "" then winners[#winners + 1] = w end
        end
        lot.record = renderRemoteRecord(lot.id, lot.itemId, lot.count, winners)
    end
    return lot
end

-- Host snapshot builder for WeirdSync. Emits one line per piece of state: an "M" meta line
-- (loot-master name + core seq), an "A" line per attendee, and an "L" line per live/resolved
-- lot. WeirdSync frames these as SB -> lines -> SD and carries them reliably.
function addon:SyncBuildSnapshot(emit)
    local session = self:GetCurrentSession()
    local core = self.lootCore
    emit({ "M", self:GetLootMasterName() or "", tostring(core.seq or 0) })
    for _, attendee in ipairs(session.attendees or {}) do
        emit({ "A", attendee.name or "", attendee.className or "", attendee.specName or "", attendee.status or "nil" })
    end
    for _, lot in ipairs(core:All()) do
        if lot.state == core.STATE.RESOLVED or core:LiveCount(lot.id) > 0 then
            emit(lotLine(self, lot))
        end
    end
end

-- Host snapshot applier (raider). Rebuilds session context + attendees from the lines and
-- applies the lots atomically via core:ApplyRemote (-> ledgerChanged -> projections + UI).
function addon:SyncApplySnapshot(lines, epoch)
    -- An empty epoch means the authority has no active session (it answered a request with an
    -- empty snapshot). Don't fabricate a session: mark inactive rather than show a phantom one.
    self.session.id = epoch
    self.session.active = epoch ~= nil and epoch ~= ""
    self.session.attendees = {}
    if self.ui then self.ui.selectedResult = nil end

    local lots, seq = {}, 0
    for _, f in ipairs(lines) do
        local tag = f[1]
        if tag == "M" then
            local mlName = f[2]
            if mlName and mlName ~= "" then self.roster.lootMasterName = mlName end
            seq = math.max(seq, tonumber(f[3]) or 0)
        elseif tag == "A" then
            self.session.attendees[#self.session.attendees + 1] = {
                name = f[2], className = f[3], specName = f[4], status = f[5],
            }
        elseif tag == "L" then
            local lot, lotSeq, remaining = decodeLotLine(self, f)
            lots[#lots + 1] = lot
            seq = math.max(seq, lotSeq)
            self:StashRollRemaining(lot, remaining)   -- before ApplyRemote -> ledgerChanged -> SyncRollPopups
        end
    end
    self.lootCore:ApplyRemote({ seq = seq, lots = lots })
end

-- Host delta applier (raider): one lot upsert.
function addon:SyncApplyLine(fields)
    if fields[1] ~= "L" then return end
    local lot, lotSeq, remaining = decodeLotLine(self, fields)
    self:StashRollRemaining(lot, remaining)   -- before ApplyRemoteLot -> ledgerChanged -> SyncRollPopups
    self.lootCore:ApplyRemoteLot(lot, lotSeq)
end

-- Full session snapshot to the raid. WeirdSync owns the framing/revision; we just hand it the
-- snapshot and drop the core's pending deltas (the snapshot already carried everything).
function addon:BroadcastSession()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can broadcast the session.")
        return
    end
    local session = self:GetCurrentSession()
    if not session.active then
        self:Print("Start a loot session first.")
        return
    end
    if not self.syncChannel then return end
    self.syncChannel:Broadcast(true)
    self.lootCore:DrainDirty()
end

-- Called on every ledgerChanged (ML only). Hands the changed lots to WeirdSync, which decides
-- delta-vs-snapshot (its deltaMax) and sends reliably. force routes to a full snapshot.
function addon:AutoBroadcastSession(force)
    local session = self:GetCurrentSession()
    if not self:IsAuthorizedLootMaster() or not session.active then return end
    if not self.syncChannel then return end
    if force then
        self:BroadcastSession()
        return
    end
    local core = self.lootCore
    local ids = core:DrainDirty()
    if #ids == 0 then return end
    local lines = {}
    for _, id in ipairs(ids) do
        local lot = core:Get(id)
        if lot then lines[#lines + 1] = lotLine(self, lot) end
    end
    self.syncChannel:NotifyChanged(lines)
    self.syncChannel:Broadcast(false)
end

function addon:SendSelection(itemId, choice)
    local session = self:GetCurrentSession()
    if not session.id then
        return
    end

    local playerName = util:GetPlayerName("player")
    local lootMasterName = self:GetLootMasterName()
    if not lootMasterName then
        return
    end

    if util:NormalizeKey(playerName or "") == util:NormalizeKey(lootMasterName or "") then
        return
    end

    self:SendLargeMessage("SELECTION", {
        session.id,
        itemId,
        playerName or "",
        choice or "pass",
    }, "WHISPER", lootMasterName, "ALERT")
end

function addon:RequestSessionSync()
    if self:IsAuthorizedLootMaster() then
        self:BroadcastSession()
        return
    end
    if not self.syncChannel then return end
    -- WeirdSync defers the request if the loot master is not resolved yet (common right after a
    -- reload, before loot-method/roster data settles) and fires it the moment it is, so a
    -- reloading raider always ends up requesting a sync instead of silently giving up.
    self.syncChannel:RequestSync()
end

function addon:BroadcastNamedItems()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can broadcast named items.")
        return
    end

    self:SendLargeMessage("NAMED_ITEMS_SYNC", {
        self:GetLootMasterName() or "",
        self.config.namedItemsText or "",
    }, "RAID")

    self:Print("Broadcast named items sent to raid.")
end

-- AceComm receive callback for the live-roll lane (self.prefix). Session-mirror traffic rides
-- the WeirdSync channel's own prefix and is dispatched straight to it, so it never reaches here.
-- We never receive our own RAID/PARTY messages (the client drops them); keep the self-skip
-- defensively in case of a self-WHISPER echo.
function addon:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= self.prefix then
        return
    end

    if util:NormalizeKey(util:GetPlayerName("player") or "") == util:NormalizeKey(sender or "") then
        return
    end

    self:HandleCommMessage(sender, message)
end

function addon:HandleCommMessage(sender, logical)
    local fields = util:SplitEncoded(logical)
    local command = table.remove(fields, 1)

    if command == "SELECTION" then
        if not self:IsAuthorizedLootMaster() then
            return
        end
        self:SetPlayerResponse(fields[2], fields[3], fields[4]) -- ML core write; snapshot syncs back
    elseif command == "NAMED_ITEMS_SYNC" then
        local expectedLootMaster = util:NormalizeKey(self:GetLootMasterName() or "")
        local senderKey = util:NormalizeKey(sender or "")
        if expectedLootMaster ~= "" and senderKey ~= expectedLootMaster then
            return
        end
        self:SaveNamedItemsText(fields[2] or "", true)
        self:Print("Named items updated from " .. ((fields[1] ~= "" and fields[1]) or sender or "loot master") .. ".")
    elseif command == "DROP" then
        self:OnDropMessage(fields)
    elseif command == "RSP" then
        self:OnRspMessage(sender, fields)
    elseif command == "WIN" then
        self:OnWinMessage(fields)
    elseif command == "CANCEL" then
        self:OnCancelMessage(fields)
    end
end
