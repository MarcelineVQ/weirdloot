local addon = WeirdLoot
local util = addon.util

local MAX_BAG_ID = 4
local SCAN_TOOLTIP_NAME = "WeirdLootScanTooltip"
local tradeScanTooltip

local function buildSessionState(ownerKey)
    return {
        id = nil,
        active = false,
        ownerKey = ownerKey,
        startedAt = nil,
        startSnapshot = {},
        currentSnapshot = {},
        scanMode = "delta",
        items = {},
        responses = {},
        results = {},
        lockedItems = {},
        pendingLinks = {},
        lootWindowHints = {},
        lootWindowItems = {},
        pendingHintedRolls = {},
        recentAddedLinks = {},
        attendees = {},
    }
end

local function getTradeScanTooltip()
    if not tradeScanTooltip then
        local owner = WorldFrame or UIParent
        tradeScanTooltip = CreateFrame("GameTooltip", SCAN_TOOLTIP_NAME, owner, "GameTooltipTemplate")
        tradeScanTooltip:SetOwner(owner, "ANCHOR_NONE")

        for index = 1, 30 do
            if not _G[SCAN_TOOLTIP_NAME .. "TextLeft" .. index] then
                local left = tradeScanTooltip:CreateFontString(SCAN_TOOLTIP_NAME .. "TextLeft" .. index, nil, "GameTooltipText")
                local right = tradeScanTooltip:CreateFontString(SCAN_TOOLTIP_NAME .. "TextRight" .. index, nil, "GameTooltipText")
                tradeScanTooltip:AddFontStrings(left, right)
            end
        end
    end

    return tradeScanTooltip
end

local function normalizeResponseChoice(choice)
    if choice == true then
        return "ms"
    end
    if choice == false or choice == nil then
        return "pass"
    end

    choice = util:NormalizeKey(choice)
    if choice == "bis" then
        return "bis"
    end
    if choice == "ms" or choice == "main spec" or choice == "mainspec" or choice == "roll" then
        return "ms"
    end
    if choice == "mu" or choice == "minor upgrade" or choice == "minorupgrade" then
        return "mu"
    end
    if choice == "os" or choice == "off spec" or choice == "offspec" then
        return "os"
    end
    if choice == "tm" or choice == "transmog" then
        return "tm"
    end

    return "pass"
end

local function tooltipHasLine(tooltip, exactText, partialText)
    local lineCount = tooltip:NumLines() or 0
    for index = 1, lineCount do
        local regions = {
            _G[SCAN_TOOLTIP_NAME .. "TextLeft" .. index],
            _G[SCAN_TOOLTIP_NAME .. "TextRight" .. index],
        }

        for _, region in ipairs(regions) do
            local text = region and region:GetText()
            if text and text ~= "" then
                if exactText and text == exactText then
                    return true
                end

                if partialText and string.find(string.lower(text), string.lower(partialText), 1, true) then
                    return true
                end
            end
        end
    end

    return false
end

function addon:InitializeSession()
    local ownerKey = self:GetSessionOwnerKey()
    self.sessionDb.activeSessions = self.sessionDb.activeSessions or {}

    local session = self.sessionDb.activeSessions[ownerKey]
    if not session then
        session = buildSessionState(ownerKey)
        self.sessionDb.activeSessions[ownerKey] = session
    end

    self.session = session
    self.session.ownerKey = ownerKey
    self.session.lockedItems = self.session.lockedItems or {}
    self.session.pendingLinks = self.session.pendingLinks or {}
    self.session.lootWindowHints = self.session.lootWindowHints or {}
    self.session.lootWindowItems = self.session.lootWindowItems or {}
    self.session.pendingHintedRolls = self.session.pendingHintedRolls or {}
    self.session.recentAddedLinks = self.session.recentAddedLinks or {}
end

function addon:HintLootWindowItem(link, count, name, icon)
    if not self.session or not self.session.active then
        return
    end
    if not link or link == "" then
        return
    end

    self.session.lootWindowHints = self.session.lootWindowHints or {}
    self.session.lootWindowHints[link] = (self.session.lootWindowHints[link] or 0) + (count or 1)
    self.session.lootWindowItems = self.session.lootWindowItems or {}
    self.session.lootWindowItems[link] = {
        name = name or link,
        icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark",
    }
    self.session.pendingHintedRolls = self.session.pendingHintedRolls or {}
    self.session.pendingHintedRolls[link] = true
end

function addon:BuildBagSnapshot()
    local snapshot = {}
    local minQuality = (self.db and self.db.testMode) and 0 or 4   -- test mode: any item

    for bag = 0, MAX_BAG_ID do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            local _, count, _, quality = GetContainerItemInfo(bag, slot)
            if link and count and quality and quality >= minQuality then
                snapshot[link] = (snapshot[link] or 0) + count
            end
        end
    end

    return snapshot
end

function addon:HasAddedEpicLoot(currentSnapshot)
    local session = self:GetCurrentSession()
    local previousSnapshot = session.currentSnapshot or {}

    for link, count in pairs(currentSnapshot or {}) do
        if count > (previousSnapshot[link] or 0) then
            return true
        end
    end

    return false
end

function addon:BuildTradeableEpicCounts()
    local counts = {}
    local testMode = self.db and self.db.testMode
    local minQuality = testMode and 0 or 4
    local tooltip = getTradeScanTooltip()

    for bag = 0, MAX_BAG_ID do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            local _, count, _, quality = GetContainerItemInfo(bag, slot)
            if testMode and link and count and quality and quality >= minQuality then
                -- city testing: any bag item is eligible EXCEPT soulbound ones (those
                -- can't be traded). A trade-window item is soulbound but tradeable, so
                -- still allow it.
                tooltip:ClearLines()
                tooltip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
                tooltip:SetBagItem(bag, slot)
                tooltip:Show()
                local soulbound = tooltipHasLine(tooltip, ITEM_SOULBOUND, "soulbound")
                local tradeWindow = tooltipHasLine(tooltip, nil, "you may trade this item")
                if (not soulbound) or tradeWindow then
                    counts[link] = (counts[link] or 0) + count
                end
            elseif link and count and quality and quality >= minQuality then
                local bindType = select(14, GetItemInfo(link))
                local isBindOnEquip = bindType == 2
                local isTemporarilyTradeable = false
                local isSoulbound = false

                tooltip:ClearLines()
                tooltip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
                tooltip:SetBagItem(bag, slot)
                tooltip:Show()
                if tooltipHasLine(tooltip, nil, "you may trade this item") then
                    isTemporarilyTradeable = true
                end
                if tooltipHasLine(tooltip, ITEM_SOULBOUND, "soulbound") then
                    isSoulbound = true
                end
                if tooltipHasLine(tooltip, ITEM_BIND_ON_EQUIP, "binds when equipped") then
                    isBindOnEquip = true
                end

                tooltip:ClearLines()
                tooltip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
                tooltip:SetHyperlink(link)
                tooltip:Show()
                if tooltipHasLine(tooltip, ITEM_BIND_ON_EQUIP, "binds when equipped") then
                    isBindOnEquip = true
                end

                if isTemporarilyTradeable or (isBindOnEquip and not isSoulbound) then
                    counts[link] = (counts[link] or 0) + count
                end
            end
        end
    end

    tooltip:Hide()
    return counts
end

function addon:StartLootSession()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can start a loot session.")
        return
    end

    local sessionId = tostring(time())
    self.session.id = sessionId
    self.session.active = true
    self.session.ownerKey = self:GetSessionOwnerKey()
    self.session.startedAt = time()
    self.session.startSnapshot = self:BuildBagSnapshot()
    self.session.currentSnapshot = util:CloneTable(self.session.startSnapshot)
    self.session.scanMode = "delta"
    self.session.items = {}
    self.session.responses = {}
    self.session.results = {}
    self.session.lockedItems = {}
    self.session.pendingLinks = {}
    self.session.lootWindowHints = {}
    self.session.lootWindowItems = {}
    self.session.pendingHintedRolls = {}
    self.session.recentAddedLinks = {}
    self.session.attendees = util:CloneTable(self:GetAttendees())

    self.sessionDb.history = self.sessionDb.history or {}

    -- A fresh session starts with a fresh payout ledger: drop any owes carried over from
    -- a prior session so they aren't re-whispered/re-delivered here.
    if self.payout then self.payout:ClearOwed() end

    -- Payout mode is on for the duration of the session: as live-roll winners get
    -- owed, a winner opening a trade with the ML auto-fills.
    self:ResumePayoutMode()

    self:TriggerCallback("SESSION_UPDATED")
    self:Print("Loot session started. Payout mode ON.")
end

function addon:ClearSession()
    self.session.active = false
    self.session.ownerKey = self:GetSessionOwnerKey()
    self.session.scanMode = "delta"
    self.session.items = {}
    self.session.responses = {}
    self.session.results = {}
    self.session.lockedItems = {}
    self.session.pendingLinks = {}
    self.session.lootWindowHints = {}
    self.session.lootWindowItems = {}
    self.session.pendingHintedRolls = {}
    self.session.recentAddedLinks = {}
    self:TriggerCallback("SESSION_UPDATED")
end

function addon:GetCurrentSession()
    return self.session
end

function addon:BuildSessionItemList(includeAllEpics)
    local session = self:GetCurrentSession()
    if not session.active then
        return {}
    end

    local currentSnapshot = self:BuildBagSnapshot()
    -- Do NOT clobber the delta baseline here. At login the bags may not be fully loaded,
    -- so storing this partial scan as session.currentSnapshot makes the next BAG_UPDATE
    -- diff the real bag against an empty baseline and auto-roll already-present loot. The
    -- baseline is owned by StartLootSession (init) and OnBagUpdate (delta); only prime it
    -- if it has never been set.
    if session.currentSnapshot == nil then
        session.currentSnapshot = currentSnapshot
    end

    local tradeableCounts = self:BuildTradeableEpicCounts()
    local hintedCounts = session.lootWindowHints or {}
    local hintedItems = session.lootWindowItems or {}
    local recentAddedLinks = session.recentAddedLinks or {}
    local allLinks = {}
    local sortedLinks = {}
    for link in pairs(currentSnapshot) do
        allLinks[link] = true
    end
    for link in pairs(hintedCounts) do
        allLinks[link] = true
    end

    for link in pairs(allLinks) do
        local totalCount = math.max(currentSnapshot[link] or 0, hintedCounts[link] or 0)
        local eligibleCount = math.max(tradeableCounts[link] or 0, hintedCounts[link] or 0, recentAddedLinks[link] and totalCount or 0)
        if eligibleCount > 0 then
            local itemName, _, quality, _, _, _, _, _, _, texture = GetItemInfo(link)
            local hintedItem = hintedItems[link] or {}
            sortedLinks[#sortedLinks + 1] = {
                link = link,
                count = math.min(totalCount, eligibleCount),
                name = itemName or hintedItem.name or link,
                icon = texture or hintedItem.icon or "Interface\\Icons\\INV_Misc_QuestionMark",
            }
        end
    end

    table.sort(sortedLinks, function(left, right)
        if left.name == right.name then
            return left.link < right.link
        end
        return left.name < right.name
    end)

    local items = {}
    for linkIndex, entry in ipairs(sortedLinks) do
        items[#items + 1] = {
            id = string.format("%s:%d", session.id, linkIndex),
            link = entry.link,
            name = entry.name,
            icon = entry.icon,
            quantity = entry.count,
        }
    end

    return items
end

function addon:RefreshSessionItems(forceRefresh)
    local session = self:GetCurrentSession()
    if not session.active and not forceRefresh then
        return
    end
    if not session.active and forceRefresh then
        self:StartLootSession()
        session = self:GetCurrentSession()
    end

    if forceRefresh then
        session.scanMode = "all"
    elseif session.scanMode ~= "all" then
        session.scanMode = "delta"
    end

    session.items = self:BuildSessionItemList(session.scanMode == "all")
    session.attendees = util:CloneTable(self:GetAttendees())

    local validIds = {}
    for _, item in ipairs(session.items) do
        validIds[item.id] = true
        session.responses[item.id] = session.responses[item.id] or {}
    end

    for itemId in pairs(session.responses) do
        if not validIds[itemId] then
            session.responses[itemId] = nil
        end
    end

    self:TriggerCallback("SESSION_UPDATED")
end

function addon:OnBagUpdate()
    local session = self:GetCurrentSession()
    if not session.active then
        return false
    end

    local currentSnapshot = self:BuildBagSnapshot()

    -- Post-login settle window: bags load in STAGES after a login/reload, so a single
    -- prime can baseline a partially-loaded bag and then mistake a later-loading bag's
    -- items for fresh loot (auto-posting them). While inside the settle window we keep
    -- re-baselining to the latest scan and never auto-roll. Genuine drops (you're not
    -- looting in the first seconds after a loading screen) still roll once it closes.
    if not self.bagSettleAt or (GetTime() < self.bagSettleAt) then
        session.currentSnapshot = currentSnapshot
        return false
    end

    local previous = session.currentSnapshot or {}

    -- which item links gained count since the last scan -- i.e. were just looted or
    -- traded in. These are the candidates for an automatic live roll.
    local added = {}
    local anyAdded = false
    for link, count in pairs(currentSnapshot) do
        if count > (previous[link] or 0) then
            added[link] = true
            anyAdded = true
        end
    end

    session.recentAddedLinks = {}
    for link in pairs(added) do
        session.recentAddedLinks[link] = true
    end

    session.currentSnapshot = currentSnapshot
    if not anyAdded then
        return false
    end

    if session.scanMode == "all" then
        self:RefreshSessionItems(true)
    else
        self:RefreshSessionItems()
    end

    -- newly-arrived loot auto-starts a live roll (loot-master only, gated inside)
    self:AutoRollHintedItems()
    self:AutoRollAddedItems(added)
    return true
end

function addon:SetPlayerResponse(itemId, playerName, choice)
    local session = self:GetCurrentSession()
    if self:IsItemLocked(itemId) then
        return false
    end
    if not session.responses[itemId] then
        session.responses[itemId] = {}
    end
    session.responses[itemId][util:NormalizeKey(playerName)] = normalizeResponseChoice(choice)
    self:TriggerCallback("SESSION_UPDATED")
    return true
end

function addon:GetPlayerResponse(itemId, playerName)
    local session = self:GetCurrentSession()
    local responses = session.responses[itemId] or {}
    return normalizeResponseChoice(responses[util:NormalizeKey(playerName)])
end

function addon:IsResponseActive(choice)
    choice = normalizeResponseChoice(choice)
    return choice ~= "pass"
end

function addon:GetItemById(itemId)
    for _, item in ipairs(self.session.items or {}) do
        if item.id == itemId then
            return item
        end
    end
    return nil
end

function addon:IsItemLocked(itemId)
    local session = self:GetCurrentSession()
    return session.lockedItems and session.lockedItems[itemId] == true or false
end

function addon:LockItem(itemId)
    local session = self:GetCurrentSession()
    session.lockedItems = session.lockedItems or {}
    session.lockedItems[itemId] = true
end

function addon:UnlockItem(itemId)
    local session = self:GetCurrentSession()
    session.lockedItems = session.lockedItems or {}
    session.lockedItems[itemId] = nil
end

function addon:GetResultByItemId(itemId)
    for _, result in ipairs(self.session.results or {}) do
        if result.itemId == itemId then
            return result
        end
    end
    return nil
end

function addon:RemoveResultByItemId(itemId)
    local results = self.session.results or {}
    for index = #results, 1, -1 do
        if results[index].itemId == itemId then
            table.remove(results, index)
        end
    end
end

function addon:HasLockedItems()
    local session = self:GetCurrentSession()
    for _, item in ipairs(session.items or {}) do
        if self:IsItemLocked(item.id) then
            return true
        end
    end

    return false
end

function addon:UnlockAllRolls()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can unlock rolled loot.")
        return false
    end

    if not self:HasLockedItems() then
        self:Print("Loot is already unlocked.")
        return false
    end

    self.session.lockedItems = {}
    self.session.results = {}
    self:BroadcastSession()
    self:TriggerCallback("RESULTS_UPDATED")
    self:Print("All loot unlocked for reroll.")
    return true
end
