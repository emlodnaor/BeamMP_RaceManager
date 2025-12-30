------ Server -------
---------------------
--- BonRaceCreator --
---------------------
---- Authored by ----
-- Beams of Norway --
---------------------

local function ensureDirectoriesExist() -- run here since this is the first file to laod
    local directories = {
        "Resources/Server/RaceManager",
        "Resources/Server/RaceManager/Races",
        "Resources/Server/RaceManager/RaceResults"
    }
    
    for _, dir in ipairs(directories) do
        if not FS.IsDirectory(dir) then
            print("Creating directory: " .. dir)
            local success = FS.CreateDirectory(dir)
            if success then
                print("Directory created: " .. dir)
            else
                print("Failed to create directory: " .. dir)
            end
        else
            print("Directory exists: " .. dir)
        end
    end
end

ensureDirectoriesExist()

local races = {}
local activeCreators = {}
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

local function sanitizeRaceName(name)
    if not name then return nil end
    -- Only allow alphanumeric, underscore, hyphen
    return name:match("^[%w_-]+$")
end

function BON_RallyCreatorChatMessageHandler(sender_id, sender_name, message)
    if string.sub(message, 1, 1) ~= '/' then
        return 0
    end
    
    local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp
    if mpUserId == nil then return end

    local args = {}

    for arg in string.gmatch(message, "%S+") do
        table.insert(args, arg)
    end

    local command = args[1]

    if args[1] == "/debug" then
        print(activeCreators[mpUserId])
        print(userIsNotAlreadyCreating(mpUserId))
        
    end

    if args[1] == "/newrace" then
        local userPosRot = getUserPosRot(sender_id)
        local raceName = args[2]
        if raceNameAvailable(raceName) and userIsNotAlreadyCreating(mpUserId) then
            races[raceName] = {
                startPosition = {},
                checkPoints = {},
                finishPoints = {},
                name = raceName,
                creator = mpUserId,
                triggers = {},
                laps = 1,
				startInterval = 30
            }
            races[raceName].startPosition[1] = userPosRot
            activeCreators[mpUserId] = raceName
            print(activeCreators)
			local StartNumber = #races[raceName].startPosition + 1
            local triggerName = "BonRaceTrigger_"..raceName.."_StartPosition_"..StartNumber --put number into thing
            local triggerData = spawnClientTrigger(sender_id, triggerName, userPosRot, "start", StartNumber)
            races[raceName].triggers[1] = triggerData
            raceCreatedSucessfully(sender_id, raceName)
        else 
            cantCreateRace(sender_id, raceName)
        end
        return 1
    end
    
    if command == "/deleteRace" then
        debugPrint()
        local raceName = args[2]
        debugPrint()
        celcelRaceMaking(sender_id, mpUserId, raceName)
        debugPrint()
        deleteRace(sender_id, mpUserId, raceName)
    end
    
    if activeCreators[mpUserId] ~= nil then
        ContinueRaceCreation(sender_id, sender_name, message)
        return 1
    end

    return 1
end

function spawnClientTrigger(sender_id, name, userPosRot, type, TriggerNumber)
    local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp
    if mpUserId == nil then return end
    local data = { 
        pos = userPosRot.pos, 
        rot = userPosRot.rot, 
        scale = {x = 8, y = 2, z = 2}, 
        color = {r = 50, g = 255, b = 20, a = 100},
        triggerName = name,
		TriggerType = type,
		TriggerNumber = TriggerNumber
    }
    if type == "start" then
        data.scale.x = 3
        data.scale.y = 5
    end
	if type == "autoloader" then
        data.scale.x = 10
        data.scale.y = 10
		data.color = {r = 255, g = 255, b = 50, a = 100}
    end
    if type == "cp" then
        data.color = {r = 50, g = 70, b = 255, a = 100}
    end
    if type == "end" then
        data.color = {r = 255, g = 70, b = 20, a = 100}
    end
    MP.TriggerClientEventJson(sender_id, "BonRaceCreateTrigger", data)
    return data
end

function ContinueRaceCreation(sender_id, sender_name, message)
    local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp
    if mpUserId == nil then return end
	local args = {}  -- Table to store command arguments

    for arg in string.gmatch(message, "%S+") do
        table.insert(args, arg)
    end

    local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp
    local raceName = activeCreators[mpUserId]
    local command = args[1]

    if args[1] == "/startInterval" then
		races[raceName].startInterval = args[2]
	end
	if args[1] == "/autoloader" then
        local posRot = getUserPosRot(sender_id)
        
        races[raceName].autoloaderPosition = posRot
        sendNormalMessage(sender_id, raceName.." AutoLoaderPosition set.")
        local triggerName = "BonRaceTrigger_"..raceName.."_AutoLoader_"
        triggerData = spawnClientTrigger(sender_id, triggerName, posRot, "autoloader", 0)
        triggerNumber = #races[raceName].triggers + 1
        races[raceName].triggers[triggerNumber] = triggerData
        return
    end
    if args[1] == "/start" then
        local posRot = getUserPosRot(sender_id)
        local StartNumber = #races[raceName].startPosition + 1
        races[raceName].startPosition[StartNumber] = posRot
        sendNormalMessage(sender_id, raceName.." startPosition "..StartNumber.." set.")
        local triggerName = "BonRaceTrigger_"..raceName.."_StartPosition_"..StartNumber
        triggerData = spawnClientTrigger(sender_id, triggerName, posRot, "start", StartNumber)
        triggerNumber = #races[raceName].triggers + 1
        races[raceName].triggers[triggerNumber] = triggerData
        return
    end
    if args[1] == "/cp" or args[1] == "/checkpoint" then
        local posRot = getUserPosRot(sender_id)
        local cpNumber = #races[raceName].checkPoints + 1
        races[raceName].checkPoints[cpNumber] = posRot

        sendNormalMessage(sender_id, raceName.." checkpoint "..cpNumber.." set.")
        local triggerName = "BonRaceTrigger_"..raceName.."_CheckPoint_"..cpNumber
        triggerData = spawnClientTrigger(sender_id, triggerName, posRot, "cp", cpNumber)
        triggerNumber = #races[raceName].triggers + 1
        races[raceName].triggers[triggerNumber] = triggerData
        return
    end
    if args[1] == "/end" or args[1] == "/endlap" or args[1] == "/finish" then
        local posRot = getUserPosRot(sender_id)
        local finishNumber = #races[raceName].finishPoints + 1
        races[raceName].finishPoints = posRot
        sendNormalMessage(sender_id, raceName.." Finsih set")
        local triggerName = "BonRaceTrigger_"..raceName.."_Finish_"..finishNumber
        triggerData = spawnClientTrigger(sender_id, triggerName, posRot, "end", finishNumber)
        triggerNumber = #races[raceName].triggers + 1
        races[raceName].triggers[triggerNumber] = triggerData
        return
    end
    if args[1] == "/laps" then
        local laps = tonumber(args[2])
        if laps ~= nil then
            if laps >= 1 then
                races[raceName].laps = laps
				sendNormalMessage(sender_id, raceName.." Laps set to "..laps)
            else
                sendErrorMessage(sender_id, "WrongArgument", args[2].." is not a valid number, example use: '/laps 3'")
            end
        else
        sendErrorMessage(sender_id, "WrongArgument", args[2].." is not a number, example use: '/laps 3'")
        end
    end

    if args[1] == "/save" then
        saveRace(raceName)
        sendNormalMessage(sender_id, raceName.." Saved to file")
        removeTriggers(sender_id, raceName)
        activeCreators[mpUserId] = nil
		BonRaceManager_SpawnAutoloader(raceName, -1)
    end
    if command == "/cancel" then
        celcelRaceMaking(sender_id, mpUserId, raceName)
    end


    if command == "/moveHere" then
       --AA 
    end
    if command == "/width" then
       --AA 
    end
    if command == "/left" then
       --AA 
    end
    if command == "/right" then
       --AA 
    end
    if command == "/forward" then
       --AA 
    end
    if command == "/backward" then
       --AA 
    end
end
function celcelRaceMaking(sender_id, mpUserId, raceName)
    if races[raceName] ~= nil then
        removeTriggers(sender_id, raceName)
        races[raceName] = nil
        activeCreators[mpUserId] = nil
        sendInfoMessage(sender_id, "Race creation for: '"..raceName.."' has been calcelled!")    
    end
end
function deleteRace(sender_id, mpUserId, raceName)
    if not raceNameAvailable(raceName) then
        local race = fetchRaceFromFile(raceName)
        if race.creator == mpUserId then
            local filePath = "Resources\\Server\\RaceManager\\Races\\raceConfig_"..sanitizeRaceName(raceName)..".json"
            if os.remove(filePath) then
                sendInfoMessage(sender_id, "Race: '"..raceName.."' deleted successfully.")    
            else
                sendInfoMessage(sender_id, "Race: '"..raceName.."' not deleted. report bug.")
                print("Failed to delete the file or the file does not exist.")
            end
        end
    else
        sendInfoMessage(sender_id, "Race: '"..raceName.."' does not exits.")
    end
end
function fetchRaceFromFile(raceName)
	local file = io.open("Resources\\Server\\RaceManager\\Races\\raceConfig_"..sanitizeRaceName(raceName)..".json", "r")
    if file == nil then
        return nil
    end
    local content = file:read("*all")
    file:close()
    local contentTable = Util.JsonDecode(content)
    return contentTable
end

function removeTriggers(sender_id, raceName)
    for key, value in pairs(races[raceName].triggers) do
        MP.TriggerClientEventJson(sender_id, "BonRaceRemoveTrigger", { triggerName = value.triggerName })
    end
end
function raceCreatedSucessfully(sender_id, raceName)
    sendNormalMessage(sender_id, raceName.." created, use /cp and finally /end")
    print("Race " .. raceName .. " created successfully.")
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

function saveRace(raceName)
	jsonRace = Util.JsonEncode(races[raceName])
    -- Open the file for writing
    local file = io.open("Resources\\Server\\RaceManager\\Races\\raceConfig_"..sanitizeRaceName(raceName)..".json", "w")

    if file == nil then
        print("Error opening file for writing.")
    else
    -- Write content to the file
    file:write(jsonRace)

    -- Close the file
    file:close()
    print("Race: "..jsonRace)
    end
end

function raceNameAvailable(raceName)
    print("Checking availability for race " .. raceName)
    local file = io.open("Resources\\Server\\RaceManager\\Races\\raceConfig_"..sanitizeRaceName(raceName)..".json", "r")
    local dontExist = file == nil
    if not dontExist then file:close() end
    return dontExist
end

function cantCreateRace(sender_id, raceName)
    local mpUserId = MP.GetPlayerIdentifiers(sender_id).beammp
    if not userIsNotAlreadyCreating(mpUserId) then
        local currentRaceName = activeCreators[MP.GetPlayerIdentifiers(sender_id).beammp]
        sendErrorMessage(sender_id, "Error:","Still wroking on: "..currentRaceName..". Continue that, or use /deleterace")
    end
    if not raceNameAvailable(raceName) then
        sendErrorMessage(sender_id, "Error:","raceName: "..raceName.." is already taken...")
    end 
    print("Cannot create race for sender_id " .. sender_id)
end

function userIsNotAlreadyCreating(mpUserId)
	print("userIsNotAlreadyCreating")
    return activeCreators[mpUserId] == nil
end
function getUserPosRot(sender_id)
	print("getUserPosRot")
    local rotPos = MP.GetPositionRaw(sender_id, 0)
    local rot = rotPos.rot
    local pos = rotPos.pos
    print("Pos:1: "..pos[1].."2: "..pos[2].."3: "..pos[3].."Rot:1: "..rot[1].."2: "..rot[2].."3: "..rot[3].."4: "..rot[4])
    return { pos = { x = pos[1], y = pos[2], z = pos[3]}, rot = { x = rot[1], y = rot[2], z = rot[3], w = rot[4] }} --w might be first...
end

function handlePlayerHorn(sender_id, jsonData)
	--print(jsonData)
	local data = Util.JsonDecode(jsonData)
	if data.state == "on" then
		BON_RallyCreatorChatMessageHandler(sender_id, "NotInUse", "/cp")
	end
	
end

function onInit()
    print("RaceCreator.lua loaded!")
    MP.RegisterEvent("onChatMessage", "BON_RallyCreatorChatMessageHandler")
	MP.RegisterEvent("playerHorn", "handlePlayerHorn")
end