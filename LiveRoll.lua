local addon = WeirdLoot
local util = addon.util

-- Live rolling system (PLAN.md "live drops/rolls"), coexisting with the batch flow.
--
-- Flow: a newly-collected item surfaces a *pending* popup to the loot master only
-- (Start Roll / Skip); nothing goes to the raid yet. When the ML presses Start Roll
-- (or right-clicks a loot row) -> DROP broadcast -> every raider gets an interest popup
-- with the priority brackets (BiS / MS / MU / OS / TM / Pass) -> RSP back to the ML ->
-- ML ends the roll -> the picks are already in session.responses, so it resolves through
-- the SAME engine as the batch flow (ResolveSessionItem: bracket -> named -> spec ->
-- status -> roll) -> WIN broadcast -> registrants get a result popup. The win goes through
-- the shared result/lock path and the winner is queued for payout.
--
-- The ML never receives its own addon messages (CHAT_MSG_ADDON ignores self), so the
-- ML drives its own popups locally and members react to DROP/WIN over comms.

function addon:InitializeLiveRoll()
    self.live = self.live or { rolls = {}, seq = 0, pool = {}, active = {} }
    self.live.rolls = self.live.rolls or {}
    self.live.seq = self.live.seq or 0
    self.live.pool = self.live.pool or {}
    self.live.active = self.live.active or {}

    if not self.live.anchor then
        local popupPos = self.db and self.db.ui and self.db.ui.liveRollPopups or nil
        local point = (popupPos and popupPos.point) or "TOP"
        local relativePoint = (popupPos and popupPos.relativePoint) or "TOP"
        local x = (popupPos and popupPos.x) or 260
        local y = (popupPos and popupPos.y) or -170
        -- Pure invisible positioning reference for the popup stack. It is intentionally NOT
        -- mouse-interactive: an always-shown EnableMouse frame would capture clicks over its
        -- rect even when no popups are visible. Dragging is driven by the popups, which call
        -- anchor:StartMoving() (that only needs SetMovable, not EnableMouse) and persist the
        -- position on their own OnDragStop.
        local anchor = CreateFrame("Frame", nil, UIParent)
        anchor:SetWidth(340)
        anchor:SetHeight(94)
        anchor:SetFrameStrata("DIALOG")
        anchor:SetMovable(true)
        anchor:SetClampedToScreen(true)
        anchor:SetPoint(point, UIParent, relativePoint, x, y)
        self.live.anchor = anchor
    end
end

-- ---------------------------------------------------------------------------
-- popup frames (custom, stacking)
-- ---------------------------------------------------------------------------
local POPUP_W, POPUP_H = 340, 94
local ROLL_DURATION = 30        -- seconds raiders have to roll before it auto-resolves (default; user may override via Options tab)

local function getOptions()
    addon.db = addon.db or {}
    addon.db.options = addon.db.options or {}
    return addon.db.options
end

local function getRollDuration()
    local v = tonumber(getOptions().rollDuration)
    if v and v > 0 then return v end
    return ROLL_DURATION
end

local function parseItemList(text)
    local set = {}
    if type(text) ~= "string" or text == "" then return set end
    for line in string.gmatch(text, "[^\r\n]+") do
        local trimmed = string.match(line, "^%s*(.-)%s*$") or ""
        if trimmed ~= "" then
            set[string.lower(trimmed)] = true
        end
    end
    return set
end

-- Returns true if the (non-loot-master) popup should be suppressed for this item name.
local function shouldSuppressPopup(self, itemName)
    if self:IsAuthorizedLootMaster() then return false end
    local opt = getOptions()
    local name = string.lower(itemName or "")
    if name == "" then return false end

    if opt.whitelistEnabled then
        local set = parseItemList(opt.whitelistText)
        if next(set) and not set[name] then
            return true
        end
    end
    if opt.blacklistEnabled then
        local set = parseItemList(opt.blacklistText)
        if set[name] then
            return true
        end
    end
    return false
end
local popupBasePoint, savePopupBasePoint, layoutPopups
local RESPONSE_ORDER = { bis = 5, ms = 4, mu = 3, os = 2, tm = 1, pass = 0 }
local RESPONSE_LABELS = { bis = "BiS", ms = "MS", mu = "MU", os = "OS", tm = "TM", pass = "Pass" }
local ROLL_LINE_LIMIT = 8
local POPUP_INTEREST_EMPTY_H = 64

local function makeButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(width)
    b:SetHeight(18)
    b:SetText(text)
    return b
end

local function getPlayerDisplayName(self, playerKey)
    local attendee = self:GetAttendee(playerKey) or self:GetRosterProfile(playerKey)
    if attendee and attendee.name and attendee.name ~= "" then
        return attendee.name
    end
    return playerKey
end

local function getPlayerClassName(self, playerKey)
    local attendee = self:GetAttendee(playerKey) or self:GetRosterProfile(playerKey)
    if attendee and attendee.className and attendee.className ~= "" then
        return attendee.className
    end
    return ""
end

local function nextLiveRollValue()
    return math.random(1, 100)
end

local function buildLiveRollEntries(self, roll)
    local entries = {}
    for playerKey, registrant in pairs(roll and roll.registrants or {}) do
        local tier = registrant.tier or "pass"
        if tier ~= "pass" then
            entries[#entries + 1] = {
                key = playerKey,
                name = registrant.name or getPlayerDisplayName(self, playerKey),
                className = registrant.className or getPlayerClassName(self, playerKey),
                tier = tier,
                roll = registrant.roll or 0,
            }
        end
    end

    table.sort(entries, function(left, right)
        local leftRank = RESPONSE_ORDER[left.tier] or 0
        local rightRank = RESPONSE_ORDER[right.tier] or 0
        if leftRank ~= rightRank then
            return leftRank > rightRank
        end
        if (left.roll or 0) ~= (right.roll or 0) then
            return (left.roll or 0) > (right.roll or 0)
        end
        return string.lower(left.name or "") < string.lower(right.name or "")
    end)

    return entries
end

function addon:GetLiveRollEntriesForItem(item)
    if not item or not item.id then return nil end
    local roll = self:GetActiveLiveRollForItem(item)
    if not roll then return nil end
    return buildLiveRollEntries(self, roll)
end

function addon:GetResponseLabel(tier)
    return RESPONSE_LABELS[tier] or string.upper(tier or "")
end

local function ensureRollLinePool(f, count)
    f.rollLines = f.rollLines or {}
    while #f.rollLines < count do
        local line = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetJustifyH("LEFT")
        line:SetWidth(POPUP_W - 20)
        if #f.rollLines == 0 then
            line:SetPoint("TOPLEFT", f.sub, "BOTTOMLEFT", 0, -6)
        else
            line:SetPoint("TOPLEFT", f.rollLines[#f.rollLines], "BOTTOMLEFT", 0, -2)
        end
        f.rollLines[#f.rollLines + 1] = line
    end
end

local function setPopupHeight(f, height)
    f:SetHeight(height)
end

local function getCompactPopupHeight(f)
    local nameHeight = math.ceil(f.name:GetStringHeight() or 0)
    local subHeight = math.ceil(f.sub:GetStringHeight() or 0)
    return math.max(POPUP_INTEREST_EMPTY_H, 39 + nameHeight + subHeight)
end

local function getCompactResultPopupHeight(f)
    local nameHeight = math.ceil(f.name:GetStringHeight() or 0)
    local subHeight = math.ceil(f.sub:GetStringHeight() or 0)
    return math.max(62, 34 + nameHeight + subHeight)
end

local function showRollCountTooltip(self, f)
    local roll = f and f.roll
    if not f or not roll then
        return
    end

    GameTooltip:SetOwner(f.countHover or f, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("TOPLEFT", f, "TOPRIGHT", 8, 0)
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Players Rolling", 1, 0.82, 0)

    local entries = buildLiveRollEntries(self, roll)
    if #entries == 0 then
        GameTooltip:AddLine("No active rollers", 1, 1, 1)
    else
        for _, entry in ipairs(entries) do
            local colorCode = util:GetClassColorCode(entry.className) or "|cffffffff"
            GameTooltip:AddLine(string.format("%s%s|r - %d - %s", colorCode, entry.name or "Unknown", entry.roll or 0, RESPONSE_LABELS[entry.tier] or string.upper(entry.tier or "")), 1, 1, 1)
        end
    end

    GameTooltip:Show()
end

local function refreshPopupRollLines(self, roll)
    local f = roll and roll.popup
    if not f or f.mode ~= "interest" then
        return
    end

    if f.rollLines then
        for _, line in ipairs(f.rollLines) do
            line:SetText("")
            line:Hide()
        end
    end

    setPopupHeight(f, getCompactPopupHeight(f))
    layoutPopups(self)
end

-- roll-choice brackets, highest priority first: BiS > MS > MU > OS > TM (Pass
-- declines). Use the button's natural pressed visual to show the pick: the chosen button
-- locks in its down state; picking a different one pops the previous back up.
local function interestButtons(f)
    return { bis = f.bisBtn, ms = f.msBtn, mu = f.muBtn, os = f.osBtn, tm = f.tmBtn, pass = f.passBtn }
end
-- chosen button: bold (outlined) green label; others: normal gold label
local function styleButtonText(btn, chosen, disabled)
    local fs = btn:GetFontString()
    if not fs then return end
    local font, size = fs:GetFont()
    if disabled then
        fs:SetFont(font, size, "")
        fs:SetTextColor(0.5, 0.5, 0.5)
    elseif chosen then
        fs:SetFont(font, size, "OUTLINE")
        fs:SetTextColor(0.2, 1.0, 0.2)
    else
        fs:SetFont(font, size, "")
        fs:SetTextColor(1.0, 0.82, 0.0)
    end
end
local function resetInterestButtons(f)
    for _, btn in pairs(interestButtons(f)) do
        if btn then
            btn:SetButtonState("NORMAL")
            styleButtonText(btn, false, false)
        end
    end
end

local function positionInterestButtons(f, isOwner)
    f.bisBtn:ClearAllPoints()
    f.bisBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 10)
end

local function isPlayerAllowedForRoll(self, roll, playerName)
    local itemName = (roll and roll.name) or ""
    return self:IsPlayerAllowedForItem(itemName, playerName)
end

local function applyInterestButtonAvailability(self, f, roll)
    local playerName = util:GetPlayerName("player")
    local allowed = isPlayerAllowedForRoll(self, roll, playerName)

    for key, btn in pairs(interestButtons(f)) do
        local disabled = false
        if key == "pass" then
            btn:Enable()
        elseif allowed then
            btn:Enable()
        else
            btn:Disable()
            disabled = true
        end
        btn:SetAlpha(disabled and 0.45 or 1)
        styleButtonText(btn, false, disabled)
    end
end

local function formatLootRuleEntry(entry)
    if not entry then
        return ""
    end
    if entry.isRest then
        return "Rest"
    end

    local colorCode = util:GetClassColorCode(entry.className) or "|cffffffff"
    local label = ""
    if entry.specName and entry.specName ~= "" then
        label = util:TitleCaseWords(entry.specName)
    elseif entry.className and entry.className ~= "" then
        label = util:TitleCaseWords(entry.className)
    else
        label = util:TitleCaseWords(entry.raw or "")
    end

    return colorCode .. label .. "|r"
end

local function formatLootRuleDisplay(rule)
    if not rule or not rule.tiers then
        return nil
    end

    local tiers = {}
    for _, tier in ipairs(rule.tiers) do
        local entries = {}
        for _, entry in ipairs(tier.entries or {}) do
            local formatted = formatLootRuleEntry(entry)
            if formatted ~= "" then
                entries[#entries + 1] = formatted
            end
        end
        if #entries > 0 then
            tiers[#tiers + 1] = table.concat(entries, " / ")
        end
    end

    if #tiers == 0 then
        return nil
    end

    return table.concat(tiers, " > ")
end

local function formatNamedRuleEntry(entry)
    if not entry then
        return ""
    end
    if entry.isLootCouncil then
        return "LC"
    end
    if entry.isRest then
        return "Rest"
    end

    local playerName = entry.raw or ""
    local profile = addon.GetRosterProfile and addon:GetRosterProfile(playerName) or nil
    local classColor = util:GetClassColorCode(profile and profile.className) or "|cffffffff"
    return classColor .. util:TitleCaseWords(playerName) .. "|r"
end

local function formatNamedRuleDisplay(rule)
    if not rule or not rule.tiers then
        return nil
    end

    local tiers = {}
    local hasLootCouncil = false
    for _, tier in ipairs(rule.tiers) do
        local entries = {}
        for _, entry in ipairs(tier.entries or {}) do
            if entry.isLootCouncil then
                hasLootCouncil = true
            end
            local formatted = formatNamedRuleEntry(entry)
            if formatted ~= "" and not entry.isLootCouncil then
                entries[#entries + 1] = formatted
            end
        end
        if #entries > 0 then
            tiers[#tiers + 1] = table.concat(entries, " / ")
        end
    end

    if hasLootCouncil then
        tiers[#tiers + 1] = "LC"
    end

    if #tiers == 0 then
        return nil
    end

    return table.concat(tiers, " > ")
end

local function highlightInterestButton(f, tier)
    for key, btn in pairs(interestButtons(f)) do
        if btn then
            local chosen = key == tier
            -- lock the chosen button pushed; leave the rest in their normal (up) state
            btn:SetButtonState(chosen and "PUSHED" or "NORMAL", chosen)
            styleButtonText(btn, chosen, not btn:IsEnabled())
        end
    end
end

local function makePopup()
    local parent = (addon.live and addon.live.anchor) or UIParent
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(POPUP_W)
    f:SetHeight(POPUP_H)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetScript("OnDragStart", function()
        if addon.live and addon.live.anchor then
            addon.live.anchor:StartMoving()
        end
    end)
    f:SetScript("OnDragStop", function()
        if addon.live and addon.live.anchor then
            addon.live.anchor:StopMovingOrSizing()
            local point, _, relativePoint, x, y = addon.live.anchor:GetPoint()
            savePopupBasePoint(addon, point, relativePoint, x, y)
        end
    end)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetWidth(32)
    f.icon:SetHeight(32)
    f.icon:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)

    -- mouse-over the icon shows the item tooltip (same as the list UI). The link is set
    -- per popup via f.itemLink; the texture itself can't take mouse, so overlay a frame.
    f.iconHover = CreateFrame("Frame", nil, f)
    f.iconHover:SetAllPoints(f.icon)
    f.iconHover:EnableMouse(true)
    f.iconHover:SetScript("OnEnter", function(hover)
        if not f.itemLink or f.itemLink == "" then return end
        GameTooltip:SetOwner(hover, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(f.itemLink)
        GameTooltip:Show()
    end)
    f.iconHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 6, -1)
    f.name:SetWidth(POPUP_W - 166)
    f.name:SetJustifyH("LEFT")

    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -2)
    f.sub:SetWidth(POPUP_W - 56)
    f.sub:SetJustifyH("LEFT")

    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.count:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -30)
    f.countHover = CreateFrame("Frame", nil, f)
    f.countHover:SetPoint("TOPLEFT", f.count, "TOPLEFT", -2, 2)
    f.countHover:SetPoint("BOTTOMRIGHT", f.count, "BOTTOMRIGHT", 2, -2)
    f.countHover:EnableMouse(true)
    f.countHover:SetScript("OnEnter", function() showRollCountTooltip(addon, f) end)
    f.countHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- choice brackets (top button row): BiS > MS > MU > OS > TM > Pass
    f.bisBtn = makeButton(f, "BiS", 34)
    f.bisBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 32)
    f.msBtn = makeButton(f, "MS", 32)
    f.msBtn:SetPoint("LEFT", f.bisBtn, "RIGHT", 3, 0)
    f.muBtn = makeButton(f, "MU", 34)
    f.muBtn:SetPoint("LEFT", f.msBtn, "RIGHT", 3, 0)
    f.osBtn = makeButton(f, "OS", 32)
    f.osBtn:SetPoint("LEFT", f.muBtn, "RIGHT", 3, 0)
    f.tmBtn = makeButton(f, "TM", 32)
    f.tmBtn:SetPoint("LEFT", f.osBtn, "RIGHT", 3, 0)
    f.passBtn = makeButton(f, "Pass", 42)
    f.passBtn:SetPoint("LEFT", f.tmBtn, "RIGHT", 3, 0)

    -- loot-master action buttons live in the header row; OK (result mode) stays bottom-right.
    f.cancelBtn = makeButton(f, "Cancel", 50)
    f.cancelBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    f.rollBtn = makeButton(f, "End", 46)
    f.rollBtn:SetPoint("RIGHT", f.cancelBtn, "LEFT", -6, 0)
    f.okBtn = makeButton(f, "OK", 60)
    f.okBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 10)

    -- countdown bar along the bottom edge; shrinks over the roll's duration
    f.timer = CreateFrame("StatusBar", nil, f)
    f.timer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 5, 4)
    f.timer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 4)
    f.timer:SetHeight(4)
    f.timer:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    f.timer:SetMinMaxValues(0, 1)
    f.timer:SetValue(1)

    f:Hide()
    return f
end

local function acquirePopup(self)
    local f = table.remove(self.live.pool)
    if not f then f = makePopup() end
    f.ownerAddon = self
    return f
end

popupBasePoint = function(self)
    if self.live and self.live.anchor then
        local point, _, relativePoint, x, y = self.live.anchor:GetPoint()
        return point or "TOP", relativePoint or point or "TOP", x or 260, y or -170
    end
    local ui = self.db and self.db.ui
    local pos = ui and ui.liveRollPopups
    return (pos and pos.point) or "TOP", (pos and pos.relativePoint) or (pos and pos.point) or "TOP", (pos and pos.x) or 260, (pos and pos.y) or -170
end

savePopupBasePoint = function(self, point, relativePoint, x, y)
    self.db.ui.liveRollPopups = self.db.ui.liveRollPopups or {}
    self.db.ui.liveRollPopups.point = point or "TOP"
    self.db.ui.liveRollPopups.relativePoint = relativePoint or point or "TOP"
    self.db.ui.liveRollPopups.x = x
    self.db.ui.liveRollPopups.y = y
end

-- Each popup keeps a fixed screen slot for its whole lifetime, so when one resolves or
-- its timer expires the others DON'T slide up to fill the gap (that shifting was
-- confusing). A closing popup frees its slot; the next new popup reuses the lowest free
-- one.
layoutPopups = function(self)
    local ordered = {}
    for _, f in ipairs(self.live.active) do
        ordered[#ordered + 1] = f
    end
    table.sort(ordered, function(a, b)
        return (a.slot or 0) < (b.slot or 0)
    end)

    local yOffset = 0
    for _, f in ipairs(ordered) do
        f:ClearAllPoints()
        f:SetPoint("TOP", self.live.anchor or UIParent, "TOP", 0, -yOffset)
        yOffset = yOffset + (f:GetHeight() or POPUP_H) + 8
    end
end

local function addActivePopup(self, f, preferredSlot)
    local used = {}
    for _, other in ipairs(self.live.active) do
        if other.slot then used[other.slot] = true end
    end
    local slot = preferredSlot
    if slot == nil or used[slot] then       -- fall back to lowest free slot
        slot = 0
        while used[slot] do slot = slot + 1 end
    end
    f.slot = slot
    self.live.active[#self.live.active + 1] = f
end

local function removeActive(self, f)
    for i = #self.live.active, 1, -1 do
        if self.live.active[i] == f then table.remove(self.live.active, i) end
    end
    f.slot = nil
end

-- Close up the gaps: reassign slots 0..n-1 in current order and re-layout. Called only
-- when a popup is dismissed (OK / Pass / Skip / Cancel) -- the one case where shifting is
-- wanted. A timer expiring (interest -> result) keeps its slot and never triggers this.
local function compactPopups(self)
    local list = {}
    for _, f in ipairs(self.live.active) do list[#list + 1] = f end
    table.sort(list, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    for i, f in ipairs(list) do f.slot = i - 1 end
    layoutPopups(self)
end

local function closePopup(self, f)
    if not f then return end
    f:SetScript("OnUpdate", nil)        -- stop the countdown on a pooled frame
    resetInterestButtons(f)             -- clear any locked roll-choice highlight
    if f.rollLines then
        for _, line in ipairs(f.rollLines) do
            line:SetText("")
            line:Hide()
        end
    end
    setPopupHeight(f, getCompactPopupHeight(f))
    f:Hide()
    removeActive(self, f)
    self.live.pool[#self.live.pool + 1] = f
    layoutPopups(self)
end

local function formatRollItemLabel(link, name, quantity)
    local itemText = link ~= "" and link or name or "Item"
    if (quantity or 1) > 1 then
        itemText = string.format("%s x%d", itemText, quantity)
    end
    return itemText
end

-- ---------------------------------------------------------------------------
-- interest popup
-- ---------------------------------------------------------------------------
function addon:ShowInterestPopup(roll, slot)
    if not roll.owner and shouldSuppressPopup(self, roll.name) then
        return
    end
    local f = acquirePopup(self)
    f.roll = roll
    roll.popup = f
    f.mode = "interest"
    if f.resultHover then
        f.resultHover:Hide()
        f.resultHover:SetScript("OnEnter", nil)
        f.resultHover:SetScript("OnLeave", nil)
    end

    local currentChoice = roll.choice
    f.icon:SetTexture(roll.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.itemLink = roll.link
    f.name:SetText(formatRollItemLabel(roll.link, roll.name, roll.quantity))
    f.sub:SetText("|cffffffffPrio:|r " .. ((roll.prio and roll.prio ~= "") and roll.prio or "BiS > MS > MU > OS > TM"))
    f.okBtn:Hide()

    f.bisBtn:Show(); f.msBtn:Show(); f.muBtn:Show(); f.osBtn:Show(); f.tmBtn:Show(); f.passBtn:Show()
    f.bisBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "bis") end)
    f.msBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "ms") end)
    f.muBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "mu") end)
    f.osBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "os") end)
    f.tmBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "tm") end)
    f.passBtn:SetScript("OnClick", function() self:ChooseInterest(roll, "pass") end)
    resetInterestButtons(f)
    positionInterestButtons(f, roll.owner)
    applyInterestButtonAvailability(self, f, roll)
    if currentChoice then
        highlightInterestButton(f, currentChoice)
    end

    if roll.owner then
        -- the ML keeps the popup to drive the roll: Cancel aborts, Roll! resolves
        f.rollBtn:Show()
        f.rollBtn:SetWidth(46)
        f.rollBtn:SetText("End")
        f.rollBtn:SetScript("OnClick", function() self:ResolveLiveRoll(roll.id) end)
        f.cancelBtn:Show()
        f.cancelBtn:SetWidth(50)
        f.cancelBtn:SetText("Cancel")
        f.cancelBtn:SetScript("OnClick", function() self:CancelLiveRoll(roll.id) end)
    else
        f.rollBtn:Hide()
        f.cancelBtn:Hide()
    end
    f.count:Show()
    f.countHover:Show()

    f:SetScript("OnEnter", nil)
    f:SetScript("OnLeave", nil)

    -- countdown: bar shrinks over the roll duration; the loot master auto-resolves at
    -- zero (clients just wait for the resulting WIN). The ML can still Roll! early.
    f.timer:Show()
    f.timer:SetValue(1)
    f.rollId = roll.id
    f.isOwner = roll.owner
    f.duration = roll.duration or ROLL_DURATION
    f.elapsed = 0
    f:SetScript("OnUpdate", function(bar, dt)
        bar.elapsed = bar.elapsed + dt
        local frac = 1 - (bar.elapsed / bar.duration)
        if frac < 0 then frac = 0 end
        bar.timer:SetValue(frac)
        bar.timer:SetStatusBarColor(1 - frac, frac, 0.1)   -- green -> red as it drains
        if bar.elapsed >= bar.duration then
            bar:SetScript("OnUpdate", nil)
            if bar.isOwner then addon:ResolveLiveRoll(bar.rollId) end
        end
    end)

    addActivePopup(self, f, slot)
    f:Show()
    layoutPopups(self)
    self:RefreshInterestPopup(roll)
end

function addon:RefreshInterestPopup(roll)
    local f = roll and roll.popup
    if not f or f.mode ~= "interest" then return end

    if roll.owner and roll.itemId then
        local total = #(self:BuildRollerList(roll.itemId) or {})
        f.count:SetText(total > 0 and (total .. " rolling") or "")
        refreshPopupRollLines(self, roll)
        return
    end

    local total = 0
    for _, r in pairs(roll.registrants) do
        if r.tier and r.tier ~= "pass" then total = total + 1 end
    end
    if roll.owner then
        f.count:SetText(total > 0 and (total .. " rolling") or "")
    end
    if not roll.owner then
        f.count:SetText(total > 0 and (total .. " rolling") or "")
    end
    refreshPopupRollLines(self, roll)
end

function addon:RefreshLiveRollCountForItem(itemId)
    if not itemId or not self.live or not self.live.rolls then
        return
    end

    for _, roll in pairs(self.live.rolls) do
        if roll and not roll.resolved and roll.itemId == itemId then
            self:RefreshInterestPopup(roll)
        end
    end
end

function addon:CloseInterestPopup(roll)
    if roll and roll.popup then
        closePopup(self, roll.popup)
        roll.popup = nil
    end
end

-- choose MS/OS/TM/Pass on a popup. The popup stays open after a choice (so everyone
-- sees the roll's progress) and the chosen button is highlighted. The sole exception
-- is Pass for a non-ML roller, which dismisses the loot immediately; the ML never
-- auto-hides (it keeps the popup to drive the roll).
function addon:ChooseInterest(roll, tier)
    local playerName = util:GetPlayerName("player")
    if tier ~= "pass" and not isPlayerAllowedForRoll(self, roll, playerName) then
        self:Print("Your class cannot use that token. You may only pass.")
        return
    end
    self:SendInterest(roll.id, tier)
    roll.choice = tier

    if tier == "pass" and not roll.owner then
        self:CloseInterestPopup(roll)
        compactPopups(self)
        return
    end

    if roll.popup then highlightInterestButton(roll.popup, tier) end
    if roll.owner then self:RefreshInterestPopup(roll) end
end

-- ---------------------------------------------------------------------------
-- pending popup (loot master only): a freshly-collected item, not yet broadcast.
-- The ML presses Start Roll to actually put it up for the raid, or Skip to dismiss.
-- ---------------------------------------------------------------------------
function addon:ShowPendingPopup(item, slot)
    if not item or not item.link or item.link == "" then return end
    local link = item.link
    local f = acquirePopup(self)
    f.mode = "pending"
    if f.resultHover then
        f.resultHover:Hide()
        f.resultHover:SetScript("OnEnter", nil)
        f.resultHover:SetScript("OnLeave", nil)
    end
    f:SetScript("OnUpdate", nil)        -- no countdown until the roll actually starts
    f.timer:Hide()
    f.pendingLink = link
    self.session.pendingLinks = self.session.pendingLinks or {}
    self.session.pendingLinks[link] = {
        link = item.link,
        name = item.name,
        icon = item.icon,
        quantity = item.quantity or 1,
    }      -- persisted: re-shown to the ML after a reload

    f.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.itemLink = link
    f.name:SetText(formatRollItemLabel(link, item.name, item.quantity))
    f.sub:SetText("|cffffffffPrio:|r " .. (self:GetLiveItemPrio(item) or "BiS > MS > MU > OS > TM"))
    f.count:Hide()
    f.countHover:Hide()
    if f.rollLines then
        for _, line in ipairs(f.rollLines) do
            line:Hide()
        end
    end
    setPopupHeight(f, getCompactPopupHeight(f))

    f.bisBtn:Hide(); f.msBtn:Hide(); f.muBtn:Hide(); f.osBtn:Hide(); f.tmBtn:Hide(); f.passBtn:Hide(); f.okBtn:Hide()

    f.cancelBtn:Show()
    f.cancelBtn:SetWidth(50)
    f.cancelBtn:SetText("Skip")
    f.cancelBtn:SetScript("OnClick", function()
        self.session.pendingLinks[link] = nil      -- Skipped: decided, don't re-show on reload
        closePopup(self, f)
        compactPopups(self)
    end)

    f.rollBtn:Show()
    f.rollBtn:SetWidth(46)
    f.rollBtn:SetText("Start")
    f.rollBtn:SetScript("OnClick", function()
        local popupSlot = f.slot
        closePopup(self, f)
        self:StartLiveRoll(item, popupSlot)        -- clears pendingLinks for this item
    end)

    f:SetScript("OnEnter", nil)
    f:SetScript("OnLeave", nil)

    addActivePopup(self, f, slot)        -- reuse a given slot (e.g. when a cancelled roll returns to pending)
    f:Show()
    layoutPopups(self)
end

-- ---------------------------------------------------------------------------
-- result popup
-- ---------------------------------------------------------------------------
function addon:ShowResultPopup(roll, winnerDetails, sections, slot)
    if shouldSuppressPopup(self, roll.name) then
        return
    end
    local f = acquirePopup(self)
    f.mode = "result"
    f:SetScript("OnUpdate", nil)        -- no countdown on a result popup
    f.timer:Hide()
    f.icon:SetTexture(roll.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.itemLink = roll.link
    f.name:SetText(formatRollItemLabel(roll.link, roll.name, roll.quantity))
    f.count:Hide()
    f.countHover:Hide()
    if f.rollLines then
        for _, line in ipairs(f.rollLines) do
            line:Hide()
        end
    end
    setPopupHeight(f, getCompactResultPopupHeight(f))

    local myKey = util:NormalizeKey(util:GetPlayerName("player") or "")

    local winners = {}
    local winnerKeys = {}
    for _, winner in ipairs(winnerDetails or {}) do
        local winnerKey = util:NormalizeKey(winner.name)
        winnerKeys[winnerKey] = true
        local winnerSection
        for _, s in ipairs(sections or {}) do
            for _, m in ipairs(s.members) do
                if util:NormalizeKey(m.name) == winnerKey then
                    winnerSection = s.label
                    break
                end
            end
            if winnerSection then break end
        end
        winners[#winners + 1] = {
            name = winner.name,
            roll = winner.roll,
            section = winnerSection,
            key = winnerKey,
        }
    end

    local line
    if #winners == 0 then
        local namedRule = roll.name and self:GetNamedRule(roll.name)
        if namedRule and namedRule.raw and namedRule.raw ~= "" then
            line = "Winner: Loot Council"
        else
            line = "Winner: No rollers."
        end
    else
        local winnerParts = {}
        for _, winner in ipairs(winners) do
            local className = getPlayerClassName(self, winner.key)
            local colorCode = util:GetClassColorCode(className) or "|cffffffff"
            winnerParts[#winnerParts + 1] = string.format("%s%s|r - %s - %s",
                colorCode,
                winner.name or "Unknown",
                tostring(winner.roll or "-"),
                winner.section or "?")
        end
        local winnerLabel = #winnerParts > 1 and "Winners" or "Winner"
        line = string.format("%s: %s", winnerLabel, table.concat(winnerParts, "; "))
    end
    f.sub:SetText(line)

    f.bisBtn:Hide(); f.msBtn:Hide(); f.muBtn:Hide(); f.osBtn:Hide(); f.tmBtn:Hide(); f.passBtn:Hide(); f.rollBtn:Hide(); f.cancelBtn:Hide()
    f.count:Hide()
    f.okBtn:Show()
    f.okBtn:ClearAllPoints()
    f.okBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    f.okBtn:SetScript("OnClick", function() closePopup(self, f); compactPopups(self) end)

    f.sections = sections
    f.winnerKeys = winnerKeys
    f.myKey = myKey
    if not f.resultHover then
        f.resultHover = CreateFrame("Frame", nil, f)
        f.resultHover:EnableMouse(true)
    end
    f.resultHover:SetPoint("TOPLEFT", f.sub, "TOPLEFT", -2, 2)
    f.resultHover:SetPoint("BOTTOMRIGHT", f.sub, "BOTTOMRIGHT", 2, -2)
    f.resultHover:Show()
    f.resultHover:SetScript("OnEnter", function(selfFrame)
        GameTooltip:SetOwner(selfFrame, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("TOPLEFT", f, "TOPRIGHT", 8, 0)
        GameTooltip:ClearLines()
        GameTooltip:AddLine("Rolls", 1, 0.82, 0)
        for _, s in ipairs(f.sections or {}) do
            if #s.members > 0 then
                local mem = {}
                for _, m in ipairs(s.members) do mem[#mem + 1] = m end
                table.sort(mem, function(a, b) return (a.roll or 0) > (b.roll or 0) end)
                for _, m in ipairs(mem) do
                    local key = util:NormalizeKey(m.name)
                    local winnerType = s.label or "?"
                    local className = getPlayerClassName(self, key)
                    local colorCode = util:GetClassColorCode(className) or "|cffffffff"
                    GameTooltip:AddLine(string.format("  %s%s|r - %s - %s", colorCode, m.name or "Unknown", tostring(m.roll or "-"), winnerType), 1, 1, 1)
                end
            end
        end
        GameTooltip:Show()
    end)
    f.resultHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:SetScript("OnEnter", nil)
    f:SetScript("OnLeave", nil)

    local opt = getOptions()
    if opt.resultPopupAutoCloseEnabled then
        local timeout = tonumber(opt.resultPopupAutoCloseSeconds) or 15
        if timeout > 0 then
            f.resultElapsed = 0
            f:SetScript("OnUpdate", function(selfFrame, elapsed)
                selfFrame.resultElapsed = (selfFrame.resultElapsed or 0) + (elapsed or 0)
                if selfFrame.resultElapsed >= timeout then
                    selfFrame:SetScript("OnUpdate", nil)
                    closePopup(self, selfFrame)
                    compactPopups(self)
                end
            end)
        end
    end

    addActivePopup(self, f, slot)        -- reuse the interest popup's slot so it stays put
    f:Show()
    layoutPopups(self)
end

-- ---------------------------------------------------------------------------
-- loot master: start / resolve
-- ---------------------------------------------------------------------------
local function nextRollId(self)
    self.live.seq = self.live.seq + 1
    return tostring(time()) .. "r" .. self.live.seq
end

function addon:GetLiveItemPrio(item)
    local itemName = item and item.name
    local namedRule = itemName and self:GetNamedRule(itemName)
    if namedRule and namedRule.raw and namedRule.raw ~= "" then
        local prioText = formatNamedRuleDisplay(namedRule)
        if not prioText or prioText == "" then
            prioText = namedRule.raw
            if self:RuleHasLootCouncil(namedRule) and not string.match(prioText, ">%s*[Ll][Cc]%s*$") then
                prioText = prioText .. " > LC"
            end
        end
        return prioText
    end

    local lootRule = itemName and self:GetLootRule(itemName)
    return formatLootRuleDisplay(lootRule) or "BiS > MS > MU > OS > TM"   -- default: bracket order
end

function addon:HasOpenRollForLink(link)
    for _, roll in pairs(self.live.rolls or {}) do
        if not roll.resolved and roll.link == link then return true end
    end
    return false
end

-- Surface a pending popup for each newly-arrived (looted or traded-in) item, once per
-- item link. The ML decides when to actually broadcast each roll (Start Roll). Loot-
-- master only, opt-out via WeirdLootDB.autoRoll. Called from OnBagUpdate with the set
-- of links whose bag count just went up.
-- is a pending popup currently on screen for this item link?
function addon:HasOpenPendingForLink(link)
    for _, f in ipairs(self.live.active) do
        if f.mode == "pending" and f.pendingLink == link then return true end
    end
    return false
end

function addon:GetActiveLiveRollForItem(item)
    if not item then
        return nil
    end

    for _, roll in pairs(self.live.rolls or {}) do
        if roll and not roll.resolved then
            if item.id then
                if roll.itemId == item.id then
                    return roll
                end
            elseif item.link and item.link ~= "" and roll.link == item.link then
                return roll
            end
        end
    end

    return nil
end

function addon:DismissPendingPopupForLink(link, clearPending)
    if not link or link == "" then
        return nil
    end

    for _, f in ipairs(self.live.active) do
        if f.mode == "pending" and f.pendingLink == link then
            local slot = f.slot
            closePopup(self, f)
            if clearPending then
                compactPopups(self)
            end
            if clearPending and self.session.pendingLinks then
                self.session.pendingLinks[link] = nil
            end
            return slot
        end
    end

    if clearPending and self.session.pendingLinks then
        self.session.pendingLinks[link] = nil
    end
    return nil
end

function addon:SkipLiveLootItem(item)
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can skip live loot items.")
        return
    end
    if not item or not item.link or item.link == "" then
        return
    end

    self:DismissPendingPopupForLink(item.link, true)
end

function addon:StartLiveRollFromItem(item)
    if not item or not item.link or item.link == "" then
        return
    end

    local slot = self:DismissPendingPopupForLink(item.link, false)
    self:StartLiveRoll(item, slot)
end

function addon:AutoRollAddedItems(addedLinks)
    if not self.db.autoRoll then return end
    if not self:IsAuthorizedLootMaster() then return end
    for _, item in ipairs(self.session.items or {}) do
        local addedCount = addedLinks[item.link]
        if addedCount and addedCount > 0 then
            -- Dedup on the actual on-screen popup, NOT the persisted pendingLinks flag
            -- (which can be stale and would wrongly suppress a real new drop).
            if not self:HasOpenPendingForLink(item.link) and not self:HasOpenRollForLink(item.link) then
                local pendingItem = {
                    id = item.id,
                    link = item.link,
                    name = item.name,
                    icon = item.icon,
                    quantity = addedCount,
                }
                self:ShowPendingPopup(pendingItem)
            end
        end
    end
end

-- After a reload, re-show the pending popups for any items the ML hadn't decided on yet
-- (Start/Skip). Skipped or rolled items aren't in pendingLinks, so they stay gone.
function addon:RestorePendingPopups()
    if not self:IsAuthorizedLootMaster() then return end
    local pending = self.session.pendingLinks
    if not pending then return end
    for _, item in ipairs(self.session.items or {}) do
        if pending[item.link] and not self:HasOpenRollForLink(item.link) then
            -- guard against a double restore (e.g. login path + delayed ML re-check)
            local already = false
            for _, f in ipairs(self.live.active) do
                if f.mode == "pending" and f.pendingLink == item.link then already = true break end
            end
            if not already then
                local pendingItem = pending[item.link]
                if type(pendingItem) == "table" then
                    self:ShowPendingPopup({
                        id = item.id,
                        link = item.link,
                        name = pendingItem.name or item.name,
                        icon = pendingItem.icon or item.icon,
                        quantity = pendingItem.quantity or item.quantity or 1,
                    })
                else
                    self:ShowPendingPopup(item)
                end
            end
        end
    end
end

-- Abort an open roll. For raiders the item disappears (CANCEL closes their popup). For
-- the ML the loot is NOT lost: we return to the pre-roll pending state (Start Roll / Skip)
-- in the same slot, so the ML can re-roll or skip it.
function addon:CancelLiveRoll(rollId)
    local roll = self.live.rolls[rollId]
    if not roll then return end
    roll.resolved = true
    self:SendLargeMessage("CANCEL", { rollId }, "RAID")
    self.live.rolls[rollId] = nil

    local item = { id = roll.itemId, link = roll.link, name = roll.name, icon = roll.icon, quantity = roll.quantity or 1 }
    local slot = roll.popup and roll.popup.slot
    self:CloseInterestPopup(roll)
    self:ShowPendingPopup(item, slot)        -- back to pending in place, not gone
    self:TriggerCallback("SESSION_UPDATED")
    self:Print("Roll cancelled: " .. (roll.name or roll.link or "item") .. " (back to pending).")
end

function addon:OnCancelMessage(fields)
    local roll = self.live.rolls[fields[1]]
    if not roll then return end
    self:CloseInterestPopup(roll)
    compactPopups(self)
    self.live.rolls[fields[1]] = nil
    self:TriggerCallback("SESSION_UPDATED")
end

function addon:StartLiveRoll(item, slot)
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can put items up for roll.")
        return
    end
    if not item or not item.link or item.link == "" then return end

    if item.id and self:IsItemLocked(item.id) then
        self:Print((item.name or item.link) .. " was already rolled out. Use Unlock Roll to reroll it.")
        if self.session.pendingLinks then self.session.pendingLinks[item.link] = nil end  -- don't leave it stuck pending
        return
    end

    if self.session.pendingLinks then self.session.pendingLinks[item.link] = nil end  -- decided: now rolling

    local rollId = nextRollId(self)
    local prio = self:GetLiveItemPrio(item)
    local rollDuration = getRollDuration()
    local roll = {
        id = rollId, itemId = item.id, link = item.link, name = item.name or item.link,
        icon = item.icon, prio = prio, owner = true, registrants = {}, resolved = false,
        duration = rollDuration, quantity = item.quantity or 1,
    }

    if item.id then
        for _, roller in ipairs(self:BuildRollerList(item.id) or {}) do
            local playerKey = util:NormalizeKey(roller.name)
            roll.registrants[playerKey] = {
                name = roller.name,
                className = roller.className or getPlayerClassName(self, playerKey),
                tier = roller.responseType,
                roll = nextLiveRollValue(),
            }
        end
    end

    self.live.rolls[rollId] = roll

    self:SendLargeMessage("DROP",
        { rollId, item.link, item.name or "", item.icon or "", prio or "", tostring(rollDuration), tostring(item.quantity or 1), item.id or "" }, "RAID")
    for _, registrant in pairs(roll.registrants or {}) do
        if registrant.tier and registrant.tier ~= "pass" then
            self:BroadcastLiveRollState(rollId, registrant.name, registrant.className, registrant.tier, registrant.roll)
        end
    end
    self:ShowInterestPopup(roll, slot)
    self:TriggerCallback("SESSION_UPDATED")
    self:Print("Put " .. (item.name or item.link) .. " up for roll. Press Roll! when ready.")
end

function addon:ResolveLiveRoll(rollId)
    local roll = self.live.rolls[rollId]
    if not roll or roll.resolved then return end
    if not self:IsAuthorizedLootMaster() then return end
    roll.resolved = true

    -- Registrants' brackets are already in session.responses (RegisterInterest). Resolve
    -- through the SAME engine the batch flow uses: bracket -> named -> spec -> status -> roll.
    local sit = self:LiveRollSessionItem(roll)
    local item = {
        id = sit.id,
        name = sit.name or roll.name,
        link = sit.link or roll.link,
        icon = sit.icon or roll.icon,
        quantity = sit.quantity or roll.quantity or 1,
        liveRollAssignments = {},
    }
    for playerKey, registrant in pairs(roll.registrants or {}) do
        if registrant.tier and registrant.tier ~= "pass" and registrant.roll then
            item.liveRollAssignments[playerKey] = {
                name = registrant.name or getPlayerDisplayName(self, playerKey),
                className = registrant.className or getPlayerClassName(self, playerKey),
                roll = registrant.roll,
                auto = false,
            }
        end
    end
    local record = self:ResolveSessionItem(item)

    -- adapt the record's roller breakdown into the popup's section format (grouped by bracket)
    local sections = self:SectionsFromResult(record)

    self:SendLargeMessage("WIN", {
        rollId, roll.link, self:EncodeWinnerDetails(record.winnerDetails), self:EncodeSections(sections),
    }, "RAID")

    -- finish: record + lock + broadcast, identical to the batch path
    self:RemoveResultByItemId(item.id)
    self.session.results = self.session.results or {}
    self.session.results[#self.session.results + 1] = record
    self:LockItem(item.id)
    self:AddResolvedHeldItem(item.link, item.quantity or 1)
    self:BroadcastResults({ record })
    self:BroadcastSessionLocks()
    self:TriggerCallback("RESULTS_UPDATED")

    -- payout (skip when the ML won their own roll -- already in hand)
    local myKey = util:NormalizeKey(util:GetPlayerName("player") or "")
    local selfWon = false
    if self.payout then
        local itemId = tonumber(string.match(roll.link or "", "|Hitem:(%d+)"))
        if itemId then
            for _, winner in ipairs(record.winnerDetails or {}) do
                local winnerKey = util:NormalizeKey(winner.name)
                if winnerKey == myKey then
                    selfWon = true
                elseif winner.name and winner.name ~= "" then
                    self.payout:Owe(winner.name, itemId, 1, roll.link)
                end
            end
        end
    end

    local slot = roll.popup and roll.popup.slot
    self:CloseInterestPopup(roll)
    self:ShowResultPopup(roll, record.winnerDetails or {}, sections, slot)
    self:TriggerCallback("SESSION_UPDATED")

    if #(record.winnerDetails or {}) == 0 then
        self:Print(roll.name .. " -> no rollers.")
    elseif selfWon then
        self:Print(string.format("%s -> %s. You already hold one copy; other winners queued for payout as needed.", roll.name, record.winnersText or record.winner or "winner"))
    else
        self:Print(string.format("%s -> %s. Queued for payout.", roll.name, record.winnersText or record.winner or "winner"))
    end
end

-- Group a result record's rollers by bracket into the popup's section format
-- ({label, members={{name, roll}}}), highest bracket first, for the result popup breakdown.
local SECTION_ORDER = { "bis", "ms", "mu", "os", "tm" }
local SECTION_LABELS = { bis = "BiS", ms = "MS", mu = "MU", os = "OS", tm = "TM" }
function addon:SectionsFromResult(record)
    local buckets = {}
    for _, d in ipairs(record.allRollerDetails or {}) do
        local b = d.responseType or "pass"
        if b ~= "pass" then
            buckets[b] = buckets[b] or {}
            buckets[b][#buckets[b] + 1] = { name = d.name, roll = tonumber(d.rollText) }
        end
    end
    local sections = {}
    for _, key in ipairs(SECTION_ORDER) do
        if buckets[key] then sections[#sections + 1] = { label = SECTION_LABELS[key], members = buckets[key] } end
    end
    return sections
end

-- Find the live roll's backing session item (so the result/lock use the real item id),
-- or synthesize a minimal one if it's no longer in the session list.
function addon:LiveRollSessionItem(roll)
    for _, it in ipairs(self.session.items or {}) do
        if (roll.itemId and it.id == roll.itemId) or it.link == roll.link then
            return it
        end
    end
    return { id = roll.itemId or roll.link, name = roll.name, link = roll.link, icon = roll.icon, quantity = roll.quantity or 1 }
end


-- pack sections for WIN: "label~name=roll,name=roll" joined by ";"
function addon:EncodeSections(sections)
    local secParts = {}
    for _, s in ipairs(sections or {}) do
        local mem = {}
        for _, m in ipairs(s.members) do mem[#mem + 1] = m.name .. "=" .. (m.roll or 0) end
        secParts[#secParts + 1] = (s.label or "") .. "~" .. table.concat(mem, ",")
    end
    return table.concat(secParts, ";")
end

function addon:EncodeWinnerDetails(winnerDetails)
    local parts = {}
    for _, winner in ipairs(winnerDetails or {}) do
        parts[#parts + 1] = (winner.name or "") .. "=" .. tostring(winner.roll or 0)
    end
    return table.concat(parts, ",")
end

function addon:DecodeWinnerDetails(text)
    local winners = {}
    for name, value in string.gmatch(text or "", "([^=,]+)=([^,]+)") do
        winners[#winners + 1] = { name = name, roll = tonumber(value) or 0 }
    end
    return winners
end

function addon:DecodeSections(text)
    local sections = {}
    for _, secText in ipairs(util:Split(text or "", ";")) do
        local label, memText = string.match(secText, "^(.-)~(.*)$")
        local members = {}
        for name, value in string.gmatch(memText or "", "([^=,]+)=([^,]+)") do
            members[#members + 1] = { name = name, roll = tonumber(value) }
        end
        sections[#sections + 1] = { label = label or "", members = members }
    end
    return sections
end

-- ---------------------------------------------------------------------------
-- interest send + register
-- ---------------------------------------------------------------------------
function addon:SendInterest(rollId, tier)
    if self:IsAuthorizedLootMaster() then
        self:RegisterInterest(rollId, util:GetPlayerName("player"), tier)
    else
        local lootMaster = self:GetLootMasterName()
        if lootMaster then
            self:SendLargeMessage("RSP", { rollId, tier }, "WHISPER", lootMaster)
        end
    end
end

function addon:BroadcastLiveRollState(rollId, playerName, className, tier, rollValue)
    if not self:IsAuthorizedLootMaster() then
        return
    end

    self:SendLargeMessage("LIVE_SYNC", {
        rollId or "",
        playerName or "",
        className or "",
        tier or "pass",
        tostring(rollValue or 0),
    }, "RAID")
end

function addon:RegisterInterest(rollId, name, tier)
    local roll = self.live.rolls[rollId]
    if not roll or roll.resolved then return end
    if tier ~= "pass" and not isPlayerAllowedForRoll(self, roll, name) then
        tier = "pass"
    end
    local playerKey = util:NormalizeKey(name)
    local existing = roll.registrants[playerKey] or {}
    local displayName = (name and name ~= "") and name or existing.name or getPlayerDisplayName(self, playerKey)
    local className = existing.className or getPlayerClassName(self, playerKey)
    local rollValue = existing.roll
    if tier == "pass" then
        rollValue = nil
    elseif not rollValue then
        rollValue = nextLiveRollValue()
    end
    roll.registrants[playerKey] = { name = displayName, className = className, tier = tier, roll = rollValue }
    if self:IsAuthorizedLootMaster() then
        self:BroadcastLiveRollState(rollId, displayName, className, tier, rollValue)
    end
    -- Mirror the pick into the shared response model so the Loot tab reflects it and the
    -- same resolver (BuildRollerList -> ResolveSessionItem) sees these rollers.
    if roll.itemId then
        self:SetPlayerResponse(roll.itemId, name, tier)
        if self:IsAuthorizedLootMaster() then
            self:BroadcastSelectionState(roll.itemId, name, tier)
        end
        self:TriggerCallback("SESSION_UPDATED")
    end
    self:RefreshInterestPopup(roll)
end

-- ---------------------------------------------------------------------------
-- incoming comm messages (dispatched from Comm.lua HandleCommMessage)
-- ---------------------------------------------------------------------------
function addon:OnDropMessage(fields)
    local roll = {
        id = fields[1],
        link = fields[2] or "",
        name = (fields[3] ~= "" and fields[3]) or fields[2],
        icon = (fields[4] ~= "" and fields[4]) or nil,
        prio = fields[5] or "",
        duration = tonumber(fields[6]) or ROLL_DURATION,
        quantity = tonumber(fields[7]) or 1,
        itemId = (fields[8] ~= "" and fields[8]) or nil,
        owner = false, registrants = {}, resolved = false,
    }
    if roll.itemId then
        local myChoice = self:GetPlayerResponse(roll.itemId, util:GetPlayerName("player"))
        if myChoice and myChoice ~= "" then
            roll.choice = myChoice
        end
    end
    self.live.rolls[roll.id] = roll
    self:ShowInterestPopup(roll)
    self:TriggerCallback("SESSION_UPDATED")
end

function addon:OnRspMessage(sender, fields)
    if not self:IsAuthorizedLootMaster() then return end
    self:RegisterInterest(fields[1], sender, fields[2])
end

function addon:OnLiveSyncMessage(fields)
    local rollId = fields[1]
    local playerName = fields[2]
    local className = fields[3] or ""
    local tier = fields[4] or "pass"
    local rollValue = tonumber(fields[5]) or 0
    local roll = self.live.rolls[rollId]
    if not roll or roll.resolved then
        return
    end

    local playerKey = util:NormalizeKey(playerName)
    roll.registrants[playerKey] = {
        name = playerName,
        className = className,
        tier = tier,
        roll = tier ~= "pass" and rollValue or nil,
    }
    self:RefreshInterestPopup(roll)
    self:TriggerCallback("SESSION_UPDATED")
end

function addon:OnWinMessage(fields)
    local rollId, link, winnersText, sectionsText = fields[1], fields[2], fields[3], fields[4]
    local roll = self.live.rolls[rollId] or { id = rollId, link = link or "", name = link, icon = nil }
    roll.resolved = true

    -- Do NOT auto-hide a won item. If the player still has the dialog open (they chose
    -- a tier or were still deciding), convert it to a result popup they must OK to
    -- dismiss. If they already Passed (popup gone), leave it gone -- don't re-pop it.
    if roll.popup then
        local winners = self:DecodeWinnerDetails(winnersText)
        local sections = self:DecodeSections(sectionsText)
        local slot = roll.popup.slot
        self:CloseInterestPopup(roll)
        self:ShowResultPopup(roll, winners, sections, slot)
    end
end
