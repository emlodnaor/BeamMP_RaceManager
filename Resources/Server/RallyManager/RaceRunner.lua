------ Server -------
---------------------
--- BonRaceRunner ---
---------------------
---- Authored by ----
-- Beams of Norway --
---------------------

-- High-level design
-- - Race JSONs are immutable templates
-- - Mode is inferred from number of start positions (1 = rally, >1 = grid)
-- - Rally: per-player session; start times spaced by startInterval between instances
-- - Grid: lobby collects up to max players (default = #start positions)
--				 starts after lobby timeout since last join, or immediately when full,
--				 always respecting inter-instance spacing
-- - Finish trigger stays active for 30s; re-enter acts like re-entering autoloader
-- - Results are saved per session
-- - Per-player triggers are streamed: start, finish, current CP
-- - Trigger type names are normalized on server: "start", "cp", "finish", "autoloader"
--	 but we accept legacy names coming from client/files

-- State tables
local raceTemplates = {}			 -- [raceName] -> parsed template (immutable)
local raceState = {}					 -- [raceName] -> { nextInstanceEarliest, currentLobby, activeInstances }
local playerState = {}				 -- [mpUserId] -> { sessionId?, gridId?, lastRaceName?, lastFinishUntil?, lastFinishRaceName? }
local resultsHistory = {}			-- [mpUserId] -> { [raceName] = { runs... } }
local mpUserIdToSenderId = {}	-- [mpUserId] -> sender_id
local pendingCountdowns = {}
local COUNTDOWN_LEAD = 3 -- seconds

local function now()
	return os.time()
end

local function queueCountdownForPlayer(sender_id, raceName, slot, goAtServerTime)
	local fireAt = (goAtServerTime or now()) - COUNTDOWN_LEAD
	table.insert(pendingCountdowns, {
		sender_id = sender_id,
		raceName = raceName,
		slot = slot,
		fireAt = fireAt
	})
	print(goAtServerTime)
	print(fireAt)
	print(now())
	local countdown = (goAtServerTime or now()) - now()
	print(countdown)
	return countdown
end
-- Compatibility: keep a small subset of older globals used elsewhere
local hornUsage = {}

-- Constants / defaults
local DEFAULT_LOBBY_TIMEOUT = 15	-- seconds if not specified in template.grid.lobbyTimeout
local RESTART_HONK_WINDOW = 30	-- seconds after finish where honk near finish will restart
local TICK_INTERVAL_MS = 1000		 -- doThingsEverySecond timer period

-- Utility



local function countKeys(t)
	local c = 0
	for _ in pairs(t or {}) do c = c + 1 end
	return c
end

local function keys(t)
	local k = {}
	for kk in pairs(t or {}) do table.insert(k, kk) end
	return k
end

local function getBonServerPlayerInfo()
	local playerInfoTable = {
		NameFromSenderId = {},
		NameFromBeamMpId = {},
		SenderIdFromName = {},
		BeamMpIdFromSenderId = {},
		SenderIdFromBeamMPID = {},
		NameFromBeamMpId = {}
	}
	local sender_id2Name = MP.GetPlayers()
	for sender_id, name in pairs(sender_id2Name) do
		local ids = MP.GetPlayerIdentifiers(sender_id)
		local mpUserId = ids.beammp
		playerInfoTable.NameFromSenderId["_"..sender_id] = name
		playerInfoTable.SenderIdFromName[name] = sender_id
		playerInfoTable.BeamMpIdFromSenderId["_"..sender_id] = mpUserId
		playerInfoTable.SenderIdFromBeamMPID[mpUserId] = sender_id
		playerInfoTable.NameFromBeamMpId[mpUserId] = name
	end
	return playerInfoTable
end

local function sendInfoMessage(sender_id, message, icon)
	MP.TriggerClientEventJson(sender_id, "BonRaceInfoMessage", { message = message, icon = icon or "info" })
end

local function sendErrorMessage(sender_id, message)
	MP.TriggerClientEventJson(sender_id, "BonRaceErrorMessage", { message = message })
end

local function sendNormalMessage(sender_id, message)
	MP.TriggerClientEventJson(sender_id, "BonRaceNormalMessage", { message = message })
end

-- Trigger normalization

local function normalizeType(tt)
	if not tt then return nil end
	tt = tostring(tt)
	-- Accept variants and map to canonical
	local map = {
		start = "start", Start = "start", StartPosition = "start", START = "start",
		["CheckPoint"] = "cp", checkpoint = "cp", cp = "cp", CP = "cp",
		finish = "finish", Finish = "finish", endt = "finish", ["end"] = "finish", END = "finish",
		autoloader = "autoloader", AutoLoader = "autoloader"
	}
	return map[tt] or tt:lower()
end

local function normalizeTriggers(template)
	if not template or not template.triggers then return template end
	for _, t in pairs(template.triggers) do
		t.TriggerType = normalizeType(t.TriggerType)
		-- Standardize TriggerNumber to number when present
		if t.TriggerNumber ~= nil then
			local n = tonumber(t.TriggerNumber)
			if n ~= nil then t.TriggerNumber = n end
		end
	end
	return template
end

-- File IO

local function fetchRaceFromFile(raceName)
	local f = io.open("Resources\\Server\\RallyManager\\Races\\raceConfig_"..raceName..".json", "r")
	if not f then return nil end
	local content = f:read("*all")
	f:close()
	local t = Util.JsonDecode(content)
	return t
end

local function getSavedRaceNames()
	local raceNames = {}
	-- Windows-only dir; if needed, swap to platform-agnostic later
	local pipe = io.popen('dir /B Resources\\Server\\RallyManager\\Races\\raceConfig_*.json')
	if not pipe then 
	return raceNames 
	
	end
	for file in pipe:lines() do
		local _, _, raceName = file:find("raceConfig_(.-)%.json")
	if raceName then table.insert(raceNames, raceName) end
	end
	pipe:close()
	return raceNames
end

local function saveSessionResult(raceName, player)
	-- Persist one file per session
	-- player object contains fields we accumulated in-session
	local result = {
		raceName = raceName,
		playerId = player.mpUserId,
		nick = player.nick,
		startTime = player.startTime,
		allowedStartTime = player.allowedStartTime,
		checkPointTimes = player.checkPointTimes or {},
		finishTime = player.finishTime or {},
		endedAt = now()
	}
	local json = Util.JsonEncode(result)
	local file = io.open("Resources/Server/RallyManager/RaceResults/run_"..raceName.."_"..player.mpUserId.."_"..os.date("%Y%m%d_%H%M%S")..".json", "w")
	if file then
		file:write(json)
		file:close()
	end
end

-- Template/State access

local function getRaceTemplate(raceName)
	if raceTemplates[raceName] then return raceTemplates[raceName] end
	local t = fetchRaceFromFile(raceName)
	if not t then return nil end
	normalizeTriggers(t)
	-- Defaults
	t.startInterval = t.startInterval or 0
	t.grid = t.grid or {}
	t.grid.lobbyTimeout = t.grid.lobbyTimeout or DEFAULT_LOBBY_TIMEOUT
	-- mode is inferred: start positions count
	t._mode = (t.startPosition and #t.startPosition or 0) > 1 and "grid" or "rally"
	t._maxPlayers = (t._mode == "grid") and (#t.startPosition or 0) or 1
	raceTemplates[raceName] = t
	return t
end

local function ensureRaceState(raceName)
	if not raceState[raceName] then
		local tpl = getRaceTemplate(raceName)
		if not tpl then return nil end
		raceState[raceName] = {
			nextInstanceEarliest = 0,
			currentLobby = { players = {}, lastJoinAt = nil, timeoutSec = tpl.grid.lobbyTimeout, maxPlayers = tpl._maxPlayers },
			activeInstances = {} -- map of id -> instance (rally or grid)
		}
	end
	-- keep lobby params synced from template updates if needed
	local tpl = raceTemplates[raceName]
	raceState[raceName].currentLobby.timeoutSec = tpl.grid.lobbyTimeout
	raceState[raceName].currentLobby.maxPlayers = tpl._maxPlayers
	return raceState[raceName]
end

-- Trigger helpers

local function getRaceTriggerBy(raceName, triggerType, triggerNumber)
	local tpl = raceTemplates[raceName]
	if not tpl or not tpl.triggers then return nil end
	local tt = normalizeType(triggerType)
	for _, t in pairs(tpl.triggers) do
		if normalizeType(t.TriggerType) == tt then
			if triggerNumber == nil then return t end
			if tonumber(t.TriggerNumber) == tonumber(triggerNumber) then
				return t
			end
		end
	end
	return nil
end


local function SpawnRaceTriggersForPlayer(mpUserId, raceName)
	local serverPlayerInfo = getBonServerPlayerInfo()
	local sender_id = serverPlayerInfo.SenderIdFromBeamMPID[mpUserId]
	local tpl = raceTemplates[raceName]
	if not tpl then return end
	
	
	for _, t in pairs(tpl.triggers) do
		if normalizeType(t.TriggerType) == "start" then
			MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", t)
		end
	end
	for _, t in pairs(tpl.triggers) do
		if normalizeType(t.TriggerType) == "finish" then
			MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", t)
		end
	end
	local firstCP = getRaceTriggerBy(raceName, "cp", 1)
	if firstCP then
		MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", firstCP)
	end
	
end

local function removeAllRaceTriggersForPlayer(sender_id, raceName)
	local tpl = raceTemplates[raceName]
	if not tpl or not tpl.triggers then return end
	for _, t in pairs(tpl.triggers) do
		if t.triggerName then
			MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = t.triggerName })
		end
	end
end

local function removeFinishTriggersForPlayer(sender_id, raceName)
	local tpl = raceTemplates[raceName]
	if not tpl or not tpl.triggers then return end
	for _, t in pairs(tpl.triggers) do
		if normalizeType(t.TriggerType) == "finish" and t.triggerName then
			MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = t.triggerName })
		end
	end
end


local function teleportPlayer(raceName, mpUserId, startPositionIndex)
	local serverPlayerInfo = getBonServerPlayerInfo()
	local sender_id = serverPlayerInfo.SenderIdFromBeamMPID[mpUserId]
	local tpl = getRaceTemplate(raceName)
	local posRot = Util.JsonEncode(tpl.startPosition[startPositionIndex])
	MP.TriggerClientEvent(sender_id, "BonRaceTeleportInstuctions", posRot)
end

local function countdownPlayer(mpUserId)
	local serverPlayerInfo = getBonServerPlayerInfo()
	local sender_id = serverPlayerInfo.SenderIdFromBeamMPID[mpUserId]
	MP.TriggerClientEvent(sender_id, "BonRaceStartCountdown", "")
end

local function SpawnAutoloader(raceName, sender_id)
	local tpl = raceTemplates[raceName] or getRaceTemplate(raceName)
	if not tpl or not tpl.triggers then return end
	for _, trigger in pairs(tpl.triggers) do
		if normalizeType(trigger.TriggerType) == "autoloader" then
			MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", trigger)
		end
	end
end

local function SpawnAllAutoloadersForPlayer(sender_id)
	print("spwn")
	for _, raceName in pairs(getSavedRaceNames()) do
	print("spwn "..raceName)
		local tpl = getRaceTemplate(raceName)
		if tpl and tpl.autoloaderPosition then
			SpawnAutoloader(raceName, sender_id)
		end
	end
end

-- Instance spacing

local function scheduleInstanceStart(raceName)
	local st = ensureRaceState(raceName)
	if not st then return now() end
	local current = now()
	local startAt = math.max(current, st.nextInstanceEarliest or 0)
	local interval = (raceTemplates[raceName] and raceTemplates[raceName].startInterval) or 0
	-- Claim the window immediately so subsequent groups respect spacing
	st.nextInstanceEarliest = startAt + interval
	return startAt
end

-- Sessions and grid instances

local seqId = 0
local function newId()
	seqId = seqId + 1
	return tostring(seqId).."_"..tostring(now())
end

local function startRallyFlow(mpUserId, sender_id, raceName)
	local tpl = getRaceTemplate(raceName)
	if not tpl then
		sendErrorMessage(sender_id, "Race not found: "..raceName)
		return
	end
	local st = ensureRaceState(raceName)
	if not st then return end

	local ps = playerState[mpUserId]
	if ps then
		if (ps.sessionId and raceState[ps.lastRaceName].activeInstances[ps.sessionId]) or (ps.gridId and raceState[ps.lastRaceName].activeInstances[ps.gridId]) then
			sendInfoMessage(sender_id, "You are already in a race.")
        return
    end
end
	
	local slot = 1 -- startPosition
	local startAt = scheduleInstanceStart(raceName)
	local sessionId = newId()
	local inst = {
		id = sessionId,
		type = "rally",
		raceName = raceName,
		playerId = mpUserId,
		startedAt = startAt,
		state = "waiting",
		data = {
			mpUserId = mpUserId,
			nick = getBonServerPlayerInfo().NameFromBeamMpId[mpUserId],
			serverScheduledStartAt = startAt,
			allowedStartTime = nil,
			startTime = nil,
			checkPointTimes = {},
			finishTime = {},
			nextCheckpoint = slot
		}
	}
	st.activeInstances[sessionId] = inst
	playerState[mpUserId] = { sessionId = sessionId, lastRaceName = raceName }

	local sid = getBonServerPlayerInfo().SenderIdFromBeamMPID[mpUserId]
	local countDownTime = queueCountdownForPlayer(sid, raceName, slot, startAt)
	
	sendInfoMessage(sender_id, "Rally run scheduled. Starting in "..countDownTime.." secs")
end

local function tryStartGrid(raceName)
	local tpl = getRaceTemplate(raceName)
	if not tpl then return end
	local st = ensureRaceState(raceName)
	if not st then return end
	local lobby = st.currentLobby
	local playerIds = keys(lobby.players)
	if #playerIds == 0 then return end

	local startAt = scheduleInstanceStart(raceName)

	local gridId = newId()
	local gridInst = {
		id = gridId,
		type = "grid",
		raceName = raceName,
		startedAt = startAt,
		state = "waiting",
		players = {} -- [mpUserId] -> per-player data
	}

	local serverPlayerInfo = getBonServerPlayerInfo()
	table.sort(playerIds, function(a, b) return tostring(a) < tostring(b) end)

	local slot = 1
	for _, pid in ipairs(playerIds) do
		gridInst.players[pid] = {
			mpUserId = pid,
			nick = serverPlayerInfo.NameFromBeamMpId[pid],
			serverScheduledStartAt = startAt,
			allowedStartTime = nil,
			startTime = nil,
			checkPointTimes = {},
			finishTime = {},
			nextCheckpoint = 1
		}
		playerState[pid] = { gridId = gridId, lastRaceName = raceName }
		local sid = serverPlayerInfo.SenderIdFromBeamMPID[pid]
		
		local countDownTime = queueCountdownForPlayer(sid, raceName, slot, startAt)
		
		slot = slot + 1
	end

	st.activeInstances[gridId] = gridInst
	st.currentLobby.players = {}
	st.currentLobby.lastJoinAt = nil
end

local function addToGridLobby(mpUserId, sender_id, raceName)
	local tpl = getRaceTemplate(raceName)
	if not tpl then
		sendErrorMessage(sender_id, "Race not found: "..raceName)
		return
	end
	local st = ensureRaceState(raceName)
	if not st then return end

	if playerState[mpUserId] and (playerState[mpUserId].sessionId or playerState[mpUserId].gridId) then
		sendInfoMessage(sender_id, "You are already in a race.")
		return
	end

	local lobby = st.currentLobby
	lobby.players[mpUserId] = true
	lobby.lastJoinAt = now()

	local present = countKeys(lobby.players)
	MP.TriggerClientEventJson(sender_id, "BonRaceLobbyStatus", {
		raceName = raceName, players = present, max = lobby.maxPlayers
	})

	if present >= lobby.maxPlayers then
		tryStartGrid(raceName)
	else
		sendInfoMessage(sender_id, "Joined grid lobby ("..present.."/"..lobby.maxPlayers..").")
	end
end

-- Public flow: autoloader entry

local function onAutoloaderEnter(sender_id, raceName)
	local ids = MP.GetPlayerIdentifiers(sender_id)
	local mpUserId = ids.beammp
	local nick = MP.GetPlayerName(sender_id)
	mpUserIdToSenderId[mpUserId] = sender_id

	local tpl = getRaceTemplate(raceName)
	if not tpl then
		sendErrorMessage(sender_id, "Race not found: "..raceName)
		return
	end

	if tpl._mode == "rally" then
		startRallyFlow(mpUserId, sender_id, raceName)
	else
		addToGridLobby(mpUserId, sender_id, raceName)
	end
end

-- Tick: handle grid lobby timeout and finish window cleanup

local function tickLobbies()
	local t = now()
	for raceName, st in pairs(raceState) do
		local lobby = st.currentLobby
		if lobby and countKeys(lobby.players) > 0 and lobby.lastJoinAt and (t - lobby.lastJoinAt) >= (lobby.timeoutSec or DEFAULT_LOBBY_TIMEOUT) then
			tryStartGrid(raceName)
		end
	end
end

-- removed: finish re-enter window cleanup (replaced by honk-to-restart window that needs no periodic cleanup)

local function tickCountdowns()
	local serverPlayerInfo = getBonServerPlayerInfo()
	local t = now()
	for i = #pendingCountdowns, 1, -1 do
		local item = pendingCountdowns[i]
		if t >= item.fireAt then
			-- Fire countdown exactly 3s before go
			mpUserId = serverPlayerInfo.BeamMpIdFromSenderId["_"..item.sender_id]
			SpawnRaceTriggersForPlayer(mpUserId, item.raceName)
			teleportPlayer(item.raceName, mpUserId, item.slot)
			MP.TriggerClientEvent(item.sender_id, "BonRaceStartCountdown", "")
			table.remove(pendingCountdowns, i)
		end
	end
end

function doThingsEverySecond()
	tickLobbies()
	tickCountdowns()
end



-- Client world readiness / autoloaders

function handlePlayerWorldReadyState(sender_id, data)
	
	local dataTable = Util.JsonDecode(data)
	if dataTable.state == 2 then
	
		MP.TriggerClientEvent(sender_id, "BonRaceFatalError", "") -- clear triggers fast
		SpawnAllAutoloadersForPlayer(sender_id)
	end
	local ids = MP.GetPlayerIdentifiers(sender_id)
	mpUserIdToSenderId[ids.beammp] = sender_id
end

-- Horn detector passthrough (kept as-is for now)

function handleOnVehicleSpawn(sender_id)
	MP.TriggerClientEventJson(sender_id, "BonRaceLoadHornDetector", { })
end

function handlePlayerHorn(sender_id, data)
	local dataTable = Util.JsonDecode(data)
	hornUsage[sender_id] = hornUsage[sender_id] or {}
	if dataTable.state == "on" then
		hornUsage[sender_id].onTime = os.clock()
	elseif dataTable.state == "off" then
		hornUsage[sender_id].offTime = os.clock()
		local dur = (hornUsage[sender_id].offTime or 0) - (hornUsage[sender_id].onTime or 0)
		if dur > 1 then
			-- Optional: find nearest autoloader and treat as autoloader enter.
			-- Left for future enhancement.
		end
	end
end

-- Trigger handling

function handleBonRaceReportClientStartTime(sender_id, data)
	local dataTable = Util.JsonDecode(data)
	local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp
	local ps = playerState[mpUserId]
	if not ps then return end

	local raceName = ps.lastRaceName
	if not raceName then return end

	if ps.sessionId then
		local inst = raceState[raceName].activeInstances[ps.sessionId]
		if inst and inst.data then
			inst.data.allowedStartTime = dataTable.osclockhp
		end
	elseif ps.gridId then
		local inst = raceState[raceName].activeInstances[ps.gridId]
		if inst and inst.players and inst.players[mpUserId] then
			inst.players[mpUserId].allowedStartTime = dataTable.osclockhp
		end
	end
end

local function onPlayerStarted(raceName, mpUserId, startTime, sender_id)
	local ps = playerState[mpUserId]
	if not ps then return end
	if ps.sessionId then
		local inst = raceState[raceName].activeInstances[ps.sessionId]
		if inst and inst.data then
			inst.data.startTime = startTime
			-- Jump start check happens below on the same event flow
		end
	elseif ps.gridId then
		local inst = raceState[raceName].activeInstances[ps.gridId]
		if inst and inst.players and inst.players[mpUserId] then
			inst.players[mpUserId].startTime = startTime
		end
	end
end

local function addCheckpointTime(raceName, mpUserId, cpNum, tstamp)
	local ps = playerState[mpUserId]
	if not ps then return end
	if ps.sessionId then
		local inst = raceState[raceName].activeInstances[ps.sessionId]
		if inst and inst.data then
			inst.data.checkPointTimes[cpNum] = tstamp
			inst.data.nextCheckpoint = (cpNum or 0) + 1
		end
	elseif ps.gridId then
		local inst = raceState[raceName].activeInstances[ps.gridId]
		if inst and inst.players and inst.players[mpUserId] then
			inst.players[mpUserId].checkPointTimes[cpNum] = tstamp
			inst.players[mpUserId].nextCheckpoint = (cpNum or 0) + 1
		end
	end
end

local function onPlayerFinished(raceName, mpUserId, finishNum, tstamp, sender_id)
	local ps = playerState[mpUserId]
	if not ps then return end

	local record
	if ps.sessionId then
		local inst = raceState[raceName].activeInstances[ps.sessionId]
		if inst and inst.data then
			inst.data.finishTime[finishNum] = tstamp
			record = inst.data
			-- Persist result and cleanup the rally instance
			saveSessionResult(raceName, record)
			raceState[raceName].activeInstances[ps.sessionId] = nil
			playerState[mpUserId].sessionId = nil
		end
	elseif ps.gridId then
		local inst = raceState[raceName].activeInstances[ps.gridId]
		if inst and inst.players and inst.players[mpUserId] then
			inst.players[mpUserId].finishTime[finishNum] = tstamp
			record = inst.players[mpUserId]
			-- Persist immediately for this finisher; the grid instance remains for others
			saveSessionResult(raceName, record)
			-- Clear player from grid context
			inst.players[mpUserId] = inst.players[mpUserId] -- keep for standings if needed
			playerState[mpUserId].gridId = nil
		end
	end

	if record then
		local timeDiff = (record.allowedStartTime and tstamp and (tstamp - record.allowedStartTime)) or nil
		if timeDiff then
			sendNormalMessage(sender_id, "Finish Time: "..timeDiff)
			MP.SendChatMessage(-1, (record.nick or tostring(mpUserId)).." finished '"..raceName.."' with time: "..timeDiff)
		end
	end

	-- Remove finish and other race triggers immediately; switching to honk-to-restart flow
	removeFinishTriggersForPlayer(sender_id, raceName)
	local tpl = raceTemplates[raceName]
	if tpl then
		for _, t in pairs(tpl.triggers) do
			local tt = normalizeType(t.TriggerType)
			if (tt == "start" or tt == "cp") and t.triggerName then
				MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = t.triggerName })
			end
		end
	end

	-- Mark player eligible to restart this race via honk for a short window
	playerState[mpUserId].restartEligibleUntil = now() + RESTART_HONK_WINDOW
	playerState[mpUserId].restartRaceName = raceName
end

local function checkJumpStartAndReact(sender_id, raceName, mpUserId, startTime)
	local ps = playerState[mpUserId]
	if not ps then return end
	local allowed
	if ps.sessionId then
		local inst = raceState[raceName].activeInstances[ps.sessionId]
		allowed = inst and inst.data and inst.data.allowedStartTime
	elseif ps.gridId then
		local inst = raceState[raceName].activeInstances[ps.gridId]
		allowed = inst and inst.players and inst.players[mpUserId] and inst.players[mpUserId].allowedStartTime
	end
	if not allowed then return end
	local diff = startTime - allowed
	if diff < 0 then
		MP.TriggerClientEventJson(sender_id, "BonRaceDISQUALIFIED", { timeDiff = diff })
		sendNormalMessage(sender_id, "DISQUALIFIED! Headstart by "..diff)
		-- Mark finishTime as -1
		if ps.sessionId then
			local inst = raceState[raceName].activeInstances[ps.sessionId]
			if inst and inst.data then inst.data.finishTime["1"] = -1 end
			raceState[raceName].activeInstances[ps.sessionId] = nil
			playerState[mpUserId].sessionId = nil
		elseif ps.gridId then
			local inst = raceState[raceName].activeInstances[ps.gridId]
			if inst and inst.players and inst.players[mpUserId] then inst.players[mpUserId].finishTime["1"] = -1 end
			playerState[mpUserId].gridId = nil
		end
		MP.TriggerClientEvent(sender_id, "BonRaceFatalError", "") -- unload triggers fast
	else
		sendNormalMessage(sender_id, "Reaction time: "..diff)
	end
end

-- Event: BeamNG trigger callback (unified)

function handleOnBeamNGTriggerBonRace(sender_id, data)
	local dataTable = Util.JsonDecode(data)
	local triggerInfo = dataTable.triggerInfo or {}
	triggerInfo.TriggerType = normalizeType(triggerInfo.TriggerType)

	local ids = MP.GetPlayerIdentifiers(sender_id)
	local mpUserId = ids.beammp
	local nick = MP.GetPlayerName(sender_id)
	mpUserIdToSenderId[mpUserId] = sender_id



	if triggerInfo.event == "enter" and triggerInfo.TriggerType == "autoloader" then
		onAutoloaderEnter(sender_id, triggerInfo.raceName)
		return
	end

	-- Require being in a race context for the rest
	local ps = playerState[mpUserId]
	if not ps then return end
	local raceName = ps.lastRaceName
	if not raceName then return end

	-- Not started yet is okay; we process based on types below
	if triggerInfo.event == "exit" and triggerInfo.TriggerType == "start" then
		local stime = dataTable.osclockhp
		local recordAllowed
		if ps.sessionId then
			local inst = raceState[raceName].activeInstances[ps.sessionId]
			if inst and inst.data then recordAllowed = inst.data.allowedStartTime end
		elseif ps.gridId then
			local inst = raceState[raceName].activeInstances[ps.gridId]
			if inst and inst.players and inst.players[mpUserId] then recordAllowed = inst.players[mpUserId].allowedStartTime end
		end
		-- store startTime
		onPlayerStarted(raceName, mpUserId, stime, sender_id)
		-- jump start check
		checkJumpStartAndReact(sender_id, raceName, mpUserId, stime)
		-- remove start trigger for this player
		MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = triggerInfo.triggerName })
		return
	end

	if triggerInfo.event == "enter" and triggerInfo.TriggerType == "cp" then
		addCheckpointTime(raceName, mpUserId, triggerInfo.TriggerNumber, dataTable.osclockhp)

		local allowed
		if ps.sessionId then
			local inst = raceState[raceName].activeInstances[ps.sessionId]
			allowed = inst and inst.data and inst.data.allowedStartTime
		elseif ps.gridId then
			local inst = raceState[raceName].activeInstances[ps.gridId]
			allowed = inst and inst.players and inst.players[mpUserId] and inst.players[mpUserId].allowedStartTime
		end

		if allowed then
			local diff = dataTable.osclockhp - allowed
			sendNormalMessage(sender_id, "Checkpoint "..tostring(triggerInfo.TriggerNumber).." : "..diff)
		end

		-- progressive CP streaming
		MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = triggerInfo.triggerName })
		local nextNum = (tonumber(triggerInfo.TriggerNumber) or 0) + 1
		local nextCP = getRaceTriggerBy(raceName, "cp", nextNum)
		if nextCP then
			MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", nextCP)
		end
		return
	end

	if triggerInfo.event == "enter" and triggerInfo.TriggerType == "finish" then
		onPlayerFinished(raceName, mpUserId, triggerInfo.TriggerNumber, dataTable.osclockhp, sender_id)
		return
	end
end

-- Chat commands (trimmed down for admin/utility; gameplay is now commandless)

function BONRaceRunnerChatMessageHandler(sender_id, sender_name, message)
	if string.sub(message, 1, 1) ~= '/' then
		return 0
	end
	local args = {}
	for arg in string.gmatch(message, "%S+") do table.insert(args, arg) end

	if args[1] == "/fatalError" then
		raceTemplates = {}
		raceState = {}
		playerState = {}
		resultsHistory = {}
		mpUserIdToSenderId = {}
		MP.TriggerClientEvent(-1, "BonRaceFatalError", "")
		MP.SendChatMessage(-1, "RaceRunner reset.")
		return 1
	end

	if args[1] == "/listRaces" then
		local names = table.concat(getSavedRaceNames(), ", ")
		sendInfoMessage(sender_id, "Available races: "..names)
		return 1
	end

	return 1
end

-- World init

function onInit()
	MP.RegisterEvent("onChatMessage", "BONRaceRunnerChatMessageHandler")
	MP.RegisterEvent("onBeamNGTriggerBonRace", "handleOnBeamNGTriggerBonRace")
	MP.RegisterEvent("BonRaceReportClientStartTime", "handleBonRaceReportClientStartTime")
	MP.RegisterEvent("playerHorn", "handlePlayerHorn")
	MP.RegisterEvent("onVehicleSpawn", "handleOnVehicleSpawn")
	MP.RegisterEvent("PlayerWorldReadyState", "handlePlayerWorldReadyState")
	MP.CancelEventTimer("doThingsEverySecond")
	MP.RegisterEvent("doThingsEverySecond", "doThingsEverySecond")
	MP.CreateEventTimer("doThingsEverySecond", TICK_INTERVAL_MS)
end

onInit()
