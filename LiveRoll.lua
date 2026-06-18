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
local ROLL_DURATION = 20        -- seconds raiders have to roll before it auto-resolves
local popupBasePoint, savePopupBasePoint, layoutPopups

local function makeButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(width)
    b:SetHeight(18)
    b:SetText(text)
    return b
end

-- roll-choice brackets, highest priority first: BiS > MS > MU > OS > TM (Pass
-- declines). Use the button's natural pressed visual to show the pick: the chosen button
-- locks in its down state; picking a different one pops the previous back up.
local function interestButtons(f)
    return { bis = f.bisBtn, ms = f.msBtn, mu = f.muBtn, os = f.osBtn, tm = f.tmBtn, pass = f.passBtn }
end
-- chosen button: bold (outlined) green label; others: normal gold label
local function styleButtonText(btn, chosen)
    local fs = btn:GetFontString()
    if not fs then return end
    local font, size = fs:GetFont()
    if chosen then
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
            styleButtonText(btn, false)
        end
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
            styleButtonText(btn, chosen)
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
    f.name:SetWidth(POPUP_W - 56)
    f.name:SetJustifyH("LEFT")

    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -2)
    f.sub:SetWidth(POPUP_W - 56)
    f.sub:SetJustifyH("LEFT")

    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.count:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -8)

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

    -- control row (loot master): End Roll / Cancel on the left, OK (result mode) on the right
    f.rollBtn = makeButton(f, "End Roll", 56)
    f.rollBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 10)
    f.cancelBtn = makeButton(f, "Cancel", 50)
    f.cancelBtn:SetPoint("LEFT", f.rollBtn, "RIGHT", 6, 0)
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
    for _, f in ipairs(self.live.active) do
        local slot = f.slot or 0
        f:ClearAllPoints()
        f:SetPoint("TOP", self.live.anchor or UIParent, "TOP", 0, -slot * (POPUP_H + 8))
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
    f:Hide()
    removeActive(self, f)
    self.live.pool[#self.live.pool + 1] = f
    layoutPopups(self)
end

-- ---------------------------------------------------------------------------
-- interest popup
-- ---------------------------------------------------------------------------
function addon:ShowInterestPopup(roll)
    local f = acquirePopup(self)
    f.roll = roll
    roll.popup = f
    f.mode = "interest"

    roll.choice = nil
    f.icon:SetTexture(roll.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.itemLink = roll.link
    f.name:SetText(roll.link ~= "" and roll.link or roll.name or "Item")
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

    if roll.owner then
        -- the ML keeps the popup to drive the roll: Cancel aborts, Roll! resolves
        f.rollBtn:Show()
        f.rollBtn:SetWidth(56)
        f.rollBtn:SetText("End Roll")
        f.rollBtn:SetScript("OnClick", function() self:ResolveLiveRoll(roll.id) end)
        f.cancelBtn:Show()
        f.cancelBtn:SetWidth(50)
        f.cancelBtn:SetText("Cancel")
        f.cancelBtn:SetScript("OnClick", function() self:CancelLiveRoll(roll.id) end)
        f.count:Show()
    else
        f.rollBtn:Hide()
        f.cancelBtn:Hide()
        f.count:Hide()
    end

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

    addActivePopup(self, f)
    f:Show()
    layoutPopups(self)
    self:RefreshInterestPopup(roll)
end

function addon:RefreshInterestPopup(roll)
    local f = roll and roll.popup
    if not f or f.mode ~= "interest" or not roll.owner then return end
    local total = 0
    for _, r in pairs(roll.registrants) do
        if r.tier and r.tier ~= "pass" then total = total + 1 end
    end
    f.count:SetText(total > 0 and (total .. " rolling") or "")
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
    f:SetScript("OnUpdate", nil)        -- no countdown until the roll actually starts
    f.timer:Hide()
    f.pendingLink = link
    self.session.pendingLinks = self.session.pendingLinks or {}
    self.session.pendingLinks[link] = true      -- persisted: re-shown to the ML after a reload

    f.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.itemLink = link
    f.name:SetText(link)
    f.sub:SetText("|cffffffffPrio:|r " .. (self:GetLiveItemPrio(item) or "BiS > MS > MU > OS > TM"))
    f.count:Hide()

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
    f.rollBtn:SetWidth(90)
    f.rollBtn:SetText("Start Roll")
    f.rollBtn:SetScript("OnClick", function()
        closePopup(self, f)
        self:StartLiveRoll(item)        -- clears pendingLinks for this item
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
function addon:ShowResultPopup(roll, winner, winnerRoll, sections, slot)
    local f = acquirePopup(self)
    f.mode = "result"
    f:SetScript("OnUpdate", nil)        -- no countdown on a result popup
    f.timer:Hide()
    f.icon:SetTexture(roll.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.itemLink = roll.link
    f.name:SetText(roll.link ~= "" and roll.link or roll.name or "Item")

    local myKey = util:NormalizeKey(util:GetPlayerName("player") or "")
    local winKey = winner and winner ~= "" and util:NormalizeKey(winner) or nil
    local myRoll, mySection, winnerSection
    for _, s in ipairs(sections or {}) do
        for _, m in ipairs(s.members) do
            local k = util:NormalizeKey(m.name)
            if k == myKey then myRoll = m.roll; mySection = s.label end
            if winKey and k == winKey then winnerSection = s.label end
        end
    end

    local line
    if not winKey then
        line = "No rollers."
    elseif winKey == myKey then
        line = string.format("|cff40ff40You won!|r  (your roll %s)", tostring(myRoll or winnerRoll))
    else
        local mine = myRoll and string.format("Your roll %d%s.  ", myRoll, mySection and (" ("..mySection..")") or "") or ""
        line = string.format("|cffff6060You lost.|r  %sWinner: %s (%s%s)", mine, winner,
            tostring(winnerRoll), winnerSection and (", " .. winnerSection) or "")
    end
    f.sub:SetText(line)

    f.bisBtn:Hide(); f.msBtn:Hide(); f.muBtn:Hide(); f.osBtn:Hide(); f.tmBtn:Hide(); f.passBtn:Hide(); f.rollBtn:Hide(); f.cancelBtn:Hide()
    f.count:Hide()
    f.okBtn:Show()
    f.okBtn:SetScript("OnClick", function() closePopup(self, f); compactPopups(self) end)

    -- hover: full breakdown by priority section so a higher roll in a lower section is
    -- clearly explained
    f.sections = sections
    f.winnerKey = winKey
    f.myKey = myKey
    f:SetScript("OnEnter", function(selfFrame)
        GameTooltip:SetOwner(selfFrame, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("Roll breakdown (priority order)", 1, 0.82, 0)
        local awarded = false
        for _, s in ipairs(selfFrame.sections or {}) do
            if #s.members > 0 then
                local marker = (not awarded) and "  |cff40ff40<- winning section|r" or ""
                GameTooltip:AddLine("|cff88ccff" .. (s.label or "?") .. "|r" .. marker, 1, 1, 1)
                local mem = {}
                for _, m in ipairs(s.members) do mem[#mem + 1] = m end
                table.sort(mem, function(a, b) return (a.roll or 0) > (b.roll or 0) end)
                for _, m in ipairs(mem) do
                    local key = util:NormalizeKey(m.name)
                    local isMe = selfFrame.myKey and key == selfFrame.myKey
                    local won = selfFrame.winnerKey and key == selfFrame.winnerKey
                    local label = isMe and "You" or m.name
                    if won then
                        label = "|cff40ff40" .. label .. "|r"            -- winner: green
                    elseif isMe then
                        label = "|cff66ccff" .. label .. "|r"            -- your own row: blue
                    end
                    GameTooltip:AddDoubleLine("  " .. label, tostring(m.roll or "-"), 1, 1, 1, 1, 1, 1)
                end
                awarded = true
            end
        end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

function addon:AutoRollAddedItems(addedLinks)
    if not self.db.autoRoll then return end
    if not self:IsAuthorizedLootMaster() then return end
    for _, item in ipairs(self.session.items or {}) do
        if addedLinks[item.link] then
            -- A genuinely new copy just arrived in the bags. If a previous copy was rolled
            -- out the item is locked; clear that so the duplicate can be rolled (the lock
            -- only ever meant "the drop already handled was rolled out").
            if item.id then self:UnlockItem(item.id) end
            -- Dedup on the actual on-screen popup, NOT the persisted pendingLinks flag
            -- (which can be stale and would wrongly suppress a real new drop).
            if not self:HasOpenPendingForLink(item.link) and not self:HasOpenRollForLink(item.link) then
                self:ShowPendingPopup(item)
            end
        end
    end
end

function addon:AutoRollHintedItems()
    if not self.db.autoRoll then return end
    if not self:IsAuthorizedLootMaster() then return end

    local pendingHintedRolls = self.session.pendingHintedRolls or {}
    for _, item in ipairs(self.session.items or {}) do
        if pendingHintedRolls[item.link] then
            if item.id then self:UnlockItem(item.id) end
            if not self:HasOpenPendingForLink(item.link) and not self:HasOpenRollForLink(item.link) then
                self:ShowPendingPopup(item)
            end
            pendingHintedRolls[item.link] = nil
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
            if not already then self:ShowPendingPopup(item) end
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

    local item = { id = roll.itemId, link = roll.link, name = roll.name, icon = roll.icon }
    local slot = roll.popup and roll.popup.slot
    self:CloseInterestPopup(roll)
    self:ShowPendingPopup(item, slot)        -- back to pending in place, not gone
    self:Print("Roll cancelled: " .. (roll.name or roll.link or "item") .. " (back to pending).")
end

function addon:OnCancelMessage(fields)
    local roll = self.live.rolls[fields[1]]
    if not roll then return end
    self:CloseInterestPopup(roll)
    compactPopups(self)
    self.live.rolls[fields[1]] = nil
end

function addon:StartLiveRoll(item)
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
    if item.id then self.session.responses[item.id] = {} end   -- fresh responses for this roll

    local rollId = nextRollId(self)
    local prio = self:GetLiveItemPrio(item)
    local roll = {
        id = rollId, itemId = item.id, link = item.link, name = item.name or item.link,
        icon = item.icon, prio = prio, owner = true, registrants = {}, resolved = false,
        duration = ROLL_DURATION,
    }
    self.live.rolls[rollId] = roll

    self:SendLargeMessage("DROP",
        { rollId, item.link, item.name or "", item.icon or "", prio or "", tostring(ROLL_DURATION) }, "RAID")
    self:ShowInterestPopup(roll)
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
    local item = { id = sit.id, name = sit.name or roll.name, link = sit.link or roll.link, icon = sit.icon or roll.icon, quantity = 1 }
    local record = self:ResolveSessionItem(item)

    local winner = (record.winner and record.winner ~= "No winner") and record.winner or nil
    local winnerRoll
    for _, w in ipairs(record.winnerDetails or {}) do
        if w.name == record.winner then winnerRoll = w.roll end
    end

    -- adapt the record's roller breakdown into the popup's section format (grouped by bracket)
    local sections = self:SectionsFromResult(record)

    self:SendLargeMessage("WIN", {
        rollId, roll.link, winner or "", "roll", tostring(winnerRoll or 0), self:EncodeSections(sections),
    }, "RAID")

    -- finish: record + lock + broadcast, identical to the batch path
    self:RemoveResultByItemId(item.id)
    self.session.results = self.session.results or {}
    self.session.results[#self.session.results + 1] = record
    self:LockItem(item.id)
    self:BroadcastResults({ record })
    self:BroadcastSessionLocks()
    self:TriggerCallback("RESULTS_UPDATED")

    -- payout (skip when the ML won their own roll -- already in hand)
    local selfWin = winner and util:NormalizeKey(winner) == util:NormalizeKey(util:GetPlayerName("player") or "")
    if winner and self.payout and not selfWin then
        local itemId = tonumber(string.match(roll.link or "", "|Hitem:(%d+)"))
        if itemId then self.payout:Owe(winner, itemId, 1, roll.link) end
    end

    local slot = roll.popup and roll.popup.slot
    self:CloseInterestPopup(roll)
    self:ShowResultPopup(roll, winner, winnerRoll, sections, slot)

    if not winner then
        self:Print(roll.name .. " -> no rollers.")
    elseif selfWin then
        self:Print(string.format("%s -> %s (%s). You already hold it; not queued for payout.", roll.name, winner, tostring(winnerRoll)))
    else
        self:Print(string.format("%s -> %s (%s). Queued for payout.", roll.name, winner, tostring(winnerRoll)))
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
    return { id = roll.itemId or roll.link, name = roll.name, link = roll.link, icon = roll.icon }
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

function addon:RegisterInterest(rollId, name, tier)
    local roll = self.live.rolls[rollId]
    if not roll or roll.resolved then return end
    roll.registrants[util:NormalizeKey(name)] = { name = name, tier = tier }
    -- Mirror the pick into the shared response model so the Loot tab reflects it and the
    -- same resolver (BuildRollerList -> ResolveSessionItem) sees these rollers.
    if roll.itemId then self:SetPlayerResponse(roll.itemId, name, tier) end
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
        owner = false, registrants = {}, resolved = false,
    }
    self.live.rolls[roll.id] = roll
    self:ShowInterestPopup(roll)
end

function addon:OnRspMessage(sender, fields)
    if not self:IsAuthorizedLootMaster() then return end
    self:RegisterInterest(fields[1], sender, fields[2])
end

function addon:OnWinMessage(fields)
    local rollId, link, winner, _, winnerRoll, sectionsText = fields[1], fields[2], fields[3], fields[4], fields[5], fields[6]
    local roll = self.live.rolls[rollId] or { id = rollId, link = link or "", name = link, icon = nil }
    roll.resolved = true

    -- Do NOT auto-hide a won item. If the player still has the dialog open (they chose
    -- a tier or were still deciding), convert it to a result popup they must OK to
    -- dismiss. If they already Passed (popup gone), leave it gone -- don't re-pop it.
    if roll.popup then
        local sections = self:DecodeSections(sectionsText)
        local slot = roll.popup.slot
        self:CloseInterestPopup(roll)
        self:ShowResultPopup(roll, winner, tonumber(winnerRoll), sections, slot)
    end
end
