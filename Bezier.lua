-- Bezier Addon
-- Tracks achievements earned for the first time by party/raid members

local BZ = {}
Bezier = BZ

-- Constants
local DEFAULT_PREFIX = "Bezier this season"

-- Addon event frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_ACHIEVEMENT")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")

-- Group scanning variables
BZ.groupScanInProgress = false
BZ.currentScanAchievementID = nil
BZ.scanCounter = 0

BZ.scanResults = {} -- Scan results and cache: [achievementID] = {completed={}, notCompleted={}, timestamp=time, zone=zone}
BZ.currentZone = nil -- Track current zone to detect instance changes
BZ.periodicScanTimer = nil -- Timer for periodic scanning
BZ.scanStartTime = nil -- Track scan timing

-- Default database structure
local defaultDB = {
    achievements = {
        [41298] = 0, -- Ahead of the Curve: Chrome King Gallywix
    }, -- [achievementID] = count (simple counter)
    settings = {
        enableDebugLogging = false,
        activeAchievementID = 41298, -- Ahead of the Curve: Chrome King Gallywix
        displayFrame = {
            x = 100,
            y = -100,
            visible = true,
            displayPrefix = DEFAULT_PREFIX, -- Customizable prefix for display
            fontSize = 12, -- Font size for display frame
            enabled = true, -- Whether to show the display frame at all
        }
    }
}

-- Initialize addon
function BZ:OnAddonLoaded()
    -- Initialize saved variables
    if not BezierDB then
        BezierDB = {}
    end

    -- Merge with defaults (deep merge)
    local function deepMerge(target, source)
        for key, value in pairs(source) do
            if target[key] == nil then
                target[key] = value
            elseif type(value) == "table" and type(target[key]) == "table" then
                deepMerge(target[key], value)
            end
        end
    end

    deepMerge(BezierDB, defaultDB)

    BZ.db = BezierDB

    BZ.debugLog("|cff00ff00Bezier|r loaded. Open Interface Options > AddOns > Bezier to configure.")

    -- Create settings panel
    BZ:CreateSettingsPanel()

    -- Create display frame
    BZ:CreateDisplayFrame()
end

-- Debug logging function
function BZ.debugLog(message)
    if BZ.db and BZ.db.settings and BZ.db.settings.enableDebugLogging then
        print(message)
    end
end

-- Parse achievement message from chat
function BZ:ParseAchievementMessage(message, sender)
    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Parsing: '%s' from %s", message or "nil", sender or "nil"))

    -- Pattern for achievement messages
    local achievementID = string.match(message, "|Hachievement:(%d+):")
    if achievementID then
        achievementID = tonumber(achievementID)
        local achievementName = select(2, GetAchievementInfo(achievementID))

        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Found achievement: ID=%d, Name=%s", achievementID, achievementName or "Unknown"))

        return sender, achievementID, achievementName
    end

    return nil, nil, nil
end

-- Check if we should track this achievement
function BZ:ShouldTrackAchievement(achievementID)
    -- Always track the active achievement
    if achievementID == BZ.db.settings.activeAchievementID then
        return true
    end

    -- Also track any achievement that's already in our database (previously tracked)
    return BZ.db.achievements[achievementID] ~= nil
end

-- Record an achievement for a player
function BZ:RecordAchievement(playerName, achievementID, achievementName)
    -- Check if we should track this achievement
    if not BZ:ShouldTrackAchievement(achievementID) then
        return
    end

    -- Check if this player was in our notCompleted list (players we know for certain didn't have the achievement)
    local shouldCount = false
    if BZ.scanResults[achievementID] and BZ.scanResults[achievementID].notCompleted then
        for _, notCompletedPlayer in ipairs(BZ.scanResults[achievementID].notCompleted) do
            if notCompletedPlayer == playerName then
                shouldCount = true
                break
            end
        end
    end

    if not shouldCount then
        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Not counting achievement for %s: not in notCompleted list (either already had it or status was unknown)", playerName))
        return
    end

    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Counting achievement for %s: confirmed they didn't have it before", playerName))

    -- Initialize counter if it doesn't exist
    if not BZ.db.achievements[achievementID] then
        BZ.db.achievements[achievementID] = 0
    end

    -- Increment the counter
    BZ.db.achievements[achievementID] = BZ.db.achievements[achievementID] + 1

    -- Debug output
    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Recorded first-time achievement for %s: [%d] %s (Total: %d)",
              playerName, achievementID, achievementName, BZ.db.achievements[achievementID]))

    -- Update scan results to reflect that this player now has the achievement
    if BZ.scanResults[achievementID] then
        local results = BZ.scanResults[achievementID]

        -- Remove player from notCompleted list if they're there
        for i, notCompletedPlayer in ipairs(results.notCompleted) do
            if notCompletedPlayer == playerName then
                table.remove(results.notCompleted, i)
                break
            end
        end

        -- Add to completed list if not already there
        local alreadyInCompleted = false
        for _, completedPlayer in ipairs(results.completed) do
            if completedPlayer == playerName then
                alreadyInCompleted = true
                break
            end
        end

        if not alreadyInCompleted then
            table.insert(results.completed, playerName)
        end
    end

    -- Update display frame if this is the active achievement
    if BZ.db.settings.activeAchievementID == achievementID then
        BZ:UpdateDisplayFrame()
    end
end

-- Event handler
function BZ:OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "Bezier" then
            BZ:OnAddonLoaded()
        end
    elseif event == "CHAT_MSG_ACHIEVEMENT" then
        local message, sender = ...
        local playerName, achievementID, achievementName = BZ:ParseAchievementMessage(message, sender)

        if playerName and achievementID and achievementName then
            BZ:RecordAchievement(playerName, achievementID, achievementName)
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Group composition changed, start/stop periodic scanning
        BZ.debugLog("|cff00ff00[BZ Debug]|r Group roster updated")

        -- Start or stop periodic scanning based on group status
        if BZ:GetGroupSize() > 1 and BZ.db.settings.activeAchievementID then
            BZ:StartPeriodicScanning()
        else
            BZ:StopPeriodicScanning()
        end

        -- Update display frame to show/hide scan button
        BZ:UpdateDisplayFrame()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Player entered world, check if we changed zones and clear cache if needed
        local newZone = GetZoneText()
        if BZ.currentZone and BZ.currentZone ~= newZone then
            BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Zone changed from '%s' to '%s', clearing scan results", BZ.currentZone, newZone))
            BZ:ClearScanResults()
        end
        BZ.currentZone = newZone

        BZ.debugLog("|cff00ff00[BZ Debug]|r Player entering world")
    elseif event == "PLAYER_LEAVING_WORLD" then
        -- Stop periodic scanning when leaving world
        BZ:StopPeriodicScanning()
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    BZ:OnEvent(event, ...)
end)

-- Get current group size
function BZ:GetGroupSize()
    local size = GetNumGroupMembers()
    if size == 0 then
        return 1 -- Solo player
    else
        return size
    end
end

-- Get group type for chat messages
function BZ:GetGroupType()
    if IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    else
        return "SAY"
    end
end

-- Get list of players in current group
function BZ:GetPlayersInGroup()
    local players = {}
    local groupSize = BZ:GetGroupSize()

    if groupSize > 1 then
        local groupType = BZ:GetGroupType()

        for i = 1, groupSize do
            local unit
            if groupType == "PARTY" then
                if i < groupSize then
                    unit = "party" .. i
                else
                    unit = "player"
                end
            elseif groupType == "RAID" then
                unit = "raid" .. i
            end

            if unit then
                local name = UnitName(unit)
                if name and name ~= "Unknown" then
                    -- Remove realm suffix if present
                    local playerName = string.match(name, "([^-]+)")
                    table.insert(players, playerName)
                end
            end
        end
    else
        -- Solo player
        local name = UnitName("player")
        if name then
            table.insert(players, name)
        end
    end

    return players
end

-- Check if a player has a specific achievement
-- Returns: "completed", "not_completed", or "unknown"
function BZ:PlayerHasAchievement(playerName, achievementID)
    if not achievementID then
        return "unknown"
    end

    -- Check scan results cache first (only for definitive results)
    if BZ.scanResults[achievementID] then
        local results = BZ.scanResults[achievementID]
        -- Check if player is in completed or notCompleted lists (definitive results only)
        for _, completedPlayer in ipairs(results.completed or {}) do
            if completedPlayer == playerName then
                BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Using cached result for %s: completed", playerName))
                return "completed"
            end
        end
        for _, notCompletedPlayer in ipairs(results.notCompleted or {}) do
            if notCompletedPlayer == playerName then
                BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Using cached result for %s: not_completed", playerName))
                return "not_completed"
            end
        end
        -- If not in either list, we need to scan this player
    end

    -- Find the unit for this player
    local unit = nil
    local groupSize = BZ:GetGroupSize()

    if groupSize > 1 then
        local groupType = BZ:GetGroupType()

        for i = 1, groupSize do
            local checkUnit
            if groupType == "PARTY" then
                if i < groupSize then
                    checkUnit = "party" .. i
                else
                    checkUnit = "player"
                end
            elseif groupType == "RAID" then
                checkUnit = "raid" .. i
            end

            if checkUnit then
                local name = UnitName(checkUnit)
                if name then
                    local checkPlayerName = string.match(name, "([^-]+)")
                    if checkPlayerName == playerName then
                        unit = checkUnit
                        break
                    end
                end
            end
        end
    else
        -- Solo player
        local name = UnitName("player")
        if name then
            local checkPlayerName = string.match(name, "([^-]+)")
            if checkPlayerName == playerName then
                unit = "player"
            end
        end
    end

    if not unit then
        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Could not find unit for player: %s", playerName))
        return "unknown"
    end

    -- Check if we can inspect this unit's achievements
    if unit == "player" then
        -- Check our own achievements
        local _, _, _, completed = GetAchievementInfo(achievementID)
        local result = completed and "completed" or "not_completed"

        -- Cache the result in scanResults
        if not BZ.scanResults[achievementID] then
            BZ.scanResults[achievementID] = {
                completed = {},
                notCompleted = {},
                timestamp = GetTime(),
                zone = GetZoneText()
            }
        end

        if result == "completed" then
            table.insert(BZ.scanResults[achievementID].completed, playerName)
        else
            table.insert(BZ.scanResults[achievementID].notCompleted, playerName)
        end

        return result
    else
        -- For other players, try to inspect their achievements
        -- This requires the player to be inspectable and may not always work
        if UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit) then
            -- Set up achievement comparison for this unit
            SetAchievementComparisonUnit(unit)

            -- Check if the achievement is completed for the comparison unit
            local _, _, _, completed = GetAchievementComparisonInfo(achievementID)

            -- Clear the comparison unit
            ClearAchievementComparisonUnit()

            if completed ~= nil then
                local result = completed and "completed" or "not_completed"
                BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r %s achievement status: %s", playerName, result))

                -- Cache the successful result in scanResults
                if not BZ.scanResults[achievementID] then
                    BZ.scanResults[achievementID] = {
                        completed = {},
                        notCompleted = {},
                        timestamp = GetTime(),
                        zone = GetZoneText()
                    }
                end

                if result == "completed" then
                    table.insert(BZ.scanResults[achievementID].completed, playerName)
                else
                    table.insert(BZ.scanResults[achievementID].notCompleted, playerName)
                end

                return result
            else
                BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r %s achievement status could not be determined", playerName))
                return "unknown"
            end
        else
            BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Cannot inspect %s (offline or dead)", playerName))
            return "unknown"
        end
    end
end

-- Scan group members for active achievement
function BZ:ScanGroupForActiveAchievement(scanType)
    local activeID = BZ.db.settings.activeAchievementID
    if not activeID then
        BZ.debugLog("|cffff0000[BZ]|r No active achievement set for scanning")
        return
    end

    if BZ.groupScanInProgress then
        BZ.debugLog("|cffff0000[BZ]|r Group scan already in progress")
        return
    end

    -- Start timing the scan
    BZ.scanStartTime = GetTime()
    BZ.groupScanInProgress = true
    BZ.currentScanAchievementID = activeID
    BZ.scanCounter = BZ.scanCounter + 1

    local players = BZ:GetPlayersInGroup()
    local achievementName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"

    -- Initialize scan results for this achievement
    if not BZ.scanResults[activeID] then
        BZ.scanResults[activeID] = {
            completed = {},
            notCompleted = {},
            timestamp = GetTime(),
            zone = GetZoneText()
        }
    end

    -- Separate players into those we need to scan vs those we have cached
    local playersToScan = {}
    local cachedResults = 0
    local results = BZ.scanResults[activeID]

    -- Clear current results but preserve structure
    results.completed = {}
    results.notCompleted = {}
    results.timestamp = GetTime()

    for _, playerName in ipairs(players) do
        -- This will populate the results through PlayerHasAchievement calls
        local status = BZ:PlayerHasAchievement(playerName, activeID)

        if status ~= "unknown" then
            cachedResults = cachedResults + 1
        else
            table.insert(playersToScan, playerName)
        end
    end

    local scanTypeText = scanType or "manual"
    if cachedResults > 0 then
        BZ.debugLog(string.format("|cff00ff00[BZ]|r %s scan: Using %d cached results, need to scan %d unknown players for achievement: %s", scanTypeText, cachedResults, #playersToScan, achievementName))
    else
        BZ.debugLog(string.format("|cff00ff00[BZ]|r %s scan: Scanning %d players for achievement: %s", scanTypeText, #players, achievementName))
    end

    -- Scanning is now complete since PlayerHasAchievement populated the results
    BZ:CompleteScan()
end

-- Complete the group scan and display results
function BZ:CompleteScan()
    BZ.groupScanInProgress = false

    -- Calculate scan duration
    local scanDuration = BZ.scanStartTime and (GetTime() - BZ.scanStartTime) or 0
    local durationText = string.format("%.2fs", scanDuration)

    local achievementName = select(2, GetAchievementInfo(BZ.currentScanAchievementID)) or "Unknown Achievement"
    local results = BZ.scanResults[BZ.currentScanAchievementID]

    if not results then
        BZ.debugLog(string.format("|cff00ff00[BZ]|r Scan completed but no results found (took %s)", durationText))
        return
    end

    local completedCount = #results.completed
    local notCompletedCount = #results.notCompleted
    local totalScanned = completedCount + notCompletedCount
    local groupSize = BZ:GetGroupSize()
    local unknownCount = groupSize - totalScanned

    BZ.debugLog(string.format("|cff00ff00[BZ]|r Scan complete: %d completed, %d not completed, %d unknown, %d total for %s (took %s)", completedCount, notCompletedCount, unknownCount, groupSize, achievementName, durationText))

    if notCompletedCount > 0 then
        BZ.debugLog("|cff00ff00[BZ]|r Players not completed the achievement:")
        for _, playerName in ipairs(results.notCompleted) do
            BZ.debugLog(string.format("  - %s", playerName))
        end
    else
        BZ.debugLog("|cff00ff00[BZ]|r All scanned players have the achievement!")
    end

    -- Update display frame to show scan results
    BZ:UpdateDisplayFrame()
end

-- Get the current scan results for the active achievement
function BZ:GetActiveScanResults()
    local activeID = BZ.db.settings.activeAchievementID
    return activeID and BZ.scanResults[activeID] or nil
end

-- Print the current scan results to chat
function BZ:PrintScanResults()
    local activeID = BZ.db.settings.activeAchievementID
    if not activeID then
        BZ.debugLog("|cffff0000[BZ]|r No active achievement set")
        return
    end

    local results = BZ.scanResults[activeID]
    if not results then
        BZ.debugLog("|cffff0000[BZ]|r No scan results available")
        return
    end

    local achievementName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"
    local notCompletedCount = #results.notCompleted

    if notCompletedCount == 0 then
        BZ.debugLog(string.format("|cff00ff00[BZ]|r Scan results: No players not completed %s", achievementName))
    else
        BZ.debugLog(string.format("|cff00ff00[BZ]|r Scan results for %s (%d players not completed):", achievementName, notCompletedCount))
        for _, playerName in ipairs(results.notCompleted) do
            BZ.debugLog(string.format("  - %s", playerName))
        end
    end
end



-- Start periodic scanning
function BZ:StartPeriodicScanning()
    if BZ.periodicScanTimer then
        BZ.periodicScanTimer:Cancel()
    end

    BZ.periodicScanTimer = C_Timer.NewTicker(10, function()
        BZ:PeriodicScanCheck()
    end)

    BZ.debugLog("|cff00ff00[BZ Debug]|r Started periodic scanning (every 10 seconds)")
end

-- Stop periodic scanning
function BZ:StopPeriodicScanning()
    if BZ.periodicScanTimer then
        BZ.periodicScanTimer:Cancel()
        BZ.periodicScanTimer = nil
        BZ.debugLog("|cff00ff00[BZ Debug]|r Stopped periodic scanning")
    end
end

-- Check if we should perform a periodic scan
function BZ:PeriodicScanCheck()
    -- Only scan if we have an active achievement
    if not BZ.db.settings.activeAchievementID then
        return
    end

    -- Only scan if we're in a group
    if BZ:GetGroupSize() <= 1 then
        return
    end

    -- Don't scan if in combat
    if InCombatLockdown() then
        BZ.debugLog("|cff00ff00[BZ Debug]|r Skipping periodic scan: in combat")
        return
    end

    -- Don't scan if already scanning
    if BZ.groupScanInProgress then
        BZ.debugLog("|cff00ff00[BZ Debug]|r Skipping periodic scan: scan already in progress")
        return
    end

    BZ.debugLog("|cff00ff00[BZ Debug]|r Performing periodic scan...")
    BZ:ScanGroupForActiveAchievement("periodic")
end

-- Clear scan results (call this when leaving instance)
function BZ:ClearScanResults()
    BZ.scanResults = {}
    BZ.debugLog("|cff00ff00[BZ Debug]|r Scan results cleared")
end




-- Toggle tracked achievement (using achievements object as source of truth)
function BZ:ToggleTrackedAchievement(achievementID)
    if BZ.db.achievements[achievementID] then
        -- Remove from tracking
        BZ.db.achievements[achievementID] = nil
        BZ.debugLog(string.format("|cff00ff00[BZ]|r Removed achievement %d from tracking", achievementID))
    else
        -- Add to tracking with 0 count
        BZ.db.achievements[achievementID] = 0
        BZ.debugLog(string.format("|cff00ff00[BZ]|r Added achievement %d to tracking", achievementID))
    end
end

-- Show tracked achievements
function BZ:ShowTrackedAchievements()
    local activeID = BZ.db.settings.activeAchievementID
    local count = 0

    BZ.debugLog("|cff00ff00[BZ]|r Currently tracked achievements:")
    for achievementID, achievementCount in pairs(BZ.db.achievements) do
        local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
        local activeMarker = (achievementID == activeID) and " |cffff8000[ACTIVE]|r" or ""
        BZ.debugLog(string.format("  [%d] %s: %d times%s", achievementID, achievementName, achievementCount, activeMarker))
        count = count + 1
    end

    if count == 0 then
        BZ.debugLog("|cff00ff00[BZ]|r No achievements currently tracked")
    end

    -- Show active achievement info
    if activeID then
        local activeName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"
        local activeCount = BZ.db.achievements[activeID] or 0
        BZ.debugLog(string.format("|cff00ff00[BZ]|r Active display: [%d] %s (%d times)", activeID, activeName, activeCount))
    else
        BZ.debugLog("|cff00ff00[BZ]|r No active achievement set for display")
    end
end

-- Set active achievement
function BZ:SetActiveAchievement(achievementID)
    BZ.db.settings.activeAchievementID = achievementID
    local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"

    -- Ensure this achievement is being tracked
    if not BZ.db.achievements[achievementID] then
        BZ.db.achievements[achievementID] = 0
    end

    BZ.debugLog(string.format("|cff00ff00[BZ]|r Set active achievement: [%d] %s", achievementID, achievementName))

    -- Start periodic scanning if in a group
    if BZ:GetGroupSize() > 1 then
        BZ:StartPeriodicScanning()
    end

    BZ:UpdateDisplayFrame()
end
-- Create settings panel
function BZ:CreateSettingsPanel()
    local panel = CreateFrame("Frame", "BezierSettingsPanel", UIParent)
    panel.name = "Bezier"

    -- Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Bezier Settings")

    -- Display Frame Settings Section
    local displayLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    displayLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -30)
    displayLabel:SetText("Display Frame Settings:")

    -- Enable Display Frame setting
    local enableCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    enableCheckbox:SetSize(20, 20)
    enableCheckbox:SetPoint("TOPLEFT", displayLabel, "BOTTOMLEFT", 10, -10)
    enableCheckbox:SetChecked(BZ.db.settings.displayFrame.enabled)

    local enableLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    enableLabel:SetPoint("LEFT", enableCheckbox, "RIGHT", 5, 0)
    enableLabel:SetText("Show Display Frame")

    enableCheckbox:SetScript("OnClick", function()
        BZ.db.settings.displayFrame.enabled = enableCheckbox:GetChecked()
        if BZ.db.settings.displayFrame.enabled then
            if BZ.displayFrame then
                BZ.displayFrame:Show()
            else
                BZ:CreateDisplayFrame()
            end
            BZ.debugLog("|cff00ff00[BZ]|r Display frame enabled")
        else
            if BZ.displayFrame then
                BZ.displayFrame:Hide()
            end
            BZ.debugLog("|cff00ff00[BZ]|r Display frame disabled")
        end
    end)

    -- Display Prefix setting
    local prefixLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    prefixLabel:SetPoint("TOPLEFT", enableCheckbox, "BOTTOMLEFT", 0, -20)
    prefixLabel:SetText("Display Text Prefix:")

    local prefixHelp = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    prefixHelp:SetPoint("TOPLEFT", prefixLabel, "BOTTOMLEFT", 0, -2)
    prefixHelp:SetText("(This text will be shown before the count, e.g., 'Your Text: 5')")
    prefixHelp:SetTextColor(0.7, 0.7, 0.7)

    local prefixInput = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    prefixInput:SetSize(150, 20)
    prefixInput:SetPoint("TOPLEFT", prefixHelp, "BOTTOMLEFT", 0, -5)
    prefixInput:SetAutoFocus(false)
    prefixInput:SetText(BZ.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX)

    local prefixSaveButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    prefixSaveButton:SetSize(50, 22)
    prefixSaveButton:SetPoint("LEFT", prefixInput, "RIGHT", 5, 0)
    prefixSaveButton:SetText("Save")
    prefixSaveButton:SetScript("OnClick", function()
        local newPrefix = prefixInput:GetText()
        if newPrefix and newPrefix ~= "" then
            BZ.db.settings.displayFrame.displayPrefix = newPrefix
            BZ:UpdateDisplayFrame()
            BZ.debugLog("|cff00ff00[BZ]|r Display prefix updated to: '" .. newPrefix .. "'")
        else
            BZ.debugLog("|cffff0000[BZ]|r Display prefix cannot be empty")
        end
    end)

    local prefixResetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    prefixResetButton:SetSize(50, 22)
    prefixResetButton:SetPoint("LEFT", prefixSaveButton, "RIGHT", 5, 0)
    prefixResetButton:SetText("Reset")
    prefixResetButton:SetScript("OnClick", function()
        BZ.db.settings.displayFrame.displayPrefix = DEFAULT_PREFIX
        prefixInput:SetText(DEFAULT_PREFIX)
        BZ:UpdateDisplayFrame()
        BZ.debugLog("|cff00ff00[BZ]|r Display prefix reset to default: '" .. DEFAULT_PREFIX .. "'")
    end)

    -- Font Size setting
    local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", prefixInput, "BOTTOMLEFT", 0, -40)
    fontLabel:SetText("Font Size:")

    local fontSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
    fontSlider:SetSize(150, 20)
    fontSlider:SetPoint("LEFT", fontLabel, "RIGHT", 10, 0)
    fontSlider:SetMinMaxValues(8, 24)
    fontSlider:SetValue(BZ.db.settings.displayFrame.fontSize or 12)
    fontSlider:SetValueStep(1)
    fontSlider:SetObeyStepOnDrag(true)

    -- Slider labels (using template's built-in labels)
    fontSlider.Low:SetText("8")
    fontSlider.High:SetText("24")

    fontSlider.Text = fontSlider:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontSlider.Text:SetPoint("LEFT", fontSlider, "RIGHT", 10, 0)
    fontSlider.Text:SetText("Size: " .. (BZ.db.settings.displayFrame.fontSize or 12))

    fontSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        BZ.db.settings.displayFrame.fontSize = value
        fontSlider.Text:SetText("Size: " .. value)
        BZ:UpdateDisplayFrame()
    end)

    -- General Settings Section
    local generalLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    generalLabel:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", -10, -40)
    generalLabel:SetText("General Settings:")

    -- Debug Mode setting
    local debugCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    debugCheckbox:SetSize(20, 20)
    debugCheckbox:SetPoint("TOPLEFT", generalLabel, "BOTTOMLEFT", 10, -10)
    debugCheckbox:SetChecked(BZ.db.settings.enableDebugLogging)

    local debugLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    debugLabel:SetPoint("LEFT", debugCheckbox, "RIGHT", 5, 0)
    debugLabel:SetText("Enable Debug Logging")

    debugCheckbox:SetScript("OnClick", function()
        BZ.db.settings.enableDebugLogging = debugCheckbox:GetChecked()
        BZ.debugLog(string.format("|cff00ff00[BZ]|r Debug logging: %s", BZ.db.settings.enableDebugLogging and "ON" or "OFF"))
    end)

    -- Group Scanning Section
    local groupLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    groupLabel:SetPoint("TOPLEFT", debugCheckbox, "BOTTOMLEFT", -10, -30)
    groupLabel:SetText("Group Achievement Scanning:")

    -- Scan Group button
    local scanButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    scanButton:SetSize(120, 22)
    scanButton:SetPoint("TOPLEFT", groupLabel, "BOTTOMLEFT", 0, -5)
    scanButton:SetText("Scan Group")
    scanButton:SetScript("OnClick", function()
        BZ:ScanGroupForActiveAchievement()
    end)

    -- Players scan results display
    local scanResultsLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    scanResultsLabel:SetPoint("TOPLEFT", scanButton, "BOTTOMLEFT", 0, -10)
    scanResultsLabel:SetText("Scan results (players not completed):")
    scanResultsLabel:SetTextColor(1, 1, 1)

    -- Scrollable list for scan results
    local scanResultsScrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scanResultsScrollFrame:SetSize(300, 80)
    scanResultsScrollFrame:SetPoint("TOPLEFT", scanResultsLabel, "BOTTOMLEFT", 0, -5)

    local scanResultsScrollChild = CreateFrame("Frame", nil, scanResultsScrollFrame)
    scanResultsScrollChild:SetSize(280, 1)
    scanResultsScrollFrame:SetScrollChild(scanResultsScrollChild)

    -- Function to update scan results display
    local function UpdateScanResultsDisplay()
        -- Clear existing children
        local children = {scanResultsScrollChild:GetChildren()}
        for i = 1, #children do
            children[i]:Hide()
            children[i]:SetParent(nil)
        end

        local yOffset = 0
        local activeID = BZ.db.settings.activeAchievementID
        local results = activeID and BZ.scanResults[activeID]

        if not results then
            local noScanText = scanResultsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noScanText:SetPoint("TOPLEFT", 0, -yOffset)
            noScanText:SetText("No scan performed yet - click Scan button")
            noScanText:SetTextColor(0.7, 0.7, 0.7)
            yOffset = yOffset + 15
        else
            local completedCount = #results.completed
            local notCompletedCount = #results.notCompleted
            local groupSize = BZ:GetGroupSize()
            local unknownCount = groupSize - completedCount - notCompletedCount

            -- Show summary
            local summaryText = scanResultsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            summaryText:SetPoint("TOPLEFT", 0, -yOffset)
            summaryText:SetText(string.format("Scan: %d completed, %d not completed, %d unknown", completedCount, notCompletedCount, unknownCount))
            summaryText:SetTextColor(0.9, 0.9, 0.9)
            yOffset = yOffset + 20

            -- Show not completed players
            if notCompletedCount > 0 then
                local notCompletedHeader = scanResultsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                notCompletedHeader:SetPoint("TOPLEFT", 0, -yOffset)
                notCompletedHeader:SetText("Players Not Completed:")
                notCompletedHeader:SetTextColor(1, 0.8, 0.8)
                yOffset = yOffset + 15

                for _, playerName in ipairs(results.notCompleted) do
                    local playerText = scanResultsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    playerText:SetPoint("TOPLEFT", 0, -yOffset)
                    playerText:SetText("• " .. playerName)
                    playerText:SetTextColor(1, 0.8, 0.8)
                    yOffset = yOffset + 15
                end
            end

            -- Show note about unknown players if any
            if unknownCount > 0 then
                if notCompletedCount > 0 then
                    yOffset = yOffset + 5 -- Add spacing
                end

                local unknownNote = scanResultsScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                unknownNote:SetPoint("TOPLEFT", 0, -yOffset)
                unknownNote:SetText(string.format("Note: %d players could not be scanned (offline/dead)", unknownCount))
                unknownNote:SetTextColor(1, 1, 0.6)
                yOffset = yOffset + 15
            end
        end

        scanResultsScrollChild:SetHeight(math.max(yOffset, 1))
        scanResultsScrollFrame:UpdateScrollChildRect()
    end

    -- Update scan button to refresh display
    scanButton:SetScript("OnClick", function()
        BZ:ScanGroupForActiveAchievement()
        C_Timer.After(1, UpdateScanResultsDisplay) -- Update display after scan
    end)

    -- Initial display update
    UpdateScanResultsDisplay()

    -- Add Achievement section
    local addLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    addLabel:SetPoint("TOPLEFT", scanButton, "BOTTOMLEFT", -10, -30)
    addLabel:SetText("Add Achievement to Track:")

    -- Input box for achievement ID
    local addInput = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    addInput:SetSize(120, 20)
    addInput:SetPoint("TOPLEFT", addLabel, "BOTTOMLEFT", 0, -5)
    addInput:SetAutoFocus(false)
    addInput:SetNumeric(true)

    -- Add button
    local addButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    addButton:SetSize(80, 22)
    addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
    addButton:SetText("Add")

    -- Tracked achievements table header
    local tableLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    tableLabel:SetPoint("TOPLEFT", addInput, "BOTTOMLEFT", 0, -30)
    tableLabel:SetText("Tracked Achievements:")

    -- Create scroll frame for the table
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(500, 300)
    scrollFrame:SetPoint("TOPLEFT", tableLabel, "BOTTOMLEFT", 0, -10)

    -- Create scroll child
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(480, 1) -- Height will be set dynamically
    scrollFrame:SetScrollChild(scrollChild)

    -- Function to update the achievements table
    local function UpdateAchievementsTable()
        -- Clear existing children more thoroughly
        local children = {scrollChild:GetChildren()}
        for i = 1, #children do
            children[i]:Hide()
            children[i]:SetParent(nil)
        end

        -- Reset scroll position to avoid rendering issues
        scrollFrame:SetVerticalScroll(0)

        local yOffset = 0
        local activeID = BZ.db.settings.activeAchievementID

        -- Create header row
        local headerFrame = CreateFrame("Frame", nil, scrollChild)
        headerFrame:SetSize(480, 25)
        headerFrame:SetPoint("TOPLEFT", 0, -yOffset)

        local headerBg = headerFrame:CreateTexture(nil, "BACKGROUND")
        headerBg:SetAllPoints()
        headerBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)

        local idHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        idHeader:SetPoint("LEFT", 5, 0)
        idHeader:SetText("ID")

        local nameHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameHeader:SetPoint("LEFT", 50, 0)
        nameHeader:SetText("Achievement Name")

        local countHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countHeader:SetPoint("LEFT", 280, 0)
        countHeader:SetText("Count")

        local activeHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        activeHeader:SetPoint("LEFT", 330, 0)
        activeHeader:SetText("Active")

        local deleteHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        deleteHeader:SetPoint("LEFT", 420, 0)
        deleteHeader:SetText("Delete")

        yOffset = yOffset + 25

        -- Create rows for each tracked achievement
        for achievementID, count in pairs(BZ.db.achievements) do
            local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
            local isActive = (achievementID == activeID)

            -- Create row frame
            local rowFrame = CreateFrame("Frame", nil, scrollChild)
            rowFrame:SetSize(480, 25)
            rowFrame:SetPoint("TOPLEFT", 0, -yOffset)

            -- Alternating row colors
            local rowBg = rowFrame:CreateTexture(nil, "BACKGROUND")
            rowBg:SetAllPoints()
            if (yOffset / 25) % 2 == 0 then
                rowBg:SetColorTexture(0.1, 0.1, 0.1, 0.3)
            else
                rowBg:SetColorTexture(0.15, 0.15, 0.15, 0.3)
            end

            -- Achievement ID
            local idText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            idText:SetPoint("LEFT", 5, 0)
            idText:SetText(tostring(achievementID))

            -- Achievement name (truncated if too long)
            local nameText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            nameText:SetPoint("LEFT", 50, 0)
            nameText:SetSize(220, 20)
            nameText:SetJustifyH("LEFT")
            if string.len(achievementName) > 30 then
                nameText:SetText(string.sub(achievementName, 1, 27) .. "...")
            else
                nameText:SetText(achievementName)
            end

            -- Count
            local countText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            countText:SetPoint("LEFT", 280, 0)
            countText:SetText(tostring(count))

            -- Set Active button
            local activeButton = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
            activeButton:SetSize(70, 18)
            activeButton:SetPoint("LEFT", 330, 0)
            if isActive then
                activeButton:SetText("ACTIVE")
                activeButton:SetEnabled(false)
            else
                activeButton:SetText("Set Active")
                activeButton:SetEnabled(true)
                activeButton:SetScript("OnClick", function()
                    BZ:SetActiveAchievement(achievementID)
                    -- Delay the table update slightly to avoid rendering conflicts
                    C_Timer.After(0.05, function()
                        UpdateAchievementsTable() -- Refresh the table
                    end)
                end)
            end

            -- Delete button
            local deleteButton = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
            deleteButton:SetSize(50, 18)
            deleteButton:SetPoint("LEFT", 420, 0)
            deleteButton:SetText("Delete")
            deleteButton:SetScript("OnClick", function()
                BZ:ToggleTrackedAchievement(achievementID) -- This will remove it
                -- Delay the table update slightly to avoid rendering conflicts
                C_Timer.After(0.05, function()
                    UpdateAchievementsTable() -- Refresh the table
                end)
            end)

            yOffset = yOffset + 25
        end

        -- If no achievements, show message
        if yOffset == 25 then -- Only header row
            local noDataFrame = CreateFrame("Frame", nil, scrollChild)
            noDataFrame:SetSize(480, 25)
            noDataFrame:SetPoint("TOPLEFT", 0, -yOffset)

            local noDataText = noDataFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            noDataText:SetPoint("CENTER")
            noDataText:SetText("No achievements tracked yet. Add one above!")
            noDataText:SetTextColor(0.7, 0.7, 0.7)

            yOffset = yOffset + 25
        end

        -- Set scroll child height and force refresh
        scrollChild:SetHeight(math.max(yOffset, 1))

        -- Force scroll frame to recalculate and refresh
        scrollFrame:UpdateScrollChildRect()

        -- Small delay to ensure proper rendering
        C_Timer.After(0.01, function()
            if scrollFrame:IsVisible() then
                scrollFrame:UpdateScrollChildRect()
            end
        end)
    end

    -- Add button click handler
    addButton:SetScript("OnClick", function()
        local achievementID = tonumber(addInput:GetText())
        if achievementID then
            -- Check if achievement exists
            local achievementName = select(2, GetAchievementInfo(achievementID))
            if achievementName then
                BZ:ToggleTrackedAchievement(achievementID)
                addInput:SetText("") -- Clear input
                UpdateAchievementsTable() -- Refresh table
            else
                BZ.debugLog("|cffff0000[BZ]|r Invalid achievement ID: " .. achievementID)
            end
        else
            BZ.debugLog("|cffff0000[BZ]|r Please enter a valid achievement ID")
        end
    end)

    -- Function to update all settings values
    local function UpdateSettingsValues()
        enableCheckbox:SetChecked(BZ.db.settings.displayFrame.enabled)
        prefixInput:SetText(BZ.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX)
        fontSlider:SetValue(BZ.db.settings.displayFrame.fontSize or 12)
        fontSlider.Text:SetText("Size: " .. (BZ.db.settings.displayFrame.fontSize or 12))
        debugCheckbox:SetChecked(BZ.db.settings.enableDebugLogging)
    end

    -- Panel show/hide handlers
    panel:SetScript("OnShow", function()
        UpdateSettingsValues()
        UpdateAchievementsTable()
    end)

    -- Register with settings
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    else
        InterfaceOptions_AddCategory(panel)
    end
end

-- Create display frame
function BZ:CreateDisplayFrame()
    if BZ.displayFrame then
        return
    end

    -- Don't create if disabled
    if not BZ.db.settings.displayFrame.enabled then
        return
    end

    -- Create the main frame
    BZ.displayFrame = CreateFrame("Frame", "BezierDisplay", UIParent, "BackdropTemplate")
    BZ.displayFrame:SetSize(200, 30)
    BZ.displayFrame:SetPoint("CENTER")
    BZ.displayFrame:SetClampedToScreen(true)

    -- Set backdrop
    BZ.displayFrame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    BZ.displayFrame:SetBackdropColor(0, 0, 0, 0.8)

    -- Enable mouse
    BZ.displayFrame:EnableMouse(true)
    BZ.displayFrame:SetMovable(true)
    BZ.displayFrame:RegisterForDrag("LeftButton")

    -- Create text
    local text = BZ.displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", 10, 0)
    text:SetTextColor(1, 1, 1, 1)
    BZ.displayFrame.text = text

    -- Create scan button (initially hidden)
    local scanButton = CreateFrame("Button", nil, BZ.displayFrame, "UIPanelButtonTemplate")
    scanButton:SetSize(50, 20)
    scanButton:SetPoint("RIGHT", -10, 0)
    scanButton:SetText("Scan")
    scanButton:Hide()
    BZ.displayFrame.scanButton = scanButton

    -- Scan button click handler
    scanButton:SetScript("OnClick", function()
        BZ:ScanGroupForActiveAchievement()
        -- Update display after a short delay to show results
        C_Timer.After(0.5, function()
            BZ:UpdateDisplayFrame()
        end)
    end)

    -- Mouse handlers
    BZ.displayFrame:SetScript("OnMouseDown", function(self, button)
        if IsShiftKeyDown() and button == "LeftButton" then
            self:StartMoving()
        end
    end)

    BZ.displayFrame:SetScript("OnMouseUp", function(self, button)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        BZ.db.settings.displayFrame.x = x
        BZ.db.settings.displayFrame.y = y
    end)

    -- Tooltip
    BZ.displayFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Bezier", 1, 1, 1)
        GameTooltip:AddLine("Hold Shift + Drag to move", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    BZ.displayFrame:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    -- Show the frame
    BZ.displayFrame:Show()

    -- Update the text
    BZ:UpdateDisplayFrame()
end

-- Update display frame text
function BZ:UpdateDisplayFrame()
    if not BZ.displayFrame or not BZ.db.settings.displayFrame.enabled then
        return
    end

    local activeID = BZ.db.settings.activeAchievementID
    if not activeID then
        BZ.displayFrame.text:SetText("No active achievement set")
        BZ.displayFrame.scanButton:Hide()
        -- Auto-resize frame for text only
        local textWidth = BZ.displayFrame.text:GetStringWidth()
        local textHeight = BZ.displayFrame.text:GetStringHeight()
        local frameWidth = math.max(textWidth + 20, 80)
        local frameHeight = math.max(textHeight + 12, 20)
        BZ.displayFrame:SetSize(frameWidth, frameHeight)
        return
    end

    local groupSize = BZ:GetGroupSize()
    local inGroup = groupSize > 1

    -- Update font size
    local fontSize = BZ.db.settings.displayFrame.fontSize or 12
    local fontPath, _, fontFlags = BZ.displayFrame.text:GetFont()
    BZ.displayFrame.text:SetFont(fontPath or "Fonts\\FRIZQT__.TTF", fontSize, fontFlags or "OUTLINE")

    local displayText
    local showScanButton = false

    if inGroup then
        -- Check if we have scan results
        local results = BZ.scanResults[activeID]

        if results then
            local completedCount = #results.completed
            local notCompletedCount = #results.notCompleted
            local totalScanned = completedCount + notCompletedCount
            local unknownCount = groupSize - totalScanned

            if totalScanned > 0 then
                -- Show scan results: X/U?/Y format (X not completed, U? unknown, Y total)
                displayText = string.format("%d/%d?/%d", notCompletedCount, unknownCount, groupSize)
            else
                -- No scan results yet, show achievement count
                local count = BZ.db.achievements[activeID] or 0
                local prefix = BZ.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX
                displayText = string.format("%s: %d", prefix, count)
            end
        else
            -- No scan results, show achievement count
            local count = BZ.db.achievements[activeID] or 0
            local prefix = BZ.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX
            displayText = string.format("%s: %d", prefix, count)
        end
        showScanButton = true
    else
        -- Solo player - show normal count
        local count = BZ.db.achievements[activeID] or 0
        local prefix = BZ.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX
        displayText = string.format("%s: %d", prefix, count)
        showScanButton = false
    end

    -- Set text
    BZ.displayFrame.text:SetText(displayText)

    -- Show/hide scan button
    if showScanButton then
        BZ.displayFrame.scanButton:Show()
    else
        BZ.displayFrame.scanButton:Hide()
    end

    -- Auto-resize frame
    local textWidth = BZ.displayFrame.text:GetStringWidth()
    local textHeight = BZ.displayFrame.text:GetStringHeight()
    local buttonWidth = showScanButton and 60 or 0 -- 50 for button + 10 padding
    local frameWidth = math.max(textWidth + buttonWidth + 20, 80)
    local frameHeight = math.max(textHeight + 12, 20)
    BZ.displayFrame:SetSize(frameWidth, frameHeight)
end