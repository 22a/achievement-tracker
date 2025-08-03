-- AotC Counter Addon
-- Tracks Ahead of the Curve achievements and displays counts

local AC = {}
AotCCounter = AC

-- Constants
local DEFAULT_PREFIX = "AotC this season"

-- Addon event frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_ACHIEVEMENT")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Group scanning variables
AC.groupScanInProgress = false
AC.playersToScan = {}
AC.playersScanned = {}
AC.playersMissingAchievement = {} -- Allowlist of players who don't have the active achievement
AC.currentScanAchievementID = nil
AC.scanCounter = 0
AC.preKillStatus = {} -- Store pre-kill achievement status for players

-- Default database structure
local defaultDB = {
    achievements = {
        [41298] = 0, -- Ahead of the Curve: Chrome King Gallywix
    }, -- [achievementID] = count (simple counter)
    settings = {
        enableDebug = false,
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
function AC:OnAddonLoaded()
    -- Initialize saved variables
    if not AotCCounterDB then
        AotCCounterDB = {}
    end

    -- Migrate old flat settings structure to new nested structure
    if AotCCounterDB.settings then
        -- Migrate displayPrefix from flat to nested structure
        if AotCCounterDB.settings.displayPrefix and not AotCCounterDB.settings.displayFrame then
            AotCCounterDB.settings.displayFrame = {}
        end
        if AotCCounterDB.settings.displayPrefix and not AotCCounterDB.settings.displayFrame.displayPrefix then
            AotCCounterDB.settings.displayFrame.displayPrefix = AotCCounterDB.settings.displayPrefix
        end

        -- Migrate fontSize from flat to nested structure
        if AotCCounterDB.settings.fontSize and not AotCCounterDB.settings.displayFrame.fontSize then
            AotCCounterDB.settings.displayFrame.fontSize = AotCCounterDB.settings.fontSize
        end
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

    deepMerge(AotCCounterDB, defaultDB)

    AC.db = AotCCounterDB

    print("|cff00ff00AotC Counter|r loaded. Open Interface Options > AddOns > AotC Counter to configure.")

    -- Create settings panel
    AC:CreateSettingsPanel()

    -- Create display frame
    AC:CreateDisplayFrame()
end

-- Parse achievement message from chat
function AC:ParseAchievementMessage(message, sender)
    if AC.db.settings.enableDebug then
        print(string.format("|cff00ff00[AC Debug]|r Parsing: '%s' from %s", message or "nil", sender or "nil"))
    end

    -- Pattern for achievement messages
    local achievementID = string.match(message, "|Hachievement:(%d+):")
    if achievementID then
        achievementID = tonumber(achievementID)
        local achievementName = select(2, GetAchievementInfo(achievementID))

        if AC.db.settings.enableDebug then
            print(string.format("|cff00ff00[AC Debug]|r Found achievement: ID=%d, Name=%s", achievementID, achievementName or "Unknown"))
        end

        return sender, achievementID, achievementName
    end

    return nil, nil, nil
end

-- Check if we should track this achievement
function AC:ShouldTrackAchievement(achievementID)
    -- Always track the active achievement
    if achievementID == AC.db.settings.activeAchievementID then
        return true
    end

    -- Also track any achievement that's already in our database (previously tracked)
    return AC.db.achievements[achievementID] ~= nil
end

-- Record an achievement for a player
function AC:RecordAchievement(playerName, achievementID, achievementName)
    -- Check if we should track this achievement
    if not AC:ShouldTrackAchievement(achievementID) then
        return
    end

    -- Check if we have pre-kill status for this achievement and player
    local isFirstTime = true
    if AC.preKillStatus[achievementID] and AC.preKillStatus[achievementID][playerName] ~= nil then
        -- We have pre-kill data - compare against it
        local hadAchievementBefore = AC.preKillStatus[achievementID][playerName]
        isFirstTime = not hadAchievementBefore

        if AC.db.settings.enableDebug then
            print(string.format("|cff00ff00[AC Debug]|r Pre-kill check for %s: had achievement = %s, counting = %s",
                  playerName, tostring(hadAchievementBefore), tostring(isFirstTime)))
        end
    else
        -- No pre-kill data available - assume it's first time (fallback behavior)
        if AC.db.settings.enableDebug then
            print(string.format("|cff00ff00[AC Debug]|r No pre-kill data for %s, assuming first time", playerName))
        end
    end

    -- Only count first-time achievements
    if not isFirstTime then
        if AC.db.settings.enableDebug then
            print(string.format("|cff00ff00[AC Debug]|r Skipping alt completion for %s: [%d] %s (already had achievement)",
                  playerName, achievementID, achievementName))
        end
        return
    end

    -- Initialize counter if it doesn't exist
    if not AC.db.achievements[achievementID] then
        AC.db.achievements[achievementID] = 0
    end

    -- Increment the counter
    AC.db.achievements[achievementID] = AC.db.achievements[achievementID] + 1

    -- Debug output
    if AC.db.settings.enableDebug then
        print(string.format("|cff00ff00[AC Debug]|r Recorded first-time achievement for %s: [%d] %s (Total: %d)",
              playerName, achievementID, achievementName, AC.db.achievements[achievementID]))
    end

    -- Update display frame if this is the active achievement
    if AC.db.settings.activeAchievementID == achievementID then
        AC:UpdateDisplayFrame()
    end
end

-- Event handler
function AC:OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "AotCCounter" then
            AC:OnAddonLoaded()
        end
    elseif event == "CHAT_MSG_ACHIEVEMENT" then
        local message, sender = ...
        local playerName, achievementID, achievementName = AC:ParseAchievementMessage(message, sender)

        if playerName and achievementID and achievementName then
            AC:RecordAchievement(playerName, achievementID, achievementName)
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Group composition changed, could trigger a rescan if needed
        if AC.db.settings.enableDebug then
            print("|cff00ff00[AC Debug]|r Group roster updated")
        end

        -- Auto-scan if we have an active achievement and are in a group
        if AC.db.settings.activeAchievementID and AC:GetGroupSize() > 1 and not AC.groupScanInProgress then
            C_Timer.After(2, function() -- Delay to let group settle
                AC:ScanGroupForActiveAchievement()
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Player entered world, could be a good time to scan if in a group
        if AC.db.settings.enableDebug then
            print("|cff00ff00[AC Debug]|r Player entering world")
        end
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    AC:OnEvent(event, ...)
end)

-- Get current group size
function AC:GetGroupSize()
    local size = GetNumGroupMembers()
    if size == 0 then
        return 1 -- Solo player
    else
        return size
    end
end

-- Get group type for chat messages
function AC:GetGroupType()
    if IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    else
        return "SAY"
    end
end

-- Get list of players in current group
function AC:GetPlayersInGroup()
    local players = {}
    local groupSize = AC:GetGroupSize()

    if groupSize > 1 then
        local groupType = AC:GetGroupType()

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
function AC:PlayerHasAchievement(playerName, achievementID)
    if not achievementID then
        return false
    end

    -- Find the unit for this player
    local unit = nil
    local groupSize = AC:GetGroupSize()

    if groupSize > 1 then
        local groupType = AC:GetGroupType()

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
        if AC.db.settings.enableDebug then
            print(string.format("|cff00ff00[AC Debug]|r Could not find unit for player: %s", playerName))
        end
        return false
    end

    -- Check if we can inspect this unit's achievements
    if unit == "player" then
        -- Check our own achievements
        local _, _, _, completed = GetAchievementInfo(achievementID)
        return completed
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

            if AC.db.settings.enableDebug then
                print(string.format("|cff00ff00[AC Debug]|r %s achievement status: %s", playerName, tostring(completed)))
            end

            return completed or false
        else
            if AC.db.settings.enableDebug then
                print(string.format("|cff00ff00[AC Debug]|r Cannot inspect %s (offline or dead)", playerName))
            end
            return false -- Assume they don't have it if we can't check
        end
    end
end

-- Scan group members for active achievement
function AC:ScanGroupForActiveAchievement()
    local activeID = AC.db.settings.activeAchievementID
    if not activeID then
        print("|cffff0000[AC]|r No active achievement set for scanning")
        return
    end

    if AC.groupScanInProgress then
        print("|cffff0000[AC]|r Group scan already in progress")
        return
    end

    AC.groupScanInProgress = true
    AC.playersToScan = {}
    AC.playersScanned = {}
    AC.playersMissingAchievement = {}
    AC.currentScanAchievementID = activeID
    AC.scanCounter = AC.scanCounter + 1

    local players = AC:GetPlayersInGroup()
    local achievementName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"

    print(string.format("|cff00ff00[AC]|r Scanning %d players for achievement: %s", #players, achievementName))

    -- Add all players to scan list
    for _, playerName in ipairs(players) do
        table.insert(AC.playersToScan, playerName)
    end

    -- Start scanning
    AC:ProcessNextPlayerScan()
end

-- Process the next player in the scan queue
function AC:ProcessNextPlayerScan()
    if #AC.playersToScan == 0 then
        -- Scanning complete
        AC:CompleteScan()
        return
    end

    local playerName = table.remove(AC.playersToScan, 1)
    local hasAchievement = AC:PlayerHasAchievement(playerName, AC.currentScanAchievementID)

    if AC.db.settings.enableDebug then
        print(string.format("|cff00ff00[AC Debug]|r %s has achievement: %s", playerName, tostring(hasAchievement)))
    end

    table.insert(AC.playersScanned, playerName)

    if not hasAchievement then
        table.insert(AC.playersMissingAchievement, playerName)
    end

    -- Continue with next player
    C_Timer.After(0.1, function()
        AC:ProcessNextPlayerScan()
    end)
end

-- Complete the group scan and display results
function AC:CompleteScan()
    AC.groupScanInProgress = false

    local achievementName = select(2, GetAchievementInfo(AC.currentScanAchievementID)) or "Unknown Achievement"
    local totalPlayers = #AC.playersScanned
    local missingCount = #AC.playersMissingAchievement

    print(string.format("|cff00ff00[AC]|r Scan complete: %d/%d players missing %s", missingCount, totalPlayers, achievementName))

    if missingCount > 0 then
        print("|cff00ff00[AC]|r Players missing the achievement:")
        for _, playerName in ipairs(AC.playersMissingAchievement) do
            print(string.format("  - %s", playerName))
        end
    else
        print("|cff00ff00[AC]|r All players have the achievement!")
    end

    -- Trigger UI update if settings panel is open
    if AotCCounterSettingsPanel and AotCCounterSettingsPanel:IsVisible() then
        -- The UI update will be handled by the timer in the scan button click
    end
end

-- Get the current allowlist of players missing the active achievement
function AC:GetPlayersMissingActiveAchievement()
    return AC.playersMissingAchievement
end

-- Print the current allowlist to chat
function AC:PrintAllowlist()
    local activeID = AC.db.settings.activeAchievementID
    if not activeID then
        print("|cffff0000[AC]|r No active achievement set")
        return
    end

    local achievementName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"
    local missingCount = #AC.playersMissingAchievement

    if missingCount == 0 then
        print(string.format("|cff00ff00[AC]|r Allowlist: No players missing %s", achievementName))
    else
        print(string.format("|cff00ff00[AC]|r Allowlist for %s (%d players):", achievementName, missingCount))
        for _, playerName in ipairs(AC.playersMissingAchievement) do
            print(string.format("  - %s", playerName))
        end
    end
end

-- Capture pre-kill achievement status for all group members
function AC:CapturePreKillStatus(achievementID)
    if not achievementID then
        achievementID = AC.db.settings.activeAchievementID
    end

    if not achievementID then
        if AC.db.settings.enableDebug then
            print("|cff00ff00[AC Debug]|r No achievement ID provided for pre-kill status")
        end
        return
    end

    -- Initialize pre-kill status table for this achievement
    if not AC.preKillStatus[achievementID] then
        AC.preKillStatus[achievementID] = {}
    end

    local players = AC:GetPlayersInGroup()
    local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"

    if AC.db.settings.enableDebug then
        print(string.format("|cff00ff00[AC Debug]|r Capturing pre-kill status for %s", achievementName))
    end

    for _, playerName in ipairs(players) do
        local hasAchievement = AC:PlayerHasAchievement(playerName, achievementID)
        AC.preKillStatus[achievementID][playerName] = hasAchievement

        if AC.db.settings.enableDebug then
            print(string.format("|cff00ff00[AC Debug]|r Pre-kill: %s had achievement = %s", playerName, tostring(hasAchievement)))
        end
    end
end

-- Clear pre-kill status (call this when leaving instance or resetting)
function AC:ClearPreKillStatus()
    AC.preKillStatus = {}
    if AC.db.settings.enableDebug then
        print("|cff00ff00[AC Debug]|r Pre-kill status cleared")
    end
end




-- Toggle tracked achievement (using achievements object as source of truth)
function AC:ToggleTrackedAchievement(achievementID)
    if AC.db.achievements[achievementID] then
        -- Remove from tracking
        AC.db.achievements[achievementID] = nil
        print(string.format("|cff00ff00[AC]|r Removed achievement %d from tracking", achievementID))
    else
        -- Add to tracking with 0 count
        AC.db.achievements[achievementID] = 0
        print(string.format("|cff00ff00[AC]|r Added achievement %d to tracking", achievementID))
    end
end

-- Show tracked achievements
function AC:ShowTrackedAchievements()
    local activeID = AC.db.settings.activeAchievementID
    local count = 0

    print("|cff00ff00[AC]|r Currently tracked achievements:")
    for achievementID, achievementCount in pairs(AC.db.achievements) do
        local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
        local activeMarker = (achievementID == activeID) and " |cffff8000[ACTIVE]|r" or ""
        print(string.format("  [%d] %s: %d times%s", achievementID, achievementName, achievementCount, activeMarker))
        count = count + 1
    end

    if count == 0 then
        print("|cff00ff00[AC]|r No achievements currently tracked")
    end

    -- Show active achievement info
    if activeID then
        local activeName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"
        local activeCount = AC.db.achievements[activeID] or 0
        print(string.format("|cff00ff00[AC]|r Active display: [%d] %s (%d times)", activeID, activeName, activeCount))
    else
        print("|cff00ff00[AC]|r No active achievement set for display")
    end
end

-- Set active achievement
function AC:SetActiveAchievement(achievementID)
    AC.db.settings.activeAchievementID = achievementID
    local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"

    -- Ensure this achievement is being tracked
    if not AC.db.achievements[achievementID] then
        AC.db.achievements[achievementID] = 0
    end

    print(string.format("|cff00ff00[AC]|r Set active achievement: [%d] %s", achievementID, achievementName))
    AC:UpdateDisplayFrame()
end
-- Create settings panel
function AC:CreateSettingsPanel()
    local panel = CreateFrame("Frame", "AotCCounterSettingsPanel", UIParent)
    panel.name = "AotC Counter"

    -- Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("AotC Counter Settings")

    -- Display Frame Settings Section
    local displayLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    displayLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -30)
    displayLabel:SetText("Display Frame Settings:")

    -- Enable Display Frame setting
    local enableCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    enableCheckbox:SetSize(20, 20)
    enableCheckbox:SetPoint("TOPLEFT", displayLabel, "BOTTOMLEFT", 10, -10)
    enableCheckbox:SetChecked(AC.db.settings.displayFrame.enabled)

    local enableLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    enableLabel:SetPoint("LEFT", enableCheckbox, "RIGHT", 5, 0)
    enableLabel:SetText("Show Display Frame")

    enableCheckbox:SetScript("OnClick", function()
        AC.db.settings.displayFrame.enabled = enableCheckbox:GetChecked()
        if AC.db.settings.displayFrame.enabled then
            if AC.displayFrame then
                AC.displayFrame:Show()
            else
                AC:CreateDisplayFrame()
            end
            print("|cff00ff00[AC]|r Display frame enabled")
        else
            if AC.displayFrame then
                AC.displayFrame:Hide()
            end
            print("|cff00ff00[AC]|r Display frame disabled")
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
    prefixInput:SetText(AC.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX)

    local prefixSaveButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    prefixSaveButton:SetSize(50, 22)
    prefixSaveButton:SetPoint("LEFT", prefixInput, "RIGHT", 5, 0)
    prefixSaveButton:SetText("Save")
    prefixSaveButton:SetScript("OnClick", function()
        local newPrefix = prefixInput:GetText()
        if newPrefix and newPrefix ~= "" then
            AC.db.settings.displayFrame.displayPrefix = newPrefix
            AC:UpdateDisplayFrame()
            print("|cff00ff00[AC]|r Display prefix updated to: '" .. newPrefix .. "'")
        else
            print("|cffff0000[AC]|r Display prefix cannot be empty")
        end
    end)

    local prefixResetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    prefixResetButton:SetSize(50, 22)
    prefixResetButton:SetPoint("LEFT", prefixSaveButton, "RIGHT", 5, 0)
    prefixResetButton:SetText("Reset")
    prefixResetButton:SetScript("OnClick", function()
        AC.db.settings.displayFrame.displayPrefix = DEFAULT_PREFIX
        prefixInput:SetText(DEFAULT_PREFIX)
        AC:UpdateDisplayFrame()
        print("|cff00ff00[AC]|r Display prefix reset to default: '" .. DEFAULT_PREFIX .. "'")
    end)

    -- Font Size setting
    local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", prefixInput, "BOTTOMLEFT", 0, -40)
    fontLabel:SetText("Font Size:")

    local fontSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
    fontSlider:SetSize(150, 20)
    fontSlider:SetPoint("LEFT", fontLabel, "RIGHT", 10, 0)
    fontSlider:SetMinMaxValues(8, 24)
    fontSlider:SetValue(AC.db.settings.displayFrame.fontSize or 12)
    fontSlider:SetValueStep(1)
    fontSlider:SetObeyStepOnDrag(true)

    -- Slider labels (using template's built-in labels)
    fontSlider.Low:SetText("8")
    fontSlider.High:SetText("24")

    fontSlider.Text = fontSlider:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontSlider.Text:SetPoint("LEFT", fontSlider, "RIGHT", 10, 0)
    fontSlider.Text:SetText("Size: " .. (AC.db.settings.displayFrame.fontSize or 12))

    fontSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        AC.db.settings.displayFrame.fontSize = value
        fontSlider.Text:SetText("Size: " .. value)
        AC:UpdateDisplayFrame()
    end)

    -- General Settings Section
    local generalLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    generalLabel:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", -10, -40)
    generalLabel:SetText("General Settings:")

    -- Debug Mode setting
    local debugCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    debugCheckbox:SetSize(20, 20)
    debugCheckbox:SetPoint("TOPLEFT", generalLabel, "BOTTOMLEFT", 10, -10)
    debugCheckbox:SetChecked(AC.db.settings.enableDebug)

    local debugLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    debugLabel:SetPoint("LEFT", debugCheckbox, "RIGHT", 5, 0)
    debugLabel:SetText("Enable Debug Mode")

    debugCheckbox:SetScript("OnClick", function()
        AC.db.settings.enableDebug = debugCheckbox:GetChecked()
        print(string.format("|cff00ff00[AC]|r Debug mode: %s", AC.db.settings.enableDebug and "ON" or "OFF"))
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
        AC:ScanGroupForActiveAchievement()
    end)

    -- Players missing achievement display
    local missingLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    missingLabel:SetPoint("TOPLEFT", scanButton, "BOTTOMLEFT", 0, -10)
    missingLabel:SetText("Players missing active achievement:")
    missingLabel:SetTextColor(1, 1, 1)

    -- Scrollable list for missing players
    local missingScrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    missingScrollFrame:SetSize(300, 80)
    missingScrollFrame:SetPoint("TOPLEFT", missingLabel, "BOTTOMLEFT", 0, -5)

    local missingScrollChild = CreateFrame("Frame", nil, missingScrollFrame)
    missingScrollChild:SetSize(280, 1)
    missingScrollFrame:SetScrollChild(missingScrollChild)

    -- Function to update missing players display
    local function UpdateMissingPlayersDisplay()
        -- Clear existing children
        local children = {missingScrollChild:GetChildren()}
        for i = 1, #children do
            children[i]:Hide()
            children[i]:SetParent(nil)
        end

        local yOffset = 0

        if #AC.playersMissingAchievement == 0 then
            local noPlayersText = missingScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noPlayersText:SetPoint("TOPLEFT", 0, -yOffset)
            noPlayersText:SetText("No players missing achievement (scan needed)")
            noPlayersText:SetTextColor(0.7, 0.7, 0.7)
            yOffset = yOffset + 15
        else
            for _, playerName in ipairs(AC.playersMissingAchievement) do
                local playerText = missingScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                playerText:SetPoint("TOPLEFT", 0, -yOffset)
                playerText:SetText("• " .. playerName)
                playerText:SetTextColor(1, 0.8, 0.8)
                yOffset = yOffset + 15
            end
        end

        missingScrollChild:SetHeight(math.max(yOffset, 1))
        missingScrollFrame:UpdateScrollChildRect()
    end

    -- Update scan button to refresh display
    scanButton:SetScript("OnClick", function()
        AC:ScanGroupForActiveAchievement()
        C_Timer.After(1, UpdateMissingPlayersDisplay) -- Update display after scan
    end)

    -- Initial display update
    UpdateMissingPlayersDisplay()

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
        local activeID = AC.db.settings.activeAchievementID

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
        for achievementID, count in pairs(AC.db.achievements) do
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
                    AC:SetActiveAchievement(achievementID)
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
                AC:ToggleTrackedAchievement(achievementID) -- This will remove it
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
                AC:ToggleTrackedAchievement(achievementID)
                addInput:SetText("") -- Clear input
                UpdateAchievementsTable() -- Refresh table
            else
                print("|cffff0000[AC]|r Invalid achievement ID: " .. achievementID)
            end
        else
            print("|cffff0000[AC]|r Please enter a valid achievement ID")
        end
    end)

    -- Function to update all settings values
    local function UpdateSettingsValues()
        enableCheckbox:SetChecked(AC.db.settings.displayFrame.enabled)
        prefixInput:SetText(AC.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX)
        fontSlider:SetValue(AC.db.settings.displayFrame.fontSize or 12)
        fontSlider.Text:SetText("Size: " .. (AC.db.settings.displayFrame.fontSize or 12))
        debugCheckbox:SetChecked(AC.db.settings.enableDebug)
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
function AC:CreateDisplayFrame()
    if AC.displayFrame then
        return
    end

    -- Don't create if disabled
    if not AC.db.settings.displayFrame.enabled then
        return
    end

    -- Create the main frame
    AC.displayFrame = CreateFrame("Frame", "AotCCounterDisplay", UIParent, "BackdropTemplate")
    AC.displayFrame:SetSize(200, 30)
    AC.displayFrame:SetPoint("CENTER")
    AC.displayFrame:SetClampedToScreen(true)

    -- Set backdrop
    AC.displayFrame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    AC.displayFrame:SetBackdropColor(0, 0, 0, 0.8)

    -- Enable mouse
    AC.displayFrame:EnableMouse(true)
    AC.displayFrame:SetMovable(true)
    AC.displayFrame:RegisterForDrag("LeftButton")

    -- Create text
    local text = AC.displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER")
    text:SetTextColor(1, 1, 1, 1)
    AC.displayFrame.text = text

    -- Mouse handlers
    AC.displayFrame:SetScript("OnMouseDown", function(self, button)
        if IsShiftKeyDown() and button == "LeftButton" then
            self:StartMoving()
        end
    end)

    AC.displayFrame:SetScript("OnMouseUp", function(self, button)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        AC.db.settings.displayFrame.x = x
        AC.db.settings.displayFrame.y = y
    end)

    -- Tooltip
    AC.displayFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("AotC Counter", 1, 1, 1)
        GameTooltip:AddLine("Hold Shift + Drag to move", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    AC.displayFrame:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    -- Show the frame
    AC.displayFrame:Show()

    -- Update the text
    AC:UpdateDisplayFrame()
end

-- Update display frame text
function AC:UpdateDisplayFrame()
    if not AC.displayFrame or not AC.db.settings.displayFrame.enabled then
        return
    end

    local activeID = AC.db.settings.activeAchievementID
    if not activeID then
        AC.displayFrame.text:SetText("No active achievement set")
        return
    end

    local count = AC.db.achievements[activeID] or 0
    local prefix = AC.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX
    local fontSize = AC.db.settings.displayFrame.fontSize or 12

    -- Update font size
    local fontPath, _, fontFlags = AC.displayFrame.text:GetFont()
    AC.displayFrame.text:SetFont(fontPath or "Fonts\\FRIZQT__.TTF", fontSize, fontFlags or "OUTLINE")

    -- Set text
    local displayText = string.format("%s: %d", prefix, count)
    AC.displayFrame.text:SetText(displayText)

    -- Auto-resize frame
    local textWidth = AC.displayFrame.text:GetStringWidth()
    local textHeight = AC.displayFrame.text:GetStringHeight()
    local frameWidth = math.max(textWidth + 20, 80)
    local frameHeight = math.max(textHeight + 12, 20)
    AC.displayFrame:SetSize(frameWidth, frameHeight)
end