local addon = WeirdLoot
local util = addon.util

function addon:InitializeComm()
    self.comm = {
        autoSync = {
            lastSignature = nil,
            lastAt = 0,
        },
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
function addon:SendLargeMessage(command, values, distribution, target)
    if not self.SendCommMessage then
        return
    end
    local logical = command .. "|" .. util:JoinEncoded(values or {})
    self:SendCommMessage(self.prefix, logical, distribution, target, "NORMAL")
end

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

    self:RefreshSessionItems()

    self:SendLargeMessage("SESSION_BEGIN", {
        session.id or "",
        tostring(self.config.revision or 0),
        self:GetLootMasterName() or "",
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

    for _, item in ipairs(session.items or {}) do
        self:SendLargeMessage("ITEM", {
            session.id or "",
            item.id or "",
            item.link or "",
            item.name or "",
            item.icon or "",
            tostring(item.quantity or 1),
            self:IsItemLocked(item.id) and "1" or "0",
        }, "RAID")
    end

    self:SendLargeMessage("SESSION_END", {
        session.id or "",
        tostring(#(session.items or {})),
    }, "RAID")

    for itemId, responses in pairs(session.responses or {}) do
        for playerKey, choice in pairs(responses) do
            self:BroadcastSelectionState(itemId, playerKey, choice)
        end
    end

    if #(session.results or {}) > 0 then
        self:BroadcastResults(session.results)
    end

    self:Print("Session broadcast to raid.")
end

function addon:BroadcastSessionLocks()
    local session = self:GetCurrentSession()
    if not self:IsAuthorizedLootMaster() or not session.id then
        return
    end

    for _, item in ipairs(session.items or {}) do
        self:SendLargeMessage("ITEM_LOCK", {
            session.id or "",
            item.id or "",
            self:IsItemLocked(item.id) and "1" or "0",
        }, "RAID")
    end
end

function addon:BuildSessionSyncSignature()
    local session = self:GetCurrentSession()
    local parts = {
        session.id or "",
        tostring(#(session.items or {})),
        tostring(#(session.attendees or {})),
    }

    for _, item in ipairs(session.items or {}) do
        parts[#parts + 1] = table.concat({
            item.id or "",
            item.link or "",
            tostring(item.quantity or 1),
        }, "~")
    end

    return table.concat(parts, "|")
end

function addon:AutoBroadcastSession(force)
    local session = self:GetCurrentSession()
    if not self:IsAuthorizedLootMaster() or not session.active then
        return
    end

    local signature = self:BuildSessionSyncSignature()
    local now = (type(GetTime) == "function" and GetTime()) or time()
    local autoSync = self.comm.autoSync or {}

    if not force and autoSync.lastSignature == signature then
        return
    end

    if not force and autoSync.lastAt and (now - autoSync.lastAt) < 0.5 then
        return
    end

    autoSync.lastSignature = signature
    autoSync.lastAt = now
    self.comm.autoSync = autoSync
    self:BroadcastSession()
end

function addon:BroadcastResults(results)
    local session = self:GetCurrentSession()
    for _, result in ipairs(results or {}) do
        self:SendLargeMessage("RESULT", {
            session.id or "",
            result.itemId or "",
            result.itemName or "",
            result.itemLink or "",
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
    }, "WHISPER", lootMasterName)
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

    if command == "SESSION_BEGIN" then
        local sessionId = fields[1]
        local lootMasterName = fields[3]
        self.session.id = sessionId
        self.session.active = true
        self.session.items = {}
        self.session.responses = {}
        self.session.results = {}
        self.session.lockedItems = {}
        self.session.attendees = {}
        self.roster.lootMasterName = lootMasterName ~= "" and lootMasterName or self.roster.lootMasterName
        if self.ui then
            self.ui.selectedResult = nil
        end
        self:TriggerCallback("SESSION_UPDATED")
    elseif command == "ATTENDEE" then
        local attendee = {
            name = fields[2],
            className = fields[3],
            specName = fields[4],
            status = fields[5],
        }
        self.session.attendees[#self.session.attendees + 1] = attendee
        self:TriggerCallback("SESSION_UPDATED")
    elseif command == "ITEM" then
        local item = {
            id = fields[2],
            link = fields[3],
            name = fields[4],
            icon = fields[5],
            quantity = tonumber(fields[6]) or 1,
        }
        self.session.items[#self.session.items + 1] = item
        self.session.responses[item.id] = self.session.responses[item.id] or {}
        self.session.lockedItems = self.session.lockedItems or {}
        self.session.lockedItems[item.id] = fields[7] == "1"
        self:TriggerCallback("SESSION_UPDATED")
    elseif command == "SESSION_END" then
        local playerName = util:GetPlayerName("player")
        for _, item in ipairs(self.session.items or {}) do
            if self.session.responses[item.id] == nil then
                self.session.responses[item.id] = {}
            end
            if self.session.responses[item.id][util:NormalizeKey(playerName or "")] == nil then
                self.session.responses[item.id][util:NormalizeKey(playerName or "")] = "pass"
            end
        end
        self:TriggerCallback("SESSION_UPDATED")
    elseif command == "SELECTION" then
        if not self:IsAuthorizedLootMaster() then
            return
        end
        if self:SetPlayerResponse(fields[2], fields[3], fields[4]) then
            self:BroadcastSelectionState(fields[2], fields[3], fields[4])
        end
    elseif command == "SELECTION_SYNC" then
        self:SetPlayerResponse(fields[2], fields[3], fields[4])
    elseif command == "REQUEST_SESSION_SYNC" then
        if not self:IsAuthorizedLootMaster() then
            return
        end
        self:BroadcastSession()
    elseif command == "ITEM_LOCK" then
        self.session.lockedItems = self.session.lockedItems or {}
        self.session.lockedItems[fields[2]] = fields[3] == "1"
        self:TriggerCallback("SESSION_UPDATED")
    elseif command == "RESULT" then
        local result = {
            itemId = fields[2],
            itemName = fields[3],
            itemLink = fields[4],
            quantity = tonumber(fields[5]) or 1,
            winner = fields[6],
            winnersText = fields[6],
            summary = fields[7],
            detailText = fields[8],
            locked = true,
        }
        self.session.results = self.session.results or {}
        self.session.results[#self.session.results + 1] = result
        self:TriggerCallback("RESULTS_UPDATED")
    elseif command == "RESULTS_DONE" then
        self:TriggerCallback("RESULTS_UPDATED")
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
