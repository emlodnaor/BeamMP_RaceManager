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
local admins = {
    adminUser1 = true,
    adminUser2 = true,
    adminUser3 = true,
}
local timeTools = nil
timeTools = require("Resources/Server/Globals/timeTools")

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
	local target = goAtServerTime or now()
	local fireAt = target - COUNTDOWN_LEAD
	table.insert(pendingCountdowns, {
		sender_id = sender_id,
		raceName = raceName,
		slot = slot,
		fireAt = fireAt
	})
	local countdown = math.max(0, target - now())
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
		if mpUserId == nil then goto getBonServerPlayerInfoContinue end
		playerInfoTable.NameFromSenderId["_"..sender_id] = name
		playerInfoTable.SenderIdFromName[name] = sender_id
		playerInfoTable.BeamMpIdFromSenderId["_"..sender_id] = mpUserId
		playerInfoTable.SenderIdFromBeamMPID[mpUserId] = sender_id
		playerInfoTable.NameFromBeamMpId[mpUserId] = name
		::getBonServerPlayerInfoContinue::
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
		finish = "finish", Finish = "finish", endt = "finish", ["end"] = "finish", END = "finish", endlap = "finish",
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
	local f = io.open("Resources\\Server\\RaceManager\\Races\\raceConfig_"..raceName..".json", "r")
	if not f then return nil end
	local content = f:read("*all")
	f:close()
	local t = Util.JsonDecode(content)
	return t
end

local function getSavedRaceNames()
	local raceNames = {}
	local racesPath = "Resources/Server/RaceManager/Races/"
	
	-- Use FS.ListFiles instead of dir command
	local files = FS.ListFiles(racesPath)
	if not files then 
		print("WARNING: Could not list files in "..racesPath)
		return raceNames 
	end
	
	for _, file in ipairs(files) do
		-- Filter for files matching pattern: raceConfig_*.json
		local raceName = file:match("^raceConfig_(.-)%.json$")
		if raceName then 
			table.insert(raceNames, raceName) 
		end
	end
	
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
		resetsCount = player.resetsCount or 0,
		endedAt = now(),
		vehicleData = player.vehicleData
		
	}
	local json = Util.JsonEncode(result)
	local file = io.open("Resources/Server/RaceManager/RaceResults/run_"..raceName.."_"..player.mpUserId.."_"..os.date("%Y%m%d_%H%M%S")..".json", "w")
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
	--t._maxPlayers = (t._mode == "grid") and (#t.startPosition or 0) or 1
	t._maxPlayers = (t._mode == "grid") and (t.startPosition and #t.startPosition or 0) or 1
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

local function spawnFinishTriggerForPlayer(sender_id, raceName)
	local tpl = raceTemplates[raceName]
	if not tpl then return end
	
	for _, t in pairs(tpl.triggers) do
		if normalizeType(t.TriggerType) == "finish" then
			MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", t)
		end
	end
end

local function getTotalCheckpoints(raceName)
	local tpl = raceTemplates[raceName]
	if not tpl or not tpl.triggers then return 0 end
	
	local maxCP = 0
	for _, t in pairs(tpl.triggers) do
		if normalizeType(t.TriggerType) == "cp" then
			local cpNum = tonumber(t.TriggerNumber) or 0
			if cpNum > maxCP then
				maxCP = cpNum
			end
		end
	end
	return maxCP
end

local function SpawnRaceTriggersForPlayer(mpUserId, raceName, startPositionIndex)
	local serverPlayerInfo = getBonServerPlayerInfo()
	local sender_id = serverPlayerInfo.SenderIdFromBeamMPID[mpUserId]
	local tpl = raceTemplates[raceName]
	if not tpl then return end
	
	
	for _, t in pairs(tpl.triggers) do
		if normalizeType(t.TriggerType) == "start" then
			if t.TriggerNumber == startPositionIndex then
				MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", t)
			end
		end
	end
	for _, t in pairs(tpl.triggers) do
		if normalizeType(t.TriggerType) == "finish" then
			-- MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", t)
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
			if string.find(t.triggerName, "AutoLoader") then goto continue end
			MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = t.triggerName })
			::continue::
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

local function teleportPlayerToAutoloader(raceName, mpUserId)
	local serverPlayerInfo = getBonServerPlayerInfo()
	local sender_id = serverPlayerInfo.SenderIdFromBeamMPID[mpUserId]
	local tpl = getRaceTemplate(raceName)
	local posRot = Util.JsonEncode(tpl.autoloaderPosition)
	MP.TriggerClientEvent(sender_id, "BonRaceTeleportInstuctions", posRot)
end

local function countdownPlayer(mpUserId)
	local serverPlayerInfo = getBonServerPlayerInfo()
	local sender_id = serverPlayerInfo.SenderIdFromBeamMPID[mpUserId]
	MP.TriggerClientEvent(sender_id, "BonRaceStartCountdown", "")
end

function BonRaceManager_SpawnAutoloader(raceName, sender_id)
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
			BonRaceManager_SpawnAutoloader(raceName, sender_id)
		end
	end
end

-- Instance spacing
local function scheduleInstanceStart(raceName)
    local st = ensureRaceState(raceName)
    if not st then return now() end

    local current = now()
    local interval = (raceTemplates[raceName] and raceTemplates[raceName].startInterval) or 0

    -- Use the later of "now" or the previously claimed earliest time
    local startAt = math.max(current, st.nextInstanceEarliest or 0)

    -- Claim the next window immediately so subsequent calls respect spacing
    st.nextInstanceEarliest = startAt + interval

    return startAt
end

-- Sessions and grid instances

local seqId = 0
local function newId()
	seqId = seqId + 1
	return tostring(seqId).."_"..tostring(now())
end

local function getInstanceFor(ps)
	if not ps or not ps.lastRaceName then return nil end
	local rs = raceState[ps.lastRaceName]
	if not rs or not rs.activeInstances then return nil end
	if ps.sessionId then return rs.activeInstances[ps.sessionId] end
	if ps.gridId then return rs.activeInstances[ps.gridId] end
	return nil
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
	local existing = getInstanceFor(ps)
	if existing then
		sendInfoMessage(sender_id, "You are already in a race.")
		return
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
			nextCheckpoint = slot,
			resetsCount = 0
		},
		playerBestTimes = GetPlayerBestTimes(sender_id, raceName)
	}
	st.activeInstances[sessionId] = inst
	playerState[mpUserId] = { sessionId = sessionId, lastRaceName = raceName }

	local sid = getBonServerPlayerInfo().SenderIdFromBeamMPID[mpUserId]
	local countDownTime = queueCountdownForPlayer(sid, raceName, slot, startAt)
	
	--sendInfoMessage(sender_id, "Rally run scheduled. Starting in "..countDownTime.." secs")
	sendInfoMessage(sender_id, string.format("Rally run scheduled. Starting in "..timeTools.secondsToReadable(countDownTime)))
	
	--print(st)
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
			nextCheckpoint = 1,
			resetsCount = 0
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


local function isWaitingForStart(rec)
	-- queued but not yet started, and server start time is in the future
	return rec
	   and not rec.startTime
	   and rec.serverScheduledStartAt
	   and now() < rec.serverScheduledStartAt
end

local function getCurrentPlayerRecord(mpUserId, raceName)
	local ps = playerState[mpUserId]
	if not ps then return nil end
	local st = raceState[raceName]
	if not st or not st.activeInstances then return nil end
	if ps.sessionId then
		local inst = st.activeInstances[ps.sessionId]
		return inst and inst.data or nil
	elseif ps.gridId then
		local inst = st.activeInstances[ps.gridId]
		return inst and inst.players and inst.players[mpUserId] or nil
	end
	return nil
end

-- Public flow: autoloader entry

local function onAutoloaderEnter(sender_id, raceName)
	
	local ids = MP.GetPlayerIdentifiers(sender_id)
	local mpUserId = ids.beammp
	if mpUserId == nil then
		sendInfoMessage(sender_id, "Please sign in with or get a BeamMP user account to enjoy races...")
		return
	end
	
	local nick = MP.GetPlayerName(sender_id)
	
	local ps = playerState[mpUserId]
	if ps and ps.lastRaceName == raceName and (ps.sessionId or ps.gridId) then
		-- Player is already in this race; check whether they're merely queued for a future start
		local rec = getCurrentPlayerRecord(mpUserId, raceName)
		if isWaitingForStart(rec) then
			-- Already queued for this race and waiting; do nothing (don't retire, don't re-enqueue)
			local secs = math.max(0, (rec.serverScheduledStartAt or now()) - now())
			
			sendInfoMessage(sender_id, "You are already queued. Starts in "..timeTools.secondsToReadable(secs))
			
			return
		end
	end
	retirePlayer(sender_id, nick)
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
			local mpUserId = serverPlayerInfo.BeamMpIdFromSenderId["_"..item.sender_id]
			
			if not mpUserId then
				table.remove(pendingCountdowns, i)
				goto continue_tickCountdown
			end
			
			SpawnRaceTriggersForPlayer(mpUserId, item.raceName, item.slot)
			teleportPlayer(item.raceName, mpUserId, item.slot)
			MP.TriggerClientEvent(item.sender_id, "BonRaceStartCountdown", "")
			table.remove(pendingCountdowns, i)
			::continue_tickCountdown::
		end
	end
end

function doThingsEverySecond()
	--print(extensions.RaceScore.superTest())
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
	print("onVehicleSpawn...")
	MP.TriggerClientEventJson(sender_id, "BonRaceLoadHornDetector", { })
end

function handlePlayerHorn(sender_id, data)
	print("beep")
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
			inst.data.vehicleData = getPlayerVehicleData(sender_id)
			-- Jump start check happens below on the same event flow
		end
	elseif ps.gridId then
		local inst = raceState[raceName].activeInstances[ps.gridId]
		if inst and inst.players and inst.players[mpUserId] then
			inst.players[mpUserId].startTime = startTime
			inst.players[mpUserId].vehicleData = getPlayerVehicleData(sender_id)
		end
	end
	local totalCheckpoints = getTotalCheckpoints(raceName)
	if totalCheckpoints == 0 then
		spawnFinishTriggerForPlayer(sender_id, raceName)
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

local function allGridPlayersDone(inst)
	-- Consider a player "done" if they have any finishTime recorded, including DQ = -1
	for _, pdata in pairs(inst.players or {}) do
		local ft = pdata and pdata.finishTime
		if not ft or next(ft) == nil then
			return false
		end
	end
	return true
end
local function generateBestDiffString(bestTime, thisTime)
	if bestTime == nil then return "" end
	if thisTime == nil then return "" end
	local bestDiff = thisTime - bestTime
	local plus = ""
	if bestDiff > 0 then plus = "+" end
	return "("..plus..timeTools.secondsToReadable(bestDiff)..")"
end
local function onPlayerFinished(raceName, mpUserId, finishNum, tstamp, sender_id)
	local ps = playerState[mpUserId]
	if not ps then return end

	local st = raceState[raceName]
	if not st or not st.activeInstances then return end

	local record
	local inst
	if ps.sessionId then
		-- Rally flow
		inst = st.activeInstances[ps.sessionId]
		if inst and inst.data then
			inst.data.finishTime[tonumber(finishNum) or 1] = tstamp
			record = inst.data

			-- Persist and cleanup rally instance
			saveSessionResult(raceName, record)
			st.activeInstances[ps.sessionId] = nil
			playerState[mpUserId].sessionId = nil
		end

	elseif ps.gridId then
		-- Grid flow
		local gridId = ps.gridId
		inst = st.activeInstances[gridId]
		if inst and inst.players and inst.players[mpUserId] then
			inst.players[mpUserId].finishTime[tonumber(finishNum) or 1] = tstamp
			record = inst.players[mpUserId]

			-- Persist immediately for this finisher; grid may keep running for others
			saveSessionResult(raceName, record)

			-- Detach player from grid context
			playerState[mpUserId].gridId = nil

		end
	end

	-- User messages
	if record and record.allowedStartTime and tstamp then
		local timeDiff = tstamp - record.allowedStartTime
		local bestDiffString = ""
		if inst.playerBestTimes ~= nil then
			local best = inst.playerBestTimes.finishTime
			bestDiffString = generateBestDiffString(best, timeDiff)
		end
		
		sendNormalMessage(sender_id, "Finish Time: "..timeTools.secondsToReadable(timeDiff).." "..bestDiffString)
		
		
		MP.SendChatMessage(
			-1,
			string.format("%s finished '%s' with time: %s",
				record.nick or tostring(mpUserId), raceName, timeTools.secondsToReadable(timeDiff))
		)
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

	--
	if ps.gridId then -- If everyone in a grid race is now done (finished or DQ), prune the instance
		local inst = st.activeInstances[gridId]
		if allGridPlayersDone(inst) then
			st.activeInstances[gridId] = nil
		end
	end
	-- Mark player eligible to restart this race via honk for a short window
	playerState[mpUserId] = playerState[mpUserId] or {}
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
	local inst
	if diff < 0 then
		MP.TriggerClientEventJson(sender_id, "BonRaceDISQUALIFIED", { timeDiff = diff })
		print(diff)
		sendNormalMessage(sender_id, "DISQUALIFIED! Headstart by "..timeTools.secondsToReadable(diff))
		-- Mark finishTime as -1
		if ps.sessionId then
			inst = raceState[raceName].activeInstances[ps.sessionId]
			if inst and inst.data then inst.data.finishTime[1] = -1 end
			raceState[raceName].activeInstances[ps.sessionId] = nil
			playerState[mpUserId].sessionId = nil
		elseif ps.gridId then
			inst = raceState[raceName].activeInstances[ps.gridId]
			if inst and inst.players and inst.players[mpUserId] then inst.players[mpUserId].finishTime[1] = -1 end
			playerState[mpUserId].gridId = nil
		end
		removeAllRaceTriggersForPlayer(sender_id, raceName) -- MP.TriggerClientEvent(sender_id, "BonRaceFatalError", "") -- unload triggers fast
	else
		if ps.sessionId then
			inst = raceState[raceName].activeInstances[ps.sessionId]
		end
		if ps.gridId then
			inst = raceState[raceName].activeInstances[ps.gridId]
		end
		local bestDiffString = ""
		if inst.playerBestTimes ~= nil then
			local best = inst.playerBestTimes.startTime
			bestDiffString = generateBestDiffString(best, diff)
		end
		sendNormalMessage(sender_id, "Reaction time: "..timeTools.secondsToReadable(diff).." "..bestDiffString)
		
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
		
		local cpId = tonumber(triggerInfo.TriggerNumber)
		addCheckpointTime(raceName, mpUserId, cpId, dataTable.osclockhp)
		local inst
		local allowed
		if ps.sessionId then
			inst = raceState[raceName].activeInstances[ps.sessionId]
			allowed = inst and inst.data and inst.data.allowedStartTime
		elseif ps.gridId then
			inst = raceState[raceName].activeInstances[ps.gridId]
			allowed = inst and inst.players and inst.players[mpUserId] and inst.players[mpUserId].allowedStartTime
		end

		if allowed then
			local diff = dataTable.osclockhp - allowed
			local bestDiffString = ""
			if inst.playerBestTimes ~= nil then
				local best = inst.playerBestTimes.checkPointTimes[cpId]
				bestDiffString = generateBestDiffString(best, diff)
			end
			
			sendNormalMessage(sender_id, "Checkpoint "..tostring(triggerInfo.TriggerNumber).." : "..timeTools.secondsToReadable(diff).." "..bestDiffString)
		end

		-- progressive CP streaming
		MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = triggerInfo.triggerName })
		local nextNum = (tonumber(triggerInfo.TriggerNumber) or 0) + 1
		local nextCP = getRaceTriggerBy(raceName, "cp", nextNum)
		if nextCP then
			MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", nextCP)
		else
			spawnFinishTriggerForPlayer(sender_id, raceName)
		end
		return
	end

	if triggerInfo.event == "enter" and triggerInfo.TriggerType == "finish" then
		onPlayerFinished(raceName, mpUserId, triggerInfo.TriggerNumber, dataTable.osclockhp, sender_id)
		return
	end
end

function BONRaceRunnerChatMessageHandler(sender_id, sender_name, message)
	if string.sub(message, 1, 1) ~= '/' then
		return 0
	end
	
	local ids = MP.GetPlayerIdentifiers(sender_id)
	if not ids or not ids.beammp then return end
	local mpUserId = ids.beammp
	
	local args = {}
	for arg in string.gmatch(message, "%S+") do table.insert(args, arg) end

	if args[1] == "/fatalError" then
		if not admins[sender_name] then
			MP.SendChatMessage(sender_id, "You are not an admin, and can't use /fatalError")
			return 0 
		end
		raceTemplates = {}
		raceState = {}
		playerState = {}
		resultsHistory = {}
		mpUserIdToSenderId = {}
		MP.TriggerClientEvent(-1, "BonRaceFatalError", "")
		MP.SendChatMessage(-1, "RaceRunner reset.")
		SpawnAllAutoloadersForPlayer(-1)
		return 1
	end

	if args[1] == "/retire" then
		retirePlayer(sender_id, sender_name)
		return 1
	end
	
	if args[1] == "/tp" then
		local raceName = args[2]
		teleportPlayerToAutoloader(raceName, mpUserId)
		return 1
	end
	
	if args[1] == "/list" then
		local raceNames = getSavedRaceNames()
		local raceNamesString = table.concat(raceNames, ", ")
		MP.SendChatMessage(sender_id, 'The following races are available: ' .. raceNamesString)
		return 1
	end
	
	if args[1] == "/help" then
		MP.SendChatMessage(-1, '"/list" returns a list of races for this server...')
		MP.SendChatMessage(-1, '"/tp [raceName]" teleports to race autoloader...')
		MP.SendChatMessage(-1, '"/retire" retire from a race...')
		MP.SendChatMessage(-1, '"/hs [raceName]" shows highScore for raceName...')
	end
	return 0
end

function retirePlayer(sender_id, sender_name)
	local ids = MP.GetPlayerIdentifiers(sender_id)
	if not ids or not ids.beammp then return end
	local mpUserId = ids.beammp
	local ps = playerState[mpUserId]
	if not ps or not ps.lastRaceName then return end
	local st = raceState[ps.lastRaceName]
	if not st or not st.activeInstances then return end

	removeAllRaceTriggersForPlayer(sender_id, ps.lastRaceName)
	MP.SendChatMessage(-1, sender_name.." retired from race "..ps.lastRaceName)
	sendNormalMessage(sender_id, "You retired from "..ps.lastRaceName)

	if ps.sessionId then
		st.activeInstances[ps.sessionId] = nil
	elseif ps.gridId then
		local inst = st.activeInstances[ps.gridId]
		if inst and inst.players then
			inst.players[mpUserId] = nil
			-- if empty, remove the instance
			if countKeys(inst.players) == 0 then
				st.activeInstances[ps.gridId] = nil
			end
		end
	end
	playerState[mpUserId] = nil
end

-- World init
function onVehicleResetHandler(player_id, vehicle_id, data)
	local ids = MP.GetPlayerIdentifiers(player_id)
	if not ids or not ids.beammp then return end
	local mpUserId = ids.beammp

	local ps = playerState[mpUserId]
	if not ps then return end
	local raceName = ps.lastRaceName
	if not raceName then return end

	local record

	if ps.sessionId then
		local inst = raceState[raceName] and raceState[raceName].activeInstances[ps.sessionId]
		if inst and inst.data then record = inst.data end
	elseif ps.gridId then
		local inst = raceState[raceName] and raceState[raceName].activeInstances[ps.gridId]
		if inst and inst.players and inst.players[mpUserId] then record = inst.players[mpUserId] end
	end
	if not record then return end

	-- Count only during the run (after start trigger). Before start we ignore.
	if not record.startTime then return end

	record.resetsCount = (record.resetsCount or 0) + 1
	-- Optional: uncomment for debugging
	-- print("Reset counted for "..tostring(mpUserId).." ("..raceName.."): "..tostring(record.resetsCount))
end

function handleReportVehicleSpawnBBox(sender_id, data)
	print("handleReportVehicleSpawnBBox data recieved...")
end

function getPlayerVehicleData(sender_id)
	local playerVehicles = MP.GetPlayerVehicles(sender_id)
	if playerVehicles == nil then return end
	local beamMPid = MP.GetPlayerIdentifiers(sender_id).beammp
	if beamMPid == nil then return end
	local PlayerVehicleData = {}
	PlayerVehicleData.Vehicles = {}
	
	for key, value in pairs(playerVehicles) do
		PlayerVehicleData.Vehicles[key] = {}
		PlayerVehicleData.Vehicles[key].config = Util.JsonDecode(value:match("{.*}"))
	end
	return PlayerVehicleData
end

function handleOnPlayerDisconnect(sender_id)
    local ids = MP.GetPlayerIdentifiers(sender_id)
    if ids and ids.beammp then
        mpUserIdToSenderId[ids.beammp] = nil
        retirePlayer(sender_id, MP.GetPlayerName(sender_id))
    end
end

MP.RegisterEvent("onChatMessage", "BONRaceRunnerChatMessageHandler")
MP.RegisterEvent("onVehicleReset", "onVehicleResetHandler")
MP.RegisterEvent("onBeamNGTriggerBonRace", "handleOnBeamNGTriggerBonRace")
MP.RegisterEvent("ReportVehicleSpawnBBox", "handleReportVehicleSpawnBBox")
MP.RegisterEvent("BonRaceReportClientStartTime", "handleBonRaceReportClientStartTime")
MP.RegisterEvent("playerHorn", "handlePlayerHorn")
MP.RegisterEvent("onVehicleSpawn", "handleOnVehicleSpawn")
MP.RegisterEvent("PlayerWorldReadyState", "handlePlayerWorldReadyState")
MP.CancelEventTimer("doThingsEverySecond")
MP.RegisterEvent("doThingsEverySecond", "doThingsEverySecond")
MP.CreateEventTimer("doThingsEverySecond", TICK_INTERVAL_MS)
MP.RegisterEvent("onPlayerDisconnect", "handleOnPlayerDisconnect")
print("RaceRunner loaded... ...")
