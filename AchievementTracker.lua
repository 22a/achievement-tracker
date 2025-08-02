-- Achievement Tracker Addon
-- Tracks achievements earned by party/raid members from chat messages

local addonName = "AchievementTracker"
local AT = {}
_G[addonName] = AT

-- Database structure
AT.db = nil

-- Default database structure
local defaultDB = {
    achievements = {}, -- [playerName] = { [achievementID] = { timestamp, achievementName, server } }
    settings = {
        trackPartyOnly = false, -- if true, only track party/raid members
        enableDebug = false,
        targetAchievements = {}, -- specific achievement IDs to track (empty = track all)
    }
}

-- Event frame
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ACHIEVEMENT")
eventFrame:RegisterEvent("CHAT_MSG_GUILD_ACHIEVEMENT")

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

-- Check if we should track this player
function AT:ShouldTrackPlayer(playerName)
    if not AT.db.settings.trackPartyOnly then
        return true
    end
    
    -- Check if player is in our party/raid
    if UnitInParty(playerName) or UnitInRaid(playerName) then
        return true
    end
    
    return false
end

-- Check if we should track this achievement
function AT:ShouldTrackAchievement(achievementID)
    if #AT.db.settings.targetAchievements == 0 then
        return true -- Track all achievements if no specific ones are set
    end
    
    for _, id in ipairs(AT.db.settings.targetAchievements) do
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
    
    -- Initialize player data if needed
    if not AT.db.achievements[playerName] then
        AT.db.achievements[playerName] = {}
    end
    
    -- Get server name
    local server = GetRealmName()
    
    -- Record the achievement
    AT.db.achievements[playerName][achievementID] = {
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
    elseif event == "CHAT_MSG_ACHIEVEMENT" or event == "CHAT_MSG_GUILD_ACHIEVEMENT" then
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
        print("|cffff0000/at stats [player]|r - Show achievement stats")
        print("|cffff0000/at list [player]|r - List achievements for player")
        print("|cffff0000/at search <achievement>|r - Search for achievement")
        print("|cffff0000/at debug|r - Toggle debug mode")
        print("|cffff0000/at partyonly|r - Toggle party-only tracking")
        print("|cffff0000/at target <achievementID>|r - Add/remove target achievement")
        print("|cffff0000/at clear|r - Clear all data (with confirmation)")
        
    elseif command == "stats" then
        local targetPlayer = args[2]
        if targetPlayer then
            AT:ShowPlayerStats(targetPlayer)
        else
            AT:ShowOverallStats()
        end
        
    elseif command == "list" then
        local targetPlayer = args[2]
        if targetPlayer then
            AT:ListPlayerAchievements(targetPlayer)
        else
            print("|cffff0000Usage:|r /at list <playername>")
        end
        
    elseif command == "debug" then
        AT.db.settings.enableDebug = not AT.db.settings.enableDebug
        print(string.format("|cff00ff00[AT]|r Debug mode: %s", 
              AT.db.settings.enableDebug and "ON" or "OFF"))
        
    elseif command == "partyonly" then
        AT.db.settings.trackPartyOnly = not AT.db.settings.trackPartyOnly
        print(string.format("|cff00ff00[AT]|r Party-only tracking: %s", 
              AT.db.settings.trackPartyOnly and "ON" or "OFF"))
        
    elseif command == "target" then
        local achievementID = tonumber(args[2])
        if achievementID then
            AT:ToggleTargetAchievement(achievementID)
        else
            print("|cffff0000Usage:|r /at target <achievementID>")
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

-- Utility functions (to be implemented)
function AT:ShowOverallStats()
    local totalPlayers = 0
    local totalAchievements = 0
    
    for playerName, achievements in pairs(AT.db.achievements) do
        totalPlayers = totalPlayers + 1
        for _ in pairs(achievements) do
            totalAchievements = totalAchievements + 1
        end
    end
    
    print(string.format("|cff00ff00[AT] Overall Stats:|r %d players, %d achievements tracked", 
          totalPlayers, totalAchievements))
end

function AT:ShowPlayerStats(playerName)
    local achievements = AT.db.achievements[playerName]
    if not achievements then
        print(string.format("|cffff0000[AT]|r No data found for player: %s", playerName))
        return
    end
    
    local count = 0
    for _ in pairs(achievements) do
        count = count + 1
    end
    
    print(string.format("|cff00ff00[AT] %s:|r %d achievements tracked", playerName, count))
end

function AT:ListPlayerAchievements(playerName)
    local achievements = AT.db.achievements[playerName]
    if not achievements then
        print(string.format("|cffff0000[AT]|r No data found for player: %s", playerName))
        return
    end
    
    print(string.format("|cff00ff00[AT] Achievements for %s:|r", playerName))
    for achievementID, data in pairs(achievements) do
        local dateStr = date("%Y-%m-%d %H:%M", data.timestamp)
        print(string.format("  [%d] %s - %s", achievementID, data.achievementName, dateStr))
    end
end

function AT:ToggleTargetAchievement(achievementID)
    local targets = AT.db.settings.targetAchievements
    local found = false
    
    for i, id in ipairs(targets) do
        if id == achievementID then
            table.remove(targets, i)
            found = true
            break
        end
    end
    
    if not found then
        table.insert(targets, achievementID)
        print(string.format("|cff00ff00[AT]|r Added achievement %d to tracking list", achievementID))
    else
        print(string.format("|cff00ff00[AT]|r Removed achievement %d from tracking list", achievementID))
    end
end
