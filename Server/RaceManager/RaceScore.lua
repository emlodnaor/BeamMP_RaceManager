------ Server -------
---------------------
--- BonRaceScore --
---------------------
---- Authored by ----
-- Beams of Norway --
---------------------
local timeTools = require("Resources/Server/Globals/timeTools")

local function loadAllResults(raceName)
    local results = {}
    local resultsPath = "Resources/Server/RaceManager/RaceResults/"
    
    -- Use FS.ListFiles instead of dir command
    local files = FS.ListFiles(resultsPath)
    if not files then return results end
    
    for _, file in ipairs(files) do
        -- Filter for files matching pattern: run_<raceName>_*.json
        if file:find("^run_"..raceName.."_.*%.json$") then
            local f = io.open(resultsPath..file, "r")
            if f then
                local content = f:read("*all")
                f:close()
                local t = Util.JsonDecode(content)
                if t and t.allowedStartTime and t.finishTime[1] and t.finishTime[1] > 0 then
                    local finalTime = t.finishTime[1] - t.allowedStartTime
                    local resets = tonumber(t.resetsCount) or 0
                    table.insert(results, { nick = t.nick, mpUserId = t.playerId, time = finalTime, resets = resets, allowedStartTime = t.allowedStartTime, startTime = t.startTime, checkPointTimes = t.checkPointTimes, finishTimes = t.finishTime })
                    
                end
                --old format below
                if t and t.allowedStartTime and t.finishTime["1"] and t.finishTime["1"] > 0 then
                    local finalTime = t.finishTime["1"] - t.allowedStartTime
                    local resets = tonumber(t.resetsCount) or 0
                    table.insert(results, { nick = t.nick, time = finalTime, resets = resets })
                end
            end
        end
    end
    
    return results
end

function GetPlayerBestTimes(sender_id, raceName)
	local raceResults = loadAllResults(raceName)
	local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp
	if mpUserId == nil then return end
	local bestTimes = {}
	bestTimes.checkPointTimes = {}
	for i = 1, #raceResults do
		local run = raceResults[i]
		if run.mpUserId == mpUserId then
			local startTime = run.startTime - run.allowedStartTime
			if bestTimes.startTime == nil or startTime < bestTimes.startTime then
				bestTimes.startTime = startTime
			end
			
			for j = 1, #run.checkPointTimes do
				local checkPointTime = run.checkPointTimes[j] - run.allowedStartTime
				if bestTimes.checkPointTimes[j] == nil or checkPointTime < bestTimes.checkPointTimes[j] then
					bestTimes.checkPointTimes[j] = checkPointTime
				end
			end
			
			local finishTime = run.finishTimes[1] - run.allowedStartTime
			if bestTimes.finishTime == nil or finishTime < bestTimes.finishTime then
				bestTimes.finishTime = finishTime
			end
		end
    end
	return bestTimes
end

local function getHighScores(raceName)
    local results = loadAllResults(raceName)
	
    table.sort(results, function(a, b)
		if (a.resets or 0) ~= (b.resets or 0) then
			return (a.resets or 0) < (b.resets or 0)
		end
		return a.time < b.time
	end)
	
	
    local top = {}
    for i = 1, math.min(15, #results) do
        table.insert(top, results[i])
    end
    return top
end
-- helper function
local function formatTime(seconds)
    local days    = math.floor(seconds / 86400)
    local hours   = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs    = seconds % 60 -- keep fractional part

    local parts = {}

    if days > 0 then
        table.insert(parts, days.."d")
    end
    if hours > 0 or days > 0 then
        table.insert(parts, hours.."h")
    end
    if minutes > 0 or hours > 0 or days > 0 then
        table.insert(parts, minutes.."m")
    end

    -- show seconds with 3 decimals
    table.insert(parts, string.format("%.3fs", secs))

    return table.concat(parts, " ")
end
function BON_RaceScoreChatMessageHandler(sender_id, sender_name, message)
    if string.sub(message, 1, 1) ~= '/' then
        return 0
    end
    print("hmm...")
    local args = {}

    for arg in string.gmatch(message, "%S+") do
        table.insert(args, arg)
    end

    local command = args[1]

    local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp

    if args[1] == "/hs" and args[2] then
        local raceName = args[2]
        local top = getHighScores(raceName)
        if #top == 0 then
            sendInfoMessage(sender_id, "No results yet for race '"..raceName.."'")
        else
            local lines = {}
            for i, r in ipairs(top) do
                --table.insert(lines, i..". "..r.nick.." - "..string.format("%.3f", r.time).."s")
				
				table.insert(lines, i..". "..r.nick.." - "..timeTools.secondsToReadable(r.time).." (resets: "..tostring(r.resets or 0)..")")
            end
        sendInfoMessage(sender_id, "Top times for '"..raceName.."':\n"..table.concat(lines, "\n"))
		return 1
        end
    return 0
    end
end




function sendInfoMessage(sender_id, message, icon)
   icon = icon or "warning"
   MP.TriggerClientEventJson(sender_id, "BonRaceInfoMessage", { message = message, icon = "warning" })
end
function sendErrorMessage(sender_id, title, message)
   MP.TriggerClientEventJson(sender_id, "BonRaceErrorMessage", { title = title, message = message })
end
function sendNormalMessage(sender_id, message)
   MP.TriggerClientEventJson(sender_id, "BonRaceNormalMessage", { message = message })
end

print("RaceScore.lua loaded")
MP.RegisterEvent("onChatMessage", "BON_RaceScoreChatMessageHandler")
MP.RegisterEvent("playerHorn", "handlePlayerHorn")
