-- Bezier Addon
-- Tracks achievements earned for the first time by party/raid members

local BZ = {}
Bezier = BZ

-- Constants
local DEFAULT_PREFIX = "AotC this season"

-- Addon event frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_ACHIEVEMENT")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_SYSTEM")  -- IAT: Used to detect when players join/leave group
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("INSPECT_ACHIEVEMENT_READY")

-- Achievement Scanning Variables (Exact IAT Implementation)
local playersToScan = {}                    -- Queue of players waiting for scanning
local playersScanned = {}                   -- List of successfully scanned players
local rescanNeeded = false                  -- Set to true if rescan needed during current scan
local playerCurrentlyScanning = nil         -- Currently scanning player unit
local scanInProgress = false                -- Global scan lock - prevents concurrent scans
BZ.scanFinished = false                     -- True when everyone scanned successfully (exposed for UI)
local scanAnnounced = false                 -- Whether scan announcement was made
local scanCounter = 0                       -- Incremented to invalidate stale timers
BZ.currentComparisonUnit = nil              -- Name of player being compared (for event validation)

BZ.scanResults = {} -- Scan results and cache: [achievementID] = {completed={}, notCompleted={}, timestamp=time, zone=zone}
BZ.currentZone = nil -- Track current zone to detect instance changes
BZ.scanStartTime = nil -- Track scan timing
BZ.currentScanAchievementID = nil -- Achievement ID being scanned

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

    -- Normalize player name to handle realm suffixes
    local normalizedPlayerName = BZ:NormalizePlayerName(playerName)

    -- Check if this player was in our notCompleted list (players we know for certain didn't have the achievement)
    local shouldCount = false
    if BZ.scanResults[achievementID] and BZ.scanResults[achievementID].notCompleted then
        for _, notCompletedPlayer in ipairs(BZ.scanResults[achievementID].notCompleted) do
            if notCompletedPlayer == normalizedPlayerName then
                shouldCount = true
                break
            end
        end
    end

    if not shouldCount then
        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Not counting achievement for %s (normalized: %s): not in notCompleted list (either already had it or status was unknown)", playerName, normalizedPlayerName))
        return
    end

    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Counting achievement for %s (normalized: %s): confirmed they didn't have it before", playerName, normalizedPlayerName))

    -- Initialize counter if it doesn't exist
    if not BZ.db.achievements[achievementID] then
        BZ.db.achievements[achievementID] = 0
    end

    -- Increment the counter
    BZ.db.achievements[achievementID] = BZ.db.achievements[achievementID] + 1

    -- Debug output
    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Recorded first-time achievement for %s: [%d] %s (Total: %d)",
              playerName, achievementID, achievementName, BZ.db.achievements[achievementID]))

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
        -- IAT: Fired whenever the composition of the group changes
        BZ.debugLog("|cff00ff00[BZ Debug]|r Group Roster Update")

        if scanInProgress == false then
            -- No scan in progress - start new scan immediately
            BZ.debugLog("|cff00ff00[BZ Debug]|r Starting Scan")
            scanInProgress = true
            BZ:GetPlayersInGroup()
        else
            -- Scan already in progress - defer rescan until current scan completes
            BZ.debugLog("|cff00ff00[BZ Debug]|r Scan in progress. Asking for rescan")
            rescanNeeded = true
        end

        -- Update display frame
        BZ:UpdateDisplayFrame()
    elseif event == "CHAT_MSG_SYSTEM" then
        -- IAT: Used to detect when players join/leave group
        local message = ...
        local chatStrs = {"joins the party", "joined the instance group", "joined the raid group", "joined a raid group", "leaves the party", "left the instance group", "leaves the party", "left the raid group"}
        for i = 1, #chatStrs do
            if string.match(message, chatStrs[i]) then
                BZ.debugLog("|cff00ff00[BZ Debug]|r CHAT_MSG_SYSTEM: " .. message)

                if scanInProgress == false then
                    -- No scan in progress - start new scan immediately
                    BZ.debugLog("|cff00ff00[BZ Debug]|r Starting Scan")
                    scanInProgress = true
                    BZ:GetPlayersInGroup()
                else
                    -- Scan already in progress - defer rescan until current scan completes
                    BZ.debugLog("|cff00ff00[BZ Debug]|r Scan in progress. Asking for rescan")
                    rescanNeeded = true
                end
                break
            end
        end
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
        -- Reset scanning variables when leaving world
        BZ:ResetScanningVariables()
    elseif event == "INSPECT_ACHIEVEMENT_READY" then
        -- IAT: Achievement inspection data is ready
        local guid = ...
        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r INSPECT_ACHIEVEMENT_READY fired for GUID: %s", tostring(guid)))
        BZ:ProcessInspectAchievementReady(guid)
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    BZ:OnEvent(event, ...)
end)

-- IAT Helper function: Check if a value exists in a table
function BZ:has_value(tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end
    return false
end

-- Helper function: Normalize player name (strip realm)
function BZ:NormalizePlayerName(playerName)
    if not playerName then return nil end
    -- Strip realm suffix (everything after the dash)
    local name = string.match(playerName, "^([^-]+)")
    return name or playerName
end

-- IAT: Reset scanning variables (called when leaving world)
function BZ:ResetScanningVariables()
    BZ.debugLog("|cff00ff00[BZ Debug]|r Resetting scanning variables")
    playersToScan = {}
    playersScanned = {}
    rescanNeeded = false
    playerCurrentlyScanning = nil
    scanInProgress = false
    BZ.scanFinished = false
    scanAnnounced = false
end

-- IAT: Get list of players in current group
function BZ:GetPlayersInGroup()
    if not BZ.db.settings.activeAchievementID then
        BZ.debugLog("|cff00ff00[BZ Debug]|r No active achievement set, skipping scan")
        return
    end

    -- Only announce scanning once
    if scanAnnounced == false then
        print("|cff00ff00[Bezier]|r Starting achievement scan for " .. (select(2, GetAchievementInfo(BZ.db.settings.activeAchievementID)) or "Unknown Achievement"))
        scanAnnounced = true
    end

    local groupSize = BZ:GetGroupSize()
    scanInProgress = true
    BZ.scanFinished = false

    if groupSize > 1 then
        -- We are in a group
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

            local name, realm = UnitName(unit)
            if name and name ~= "Unknown" then
                -- Use simple name for IAT compatibility
                local playerName = name
                if BZ:has_value(playersScanned, playerName) == false and
                   BZ:has_value(playersToScan, playerName) == false then
                    table.insert(playersToScan, playerName)
                end
            end
        end
    else
        -- Solo player
        local name, realm = UnitName("player")
        if name then
            local playerName = name
            if BZ:has_value(playersScanned, playerName) == false and
               BZ:has_value(playersToScan, playerName) == false then
                table.insert(playersToScan, playerName)
            end
        end
    end

    rescanNeeded = false

    -- Start scanning or complete if no players to scan
    if #playersToScan > 0 then
        BZ:GetInstanceAchievements()
    else
        BZ.debugLog("|cff00ff00[BZ Debug]|r No players to scan")
        scanInProgress = false
        BZ.scanFinished = true
    end
end

-- IAT: Core scanning function - processes one player at a time
function BZ:GetInstanceAchievements()
    ClearAchievementComparisonUnit()

    -- Make sure the player we are about to scan is still in the group
    if UnitExists(playersToScan[1]) then
        playerCurrentlyScanning = playersToScan[1]
        BZ.currentComparisonUnit = UnitName(playersToScan[1])

        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Setting comparison unit to: %s", BZ.currentComparisonUnit))

        -- Check if the achievement UI is open before setting the comparison unit
        if _G["AchievementFrameComparison"] then
            -- Temporarily disable the event while we do our scanning
            _G["AchievementFrameComparison"]:UnregisterEvent("INSPECT_ACHIEVEMENT_READY")
            SetAchievementComparisonUnit(playersToScan[1])
        else
            -- Achievement Frame has not been loaded so go ahead and set the comparison unit
            SetAchievementComparisonUnit(playersToScan[1])
        end

        -- Set timeout with scan counter validation
        local scanCounterloc = scanCounter
        C_Timer.After(2, function()
            -- Check if the scan is still valid or not
            if scanCounterloc == scanCounter then
                -- Last player to scan was not successful - cache as unknown
                local playerName = playersToScan[1] and UnitName(playersToScan[1]) or "unknown"
                BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Timeout scanning %s", playerName))

                -- Cache as unknown if we have an active achievement
                if BZ.db.settings.activeAchievementID and playerName ~= "unknown" then
                    BZ:CachePlayerAsUnknown(playerName, BZ.db.settings.activeAchievementID)
                end

                rescanNeeded = true
                if playersToScan[1] ~= nil then
                    table.remove(playersToScan, 1)
                end

                if #playersToScan > 0 then
                    BZ:GetInstanceAchievements()
                elseif #playersToScan == 0 and rescanNeeded == true then
                    -- Achievement scanning finished but some players still need scanning
                    BZ.debugLog("|cff00ff00[BZ Debug]|r Scan finished but rescan needed. Waiting 10 seconds then trying again")
                    C_Timer.After(10, function()
                        scanInProgress = true
                        BZ:GetPlayersInGroup()
                    end)

                    -- Update display frame
                    BZ:UpdateDisplayFrame()
                end
            end
        end)
    else
        -- Player no longer exists - trigger rescan
        rescanNeeded = true
        scanInProgress = true
        BZ:GetPlayersInGroup()
    end
end

-- IAT: Process INSPECT_ACHIEVEMENT_READY event
function BZ:ProcessInspectAchievementReady(guid)
    if (guid and C_PlayerInfo.GUIDIsPlayer(guid)) then
        local class, classFilename, race, raceFilename, sex, name, realm = GetPlayerInfoByGUID(guid)
        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r INSPECT_ACHIEVEMENT_READY fired for: %s", name))

        -- Check if this event is for our current scan
        if BZ.currentComparisonUnit == name then
            -- IAT: Make sure the player is still online since achievement scanning may happen some time after scanning players
            if UnitExists(playerCurrentlyScanning) then
                -- IAT: Check achievement completion status with proper player self-scanning
                local completed
                if BZ.currentComparisonUnit == UnitName("player") then
                    -- IAT: For player themselves, use GetAchievementInfo and check wasEarnedByMe
                    local _, _, _, completedFlag, _, _, _, _, _, _, _, _, wasEarnedByMe = GetAchievementInfo(BZ.db.settings.activeAchievementID)
                    completed = wasEarnedByMe
                    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Player self-scan: wasEarnedByMe=%s", tostring(wasEarnedByMe)))
                else
                    -- IAT: For other players, use GetAchievementComparisonInfo
                    local completedFlag, month, day, year = GetAchievementComparisonInfo(BZ.db.settings.activeAchievementID)
                    completed = completedFlag
                    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Comparison scan: completed=%s, month=%s, day=%s, year=%s",
                        tostring(completedFlag), tostring(month), tostring(day), tostring(year)))
                end

                -- Cache the result
                BZ:CachePlayerResult(name, BZ.db.settings.activeAchievementID, completed or false)

                if completed then
                    print(string.format("|cff00ff00[BZ CONFIRMED]|r %s has COMPLETED the achievement", name))
                else
                    print(string.format("|cffffff00[BZ CONFIRMED]|r %s has NOT COMPLETED the achievement", name))
                end

                -- Move player from toScan to scanned
                table.insert(playersScanned, playersToScan[1])
                table.remove(playersToScan, 1)
                playerCurrentlyScanning = nil

                -- Increment scan counter to invalidate pending timers
                scanCounter = scanCounter + 1

                -- Continue scanning or complete
                if #playersToScan > 0 then
                    -- More players to scan
                    BZ:GetInstanceAchievements()
                elseif #playersToScan == 0 and rescanNeeded == false and #playersScanned == BZ:GetGroupSize() then
                    -- Perfect completion - all players scanned successfully
                    print(string.format("|cff00ff00[Bezier]|r Achievement scan finished (%d/%d)", #playersScanned, BZ:GetGroupSize()))
                    scanInProgress = false
                    BZ.scanFinished = true

                    -- Re-enable Blizzard achievement frame
                    if _G["AchievementFrameComparison"] ~= nil then
                        _G["AchievementFrameComparison"]:RegisterEvent("INSPECT_ACHIEVEMENT_READY")
                    end

                    -- Update display frame and settings panel
                    BZ:UpdateDisplayFrame()
                    if UpdateScanResultsDisplay then
                        UpdateScanResultsDisplay()
                    end
                elseif #playersToScan == 0 and rescanNeeded == true then
                    -- Scan complete but rescan needed (group changed during scan)
                    BZ.debugLog("|cff00ff00[BZ Debug]|r Scan finished but rescan needed. Waiting 10 seconds then trying again")

                    -- Re-enable Blizzard achievement frame
                    if _G["AchievementFrameComparison"] ~= nil then
                        _G["AchievementFrameComparison"]:RegisterEvent("INSPECT_ACHIEVEMENT_READY")
                    end

                    -- Schedule rescan
                    C_Timer.After(10, function()
                        scanInProgress = true
                        BZ:GetPlayersInGroup()
                    end)

                    -- Update display frame
                    BZ:UpdateDisplayFrame()
                else
                    -- IAT: Unknown error scenario
                    BZ.debugLog("|cff00ff00[BZ Debug]|r UNKNOWN ERROR in scan completion")
                end
            else
                -- IAT: Player went offline during scan - just set rescanNeeded and let scan complete naturally
                BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Player %s went offline during scan", name))
                rescanNeeded = true
            end
        else
            -- Someone else called the INSPECT_ACHIEVEMENT_READY event
            BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Incorrect INSPECT_ACHIEVEMENT_READY call for %s (expected %s)", name, tostring(BZ.currentComparisonUnit)))
        end
    end

    -- Always forward to Blizzard's achievement frame if it exists
    if (AchievementFrame and AchievementFrame.isComparison and AchievementFrameComparison) then
        AchievementFrameComparison_OnEvent(AchievementFrameComparison, "INSPECT_ACHIEVEMENT_READY", guid)
    end
end

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

-- Simple trigger function for manual scans
function BZ:ScanGroupForActiveAchievement()
    local activeID = BZ.db.settings.activeAchievementID
    if not activeID then
        BZ.debugLog("|cffff0000[BZ]|r No active achievement set for scanning")
        return
    end

    if scanInProgress then
        BZ.debugLog("|cffff0000[BZ]|r Scan already in progress")
        return
    end

    BZ.debugLog("|cff00ff00[BZ]|r Starting manual scan")
    scanInProgress = true
    BZ:GetPlayersInGroup()

    -- Update display frame to show scan in progress
    BZ:UpdateDisplayFrame()
end

-- Reset scan results for active achievement
function BZ:ResetScanResults()
    local activeID = BZ.db.settings.activeAchievementID
    if not activeID then
        BZ.debugLog("|cffff0000[BZ]|r No active achievement set")
        return
    end

    -- Clear scan results for active achievement
    BZ.scanResults[activeID] = nil
    BZ.scanFinished = false
    scanInProgress = false

    BZ.debugLog("|cff00ff00[BZ]|r Scan results reset for active achievement")

    -- Update display frame and settings panel
    BZ:UpdateDisplayFrame()
    if UpdateScanResultsDisplay then
        UpdateScanResultsDisplay()
    end
end



-- Cache a player's achievement result
function BZ:CachePlayerResult(playerName, achievementID, completed)
    if not BZ.scanResults[achievementID] then
        BZ.scanResults[achievementID] = {
            completed = {},
            notCompleted = {},
            unknown = {},
            timestamp = GetTime(),
            zone = GetZoneText()
        }
    end

    if completed then
        table.insert(BZ.scanResults[achievementID].completed, playerName)
    else
        table.insert(BZ.scanResults[achievementID].notCompleted, playerName)
    end
end

-- Cache a player as unknown (cross-realm limitation)
function BZ:CachePlayerAsUnknown(playerName, achievementID)
    if not BZ.scanResults[achievementID] then
        BZ.scanResults[achievementID] = {
            completed = {},
            notCompleted = {},
            unknown = {},
            timestamp = GetTime(),
            zone = GetZoneText()
        }
    end

    table.insert(BZ.scanResults[achievementID].unknown, playerName)
    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Cached %s as unknown (cross-realm)", playerName))
end

-- Find unit for a player name
function BZ:FindUnitForPlayer(playerName)
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

            if unit and UnitExists(unit) then
                local name, realm = UnitFullName(unit)
                if name then
                    local fullName = realm and (name .. "-" .. realm) or name
                    if fullName == playerName then
                        return unit
                    end
                end
            end
        end
    else
        -- Solo player
        local name, realm = UnitFullName("player")
        if name then
            local fullName = realm and (name .. "-" .. realm) or name
            if fullName == playerName then
                return "player"
            end
        end
    end
    return nil
end

-- Check if player result is cached
function BZ:CheckPlayerCache(playerName, achievementID)
    if BZ.scanResults[achievementID] then
        local results = BZ.scanResults[achievementID]

        -- Check if player is in completed list
        for _, completedPlayer in ipairs(results.completed or {}) do
            if completedPlayer == playerName then
                return "completed"
            end
        end

        -- Check if player is in not completed list
        for _, notCompletedPlayer in ipairs(results.notCompleted or {}) do
            if notCompletedPlayer == playerName then
                return "not_completed"
            end
        end

        -- Check if player is in unknown list (cross-realm limitation)
        for _, unknownPlayer in ipairs(results.unknown or {}) do
            if unknownPlayer == playerName then
                return "cross_realm_unknown"
            end
        end
    end

    return "unknown"
end



-- Check if a player has a specific achievement (simplified for sequential scanning)
-- Returns: "completed", "not_completed", or "unknown"
function BZ:PlayerHasAchievement(playerName, achievementID)
    if not achievementID then
        return "unknown"
    end

    -- Just check cache - sequential scanning will handle the actual scanning
    return BZ:CheckPlayerCache(playerName, achievementID)
end


-- Print comprehensive group status for debugging
function BZ:PrintGroupStatus(players, achievementID, achievementName)
    BZ.debugLog("|cff00ff00[BZ Debug]|r ========== GROUP STATUS ==========")
    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Achievement: %s (ID: %s)", achievementName, tostring(achievementID)))
    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Group Size: %d", #players))
    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Group Type: %s", IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "SOLO")))
    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Zone: %s", GetZoneText()))

    -- Show each player and their unit mapping
    for i, playerName in ipairs(players) do
        local unit = nil
        local unitStatus = "NOT FOUND"

        -- Try to find the unit for this player
        if IsInRaid() then
            for j = 1, GetNumGroupMembers() do
                local checkUnit = "raid" .. j
                if UnitExists(checkUnit) then
                    local name, realm = UnitFullName(checkUnit)
                    if name then
                        local fullName = realm and (name .. "-" .. realm) or name
                        if fullName == playerName then
                            unit = checkUnit
                            break
                        end
                    end
                end
            end
        elseif IsInGroup() then
            -- Check party members
            for j = 1, GetNumSubgroupMembers() do
                local checkUnit = "party" .. j
                if UnitExists(checkUnit) then
                    local name, realm = UnitFullName(checkUnit)
                    if name then
                        local fullName = realm and (name .. "-" .. realm) or name
                        if fullName == playerName then
                            unit = checkUnit
                            break
                        end
                    end
                end
            end
            -- Check player
            local name, realm = UnitFullName("player")
            if name then
                local fullName = realm and (name .. "-" .. realm) or name
                if fullName == playerName then
                    unit = "player"
                end
            end
        else
            -- Solo
            local name, realm = UnitFullName("player")
            if name then
                local fullName = realm and (name .. "-" .. realm) or name
                if fullName == playerName then
                    unit = "player"
                end
            end
        end

        if unit then
            local connected = UnitIsConnected(unit)
            local dead = UnitIsDeadOrGhost(unit)
            local canInspect = CanInspect(unit)
            local unitName = UnitName(unit)
            unitStatus = string.format("FOUND (%s) - connected:%s, dead:%s, canInspect:%s, unitName:%s",
                unit, tostring(connected), tostring(dead), tostring(canInspect), tostring(unitName))
        end

        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Player %d: %s -> %s", i, playerName, unitStatus))
    end

    -- Show cache status
    if BZ.scanResults[achievementID] then
        local cache = BZ.scanResults[achievementID]
        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Cache: %d completed, %d not completed",
            #(cache.completed or {}), #(cache.notCompleted or {})))
        if #(cache.completed or {}) > 0 then
            BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Completed: %s", table.concat(cache.completed, ", ")))
        end
        if #(cache.notCompleted or {}) > 0 then
            BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Not Completed: %s", table.concat(cache.notCompleted, ", ")))
        end
    else
        BZ.debugLog("|cff00ff00[BZ Debug]|r Cache: No cache for this achievement")
    end

    BZ.debugLog("|cff00ff00[BZ Debug]|r ===================================")
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

    -- Create tab system
    local tabButtons = {}
    local tabFrames = {}
    local currentTab = 1

    -- Tab button creation function
    local function CreateTabButton(index, text, parent)
        local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetSize(120, 25)
        button:SetPoint("TOPLEFT", title, "BOTTOMLEFT", (index - 1) * 125, -10)
        button:SetText(text)

        button:SetScript("OnClick", function()
            -- Hide all tab frames
            for i = 1, #tabFrames do
                tabFrames[i]:Hide()
            end
            -- Show selected tab frame
            tabFrames[index]:Show()

            -- Update button states
            for i = 1, #tabButtons do
                if i == index then
                    tabButtons[i]:SetButtonState("PUSHED", true)
                    tabButtons[i]:Disable()
                else
                    tabButtons[i]:SetButtonState("NORMAL")
                    tabButtons[i]:Enable()
                end
            end
            currentTab = index
        end)

        return button
    end

    -- Create tab buttons
    tabButtons[1] = CreateTabButton(1, "General", panel)
    tabButtons[2] = CreateTabButton(2, "Scan Results", panel)
    tabButtons[3] = CreateTabButton(3, "Achievements", panel)

    -- Create tab content frames
    for i = 1, 3 do
        local tabFrame = CreateFrame("Frame", nil, panel)
        tabFrame:SetSize(600, 500)
        tabFrame:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -45)
        tabFrame:Hide()
        tabFrames[i] = tabFrame
    end

    -- Show first tab by default
    tabFrames[1]:Show()
    tabButtons[1]:SetButtonState("PUSHED", true)
    tabButtons[1]:Disable()

    -- TAB 1: GENERAL SETTINGS
    local generalTab = tabFrames[1]

    -- Display Frame Settings Section
    local displayLabel = generalTab:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    displayLabel:SetPoint("TOPLEFT", 10, -10)
    displayLabel:SetText("Display Frame Settings:")

    -- Enable Display Frame setting
    local enableCheckbox = CreateFrame("CheckButton", nil, generalTab, "UICheckButtonTemplate")
    enableCheckbox:SetSize(20, 20)
    enableCheckbox:SetPoint("TOPLEFT", displayLabel, "BOTTOMLEFT", 10, -10)
    enableCheckbox:SetChecked(BZ.db.settings.displayFrame.enabled)

    local enableLabel = generalTab:CreateFontString(nil, "ARTWORK", "GameFontNormal")
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
    local prefixLabel = generalTab:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    prefixLabel:SetPoint("TOPLEFT", enableCheckbox, "BOTTOMLEFT", 0, -20)
    prefixLabel:SetText("Display Text Prefix:")

    local prefixHelp = generalTab:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    prefixHelp:SetPoint("TOPLEFT", prefixLabel, "BOTTOMLEFT", 0, -2)
    prefixHelp:SetText("(This text will be shown before the count, e.g., 'Your Text: 5')")
    prefixHelp:SetTextColor(0.7, 0.7, 0.7)

    local prefixInput = CreateFrame("EditBox", nil, generalTab, "InputBoxTemplate")
    prefixInput:SetSize(150, 20)
    prefixInput:SetPoint("TOPLEFT", prefixHelp, "BOTTOMLEFT", 0, -5)
    prefixInput:SetAutoFocus(false)
    prefixInput:SetText(BZ.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX)

    local prefixSaveButton = CreateFrame("Button", nil, generalTab, "UIPanelButtonTemplate")
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

    local prefixResetButton = CreateFrame("Button", nil, generalTab, "UIPanelButtonTemplate")
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
    local fontLabel = generalTab:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", prefixInput, "BOTTOMLEFT", 0, -40)
    fontLabel:SetText("Font Size:")

    local fontSlider = CreateFrame("Slider", nil, generalTab, "OptionsSliderTemplate")
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
    local generalLabel = generalTab:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    generalLabel:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", -10, -40)
    generalLabel:SetText("General Settings:")

    -- Debug Mode setting
    local debugCheckbox = CreateFrame("CheckButton", nil, generalTab, "UICheckButtonTemplate")
    debugCheckbox:SetSize(20, 20)
    debugCheckbox:SetPoint("TOPLEFT", generalLabel, "BOTTOMLEFT", 10, -10)
    debugCheckbox:SetChecked(BZ.db.settings.enableDebugLogging)

    local debugLabel = generalTab:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    debugLabel:SetPoint("LEFT", debugCheckbox, "RIGHT", 5, 0)
    debugLabel:SetText("Enable Debug Logging")

    debugCheckbox:SetScript("OnClick", function()
        BZ.db.settings.enableDebugLogging = debugCheckbox:GetChecked()
        BZ.debugLog(string.format("|cff00ff00[BZ]|r Debug logging: %s", BZ.db.settings.enableDebugLogging and "ON" or "OFF"))
    end)

    -- TAB 2: SCAN RESULTS
    local scanTab = tabFrames[2]

    -- Group Scanning Section
    local groupLabel = scanTab:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    groupLabel:SetPoint("TOPLEFT", 10, -10)
    groupLabel:SetText("Group Achievement Scanning:")

    -- Scan Group button
    local scanButton = CreateFrame("Button", nil, scanTab, "UIPanelButtonTemplate")
    scanButton:SetSize(120, 22)
    scanButton:SetPoint("TOPLEFT", groupLabel, "BOTTOMLEFT", 0, -5)
    scanButton:SetText("Scan Group")
    scanButton:SetScript("OnClick", function()
        BZ:ScanGroupForActiveAchievement()
    end)

    -- Reset Scan button
    local resetScanButton = CreateFrame("Button", nil, scanTab, "UIPanelButtonTemplate")
    resetScanButton:SetSize(120, 22)
    resetScanButton:SetPoint("LEFT", scanButton, "RIGHT", 10, 0)
    resetScanButton:SetText("Reset Scan")
    resetScanButton:SetScript("OnClick", function()
        BZ:ResetScanResults()
    end)

    -- Scanning limitation note
    local scanNote = scanTab:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    scanNote:SetPoint("TOPLEFT", scanButton, "BOTTOMLEFT", 0, -5)
    scanNote:SetText("Note: Only works reliably for same-realm players in range")
    scanNote:SetTextColor(0.8, 0.8, 0.8)

    -- Scanned Members Table
    local scanResultsLabel = scanTab:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    scanResultsLabel:SetPoint("TOPLEFT", scanNote, "BOTTOMLEFT", 0, -10)
    scanResultsLabel:SetText("Scanned Members:")
    scanResultsLabel:SetTextColor(1, 1, 1)

    -- Direct table container for scanned members
    local scanResultsContainer = CreateFrame("Frame", nil, scanTab)
    scanResultsContainer:SetSize(500, 400)
    scanResultsContainer:SetPoint("TOPLEFT", scanResultsLabel, "BOTTOMLEFT", 0, -5)

    -- Function to update scanned members table
    local function UpdateScanResultsDisplay()
        -- Clear existing children
        local children = {scanResultsContainer:GetChildren()}
        for i = 1, #children do
            children[i]:Hide()
            children[i]:SetParent(nil)
        end

        local yOffset = 0
        local activeID = BZ.db.settings.activeAchievementID
        local results = activeID and BZ.scanResults[activeID]

        if not results then
            local noScanText = scanResultsContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            noScanText:SetPoint("TOPLEFT", 0, -yOffset)
            noScanText:SetText("No scan performed yet - click Scan button")
            noScanText:SetTextColor(0.7, 0.7, 0.7)
            yOffset = yOffset + 20
        else
            -- Create table header
            local headerFrame = CreateFrame("Frame", nil, scanResultsContainer)
            headerFrame:SetSize(480, 25)
            headerFrame:SetPoint("TOPLEFT", 0, -yOffset)

            local headerBg = headerFrame:CreateTexture(nil, "BACKGROUND")
            headerBg:SetAllPoints()
            headerBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)

            local nameHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            nameHeader:SetPoint("LEFT", 10, 0)
            nameHeader:SetText("Player Name")
            nameHeader:SetTextColor(1, 1, 1)

            local statusHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            statusHeader:SetPoint("LEFT", 250, 0)
            statusHeader:SetText("Status")
            statusHeader:SetTextColor(1, 1, 1)

            yOffset = yOffset + 30

            -- Show completed players
            for _, playerName in ipairs(results.completed or {}) do
                local rowFrame = CreateFrame("Frame", nil, scanResultsContainer)
                rowFrame:SetSize(480, 22)
                rowFrame:SetPoint("TOPLEFT", 0, -yOffset)

                local playerText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                playerText:SetPoint("LEFT", 10, 0)
                playerText:SetText(playerName)
                playerText:SetTextColor(0.8, 1, 0.8)

                local statusText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                statusText:SetPoint("LEFT", 250, 0)
                statusText:SetText("Completed")
                statusText:SetTextColor(0.8, 1, 0.8)

                yOffset = yOffset + 22
            end

            -- Show not completed players
            for _, playerName in ipairs(results.notCompleted or {}) do
                local rowFrame = CreateFrame("Frame", nil, scanResultsContainer)
                rowFrame:SetSize(480, 22)
                rowFrame:SetPoint("TOPLEFT", 0, -yOffset)

                local playerText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                playerText:SetPoint("LEFT", 10, 0)
                playerText:SetText(playerName)
                playerText:SetTextColor(1, 0.8, 0.8)

                local statusText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                statusText:SetPoint("LEFT", 250, 0)
                statusText:SetText("Not Completed")
                statusText:SetTextColor(1, 0.8, 0.8)

                yOffset = yOffset + 22
            end

            -- Show unknown players (from scan results)
            for _, playerName in ipairs(results.unknown or {}) do
                local rowFrame = CreateFrame("Frame", nil, scanResultsContainer)
                rowFrame:SetSize(480, 22)
                rowFrame:SetPoint("TOPLEFT", 0, -yOffset)

                local playerText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                playerText:SetPoint("LEFT", 10, 0)
                playerText:SetText(playerName)
                playerText:SetTextColor(1, 1, 0.6)

                local statusText = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                statusText:SetPoint("LEFT", 250, 0)
                statusText:SetText("Unknown")
                statusText:SetTextColor(1, 1, 0.6)

                yOffset = yOffset + 22
            end

            -- Show summary at bottom
            local completedCount = #(results.completed or {})
            local notCompletedCount = #(results.notCompleted or {})
            local unknownCount = #(results.unknown or {})

            yOffset = yOffset + 15
            local summaryText = scanResultsContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            summaryText:SetPoint("TOPLEFT", 0, -yOffset)
            summaryText:SetText(string.format("Total: %d completed, %d not completed, %d unknown", completedCount, notCompletedCount, unknownCount))
            summaryText:SetTextColor(0.9, 0.9, 0.9)
            yOffset = yOffset + 20
        end
    end

    -- Update scan button to refresh display
    scanButton:SetScript("OnClick", function()
        BZ:ScanGroupForActiveAchievement()
        C_Timer.After(1, UpdateScanResultsDisplay) -- Update display after scan
    end)

    -- Initial display update
    UpdateScanResultsDisplay()

    -- TAB 3: ACHIEVEMENTS
    local achievementsTab = tabFrames[3]

    -- Add Achievement section
    local addLabel = achievementsTab:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    addLabel:SetPoint("TOPLEFT", 10, -10)
    addLabel:SetText("Add Achievement to Track:")

    -- Input box for achievement ID
    local addInput = CreateFrame("EditBox", nil, achievementsTab, "InputBoxTemplate")
    addInput:SetSize(120, 20)
    addInput:SetPoint("TOPLEFT", addLabel, "BOTTOMLEFT", 0, -5)
    addInput:SetAutoFocus(false)
    addInput:SetNumeric(true)

    -- Add button
    local addButton = CreateFrame("Button", nil, achievementsTab, "UIPanelButtonTemplate")
    addButton:SetSize(80, 22)
    addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
    addButton:SetText("Add")

    -- Tracked achievements table header
    local tableLabel = achievementsTab:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    tableLabel:SetPoint("TOPLEFT", addInput, "BOTTOMLEFT", 0, -30)
    tableLabel:SetText("Tracked Achievements:")

    -- Direct table container for achievements
    local achievementsContainer = CreateFrame("Frame", nil, achievementsTab)
    achievementsContainer:SetSize(550, 350)
    achievementsContainer:SetPoint("TOPLEFT", tableLabel, "BOTTOMLEFT", 0, -10)

    -- Function to update the achievements table
    local function UpdateAchievementsTable()
        -- Clear existing children more thoroughly
        local children = {achievementsContainer:GetChildren()}
        for i = 1, #children do
            children[i]:Hide()
            children[i]:SetParent(nil)
        end

        local yOffset = 0
        local activeID = BZ.db.settings.activeAchievementID

        -- Create header row
        local headerFrame = CreateFrame("Frame", nil, achievementsContainer)
        headerFrame:SetSize(540, 30)
        headerFrame:SetPoint("TOPLEFT", 0, -yOffset)

        local headerBg = headerFrame:CreateTexture(nil, "BACKGROUND")
        headerBg:SetAllPoints()
        headerBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)

        local idHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        idHeader:SetPoint("LEFT", 10, 0)
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
            local rowFrame = CreateFrame("Frame", nil, achievementsContainer)
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
            local noDataFrame = CreateFrame("Frame", nil, achievementsContainer)
            noDataFrame:SetSize(480, 25)
            noDataFrame:SetPoint("TOPLEFT", 0, -yOffset)

            local noDataText = noDataFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            noDataText:SetPoint("CENTER")
            noDataText:SetText("No achievements tracked yet. Add one above!")
            noDataText:SetTextColor(0.7, 0.7, 0.7)

            yOffset = yOffset + 25
        end


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
    BZ.displayFrame:SetSize(200, 50)
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

    -- Create first line text
    local text1 = BZ.displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text1:SetPoint("TOPLEFT", 10, -8)
    text1:SetTextColor(1, 1, 1, 1)
    BZ.displayFrame.text1 = text1

    -- Create second line text
    local text2 = BZ.displayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text2:SetPoint("TOPLEFT", 10, -25)
    text2:SetTextColor(1, 1, 1, 1)
    BZ.displayFrame.text2 = text2



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
        BZ.displayFrame.text1:SetText("No active achievement set")
        BZ.displayFrame.text2:SetText("")
        -- Auto-resize frame for text only
        local textWidth = BZ.displayFrame.text1:GetStringWidth()
        local frameWidth = math.max(textWidth + 20, 80)
        local frameHeight = 50
        BZ.displayFrame:SetSize(frameWidth, frameHeight)
        return
    end

    local groupSize = BZ:GetGroupSize()
    local inGroup = groupSize > 1

    -- Update font size for both lines
    local fontSize = BZ.db.settings.displayFrame.fontSize or 12
    local fontPath, _, fontFlags = BZ.displayFrame.text1:GetFont()
    BZ.displayFrame.text1:SetFont(fontPath or "Fonts\\FRIZQT__.TTF", fontSize, fontFlags or "OUTLINE")
    BZ.displayFrame.text2:SetFont(fontPath or "Fonts\\FRIZQT__.TTF", fontSize, fontFlags or "OUTLINE")

    local line1Text, line2Text

    if inGroup then
        -- Check if we have scan results
        local results = BZ.scanResults[activeID]

        if results then
            local notCompletedCount = #results.notCompleted
            local unknownCount = #(results.unknown or {})

            -- Line 1: Incoming AotC count
            line1Text = string.format("Incoming AotC: %d", notCompletedCount)

            -- Line 2: Pending scan count
            line2Text = string.format("Pending scan: %d", unknownCount)
        else
            -- No scan results yet
            line1Text = "Incoming AotC: ?"
            line2Text = "Pending scan: ?"
        end
    else
        -- Solo player - show total count
        local count = BZ.db.achievements[activeID] or 0
        local prefix = BZ.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX
        line1Text = string.format("%s: %d", prefix, count)
        line2Text = ""
    end

    -- Set text
    BZ.displayFrame.text1:SetText(line1Text)
    BZ.displayFrame.text2:SetText(line2Text)

    -- Auto-resize frame based on widest line
    local text1Width = BZ.displayFrame.text1:GetStringWidth()
    local text2Width = BZ.displayFrame.text2:GetStringWidth()
    local maxWidth = math.max(text1Width, text2Width)
    local frameWidth = math.max(maxWidth + 20, 80)
    local frameHeight = 50
    BZ.displayFrame:SetSize(frameWidth, frameHeight)
end