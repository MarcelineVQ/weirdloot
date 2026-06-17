local addon = WeirdLoot
local util = addon.util

function addon:InitializeResolver()
end

function addon:BuildRollerList(itemId)
    local session = self:GetCurrentSession()
    local rollers = {}
    local responses = session.responses[itemId] or {}

    for playerKey, shouldRoll in pairs(responses) do
        if shouldRoll then
            local attendee = self:GetAttendee(playerKey) or self:GetRosterProfile(playerKey)
            if attendee then
                rollers[#rollers + 1] = {
                    name = attendee.name or playerKey,
                    className = attendee.className or "",
                    specName = attendee.specName or "",
                    status = attendee.status or "nil",
                    descriptor = util:NormalizeKey((attendee.className or "") .. " " .. (attendee.specName or "")),
                }
            else
                rollers[#rollers + 1] = {
                    name = playerKey,
                    className = "",
                    specName = "",
                    status = "nil",
                    descriptor = "",
                }
            end
        end
    end

    util:SortByName(rollers, "name")
    return rollers
end

function addon:FindMatchingTier(rule, candidates, matcher)
    if not rule or not rule.tiers then
        return nil, candidates
    end

    local unmatched = util:CloneTable(candidates)
    for _, tier in ipairs(rule.tiers) do
        local survivors = {}
        local matchedKeys = {}
        local hasRest = false

        for _, entry in ipairs(tier.entries) do
            if entry.isRest then
                hasRest = true
            else
                for _, candidate in ipairs(candidates) do
                    if not matchedKeys[candidate.name] and matcher(entry, candidate) then
                        survivors[#survivors + 1] = candidate
                        matchedKeys[candidate.name] = true
                    end
                end
            end
        end

        if #survivors > 0 then
            return tier, survivors
        end

        if hasRest then
            return tier, unmatched
        end
    end

    return nil, candidates
end

function addon:FilterByStatus(candidates)
    local highestRank = 0
    local survivors = {}

    for _, candidate in ipairs(candidates) do
        highestRank = math.max(highestRank, util:StatusRank(candidate.status))
    end

    for _, candidate in ipairs(candidates) do
        if util:StatusRank(candidate.status) == highestRank then
            survivors[#survivors + 1] = candidate
        end
    end

    return survivors, highestRank
end

function addon:RollCandidates(candidates)
    local rolls = {}
    for _, candidate in ipairs(candidates) do
        rolls[#rolls + 1] = {
            name = candidate.name,
            roll = math.random(1, 100),
            auto = false,
        }
    end

    table.sort(rolls, function(left, right)
        if left.roll == right.roll then
            return string.lower(left.name) < string.lower(right.name)
        end
        return left.roll > right.roll
    end)

    return rolls
end

local function sortRollsDescending(rolls)
    table.sort(rolls, function(left, right)
        if left.roll == right.roll then
            return string.lower(left.name) < string.lower(right.name)
        end
        return left.roll > right.roll
    end)
end

local function formatCandidateSummary(candidate)
    local nameText = (util:GetClassColorCode(candidate.className) or "|cffffffff") .. (candidate.name or "Unknown") .. "|r"
    local parts = {
        nameText,
        util:TitleCaseWords(string.trim((candidate.className or "") .. " " .. (candidate.specName or ""))),
        util:PlayerDisplayStatus(candidate.status),
    }

    return table.concat(parts, " - ")
end

function addon:IsCandidateNamedForItem(namedRule, candidateName)
    if not namedRule or not namedRule.tiers then
        return false
    end

    local candidateKey = util:NormalizeKey(candidateName or "")
    for _, tier in ipairs(namedRule.tiers) do
        for _, entry in ipairs(tier.entries or {}) do
            if not entry.isRest and entry.playerKey == candidateKey then
                return true
            end
        end
    end

    return false
end

function addon:FindMatchingNamedTier(rule, candidates)
    if not rule or not rule.tiers then
        return nil, candidates, false
    end

    for _, tier in ipairs(rule.tiers) do
        local survivors = {}
        local matchedKeys = {}
        local hasLootCouncil = false

        for _, entry in ipairs(tier.entries or {}) do
            if entry.isLootCouncil then
                hasLootCouncil = true
            elseif not entry.isRest then
                for _, candidate in ipairs(candidates or {}) do
                    local candidateKey = util:NormalizeKey(candidate.name)
                    if not matchedKeys[candidateKey] and entry.playerKey == candidateKey then
                        survivors[#survivors + 1] = candidate
                        matchedKeys[candidateKey] = true
                    end
                end
            end
        end

        if #survivors > 0 then
            return tier, survivors, false
        end

        if hasLootCouncil then
            return tier, candidates, true
        end
    end

    return nil, candidates, false
end

local function formatPlainCandidateNames(candidates)
    local names = {}
    for _, candidate in ipairs(candidates or {}) do
        if candidate.name and candidate.name ~= "" then
            names[#names + 1] = candidate.name
        end
    end

    if #names == 0 then
        return "none"
    end

    return table.concat(names, ", ")
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
                    formattedEntries[#formattedEntries + 1] = util:TitleCaseWords(string.trim(entryText))
                end
                tiers[#tiers + 1] = table.concat(formattedEntries, " / ")
            else
                tiers[#tiers + 1] = util:TitleCaseWords(tierText)
            end
        end
    end

    if #tiers == 0 then
        return "none"
    end

    return table.concat(tiers, "\n---\n")
end

function addon:RuleHasLootCouncil(rule)
    if not rule or not rule.tiers then
        return false
    end

    for _, tier in ipairs(rule.tiers) do
        for _, entry in ipairs(tier.entries or {}) do
            if entry.isLootCouncil then
                return true
            end
        end
    end

    return false
end

function addon:BuildResultDetail(result)
    local lines = {}
    local quantityText = (result.quantity or 1) > 1 and string.format(" x%d", result.quantity or 1) or ""
    lines[#lines + 1] = "Item: " .. (result.itemName or "") .. quantityText
    lines[#lines + 1] = ""
    lines[#lines + 1] = "All Rollers -"
    if #(result.allRollerDetails or {}) == 0 then
        lines[#lines + 1] = "none"
    else
        for _, roller in ipairs(result.allRollerDetails or {}) do
            local rollText = roller.rollText and (" - (" .. roller.rollText .. ")") or ""
            lines[#lines + 1] = formatCandidateSummary(roller) .. rollText
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "LC Names:"
    lines[#lines + 1] = ((result.lcNamesText and result.lcNamesText ~= "") and result.lcNamesText or "none")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Spec Priority:"
    lines[#lines + 1] = formatSpecPriorityDisplay(result.specPriorityText)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Prioritized Rolls:"
    if #(result.rollDetails or {}) == 0 then
        lines[#lines + 1] = "none"
    else
        for _, roll in ipairs(result.rollDetails or {}) do
            local rollValue = roll.auto and "AUTO" or tostring(roll.roll or "")
            local namedText = roll.isNamed and " - Named" or ""
            lines[#lines + 1] = string.format("%s - (%s)%s", formatCandidateSummary(roll), rollValue, namedText)
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
            local winnerName = (util:GetClassColorCode(winner.className) or "|cffffffff") .. (winner.name or "Unknown") .. "|r"
            lines[#lines + 1] = string.format("%s (%s)", winnerName, rollValue)
        end
    end
    return table.concat(lines, "\n")
end

function addon:SelectWinningRolls(rolls, quantity)
    local winnerCount = 1
    if (quantity or 1) >= 2 then
        winnerCount = math.min(2, #rolls)
    end

    local winners = {}
    for index = 1, winnerCount do
        if rolls[index] then
            winners[#winners + 1] = rolls[index].name
        end
    end

    return winners
end

function addon:CollectPriorityWinnerCandidates(rule, candidates, matcher, quantity, allRollByName)
    local orderedCandidates = {}
    local chosen = {}
    local maxCount = quantity or 1

    local function appendSortedCandidates(tierCandidates)
        local statusSurvivors = self:FilterByStatus(tierCandidates)
        table.sort(statusSurvivors, function(left, right)
            local leftRoll = allRollByName[util:NormalizeKey(left.name)] and allRollByName[util:NormalizeKey(left.name)].roll or 0
            local rightRoll = allRollByName[util:NormalizeKey(right.name)] and allRollByName[util:NormalizeKey(right.name)].roll or 0
            if leftRoll == rightRoll then
                return string.lower(left.name or "") < string.lower(right.name or "")
            end
            return leftRoll > rightRoll
        end)

        for _, candidate in ipairs(statusSurvivors) do
            local candidateKey = util:NormalizeKey(candidate.name)
            if not chosen[candidateKey] then
                orderedCandidates[#orderedCandidates + 1] = candidate
                chosen[candidateKey] = true
                if #orderedCandidates >= maxCount then
                    return true
                end
            end
        end

        return false
    end

    for _, tier in ipairs(rule and rule.tiers or {}) do
        local tierCandidates = {}
        local hasRest = false

        for _, entry in ipairs(tier.entries or {}) do
            if entry.isRest then
                hasRest = true
            else
                for _, candidate in ipairs(candidates or {}) do
                    local candidateKey = util:NormalizeKey(candidate.name)
                    if not chosen[candidateKey] and matcher(entry, candidate) then
                        tierCandidates[#tierCandidates + 1] = candidate
                    end
                end
            end
        end

        if #tierCandidates == 0 and hasRest then
            for _, candidate in ipairs(candidates or {}) do
                local candidateKey = util:NormalizeKey(candidate.name)
                if not chosen[candidateKey] then
                    tierCandidates[#tierCandidates + 1] = candidate
                end
            end
        end

        if #tierCandidates > 0 and appendSortedCandidates(tierCandidates) then
            break
        end
    end

    return orderedCandidates
end

function addon:BuildResultRecord(item, allRollerNames, allRollerDetails, lcNamesText, specPriorityText, statusRank, prioritizedNames, rolls, rollDetails, winnerDetails)
    local winners = {}
    for _, winner in ipairs(winnerDetails or {}) do
        winners[#winners + 1] = winner.name
    end
    if #winners == 0 then
        winners = self:SelectWinningRolls(rolls, item.quantity or 1)
    end
    local winnersText = #winners > 0 and table.concat(winners, ", ") or "No winner"
    local result = {
        itemId = item.id,
        itemName = item.name,
        itemLink = item.link,
        itemIcon = item.icon,
        quantity = item.quantity or 1,
        allRollers = allRollerNames,
        allRollerDetails = allRollerDetails or {},
        lcNamesText = lcNamesText,
        specPriorityText = specPriorityText,
        statusTierText = statusRank == 3 and "Main" or (statusRank == 2 and "Designated Alt" or "Nil"),
        prioritizedNames = prioritizedNames,
        finalRolls = rolls,
        rollDetails = rollDetails or {},
        winnerDetails = winnerDetails or {},
        winners = winners,
        winnersText = winnersText,
        winner = winners[1] or "No winner",
        locked = true,
    }

    if (item.quantity or 1) >= 2 then
        result.summary = string.format("%s x%d -> %s", item.name or "Item", item.quantity or 1, winnersText)
    else
        result.summary = string.format("%s -> %s", item.name or "Item", winnersText)
    end
    result.detailText = self:BuildResultDetail(result)
    return result
end

function addon:BuildLootCouncilResultRecord(item, allRollerNames, allRollerDetails, lcNamesText, specPriorityText, statusRank, prioritizedNames)
    local result = {
        itemId = item.id,
        itemName = item.name,
        itemLink = item.link,
        itemIcon = item.icon,
        quantity = item.quantity or 1,
        allRollers = allRollerNames,
        allRollerDetails = allRollerDetails or {},
        lcNamesText = lcNamesText,
        specPriorityText = specPriorityText,
        statusTierText = statusRank == 3 and "Main" or (statusRank == 2 and "Designated Alt" or "Nil"),
        prioritizedNames = prioritizedNames or {},
        finalRolls = {},
        rollDetails = {},
        winnerDetails = {},
        winners = {},
        winnersText = "Loot Council",
        winner = "No winner",
        locked = true,
        isLootCouncil = true,
    }

    if (item.quantity or 1) >= 2 then
        result.summary = string.format("%s x%d -> Loot Council", item.name or "Item", item.quantity or 1)
    else
        result.summary = string.format("%s -> Loot Council", item.name or "Item")
    end
    result.detailText = self:BuildResultDetail(result)
    return result
end

function addon:ProcessLoot()
    if not self:IsAuthorizedLootMaster() then
        self:Print("Only the loot master can process loot.")
        return
    end

    local session = self:GetCurrentSession()
    session.lockedItems = session.lockedItems or {}
    local results = {}
    local hadUnlockedItems = false
    local existingResultsByItemId = {}

    for _, existingResult in ipairs(session.results or {}) do
        existingResultsByItemId[existingResult.itemId] = existingResult
    end

    for _, item in ipairs(session.items or {}) do
        if self:IsItemLocked(item.id) then
            if existingResultsByItemId[item.id] then
                results[#results + 1] = existingResultsByItemId[item.id]
            end
        else
            hadUnlockedItems = true
        local rollers = self:BuildRollerList(item.id)
        local allRollerNames = {}
        local allRollerDetails = {}
        for _, roller in ipairs(rollers) do
            allRollerNames[#allRollerNames + 1] = roller.name
            allRollerDetails[#allRollerDetails + 1] = {
                name = roller.name,
                className = roller.className,
                specName = roller.specName,
                status = roller.status,
            }
        end

        local allRolls = self:RollCandidates(rollers)
        local allRollByName = {}
        for _, roll in ipairs(allRolls) do
            allRollByName[util:NormalizeKey(roll.name)] = roll
        end
        for _, detail in ipairs(allRollerDetails) do
            local matchedRoll = allRollByName[util:NormalizeKey(detail.name)]
            detail.rollText = matchedRoll and (matchedRoll.auto and "AUTO" or tostring(matchedRoll.roll)) or nil
        end

        local namedRule = self:GetNamedRule(item.name)
        local lootRule = self:GetLootRule(item.name)
        local defaultSpecPriorityText = lootRule and lootRule.raw or (self:RuleHasLootCouncil(namedRule) and "LC" or nil)

        local namedTier, prioritized, isLootCouncil = self:FindMatchingNamedTier(namedRule, rollers)

        if isLootCouncil then
            local councilCandidates = prioritized
            local prioritizedNames = {}
            local rank = 0
            local displaySpecPriorityText = defaultSpecPriorityText or "LC"

            if lootRule then
                local lootTier
                lootTier, councilCandidates = self:FindMatchingTier(lootRule, councilCandidates, function(entry, candidate)
                    local keyA = util:NormalizeKey((candidate.className or "") .. " " .. (candidate.specName or ""))
                    local keyB = util:NormalizeKey((candidate.specName or "") .. " " .. (candidate.className or ""))
                    for _, key in ipairs(entry.matchKeys or {}) do
                        if key ~= "" and (key == keyA or key == keyB) then
                            return true
                        end
                    end
                    return false
                end)
            end

            councilCandidates, rank = self:FilterByStatus(councilCandidates)
            for _, player in ipairs(councilCandidates) do
                prioritizedNames[#prioritizedNames + 1] = player.name
            end

            results[#results + 1] = self:BuildLootCouncilResultRecord(
                item,
                allRollerNames,
                allRollerDetails,
                formatPlainCandidateNames(councilCandidates),
                displaySpecPriorityText,
                rank,
                prioritizedNames
            )
        elseif not namedTier and lootRule then
            local lootTier
            lootTier, prioritized = self:FindMatchingTier(lootRule, prioritized, function(entry, candidate)
                local keyA = util:NormalizeKey((candidate.className or "") .. " " .. (candidate.specName or ""))
                local keyB = util:NormalizeKey((candidate.specName or "") .. " " .. (candidate.className or ""))
                for _, key in ipairs(entry.matchKeys or {}) do
                    if key ~= "" and (key == keyA or key == keyB) then
                        return true
                    end
                end
                return false
            end)

            local statusSurvivors, rank = self:FilterByStatus(prioritized)
            local rolls = {}
            local prioritizedNames = {}
            local rollDetails = {}
            local survivorByName = {}
            for _, player in ipairs(statusSurvivors) do
                prioritizedNames[#prioritizedNames + 1] = player.name
                survivorByName[util:NormalizeKey(player.name)] = player
                local matchedRoll = allRollByName[util:NormalizeKey(player.name)]
                if matchedRoll then
                    rolls[#rolls + 1] = {
                        name = matchedRoll.name,
                        roll = matchedRoll.roll,
                        auto = matchedRoll.auto,
                    }
                end
            end
            sortRollsDescending(rolls)
            for _, roller in ipairs(statusSurvivors) do
                local matchedRoll = allRollByName[util:NormalizeKey(roller.name)]
                rollDetails[#rollDetails + 1] = {
                    name = roller.name,
                    className = roller.className,
                    specName = roller.specName,
                    status = roller.status,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                    isNamed = self:IsCandidateNamedForItem(namedRule, roller.name),
                }
            end
            local winnerDetails = {}
            local winnerCandidates = self:CollectPriorityWinnerCandidates(lootRule, rollers, function(entry, candidate)
                local keyA = util:NormalizeKey((candidate.className or "") .. " " .. (candidate.specName or ""))
                local keyB = util:NormalizeKey((candidate.specName or "") .. " " .. (candidate.className or ""))
                for _, key in ipairs(entry.matchKeys or {}) do
                    if key ~= "" and (key == keyA or key == keyB) then
                        return true
                    end
                end
                return false
            end, item.quantity or 1, allRollByName)
            for _, winnerCandidate in ipairs(winnerCandidates) do
                local winnerName = winnerCandidate.name
                local matchedRoll = allRollByName[util:NormalizeKey(winnerName)]
                winnerDetails[#winnerDetails + 1] = {
                    name = winnerName,
                    className = winnerCandidate.className,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                }
            end

            results[#results + 1] = self:BuildResultRecord(
                item,
                allRollerNames,
                allRollerDetails,
                namedTier and namedTier.raw or nil,
                defaultSpecPriorityText,
                rank,
                prioritizedNames,
                rolls,
                rollDetails,
                winnerDetails
            )
        else
            local statusSurvivors, rank = self:FilterByStatus(prioritized)
            local rolls = {}
            local prioritizedNames = {}
            local rollDetails = {}
            local survivorByName = {}
            for _, player in ipairs(statusSurvivors) do
                prioritizedNames[#prioritizedNames + 1] = player.name
                survivorByName[util:NormalizeKey(player.name)] = player
                local matchedRoll = allRollByName[util:NormalizeKey(player.name)]
                if matchedRoll then
                    rolls[#rolls + 1] = {
                        name = matchedRoll.name,
                        roll = matchedRoll.roll,
                        auto = matchedRoll.auto,
                    }
                end
            end
            sortRollsDescending(rolls)
            for _, roller in ipairs(statusSurvivors) do
                local matchedRoll = allRollByName[util:NormalizeKey(roller.name)]
                rollDetails[#rollDetails + 1] = {
                    name = roller.name,
                    className = roller.className,
                    specName = roller.specName,
                    status = roller.status,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                    isNamed = self:IsCandidateNamedForItem(namedRule, roller.name),
                }
            end
            local winnerDetails = {}
            local winnerCandidates
            if namedTier and namedRule then
                winnerCandidates = self:CollectPriorityWinnerCandidates(namedRule, rollers, function(entry, candidate)
                    return entry.playerKey == util:NormalizeKey(candidate.name)
                end, item.quantity or 1, allRollByName)
            else
                winnerCandidates = {}
                for _, winnerName in ipairs(self:SelectWinningRolls(rolls, item.quantity or 1)) do
                    local winnerCandidate = survivorByName[util:NormalizeKey(winnerName)]
                    if winnerCandidate then
                        winnerCandidates[#winnerCandidates + 1] = winnerCandidate
                    end
                end
            end
            for _, winnerCandidate in ipairs(winnerCandidates) do
                local winnerName = winnerCandidate.name
                local matchedRoll = allRollByName[util:NormalizeKey(winnerName)]
                winnerDetails[#winnerDetails + 1] = {
                    name = winnerName,
                    className = winnerCandidate.className,
                    roll = matchedRoll and matchedRoll.roll or nil,
                    auto = matchedRoll and matchedRoll.auto or false,
                }
            end

            results[#results + 1] = self:BuildResultRecord(
                item,
                allRollerNames,
                allRollerDetails,
                namedTier and namedTier.raw or nil,
                defaultSpecPriorityText,
                rank,
                prioritizedNames,
                rolls,
                rollDetails,
                winnerDetails
            )
        end

            self:LockItem(item.id)
        end
    end

    if not hadUnlockedItems then
        self:Print("All session loot is already locked. Unlock a result to reroll it.")
        return
    end

    session.results = results
    self.sessionDb.history = self.sessionDb.history or {}
    self.sessionDb.history[#self.sessionDb.history + 1] = {
        sessionId = session.id,
        timestamp = time(),
        results = util:CloneTable(results),
    }

    if #results > 0 then
        SendChatMessage("Loot has been rolled on, check the Results tab.", "RAID_WARNING")
    end

    self:BroadcastResults(results)
    self:BroadcastSessionLocks()
    self:TriggerCallback("RESULTS_UPDATED")
    self:Print("Loot processed.")
end
