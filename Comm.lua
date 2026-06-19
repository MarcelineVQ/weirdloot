local addon = WeirdLoot
local util = addon.util

function addon:InitializeComm()
    self.comm = {
        -- comm.incoming holds snapshot staging during SNAP_BEGIN..SNAP_END.
        rev = 0,        -- ML: monotonic broadcast revision stamped on every sync message
        lastRev = nil,  -- raider: highest rev applied; a gap triggers an auto full-resync
    }

    -- AceComm-3.0 owns chunking + reassembly and paces every send through
    -- ChatThrottleLib, so a full session broadcast can't trip the server's
    -- addon-message flood limit. It registers its own CHAT_MSG_ADDON frame and
    -- fires OnCommReceived with the fully-reassembled logical message.
    local AceComm = LibStub and LibStub("AceComm-3.0", true)
    if AceComm then
        AceComm:Embed(self)
        self:RegisterComm(self.prefix, "OnCommReceived")
    else
        self:Print("AceComm-3.0 not found; raid sync disabled.")
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

-- Structured-only encoding of one lot for the wire (shared by the full snapshot and deltas):
-- ids + state + live count + responses + winner NAMES + a removed flag. No text, no links.
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
        tostring(self.lootCore.seq or 0),   -- field 9: core seq (used by LOTD deltas; ignored in a full snapshot)
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

-- One snapshot of the whole core ledger, replacing the old per-ITEM / per-LOCK / per-RESULT
-- message storm. Sent as SNAP_BEGIN -> LOT* -> SNAP_END; the raider stages the lots and
-- applies them atomically via core:ApplyRemote.
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

    local core = self.lootCore

    self.comm.rev = (self.comm.rev or 0) + 1
    self:SendLargeMessage("SNAP_BEGIN", {
        session.id or "",
        self:GetLootMasterName() or "",
        tostring(core.seq or 0),
        tostring(self.comm.rev),          -- baseline revision; raider sets lastRev to this
    }, "RAID")

    for _, attendee in ipairs(session.attendees or {}) do
        self:SendLargeMessage("ATTENDEE", {
            session.id or "",
            attendee.name or "",
            attendee.className or "",
            attendee.specName or "",
            attendee.status or "nil",
        }, "RAID")
    end

    for _, lot in ipairs(core:All()) do
        if lot.state == core.STATE.RESOLVED or core:LiveCount(lot.id) > 0 then
            self:SendLargeMessage("LOT", self:EncodeLot(lot), "RAID")
        end
    end

    self:SendLargeMessage("SNAP_END", { session.id or "" }, "RAID")
    self.lootCore:DrainDirty()   -- a full snapshot already carries everything; drop pending deltas
end

-- Delta sync: broadcast only the changed lots as standalone LOTD messages (one upsert each on
-- the raider). This replaces a full-ledger storm for the common case of a single state change.
function addon:BroadcastDelta(ids)
    if not self:IsAuthorizedLootMaster() then return end
    local core = self.lootCore
    for _, id in ipairs(ids or {}) do
        local lot = core:Get(id)
        if lot then
            self.comm.rev = (self.comm.rev or 0) + 1
            local f = self:EncodeLot(lot)
            f[#f + 1] = tostring(self.comm.rev)   -- field 10: broadcast revision for gap detection
            self:SendLargeMessage("LOTD", f, "RAID")
        end
    end
end

-- More changed lots than this in one tick -> a single full snapshot is cheaper and safer than
-- N separate delta messages (and resyncs a raider that may have missed an earlier delta).
local DELTA_MAX = 8

-- Called on every ledgerChanged (ML only). Sends just the changed lots as deltas, or a full
-- snapshot when forced (session start / joiner request / batch process) or the delta is large.
function addon:AutoBroadcastSession(force)
    local session = self:GetCurrentSession()
    if not self:IsAuthorizedLootMaster() or not session.active then
        return
    end

    local core = self.lootCore
    local ids = core:DrainDirty()

    if force then
        self:BroadcastSession()
        return
    end

    if #ids == 0 then
        return
    end

    -- "too large a delta": N separate LOTD messages would cost more than one snapshot
    -- (SNAP_BEGIN + attendees + lots + SNAP_END), so fall back to a full resync.
    if #ids > DELTA_MAX then
        self:BroadcastSession()
        return
    end

    self:BroadcastDelta(ids)
end

function addon:BroadcastResults(results)
    local session = self:GetCurrentSession()
    for _, result in ipairs(results or {}) do
        self:SendLargeMessage("RESULT", {
            session.id or "",
            result.itemId or "",
            result.itemName or "",
            result.itemLink or "",
            result.itemIcon or result.icon or "",
            tostring(result.quantity or 1),
            result.winnersText or result.winner or "",
            result.summary or "",
            result.detailText or "",
        }, "RAID")
    end
    self:SendLargeMessage("RESULTS_DONE", { session.id or "" }, "RAID")
end

function addon:BroadcastSelectionState(itemId, playerName, choice)
    local session = self:GetCurrentSession()
    if not self:IsAuthorizedLootMaster() or not session.id then
        return
    end

    self:SendLargeMessage("SELECTION_SYNC", {
        session.id or "",
        itemId or "",
        playerName or "",
        choice or "pass",
    }, "RAID")
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
    local lootMasterName = self:GetLootMasterName()
    if not lootMasterName then
        self:Print("No loot master detected for session sync.")
        return
    end

    if self:IsAuthorizedLootMaster() then
        self:BroadcastSession()
        return
    end

    self:SendLargeMessage("REQUEST_SESSION_SYNC", {
        util:GetPlayerName("player") or "",
    }, "WHISPER", lootMasterName)
    self:Print("Requested session sync from loot master.")
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

-- AceComm receive callback: prefix-filtered and already reassembled. We still
-- never receive our own RAID/PARTY messages (the client drops them), but keep the
-- self-skip defensively in case of a self-WHISPER echo.
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

    if command == "SNAP_BEGIN" then
        local sessionId, lootMasterName, seq = fields[1], fields[2], tonumber(fields[3]) or 0
        self.session.id = sessionId
        self.session.active = true
        self.session.attendees = {}
        self.roster.lootMasterName = (lootMasterName ~= "" and lootMasterName) or self.roster.lootMasterName
        if self.ui then self.ui.selectedResult = nil end
        self.comm.incoming = { seq = seq, rev = tonumber(fields[4]) or 0, lots = {} } -- stage lots until SNAP_END
    elseif command == "ATTENDEE" then
        self.session.attendees[#self.session.attendees + 1] = {
            name = fields[2],
            className = fields[3],
            specName = fields[4],
            status = fields[5],
        }
        self:TriggerCallback("SESSION_UPDATED")
    elseif command == "LOT" then
        local inc = self.comm.incoming
        if not inc then return end
        inc.lots[#inc.lots + 1] = self:DecodeLot(fields)
    elseif command == "SNAP_END" then
        local inc = self.comm.incoming
        if inc then
            self.lootCore:ApplyRemote({ seq = inc.seq, lots = inc.lots }) -- -> projections + UI refresh
            self.comm.lastRev = inc.rev      -- snapshot re-baselines the revision
            self.comm.resyncPending = nil    -- drift healed
            self.comm.incoming = nil
        end
    elseif command == "LOTD" then
        -- one-lot delta. field 9 = core seq, field 10 = broadcast revision (gap detection).
        local rev = tonumber(fields[10]) or 0
        local last = self.comm.lastRev
        if last == nil or rev > last + 1 then
            -- never synced, or a gap (a delta was dropped): pull a fresh full snapshot. The
            -- pending flag throttles the request to once until the snapshot re-baselines us.
            if not self.comm.resyncPending then
                self.comm.resyncPending = true
                self:RequestSessionSync()
            end
            return
        end
        if rev <= last then return end       -- stale / duplicate
        self.lootCore:ApplyRemoteLot(self:DecodeLot(fields), tonumber(fields[9]) or 0)
        self.comm.lastRev = rev
    elseif command == "SELECTION" then
        if not self:IsAuthorizedLootMaster() then
            return
        end
        self:SetPlayerResponse(fields[2], fields[3], fields[4]) -- ML core write; snapshot syncs back
    elseif command == "REQUEST_SESSION_SYNC" then
        if not self:IsAuthorizedLootMaster() then
            return
        end
        self:BroadcastSession()
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
    elseif command == "LIVE_SYNC" then
        self:OnLiveSyncMessage(fields)
    elseif command == "WIN" then
        self:OnWinMessage(fields)
    elseif command == "CANCEL" then
        self:OnCancelMessage(fields)
    end
end
