-- Achievement Tracker Addon
-- Tracks achievements earned by party/raid members from chat messages

local addonName = "AchievementTracker"
local AT = {}
_G[addonName] = AT

-- Database structure
AT.db = nil

-- Default database structure
local defaultDB = {
    achievements = {}, -- [achievementID] = count (simple counter)
    settings = {
        enableDebug = false,
        activeAchievementID = 41298, -- Ahead of the Curve: Chrome King Gallywix
        displayPrefix = "AotC this season", -- Customizable prefix for display
        fontSize = 12, -- Font size for display frame
        displayFrame = {
            x = 100,
            y = -100,
            visible = true,
        }
    }
}

-- Event frame
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ACHIEVEMENT")

-- Initialize the addon
function AT:Initialize()
    -- Initialize saved variables
    if not AchievementTrackerDB then
        AchievementTrackerDB = {}
    end

    -- Merge with defaults
    for key, value in pairs(defaultDB) do
        if AchievementTrackerDB[key] == nil then
            AchievementTrackerDB[key] = value
        end
    end

    AT.db = AchievementTrackerDB

    if AT.db.settings.enableDebug then
        print("|cff00ff00Achievement Tracker|r loaded. Type |cffff0000/at help|r for commands.")
    end

    -- Create settings panel
    AT:CreateSettingsPanel()

    -- Create display frame
    AT:CreateDisplayFrame()
end

-- Parse achievement message from chat
function AT:ParseAchievementMessage(message, sender)
    -- Debug: show what we're trying to parse
    if AT.db.settings.enableDebug then
        print(string.format("|cff00ff00[AT]|r Parsing message: '%s'", message))
        print(string.format("|cff00ff00[AT]|r From sender: '%s'", sender))
    end

    -- Look for achievement link patterns - try multiple formats
    local achievementLink = string.match(message, "(|c.-|r)")
    if not achievementLink then
        achievementLink = string.match(message, "(%[.-%])")
    end

    if achievementLink then
        if AT.db.settings.enableDebug then
            print(string.format("|cff00ff00[AT]|r Found link: '%s'", achievementLink))
        end

        -- Extract achievement ID from the link
        local achievementID = string.match(achievementLink, "achievement:(%d+)")
        if achievementID then
            achievementID = tonumber(achievementID)
            local achievementName = string.match(achievementLink, "%[(.+)%]")

            if AT.db.settings.enableDebug then
                print(string.format("|cff00ff00[AT]|r Extracted ID: %d, Name: '%s'", achievementID, achievementName or "nil"))
            end

            return sender, achievementID, achievementName
        else
            -- No achievement ID found in link, try name lookup
            local achievementName = string.match(achievementLink, "%[(.+)%]")
            if achievementName then
                if AT.db.settings.enableDebug then
                    print(string.format("|cff00ff00[AT]|r No ID in link, trying name lookup for: '%s'", achievementName))
                end
                local achievementID = AT:FindAchievementIDByName(achievementName)
                if achievementID then
                    return sender, achievementID, achievementName
                end
            end
        end
    end

    if AT.db.settings.enableDebug then
        print("|cffff0000[AT]|r Failed to parse achievement message")
    end

    return nil
end

-- Cache for achievement name -> ID lookups
AT.achievementNameCache = AT.achievementNameCache or {}

-- Find achievement ID by name (expensive operation, cached)
function AT:FindAchievementIDByName(targetName)
    -- Check cache first
    if AT.achievementNameCache[targetName] then
        return AT.achievementNameCache[targetName]
    end

    if AT.db.settings.enableDebug then
        print(string.format("|cff00ff00[AT]|r Searching for achievement: '%s'", targetName))
    end

    -- Search through achievement categories to find matching name
    local categories = GetCategoryList()
    for _, categoryID in ipairs(categories) do
        local achievements = GetCategoryAchievementList(categoryID)
        for _, achievementID in ipairs(achievements) do
            local _, name = GetAchievementInfo(achievementID)
            if name and name == targetName then
                -- Cache the result
                AT.achievementNameCache[targetName] = achievementID
                if AT.db.settings.enableDebug then
                    print(string.format("|cff00ff00[AT]|r Found achievement ID %d for '%s'", achievementID, targetName))
                end
                return achievementID
            end
        end
    end

    if AT.db.settings.enableDebug then
        print(string.format("|cffff0000[AT]|r Could not find achievement ID for '%s'", targetName))
    end

    return nil
end

-- Check if we should track this player (must be in party/raid)
function AT:ShouldTrackPlayer(playerName)
    -- Always track if we're in a group (since achievement messages only come from group members)
    if IsInGroup() then
        return true
    end

    -- If not in a group, only track ourselves
    local myName = UnitName("player")
    local myServer = GetRealmName()
    local myFullName = myName .. "-" .. myServer

    return playerName == myName or playerName == myFullName
end

-- Check if we should track this achievement
function AT:ShouldTrackAchievement(achievementID)
    -- Always track the active achievement
    if achievementID == AT.db.settings.activeAchievementID then
        return true
    end

    -- Also track any achievement that's already in our database (previously tracked)
    return AT.db.achievements[achievementID] ~= nil
end

-- Record achievement
function AT:RecordAchievement(playerName, achievementID, achievementName)
    if AT.db.settings.enableDebug then
        print(string.format("|cff00ff00[AT]|r Attempting to record: %s earned [%s] (ID: %d)", playerName, achievementName, achievementID))
    end

    if not AT:ShouldTrackPlayer(playerName) then
        if AT.db.settings.enableDebug then
            print(string.format("|cffff0000[AT]|r Not tracking player: %s", playerName))
        end
        return
    end

    if not AT:ShouldTrackAchievement(achievementID) then
        if AT.db.settings.enableDebug then
            print(string.format("|cffff0000[AT]|r Not tracking achievement ID: %d", achievementID))
        end
        return
    end

    -- Initialize achievement counter if needed
    if not AT.db.achievements[achievementID] then
        AT.db.achievements[achievementID] = 0
    end

    -- Increment the counter
    AT.db.achievements[achievementID] = AT.db.achievements[achievementID] + 1

    if AT.db.settings.enableDebug then
        print(string.format("|cff00ff00[AT]|r Recorded: %s earned [%s] (ID: %d) - Total count: %d",
              playerName, achievementName, achievementID, AT.db.achievements[achievementID]))
    end

    -- Update display frame if this is the active achievement
    if AT.db.settings.activeAchievementID == achievementID then
        AT:UpdateDisplayFrame()
    end
end

-- Try to get a player's server name
function AT:GetPlayerServer(playerName)
    -- Check if they're in our party/raid and get their server
    for i = 1, GetNumGroupMembers() do
        local unit = IsInRaid() and ("raid" .. i) or ("party" .. (i - 1))
        if i == 1 and not IsInRaid() then
            unit = "player"
        end

        local name = UnitName(unit)
        if name == playerName then
            local server = select(2, UnitName(unit))
            return server
        end
    end

    return nil -- Couldn't determine server
end



-- Event handler
function AT:OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            AT:Initialize()
        end
    elseif event == "CHAT_MSG_ACHIEVEMENT" then
        local message, sender, language, channelString, target, flags, unknown, channelNumber, channelName, unknown2, counter, guid = ...

        local playerName, achievementID, achievementName = AT:ParseAchievementMessage(message, sender)

        if playerName and achievementID and achievementName then
            AT:RecordAchievement(playerName, achievementID, achievementName)
        end
    end
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    AT:OnEvent(event, ...)
end)

-- Slash commands
SLASH_ACHIEVEMENTTRACKER1 = "/at"
SLASH_ACHIEVEMENTTRACKER2 = "/achievementtracker"

function SlashCmdList.ACHIEVEMENTTRACKER(msg)
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, word)
    end

    local command = args[1] and string.lower(args[1]) or "help"

    -- Debug output
    if command == "show" then
        print("|cff00ff00[AT Debug]|r Received 'show' command")
    end

    if command == "help" then
        print("|cff00ff00Achievement Tracker Commands:|r")
        print("|cffff0000/at stats|r - Show overall achievement stats")
        print("|cffff0000/at debug|r - Toggle debug mode")
        print("|cffff0000/at track <achievementID>|r - Add/remove tracked achievement")
        print("|cffff0000/at config|r - Open settings panel")
        print("|cffff0000/at list|r - Show currently tracked achievements")


        print("|cffff0000/at active <achievementID>|r - Set active achievement for display")
        print("|cffff0000/at show|r - Show/hide the display frame")
        print("|cffff0000/at reset|r - Reset display frame position")

    elseif command == "stats" then
        AT:ShowOverallStats()

    elseif command == "debug" then
        AT.db.settings.enableDebug = not AT.db.settings.enableDebug
        print(string.format("|cff00ff00[AT]|r Debug mode: %s",
              AT.db.settings.enableDebug and "ON" or "OFF"))

    elseif command == "track" then
        local achievementID = tonumber(args[2])
        if achievementID then
            AT:ToggleTrackedAchievement(achievementID)
        else
            print("|cffff0000Usage:|r /at track <achievementID>")
        end

    elseif command == "list" then
        AT:ShowTrackedAchievements()

    elseif command == "config" then
        -- Open the settings panel
        if Settings and Settings.OpenToCategory then
            Settings.OpenToCategory("Achievement Tracker")
        else
            -- Fallback for older versions
            InterfaceOptionsFrame_OpenToCategory("Achievement Tracker")
            InterfaceOptionsFrame_OpenToCategory("Achievement Tracker") -- Call twice for reliability
        end





    elseif command == "active" then
        local achievementID = tonumber(args[2])
        if achievementID then
            AT:SetActiveAchievement(achievementID)
        else
            print("|cffff0000Usage:|r /at active <achievementID>")
        end

    elseif command == "show" then
        AT:ToggleDisplayFrame()

    elseif command == "reset" then
        AT:ResetDisplayFrame()

    else
        print("|cffff0000Unknown command.|r Type |cffff0000/at help|r for help.")
    end
end

-- Utility functions
function AT:ShowOverallStats()
    local totalAchievements = 0
    local totalCount = 0
    local activeID = AT.db.settings.activeAchievementID

    for achievementID, count in pairs(AT.db.achievements) do
        totalAchievements = totalAchievements + 1
        totalCount = totalCount + count
    end

    if totalAchievements == 0 then
        print("|cff00ff00[AT]|r No achievements recorded yet.")
        return
    end

    print(string.format("|cff00ff00[AT]|r Achievement Statistics (%d achievements, %d total):",
          totalAchievements, totalCount))

    -- Show breakdown by achievement (sorted by count, highest first)
    local sortedAchievements = {}
    for achievementID, count in pairs(AT.db.achievements) do
        table.insert(sortedAchievements, {id = achievementID, count = count})
    end

    table.sort(sortedAchievements, function(a, b) return a.count > b.count end)

    for _, achievement in ipairs(sortedAchievements) do
        local achievementName = select(2, GetAchievementInfo(achievement.id)) or "Unknown Achievement"
        local activeMarker = (achievement.id == activeID) and " |cffff8000[ACTIVE]|r" or ""
        print(string.format("  [%d] %s: %d times%s", achievement.id, achievementName, achievement.count, activeMarker))
    end
end
-- Toggle tracked achievement (using achievements object as source of truth)
function AT:ToggleTrackedAchievement(achievementID)
    if AT.db.achievements[achievementID] then
        -- Remove from tracking
        AT.db.achievements[achievementID] = nil
        if AT.db.settings.enableDebug then
            local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
            print(string.format("|cff00ff00[AT]|r Removed achievement %d (%s) from tracking", achievementID, achievementName))
        end
    else
        -- Add to tracking with 0 count
        AT.db.achievements[achievementID] = 0
        if AT.db.settings.enableDebug then
            local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
            print(string.format("|cff00ff00[AT]|r Added achievement %d (%s) to tracking", achievementID, achievementName))
        end
    end
end

-- Show tracked achievements
function AT:ShowTrackedAchievements()
    local activeID = AT.db.settings.activeAchievementID
    local count = 0

    print("|cff00ff00[AT]|r Currently tracked achievements:")
    for achievementID, achievementCount in pairs(AT.db.achievements) do
        local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
        local activeMarker = (achievementID == activeID) and " |cffff8000[ACTIVE]|r" or ""
        print(string.format("  [%d] %s: %d times%s", achievementID, achievementName, achievementCount, activeMarker))
        count = count + 1
    end

    if count == 0 then
        print("|cff00ff00[AT]|r No achievements currently tracked")
    end

    -- Show active achievement info
    if activeID then
        local activeName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"
        local activeCount = AT.db.achievements[activeID] or 0
        print(string.format("|cff00ff00[AT]|r Active display: [%d] %s (%d times)", activeID, activeName, activeCount))
    else
        print("|cff00ff00[AT]|r No active achievement set for display")
    end
end





-- Create settings panel
function AT:CreateSettingsPanel()
    local panel = CreateFrame("Frame", "AchievementTrackerSettingsPanel", UIParent)
    panel.name = "Achievement Tracker"

    -- Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Achievement Tracker Settings")

    -- Stats display
    local statsLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    statsLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
    statsLabel:SetText("Current Statistics:")

    local statsText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    statsText:SetPoint("TOPLEFT", statsLabel, "BOTTOMLEFT", 0, -10)
    statsText:SetJustifyH("LEFT")

    -- Update stats function
    local function UpdateStats()
        local totalAchievements = 0
        local totalCount = 0
        local statsLines = {}
        local activeID = AT.db.settings.activeAchievementID

        -- Calculate totals
        for achievementID, count in pairs(AT.db.achievements) do
            totalAchievements = totalAchievements + 1
            totalCount = totalCount + count
        end

        if totalAchievements == 0 then
            table.insert(statsLines, "No achievements recorded yet.")
        else
            table.insert(statsLines, string.format("Achievement Statistics (%d achievements, %d total):", totalAchievements, totalCount))
            table.insert(statsLines, "")

            -- Sort achievements by count (highest first)
            local sortedAchievements = {}
            for achievementID, count in pairs(AT.db.achievements) do
                table.insert(sortedAchievements, {id = achievementID, count = count})
            end

            table.sort(sortedAchievements, function(a, b) return a.count > b.count end)

            for _, achievement in ipairs(sortedAchievements) do
                local achievementName = select(2, GetAchievementInfo(achievement.id)) or "Unknown"
                local activeMarker = (achievement.id == activeID) and " [ACTIVE]" or ""
                table.insert(statsLines, string.format("[%d] %s: %d times%s",
                    achievement.id, achievementName, achievement.count, activeMarker))
            end
        end

        -- Add active achievement info at the bottom
        if activeID then
            local activeName = select(2, GetAchievementInfo(activeID)) or "Unknown Achievement"
            local count = AT.db.achievements[activeID] or 0
            table.insert(statsLines, "")
            table.insert(statsLines, string.format("Active Display: [%d] %s (%d times)", activeID, activeName, count))
        end

        statsText:SetText(table.concat(statsLines, "\n"))
    end

    -- Display prefix settings
    local prefixLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    prefixLabel:SetPoint("TOPLEFT", statsText, "BOTTOMLEFT", 0, -30)
    prefixLabel:SetText("Display Text Prefix:")

    -- Input field for prefix
    local prefixInput = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    prefixInput:SetSize(200, 20)
    prefixInput:SetPoint("TOPLEFT", prefixLabel, "BOTTOMLEFT", 0, -5)
    prefixInput:SetAutoFocus(false)

    -- Update input field when panel is shown
    local function UpdatePrefixInput()
        prefixInput:SetText(AT.db.settings.displayPrefix or "AotC this season")
    end

    -- Save button
    local saveButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    saveButton:SetSize(60, 22)
    saveButton:SetPoint("LEFT", prefixInput, "RIGHT", 10, 0)
    saveButton:SetText("Save")
    saveButton:SetScript("OnClick", function()
        local newPrefix = prefixInput:GetText()
        if newPrefix and newPrefix ~= "" then
            AT.db.settings.displayPrefix = newPrefix
            AT:UpdateDisplayFrame()
                if AT.db.settings.enableDebug then
                print(string.format("|cff00ff00[AT]|r Display prefix updated to: '%s'", newPrefix))
            end
        end
    end)

    -- Reset button
    local resetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetButton:SetSize(60, 22)
    resetButton:SetPoint("LEFT", saveButton, "RIGHT", 5, 0)
    resetButton:SetText("Reset")
    resetButton:SetScript("OnClick", function()
        AT.db.settings.displayPrefix = "AotC this season"
        prefixInput:SetText("AotC this season")
        AT:UpdateDisplayFrame()
        if AT.db.settings.enableDebug then
            print("|cff00ff00[AT]|r Display prefix reset to default")
        end
    end)

    -- Font size settings
    local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fontLabel:SetPoint("TOPLEFT", prefixInput, "BOTTOMLEFT", 0, -30)
    fontLabel:SetText("Font Size:")

    -- Font size slider
    local fontSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
    fontSlider:SetSize(200, 20)
    fontSlider:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -10)
    fontSlider:SetMinMaxValues(8, 24)
    fontSlider:SetValue(AT.db.settings.fontSize or 12)
    fontSlider:SetValueStep(1)
    fontSlider:SetObeyStepOnDrag(true)

    -- Slider labels
    fontSlider.Low = fontSlider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fontSlider.Low:SetPoint("TOPLEFT", fontSlider, "BOTTOMLEFT", 0, 3)
    fontSlider.Low:SetText("8")

    fontSlider.High = fontSlider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fontSlider.High:SetPoint("TOPRIGHT", fontSlider, "BOTTOMRIGHT", 0, 3)
    fontSlider.High:SetText("24")

    fontSlider.Text = fontSlider:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontSlider.Text:SetPoint("TOP", fontSlider, "BOTTOM", 0, -15)
    fontSlider.Text:SetText("Size: " .. (AT.db.settings.fontSize or 12))

    -- Slider event handler
    fontSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5) -- Round to nearest integer
        AT.db.settings.fontSize = value
        fontSlider.Text:SetText("Size: " .. value)
        AT:UpdateDisplayFrame()
    end)

    -- Achievement Management section
    local achievementLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    achievementLabel:SetPoint("TOPLEFT", fontSlider, "BOTTOMLEFT", 0, -50)
    achievementLabel:SetText("Achievement Management:")

    -- Add achievement input
    local addLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    addLabel:SetPoint("TOPLEFT", achievementLabel, "BOTTOMLEFT", 0, -10)
    addLabel:SetText("Add Achievement ID:")

    local addInput = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    addInput:SetSize(100, 20)
    addInput:SetPoint("TOPLEFT", addLabel, "BOTTOMLEFT", 0, -5)
    addInput:SetAutoFocus(false)
    addInput:SetNumeric(true)

    local addButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    addButton:SetSize(60, 22)
    addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
    addButton:SetText("Add")
    addButton:SetScript("OnClick", function()
        local achievementID = tonumber(addInput:GetText())
        if achievementID then
            AT:ToggleTrackedAchievement(achievementID)
            addInput:SetText("")
            UpdateStats() -- Refresh the display
        end
    end)

    -- Tracked achievements list with active selection
    local trackedLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    trackedLabel:SetPoint("TOPLEFT", addInput, "BOTTOMLEFT", 0, -20)
    trackedLabel:SetText("Currently Tracked:")

    -- Scrollable list for tracked achievements
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(300, 120)
    scrollFrame:SetPoint("TOPLEFT", trackedLabel, "BOTTOMLEFT", 0, -5)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(280, 1)
    scrollFrame:SetScrollChild(scrollChild)

    -- Function to update the tracked achievements list
    local function UpdateTrackedList()
        -- Clear existing children
        for i = 1, scrollChild:GetNumChildren() do
            local child = select(i, scrollChild:GetChildren())
            child:Hide()
            child:SetParent(nil)
        end

        local yOffset = 0
        local activeID = AT.db.settings.activeAchievementID

        for achievementID, count in pairs(AT.db.achievements) do
            local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"

            -- Achievement frame
            local achievementFrame = CreateFrame("Frame", nil, scrollChild)
            achievementFrame:SetSize(280, 25)
            achievementFrame:SetPoint("TOPLEFT", 0, -yOffset)

            -- Achievement text
            local achievementText = achievementFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            achievementText:SetPoint("LEFT", 5, 0)
            achievementText:SetSize(180, 20)
            achievementText:SetJustifyH("LEFT")
            local isActive = (achievementID == activeID)
            local color = isActive and "|cffff8000" or "|cffffffff"
            local activeMarker = isActive and " [ACTIVE]" or ""
            achievementText:SetText(string.format("%s[%d] %s: %d%s|r", color, achievementID, achievementName, count, activeMarker))

            -- Set Active button
            local setActiveButton = CreateFrame("Button", nil, achievementFrame, "UIPanelButtonTemplate")
            setActiveButton:SetSize(60, 20)
            setActiveButton:SetPoint("RIGHT", -70, 0)
            setActiveButton:SetText(isActive and "Active" or "Set Active")
            setActiveButton:SetEnabled(not isActive)
            setActiveButton:SetScript("OnClick", function()
                AT:SetActiveAchievement(achievementID)
                UpdateTrackedList() -- Refresh the list
                AT:UpdateDisplayFrame() -- Update the display
            end)

            -- Remove button
            local removeButton = CreateFrame("Button", nil, achievementFrame, "UIPanelButtonTemplate")
            removeButton:SetSize(60, 20)
            removeButton:SetPoint("RIGHT", -5, 0)
            removeButton:SetText("Remove")
            removeButton:SetScript("OnClick", function()
                AT:ToggleTrackedAchievement(achievementID)
                UpdateTrackedList() -- Refresh the list
                UpdateStats() -- Refresh stats
            end)

            yOffset = yOffset + 25
        end

        scrollChild:SetHeight(math.max(yOffset, 1))
    end

    -- Clear data section
    local clearLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    clearLabel:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT", 0, -30)
    clearLabel:SetText("Danger Zone:")

    local clearWarning = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    clearWarning:SetPoint("TOPLEFT", clearLabel, "BOTTOMLEFT", 0, -10)
    clearWarning:SetText("This will permanently delete ALL tracked achievement data!")
    clearWarning:SetTextColor(1, 0.5, 0.5) -- Light red

    -- Clear button
    local clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearButton:SetSize(150, 25)
    clearButton:SetPoint("TOPLEFT", clearWarning, "BOTTOMLEFT", 0, -10)
    clearButton:SetText("Clear All Data")

    -- Confirmation state
    local confirmationPending = false

    clearButton:SetScript("OnClick", function()
        if not confirmationPending then
            -- First click - ask for confirmation
            confirmationPending = true
            clearButton:SetText("Click Again to Confirm")
            clearButton:SetScript("OnUpdate", function(self, elapsed)
                -- Reset after 5 seconds
                self.timer = (self.timer or 0) + elapsed
                if self.timer >= 5 then
                    confirmationPending = false
                    clearButton:SetText("Clear All Data")
                    clearButton:SetScript("OnUpdate", nil)
                    self.timer = nil
                end
            end)
        else
            -- Second click - actually clear
            AT.db.achievements = {}
            confirmationPending = false
            clearButton:SetText("Clear All Data")
            clearButton:SetScript("OnUpdate", nil)
            UpdateStats()
            if AT.db.settings.enableDebug then
                print("|cff00ff00[AT]|r All achievement data has been cleared.")
            end
        end
    end)

    -- Update stats when panel is shown and set up auto-refresh
    panel:SetScript("OnShow", function()
        UpdateStats()
        UpdatePrefixInput() -- Update the prefix input field
        UpdateTrackedList() -- Update the tracked achievements list
        -- Set up auto-refresh timer
        panel.refreshTimer = C_Timer.NewTicker(2, function()
            UpdateStats()
            UpdateTrackedList()
        end) -- Update every 2 seconds
    end)

    -- Clean up timer when panel is hidden
    panel:SetScript("OnHide", function()
        if panel.refreshTimer then
            panel.refreshTimer:Cancel()
            panel.refreshTimer = nil
        end
    end)

    -- Add to Interface Options (support both old and new APIs)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        -- New Settings API (11.0+)
        local category = Settings.RegisterCanvasLayoutCategory(panel, "Achievement Tracker")
        Settings.RegisterAddOnCategory(category)
    else
        -- Old Interface Options API (pre-11.0)
        InterfaceOptions_AddCategory(panel)
    end
end

-- Create the on-screen display frame (copied exactly from BestFPS pattern)
function AT:CreateDisplayFrame()
    if AT.displayFrame then
        print("|cff00ff00[AT]|r Display frame already exists")
        return
    end

    print("|cff00ff00[AT]|r Creating display frame using BestFPS pattern...")

    -- Create the main frame exactly like BestFPS does
    AT.displayFrame = CreateFrame("Frame", "AchievementTrackerDisplay", UIParent, "BackdropTemplate")
    AT.displayFrame:SetSize(200, 30)
    AT.displayFrame:SetPoint("CENTER")
    AT.displayFrame:SetClampedToScreen(true)

    -- Set backdrop exactly like BestFPS
    AT.displayFrame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    AT.displayFrame:SetBackdropColor(0, 0, 0, 0.8)

    -- Enable mouse exactly like BestFPS
    AT.displayFrame:EnableMouse(true)
    AT.displayFrame:SetMovable(true)
    AT.displayFrame:RegisterForDrag("LeftButton")

    -- Create text
    local text = AT.displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER")
    text:SetTextColor(1, 1, 1, 1)
    AT.displayFrame.text = text

    -- Mouse handlers exactly like BestFPS
    local function OnMouseDown(self, button)
        if IsShiftKeyDown() and button == "LeftButton" then
            self:StartMoving()
        end
    end

    local function OnMouseUp(self, button)
        self:StopMovingOrSizing()
        -- Save position
        local point, _, _, x, y = self:GetPoint()
        AT.db.settings.displayFrame.x = x
        AT.db.settings.displayFrame.y = y
    end

    -- Tooltip handlers exactly like BestFPS
    local function OnEnter(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Achievement Tracker", 1, 1, 1)
        GameTooltip:AddLine("Hold |cffffffffShift|r + Drag to move", nil, nil, nil, true)
        GameTooltip:Show()
    end

    local function OnLeave(self)
        GameTooltip:Hide()
    end

    -- Attach scripts exactly like BestFPS
    AT.displayFrame:SetScript("OnMouseDown", OnMouseDown)
    AT.displayFrame:SetScript("OnMouseUp", OnMouseUp)
    AT.displayFrame:SetScript("OnEnter", OnEnter)
    AT.displayFrame:SetScript("OnLeave", OnLeave)

    -- Show the frame
    AT.displayFrame:Show()

    -- Update the text
    AT:UpdateDisplayFrame()

    if AT.db.settings.enableDebug then
        print("|cff00ff00[AT]|r Display frame created successfully using BestFPS pattern!")
    end
end

-- Update the display frame text
function AT:UpdateDisplayFrame()
    if not AT.displayFrame then
        return
    end

    local activeID = AT.db.settings.activeAchievementID
    if not activeID then
        AT.displayFrame.text:SetText("No active achievement set")
        -- Resize frame for this text
        local textWidth = AT.displayFrame.text:GetStringWidth()
        local textHeight = AT.displayFrame.text:GetStringHeight()
        AT.displayFrame:SetSize(textWidth + 20, textHeight + 12)
        return
    end

    local count = AT.db.achievements[activeID] or 0
    local prefix = AT.db.settings.displayPrefix or "AotC this season"
    local fontSize = AT.db.settings.fontSize or 12

    -- Update font size
    local fontPath, _, fontFlags = AT.displayFrame.text:GetFont()
    AT.displayFrame.text:SetFont(fontPath or "Fonts\\FRIZQT__.TTF", fontSize, fontFlags or "OUTLINE")

    -- Format the display text with custom prefix
    local displayText = string.format("%s: %d", prefix, count)
    AT.displayFrame.text:SetText(displayText)

    -- Auto-resize frame based on text dimensions
    local textWidth = AT.displayFrame.text:GetStringWidth()
    local textHeight = AT.displayFrame.text:GetStringHeight()

    -- Add padding around the text (10px horizontal, 6px vertical)
    local frameWidth = textWidth + 20
    local frameHeight = textHeight + 12

    -- Set minimum size to prevent frame from being too small
    frameWidth = math.max(frameWidth, 80)
    frameHeight = math.max(frameHeight, 20)

    AT.displayFrame:SetSize(frameWidth, frameHeight)
end

-- Set the active achievement for display
function AT:SetActiveAchievement(achievementID)
    AT.db.settings.activeAchievementID = achievementID
    local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
    if AT.db.settings.enableDebug then
        print(string.format("|cff00ff00[AT]|r Set active achievement: [%d] %s", achievementID, achievementName))
    end
    AT:UpdateDisplayFrame()
end

-- Toggle display frame visibility
function AT:ToggleDisplayFrame()
    if AT.db.settings.enableDebug then
        print("|cff00ff00[AT]|r ToggleDisplayFrame called")
    end

    if not AT.displayFrame then
        if AT.db.settings.enableDebug then
            print("|cff00ff00[AT]|r Creating display frame...")
        end
        AT:CreateDisplayFrame()
        return
    end

    if AT.displayFrame:IsShown() then
        AT.displayFrame:Hide()
        AT.db.settings.displayFrame.visible = false
        if AT.db.settings.enableDebug then
            print("|cff00ff00[AT]|r Display frame hidden")
        end
    else
        AT.displayFrame:Show()
        AT.db.settings.displayFrame.visible = true
        if AT.db.settings.enableDebug then
            print("|cff00ff00[AT]|r Display frame shown")
        end
    end
end

-- Reset display frame position
function AT:ResetDisplayFrame()
    AT.db.settings.displayFrame.x = 100
    AT.db.settings.displayFrame.y = -100
    if AT.displayFrame then
        AT.displayFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -100)
    end
    if AT.db.settings.enableDebug then
        print("|cff00ff00[AT]|r Display frame position reset")
    end
end
