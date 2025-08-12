------ Server -------
---------------------
--- BonRaceRunner ---
---------------------
---- Authored by ----
-- Beams of Norway --
---------------------
activeRaces = {}
activeUsers = {}
playerStartQues = {}
BonRaceDebug = false
mpUserIdToSenderId = {}
hornUsage = {}


function ForceUnload(raceName)
	if activeRaces[raceName] ~= nil then
		print(Util.JsonEncode(activeRaces[raceName]))
        activeRaces[raceName] = nil
        MP.SendChatMessage(-1, raceName.." race is Finished!")
	else
		MP.SendChatMessage(sender_id, raceName.." not loaded...")
	end
end
function BONRaceRunnerChatMessageHandler(sender_id, sender_name, message)
	
	print("SenderId: "..sender_id)
    if string.sub(message, 1, 1) ~= '/' then
        return 0
    end
    local args = {}

    for arg in string.gmatch(message, "%S+") do
        table.insert(args, arg)
    end

	
    local mpIdentifiers = MP.GetPlayerIdentifiers(sender_id)
    local mpUserId = mpIdentifiers.beammp
    local mpUserIp = mpIdentifiers.ip
    local mpUserNick = MP.GetPlayerName(sender_id)
	
	mpUserIdToSenderId[mpUserId] = sender_id
	
    if args[1] == "/debug" then
         BonRaceDebug = not BonRaceDebug
		 print("BonRaceDebug set to: "..tostring(BonRaceDebug))
    end
	
    if args[1] == "/fatalError" then
         print(Util.JsonEncode(activeRaces))
         print(Util.JsonEncode(activeUsers))
         print(Util.JsonEncode(playerStartQues))
         activeRaces = {}
         activeUsers = {}
         playerStartQues = {}
         MP.TriggerClientEvent(-1, "BonRaceFatalError", "")
         MP.SendChatMessage(-1, "Hard reset of RaceRunner performed, this does not affect race creation...")
    end
    if args[1] == "/forceUnload" then
        local raceName = args[2]
		ForceUnload(raceName)
        
    end
    if args[1] == "/loadrace" then
        local raceName = args[2]
		
		
        debugPrint("/loadrace "..raceName)
		
		
        if raceNameExists(raceName) and raceNotAlreadyInProgress(raceName) then
            
            activeRaces[raceName] = {
                loader = mpUserId,
                loaderNick = mpUserNick,
                players = {},
                started = false,
                toLateToJoin = false
            }

            debugPrint("lalala")
            activeRaces[raceName].race = fetchRaceFromFile(raceName)
            debugPrint("gogogo")
            if AddPlayerToRace(mpUserId, raceName) then
				raceLoadedSucessfully(sender_id, raceName)
			end
        else 
		
            cantLoadRace(sender_id, raceName)
        end
		
        return 1
    end

    if args[1] == "/join" then
        local raceName = args[2]
        debugPrint("/join "..raceName)
        if AddPlayerToRace(mpUserId, raceName) then
			sendInfoMessage(sender_id, "Joined race: "..raceNamesString)
		end
        return 1
    end

    if args[1] == "/startrace" then
        local raceName = args[2]
        if raceNameLoaded(raceName) and allowedToStartRace(raceName, mpUserId) then
            debugPrint()
            clearStartArea(raceName)
            debugPrint()
            activeRaces[raceName].started = true
            debugPrint()
            startTheRace(raceName)
        else
            sendErrorMessage(sender_id, "/loadrace 'name' first...")
        end
    end

    if args[1] == "/restartRace" then
        -- hmm
    end

    if args[1] == "/listRaces" then
        local raceNames = getSavedRaceNames()
        local raceNamesString = table.concat(raceNames, ", ")
        sendInfoMessage(sender_id, "CreatedRaces: "..raceNamesString)
    end
    return 1
end
function sendInfoMessage(sender_id, message, icon)
   icon = icon or "warning"
   print(sender_id)
   debugPrint("MP_Warning sent to"..sender_id..": "..message)
   MP.TriggerClientEventJson(sender_id, "BonRaceInfoMessage", { message = message, icon = "warning" })
end
function startTheRace(raceName)
    local playerCount = 0

    for _, _ in pairs(activeRaces[raceName].players) do
        playerCount = playerCount + 1
    end
    -- local playerCount = #activeRaces[raceName].players
    --debugPrint(Util.JsonEncode(activeRaces[raceName].players))
    local startPositions = #activeRaces[raceName].race.startPosition
    debugPrint()
    debugPrint(startPositions, playerCount)
    if startPositions >= playerCount then
        debugPrint()
        teleportPlayers(raceName)
        debugPrint()
        coutdownPlayers(raceName)
    else
        debugPrint()
        quePlayers(raceName)
        debugPrint()
    end
end
function quePlayers(raceName)
    local queCounter = 0
    for key, value in pairs(activeRaces[raceName].players) do
        local serverPlayerInfo = getBonServerPlayerInfo()
        local thisSenderId = serverPlayerInfo.SenderIdFromBeamMPID[value.mpUserId]
        playerStartQues[value.mpUserId] = { raceName = raceName, serverGoTime = os.time() + (15 * queCounter)}
        queCounter = queCounter + 1
    end
end
function handleBonRaceSendNextPlayer(...)
    --debugPrint(os.time())
    for key, value in pairs(playerStartQues) do
        debugPrint("Que: ",key,value)
        local player = key
        local raceName = value.raceName
        local serverGoTime = value.serverGoTime

        if os.time() > serverGoTime then
            debugPrint("Let's go:", raceName, player)
            teleportPlayer(raceName, player, 1)
            coutdownPlayer(raceName, player)
            playerStartQues[key] = nil
        end
    end
end


function AddPlayerToRace(mpUserId, raceName)
    debugPrint("Trying to add "..mpUserId.." to race: "..raceName.."")
    if raceNameLoaded(raceName) and PlayerNotInARace(mpUserId) and raceNotTooLateToJoin(raceName) then
		debugPrint("Adding player to race")
        activeUsers[mpUserId] = raceName
        playerCount = #activeRaces[raceName].players + 1
        activeRaces[raceName].players[mpUserId] = {
            mpUserId = mpUserId,
            nick = getBonServerPlayerInfo().NameFromBeamMpId[mpUserId],
            serverJoinTime = os.time(),
            allowedStartTime = nil,
            startTime = nil,
            checkPointTimes = {},
            finishTime = {},
			nextCheckpoint = 1
        }
		print("Got here 1")
        SpawnRaceTriggersForPlayer(mpUserId, raceName)
        raceJoinSucessfull(mpUserId) 
		return true
	else
		debugPrint("Failed to add "..mpUserId.." to race: "..raceName.."...")
		debugPrint("- raceNameLoaded: "..tostring(raceNameLoaded(raceName)))
		debugPrint("- PlayerNotInARace: "..tostring(PlayerNotInARace(mpUserId)))
		debugPrint("- raceNotTooLateToJoin: "..tostring(raceNotTooLateToJoin(raceName)))
		return false
    end
end

function getRaceTriggerBy(raceName, triggerType, triggerNumber)
    local triggers = activeRaces[raceName].race.triggers
	print(triggers)
    for _, t in pairs(triggers) do
        if t.TriggerType == triggerType then
            local num = tonumber(t.TriggerNumber)
            if triggerNumber == nil or (num ~= nil and num == tonumber(triggerNumber)) then
                return t
            end
        end
    end
	debugPrint("Trigger Not Found... raceName, triggerType, triggerNumber: "..raceName.." "..triggerType.." "..triggerNumber)
    return nil
end

function SpawnRaceTriggersForPlayer(mpUserId, raceName)
	print("Got here 2")
    debugPrint("SpawningInitialTriggersForPlayer")
    local sender_id = getBonServerPlayerInfo().SenderIdFromBeamMPID[mpUserId]

    local triggers = activeRaces[raceName].race.triggers
	print(triggers)
    -- Send StartPosition triggers
    for _, t in pairs(triggers) do
        if t.TriggerType == "start" then
            debugPrint("BonRaceCreateTrigger StartPosition -> "..sender_id)
            MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", t)
        end
    end

    -- Send Finish triggers
    for _, t in pairs(triggers) do
        if t.TriggerType == "end" then
            debugPrint("BonRaceCreateTrigger Finish -> "..sender_id)
            MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", t)
        end
    end

    -- Send first checkpoint only
    local firstCP = getRaceTriggerBy(raceName, "cp", 1)
    if firstCP then
        debugPrint("BonRaceCreateTrigger First CheckPoint -> "..sender_id)
        MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", firstCP)
    else
        debugPrint("No checkpoint #1 found for race "..raceName)
    end
end



function fetchRaceFromFile(raceName)
	local file = io.open("raceConfig_"..raceName..".json", "r")
    if file == nil then
        return nil
    end
    local content = file:read("*all")
    file:close()
    local contentTable = Util.JsonDecode(content)
    return contentTable
end

function getSavedRaceNames()
    local raceNames = {}

    local command = 'dir /B raceConfig_*.json'
    local pipe = io.popen(command)

    for file in pipe:lines() do
        local resultTable = file:find("raceConfig_(.-)%.json")
        local var1, var2, raceName = file:find("raceConfig_(.-)%.json")
        table.insert(raceNames, raceName)
    end

    pipe:close()

    return raceNames
end

function coutdownPlayers(raceName)
	local serverPlayerInfo = getBonServerPlayerInfo()
    for key, value in pairs(activeRaces[raceName].players) do
        coutdownPlayer(raceName, value.mpUserId)
    end
end
function coutdownPlayer(raceName, mpUserId)
	local serverPlayerInfo = getBonServerPlayerInfo()
    local thisSenderId = serverPlayerInfo.SenderIdFromBeamMPID[mpUserId]
	debugPrint("MP_TriggerClient BonRaceStartCountdown sent to"..mpUserIdToSenderId[mpUserId])
    MP.TriggerClientEvent(thisSenderId, "BonRaceStartCountdown", "")
end

function clearStartArea(raceName)
	-- body
end


function allowedToStartRace(raceName, mpUserId)
    if activeRaces[raceName].started == true then 
        return false 
    end
    if activeRaces[raceName].players[mpUserId] == nil then 
        return false 
    end
    return true
end

function teleportPlayers(raceName)
    local serverPlayerInfo = getBonServerPlayerInfo()
    
    local positionCounter = 1

	for key, value in pairs(activeRaces[raceName].players) do
        debugPrint()
        debugPrint(key)
        debugPrint(value)
        local mpUserId = value.mpUserId
        debugPrint(raceName, mpUserId, positionCounter)
        teleportPlayer(raceName, mpUserId, positionCounter)
        debugPrint()
        positionCounter = positionCounter + 1
        debugPrint()
    end
end
function teleportPlayer(raceName, mpUserId, startPosition)
        local serverPlayerInfo = getBonServerPlayerInfo()
        debugPrint(raceName, mpUserId, startPosition)
        --debugPrint(Util.JsonEncode(activeRaces[raceName].race))
        local posRot = Util.JsonEncode(activeRaces[raceName].race.startPosition[startPosition])
        debugPrint()
        local thisSenderId = serverPlayerInfo.SenderIdFromBeamMPID[mpUserId]
        debugPrint(thisSenderId)
        MP.TriggerClientEvent(thisSenderId, "BonRaceTeleportInstuctions", posRot)
        debugPrint()
end

function getBonServerPlayerInfo()
	local playerInfoTable = {
        NameFromSenderId = {},
        NameFromBeamMpId = {},
        SenderIdFromName = {},
        BeamMpIdFromSenderId = {},
        SenderIdFromBeamMPID = {}
    }
    local sender_id2Name = MP.GetPlayers()
    for key, value in pairs(sender_id2Name) do
        local sender_id = key
        local name = value
        local thisPlayerIdentifiers = MP.GetPlayerIdentifiers(sender_id)
        local mpUserId = thisPlayerIdentifiers.beammp
        playerInfoTable.NameFromSenderId["_"..sender_id] = name
        playerInfoTable.SenderIdFromName[name] = sender_id
        playerInfoTable.BeamMpIdFromSenderId["_"..sender_id] = mpUserId
        playerInfoTable.SenderIdFromBeamMPID[mpUserId] = sender_id
        playerInfoTable.NameFromBeamMpId[mpUserId] = name
        
    end
    return playerInfoTable
    --MP.GetPlayerName(sender_id)
end



function raceNameLoaded(raceName)
    local isLoaded = activeRaces[raceName] ~= nil
    if isLoaded then
        debugPrint(raceName.." is loaded")
    else
        debugPrint(raceName.." ISN'T loaded")
    end
    return isLoaded
end
function raceJoinSucessfull(mpUserId)
	print("raceJoinMeh "..mpUserId)
    sendInfoMessage(mpUserIdToSenderId[mpUserId], "You have joined the race: "..activeUsers[mpUserId], "check")
	debugPrint("Player "..mpUserId.." added to race")
end
function raceNotAlreadyInProgress(raceName)
    local result = activeRaces[raceName] == nil
    debugPrint("raceNotAlreadyInProgress: "..tostring(result))
	return result
end
function PlayerNotInARace(mpUserId)
    local result = activeUsers[mpUserId] == nil
    debugPrint("PlayerNotInARace: "..tostring(result))
    return result
end
function raceNotTooLateToJoin(raceName)
    local result = not activeRaces[raceName].toLateToJoin
    debugPrint("raceNotTooLateToJoin: "..tostring(result))    
	return result
end
function raceLoadedSucessfully(sender_id, raceName)
    debugPrint("raceLoadedSucessfully")
    sendNormalMessage(sender_id, raceName.." race loaded, /startrace when everybody has joined.")
end

function sendErrorMessage(sender_id, message)
   MP.TriggerClientEventJson(sender_id, "BonRaceErrorMessage", { message = message })
end
function sendNormalMessage(sender_id, message)
   MP.TriggerClientEventJson(sender_id, "BonRaceNormalMessage", { message = message })
end

function saveRace(raceName)
	jsonRace = Util.JsonEncode(races[raceName])
    -- Open the file for writing
    local file = io.open("raceConfig_"..raceName..".json", "w")

    if file == nil then
        debugPrint("Error opening file for writing.")
    else
    -- Write content to the file
    file:write(jsonRace)

    -- Close the file
    file:close()
    debugPrint("Race: "..jsonRace)
    end
end

function raceNameExists(raceName)
    debugPrint("Checking availability for race " .. raceName)
    local file = io.open("raceConfig_"..raceName..".json", "r")
    local exist = file ~= nil
    if exist then 
        file:close() 
        debugPrint(raceName.." does exist!")
    else
        debugPrint(raceName.." does NOT exist!")
    end
    
    
    return exist
end

function cantLoadRace(sender_id, raceName)
    debugPrint("cantLoadRace"..raceName)
    local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp
    if not raceNameExists(raceName) then
        sendErrorMessage(sender_id, "Race not found", "Cannot find a race with name "..raceName..". Try /listRaces")
    end
    if not raceNotAlreadyInProgress(raceName) then
        debugPrint()
        userName = activeRaces[raceName].loaderNick
        sendErrorMessage(sender_id, "Race already loaded: ", raceName.." is already loaded by"..userName)
    end 
    debugPrint("Cannot load race for sender_id " .. sender_id)
end
function allPlayersAreDone(raceName)
	for key, value in pairs(activeRaces[raceName].players) do
		print("-----------------------------------")
		print(value)
		print("...................................")
		print(value.finishTime)
		print("-----------------------------------")
		if next(value.finishTime) == nil then
			return false
		end
	end
	return true
end
function CheckIfAllPlayersAreDone(raceName)
	if allPlayersAreDone(raceName) then
		ForceUnload(raceName)
	end
end
function handleOnBeamNGTriggerBonRace(sender_id, data) 
	local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp
    if activeUsers[mpUserId] == nil then
        debugPrint("player not in active race")
        return
    end
    if not activeRaces[activeUsers[mpUserId]].started then
        debugPrint("Race not started")
        return
    end
    debugPrint("handeling trigger...")
    local dataTable = Util.JsonDecode(data)
    local triggerInfo = dataTable.triggerInfo

    if triggerInfo.event == "exit" and triggerInfo.TriggerType == "StartPosition" then
        debugPrint("triggerStartExit",tostring(dataTable.osclockhp))
        activeRaces[triggerInfo.raceName].players[mpUserId].startTime = dataTable.osclockhp
        checkIfPlayerStartedTooSoon(triggerInfo.raceName, mpUserId, sender_id)
		MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = triggerInfo.triggerName })
    end

    if triggerInfo.event == "enter" and triggerInfo.TriggerType == "CheckPoint" then
        debugPrint("cpEnter: "..triggerInfo.TriggerNumber.." ",tostring(dataTable.osclockhp))
        activeRaces[triggerInfo.raceName].players[mpUserId].checkPointTimes[triggerInfo.TriggerNumber] = dataTable.osclockhp
        sendRaceTimeInformation(triggerInfo, mpUserId, sender_id, dataTable.osclockhp)
		-- Progressive checkpoint streaming per player
        do
            local raceName = triggerInfo.raceName

            -- Remove the checkpoint the player just crossed
            MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = triggerInfo.triggerName })

            -- Compute next checkpoint (TriggerNumber is a string; coerce safely)
            local nextNum = (tonumber(triggerInfo.TriggerNumber) or 0) + 1
            activeRaces[raceName].players[mpUserId].nextCheckpoint = nextNum

            -- Spawn the next checkpoint for this player if it exists
            local nextCP = getRaceTriggerBy(raceName, "cp", nextNum)
            if nextCP then
                MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", nextCP)
                debugPrint("Spawned next CP "..nextNum.." for "..mpUserId)
            else
                debugPrint("No more checkpoints after "..(triggerInfo.TriggerNumber or "?").." for race "..raceName)
                -- Finish is already present
            end
        end
    end

    if triggerInfo.event == "enter" and triggerInfo.TriggerType == "Finish" then
        debugPrint("FinishEnter: "..triggerInfo.TriggerNumber.." ",tostring(dataTable.osclockhp))
        activeRaces[triggerInfo.raceName].players[mpUserId].finishTime[triggerInfo.TriggerNumber] = dataTable.osclockhp
        sendRaceTimeInformation(triggerInfo, mpUserId, sender_id, dataTable.osclockhp)
        debugPrint(mpUserId.." finished race!")
        --debugPrint(Util.JsonEncode(activeRaces[triggerInfo.raceName]))
        removeRaceTriggers(sender_id, triggerInfo.raceName)
        activeUsers[mpUserId] = nil  

		CheckIfAllPlayersAreDone(triggerInfo.raceName)
		
    end

    function sendRaceTimeInformation(triggerInfo, mpUserId, sender_id, osclockhp)
        local raceName = triggerInfo.raceName
        local timeDiff = osclockhp - activeRaces[raceName].players[mpUserId].allowedStartTime	  
        sendNormalMessage(sender_id, triggerInfo.TriggerType.." "..triggerInfo.TriggerNumber..": "..timeDiff)
        if triggerInfo.TriggerType == "Finish" then
            MP.SendChatMessage(-1, activeRaces[raceName].players[mpUserId].nick.." finished race '"..raceName.."' with the time: "..timeDiff)
        end
    end

    function checkIfPlayerStartedTooSoon(raceName, mpUserId, sender_id)
        if activeRaces[raceName].players[mpUserId].allowedStartTime == nil then
            goto continue
        end
        local timeDiff = activeRaces[raceName].players[mpUserId].startTime - activeRaces[raceName].players[mpUserId].allowedStartTime	    
        if timeDiff < 0 then
            MP.TriggerClientEventJson(sender_id, "BonRaceDISQUALIFIED", { timeDiff = timeDiff })
            
            sendNormalMessage(sender_id, "DISQUALIFIED!")
            sendErrorMessage(sender_id, "Headstart by "..timeDiff)
			
			CheckIfAllPlayersAreDone(raceName)
            MP.TriggerClientEvent(sender_id, "BonRaceFatalError", "") --fastest way to unload triggers
        else
            sendNormalMessage(sender_id, "Reaction time: "..timeDiff)
        end
        ::continue::
    end
    -- debugPrint(data)
    if data.eventType == "BonRaceTrigger" then
        --if data.triggerName = ""
        --AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    end
end
function handleBonRaceReportClientStartTime(sender_id, data) 
    debugPrint("ClientSupposedToStart: ",data)
    dataTable = Util.JsonDecode(data)
    local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp
    debugPrint(data)
    debugPrint(mpUserId)
    debugPrint(sender_id)
    activeRaces[activeUsers[mpUserId]].players[mpUserId].allowedStartTime = dataTable.osclockhp
end
function debugPrint(...)
    local info = debug.getinfo(2, "nSl")
    local source = info.short_src or info.source or "unknown"
    local line = info.currentline or 0
    local funcName = info.name or "unknown function"

    local debugInfo = string.format("[%s:%d - %s] ", source, line, funcName)
    if BonRaceDebug then 
        print(debugInfo, ...)
    end
end
function removeRaceTriggers(sender_id, raceName)
    for key, value in pairs(activeRaces[raceName].race.triggers) do
        MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = value.triggerName })
    end
end
function handleOnVehicleSpawn(sender_id)
	MP.TriggerClientEventJson(sender_id, "BonRaceLoadHornDetector", { })
end

function handlePlayerHorn(sender_id, data)
	dataTable = Util.JsonDecode(data) 
	if hornUsage[sender_id] == nil then
		hornUsage[sender_id] = {}
	end
	if dataTable.state == "on" then
		hornUsage[sender_id].onTime = os.clock()
	end
	if dataTable.state == "off" then
		hornUsage[sender_id].offTime = os.clock()
		
		honkDuration = hornUsage[sender_id].offTime - hornUsage[sender_id].onTime
		print("Honk time for "..sender_id..": "..honkDuration)
		if honkDuration > 1 then
			print("Searching for nearby race autoloaders...")
		end
	end
	
end
function doThingsEverySecond()
	BonRaceSendNextPlayer()
end
function onInit()
    debugPrint("RaceRunner.lua loaded")
    MP.RegisterEvent("onChatMessage", "BONRaceRunnerChatMessageHandler") --change to spesific name?
    MP.RegisterEvent("onBeamNGTriggerBonRace", "handleOnBeamNGTriggerBonRace")
    MP.RegisterEvent("BonRaceReportClientStartTime", "handleBonRaceReportClientStartTime")
    MP.RegisterEvent("BonRaceSendNextPlayer", "handleBonRaceSendNextPlayer")
	MP.RegisterEvent("playerHorn", "handlePlayerHorn")
	MP.RegisterEvent("onVehicleSpawn", "handleOnVehicleSpawn")
    MP.CreateEventTimer("doThingsEverySecond", 1000)
    end
onInit() --unsure why this is needed here, but not in the other file...
