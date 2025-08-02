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
    rawData = {}, -- Store all raw achievement data for analysis
    settings = {
        enableDebug = false,
        trackedAchievements = {}, -- specific achievement IDs to track (empty = track all)
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

    -- Migrate old data format to new format
    AT:MigrateData()

    print("|cff00ff00Achievement Tracker|r loaded. Type |cffff0000/at help|r for commands.")

    -- Create settings panel
    AT:CreateSettingsPanel()
end

-- Migrate old data format to new format
function AT:MigrateData()
    local migrated = false

    for achievementID, data in pairs(AT.db.achievements) do
        -- Check if this is old format (table with player data) vs new format (number)
        if type(data) == "table" then
            -- Count how many players had this achievement
            local count = 0
            for playerKey, timestamp in pairs(data) do
                count = count + 1
            end

            -- Replace with simple counter
            AT.db.achievements[achievementID] = count
            migrated = true

            if AT.db.settings.enableDebug then
                local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown"
                print(string.format("|cff00ff00[AT]|r Migrated [%d] %s: %d players -> %d count",
                    achievementID, achievementName, count, count))
            end
        end
    end

    if migrated then
        print("|cff00ff00[AT]|r Data migrated from old format to new simple counter format.")
    end
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
    if #AT.db.settings.trackedAchievements == 0 then
        return true -- Track all achievements if no specific ones are set
    end

    for _, id in ipairs(AT.db.settings.trackedAchievements) do
        if id == achievementID then
            return true
        end
    end

    return false
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

-- Capture all raw achievement data for analysis
function AT:CaptureRawAchievementData(event, message, sender, language, channelString, target, flags, unknown, channelNumber, channelName, unknown2, counter, guid)
    -- Initialize raw data storage
    if not AT.db.rawData then
        AT.db.rawData = {}
    end

    local timestamp = time()
    local entry = {
        timestamp = timestamp,
        event = event,
        message = message,
        sender = sender,
        language = language,
        channelString = channelString,
        target = target,
        flags = flags,
        unknown = unknown,
        channelNumber = channelNumber,
        channelName = channelName,
        unknown2 = unknown2,
        counter = counter,
        guid = guid,
        -- Additional context
        playerServer = GetRealmName(),
        isInParty = IsInGroup(LE_PARTY_CATEGORY_HOME),
        isInRaid = IsInRaid(LE_PARTY_CATEGORY_HOME),
        groupSize = GetNumGroupMembers(),
    }

    -- Try to extract achievement info
    local playerName, achievementID, achievementName = AT:ParseAchievementMessage(message, sender)
    if achievementID then
        entry.parsedPlayerName = playerName
        entry.parsedAchievementID = achievementID
        entry.parsedAchievementName = achievementName

        -- Get additional achievement info from API
        local id, name, points, completed, month, day, year, description, flags, icon, rewardText, isGuild, wasEarnedByMe, earnedBy = GetAchievementInfo(achievementID)
        entry.apiInfo = {
            id = id,
            name = name,
            points = points,
            completed = completed,
            month = month,
            day = day,
            year = year,
            description = description,
            flags = flags,
            icon = icon,
            rewardText = rewardText,
            isGuild = isGuild,
            wasEarnedByMe = wasEarnedByMe,
            earnedBy = earnedBy
        }
    end

    -- Store with unique key
    local key = timestamp .. "_" .. (counter or 0)
    AT.db.rawData[key] = entry

    if AT.db.settings.enableDebug then
        print(string.format("|cff00ff00[AT Debug]|r Raw data captured: %s", key))
        print(string.format("  Message: %s", message or "nil"))
        print(string.format("  Sender: %s", sender or "nil"))
        print(string.format("  GUID: %s", guid or "nil"))
    end
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

        -- Capture ALL the raw data first
        AT:CaptureRawAchievementData(event, message, sender, language, channelString, target, flags, unknown, channelNumber, channelName, unknown2, counter, guid)

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
    
    if command == "help" then
        print("|cff00ff00Achievement Tracker Commands:|r")
        print("|cffff0000/at stats|r - Show overall achievement stats")
        print("|cffff0000/at debug|r - Toggle debug mode")
        print("|cffff0000/at track <achievementID>|r - Add/remove tracked achievement")
        print("|cffff0000/at config|r - Open settings panel")
        print("|cffff0000/at rawdata [count]|r - Show recent raw achievement data")
        print("|cffff0000/at list|r - Show currently tracked achievements")

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

    elseif command == "config" then
        -- Open the settings panel
        if Settings and Settings.OpenToCategory then
            Settings.OpenToCategory("Achievement Tracker")
        else
            -- Fallback for older versions
            InterfaceOptionsFrame_OpenToCategory("Achievement Tracker")
            InterfaceOptionsFrame_OpenToCategory("Achievement Tracker") -- Call twice for reliability
        end

    elseif command == "rawdata" then
        local count = tonumber(args[2]) or 5
        AT:ShowRawData(count)

    elseif command == "list" then
        AT:ShowTrackedAchievements()

    else
        print("|cffff0000Unknown command.|r Type |cffff0000/at help|r for help.")
    end
end

-- Utility functions
function AT:ShowOverallStats()
    local totalAchievements = 0
    local totalCount = 0

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
        print(string.format("  [%d] %s: %d times", achievement.id, achievementName, achievement.count))
    end
end

function AT:ToggleTrackedAchievement(achievementID)
    local tracked = AT.db.settings.trackedAchievements
    local found = false

    for i, id in ipairs(tracked) do
        if id == achievementID then
            table.remove(tracked, i)
            found = true
            break
        end
    end

    local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"

    if not found then
        table.insert(tracked, achievementID)
        print(string.format("|cff00ff00[AT]|r Added achievement %d (%s) to tracking list", achievementID, achievementName))
    else
        print(string.format("|cff00ff00[AT]|r Removed achievement %d (%s) from tracking list", achievementID, achievementName))
    end

    -- Show current tracking status
    if #tracked == 0 then
        print("|cff00ff00[AT]|r Now tracking ALL achievements")
    else
        print(string.format("|cff00ff00[AT]|r Now tracking %d specific achievements", #tracked))
    end
end

function AT:ShowTrackedAchievements()
    local tracked = AT.db.settings.trackedAchievements

    if #tracked == 0 then
        print("|cff00ff00[AT]|r Currently tracking ALL achievements")
    else
        print(string.format("|cff00ff00[AT]|r Currently tracking %d specific achievements:", #tracked))
        for _, achievementID in ipairs(tracked) do
            local achievementName = select(2, GetAchievementInfo(achievementID)) or "Unknown Achievement"
            print(string.format("  [%d] %s", achievementID, achievementName))
        end
    end
end

-- Show raw achievement data for analysis
function AT:ShowRawData(count)
    if not AT.db.rawData then
        print("|cffff0000[AT]|r No raw data captured yet.")
        return
    end

    -- Sort by timestamp (newest first)
    local sortedKeys = {}
    for key, _ in pairs(AT.db.rawData) do
        table.insert(sortedKeys, key)
    end

    table.sort(sortedKeys, function(a, b)
        local timestampA = AT.db.rawData[a].timestamp
        local timestampB = AT.db.rawData[b].timestamp
        return timestampA > timestampB
    end)

    print(string.format("|cff00ff00[AT] Raw Achievement Data (showing %d most recent):|r", math.min(count, #sortedKeys)))

    for i = 1, math.min(count, #sortedKeys) do
        local key = sortedKeys[i]
        local data = AT.db.rawData[key]

        print(string.format("|cffff8800Entry %d:|r %s", i, key))
        print(string.format("  Event: %s", data.event or "nil"))
        print(string.format("  Message: %s", data.message or "nil"))
        print(string.format("  Sender: %s", data.sender or "nil"))
        print(string.format("  GUID: %s", data.guid or "nil"))
        print(string.format("  Language: %s", data.language or "nil"))
        print(string.format("  Channel: %s", data.channelString or "nil"))
        print(string.format("  Flags: %s", tostring(data.flags)))
        print(string.format("  Group Info: Party=%s, Raid=%s, Size=%d",
              tostring(data.isInParty), tostring(data.isInRaid), data.groupSize or 0))

        if data.parsedAchievementID then
            print(string.format("  Parsed: Player=%s, ID=%d, Name=%s",
                  data.parsedPlayerName or "nil", data.parsedAchievementID, data.parsedAchievementName or "nil"))
        end

        if data.apiInfo then
            print(string.format("  API Info: ID=%s, Name=%s, Points=%s, Guild=%s",
                  tostring(data.apiInfo.id), data.apiInfo.name or "nil",
                  tostring(data.apiInfo.points), tostring(data.apiInfo.isGuild)))
        end

        print("") -- Empty line for readability
    end

    print(string.format("|cff00ff00[AT]|r Total raw entries: %d", #sortedKeys))
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
                table.insert(statsLines, string.format("[%d] %s: %d times",
                    achievement.id, achievementName, achievement.count))
            end
        end

        statsText:SetText(table.concat(statsLines, "\n"))
    end

    -- Clear data section
    local clearLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    clearLabel:SetPoint("TOPLEFT", statsText, "BOTTOMLEFT", 0, -30)
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
            print("|cff00ff00[AT]|r All achievement data has been cleared.")
        end
    end)

    -- Update stats when panel is shown and set up auto-refresh
    panel:SetScript("OnShow", function()
        UpdateStats()
        -- Set up auto-refresh timer
        panel.refreshTimer = C_Timer.NewTicker(2, UpdateStats) -- Update every 2 seconds
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
