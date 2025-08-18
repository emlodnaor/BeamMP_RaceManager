------ Client -------
---------------------
--- BonRaceClient ---
---------------------
---- Authored by ----
-- Beams of Norway --
---------------------
local M = {}

function logeM(string)
    print(string)
    appendToFile("bonRaceClientLog.txt", string)
end

local function onWorldReadyState(worldReadyState)
  if worldReadyState == 2 then
     TriggerServerEvent("PlayerWorldReadyState", jsonEncode({state = worldReadyState}))
  end
end

local function onBeamNGTrigger(data)
    local currentOsClockHp = os.clockhp()
    if string.sub(data.triggerName, 1, 7) == "BonRace" and MPVehicleGE.isOwn(data.subjectID) then
        local triggerInfo = getTriggerInfo(data)
        
        local pos = be:getPlayerVehicle(0):getPosition()
        local rot = quatFromDir(be:getPlayerVehicle(0):getDirectionVector(), be:getPlayerVehicle(0):getDirectionVectorUp())
        local raceName = triggerInfo.raceName
        
        local jsonData = jsonEncode({eventType = "BonRaceTrigger", triggerInfo = triggerInfo, pos = pos, rot = rot, osclockhp = currentOsClockHp})
        TriggerServerEvent("onBeamNGTriggerBonRace", jsonData)
    end
end
function split_string(input_string, delimiter)
    local result = {}
    for match in (input_string .. delimiter):gmatch("(.-)" .. delimiter) do
        table.insert(result, match)
    end
    return result
end
function getTriggerInfo(data)
    splitTriggerName = split_string(data.triggerName,"_") --"BonRaceTrigger_"..raceName.."_StartPosition_1" _CheckPoint_ _Finish
    
    local triggerInfo = {
    event = data.event,
    triggerName = data.triggerName,
    raceName = splitTriggerName[2],
    TriggerType = splitTriggerName[3],
    TriggerNumber = splitTriggerName[4] -- nil check needed?

    }    
    return triggerInfo
end

function BonRaceNormalMessage(data)
    local dataTable = jsonDecode(data)
    local message = dataTable.message
    handleInform(message)
end
function BonRaceInfoMessage(data)
    local dataTable = jsonDecode(data)
    local title = dataTable.title
    local icon = dataTable.icon
    local message = dataTable.message
    guihooks.trigger('Message', {msg = message, ttl = 5.0, category = icon, icon = icon}) 
end
function BonRaceErrorMessage(data)
    local dataTable = jsonDecode(data)
    local title = dataTable.title
    local message = dataTable.message
    guihooks.trigger('toastrMsg', {type = "error", title = title, msg = message, config = {timeOut = 5000}})
end
function handleInform(message)
    print("Info from Server: "..message)
    local big = string.len(message) < 10
	guihooks.trigger('ScenarioFlashMessageClear')
    guihooks.trigger('ScenarioFlashMessage', {{message, 3.0, 0, big}} ) 
end

local function BonRaceCreateTrigger(data)
    local dataTable = jsonDecode(data)
    local pos = dataTable.pos
    local rot = dataTable.rot
    local scale = vec3(dataTable.scale.x, dataTable.scale.y, dataTable.scale.z)
    local color = string.format("%g %g %g %g", dataTable.color.r, dataTable.color.g, dataTable.color.b, dataTable.color.a)
    local triggerName = dataTable.triggerName

    local marker =  createObject('BeamNGTrigger')
    marker:setField('luaFunction', 0, "onBeamNGTrigger")
    marker.scale = scale
    marker:setField('triggerColor', 0, color)
    marker:setField('debug', 0, 'true')
    marker:registerObject(triggerName)
    marker:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    scenetree.MissionGroup:addObject(marker)
    return marker
end

local function BonRaceRemoveTrigger(data)
    local dataTable = jsonDecode(data)
    local triggerName = dataTable.triggerName
    local markerObject = scenetree.findObject(triggerName)
	if markerObject then
		markerObject:deleteObject()
	end
end

function BonRaceTeleportInstuctions(data)
	local dataTable = jsonDecode(data)
    local pos = dataTable.pos
    local rot = dataTable.rot
    
    be:getPlayerVehicle(0):setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
end

function BonRaceStartCountdown(data)
	guihooks.trigger('ScenarioFlashMessageClear')
    local startTime = os.clockhp() + 3
    TriggerServerEvent("BonRaceReportClientStartTime", jsonEncode({osclockhp = startTime}))
    guihooks.trigger('ScenarioFlashMessage', {{"3", 1.0, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown1')", true}}) 
    guihooks.trigger('ScenarioFlashMessage', {{"2", 1.0, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown2')", true}}) 
    guihooks.trigger('ScenarioFlashMessage', {{"1", 1.0, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown3')", true}}) 
    guihooks.trigger('ScenarioFlashMessage', {{"GO!", 3.0, "Engine.Audio.playOnce('AudioGui', 'event:UI_CountdownGo')", true}}) 
end

function BonRaceFatalError(data)
    removeAllBonRaceTriggers()
end

function removeAllBonRaceTriggers()
	local allTriggers = scenetree.findClassObjects("BeamNGTrigger")
    
    for i = 1, #allTriggers do
        local triggerName = allTriggers[i]
		local prefix = "BonRaceTrigger_"
        if string.sub(triggerName, 1, #prefix) == prefix then
			local data = {}
			data.triggerName = triggerName
			local triggerInfo = getTriggerInfo(data)
			if triggerInfo.TriggerType ~= "AutoLoader" then
				local markerObject = scenetree.findObject(triggerName)
				markerObject:deleteObject()
			end
        end
    end
end


function BonRaceDISQUALIFIED(data)
	be:getPlayerVehicle(0):applyClusterVelocityScaleAdd(be:getPlayerVehicle(0):getRefNodeId(), 0, math.random(-50, -15), math.random(-15, 15), math.random(25, 50))
	be:getPlayerVehicle(0):queueLuaCommand('beamstate.breakAllBreakgroups()')
end

function BonRaceLoadHornDetector(data)
	getPlayerVehicle(0):queueLuaCommand("extensions.reload('hornDetector')")
end

AddEventHandler("BonRaceFatalError", BonRaceFatalError)
AddEventHandler("BonRaceDISQUALIFIED", BonRaceDISQUALIFIED)
AddEventHandler("BonRaceStartCountdown", BonRaceStartCountdown)
AddEventHandler("BonRaceRemoveTrigger", BonRaceRemoveTrigger) 
AddEventHandler("BonRaceCreateTrigger", BonRaceCreateTrigger) 
AddEventHandler("BonRaceNormalMessage", BonRaceNormalMessage) 
AddEventHandler("BonRaceInfoMessage", BonRaceInfoMessage) 
AddEventHandler("BonRaceErrorMessage", BonRaceErrorMessage)
AddEventHandler("BonRaceTeleportInstuctions", BonRaceTeleportInstuctions)
AddEventHandler("BonRaceLoadHornDetector", BonRaceLoadHornDetector)


M.BonRaceFatalError = BonRaceFatalError
M.BonRaceDISQUALIFIED = BonRaceDISQUALIFIED
M.BonRaceStartCountdown = BonRaceStartCountdown
M.BonRaceTeleportInstuctions = BonRaceTeleportInstuctions
M.BonRaceCreateTrigger = BonRaceCreateTrigger
M.BonRaceRemoveTrigger = BonRaceRemoveTrigger
M.BonRaceNormalMessage = BonRaceNormalMessage
M.BonRaceInfoMessage = BonRaceInfoMessage
M.BonRaceErrorMessage = BonRaceErrorMessage
M.handleInform = handleInform
M.logeM = logeM
M.onBeamNGTrigger = onBeamNGTrigger
M.onWorldReadyState = onWorldReadyState
return M
