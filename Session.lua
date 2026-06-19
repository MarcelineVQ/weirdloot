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
        attendees = {},
        itemIdsByLink = {},
        nextItemSeq = 0,
        itemOrderByLink = {},
        nextItemOrder = 0,
        resolvedHeldByLink = {},
    }
end

-- Quality from the item link's colour code. ALWAYS prefer this: the link colour is consistent,
-- whereas GetContainerItemInfo's quality field is unreliable on 3.3.5a -- it spuriously returns
-- -1 even for known, fully-cached items (observed on tier tokens AND Hearthstone, which is always
-- cached), so it is NOT just a cache-miss sentinel, the API simply returns garbage at times.
-- The API value is only used as a last resort when there's no link to read a colour from.
local qualityByHex
local function resolveQuality(link, apiQuality)
    if link then
        if not qualityByHex then
            qualityByHex = {}
            if ITEM_QUALITY_COLORS then
                -- poor(0) through legendary(5) only; artifact/heirloom aren't raid loot.
                for quality, info in pairs(ITEM_QUALITY_COLORS) do
                    if quality >= 0 and quality <= 5 and info and info.hex then
                        qualityByHex[string.lower(info.hex)] = quality
                    end
                end
            end
        end
        local hex = string.match(link, "^(|c%x%x%x%x%x%x%x%x)")
        local q = hex and qualityByHex[string.lower(hex)]
        if q then return q end
    end
    return apiQuality
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

local function getBagItemCountAndQuality(bag, slot, link)
    local _, count, _, quality = GetContainerItemInfo(bag, slot)
    quality = resolveQuality(link, quality)
    if not quality and link and link ~= "" then
        quality = select(3, GetItemInfo(link))
    end
    return count or 0, quality
end

local function getItemNameFromLink(link)
    if not link or link == "" then
        return nil
    end

    local itemName = GetItemInfo(link)
    if itemName and itemName ~= "" then
        return itemName
    end

    return string.match(link, "%[(.+)%]")
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

    -- The LootCore owns loot truth; session.items/results are projections rebuilt from it.
    -- Subscribe once: any ledger change re-projects, refreshes the UI, and (ML only) syncs.
    if self.lootCore and not self._lootCoreWired then
        self._lootCoreWired = true
        self.lootCore:On("ledgerChanged", function()
            self:RebuildLootProjections()
            self:TriggerCallback("SESSION_UPDATED")
            if self:IsAuthorizedLootMaster() then self:AutoBroadcastSession() end
        end)
    end
    self:RebuildLootProjections()
end

-- Rebuild the session.items / session.results display projections from the core ledger.
-- Runs on both the ML (after Reconcile/Resolve) and raiders (after ApplyRemote), so both
-- render from one source of truth. Names/links/icons are rendered on demand from itemId.
function addon:RebuildLootProjections()
    local core = self.lootCore
    local session = self.session
    if not core or not session then return end

    local items = {}
    for _, lot in ipairs(core:List()) do
        local name, link, icon = util:ItemRender(lot.itemId)
        items[#items + 1] = {
            id = lot.id,
            itemId = lot.itemId,
            link = link,
            name = name or link or ("item:" .. tostring(lot.itemId)),
            icon = icon,
            quantity = core:LiveCount(lot.id),
            state = lot.state,
            responses = lot.responses,          -- playerKey -> tier string
            locked = lot.state == core.STATE.RESOLVED,
        }
    end
    session.items = items

    local results = {}
    for _, lot in ipairs(core:Resolved()) do
        if lot.record then results[#results + 1] = lot.record end
    end
    session.results = results
end

function addon:BuildBagSnapshot()
    local snapshot = {}
    local minQuality = (self.db and self.db.testMode) and 0 or 4   -- test mode: any item

    for bag = 0, MAX_BAG_ID do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            local count, quality = getBagItemCountAndQuality(bag, slot, link)
            if link and count > 0 and quality and quality >= minQuality then
                snapshot[link] = (snapshot[link] or 0) + count
            end
        end
    end

    return snapshot
end

function addon:BuildManualScanCounts()
    -- Manual Scan Bags should still only surface loot the master can actually hand out.
    -- Now that quality is derived reliably from the link colour, the tradeable scan can
    -- correctly pick up tier tokens without also leaking in permanently non-tradable loot.
    return self:BuildTradeableEpicCounts()
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
            local count, quality = getBagItemCountAndQuality(bag, slot, link)
            if testMode and link and count > 0 and quality and quality >= minQuality then
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
            elseif link and count > 0 and quality and quality >= minQuality then
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
    self.session.attendees = util:CloneTable(self:GetAttendees())
    self.session.itemIdsByLink = {}
    self.session.nextItemSeq = 0
    self.session.itemOrderByLink = {}
    self.session.nextItemOrder = 0
    self.session.resolvedHeldByLink = {}

    -- Wipe the ledger and baseline the loot already in bags as idle (not fresh drops), so a
    -- session started mid-bag does not auto-roll everything the ML is already carrying.
    self.lootCore:Reset()
    local eligible = self:ItemIdCounts(self:BuildTradeableEpicCounts())
    self.session.prevEligible = eligible
    self.lootCore:Reconcile(eligible, {})

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
    self.session.prevEligible = {}
    self.lootCore:Reset()
    self:TriggerCallback("SESSION_UPDATED")
end

function addon:GetCurrentSession()
    return self.session
end

-- Convert a link-keyed count map (from the bag scans) into an itemId-keyed one. Two links
-- that share an itemId (e.g. random-suffix variants) collapse into one lot.
function addon:ItemIdCounts(linkCounts)
    local out = {}
    for link, count in pairs(linkCounts or {}) do
        local itemId = util:ItemIdFromLink(link)
        if itemId then out[itemId] = (out[itemId] or 0) + count end
    end
    return out
end

function addon:BuildSessionItemList(includeAllEpics)
    local session = self:GetCurrentSession()
    if not session.active then
        return {}
    end

    local currentSnapshot = includeAllEpics and self:BuildManualScanCounts() or self:BuildBagSnapshot()
    -- Do NOT clobber the delta baseline here. At login the bags may not be fully loaded,
    -- so storing this partial scan as session.currentSnapshot makes the next BAG_UPDATE
    -- diff the real bag against an empty baseline and auto-roll already-present loot. The
    -- baseline is owned by StartLootSession (init) and OnBagUpdate (delta); only prime it
    -- if it has never been set.
    if session.currentSnapshot == nil then
        session.currentSnapshot = currentSnapshot
    end

    local tradeableCounts = self:BuildTradeableEpicCounts()
    self:AssignPickupOrder(currentSnapshot, tradeableCounts, includeAllEpics)
    session.resolvedHeldByLink = session.resolvedHeldByLink or {}
    for link in pairs(session.resolvedHeldByLink) do
        local currentEligibleCount = includeAllEpics and (currentSnapshot[link] or 0) or (tradeableCounts[link] or 0)
        if currentEligibleCount <= 0 then
            session.resolvedHeldByLink[link] = nil
        elseif session.resolvedHeldByLink[link] > currentEligibleCount then
            session.resolvedHeldByLink[link] = currentEligibleCount
        end
    end
    local sortedLinks = {}
    for link, totalCount in pairs(currentSnapshot) do
        local eligibleCount = includeAllEpics and totalCount or (tradeableCounts[link] or 0)
        if eligibleCount > 0 then
            local heldResolved = math.min(eligibleCount, session.resolvedHeldByLink[link] or 0)
            session.resolvedHeldByLink[link] = heldResolved > 0 and heldResolved or nil
            local unresolvedCount = eligibleCount - heldResolved
            if unresolvedCount > 0 then
                local itemName, _, _, _, _, _, _, _, _, texture = GetItemInfo(link)
                sortedLinks[#sortedLinks + 1] = {
                    link = link,
                    count = unresolvedCount,
                    name = itemName or link,
                    icon = texture or "Interface\\Icons\\INV_Misc_QuestionMark",
                }
            end
        end
    end

    table.sort(sortedLinks, function(left, right)
        local leftOrder = session.itemOrderByLink[left.link] or math.huge
        local rightOrder = session.itemOrderByLink[right.link] or math.huge
        if leftOrder == rightOrder then
            return left.link < right.link
        end
        return leftOrder < rightOrder
    end)

    local items = {}
    for _, entry in ipairs(sortedLinks) do
        local currentId = session.itemIdsByLink[entry.link]
        if not currentId or self:IsItemLocked(currentId) then
            currentId = self:NextSessionItemId()
            session.itemIdsByLink[entry.link] = currentId
        end
        items[#items + 1] = {
            id = currentId,
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
        self:RebuildLootProjections()
        return
    end
    if not session.active and forceRefresh then
        self:StartLootSession()
        session = self:GetCurrentSession()
    end

    if forceRefresh and self:IsAuthorizedLootMaster() then
        -- manual Scan Bags: pick up all eligible loot and surface every open lot to the ML.
        local eligible = self:ItemIdCounts(self:BuildManualScanCounts())
        local fresh = {}
        for itemId in pairs(eligible) do fresh[itemId] = true end
        session.prevEligible = eligible
        local core = self.lootCore
        core:Reconcile(eligible, fresh)
        for _, lot in ipairs(core:List()) do
            if lot.state == core.STATE.IDLE or lot.state == core.STATE.NEW or lot.state == core.STATE.SKIPPED then
                core:Surface(lot.id)
            end
        end
    end

    session.attendees = util:CloneTable(self:GetAttendees())
    self:RebuildLootProjections()
    self:TriggerCallback("SESSION_UPDATED")
end

function addon:OnBagUpdate()
    local session = self:GetCurrentSession()
    if not session.active then
        return false
    end
    -- Only the ML reconciles bag reality into the ledger; raiders mirror via the snapshot.
    if not self:IsAuthorizedLootMaster() then
        return false
    end

    local eligible = self:ItemIdCounts(self:BuildTradeableEpicCounts())

    -- Post-login settle window: bags load in STAGES after a login/reload. While inside it we
    -- still reconcile (to baseline counts) but mark nothing fresh, so staged-loading items are
    -- never mistaken for fresh drops and auto-surfaced.
    local settled = self.bagSettleAt and (GetTime() >= self.bagSettleAt)
    local prev = session.prevEligible or {}
    local fresh = {}
    if settled then
        for itemId, count in pairs(eligible) do
            if count > (prev[itemId] or 0) then fresh[itemId] = true end
        end
    end
    session.prevEligible = eligible

    self.lootCore:Reconcile(eligible, fresh) -- ledgerChanged -> projections + auto-surface (LiveRoll)
    return true
end

function addon:SetPlayerResponse(lotId, playerName, choice)
    if self:IsItemLocked(lotId) then
        return false
    end
    -- Only the ML mutates the authoritative ledger. A raider sends its pick to the ML and
    -- waits for the snapshot to reflect it (mutating the local mirror would be overwritten).
    if not self:IsAuthorizedLootMaster() then
        self:SendSelection(lotId, choice)
        return true
    end
    local applied = self.lootCore:SetResponse(lotId, util:NormalizeKey(playerName), normalizeResponseChoice(choice))
    if applied then
        self:TriggerCallback("SESSION_UPDATED")
        if self.RefreshLiveRollCountForItem then
            self:RefreshLiveRollCountForItem(lotId)
        end
        -- SetResponse does not emit ledgerChanged (it is not a lifecycle change), so push the
        -- updated lot to the raiders explicitly. The lot is already dirty, so this is one LOTD.
        self:AutoBroadcastSession()
    end
    return applied
end

function addon:GetPlayerResponse(lotId, playerName)
    return normalizeResponseChoice(self.lootCore:GetResponse(lotId, util:NormalizeKey(playerName)))
end

function addon:IsResponseActive(choice)
    choice = normalizeResponseChoice(choice)
    return choice ~= "pass"
end

function addon:GetItemById(lotId)
    for _, item in ipairs(self.session.items or {}) do
        if item.id == lotId then
            return item
        end
    end
    return nil
end

-- Lock state now lives in the core: a lot is "locked" once it has been resolved.
function addon:IsItemLocked(lotId)
    return self.lootCore:IsResolved(lotId)
end

-- Retained as no-ops: locking/unlocking is a side effect of Resolve/Unlock in the core now.
function addon:LockItem() end
function addon:UnlockItem() end

function addon:GetResultByItemId(lotId)
    for _, result in ipairs(self.session.results or {}) do
        if result.itemId == lotId then
            return result
        end
    end
    return nil
end

function addon:RemoveResultByItemId() end

function addon:HasLockedItems()
    return #self.lootCore:Resolved() > 0
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

    self.lootCore:UnlockAll() -- ledgerChanged -> projections + snapshot broadcast
    self:TriggerCallback("RESULTS_UPDATED")
    self:Print("All loot unlocked for reroll.")
    return true
end
