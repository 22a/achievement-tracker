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
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("INSPECT_ACHIEVEMENT_READY")

-- Group scanning variables
BZ.groupScanInProgress = false
BZ.currentScanAchievementID = nil
BZ.scanCounter = 0

BZ.scanResults = {} -- Scan results and cache: [achievementID] = {completed={}, notCompleted={}, timestamp=time, zone=zone}
BZ.currentZone = nil -- Track current zone to detect instance changes
BZ.periodicScanTimer = nil -- Timer for periodic scanning
BZ.scanStartTime = nil -- Track scan timing

-- Achievement inspection queue (using Instance Achievement Tracker approach)
BZ.playersToScan = {} -- Queue of players waiting for inspection
BZ.playerCurrentlyScanning = nil -- Currently inspecting player name
BZ.scanCounter = 0 -- Incremented each scan to validate timers

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

    print("|cff00ff00Bezier|r loaded. Open Interface Options > AddOns > Bezier to configure.")

    -- Delay UI creation until after all functions are loaded
    C_Timer.After(0.1, function()
        -- Create settings panel with error handling
        local success, err = pcall(function()
            BZ:CreateSettingsPanel()
        end)
        if not success then
            print("|cffff0000[BZ Error]|r Failed to create settings panel: " .. tostring(err))
        end

        -- Create display frame with error handling
        local success2, err2 = pcall(function()
            BZ:CreateDisplayFrame()
        end)
        if not success2 then
            print("|cffff0000[BZ Error]|r Failed to create display frame: " .. tostring(err2))
        end
    end)
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
    elseif event == "INSPECT_ACHIEVEMENT_READY" then
        -- Achievement inspection data is ready
        local guid = ...
        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r INSPECT_ACHIEVEMENT_READY fired for GUID: %s", tostring(guid)))
        BZ:ProcessInspectReady(guid)
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

-- Process INSPECT_ACHIEVEMENT_READY event (Instance Achievement Tracker approach)
function BZ:ProcessInspectReady(guid)
    if not BZ.playerCurrentlyScanning then
        BZ.debugLog("|cff00ff00[BZ Debug]|r INSPECT_ACHIEVEMENT_READY but no current scan")
        return
    end

    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r INSPECT_ACHIEVEMENT_READY for %s (GUID: %s)", BZ.playerCurrentlyScanning, tostring(guid)))

    -- Signal that the scan was successful by clearing the current player
    BZ.playerCurrentlyScanning = nil
    BZ.scanCounter = BZ.scanCounter + 1
end

-- Start scanning achievements for players (Instance Achievement Tracker approach)
function BZ:StartAchievementScan(achievementID)
    BZ.playersToScan = {}
    BZ.scanCounter = BZ.scanCounter + 1

    -- Get list of players to scan
    local players = BZ:GetPlayersInGroup()
    for _, playerName in ipairs(players) do
        -- Check cache first
        local cached = BZ:CheckPlayerCache(playerName, achievementID)
        if cached == "unknown" then
            table.insert(BZ.playersToScan, playerName)
        end
    end

    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Starting achievement scan for %d players", #BZ.playersToScan))

    if #BZ.playersToScan > 0 then
        BZ:ScanNextPlayer(achievementID)
    else
        BZ.debugLog("|cff00ff00[BZ Debug]|r All players already cached, scan complete")
    end
end

-- Scan the next player in the queue (Instance Achievement Tracker approach)
function BZ:ScanNextPlayer(achievementID)
    if #BZ.playersToScan == 0 then
        BZ.debugLog("|cff00ff00[BZ Debug]|r Achievement scan complete")
        return
    end

    local playerName = BZ.playersToScan[1]
    BZ.playerCurrentlyScanning = playerName

    -- Find the unit for this player
    local unit = BZ:FindUnitForPlayer(playerName)
    if not unit then
        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Could not find unit for %s, skipping", playerName))
        table.remove(BZ.playersToScan, 1)
        BZ:ScanNextPlayer(achievementID)
        return
    end

    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Scanning %s (unit: %s)", playerName, unit))

    -- Skip offline players
    if not UnitIsConnected(unit) then
        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r %s is offline, skipping", playerName))
        table.remove(BZ.playersToScan, 1)
        BZ.playerCurrentlyScanning = nil
        BZ:ScanNextPlayer(achievementID)
        return
    end

    -- Set comparison unit and request inspection
    SetAchievementComparisonUnit(unit)
    if CanInspect(unit) then
        NotifyInspect(unit)
    end

    -- Store scan counter for this specific scan
    local scanCounterLocal = BZ.scanCounter

    -- Wait 2 seconds then check if scan was successful (like Instance Achievement Tracker)
    C_Timer.After(2, function()
        -- Check if scan is still valid
        if scanCounterLocal == BZ.scanCounter then
            -- Scan was not successful (playerCurrentlyScanning still set)
            BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Scan timeout for %s", playerName))

            -- Try to get achievement data anyway
            local _, _, _, completed = GetAchievementComparisonInfo(achievementID)
            ClearAchievementComparisonUnit()

            if completed ~= nil then
                BZ:CachePlayerResult(playerName, achievementID, completed)
                BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Got achievement data on timeout for %s: %s", playerName, completed and "completed" or "not_completed"))
            else
                BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r No achievement data available for %s", playerName))
            end

            -- Remove from queue and continue
            table.remove(BZ.playersToScan, 1)
            BZ.playerCurrentlyScanning = nil
            BZ:ScanNextPlayer(achievementID)
        else
            -- Scan was successful (INSPECT_ACHIEVEMENT_READY fired and cleared playerCurrentlyScanning)
            BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Scan successful for %s", playerName))

            -- Get achievement data
            local _, _, _, completed = GetAchievementComparisonInfo(achievementID)
            ClearAchievementComparisonUnit()

            if completed ~= nil then
                BZ:CachePlayerResult(playerName, achievementID, completed)
                BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Cached result for %s: %s", playerName, completed and "completed" or "not_completed"))
            end

            -- Remove from queue and continue
            table.remove(BZ.playersToScan, 1)
            BZ:ScanNextPlayer(achievementID)
        end
    end)
end

-- Cache a player's achievement result
function BZ:CachePlayerResult(playerName, achievementID, completed)
    if not BZ.scanResults[achievementID] then
        BZ.scanResults[achievementID] = {
            completed = {},
            notCompleted = {},
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

-- Find unit for a player name
function BZ:FindUnitForPlayer(playerName)
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local name, realm = UnitFullName(unit)
                if name then
                    local fullName = realm and (name .. "-" .. realm) or name
                    if fullName == playerName then
                        return unit
                    end
                end
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name, realm = UnitFullName(unit)
                if name then
                    local fullName = realm and (name .. "-" .. realm) or name
                    if fullName == playerName then
                        return unit
                    end
                end
            end
        end
        -- Check player
        local name, realm = UnitFullName("player")
        if name then
            local fullName = realm and (name .. "-" .. realm) or name
            if fullName == playerName then
                return "player"
            end
        end
    else
        -- Solo
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
                local name, realm = UnitFullName(unit)
                if name and name ~= "Unknown" then
                    -- Use full name with realm for unique identification
                    local fullName = realm and (name .. "-" .. realm) or name
                    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r GetPlayersInGroup: %s -> %s (realm: %s)", unit, fullName, tostring(realm)))
                    table.insert(players, fullName)
                end
            end
        end
    else
        -- Solo player
        local name, realm = UnitFullName("player")
        if name then
            local fullName = realm and (name .. "-" .. realm) or name
            table.insert(players, fullName)
        end
    end

    return players
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
    end

    return "unknown"
end

-- Check if a player has a specific achievement (simplified for new scanning approach)
-- Returns: "completed", "not_completed", or "unknown"
function BZ:PlayerHasAchievement(playerName, achievementID)
    if not achievementID then
        return "unknown"
    end

    -- Check cache first
    local cached = BZ:CheckPlayerCache(playerName, achievementID)
    if cached ~= "unknown" then
        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Using cached result for %s: %s", playerName, cached))
        return cached
    end

    BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r %s not in cache, need to scan", playerName))
    return "unknown"
end

        -- Get unit info for debugging
        local unitName = UnitName(unit)
        local isCrossRealm = unitName and string.find(unitName, "-") ~= nil
        local isConnected = UnitIsConnected(unit)
        local isDead = UnitIsDeadOrGhost(unit)
        local canInspect = CanInspect(unit)

        BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r Scanning %s: unit=%s, unitName=%s, connected=%s, dead=%s, canInspect=%s, crossRealm=%s",
            playerName, unit, tostring(unitName), tostring(isConnected), tostring(isDead), tostring(canInspect), tostring(isCrossRealm)))

        -- Skip offline players - we can't get achievement data from them
        if not isConnected then
            BZ.debugLog(string.format("|cff00ff00[BZ Debug]|r %s is offline, cannot scan achievements", playerName))
            return "unknown"
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

    -- Print comprehensive group status for debugging
    BZ:PrintGroupStatus(players, activeID, achievementName)

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

    -- Explain unknown players if there are many
    if unknownCount > 0 then
        if unknownCount == groupSize then
            BZ.debugLog("|cffff8000[BZ]|r Note: Could not scan any players. This usually happens with cross-realm groups or when players are out of range.")
        elseif unknownCount > groupSize / 2 then
            BZ.debugLog(string.format("|cffff8000[BZ]|r Note: %d players could not be scanned (likely cross-realm or out of range)", unknownCount))
        end
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

    -- Scanning limitation note
    local scanNote = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    scanNote:SetPoint("TOPLEFT", scanButton, "BOTTOMLEFT", 0, -5)
    scanNote:SetText("Note: Only works reliably for same-realm players in range")
    scanNote:SetTextColor(0.8, 0.8, 0.8)

    -- Players scan results display
    local scanResultsLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    scanResultsLabel:SetPoint("TOPLEFT", scanNote, "BOTTOMLEFT", 0, -10)
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
                unknownNote:SetText(string.format("Note: %d players could not be scanned (cross-realm/out of range)", unknownCount))
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
                -- Show scan results with prefix: PREFIX: COUNT (X/U?/Y format)
                local count = BZ.db.achievements[activeID] or 0
                local prefix = BZ.db.settings.displayFrame.displayPrefix or DEFAULT_PREFIX
                displayText = string.format("%s: %d (%d/%d?/%d)", prefix, count, notCompletedCount, unknownCount, groupSize)
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