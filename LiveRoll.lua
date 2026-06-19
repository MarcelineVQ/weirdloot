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

    -- The core drives surfacing now: a fresh lot auto-surfaces (ML + autoRoll), and any
    -- ledger change reconciles the on-screen pending popups with the core's PENDING lots.
    if self.lootCore and not self._liveRollWired then
        self._liveRollWired = true
        self.lootCore:On("lotAdded", function(lot) self:OnLotAdded(lot) end)
        self.lootCore:On("ledgerChanged", function() self:SyncPendingPopups() end)
    end
end

-- A freshly-minted lot auto-surfaces to the ML (unless autoRoll is off), moving it to
-- PENDING so SyncPendingPopups shows its Start Roll / Skip popup.
function addon:OnLotAdded(lot)
    if not self:IsAuthorizedLootMaster() then return end
    if not self.db or not self.db.autoRoll then return end
    if lot and lot.state == self.lootCore.STATE.NEW then
        self.lootCore:Surface(lot.id)
    end
end

-- Reconcile pending popups against the core: show one for every PENDING lot that lacks a
-- popup, and close any pending popup whose lot has left PENDING (rolled / skipped / gone).
function addon:SyncPendingPopups()
    if not self:IsAuthorizedLootMaster() then return end
    local core = self.lootCore
    for _, lot in ipairs(core:List()) do
        if lot.state == core.STATE.PENDING and not self:HasOpenPendingForLot(lot.id) then
            self:ShowPendingPopup(lot)
        end
    end
    for i = #self.live.active, 1, -1 do
        local f = self.live.active[i]
        if f.mode == "pending" and f.lotId and core:State(f.lotId) ~= core.STATE.PENDING then
            self:ClosePendingFrame(f)
        end
    end
end

function addon:HasOpenPendingForLot(lotId)
    for _, f in ipairs(self.live.active) do
        if f.mode == "pending" and f.lotId == lotId then return true end
    end
    return false
end

function addon:HasOpenRollForLot(lotId)
    local roll = self.live.rolls and self.live.rolls[lotId]
    return roll ~= nil and not roll.resolved
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

local function positionInterestButtons(f, isOwner)
    f.bisBtn:ClearAllPoints()
    if isOwner then
        f.bisBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 32)
    else
        f.bisBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 10)
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

-- Late-bound method wrapper so the event handlers defined earlier (SyncPendingPopups) can
-- close a frame without a forward reference to the local closePopup.
function addon:ClosePendingFrame(f)
    closePopup(self, f)
    compactPopups(self)
end

local function formatRollItemLabel(link, name, quantity)
    local itemText = link ~= "" and link or name or "Item"
    if (quantity or 1) > 1 then
        itemText = string.format("%s x%d", itemText, quantity)
    end
    return itemText
end

-- ---------------------------------------------------------------------------
-- item-name resolution for popups
--
-- Popups render their label from the lot's itemId via util:ItemRender (GetItemInfo). On a
-- cache miss (an item the client has not cached yet -- always the case for raiders, who get
-- only the itemId over the wire, and often for the ML on a fresh drop) GetItemInfo returns
-- nil and the label freezes as "item:<id>". Unlike the Loot tab (rebuilt on every
-- ledgerChanged), a popup is built once, so without this it would never recover. We prime
-- the client cache and re-render on a ticker until the real name arrives.
-- ---------------------------------------------------------------------------

-- Force the client to fetch an item's data (3.3.5a has no GET_ITEM_INFO_RECEIVED event).
function addon:PrimeItemInfo(itemId)
    if not itemId then return end
    if not self._scanTip then
        self._scanTip = CreateFrame("GameTooltip", "WeirdLootScanTip", UIParent, "GameTooltipTemplate")
    end
    self._scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    self._scanTip:SetHyperlink("item:" .. tostring(itemId))
end

-- Re-render a popup's name/icon/link from its itemId. Returns true once the name resolves.
function addon:RefreshPopupItem(f)
    if not f or not f.itemId then return true end
    local name, link, icon = util:ItemRender(f.itemId)
    if not name then return false end
    f.itemLink = link
    f.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.name:SetText(formatRollItemLabel(link, name, f.itemQuantity))
    if f.mode == "pending" then
        f.sub:SetText("|cffffffffPrio:|r " .. (self:GetLiveItemPrio({ name = name }) or "BiS > MS > MU > OS > TM"))
    end
    if f.roll then f.roll.name = name; f.roll.link = link; f.roll.icon = icon end
    return true
end

-- Drive a ~0.25s sweep over open popups, re-rendering any whose name has not resolved yet.
-- Self-stops when every popup has a real name, and re-arms when a new unresolved popup opens.
function addon:EnsureNameTicker()
    local anchor = self.live and self.live.anchor
    if not anchor or anchor.__nameTicker then return end
    anchor.__nameTicker = true
    anchor.__nameAccum = 0
    anchor:SetScript("OnUpdate", function(_, elapsed)
        anchor.__nameAccum = anchor.__nameAccum + (elapsed or 0)
        if anchor.__nameAccum < 0.25 then return end
        anchor.__nameAccum = 0
        local pending = 0
        for _, f in ipairs(self.live.active or {}) do
            if f.itemId and not f.itemResolved then
                if self:RefreshPopupItem(f) then
                    f.itemResolved = true
                else
                    pending = pending + 1
                end
            end
        end
        if pending == 0 then
            anchor:SetScript("OnUpdate", nil)
            anchor.__nameTicker = nil
        end
    end)
end

-- Record the itemId a popup is showing. If its name is not cached yet, prime the client and
-- start the resolve ticker; the creation-site render already shows the "item:<id>" fallback.
function addon:TrackPopupItem(f, itemId, quantity)
    f.itemId = itemId
    f.itemQuantity = quantity
    if itemId and util:ItemRender(itemId) then
        f.itemResolved = true
    else
        f.itemResolved = false
        self:PrimeItemInfo(itemId)
        self:EnsureNameTicker()
    end
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
    f.name:SetText(formatRollItemLabel(roll.link, roll.name, roll.quantity))
    self:TrackPopupItem(f, roll.itemId, roll.quantity)
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

    -- count active responses from the core lot (the single source of truth)
    local total = 0
    local lot = self.lootCore:Get(roll.id)
    if lot then
        for _, choice in pairs(lot.responses) do
            if self:IsResponseActive(choice) then total = total + 1 end
        end
    end
    f.count:SetText(total > 0 and (total .. " rolling") or "")
end

function addon:RefreshLiveRollCountForItem(lotId)
    local roll = lotId and self.live and self.live.rolls and self.live.rolls[lotId]
    if roll and not roll.resolved then
        self:RefreshInterestPopup(roll)
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
function addon:ShowPendingPopup(lot, slot)
    if not lot or not lot.id then return end
    local lotId = lot.id
    local name, link, icon = util:ItemRender(lot.itemId)
    name = name or link or ("item:" .. tostring(lot.itemId))
    local quantity = self.lootCore:LiveCount(lotId)

    local f = acquirePopup(self)
    f.mode = "pending"
    f:SetScript("OnUpdate", nil)        -- no countdown until the roll actually starts
    f.timer:Hide()
    f.lotId = lotId

    f.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.itemLink = link
    f.name:SetText(formatRollItemLabel(link, name, quantity))
    self:TrackPopupItem(f, lot.itemId, quantity)
    f.sub:SetText("|cffffffffPrio:|r " .. (self:GetLiveItemPrio({ name = name }) or "BiS > MS > MU > OS > TM"))
    f.count:Hide()

    f.bisBtn:Hide(); f.msBtn:Hide(); f.muBtn:Hide(); f.osBtn:Hide(); f.tmBtn:Hide(); f.passBtn:Hide(); f.okBtn:Hide()

    f.cancelBtn:Show()
    f.cancelBtn:SetWidth(50)
    f.cancelBtn:SetText("Skip")
    f.cancelBtn:SetScript("OnClick", function()
        self.lootCore:Skip(lotId)       -- pending -> skipped; ledgerChanged closes this popup
    end)

    f.rollBtn:Show()
    f.rollBtn:SetWidth(90)
    f.rollBtn:SetText("Start Roll")
    f.rollBtn:SetScript("OnClick", function()
        closePopup(self, f)
        self:StartLiveRoll(lotId)
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
function addon:ShowResultPopup(roll, winners, sections, slot)
    local f = acquirePopup(self)
    f.mode = "result"
    f:SetScript("OnUpdate", nil)        -- no countdown on a result popup
    f.timer:Hide()
    f.icon:SetTexture(roll.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.itemLink = roll.link
    f.name:SetText(formatRollItemLabel(roll.link, roll.name, roll.quantity))
    self:TrackPopupItem(f, roll.itemId, roll.quantity)

    winners = winners or {}
    local myKey = util:NormalizeKey(util:GetPlayerName("player") or "")
    local winnerKeys = {}
    for _, w in ipairs(winners) do winnerKeys[util:NormalizeKey(w)] = true end
    local myRoll, mySection
    for _, s in ipairs(sections or {}) do
        for _, m in ipairs(s.members) do
            if util:NormalizeKey(m.name) == myKey then myRoll = m.roll; mySection = s.label end
        end
    end

    local line
    if #winners == 0 then
        line = "No rollers."
    elseif winnerKeys[myKey] then
        line = string.format("|cff40ff40You won!|r  (your roll %s)", tostring(myRoll or "?"))
    else
        local mine = myRoll and string.format("Your roll %d%s.  ", myRoll, mySection and (" (" .. mySection .. ")") or "") or ""
        line = string.format("|cffff6060You lost.|r  %sWinner%s: %s", mine, (#winners > 1 and "s" or ""), table.concat(winners, ", "))
    end
    f.sub:SetText(line)

    f.bisBtn:Hide(); f.msBtn:Hide(); f.muBtn:Hide(); f.osBtn:Hide(); f.tmBtn:Hide(); f.passBtn:Hide(); f.rollBtn:Hide(); f.cancelBtn:Hide()
    f.count:Hide()
    f.okBtn:Show()
    f.okBtn:SetScript("OnClick", function() closePopup(self, f); compactPopups(self) end)

    -- hover: full breakdown by priority section so a higher roll in a lower section is
    -- clearly explained
    f.sections = sections
    f.winnerKeys = winnerKeys
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
                    local won = selfFrame.winnerKeys and selfFrame.winnerKeys[key]
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

-- Auto-surfacing and pending-popup restoration are now driven by core events
-- (OnLotAdded + SyncPendingPopups). These remain as thin entry points for any callers.
function addon:AutoRollAddedItems()
    self:SyncPendingPopups()
end

function addon:RestorePendingPopups()
    self:SyncPendingPopups()
end

-- Abort an open roll. For raiders the item disappears (CANCEL closes their popup). For
-- the ML the loot is NOT lost: we return to the pre-roll pending state (Start Roll / Skip)
-- in the same slot, so the ML can re-roll or skip it.
function addon:CancelLiveRoll(rollId)
    local roll = self.live.rolls[rollId]
    if not roll then return end
    roll.resolved = true
    self:SendLargeMessage("CANCEL", { rollId }, "RAID", nil, "ALERT")
    self.live.rolls[rollId] = nil

    self:CloseInterestPopup(roll)
    self.lootCore:Cancel(rollId)             -- rolling -> pending; SyncPendingPopups re-shows it
    self:Print("Roll cancelled: " .. (roll.name or "item") .. " (back to pending).")
end

function addon:OnCancelMessage(fields)
    local roll = self.live.rolls[fields[1]]
    if not roll then return end
    self:CloseInterestPopup(roll)
    compactPopups(self)
    self.live.rolls[fields[1]] = nil
end

-- Start a live roll for a lot id. The core lot is the single source of truth; the roll
-- object here is just the popup/wire wrapper, keyed by the SAME id as the lot.
function addon:StartLiveRoll(lotId)
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can put items up for roll.")
        return
    end
    local core = self.lootCore
    local lot = core:Get(lotId)
    if not lot then return end

    local name, link, icon = util:ItemRender(lot.itemId)
    name = name or link or ("item:" .. tostring(lot.itemId))

    if lot.state == core.STATE.RESOLVED then
        self:Print(name .. " was already rolled out. Use Unlock Roll to reroll it.")
        return
    end

    -- move the lot to rolling (surface first if it is still idle/new/skipped)
    if lot.state ~= core.STATE.PENDING then core:Surface(lotId) end
    if not core:StartRoll(lotId) then return end

    local prio = self:GetLiveItemPrio({ name = name })
    local quantity = core:LiveCount(lotId)
    local roll = {
        id = lotId, itemId = lot.itemId, link = link, name = name,
        icon = icon, prio = prio, owner = true, registrants = {}, resolved = false,
        duration = ROLL_DURATION, quantity = quantity,
    }
    self.live.rolls[lotId] = roll

    -- the wire carries the itemId (not a link): every client renders its own localized name
    self:SendLargeMessage("DROP",
        { lotId, tostring(lot.itemId), prio or "", tostring(ROLL_DURATION), tostring(quantity) }, "RAID", nil, "ALERT")
    self:ShowInterestPopup(roll)
    self:Print("Put " .. name .. " up for roll. Press End Roll when ready.")
end

-- ---------------------------------------------------------------------------
-- loot-tab roll buttons (upstream UI) routed through the core. Rolls are keyed by lot id
-- (roll.id == lot.id == item.id), so identity is the lot, never a link, and start/skip go
-- through the core's lifecycle commands rather than the old link-based popup bookkeeping.
-- ---------------------------------------------------------------------------

-- The active (unresolved) live roll for a loot row, by lot id. No link fallback or scan: the
-- roll is stored under the lot id, which is the row's item.id.
function addon:GetActiveLiveRollForItem(item)
    if not item or not item.id then return nil end
    local roll = self.live and self.live.rolls and self.live.rolls[item.id]
    if roll and not roll.resolved then return roll end
    return nil
end

-- Start a roll straight from a loot row. StartLiveRoll surfaces the lot if needed and moves it
-- to rolling; the resulting ledgerChanged drives SyncPendingPopups to close any pending popup,
-- so there is nothing link-keyed to dismiss by hand.
function addon:StartLiveRollFromItem(item)
    if not item or not item.id then return end
    self:StartLiveRoll(item.id)
end

-- Skip a loot row (ML only): move the lot to SKIPPED through the core (Surface first if it is
-- not already pending). SKIPPED is a snooze that resurfaces on the next scan; SyncPendingPopups
-- closes its popup off the ledger change.
function addon:SkipLiveLootItem(item)
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can skip live loot items.")
        return
    end
    if not item or not item.id then return end
    local core = self.lootCore
    local lot = core:Get(item.id)
    if not lot then return end
    if lot.state ~= core.STATE.PENDING then core:Surface(item.id) end
    core:Skip(item.id)
end

function addon:ResolveLiveRoll(rollId)
    local roll = self.live.rolls[rollId]
    if not roll or roll.resolved then return end
    if not self:IsAuthorizedLootMaster() then return end
    roll.resolved = true

    -- Resolve through the core: it hands this lot's responses to ResolveSessionItem (bracket
    -- -> named -> spec -> status -> roll, top-N by count) and freezes the ordered winners onto
    -- per-copy awards. lotResolved fires here -> payout owes; ledgerChanged -> projection + sync.
    local record = self.lootCore:Resolve(rollId) or {}
    local winners = record.winners
    if not winners or #winners == 0 then
        winners = (record.winner and record.winner ~= "No winner") and { record.winner } or {}
    end
    local sections = self:SectionsFromResult(record)
    local winnersText = table.concat(winners, ",")

    -- the wire carries itemId (not a link) and the full winners list (top-N may be > 1)
    self:SendLargeMessage("WIN", {
        rollId, tostring(roll.itemId or 0), winnersText, "roll", "0", self:EncodeSections(sections),
    }, "RAID", nil, "ALERT")
    self:TriggerCallback("RESULTS_UPDATED")

    local slot = roll.popup and roll.popup.slot
    self:CloseInterestPopup(roll)
    self:ShowResultPopup(roll, winners, sections, slot)
    self.live.rolls[rollId] = nil   -- live-roll UI done; the core holds the truth

    if #winners == 0 then
        self:Print((roll.name or "item") .. " -> no rollers.")
    else
        self:Print(string.format("%s -> %s.", roll.name or "item", winnersText))
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
            self:SendLargeMessage("RSP", { rollId, tier }, "WHISPER", lootMaster, "ALERT")
        end
    end
end

function addon:RegisterInterest(rollId, name, tier)
    local roll = self.live.rolls[rollId]
    if not roll or roll.resolved then return end
    roll.registrants[util:NormalizeKey(name)] = { name = name, tier = tier }
    -- Record the pick on the core lot (rollId == lot id). Only the ML owns the lot; the
    -- snapshot sync carries it to raiders. SetPlayerResponse fires SESSION_UPDATED + count.
    if self:IsAuthorizedLootMaster() then
        self:SetPlayerResponse(rollId, name, tier)
    end
    self:RefreshInterestPopup(roll)
end

-- ---------------------------------------------------------------------------
-- incoming comm messages (dispatched from Comm.lua HandleCommMessage)
-- ---------------------------------------------------------------------------
function addon:OnDropMessage(fields)
    -- wire: { lotId, itemId, prio, duration, quantity }. Render display from itemId so each
    -- client shows its OWN localized name/link/icon.
    local itemId = tonumber(fields[2])
    local name, link, icon = util:ItemRender(itemId)
    local roll = {
        id = fields[1],
        itemId = itemId,
        link = link,
        name = name or link or ("item:" .. tostring(itemId)),
        icon = icon,
        prio = fields[3] or "",
        duration = tonumber(fields[4]) or ROLL_DURATION,
        quantity = tonumber(fields[5]) or 1,
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
    -- wire: { lotId, itemId, winnersText, "roll", "0", sectionsText }
    local rollId, itemId, winnersText, sectionsText = fields[1], tonumber(fields[2]), fields[3], fields[6]
    local roll = self.live.rolls[rollId]
    if not roll then
        local name, link, icon = util:ItemRender(itemId)
        roll = { id = rollId, itemId = itemId, link = link, name = name or link, icon = icon }
    end
    roll.resolved = true

    local winners = {}
    for _, w in ipairs(util:Split(winnersText or "", ",")) do
        if w ~= "" then winners[#winners + 1] = w end
    end

    -- Do NOT auto-hide a won item. If the player still has the dialog open, convert it to a
    -- result popup they must OK to dismiss. If they already Passed (popup gone), leave it gone.
    if roll.popup then
        local sections = self:DecodeSections(sectionsText)
        local slot = roll.popup.slot
        self:CloseInterestPopup(roll)
        self:ShowResultPopup(roll, winners, sections, slot)
    end
end
