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

-- Group scanning variables
BZ.groupScanInProgress = false
BZ.playersToScan = {}
BZ.playersScanned = {}
BZ.playersMissingAchievement = {} -- Allowlist of players who don't have the active achievement
BZ.currentScanAchievementID = nil
BZ.scanCounter = 0
BZ.preKillStatus = {} -- Store pre-kill achievement status for players

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
function BZ:OnAddonLoaded()
    -- Initialize saved variables
    if not BezierDB then
        BezierDB = {}
    end

    -- Migrate old AotCCounterDB to new BezierDB
    if AotCCounterDB and not BezierDB.migrated then
        for key, value in pairs(AotCCounterDB) do
            BezierDB[key] = value
        end
        BezierDB.migrated = true
        print("|cff00ff00Bezier|r Migrated data from AotC Counter")
    end

    -- Migrate old flat settings structure to new nested structure
    if BezierDB.settings then
        -- Migrate displayPrefix from flat to nested structure
        if BezierDB.settings.displayPrefix and not BezierDB.settings.displayFrame then
            BezierDB.settings.displayFrame = {}
        end
        if BezierDB.settings.displayPrefix and not BezierDB.settings.displayFrame.displayPrefix then
            BezierDB.settings.displayFrame.displayPrefix = BezierDB.settings.displayPrefix
        end

        -- Migrate fontSize from flat to nested structure
        if BezierDB.settings.fontSize and not BezierDB.settings.displayFrame.fontSize then
            BezierDB.settings.displayFrame.fontSize = BezierDB.settings.fontSize
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

    deepMerge(BezierDB, defaultDB)

    BZ.db = BezierDB

    print("|cff00ff00Bezier|r loaded. Open Interface Options > AddOns > Bezier to configure.")

    -- Create settings panel
    BZ:CreateSettingsPanel()

    -- Create display frame
    BZ:CreateDisplayFrame()
end

-- Parse achievement message from chat
function BZ:ParseAchievementMessage(message, sender)
    if BZ.db.settings.enableDebug then
        print(string.format("|cff00ff00[BZ Debug]|r Parsing: '%s' from %s", message or "nil", sender or "nil"))
    end

    -- Pattern for achievement messages
    local achievementID = string.match(message, "|Hachievement:(%d+):")
    if achievementID then
        achievementID = tonumber(achievementID)
        local achievementName = select(2, GetAchievementInfo(achievementID))

        if BZ.db.settings.enableDebug then
            print(string.format("|cff00ff00[BZ Debug]|r Found achievement: ID=%d, Name=%s", achievementID, achievementName or "Unknown"))
        end

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

    -- Check if we have pre-kill status for this achievement and player
    local isFirstTime = true
    if BZ.preKillStatus[achievementID] and BZ.preKillStatus[achievementID][playerName] ~= nil then
        -- We have pre-kill data - compare against it
        local hadAchievementBefore = BZ.preKillStatus[achievementID][playerName]
        isFirstTime = not hadAchievementBefore

        if BZ.db.settings.enableDebug then
            print(string.format("|cff00ff00[BZ Debug]|r Pre-kill check for %s: had achievement = %s, counting = %s",
                  playerName, tostring(hadAchievementBefore), tostring(isFirstTime)))
        end
    else
        -- No pre-kill data available - assume it's first time (fallback behavior)
        if BZ.db.settings.enableDebug then
            print(string.format("|cff00ff00[BZ Debug]|r No pre-kill data for %s, assuming first time", playerName))
        end
    end

    -- Only count first-time achievements
    if not isFirstTime then
        if BZ.db.settings.enableDebug then
            print(string.format("|cff00ff00[BZ Debug]|r Skipping alt completion for %s: [%d] %s (already had achievement)",
                  playerName, achievementID, achievementName))
        end
        return
    end

    -- Initialize counter if it doesn't exist
    if not BZ.db.achievements[achievementID] then
        BZ.db.achievements[achievementID] = 0
    end

    -- Increment the counter
    BZ.db.achievements[achievementID] = BZ.db.achievements[achievementID] + 1

    -- Debug output
    if BZ.db.settings.enableDebug then
        print(string.format("|cff00ff00[BZ Debug]|r Recorded first-time achievement for %s: [%d] %s (Total: %d)",
              playerName, achievementID, achievementName, BZ.db.achievements[achievementID]))
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
        -- Group composition changed, could trigger a rescan if needed
        if BZ.db.settings.enableDebug then
            print("|cff00ff00[BZ Debug]|r Group roster updated")
        end

        -- Auto-scan if we have an active achievement and are in a group
        if BZ.db.settings.activeAchievementID and BZ:GetGroupSize() > 1 and not BZ.groupScanInProgress then
            C_Timer.After(2, function() -- Delay to let group settle
                BZ:ScanGroupForActiveAchievement()
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Player entered world, could be a good time to scan if in a group
        if BZ.db.settings.enableDebug then
            print("|cff00ff00[BZ Debug]|r Player entering world")
        end
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
function BZ:PlayerHasAchievement(playerName, achievementID)
    if not achievementID then
        return false
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
        if BZ.db.settings.enableDebug then
            print(string.format("|cff00ff00[BZ Debug]|r Could not find unit for player: %s", playerName))
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

            if BZ.db.settings.enableDebug then
                print(string.format("|cff00ff00[BZ Debug]|r %s achievement status: %s", playerName, tostring(completed)))
            end

            return completed or false
        else
            if BZ.db.settings.enableDebug then
                print(string.format("|cff00ff00[BZ Debug]|r Cannot inspect %s (offline or dead)", playerName))
            end
            return false -- Assume they don't have it if we can't check
        end
    end
end

-- Scan group members for active achievement
function BZ:ScanGroupForActiveAchievement()
    local activeID = BZ.db.settings.activeAchievementID
    if not activeID then
        print("|cffff0000[BZ]|r No active achievement set for scanning")
        return
    end

    if BZ.groupScanInProgress then
        print("|cffff0000[BZ]|r Group scan already in progress")
        return
    end

    BZ.groupScanInProgress = true
    BZ.playersToScan = {}
    BZ.playersScanned = {}
    BZ.playersMissingAchievement = {}
    BZ.currentScanAchievementID = activeID
    BZ.scanCounter = BZ.scanCounter + 1

    local players = BZ:GetPlayersInGroup()
    local achievementName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"

    print(string.format("|cff00ff00[BZ]|r Scanning %d players for achievement: %s", #players, achievementName))

    -- Add all players to scan list
    for _, playerName in ipairs(players) do
        table.insert(BZ.playersToScan, playerName)
    end

    -- Start scanning
    BZ:ProcessNextPlayerScan()
end

-- Process the next player in the scan queue
function BZ:ProcessNextPlayerScan()
    if #BZ.playersToScan == 0 then
        -- Scanning complete
        BZ:CompleteScan()
        return
    end

    local playerName = table.remove(BZ.playersToScan, 1)
    local hasAchievement = BZ:PlayerHasAchievement(playerName, BZ.currentScanAchievementID)

    if BZ.db.settings.enableDebug then
        print(string.format("|cff00ff00[BZ Debug]|r %s has achievement: %s", playerName, tostring(hasAchievement)))
    end

    table.insert(BZ.playersScanned, playerName)

    if not hasAchievement then
        table.insert(BZ.playersMissingAchievement, playerName)
    end

    -- Continue with next player
    C_Timer.After(0.1, function()
        BZ:ProcessNextPlayerScan()
    end)
end

-- Complete the group scan and display results
function BZ:CompleteScan()
    BZ.groupScanInProgress = false

    local achievementName = select(2, GetAchievementInfo(BZ.currentScanAchievementID)) or "Unknown Achievement"
    local totalPlayers = #BZ.playersScanned
    local missingCount = #BZ.playersMissingAchievement

    print(string.format("|cff00ff00[BZ]|r Scan complete: %d/%d players missing %s", missingCount, totalPlayers, achievementName))

    if missingCount > 0 then
        print("|cff00ff00[BZ]|r Players missing the achievement:")
        for _, playerName in ipairs(BZ.playersMissingAchievement) do
            print(string.format("  - %s", playerName))
        end
    else
        print("|cff00ff00[BZ]|r All players have the achievement!")
    end

    -- Trigger UI update if settings panel is open
    if BezierSettingsPanel and BezierSettingsPanel:IsVisible() then
        -- The UI update will be handled by the timer in the scan button click
    end
end

-- Get the current allowlist of players missing the active achievement
function BZ:GetPlayersMissingActiveAchievement()
    return BZ.playersMissingAchievement
end

-- Print the current allowlist to chat
function BZ:PrintAllowlist()
    local activeID = BZ.db.settings.activeAchievementID
    if not activeID then
        print("|cffff0000[BZ]|r No active achievement set")
        return
    end

    local achievementName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"
    local missingCount = #BZ.playersMissingAchievement

    if missingCount == 0 then
        print(string.format("|cff00ff00[BZ]|r Allowlist: No players missing %s", achievementName))
    else
        print(string.format("|cff00ff00[BZ]|r Allowlist for %s (%d players):", achievementName, missingCount))
        for _, playerName in ipairs(BZ.playersMissingAchievement) do
            print(string.format("  - %s", playerName))
        end
    end
end

-- Capture pre-kill achievement status for all group members
function BZ:CapturePreKillStatus(achievementID)
    if not achievementID then
        achievementID = BZ.db.settings.activeAchievementID
    end

    if not achievementID then
        if BZ.db.settings.enableDebug then
            print("|cff00ff00[BZ Debug]|r No achievement ID provided for pre-kill status")
        end
        return
    end

    -- Initialize pre-kill status table for this achievement
    if not BZ.preKillStatus[achievementID] then
        BZ.preKillStatus[achievementID] = {}
    end

    local players = BZ:GetPlayersInGroup()
    local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"

    if BZ.db.settings.enableDebug then
        print(string.format("|cff00ff00[BZ Debug]|r Capturing pre-kill status for %s", achievementName))
    end

    for _, playerName in ipairs(players) do
        local hasAchievement = BZ:PlayerHasAchievement(playerName, achievementID)
        BZ.preKillStatus[achievementID][playerName] = hasAchievement

        if BZ.db.settings.enableDebug then
            print(string.format("|cff00ff00[BZ Debug]|r Pre-kill: %s had achievement = %s", playerName, tostring(hasAchievement)))
        end
    end
end

-- Clear pre-kill status (call this when leaving instance or resetting)
function BZ:ClearPreKillStatus()
    BZ.preKillStatus = {}
    if BZ.db.settings.enableDebug then
        print("|cff00ff00[BZ Debug]|r Pre-kill status cleared")
    end
end




-- Toggle tracked achievement (using achievements object as source of truth)
function BZ:ToggleTrackedAchievement(achievementID)
    if BZ.db.achievements[achievementID] then
        -- Remove from tracking
        BZ.db.achievements[achievementID] = nil
        print(string.format("|cff00ff00[BZ]|r Removed achievement %d from tracking", achievementID))
    else
        -- Add to tracking with 0 count
        BZ.db.achievements[achievementID] = 0
        print(string.format("|cff00ff00[BZ]|r Added achievement %d to tracking", achievementID))
    end
end

-- Show tracked achievements
function BZ:ShowTrackedAchievements()
    local activeID = BZ.db.settings.activeAchievementID
    local count = 0

    print("|cff00ff00[BZ]|r Currently tracked achievements:")
    for achievementID, achievementCount in pairs(BZ.db.achievements) do
        local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
        local activeMarker = (achievementID == activeID) and " |cffff8000[ACTIVE]|r" or ""
        print(string.format("  [%d] %s: %d times%s", achievementID, achievementName, achievementCount, activeMarker))
        count = count + 1
    end

    if count == 0 then
        print("|cff00ff00[BZ]|r No achievements currently tracked")
    end

    -- Show active achievement info
    if activeID then
        local activeName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"
        local activeCount = BZ.db.achievements[activeID] or 0
        print(string.format("|cff00ff00[BZ]|r Active display: [%d] %s (%d times)", activeID, activeName, activeCount))
    else
        print("|cff00ff00[BZ]|r No active achievement set for display")
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

    print(string.format("|cff00ff00[BZ]|r Set active achievement: [%d] %s", achievementID, achievementName))
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
            print("|cff00ff00[BZ]|r Display frame enabled")
        else
            if BZ.displayFrame then
                BZ.displayFrame:Hide()
            end
            print("|cff00ff00[BZ]|r Display frame disabled")
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
            print("|cff00ff00[BZ]|r Display prefix updated to: '" .. newPrefix .. "'")
        else
            print("|cffff0000[BZ]|r Display prefix cannot be empty")
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
        print("|cff00ff00[BZ]|r Display prefix reset to default: '" .. DEFAULT_PREFIX .. "'")
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
    debugCheckbox:SetChecked(BZ.db.settings.enableDebug)

    local debugLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    debugLabel:SetPoint("LEFT", debugCheckbox, "RIGHT", 5, 0)
    debugLabel:SetText("Enable Debug Mode")

    debugCheckbox:SetScript("OnClick", function()
        BZ.db.settings.enableDebug = debugCheckbox:GetChecked()
        print(string.format("|cff00ff00[BZ]|r Debug mode: %s", BZ.db.settings.enableDebug and "ON" or "OFF"))
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

        if #BZ.playersMissingAchievement == 0 then
            local noPlayersText = missingScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noPlayersText:SetPoint("TOPLEFT", 0, -yOffset)
            noPlayersText:SetText("No players missing achievement (scan needed)")
            noPlayersText:SetTextColor(0.7, 0.7, 0.7)
            yOffset = yOffset + 15
        else
            for _, playerName in ipairs(BZ.playersMissingAchievement) do
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
        BZ:ScanGroupForActiveAchievement()
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
                print("|cffff0000[BZ]|r Invalid achievement ID: " .. achievementID)
            end
        else
            print("|cffff0000[BZ]|r Please enter a valid achievement ID")
        end
    end)

    -- Function to update all settings values
    local function UpdateSettingsValues()
        enableCheckbox:SetChecked(BZ.db.settings.displayFrame.enabled)
        prefixInput:SetText(BZ.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX)
        fontSlider:SetValue(BZ.db.settings.displayFrame.fontSize or 12)
        fontSlider.Text:SetText("Size: " .. (BZ.db.settings.displayFrame.fontSize or 12))
        debugCheckbox:SetChecked(BZ.db.settings.enableDebug)
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
    text:SetPoint("CENTER")
    text:SetTextColor(1, 1, 1, 1)
    BZ.displayFrame.text = text

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
        return
    end

    local count = BZ.db.achievements[activeID] or 0
    local prefix = BZ.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX
    local fontSize = BZ.db.settings.displayFrame.fontSize or 12

    -- Update font size
    local fontPath, _, fontFlags = BZ.displayFrame.text:GetFont()
    BZ.displayFrame.text:SetFont(fontPath or "Fonts\\FRIZQT__.TTF", fontSize, fontFlags or "OUTLINE")

    -- Set text
    local displayText = string.format("%s: %d", prefix, count)
    BZ.displayFrame.text:SetText(displayText)

    -- Auto-resize frame
    local textWidth = BZ.displayFrame.text:GetStringWidth()
    local textHeight = BZ.displayFrame.text:GetStringHeight()
    local frameWidth = math.max(textWidth + 20, 80)
    local frameHeight = math.max(textHeight + 12, 20)
    BZ.displayFrame:SetSize(frameWidth, frameHeight)
end