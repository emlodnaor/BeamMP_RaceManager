------ Server -------
---------------------
--- BonTimeTools  ---
---------------------
---- Authored by ----
-- Beams of Norway --
---------------------
local M = {}
local function secondsToReadable(seconds)
	local isNegative = seconds < 0
	if isNegative then
		seconds = seconds * -1
	end
	
    local days    = math.floor(seconds / 86400)
    local hours   = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs    = seconds % 60 -- keep fractional part

    local parts = {}


	if isNegative then
		table.insert(parts, "-")
	end
	
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

M.secondsToReadable = secondsToReadable
return M