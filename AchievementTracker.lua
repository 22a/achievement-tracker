-- Achievement Tracker Addon
-- Tracks achievements earned by party/raid members from chat messages

local addonName = "AchievementTracker"
local AT = {}
_G[addonName] = AT

-- Database structure
AT.db = nil

-- Default database structure
local defaultDB = {
    achievements = {}, -- [achievementID] = { [playerName] = { timestamp, achievementName, server } }
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
    
    print("|cff00ff00Achievement Tracker|r loaded. Type |cffff0000/at help|r for commands.")
end

-- Parse achievement message from chat
function AT:ParseAchievementMessage(message, sender)
    -- Achievement messages typically look like:
    -- "PlayerName has earned the achievement [Achievement Name]!"
    -- or variations depending on locale
    
    local playerName, achievementLink = string.match(message, "(.+) has earned the achievement (.+)!")
    
    if not playerName then
        -- Try alternative patterns for different locales or message formats
        playerName, achievementLink = string.match(message, "(.+) a obtenu le haut%-fait (.+)!") -- French
        -- Add more patterns as needed for other locales
    end
    
    if playerName and achievementLink then
        -- Extract achievement ID from the link
        local achievementID = string.match(achievementLink, "achievement:(%d+)")
        if achievementID then
            achievementID = tonumber(achievementID)
            local achievementName = string.match(achievementLink, "%[(.+)%]")
            
            return playerName, achievementID, achievementName
        end
    end
    
    return nil
end

-- Check if we should track this player (must be in party/raid)
function AT:ShouldTrackPlayer(playerName)
    -- Check if player is in our party/raid
    if UnitInParty(playerName) or UnitInRaid(playerName) then
        return true
    end

    return false
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
    if not AT:ShouldTrackPlayer(playerName) then
        return
    end

    if not AT:ShouldTrackAchievement(achievementID) then
        return
    end

    -- Initialize achievement data if needed
    if not AT.db.achievements[achievementID] then
        AT.db.achievements[achievementID] = {}
    end

    -- Get server name
    local server = GetRealmName()

    -- Record the achievement
    AT.db.achievements[achievementID][playerName] = {
        timestamp = time(),
        achievementName = achievementName,
        server = server
    }

    if AT.db.settings.enableDebug then
        print(string.format("|cff00ff00[AT]|r Recorded: %s earned [%s] (ID: %d)",
              playerName, achievementName, achievementID))
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
        local message, sender = ...
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
        print("|cffff0000/at clear|r - Clear all data (with confirmation)")

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

    elseif command == "clear" then
        print("|cffff0000WARNING:|r This will clear all tracked achievement data!")
        print("Type |cffff0000/at confirmclear|r to confirm.")

    elseif command == "confirmclear" then
        AT.db.achievements = {}
        print("|cff00ff00[AT]|r All achievement data cleared.")

    else
        print("|cffff0000Unknown command.|r Type |cffff0000/at help|r for help.")
    end
end

-- Utility functions
function AT:ShowOverallStats()
    local totalAchievements = 0
    local totalPlayers = 0
    local playerSet = {}

    for achievementID, players in pairs(AT.db.achievements) do
        totalAchievements = totalAchievements + 1
        for playerName, _ in pairs(players) do
            playerSet[playerName] = true
        end
    end

    for _ in pairs(playerSet) do
        totalPlayers = totalPlayers + 1
    end

    print(string.format("|cff00ff00[AT] Overall Stats:|r %d unique achievements, %d unique players tracked",
          totalAchievements, totalPlayers))

    -- Show breakdown by achievement
    for achievementID, players in pairs(AT.db.achievements) do
        local count = 0
        local achievementName = ""
        for playerName, data in pairs(players) do
            count = count + 1
            if achievementName == "" then
                achievementName = data.achievementName
            end
        end
        print(string.format("  [%d] %s: %d players", achievementID, achievementName, count))
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

    if not found then
        table.insert(tracked, achievementID)
        print(string.format("|cff00ff00[AT]|r Added achievement %d to tracking list", achievementID))
    else
        print(string.format("|cff00ff00[AT]|r Removed achievement %d from tracking list", achievementID))
    end
end
