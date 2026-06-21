local addon = WeirdLoot
local util = addon.util

local ROW_HEIGHT = 22
local TAB_KEYS = { "loot", "results", "raiders", "master", "options" }
local TAB_LABELS = {
    loot = "Loot",
    raiders = "Roster",
    results = "Loot Results",
    master = "Loot Master",
    options = "Options",
}
local GROUP_LOOT_TEXTURES = {
    glow = "Interface\\Buttons\\UI-ActionButton-Border",
}

local RESPONSE_BUTTONS = {
    { key = "bis", label = "BiS", width = 30 },
    { key = "ms", label = "MS", width = 26 },
    { key = "mu", label = "MU", width = 26 },
    { key = "os", label = "OS", width = 26 },
    { key = "tm", label = "TM", width = 26 },
    { key = "pass", label = "Pass", width = 34 },
}

local function isItemUsableForPlayer(itemLink)
    if not itemLink or itemLink == "" then
        return false
    end

    local _, _, _, _, _, itemType, itemSubType, _, equipLoc = GetItemInfo(itemLink)
    local _, classToken = UnitClass("player")
    local normalizedType = util:NormalizeKey(itemType or "")
    local normalizedSubType = util:NormalizeKey(itemSubType or "")
    local normalizedEquipLoc = util:NormalizeKey(equipLoc or "")

    if not classToken then
        return false
    end

    local armorByClass = {
        DEATHKNIGHT = "plate",
        DRUID = "leather",
        HUNTER = "mail",
        MAGE = "cloth",
        PALADIN = "plate",
        PRIEST = "cloth",
        ROGUE = "leather",
        SHAMAN = "mail",
        WARLOCK = "cloth",
        WARRIOR = "plate",
    }

    local weaponByClass = {
        DEATHKNIGHT = { ["one-handed axes"] = true, ["two-handed axes"] = true, ["one-handed maces"] = true, ["two-handed maces"] = true, ["one-handed swords"] = true, ["two-handed swords"] = true, polearms = true, sigils = true },
        DRUID = { daggers = true, ["fist weapons"] = true, ["one-handed maces"] = true, ["two-handed maces"] = true, polearms = true, staves = true, idols = true },
        HUNTER = { ["one-handed axes"] = true, ["two-handed axes"] = true, daggers = true, ["fist weapons"] = true, polearms = true, staves = true, ["one-handed swords"] = true, ["two-handed swords"] = true, bows = true, guns = true, crossbows = true },
        MAGE = { daggers = true, ["one-handed swords"] = true, staves = true, wands = true },
        PALADIN = { ["one-handed axes"] = true, ["two-handed axes"] = true, ["one-handed maces"] = true, ["two-handed maces"] = true, polearms = true, ["one-handed swords"] = true, ["two-handed swords"] = true, shields = true, librams = true },
        PRIEST = { daggers = true, ["one-handed maces"] = true, staves = true, wands = true },
        ROGUE = { daggers = true, ["fist weapons"] = true, ["one-handed maces"] = true, ["one-handed swords"] = true, bows = true, guns = true, crossbows = true, thrown = true },
        SHAMAN = { ["one-handed axes"] = true, ["two-handed axes"] = true, daggers = true, ["fist weapons"] = true, ["one-handed maces"] = true, ["two-handed maces"] = true, staves = true, shields = true, totems = true },
        WARLOCK = { daggers = true, ["one-handed swords"] = true, staves = true, wands = true },
        WARRIOR = { ["one-handed axes"] = true, ["two-handed axes"] = true, daggers = true, ["fist weapons"] = true, ["one-handed maces"] = true, ["two-handed maces"] = true, polearms = true, ["one-handed swords"] = true, ["two-handed swords"] = true, bows = true, guns = true, crossbows = true, thrown = true, shields = true },
    }

    if normalizedType == "armor" then
        if normalizedSubType == "cloak"
            or normalizedSubType == "miscellaneous"
            or normalizedEquipLoc == "invtype_neck"
            or normalizedEquipLoc == "invtype_finger"
            or normalizedEquipLoc == "invtype_trinket"
            or normalizedEquipLoc == "invtype_holdable"
            or normalizedEquipLoc == "invtype_shield"
            or normalizedEquipLoc == "invtype_relic" then
            if normalizedEquipLoc == "invtype_shield" then
                return weaponByClass[classToken] and weaponByClass[classToken].shields or false
            end
            if normalizedEquipLoc == "invtype_relic" then
                if normalizedSubType == "idol" or normalizedSubType == "idols" then
                    return classToken == "DRUID"
                elseif normalizedSubType == "libram" or normalizedSubType == "librams" then
                    return classToken == "PALADIN"
                elseif normalizedSubType == "totem" or normalizedSubType == "totems" then
                    return classToken == "SHAMAN"
                elseif normalizedSubType == "sigil" or normalizedSubType == "sigils" then
                    return classToken == "DEATHKNIGHT"
                end
            end
            return true
        end

        return armorByClass[classToken] == normalizedSubType
    end

    if normalizedType == "weapon" then
        local allowed = weaponByClass[classToken]
        if not allowed then
            return false
        end

        return allowed[normalizedSubType] and true or false
    end

    if type(IsUsableItem) == "function" then
        local isUsable = IsUsableItem(itemLink)
        return isUsable and true or false
    end

    return false
end

local function getLootItemColumns(itemLink)
    local _, _, _, _, _, itemType, itemSubType, _, equipLoc = GetItemInfo(itemLink or "")
    local normalizedType = util:NormalizeKey(itemType or "")
    local normalizedSubType = util:NormalizeKey(itemSubType or "")
    local normalizedEquipLoc = util:NormalizeKey(equipLoc or "")

    local slotByEquipLoc = {
        invtype_head = "Head",
        invtype_neck = "Neck",
        invtype_shoulder = "Shoulder",
        invtype_body = "Shirt",
        invtype_chest = "Chest",
        invtype_robe = "Chest",
        invtype_waist = "Waist",
        invtype_legs = "Legs",
        invtype_feet = "Feet",
        invtype_wrist = "Wrist",
        invtype_hand = "Hands",
        invtype_finger = "Finger",
        invtype_trinket = "Trinket",
        invtype_cloak = "Back",
        invtype_weapon = "Weapon",
        invtype_2hweapon = "Two-Hand",
        invtype_weaponmainhand = "Main Hand",
        invtype_weaponoffhand = "Off Hand",
        invtype_holdable = "Off Hand",
        invtype_shield = "Shield",
        invtype_ranged = "Ranged",
        invtype_rangedright = "Ranged",
        invtype_thrown = "Thrown",
        invtype_relic = "Relic",
        invtype_tabard = "Tabard",
    }

    local slotText = slotByEquipLoc[normalizedEquipLoc] or util:TitleCaseWords(normalizedSubType ~= "" and normalizedSubType or normalizedType)
    if normalizedEquipLoc == "invtype_relic" then
        slotText = util:TitleCaseWords(normalizedSubType ~= "" and normalizedSubType or "Relic")
    end

    local typeText = ""
    if normalizedType == "armor" then
        typeText = util:TitleCaseWords(normalizedSubType ~= "" and normalizedSubType or "Armor")
    elseif normalizedType == "weapon" then
        typeText = util:TitleCaseWords(normalizedSubType ~= "" and normalizedSubType or "Weapon")
    else
        typeText = util:TitleCaseWords(normalizedSubType ~= "" and normalizedSubType or normalizedType)
    end

    return typeText, slotText
end

local function getLootItemLookupName(item)
    if not item then
        return ""
    end

    local resolvedName = item.link and GetItemInfo(item.link)
    if resolvedName and resolvedName ~= "" then
        return resolvedName
    end

    if item.link and item.link ~= "" then
        local linkedName = string.match(item.link, "%[(.+)%]")
        if linkedName and linkedName ~= "" then
            return linkedName
        end
    end

    return item.name or ""
end

local function getLootItemInfoText(item)
    local lookupName = getLootItemLookupName(item)
    local entry = addon.defaultItemInfo and addon.defaultItemInfo[util:NormalizeKey(lookupName)]
    if not entry then
        return ""
    end

    local note = string.trim(entry.note or "")
    local role = string.trim(entry.role or "")
    if note ~= "" and role ~= "" then
        return string.format("%s, %s", note, role)
    end

    return note ~= "" and note or role
end

local function isPlayerAllowedForLootItem(item, playerName)
    local lookupName = getLootItemLookupName(item)
    return addon:IsPlayerAllowedForItem(lookupName, playerName)
end

local function createLabel(parent, text, anchor, relativeTo, relativePoint, offsetX, offsetY)
    local fontString = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontString:SetPoint(anchor, relativeTo, relativePoint, offsetX, offsetY)
    fontString:SetJustifyH("LEFT")
    fontString:SetText(text)
    return fontString
end

local function elevateInteractiveFrame(frame, parent, extraLevel)
    if not frame or not parent or type(parent.GetFrameLevel) ~= "function" then
        return
    end
    if type(parent.GetFrameStrata) == "function" then
        frame:SetFrameStrata(parent:GetFrameStrata())
    end
    frame:SetFrameLevel((parent:GetFrameLevel() or 0) + (extraLevel or 5))
end

local function createButton(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    elevateInteractiveFrame(button, parent, 8)
    button:SetWidth(width)
    button:SetHeight(height)
    button:SetText(text)
    return button
end

-- attach a hover tooltip (title + wrapped body) to a button
local function setButtonTooltip(button, title, body)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(title, 1, 0.82, 0)
        if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function createLootChoiceButton(parent, label, width)
    local button = CreateFrame("Button", nil, parent)
    elevateInteractiveFrame(button, parent, 8)
    button:SetWidth(width or 28)
    button:SetHeight(18)
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    button:SetBackdropColor(0.2, 0.06, 0.06, 0.95)
    button:SetBackdropBorderColor(0.55, 0.38, 0.12, 0.9)
    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.text:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.text:SetText(label or "")
    button.glow = button:CreateTexture(nil, "OVERLAY")
    button.glow:SetTexture(GROUP_LOOT_TEXTURES.glow)
    button.glow:SetBlendMode("ADD")
    button.glow:SetAlpha(0.9)
    button.glow:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.glow:SetWidth((width or 28) + 22)
    button.glow:SetHeight(34)
    button.glow:Hide()
    button:SetScript("OnDisable", function(selfButton)
        selfButton:SetAlpha(0.45)
    end)
    button:SetScript("OnEnable", function(selfButton)
        selfButton:SetAlpha(1)
    end)
    return button
end

local function setLootChoiceButtonState(button, selected)
    if not button then
        return
    end

    if selected then
        button.glow:Show()
        button:SetBackdropColor(0.42, 0.12, 0.12, 0.95)
        button:SetBackdropBorderColor(1, 0.82, 0.18, 1)
        button.text:SetTextColor(1, 0.95, 0.7)
    else
        button.glow:Hide()
        button:SetBackdropColor(0.2, 0.06, 0.06, 0.95)
        button:SetBackdropBorderColor(0.55, 0.38, 0.12, 0.9)
        button.text:SetTextColor(1, 0.82, 0)
    end
end

local function updateLootChoiceButtons(row, selectedChoice)
    for _, option in ipairs(RESPONSE_BUTTONS) do
        setLootChoiceButtonState(row.choiceButtons and row.choiceButtons[option.key], selectedChoice == option.key)
    end
end

local function updateLootMasterControlButtons(row, isVisible, activeRoll, isLocked)
    if not row.startStopButton or not row.skipCancelButton then
        return
    end

    if isVisible then
        row.startStopButton:Show()
        row.skipCancelButton:Show()
        row.startStopButton.text:SetText(activeRoll and "End" or "Start")
        row.skipCancelButton.text:SetText(activeRoll and "Cancel" or "Skip")
        if activeRoll or not isLocked then
            row.startStopButton:Enable()
            row.skipCancelButton:Enable()
        else
            row.startStopButton:Disable()
            row.skipCancelButton:Disable()
        end
    else
        row.startStopButton:Hide()
        row.skipCancelButton:Hide()
    end
end

local function applyLootChoiceAvailability(row, isLocked, isAllowed)
    for _, option in ipairs(RESPONSE_BUTTONS) do
        local button = row.choiceButtons[option.key]
        if isLocked then
            button:Disable()
        elseif not isAllowed and option.key ~= "pass" then
            button:Disable()
        else
            button:Enable()
        end
    end
end

local function createBackdropFrame(name, parent)
    local frame = CreateFrame("Frame", name, parent)
    elevateInteractiveFrame(frame, parent, 1)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
    return frame
end

local function createTextWindow(name, width, height, titleText, options)
    options = options or {}
    local frame = createBackdropFrame(name, UIParent)
    frame:SetWidth(width)
    frame:SetHeight(height)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(selfFrame)
        selfFrame:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(selfFrame)
        selfFrame:StopMovingOrSizing()
    end)
    frame:Hide()

    local title = createLabel(frame, titleText or "", "TOPLEFT", frame, "TOPLEFT", 16, -14)
    title:SetFontObject(GameFontHighlightLarge)

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    elevateInteractiveFrame(closeButton, frame, 10)
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local scroll = CreateFrame("ScrollFrame", name .. "Scroll", frame, "UIPanelScrollFrameTemplate")
    elevateInteractiveFrame(scroll, frame, 6)
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -42)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, options.showSaveButton and 44 or 12)

    local editBox = CreateFrame("EditBox", name .. "EditBox", scroll)
    elevateInteractiveFrame(editBox, frame, 7)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(width - 56)
    editBox:SetHeight(height - 72)
    editBox:SetAutoFocus(false)
    editBox:EnableMouse(true)
    editBox:SetTextInsets(4, 4, 4, 4)
    editBox:SetScript("OnEscapePressed", function()
        editBox:ClearFocus()
        frame:Hide()
    end)
    editBox:SetScript("OnEditFocusGained", function()
        if options.highlightOnFocus then
            editBox:HighlightText()
        end
    end)
    if options.readOnly then
        editBox:SetScript("OnTextChanged", function(selfBox)
            selfBox:HighlightText()
        end)
    end
    scroll:SetScrollChild(editBox)

    local saveButton
    if options.showSaveButton then
        saveButton = createButton(frame, options.saveButtonText or "Save", 90, 22)
        saveButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 12)
        saveButton:SetScript("OnClick", function()
            if options.onSave then
                options.onSave(editBox:GetText() or "", frame)
            end
        end)
    end

    frame.title = title
    frame.scroll = scroll
    frame.editBox = editBox
    frame.saveButton = saveButton
    return frame
end

local function buildPlainCandidateSummary(candidate)
    return table.concat({
        candidate.name or "Unknown",
        util:TitleCaseWords(string.trim((candidate.className or "") .. " " .. (candidate.specName or ""))),
        util:PlayerDisplayStatus(candidate.status),
    }, " - ")
end

local function formatSpecPriorityDisplay(specPriorityText)
    local normalized = string.trim(specPriorityText or "")
    if normalized == "" then
        return "none"
    end

    local tiers = {}
    for _, tierText in ipairs(util:Split(normalized, ">")) do
        tierText = string.trim(tierText)
        if tierText ~= "" then
            if string.find(tierText, "/", 1, true) then
                local formattedEntries = {}
                for _, entryText in ipairs(util:Split(tierText, "/")) do
                    entryText = string.trim(entryText)
                    formattedEntries[#formattedEntries + 1] = util:NormalizeKey(entryText) == "lc" and "LC" or util:TitleCaseWords(entryText)
                end
                tiers[#tiers + 1] = table.concat(formattedEntries, " / ")
            else
                tiers[#tiers + 1] = util:NormalizeKey(tierText) == "lc" and "LC" or util:TitleCaseWords(tierText)
            end
        end
    end

    if #tiers == 0 then
        return "none"
    end

    return table.concat(tiers, "\n---\n")
end

local function createScrollList(parent, name, rowCount, initializer)
    local frame = createBackdropFrame(name, parent)
    frame.scroll = CreateFrame("ScrollFrame", name .. "Scroll", frame, "FauxScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", 0, -4)
    frame.scroll:SetPoint("BOTTOMRIGHT", -26, 4)

    frame.rows = {}
    for index = 1, rowCount do
        local row = CreateFrame("Button", name .. "Row" .. index, frame)
        elevateInteractiveFrame(row, frame, 4)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("LEFT", 6, 0)
        row:SetPoint("RIGHT", -6, 0)
        if index == 1 then
            row:SetPoint("TOP", frame, "TOP", 0, -8)
        else
            row:SetPoint("TOP", frame.rows[index - 1], "BOTTOM", 0, -2)
        end
        initializer(row, index)
        frame.rows[index] = row
    end

    frame.update = function(totalCount, updater)
        frame.totalCount = totalCount
        frame.rowUpdater = updater
        local offset = FauxScrollFrame_GetOffset(frame.scroll)
        FauxScrollFrame_Update(frame.scroll, totalCount, rowCount, ROW_HEIGHT)
        for index, row in ipairs(frame.rows) do
            local dataIndex = index + offset
            updater(row, dataIndex)
        end
    end

    frame.scroll:SetScript("OnVerticalScroll", function(scrollFrame, offset)
        FauxScrollFrame_OnVerticalScroll(scrollFrame, offset, ROW_HEIGHT, function()
            if frame.rowUpdater then
                frame.update(frame.totalCount or 0, frame.rowUpdater)
            end
        end)
    end)

    return frame
end

function addon:InitializeUI()
    self.ui = self.ui or {}

    local frame = createBackdropFrame("WeirdLootFrame", UIParent)
    frame:SetWidth(980)
    frame:SetHeight(640)
    frame:SetPoint("CENTER", UIParent, "CENTER", self.db.ui.frame.x or 0, self.db.ui.frame.y or 0)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetToplevel(true)
    frame:SetFrameLevel(1000)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(selfFrame)
        selfFrame:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(selfFrame)
        selfFrame:StopMovingOrSizing()
        local _, _, _, x, y = selfFrame:GetPoint()
        addon.db.ui.frame.x = x
        addon.db.ui.frame.y = y
    end)
    frame:SetScript("OnShow", function(selfFrame)
        selfFrame:Raise()
    end)
    frame:Hide()

    tinsert(UISpecialFrames, "WeirdLootFrame")

    local title = createLabel(frame, "WeirdLoot", "TOPLEFT", frame, "TOPLEFT", 16, -14)
    title:SetFontObject(GameFontHighlightLarge)

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    elevateInteractiveFrame(closeButton, frame, 10)
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local status = createLabel(frame, "", "TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    status:SetWidth(720)

    local content = CreateFrame("Frame", nil, frame)
    elevateInteractiveFrame(content, frame, 4)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -64)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 44)

    self.ui.frame = frame
    self.ui.status = status
    self.ui.content = content
    self.ui.tabs = {}
    self.ui.panels = {}
    self.ui.selectedTab = self.db.ui.selectedTab or "loot"

    self:BuildLootTab()
    self:BuildRaidersTab()
    self:BuildResultsTab()
    self:BuildMasterTab()
    self:BuildOptionsTab()
    self:BuildBottomTabs()
    self:BuildMinimapButton()

    self:RegisterCallback("STATE_UPDATED", function()
        addon:RefreshUI()
    end)
    self:RegisterCallback("CONFIG_UPDATED", function()
        addon:RefreshUI()
    end)
    self:RegisterCallback("ROSTER_UPDATED", function()
        addon:RefreshUI()
    end)
    self:RegisterCallback("AUTHORITY_UPDATED", function()
        addon:RefreshUI()
    end)
    self:RegisterCallback("SESSION_UPDATED", function()
        addon:RefreshUI()
    end)
    self:RegisterCallback("RESULTS_UPDATED", function()
        addon:RefreshUI()
    end)

    self:SelectTab(self.ui.selectedTab)
    self:RefreshUI()
end

function addon:BuildBottomTabs()
    local previous
    for _, key in ipairs(TAB_KEYS) do
        local tab = createButton(self.ui.frame, TAB_LABELS[key], 120, 24)
        if not previous then
            tab:SetPoint("BOTTOMLEFT", self.ui.frame, "BOTTOMLEFT", 16, 12)
        else
            tab:SetPoint("LEFT", previous, "RIGHT", 8, 0)
        end
        tab:SetScript("OnClick", function()
            addon:SelectTab(key)
        end)
        self.ui.tabs[key] = tab
        previous = tab
    end

    local versionLabel = self.ui.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    versionLabel:SetPoint("BOTTOMRIGHT", self.ui.frame, "BOTTOMRIGHT", -16, 18)
    versionLabel:SetWidth(120)
    versionLabel:SetJustifyH("RIGHT")
    versionLabel:SetText("v" .. tostring(addon.version or "1.0"))
    self.ui.versionLabel = versionLabel
end

function addon:SelectTab(tabKey)
    self.ui.selectedTab = tabKey
    self.db.ui.selectedTab = tabKey

    for key, panel in pairs(self.ui.panels) do
        if key == tabKey then
            panel:Show()
        else
            panel:Hide()
        end
    end

    self:RefreshUI()
end

function addon:ToggleMainFrame()
    if not self.ui or not self.ui.frame then
        self:Print("UI is not initialized yet. If this keeps happening, reload the UI and check script errors.")
        return
    end

    if self.ui.frame:IsShown() then
        self.ui.frame:Hide()
    else
        self.ui.frame:Show()
        self:RefreshUI()
    end
end

function addon:TradeSelectedWinner()
    local result = self.ui and self.ui.selectedResult
    local winner = result and result.winner
    if not result or not winner or winner == "" or winner == "No winner" then
        self:Print("No winner is selected for trade.")
        return
    end

    if UnitExists("target") and util:NormalizeKey(util:GetPlayerName("target") or "") == util:NormalizeKey(winner) then
        InitiateTrade("target")
    else
        self:Print("Click Target Winner first, then click Trade Winner.")
    end
end

-- Fill the open trade from the loot ledger via the TradeDeliver engine. Routes
-- manual delivery through the same filler as auto-payout (stack/split-correct,
-- soonest-to-expire first) instead of hand-placing an item, so the two never
-- double-fill the same trade window.
function addon:FillSelectedTrade()
    self:FillOpenTrade()
end

function addon:UnlockAllSessionRolls()
    self:UnlockAllRolls()
end

function addon:BuildWinnersExportText()
    local lines = {}

    for _, result in ipairs(self.session.results or {}) do
        local itemName = result.itemName or ""
        if result.winners and #result.winners > 0 then
            for _, winnerName in ipairs(result.winners) do
                lines[#lines + 1] = string.format("%s\t%s", itemName, winnerName or "")
            end
        elseif result.isLootCouncil then
            lines[#lines + 1] = string.format("%s\t%s", itemName, "Loot Council")
        else
            lines[#lines + 1] = string.format("%s\t%s", itemName, "No winner")
        end
    end

    if #lines == 0 then
        return ""
    end

    return table.concat(lines, "\n")
end

function addon:BuildDetailedExportLogText()
    local blocks = {}
    local groups = {
        { key = "bis", label = "BiS Rollers:" },
        { key = "ms", label = "MS Rollers:" },
        { key = "mu", label = "MU Rollers:" },
        { key = "os", label = "OS Rollers:" },
        { key = "tm", label = "TM Rollers:" },
    }

    for _, result in ipairs(self.session.results or {}) do
        local groupedRollers = {
            bis = {},
            ms = {},
            mu = {},
            os = {},
            tm = {},
        }
        local lines = {}
        local quantityText = (result.quantity or 1) > 1 and string.format(" x%d", result.quantity or 1) or ""
        local lcNamesText = string.trim(result.lcNamesText or "")
        local hasLcNames = lcNamesText ~= "" and lcNamesText ~= "none"
        lines[#lines + 1] = "Item: " .. (result.itemName or "") .. quantityText
        lines[#lines + 1] = ""

        for _, roller in ipairs(result.allRollerDetails or {}) do
            local choice = roller.responseType or "pass"
            if choice ~= "pass" then
                groupedRollers[choice] = groupedRollers[choice] or {}
                groupedRollers[choice][#groupedRollers[choice] + 1] = roller
            end
        end

        local renderedGroups = 0
        for _, group in ipairs(groups) do
            local entries = groupedRollers[group.key] or {}
            if #entries > 0 then
                if renderedGroups > 0 then
                    lines[#lines + 1] = ""
                end

                lines[#lines + 1] = group.label
                for _, roller in ipairs(entries) do
                    local rollText = roller.rollText and (" - (" .. roller.rollText .. ")") or ""
                    lines[#lines + 1] = buildPlainCandidateSummary(roller) .. rollText
                end
                renderedGroups = renderedGroups + 1
            end
        end

        if renderedGroups > 0 then
            lines[#lines + 1] = ""
        end

        if hasLcNames then
            lines[#lines + 1] = "LC Names:"
            lines[#lines + 1] = lcNamesText
            lines[#lines + 1] = ""
        end

        lines[#lines + 1] = "Spec Priority:"
        lines[#lines + 1] = formatSpecPriorityDisplay(result.specPriorityText)
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Prioritized Rolls:"
        if #(result.rollDetails or {}) == 0 then
            lines[#lines + 1] = "none"
        else
            for _, roll in ipairs(result.rollDetails or {}) do
                local rollValue = roll.auto and "AUTO" or tostring(roll.roll or "")
                local namedText = roll.isNamed and " - LC" or ""
                lines[#lines + 1] = string.format("%s - (%s)%s", buildPlainCandidateSummary(roll), rollValue, namedText)
            end
        end

        lines[#lines + 1] = ""
        lines[#lines + 1] = "Winner:"
        if result.isLootCouncil then
            lines[#lines + 1] = "Loot Council"
        elseif #(result.winnerDetails or {}) == 0 then
            lines[#lines + 1] = "No winner"
        else
            for _, winner in ipairs(result.winnerDetails or {}) do
                local rollValue = winner.auto and "AUTO" or tostring(winner.roll or "")
                lines[#lines + 1] = string.format("%s (%s)", winner.name or "Unknown", rollValue)
            end
        end

        blocks[#blocks + 1] = table.concat(lines, "\n")
    end

    return table.concat(blocks, "\n\n")
end

function addon:ShowExportWindow(kind, titleText, bodyText)
    self.ui = self.ui or {}
    self.ui.exportWindows = self.ui.exportWindows or {}

    local window = self.ui.exportWindows[kind]
    if not window then
        window = createTextWindow("WeirdLoot" .. kind .. "ExportWindow", 720, 520, titleText, {
            readOnly = true,
            highlightOnFocus = true,
        })
        self.ui.exportWindows[kind] = window
    end

    window.title:SetText(titleText or "")
    window.editBox:SetText(bodyText or "")
    window.editBox:SetFocus()
    window.editBox:HighlightText()
    window.scroll:SetVerticalScroll(0)
    window:Show()
end

function addon:ShowImportWindow(kind, titleText, bodyText, onSave)
    self.ui = self.ui or {}
    self.ui.importWindows = self.ui.importWindows or {}

    local window = self.ui.importWindows[kind]
    if not window then
        window = createTextWindow("WeirdLoot" .. kind .. "ImportWindow", 720, 520, titleText, {
            showSaveButton = true,
            saveButtonText = "Save Import",
        })
        self.ui.importWindows[kind] = window
    end

    window.saveButton:SetScript("OnClick", function()
        if onSave then
            onSave(window.editBox:GetText() or "")
        end
        window.editBox:ClearFocus()
        window:Hide()
    end)

    window.title:SetText(titleText or "")
    window.editBox:SetText(bodyText or "")
    window.editBox:SetFocus()
    window.scroll:SetVerticalScroll(0)
    window:Show()
end

function addon:ExportWinners()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can export winners.")
        return
    end

    self:ShowExportWindow("Winners", "Export Winners", self:BuildWinnersExportText())
end

function addon:ExportLog()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can export the log.")
        return
    end

    self:ShowExportWindow("Log", "Export Log", self:BuildDetailedExportLogText())
end

function addon:ImportRoster()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can import the roster.")
        return
    end

    self:ShowImportWindow("Roster", "Import Roster", self.config.rosterImportText or "", function(text)
        addon:SaveImports(text, addon.config.lootPriorityText, addon.config.namedItemsText)
    end)
end

function addon:ImportNamedItems()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can import named items.")
        return
    end

    self:ShowImportWindow("NamedItems", "Import Named Items", self.config.namedItemsText or "", function(text)
        addon:SaveImports(addon.config.rosterImportText, addon.config.lootPriorityText, text)
    end)
end

function addon:BuildLootTab()
    local panel = CreateFrame("Frame", nil, self.ui.content)
    elevateInteractiveFrame(panel, self.ui.content, 2)
    panel:SetAllPoints(self.ui.content)
    self.ui.panels.loot = panel

    local header = createLabel(panel, "Session items", "TOPLEFT", panel, "TOPLEFT", 4, -4)
    header:SetFontObject(GameFontHighlight)

    local syncButton = createButton(panel, "Request Sync", 110, 22)
    syncButton:SetPoint("LEFT", header, "RIGHT", 12, 0)
    syncButton:SetScript("OnClick", function()
        addon:RequestSessionSync()
    end)
    panel.syncButton = syncButton

    local usabilityButton = createButton(panel, "Usable: Off", 110, 22)
    usabilityButton:SetPoint("LEFT", syncButton, "RIGHT", 8, 0)
    usabilityButton:SetScript("OnClick", function()
        addon:ToggleLootUsabilitySort()
    end)
    panel.usabilityButton = usabilityButton

    local headerName = createButton(panel, "Name", 80, 18)
    headerName:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 24, -12)
    headerName:SetScript("OnClick", function()
        addon:SetLootSortMode("name")
    end)
    panel.headerName = headerName

    local headerChoice = createButton(panel, "Roll Type", 204, 18)
    headerChoice:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 228, -12)
    headerChoice:SetScript("OnClick", function() end)
    panel.headerChoice = headerChoice

    local headerType = createButton(panel, "Type", 54, 18)
    headerType:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 490, -12)
    headerType:SetScript("OnClick", function()
        addon:SetLootSortMode("type")
    end)
    panel.headerType = headerType

    local headerSlot = createButton(panel, "Slot", 54, 18)
    headerSlot:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 548, -12)
    headerSlot:SetScript("OnClick", function()
        addon:SetLootSortMode("slot")
    end)
    panel.headerSlot = headerSlot

    local headerInfo = createButton(panel, "Info", 70, 18)
    headerInfo:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 608, -12)
    headerInfo:SetScript("OnClick", function()
        addon:SetLootSortMode("info")
    end)
    panel.headerInfo = headerInfo

    local headerRollers = createButton(panel, "Rollers", 80, 18)
    headerRollers:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 804, -12)
    headerRollers:SetScript("OnClick", function() end)
    panel.headerRollers = headerRollers

    local list = createScrollList(panel, "WeirdLootLootList", 19, function(row)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(18)
        row.icon:SetHeight(18)
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)

        row.name = createLabel(row, "", "LEFT", row.icon, "RIGHT", 8, 0)
        row.name:SetWidth(176)

        row.startStopButton = createLootChoiceButton(row, "Start", 42)
        row.startStopButton:SetPoint("LEFT", row, "LEFT", 210, 0)
        row.startStopButton:SetScript("OnClick", function()
            if not row.item or not addon:IsAuthorizedLootMaster() then
                return
            end

            local activeRoll = addon:GetActiveLiveRollForItem(row.item)
            if activeRoll then
                addon:ResolveLiveRoll(activeRoll.id)
            else
                addon:StartLiveRollFromItem(row.item)
            end
        end)
        row.startStopButton:Hide()

        row.skipCancelButton = createLootChoiceButton(row, "Skip", 46)
        row.skipCancelButton:SetPoint("LEFT", row.startStopButton, "RIGHT", 2, 0)
        row.skipCancelButton:SetScript("OnClick", function()
            if not row.item or not addon:IsAuthorizedLootMaster() then
                return
            end

            local activeRoll = addon:GetActiveLiveRollForItem(row.item)
            if activeRoll then
                addon:CancelLiveRoll(activeRoll.id)
            else
                addon:SkipLiveLootItem(row.item)
            end
        end)
        row.skipCancelButton:Hide()

        row.choiceButtons = {}
        local previousButton
        for _, option in ipairs(RESPONSE_BUTTONS) do
            local responseButton = createLootChoiceButton(row, option.label, option.width)
            if not previousButton then
                responseButton:SetPoint("LEFT", row.skipCancelButton, "RIGHT", 4, 0)
            else
                responseButton:SetPoint("LEFT", previousButton, "RIGHT", 2, 0)
            end
            responseButton:SetScript("OnClick", function()
                if not row.item then
                    return
                end
                if addon:IsItemLocked(row.item.id) then
                    addon:Print("That loot is locked. Ask the loot master to unlock it before changing rolls.")
                    return
                end

                local playerName = util:GetPlayerName("player")
                if option.key ~= "pass" and not isPlayerAllowedForLootItem(row.item, playerName) then
                    addon:Print("Your class cannot use that token. You may only pass.")
                    return
                end
                local activeRoll = addon:GetActiveLiveRollForItem(row.item)
                if not addon:SetPlayerResponse(row.item.id, playerName, option.key) then
                    return
                end
                if activeRoll then
                    addon:SendInterest(activeRoll.id, option.key)
                else
                    addon:BroadcastSelectionState(row.item.id, playerName, option.key)
                    addon:SendSelection(row.item.id, option.key)
                end
                updateLootChoiceButtons(row, option.key)
            end)
            row.choiceButtons[option.key] = responseButton
            previousButton = responseButton
        end

        row.itemType = createLabel(row, "", "LEFT", row, "LEFT", 490, 0)
        row.itemType:SetWidth(52)

        row.itemSlot = createLabel(row, "", "LEFT", row, "LEFT", 548, 0)
        row.itemSlot:SetWidth(54)

        row.info = createLabel(row, "", "LEFT", row, "LEFT", 608, 0)
        row.info:SetWidth(188)

        row.state = createLabel(row, "", "LEFT", row, "LEFT", 804, 0)
        row.state:SetWidth(80)
        row.state:SetJustifyH("LEFT")
        row.stateHitbox = CreateFrame("Frame", nil, row)
        elevateInteractiveFrame(row.stateHitbox, row, 10)
        row.stateHitbox:SetPoint("TOPLEFT", row.state, "TOPLEFT", -4, 4)
        row.stateHitbox:SetPoint("BOTTOMRIGHT", row.state, "BOTTOMRIGHT", 4, -4)
        row.stateHitbox:EnableMouse(true)
        row.stateHitbox:SetScript("OnEnter", function()
            GameTooltip:Hide()
            if not row.item then
                return
            end

            GameTooltip:SetOwner(row.stateHitbox, "ANCHOR_NONE")
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("TOPLEFT", row.stateHitbox, "BOTTOMLEFT", 0, -4)
            GameTooltip:ClearLines()
            GameTooltip:AddLine("Players Rolling", 1, 0.82, 0)

            local entries = addon:GetLiveRollEntriesForItem(row.item)
            if entries and #entries > 0 then
                for _, entry in ipairs(entries) do
                    local colorCode = util:GetClassColorCode(entry.className) or "|cffffffff"
                    GameTooltip:AddLine(string.format("%s%s|r - %d - %s",
                        colorCode,
                        entry.name or "Unknown",
                        entry.roll or 0,
                        addon:GetResponseLabel(entry.tier)), 1, 1, 1)
                end
            else
                local rollers = addon:BuildRollerList(row.item.id) or {}
                table.sort(rollers, function(left, right)
                    return string.lower(left.name or "") < string.lower(right.name or "")
                end)
                if #rollers == 0 then
                    GameTooltip:AddLine("No active rollers", 1, 1, 1)
                else
                    for _, roller in ipairs(rollers) do
                        local colorCode = util:GetClassColorCode(roller.className) or "|cffffffff"
                        GameTooltip:AddLine(string.format("%s%s|r - %s",
                            colorCode,
                            roller.name or "Unknown",
                            string.upper(roller.responseType or "pass")), 1, 1, 1)
                    end
                end
            end

            GameTooltip:Show()
        end)
        row.stateHitbox:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        row:SetScript("OnEnter", function(selfRow)
            if not selfRow.item or not selfRow.item.link or selfRow.item.link == "" then
                return
            end

            GameTooltip:SetOwner(selfRow, "ANCHOR_LEFT")
            GameTooltip:SetHyperlink(selfRow.item.link)
            GameTooltip:Show()
        end)

        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        row:SetScript("OnClick", function(selfRow, button)
            if not selfRow.item or not selfRow.item.link or selfRow.item.link == "" then
                return
            end

            if button == "RightButton" then
                if addon:IsAuthorizedLootMaster() then
                    addon:StartLiveRollFromItem(selfRow.item)
                end
                return
            end

            if button ~= "LeftButton" then
                return
            end

            if IsShiftKeyDown() and ChatEdit_GetActiveWindow() then
                ChatEdit_InsertLink(selfRow.item.link)
                return
            end

            -- Plain click does nothing; ctrl+click previews in the dressing room, matching
            -- the standard modified-click behavior of item links everywhere else.
            if IsModifiedClick("DRESSUP") then
                if DressUpItemLink then
                    DressUpItemLink(selfRow.item.link)
                else
                    GameTooltip:SetOwner(selfRow, "ANCHOR_NONE")
                    GameTooltip:ClearAllPoints()
                    GameTooltip:SetPoint("TOPRIGHT", selfRow, "TOPLEFT", -8, 0)
                    GameTooltip:SetHyperlink(selfRow.item.link)
                    GameTooltip:Show()
                end
            end
        end)
    end)
    list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -28)
    list:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    self.ui.lootList = list
end

function addon:ToggleLootSortMode()
    self.db.ui.lootSortMode = self.db.ui.lootSortMode == "gear" and "name" or "gear"
    self:RefreshLootTab()
end

function addon:SetLootSortMode(sortMode)
    self.db.ui.lootSortMode = sortMode or "name"
    self:RefreshLootTab()
end

function addon:ToggleLootUsabilitySort()
    self.db.ui.lootUsabilitySort = not self.db.ui.lootUsabilitySort
    self:RefreshLootTab()
end

function addon:GetSortedLootItems()
    local items = {}
    for _, item in ipairs(self.session.items or {}) do
        items[#items + 1] = item
    end

    local sortMode = self.db.ui.lootSortMode or "name"
    if sortMode == "gear" then
        table.sort(items, function(left, right)
            if self.db.ui.lootUsabilitySort then
                local leftUsable = isItemUsableForPlayer(left.link)
                local rightUsable = isItemUsableForPlayer(right.link)
                if leftUsable ~= rightUsable then
                    return leftUsable
                end
            end

            local leftInfo = util:GetLootSortInfo(left.link)
            local rightInfo = util:GetLootSortInfo(right.link)

            if leftInfo.order ~= rightInfo.order then
                return leftInfo.order < rightInfo.order
            end
            if leftInfo.subtype ~= rightInfo.subtype then
                return leftInfo.subtype < rightInfo.subtype
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end)
    elseif sortMode == "type" then
        table.sort(items, function(left, right)
            if self.db.ui.lootUsabilitySort then
                local leftUsable = isItemUsableForPlayer(left.link)
                local rightUsable = isItemUsableForPlayer(right.link)
                if leftUsable ~= rightUsable then
                    return leftUsable
                end
            end

            local leftType = util:NormalizeKey(select(1, getLootItemColumns(left.link)))
            local rightType = util:NormalizeKey(select(1, getLootItemColumns(right.link)))
            if leftType ~= rightType then
                return leftType < rightType
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end)
    elseif sortMode == "slot" then
        table.sort(items, function(left, right)
            if self.db.ui.lootUsabilitySort then
                local leftUsable = isItemUsableForPlayer(left.link)
                local rightUsable = isItemUsableForPlayer(right.link)
                if leftUsable ~= rightUsable then
                    return leftUsable
                end
            end

            local leftSlot = util:NormalizeKey(select(2, getLootItemColumns(left.link)))
            local rightSlot = util:NormalizeKey(select(2, getLootItemColumns(right.link)))
            if leftSlot ~= rightSlot then
                return leftSlot < rightSlot
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end)
    elseif sortMode == "info" then
        table.sort(items, function(left, right)
            if self.db.ui.lootUsabilitySort then
                local leftUsable = isItemUsableForPlayer(left.link)
                local rightUsable = isItemUsableForPlayer(right.link)
                if leftUsable ~= rightUsable then
                    return leftUsable
                end
            end

            local leftInfo = util:NormalizeKey(getLootItemInfoText(left))
            local rightInfo = util:NormalizeKey(getLootItemInfoText(right))
            if leftInfo ~= rightInfo then
                return leftInfo < rightInfo
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end)
    else
        table.sort(items, function(left, right)
            if self.db.ui.lootUsabilitySort then
                local leftUsable = isItemUsableForPlayer(left.link)
                local rightUsable = isItemUsableForPlayer(right.link)
                if leftUsable ~= rightUsable then
                    return leftUsable
                end
            end

            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end)
    end

    return items
end

function addon:SetRosterSortMode(sortMode)
    self.db.ui.rosterSortMode = sortMode or "name"
    self:RefreshRaidersTab()
end

function addon:GetSortedRosterEntries()
    local entries = util:CloneTable(self:GetRosterDisplayList() or {})
    local sortMode = self.db.ui.rosterSortMode or "name"

    table.sort(entries, function(left, right)
        if sortMode == "raid" then
            if left.present ~= right.present then
                return left.present
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        elseif sortMode == "classspec" then
            local leftClassSpec = util:NormalizeKey(string.trim((left.className or "") .. " " .. (left.specName or "")))
            local rightClassSpec = util:NormalizeKey(string.trim((right.className or "") .. " " .. (right.specName or "")))
            if leftClassSpec ~= rightClassSpec then
                return leftClassSpec < rightClassSpec
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        elseif sortMode == "status" then
            local leftRank = util:StatusRank(left.status)
            local rightRank = util:StatusRank(right.status)
            if leftRank ~= rightRank then
                return leftRank > rightRank
            end
            return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
        end

        return util:NormalizeKey(left.name or "") < util:NormalizeKey(right.name or "")
    end)

    return entries
end

function addon:BuildRaidersTab()
    local panel = CreateFrame("Frame", nil, self.ui.content)
    elevateInteractiveFrame(panel, self.ui.content, 2)
    panel:SetAllPoints(self.ui.content)
    self.ui.panels.raiders = panel

    local summary = createLabel(panel, "", "TOPLEFT", panel, "TOPLEFT", 8, -6)
    summary:SetWidth(760)
    summary:SetTextColor(0.9, 0.82, 0.5)

    local rosterFrame = createBackdropFrame("WeirdLootRaidersFrame", panel)
    rosterFrame:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -10)
    rosterFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 0)

    local headerPresence = createButton(rosterFrame, "Raid", 54, 18)
    headerPresence:SetPoint("TOPLEFT", rosterFrame, "TOPLEFT", 6, -6)
    headerPresence:SetScript("OnClick", function()
        addon:SetRosterSortMode("raid")
    end)

    local headerName = createButton(rosterFrame, "Name", 132, 18)
    headerName:SetPoint("LEFT", headerPresence, "RIGHT", 8, 0)
    headerName:SetScript("OnClick", function()
        addon:SetRosterSortMode("name")
    end)

    local headerClassSpec = createButton(rosterFrame, "Class / Spec", 200, 18)
    headerClassSpec:SetPoint("LEFT", headerName, "RIGHT", 4, 0)
    headerClassSpec:SetScript("OnClick", function()
        addon:SetRosterSortMode("classspec")
    end)

    local headerStatus = createButton(rosterFrame, "Status", 110, 18)
    headerStatus:SetPoint("LEFT", headerClassSpec, "RIGHT", 12, 0)
    headerStatus:SetScript("OnClick", function()
        addon:SetRosterSortMode("status")
    end)

    local headerSource = createButton(rosterFrame, "Source", 80, 18)
    headerSource:SetPoint("LEFT", headerStatus, "RIGHT", 12, 0)
    headerSource:SetScript("OnClick", function()
    end)

    local list = createScrollList(rosterFrame, "WeirdLootRaidersList", 18, function(row)
        row.present = createLabel(row, "", "LEFT", row, "LEFT", 8, 0)
        row.present:SetWidth(48)
        row.name = createLabel(row, "", "LEFT", row.present, "RIGHT", 14, 0)
        row.name:SetWidth(132)
        row.classSpec = createLabel(row, "", "LEFT", row.name, "RIGHT", 4, 0)
        row.classSpec:SetWidth(200)
        row.status = createLabel(row, "", "LEFT", row.classSpec, "RIGHT", 12, 0)
        row.status:SetWidth(110)
        row.source = createLabel(row, "", "LEFT", row.status, "RIGHT", 12, 0)
        row.source:SetWidth(80)
    end)
    list:SetPoint("TOPLEFT", headerPresence, "BOTTOMLEFT", 0, -8)
    list:SetPoint("BOTTOMRIGHT", rosterFrame, "BOTTOMRIGHT", -6, 6)
    self.ui.raidersList = list
    self.ui.raidersSummary = summary
end

function addon:BuildResultsTab()
    local panel = CreateFrame("Frame", nil, self.ui.content)
    elevateInteractiveFrame(panel, self.ui.content, 2)
    panel:SetAllPoints(self.ui.content)
    self.ui.panels.results = panel

    local list = createScrollList(panel, "WeirdLootResultsList", 16, function(row)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(18)
        row.icon:SetHeight(18)
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)

        row.name = createLabel(row, "", "LEFT", row.icon, "RIGHT", 8, 0)
        row.name:SetWidth(290)
        row.winner = createLabel(row, "", "LEFT", row.name, "RIGHT", 12, 0)
        row.winner:SetWidth(200)

        row:SetScript("OnEnter", function(selfRow)
            local result = selfRow.result
            if not result or not result.itemLink or result.itemLink == "" then
                return
            end

            GameTooltip:SetOwner(selfRow, "ANCHOR_LEFT")
            GameTooltip:SetHyperlink(result.itemLink)
            GameTooltip:Show()
        end)

        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        row:SetScript("OnClick", function()
            if row.result then
                addon.ui.selectedResult = row.result
                addon:RefreshUI()
            end

            if not row.result or not row.result.itemLink or row.result.itemLink == "" then
                return
            end

            if IsShiftKeyDown() and ChatEdit_GetActiveWindow() then
                ChatEdit_InsertLink(row.result.itemLink)
                return
            end

            -- Plain click only selects the row; ctrl+click previews in the dressing room.
            if IsModifiedClick("DRESSUP") then
                if DressUpItemLink then
                    DressUpItemLink(row.result.itemLink)
                else
                    GameTooltip:SetOwner(row, "ANCHOR_NONE")
                    GameTooltip:ClearAllPoints()
                    GameTooltip:SetPoint("TOPRIGHT", row, "TOPLEFT", -8, 0)
                    GameTooltip:SetHyperlink(row.result.itemLink)
                    GameTooltip:Show()
                end
            end
        end)
    end)
    list:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    list:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
    list:SetWidth(520)

    local detailFrame = createBackdropFrame("WeirdLootResultDetail", panel)
    detailFrame:SetPoint("TOPLEFT", list, "TOPRIGHT", 8, 0)
    detailFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

    local itemHeader = CreateFrame("Button", nil, detailFrame)
    elevateInteractiveFrame(itemHeader, detailFrame, 6)
    itemHeader:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 8, -8)
    itemHeader:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -30, -8)
    itemHeader:SetHeight(20)
    itemHeader.text = itemHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    itemHeader.text:SetPoint("LEFT", itemHeader, "LEFT", 0, 0)
    itemHeader.text:SetJustifyH("LEFT")
    itemHeader.text:SetWidth(360)
    itemHeader:SetScript("OnEnter", function()
        local result = addon.ui and addon.ui.selectedResult
        if not result or not result.itemLink or result.itemLink == "" then
            return
        end

        GameTooltip:SetOwner(itemHeader, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("TOPLEFT", itemHeader, "BOTTOMLEFT", 0, -4)
        GameTooltip:SetHyperlink(result.itemLink)
        GameTooltip:Show()
    end)
    itemHeader:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    itemHeader:SetScript("OnClick", function()
        local result = addon.ui and addon.ui.selectedResult
        if not result or not result.itemLink or result.itemLink == "" then
            return
        end

        if IsShiftKeyDown() and ChatEdit_GetActiveWindow() then
            ChatEdit_InsertLink(result.itemLink)
            return
        end

        -- ctrl+click previews in the dressing room; plain click does nothing.
        if IsModifiedClick("DRESSUP") and DressUpItemLink then
            DressUpItemLink(result.itemLink)
        end
    end)

    local scroll = CreateFrame("ScrollFrame", "WeirdLootResultDetailScroll", detailFrame, "UIPanelScrollFrameTemplate")
    elevateInteractiveFrame(scroll, detailFrame, 6)
    scroll:SetPoint("TOPLEFT", itemHeader, "BOTTOMLEFT", 0, -8)
    scroll:SetPoint("BOTTOMRIGHT", -30, 8)

    local editBox = CreateFrame("EditBox", "WeirdLootResultDetailText", scroll)
    elevateInteractiveFrame(editBox, detailFrame, 7)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(380)
    editBox:SetHeight(1120)
    editBox:SetAutoFocus(false)
    editBox:EnableMouse(true)
    editBox:SetScript("OnEscapePressed", function() editBox:ClearFocus() end)
    scroll:SetScrollChild(editBox)

    local targetButton = CreateFrame("Button", "WeirdLootResultTargetButton", detailFrame, "UIPanelButtonTemplate")
    elevateInteractiveFrame(targetButton, detailFrame, 8)
    targetButton:SetWidth(110)
    targetButton:SetHeight(22)
    targetButton:SetPoint("BOTTOMLEFT", detailFrame, "BOTTOMLEFT", 8, 8)
    targetButton:SetText("Target + Whisper")
    targetButton:SetScript("OnClick", function()
        local result = addon.ui and addon.ui.selectedResult
        local whisperName = result and result.winner or nil
        local itemName = result and (result.itemLink or result.itemName or "your item") or "your item"
        if not whisperName or whisperName == "" or whisperName == "No winner" then
            return
        end

        if type(TargetByName) == "function" then
            TargetByName(whisperName, true)
        end
        if type(SendChatMessage) == "function" then
            SendChatMessage("You won " .. itemName .. ". Please run to the loot master for trade.", "WHISPER", nil, whisperName)
        end
    end)

    local tradeButton = createButton(detailFrame, "Trade Winner", 110, 22)
    tradeButton:SetPoint("LEFT", targetButton, "RIGHT", 8, 0)
    tradeButton:SetScript("OnClick", function()
        addon:TradeSelectedWinner()
    end)

    local loadItemButton = createButton(detailFrame, "Fill Trade", 100, 22)
    loadItemButton:SetPoint("LEFT", tradeButton, "RIGHT", 8, 0)
    loadItemButton:SetScript("OnClick", function()
        addon:FillSelectedTrade()
    end)

    local tradeHelp = createLabel(detailFrame, "", "BOTTOMLEFT", targetButton, "TOPLEFT", 0, 10)
    tradeHelp:SetWidth(420)
    tradeHelp:SetTextColor(0.85, 0.85, 0.85)

    self.ui.resultsList = list
    self.ui.resultItemHeader = itemHeader
    self.ui.resultDetail = editBox
    self.ui.resultTargetButton = targetButton
    self.ui.resultTradeButton = tradeButton
    self.ui.resultLoadItemButton = loadItemButton
    self.ui.resultTradeHelp = tradeHelp
end

function addon:BuildMasterTab()
    local panel = CreateFrame("Frame", nil, self.ui.content)
    elevateInteractiveFrame(panel, self.ui.content, 2)
    panel:SetAllPoints(self.ui.content)
    self.ui.panels.master = panel

    panel.warning = createLabel(panel, "", "TOPLEFT", panel, "TOPLEFT", 8, -8)
    panel.warning:SetTextColor(1, 0.2, 0.2)

    local startButton = createButton(panel, "Start Session", 120, 24)
    startButton:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -36)
    startButton:SetScript("OnClick", function()
        addon:StartLootSession()
    end)

    local scanButton = createButton(panel, "Scan Bags", 120, 24)
    scanButton:SetPoint("LEFT", startButton, "RIGHT", 8, 0)
    scanButton:SetScript("OnClick", function()
        addon:RefreshSessionItems(true)
    end)

    local broadcastButton = createButton(panel, "Broadcast", 120, 24)
    broadcastButton:SetPoint("LEFT", scanButton, "RIGHT", 8, 0)
    broadcastButton:SetScript("OnClick", function()
        addon:BroadcastSession()
    end)

    local processButton = createButton(panel, "Roll Out the Loot", 120, 24)
    processButton:SetPoint("LEFT", broadcastButton, "RIGHT", 8, 0)
    processButton:SetScript("OnClick", function()
        addon:ProcessLoot()
    end)

    local unlockButton = createButton(panel, "Unlock Roll", 100, 24)
    unlockButton:SetPoint("LEFT", processButton, "RIGHT", 8, 0)
    unlockButton:SetScript("OnClick", function()
        addon:UnlockAllSessionRolls()
    end)

    local exportWinnersButton = createButton(panel, "Export Winners", 110, 24)
    exportWinnersButton:SetPoint("TOPLEFT", startButton, "BOTTOMLEFT", 0, -8)
    exportWinnersButton:SetScript("OnClick", function()
        addon:ExportWinners()
    end)

    local exportLogButton = createButton(panel, "Export Log", 100, 24)
    exportLogButton:SetPoint("LEFT", exportWinnersButton, "RIGHT", 8, 0)
    exportLogButton:SetScript("OnClick", function()
        addon:ExportLog()
    end)

    local importRosterButton = createButton(panel, "Import Roster", 110, 24)
    importRosterButton:SetPoint("LEFT", exportLogButton, "RIGHT", 8, 0)
    importRosterButton:SetScript("OnClick", function()
        addon:ImportRoster()
    end)

    local broadcastRosterButton = createButton(panel, "Broadcast Roster", 130, 24)
    broadcastRosterButton:SetPoint("LEFT", importRosterButton, "RIGHT", 8, 0)
    broadcastRosterButton:SetScript("OnClick", function()
        addon:BroadcastRoster()
    end)

    local importNamedItemsButton = createButton(panel, "Import Named Items", 130, 24)
    importNamedItemsButton:SetPoint("LEFT", broadcastRosterButton, "RIGHT", 8, 0)
    importNamedItemsButton:SetScript("OnClick", function()
        addon:ImportNamedItems()
    end)

    local broadcastNamedItemsButton = createButton(panel, "Broadcast Named Items", 150, 24)
    broadcastNamedItemsButton:SetPoint("LEFT", importNamedItemsButton, "RIGHT", 8, 0)
    broadcastNamedItemsButton:SetScript("OnClick", function()
        addon:BroadcastNamedItems()
    end)

    local payoutButton = createButton(panel, "Start Payout", 120, 24)
    payoutButton:SetPoint("LEFT", unlockButton, "RIGHT", 8, 0)
    payoutButton:SetScript("OnClick", function()
        addon:TogglePayout()
    end)

    panel.startButton = startButton
    panel.scanButton = scanButton
    panel.broadcastButton = broadcastButton
    panel.processButton = processButton
    panel.unlockButton = unlockButton
    panel.exportWinnersButton = exportWinnersButton
    panel.exportLogButton = exportLogButton
    panel.importRosterButton = importRosterButton
    panel.broadcastRosterButton = broadcastRosterButton
    panel.importNamedItemsButton = importNamedItemsButton
    panel.broadcastNamedItemsButton = broadcastNamedItemsButton
    panel.payoutButton = payoutButton

    setButtonTooltip(payoutButton, "Payout Mode (toggle)",
        "Turn automatic loot delivery on or off. While ON: each winner is whispered to open a trade with you, "
        .. "and their owed items auto-fill into the trade window (you click Trade to send). Trades from non-winners "
        .. "are declined while loot is still owed. Pause keeps the owed list but stops auto-fill.")

    panel.controlsTitle = createLabel(panel, "Controls", "TOPLEFT", exportWinnersButton, "BOTTOMLEFT", 0, -24)
    panel.controlsTitle:SetFontObject(GameFontHighlightLarge)

    panel.summary = createLabel(panel, "", "TOPLEFT", panel.controlsTitle, "BOTTOMLEFT", 0, -8)
    panel.summary:SetWidth(900)
    panel.summary:SetJustifyV("TOP")

    panel.snapshotTitle = createLabel(panel, "Session Snapshot", "TOPLEFT", panel.summary, "BOTTOMLEFT", 0, -20)
    panel.snapshotTitle:SetFontObject(GameFontHighlightLarge)

    panel.snapshot = createLabel(panel, "", "TOPLEFT", panel.snapshotTitle, "BOTTOMLEFT", 0, -8)
    panel.snapshot:SetWidth(900)
    panel.snapshot:SetJustifyV("TOP")

    self.ui.masterPanel = panel
end

local function getOptions(self)
    self.db.options = self.db.options or {}
    return self.db.options
end

local function createOptionsCheckbox(parent, label)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    elevateInteractiveFrame(cb, parent, 8)
    cb:SetWidth(24)
    cb:SetHeight(24)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    fs:SetText(label)
    cb.label = fs
    return cb
end

local function createNumberEditBox(parent, width)
    local w = width or 50
    local h = 20

    local bg = CreateFrame("Frame", nil, parent)
    elevateInteractiveFrame(bg, parent, 8)
    bg:SetWidth(w)
    bg:SetHeight(h)
    bg:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    bg:SetBackdropColor(0, 0, 0, 0.7)
    bg:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    local box = CreateFrame("EditBox", nil, bg)
    elevateInteractiveFrame(box, bg, 1)
    box:SetPoint("TOPLEFT", bg, "TOPLEFT", 4, -2)
    box:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -4, 2)
    box:SetFontObject(GameFontHighlight)
    box:SetJustifyH("CENTER")
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(4)
    box:SetScript("OnEscapePressed", function(selfBox) selfBox:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(selfBox) selfBox:ClearFocus() end)

    -- Expose box methods on the container so existing call sites that anchor
    -- to / read from the "edit box" keep working through the wrapper.
    bg.editBox = box
    bg.SetText = function(_, text) box:SetText(text) end
    bg.GetText = function() return box:GetText() end
    bg.SetTextColor = function(_, r, g, b, a) box:SetTextColor(r, g, b, a or 1) end
    bg.SetScript = function(_, scriptType, fn) box:SetScript(scriptType, fn) end
    bg.SetNumeric = function(_, v) box:SetNumeric(v) end
    bg.SetFocus = function() box:SetFocus() end
    bg.ClearFocus = function() box:ClearFocus() end

    return bg
end

local multilineScrollSeq = 0
local function createMultilineEditScroll(parent, width, height)
    multilineScrollSeq = multilineScrollSeq + 1
    local baseName = "WeirdLootOptionsScroll" .. multilineScrollSeq

    local container = CreateFrame("Frame", baseName .. "Container", parent)
    elevateInteractiveFrame(container, parent, 6)
    container:SetWidth(width)
    container:SetHeight(height)
    container:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    container:SetBackdropColor(0, 0, 0, 0.6)

    local scroll = CreateFrame("ScrollFrame", baseName, container, "UIPanelScrollFrameTemplate")
    elevateInteractiveFrame(scroll, container, 1)
    scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -26, 6)

    local editBox = CreateFrame("EditBox", baseName .. "Edit", scroll)
    elevateInteractiveFrame(editBox, container, 2)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(width - 36)
    editBox:SetHeight(height - 12)
    editBox:SetAutoFocus(false)
    editBox:EnableMouse(true)
    editBox:SetScript("OnEscapePressed", function(selfBox) selfBox:ClearFocus() end)
    scroll:SetScrollChild(editBox)

    container.editBox = editBox
    container.scroll = scroll
    return container
end

function addon:BuildOptionsTab()
    local scroll = CreateFrame("ScrollFrame", "WeirdLootOptionsScrollFrame", self.ui.content, "UIPanelScrollFrameTemplate")
    elevateInteractiveFrame(scroll, self.ui.content, 2)
    scroll:SetPoint("TOPLEFT", self.ui.content, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", self.ui.content, "BOTTOMRIGHT", -24, 0)
    self.ui.panels.options = scroll

    local panel = CreateFrame("Frame", nil, scroll)
    elevateInteractiveFrame(panel, scroll, 1)
    panel:SetWidth(920)
    panel:SetHeight(900)
    scroll:SetScrollChild(panel)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(selfFrame, delta)
        local current = selfFrame:GetVerticalScroll() or 0
        local max = selfFrame:GetVerticalScrollRange() or 0
        local step = 30
        local new = current - delta * step
        if new < 0 then new = 0 elseif new > max then new = max end
        selfFrame:SetVerticalScroll(new)
    end)
    self.ui.optionsPanel = panel

    local opt = getOptions(self)

    panel.title = createLabel(panel, "Options", "TOPLEFT", panel, "TOPLEFT", 12, -12)
    panel.title:SetFontObject(GameFontHighlightLarge)

    -- Result popup auto-close
    local autoCloseCB = createOptionsCheckbox(panel, "Auto-close winner popup after")
    autoCloseCB:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -16)
    autoCloseCB:SetChecked(opt.resultPopupAutoCloseEnabled and true or false)

    local autoCloseSeconds = createNumberEditBox(panel, 40)
    autoCloseSeconds:SetPoint("LEFT", autoCloseCB.label or autoCloseCB, "RIGHT", 8, 0)
    autoCloseSeconds:SetText(tostring(opt.resultPopupAutoCloseSeconds or 15))
    autoCloseSeconds:SetScript("OnEditFocusLost", function(selfBox)
        local v = tonumber(selfBox:GetText())
        if v and v > 0 then
            getOptions(addon).resultPopupAutoCloseSeconds = v
        else
            selfBox:SetText(tostring(getOptions(addon).resultPopupAutoCloseSeconds or 15))
        end
    end)
    local autoCloseLabel = createLabel(panel, "seconds", "LEFT", autoCloseSeconds, "RIGHT", 6, 0)

    local function applyAutoCloseColor()
        if autoCloseCB:GetChecked() then
            autoCloseSeconds:SetTextColor(1, 1, 1)
        else
            autoCloseSeconds:SetTextColor(0.5, 0.5, 0.5)
        end
    end
    autoCloseCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).resultPopupAutoCloseEnabled = selfCB:GetChecked() and true or false
        applyAutoCloseColor()
    end)
    applyAutoCloseColor()

    -- Roll duration (loot master)
    local rollDurLabel = createLabel(panel, "Roll duration (seconds, loot master only):",
        "TOPLEFT", autoCloseCB, "BOTTOMLEFT", 0, -20)
    local rollDurBox = createNumberEditBox(panel, 50)
    rollDurBox:SetPoint("LEFT", rollDurLabel, "RIGHT", 12, 0)
    rollDurBox:SetText(tostring(opt.rollDuration or 20))
    rollDurBox:SetScript("OnEditFocusLost", function(selfBox)
        local v = tonumber(selfBox:GetText())
        if v and v > 0 then
            getOptions(addon).rollDuration = v
        else
            selfBox:SetText(tostring(getOptions(addon).rollDuration or 20))
        end
    end)

    -- Whitelist
    local whitelistCB = createOptionsCheckbox(panel, "Enable White List (Warning: You will ONLY see loot popups for items on this list)")
    whitelistCB:SetPoint("TOPLEFT", rollDurLabel, "BOTTOMLEFT", 0, -24)
    whitelistCB:SetChecked(opt.whitelistEnabled and true or false)
    whitelistCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).whitelistEnabled = selfCB:GetChecked() and true or false
    end)

    local wlPresetLabel = createLabel(panel, "Preset:", "TOPLEFT", whitelistCB, "BOTTOMLEFT", 4, -10)
    local wlPresetDropdown = CreateFrame("Frame", "WeirdLootWhitelistPresetDropdown", panel, "UIDropDownMenuTemplate")
    elevateInteractiveFrame(wlPresetDropdown, panel, 10)
    wlPresetDropdown:SetPoint("LEFT", wlPresetLabel, "RIGHT", -4, -2)
    UIDropDownMenu_SetWidth(wlPresetDropdown, 160)
    UIDropDownMenu_JustifyText(wlPresetDropdown, "LEFT")
    if UIDropDownMenu_EnableDropDown then
        UIDropDownMenu_EnableDropDown(wlPresetDropdown)
    end
    local wlDdButton = _G["WeirdLootWhitelistPresetDropdownButton"]
    if wlDdButton then
        wlDdButton:SetFrameLevel((wlPresetDropdown:GetFrameLevel() or 0) + 2)
        wlDdButton:Enable()
    end

    local wlSaveBtn = createButton(panel, "Save as...", 80, 22)
    wlSaveBtn:SetPoint("LEFT", wlPresetDropdown, "RIGHT", 4, 2)
    wlSaveBtn:SetScript("OnClick", function()
        StaticPopup_Show("WEIRDLOOT_SAVE_WHITELIST_PRESET")
    end)

    local wlDeleteBtn = createButton(panel, "Delete", 60, 22)
    wlDeleteBtn:SetPoint("LEFT", wlSaveBtn, "RIGHT", 4, 0)
    wlDeleteBtn:Disable()

    local whitelistBox = createMultilineEditScroll(panel, 420, 110)
    whitelistBox:SetPoint("TOPLEFT", wlPresetDropdown, "BOTTOMLEFT", 16, -2)
    whitelistBox.editBox:SetText(opt.whitelistText or "")
    whitelistBox.editBox:SetScript("OnEditFocusLost", function(selfBox)
        getOptions(addon).whitelistText = selfBox:GetText() or ""
    end)

    local function applyWhitelistPreset(preset)
        if not preset then
            UIDropDownMenu_SetText(wlPresetDropdown, "<none>")
            wlDeleteBtn:Disable()
            return
        end
        whitelistBox.editBox:SetText(preset.text or "")
        getOptions(addon).whitelistText = preset.text or ""
        UIDropDownMenu_SetText(wlPresetDropdown, preset.name)
        if preset.builtin then
            wlDeleteBtn:Disable()
        else
            wlDeleteBtn:Enable()
        end
        wlDeleteBtn.currentPresetName = preset.name
        wlDeleteBtn.currentPresetBuiltin = preset.builtin
    end

    local function wlInitDropdown()
        local noneInfo = UIDropDownMenu_CreateInfo()
        noneInfo.text = "<none>"
        noneInfo.value = ""
        noneInfo.func = function() applyWhitelistPreset({ name = "<none>", text = "", builtin = true, isNone = true }) end
        UIDropDownMenu_AddButton(noneInfo)
        for _, preset in ipairs(addon:GetWhitelistPresets()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = preset.builtin and preset.name or (preset.name .. " (custom)")
            info.value = preset.name
            info.func = function() applyWhitelistPreset(preset) end
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(wlPresetDropdown, wlInitDropdown)
    UIDropDownMenu_SetText(wlPresetDropdown, "<none>")

    wlDeleteBtn:SetScript("OnClick", function()
        local name = wlDeleteBtn.currentPresetName
        if not name or wlDeleteBtn.currentPresetBuiltin then return end
        local dialog = StaticPopup_Show("WEIRDLOOT_DELETE_WHITELIST_PRESET", name)
        if dialog then dialog.data = name end
    end)

    function addon:RefreshWhitelistPresetDropdown(selectName)
        UIDropDownMenu_Initialize(wlPresetDropdown, wlInitDropdown)
        if selectName then
            for _, preset in ipairs(self:GetWhitelistPresets()) do
                if preset.name == selectName then
                    applyWhitelistPreset(preset)
                    return
                end
            end
        end
        applyWhitelistPreset(nil)
    end

    -- Blacklist
    local blacklistCB = createOptionsCheckbox(panel, "Enable Black List (Warning: you will ONLY see loot popups for items NOT on this list)")
    blacklistCB:SetPoint("TOP", whitelistBox, "BOTTOM", 0, -16)
    blacklistCB:SetPoint("LEFT", panel, "LEFT", 12, 0)
    blacklistCB:SetChecked(opt.blacklistEnabled and true or false)
    blacklistCB:SetScript("OnClick", function(selfCB)
        getOptions(addon).blacklistEnabled = selfCB:GetChecked() and true or false
    end)

    local presetLabel = createLabel(panel, "Preset:", "TOPLEFT", blacklistCB, "BOTTOMLEFT", 4, -10)
    local presetDropdown = CreateFrame("Frame", "WeirdLootBlacklistPresetDropdown", panel, "UIDropDownMenuTemplate")
    elevateInteractiveFrame(presetDropdown, panel, 10)
    presetDropdown:SetPoint("LEFT", presetLabel, "RIGHT", -4, -2)
    UIDropDownMenu_SetWidth(presetDropdown, 160)
    UIDropDownMenu_JustifyText(presetDropdown, "LEFT")
    if UIDropDownMenu_EnableDropDown then
        UIDropDownMenu_EnableDropDown(presetDropdown)
    end
    local ddButton = _G["WeirdLootBlacklistPresetDropdownButton"]
    if ddButton then
        ddButton:SetFrameLevel((presetDropdown:GetFrameLevel() or 0) + 2)
        ddButton:Enable()
    end

    local saveBtn = createButton(panel, "Save as...", 80, 22)
    saveBtn:SetPoint("LEFT", presetDropdown, "RIGHT", 4, 2)
    saveBtn:SetScript("OnClick", function()
        StaticPopup_Show("WEIRDLOOT_SAVE_BLACKLIST_PRESET")
    end)

    local deleteBtn = createButton(panel, "Delete", 60, 22)
    deleteBtn:SetPoint("LEFT", saveBtn, "RIGHT", 4, 0)
    deleteBtn:Disable()

    local blacklistBox = createMultilineEditScroll(panel, 420, 110)
    blacklistBox:SetPoint("TOPLEFT", presetDropdown, "BOTTOMLEFT", 16, -2)
    blacklistBox.editBox:SetText(opt.blacklistText or "")
    blacklistBox.editBox:SetScript("OnEditFocusLost", function(selfBox)
        getOptions(addon).blacklistText = selfBox:GetText() or ""
    end)

    local function applyPreset(preset)
        if not preset then
            UIDropDownMenu_SetText(presetDropdown, "<none>")
            deleteBtn:Disable()
            return
        end
        blacklistBox.editBox:SetText(preset.text or "")
        getOptions(addon).blacklistText = preset.text or ""
        UIDropDownMenu_SetText(presetDropdown, preset.name)
        if preset.builtin then
            deleteBtn:Disable()
        else
            deleteBtn:Enable()
        end
        deleteBtn.currentPresetName = preset.name
        deleteBtn.currentPresetBuiltin = preset.builtin
    end

    local function initDropdown()
        local noneInfo = UIDropDownMenu_CreateInfo()
        noneInfo.text = "<none>"
        noneInfo.value = ""
        noneInfo.func = function() applyPreset({ name = "<none>", text = "", builtin = true, isNone = true }) end
        UIDropDownMenu_AddButton(noneInfo)
        for _, preset in ipairs(addon:GetBlacklistPresets()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = preset.builtin and preset.name or (preset.name .. " (custom)")
            info.value = preset.name
            info.func = function() applyPreset(preset) end
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(presetDropdown, initDropdown)
    UIDropDownMenu_SetText(presetDropdown, "<none>")

    deleteBtn:SetScript("OnClick", function()
        local name = deleteBtn.currentPresetName
        if not name or deleteBtn.currentPresetBuiltin then return end
        local dialog = StaticPopup_Show("WEIRDLOOT_DELETE_BLACKLIST_PRESET", name)
        if dialog then dialog.data = name end
    end)

    function addon:RefreshBlacklistPresetDropdown(selectName)
        UIDropDownMenu_Initialize(presetDropdown, initDropdown)
        if selectName then
            for _, preset in ipairs(self:GetBlacklistPresets()) do
                if preset.name == selectName then
                    applyPreset(preset)
                    return
                end
            end
        end
        applyPreset(nil)
    end

    -- Minimap button visibility
    local minimapCB = createOptionsCheckbox(panel, "Show minimap button")
    minimapCB:SetPoint("TOP", blacklistBox, "BOTTOM", 0, -18)
    minimapCB:SetPoint("LEFT", panel, "LEFT", 12, 0)
    minimapCB:SetChecked(not (opt.minimapButtonHidden and true or false))
    minimapCB:SetScript("OnClick", function(selfCB)
        local checked = selfCB:GetChecked() and true or false
        getOptions(addon).minimapButtonHidden = not checked
        addon:SetMinimapButtonShown(checked)
    end)

    panel.autoCloseCB = autoCloseCB
    panel.autoCloseSeconds = autoCloseSeconds
    panel.rollDurBox = rollDurBox
    panel.whitelistCB = whitelistCB
    panel.whitelistBox = whitelistBox
    panel.whitelistPresetDropdown = wlPresetDropdown
    panel.whitelistSaveBtn = wlSaveBtn
    panel.whitelistDeleteBtn = wlDeleteBtn
    panel.blacklistCB = blacklistCB
    panel.blacklistBox = blacklistBox
    panel.blacklistPresetDropdown = presetDropdown
    panel.blacklistSaveBtn = saveBtn
    panel.blacklistDeleteBtn = deleteBtn
    panel.minimapCB = minimapCB
end

local function positionMinimapButton(button)
    local opt = getOptions(addon)
    local angle = tonumber(opt.minimapButtonAngle) or 200
    local rad = math.rad(angle)
    local radius = 80
    local x = math.cos(rad) * radius
    local y = math.sin(rad) * radius
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function addon:BuildMinimapButton()
    if self.ui.minimapButton then return end
    if not Minimap then return end

    local button = CreateFrame("Button", "WeirdLootMinimapButton", Minimap)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
    button:SetWidth(31)
    button:SetHeight(31)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53)
    overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetTexture("Interface\\AddOns\\WeirdLoot\\Textures\\weirdloot")
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -6)
    icon:SetTexCoord(0, 1, 0, 1)

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints(button)

    button:SetScript("OnClick", function()
        addon:ToggleMainFrame()
    end)

    button:SetScript("OnEnter", function(selfBtn)
        GameTooltip:SetOwner(selfBtn, "ANCHOR_LEFT")
        GameTooltip:AddLine("WeirdLoot", 1, 0.82, 0)
        GameTooltip:AddLine("Click to toggle the main window.", 1, 1, 1)
        GameTooltip:AddLine("Drag to reposition.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    button:SetScript("OnDragStart", function(selfBtn)
        selfBtn.isDragging = true
        selfBtn:SetScript("OnUpdate", function(s)
            local mx, my = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = Minimap:GetCenter()
            mx, my = mx / scale, my / scale
            local angle = math.deg(math.atan2(my - cy, mx - cx))
            getOptions(addon).minimapButtonAngle = angle
            positionMinimapButton(s)
        end)
    end)
    button:SetScript("OnDragStop", function(selfBtn)
        selfBtn.isDragging = false
        selfBtn:SetScript("OnUpdate", nil)
    end)

    self.ui.minimapButton = button
    positionMinimapButton(button)

    local opt = getOptions(self)
    if opt.minimapButtonHidden then
        button:Hide()
    else
        button:Show()
    end
end

function addon:SetMinimapButtonShown(shown)
    if not self.ui or not self.ui.minimapButton then return end
    if shown then
        self.ui.minimapButton:Show()
    else
        self.ui.minimapButton:Hide()
    end
end

function addon:RefreshUI()
    if not self.ui or not self.ui.frame then
        return
    end

    local session = self:GetCurrentSession()
    local lootMasterName = self:GetLootMasterName() or "Unknown"
    local authority = self:IsAuthorizedLootMaster() and "Yes" or "No"
    local sessionState = session.active and ("Active session " .. (session.id or "")) or "No active session"
    self.ui.status:SetText(string.format("Loot master: %s | Authorized: %s | %s", lootMasterName, authority, sessionState))

    self:RefreshLootTab()
    self:RefreshRaidersTab()
    self:RefreshResultsTab()
    self:RefreshMasterTab()
end

function addon:RefreshLootTab()
    local items = self:GetSortedLootItems()
    local playerName = util:GetPlayerName("player")
    if self.ui.panels and self.ui.panels.loot and self.ui.panels.loot.syncButton then
        local label = self:IsAuthorizedLootMaster() and "Rebroadcast" or "Request Sync"
        self.ui.panels.loot.syncButton:SetText(label)
    end
    if self.ui.panels and self.ui.panels.loot and self.ui.panels.loot.usabilityButton then
        local usabilityLabel = self.db.ui.lootUsabilitySort and "Usable: On" or "Usable: Off"
        self.ui.panels.loot.usabilityButton:SetText(usabilityLabel)
    end
    self.ui.lootList.update(#items, function(row, index)
        local item = items[index]
        row.item = item
        if not item then
            row:Hide()
            return
        end

        row:Show()
        row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local itemText = item.link and item.link ~= "" and item.link or item.name or ""
        if (item.quantity or 1) > 1 then
            itemText = string.format("%s x%d", itemText, item.quantity)
        end
        row.name:SetText(itemText)

        local responseChoice = self:GetPlayerResponse(item.id, playerName)
        updateLootChoiceButtons(row, responseChoice)
        local locked = self:IsItemLocked(item.id)
        local allowedForPlayer = isPlayerAllowedForLootItem(item, playerName)
        row.icon:SetDesaturated(locked)        -- grey out the item icon once it's been rolled out
        applyLootChoiceAvailability(row, locked, allowedForPlayer)
        updateLootMasterControlButtons(row, self:IsAuthorizedLootMaster(), self:GetActiveLiveRollForItem(item), locked)
        local typeText, slotText = getLootItemColumns(item.link)
        row.itemType:SetText(typeText)
        row.itemSlot:SetText(slotText)
        row.info:SetText(getLootItemInfoText(item))

        local rollCount = #(self:BuildRollerList(item.id) or {})
        row.state:SetText(string.format("%d rolling", rollCount))
    end)
end

function addon:RefreshRaidersTab()
    local rosterEntries = self:GetSortedRosterEntries()
    local configuredCount = #self:GetRosterEntries()
    local attendeeCount = #self:GetAttendees()
    local matchedCount = 0
    local unconfiguredCount = 0

    for _, entry in ipairs(rosterEntries) do
        if entry.present and entry.source == "configured" then
            matchedCount = matchedCount + 1
        elseif entry.present and entry.source == "unconfigured" then
            unconfiguredCount = unconfiguredCount + 1
        end
    end

    if self.ui.raidersSummary then
        self.ui.raidersSummary:SetText(string.format(
            "Master roster: %d | In current raid: %d | Matched: %d | Unconfigured in raid: %d",
            configuredCount,
            attendeeCount,
            matchedCount,
            unconfiguredCount
        ))
    end

    self.ui.raidersList.update(#rosterEntries, function(row, index)
        local entry = rosterEntries[index]
        if not entry then
            row:Hide()
            return
        end
        row:Show()
        row.present:SetText(entry.present and "Yes" or "No")
        row.present:SetTextColor(entry.present and 0.3 or 0.7, entry.present and 0.9 or 0.3, 0.3)
        row.name:SetText((util:GetClassColorCode(entry.className) or "|cffffffff") .. util:TitleCaseWords(entry.name or "") .. "|r")
        row.classSpec:SetText((util:GetClassColorCode(entry.className) or "|cffffffff") .. util:TitleCaseWords(string.trim((entry.className or "") .. " " .. (entry.specName or ""))) .. "|r")
        row.status:SetText(util:PlayerDisplayStatus(entry.status))
        row.source:SetText(entry.source == "configured" and "Roster" or "Live")
        row.source:SetTextColor(entry.source == "configured" and 0.85 or 1, entry.source == "configured" and 0.85 or 0.45, entry.source == "configured" and 0.85 or 0.45)
    end)
end

function addon:RefreshResultsTab()
    local results = self.session.results or {}
    self.ui.resultsList.update(#results, function(row, index)
        local result = results[index]
        row.result = result
        if not result then
            row:Hide()
            return
        end
        row:Show()
        row.icon:SetTexture(result.itemIcon or result.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local itemText = (result.itemLink and result.itemLink ~= "" and result.itemLink) or result.itemName or ""
        if (result.quantity or 1) > 1 then
            itemText = string.format("%s x%d", itemText, result.quantity)
        end
        row.name:SetText(itemText)
        if result.winners and #result.winners > 0 and result.winnerDetails and #result.winnerDetails > 0 then
            local winnerParts = {}
            for winnerIndex, winnerName in ipairs(result.winners) do
                local detail = result.winnerDetails[winnerIndex] or {}
                local colorCode = util:GetClassColorCode(detail.className)
                winnerParts[#winnerParts + 1] = (colorCode or "|cffffffff") .. winnerName .. "|r"
            end
            row.winner:SetText(table.concat(winnerParts, ", "))
        else
            row.winner:SetText(result.winnersText or result.winner or "No winner")
        end
    end)

    local selected = self.ui.selectedResult
    if selected and selected.itemId and not self:GetResultByItemId(selected.itemId) then
        selected = nil
        self.ui.selectedResult = nil
    end
    if not selected and results[1] then
        selected = results[1]
        self.ui.selectedResult = selected
    end

    if self.ui.resultItemHeader and self.ui.resultItemHeader.text then
        local itemHeaderText = selected and (((selected.itemLink and selected.itemLink ~= "" and selected.itemLink) or selected.itemName or "")) or "No results yet."
        if selected and (selected.quantity or 1) > 1 then
            itemHeaderText = string.format("%s x%d", itemHeaderText, selected.quantity)
        end
        self.ui.resultItemHeader.text:SetText(itemHeaderText)
    end

    self.ui.resultDetail:SetText(selected and selected.detailText or "No results yet.")

    local canAct = self:IsAuthorizedLootMaster() and selected and selected.winner and selected.winner ~= "" and selected.winner ~= "No winner"
    if self.ui.resultTargetButton then
        if canAct then
            self.ui.resultTargetButton:Enable()
            self.ui.resultTradeButton:Enable()
            self.ui.resultLoadItemButton:Enable()
            self.ui.resultTargetButton:Show()
            self.ui.resultTradeButton:Show()
            self.ui.resultLoadItemButton:Show()
            self.ui.resultTradeHelp:Show()
            self.ui.resultTradeHelp:SetText("Trade flow: Target + Whisper, then Trade Winner to open the trade, then Fill Trade to auto-load their loot. Click Trade to send.")
        else
            self.ui.resultTargetButton:Disable()
            self.ui.resultTradeButton:Disable()
            self.ui.resultLoadItemButton:Disable()
            if self:IsAuthorizedLootMaster() then
                self.ui.resultTargetButton:Show()
                self.ui.resultTradeButton:Show()
                self.ui.resultLoadItemButton:Show()
                self.ui.resultTradeHelp:Show()
                self.ui.resultTradeHelp:SetText("Select a result with a winner to use trade actions.")
            else
                self.ui.resultTargetButton:Hide()
                self.ui.resultTradeButton:Hide()
                self.ui.resultLoadItemButton:Hide()
                self.ui.resultTradeHelp:Hide()
            end
        end
    end

end

function addon:RefreshMasterTab()
    local panel = self.ui.masterPanel
    local authorized = self:IsAuthorizedLootMaster()
    panel.warning:SetText(authorized and "" or "Loot master controls are locked until you are the loot master or leadership fallback.")

    if authorized then
        panel.startButton:Enable()
        panel.scanButton:Enable()
        panel.broadcastButton:Enable()
        panel.processButton:Enable()
        panel.exportWinnersButton:Enable()
        panel.exportLogButton:Enable()
        panel.importRosterButton:Enable()
        panel.broadcastRosterButton:Enable()
        panel.importNamedItemsButton:Enable()
        panel.broadcastNamedItemsButton:Enable()
        panel.payoutButton:Enable()
    else
        panel.startButton:Disable()
        panel.scanButton:Disable()
        panel.broadcastButton:Disable()
        panel.processButton:Disable()
        panel.exportWinnersButton:Disable()
        panel.exportLogButton:Disable()
        panel.importRosterButton:Disable()
        panel.broadcastRosterButton:Disable()
        panel.importNamedItemsButton:Disable()
        panel.broadcastNamedItemsButton:Disable()
        panel.payoutButton:Disable()
    end

    if panel.unlockButton then
        if authorized then
            panel.unlockButton:Show()
            if self:HasLockedItems() then
                panel.unlockButton:Enable()
            else
                panel.unlockButton:Disable()
            end
        else
            panel.unlockButton:Disable()
        end
    end

    local payoutActive = self.payout and self.payout:IsPayoutActive()
    panel.payoutButton:SetText(payoutActive and "Pause Payout" or "Start Payout")

    local session = self:GetCurrentSession()
    local attendeeCount = #(self:GetAttendees() or {})
    local itemCount = #(session.items or {})
    local resultCount = #(session.results or {})
    local lockedCount = 0
    for _, item in ipairs(session.items or {}) do
        if self:IsItemLocked(item.id) then
            lockedCount = lockedCount + 1
        end
    end
    panel.summary:SetText(table.concat({
        "Start Session: Establishes the active loot session.",
        "Scan Bags: Searches bags for current epic items from the loot master's bags.",
        "Broadcast: Manually syncs items and current roll status to the raid.",
        "Roll Out the Loot: Resolves winners, records results, and enables the safety lock.",
        "Unlock Roll: Clears the rollout lock so the current session's loot can be rerolled intentionally.",
        "Pause Payout: Toggles payout mode so owed winners can trade for auto-filled loot, or pauses that flow without clearing the ledger.",
        "Export Winners: Opens a simple item-to-winner export list for sharing or cleanup.",
        "Export Log: Opens the detailed loot-resolution audit log for review or record keeping.",
        "Import Roster: Opens an editable import window where you can paste the current weekly roster list and save it to WeirdLoot.",
        "Import Named Items: Opens an editable import window where you can paste the current named-item priority list and save it to WeirdLoot.",
        "Broadcast Named Items: Sends your current named-item list to the raid once so each raider's addon saves and uses the latest version.",
    }, "\n"))

    panel.snapshot:SetText(string.format(
        "Config revision: %d\nRaid attendees: %d\nSession items: %d\nLocked items: %d\nProcessed results: %d",
        self.config.revision or 0,
        attendeeCount,
        itemCount,
        lockedCount,
        resultCount
    ))
end
