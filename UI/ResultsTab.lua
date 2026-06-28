-- WeirdLoot Results tab: resolved-loot list with sort, the per-result detail panel, and the
-- target/trade/fill action buttons. Pure presentation; pulls shared widgets from addon.UI.
local addon = WeirdLoot
local util = addon.util
local UI = addon.UI
local createLabel = UI.createLabel
local createButton = UI.createButton
local createScrollList = UI.createScrollList
local createBackdropFrame = UI.createBackdropFrame
local elevateInteractiveFrame = UI.elevateInteractiveFrame

function addon:BuildResultsTab()
    local panel = CreateFrame("Frame", nil, self.ui.content)
    elevateInteractiveFrame(panel, self.ui.content, 2)
    panel:SetAllPoints(self.ui.content)
    self.ui.panels.results = panel

    -- Clickable column headers above the list. Each click sets the sort mode and re-refreshes; same
    -- pattern as the Loot tab's headers. Widths match the row columns below (icon+name = 290,
    -- winner = 170) so the labels sit over the data they sort.
    local nameHeader = createButton(panel, "Item Name", 290, 18)
    nameHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
    nameHeader:SetScript("OnClick", function() addon:SetResultsSortMode("name") end)
    nameHeader.baseLabel = "Item Name"
    self.ui.resultsNameHeader = nameHeader

    local winnerHeader = createButton(panel, "Who Won", 170, 18)
    winnerHeader:SetPoint("LEFT", nameHeader, "RIGHT", 12, 0)
    winnerHeader:SetScript("OnClick", function() addon:SetResultsSortMode("winner") end)
    winnerHeader.baseLabel = "Who Won"
    self.ui.resultsWinnerHeader = winnerHeader

    -- 21 rows fills the full-height list (content is ~532px; 24px row pitch) instead of leaving the
    -- lower third of the panel as empty backdrop.
    local list = createScrollList(panel, "WeirdLootResultsList", 21, function(row)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- Tinted when the local player is among the winners (set in RefreshResultsTab). Behind the
        -- content so the item link / "You" text read on top.
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints(row)
        row.bg:SetTexture(0, 0, 0, 0)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(18)
        row.icon:SetHeight(18)
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)

        -- icon(18) + name(264) + winner(170) + gaps fit inside the 520 list minus the scrollbar
        -- gutter, so neither column runs under the bar.
        row.name = createLabel(row, "", "LEFT", row.icon, "RIGHT", 8, 0)
        row.name:SetWidth(264)
        row.winner = createLabel(row, "", "LEFT", row.name, "RIGHT", 12, 0)
        row.winner:SetWidth(170)

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
    list:SetPoint("TOPLEFT", nameHeader, "BOTTOMLEFT", -4, -4)
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

-- Header click is tri-state: first click on a column sorts it ascending, second flips to
-- descending, third turns sorting off (back to the resolution-time default). Clicking a
-- different column starts that column fresh at ascending.
function addon:SetResultsSortMode(mode)
    local ui = self.db.ui
    if ui.resultsSortMode ~= mode then
        ui.resultsSortMode = mode
        ui.resultsSortDir = "asc"
    elseif ui.resultsSortDir ~= "desc" then
        ui.resultsSortDir = "desc"
    else
        ui.resultsSortMode = "default"
        ui.resultsSortDir = "asc"
    end
    self:RefreshResultsTab()
end

-- Return a shallow copy of lootView.results sorted by the active mode (default is resolution
-- time). Stable on ties: the comparator falls back to the original index (mint order) so two
-- items with the same key keep a deterministic order. Never mutates lootView.results itself.
function addon:GetSortedResults()
    local out = {}
    for i, r in ipairs(self.lootView.results or {}) do
        out[#out + 1] = { _idx = i, r = r }
    end
    local mode = (self.db.ui and self.db.ui.resultsSortMode) or "default"
    local asc = not (self.db.ui and self.db.ui.resultsSortDir == "desc")
    local function winnerNameOf(r)
        if r.winners and r.winners[1] then return r.winners[1] end
        return r.winnersText or r.winner or ""
    end
    local function isNoWinnerResult(r)
        local winner = string.lower(string.trim(winnerNameOf(r) or ""))
        return winner == "" or winner == "no winner"
    end
    if mode == "name" then
        table.sort(out, function(a, b)
            local an = string.lower(a.r.itemName or "")
            local bn = string.lower(b.r.itemName or "")
            if an == bn then return a._idx < b._idx end   -- ties stay in mint order regardless of dir
            if asc then return an < bn else return an > bn end
        end)
    elseif mode == "winner" then
        table.sort(out, function(a, b)
            local aNoWinner = isNoWinnerResult(a.r)
            local bNoWinner = isNoWinnerResult(b.r)
            if aNoWinner ~= bNoWinner then
                return not aNoWinner
            end
            local aw = string.lower(winnerNameOf(a.r))
            local bw = string.lower(winnerNameOf(b.r))
            if aw == bw then return a._idx < b._idx end
            if asc then return aw < bw else return aw > bw end
        end)
    else
        -- default: resolution time, newest first. resolvedAt is second-granularity, so same-second
        -- resolves (e.g. a batch) fall back to reverse mint order via _idx (later-minted on top).
        -- Records mirrored from an older ML lack resolvedAt and collapse to that mint ordering.
        table.sort(out, function(a, b)
            local at = a.r.resolvedAt or 0
            local bt = b.r.resolvedAt or 0
            if at == bt then return a._idx > b._idx end
            return at > bt
        end)
    end
    local flat = {}
    for _, w in ipairs(out) do flat[#flat + 1] = w.r end
    return flat
end

-- Show which column is sorting and which way: "^" ascending, "v" descending, nothing when off.
function addon:UpdateResultsHeaderLabels()
    local mode = (self.db.ui and self.db.ui.resultsSortMode) or "default"
    local arrow = (self.db.ui and self.db.ui.resultsSortDir == "desc") and " v" or " ^"
    local nameH, winnerH = self.ui.resultsNameHeader, self.ui.resultsWinnerHeader
    if nameH then nameH:SetText(nameH.baseLabel .. (mode == "name" and arrow or "")) end
    if winnerH then winnerH:SetText(winnerH.baseLabel .. (mode == "winner" and arrow or "")) end
end

function addon:RefreshResultsTab()
    self:UpdateResultsHeaderLabels()
    local results = self:GetSortedResults()
    -- Cold cache: a result resolved before its item data arrived baked the "item:<id>" fallback into
    -- the record. Heal each in place (and prime + flag the resolve ticker for any still cold) so the
    -- Results surfaces show the real name, the same way RefreshLootTab warms the Loot tab.
    for _, result in ipairs(results) do self:RehydrateResult(result) end
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
        -- Tint the row when YOU won a copy: an indigo-teal that bridges the epic-purple item link and
        -- the aqua "You" without washing either out.
        local iWon = false
        for _, winnerName in ipairs(result.winners or {}) do
            if util:IsSelfName(winnerName) then iWon = true break end
        end
        if iWon then
            row.bg:SetTexture(0.04, 0.12, 0.17, 0.42)
        else
            row.bg:SetTexture(0, 0, 0, 0)
        end
        if result.winners and #result.winners > 0 and result.winnerDetails and #result.winnerDetails > 0 then
            local winnerParts = {}
            for winnerIndex, winnerName in ipairs(result.winners) do
                local detail = result.winnerDetails[winnerIndex] or {}
                winnerParts[#winnerParts + 1] = util:ColorPlayerName(winnerName, detail.className)
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

    -- arm the shared resolve ticker if any result name was still cold; it re-renders this tab as the
    -- client caches them, then self-stops (same machinery the Loot tab and roll popups use).
    if self._lootNamesPending then self:EnsureNameTicker() end
end
