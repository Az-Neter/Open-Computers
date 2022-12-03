-- ###############################################
-- #                  IrisAuth                   #
-- #                                             #
-- #   12.2014                   by: IlynPayne   #
-- ###############################################

local event = require("event")
local term = require("term")
local key = require("keyboard")
local fs = require("filesystem")
local shell = require("shell")
local component = require("component")
local serial = require("serialization")
local modem = component.modem
local gpu = component.gpu

local wersja = "1.8"

local args, options = shell.parse(...)
if args[1]=="version_check" then return wersja end

if modem~=nil then
	if modem.isWireless()~=true	then modem=nil end
end

local res = {gpu.getResolution()}
local port = 12838
local kod = 4220

local changed = false

local function ladujConfig()
	if fs.exists("/etc/iaConfig.cfg") then
		local confFile = io.open("/etc/iaConfig.cfg", "r")
		port = tonumber(confFile:read("*l"))
		kod = tonumber(confFile:read("*l"))
		confFile:close()
	end
end

local function zapiszConfig()
	if changed then
		local file = io.open("/etc/iaConfig.cfg", "w")
		file:write(tostring(port) .. "\n" .. (kod))
		file:close()
	end
end

local function wrt(x, y, str)
	term.setCursor(x, y)
	term.write(str)
end

local function draw()
	term.clear()
	gpu.fill(1, 1, res[1], 4, "=")
	gpu.fill(1, 2, res[1], 2, "|")
	gpu.fill(2, 2, res[1] - 2, 2, " ")
	term.setCursor(3, 2)
	term.write("Iris Authenticator - Remote Iris Controller for SGCX")
	wrt(3, 3, "Version " .. wersja)
	wrt(4, 7, "Port:  " .. tostring(port))
	wrt(4, 8, "Code:   " .. tostring(kod))
	wrt(3, 10, "P - change port")
	wrt(3, 11, "K - change code")
	wrt(3, 12, "S - send signal")
	wrt(3, 13, "Q - quit program")
	wrt(1, 15, "--------")
	term.setCursor(2, 16)
end

local function main()
	while true do
		draw()
		local ev = {event.pull("key_down")}
		if ev[4] == key.keys.p then
			term.write("Enter new port number[10 000 - 50 000]: ")
			ret = tonumber(term.read())
			if ret~=nil then
				if ret >= 10000 and ret <= 50000 then
					port = ret
					changed = true
				else
					wrt(2, 17, "Entered incorrect port number!")
					os.sleep(2)
				end
			else
				wrt(2, 17, "Entered incorrect port number!")
				os.sleep(2)
			end
		elseif ev[4] == key.keys.k then
			term.write("Enter new code[1000 - 9999]: ")
			ret = tonumber(term.read())
			if ret~=nil then
				if ret >= 1000 and ret <= 9999 then
					kod = ret
					changed = true
				else
					wrt(2, 17, "Entered incorrect code!")
					os.sleep(2)
				end
			else
				wrt(2, 17, "Entered incorrect code!")
				os.sleep(2)
			end
		elseif ev[4] == key.keys.s then
			if modem ~= nil then
				local localPort = 0
				repeat
					localPort = math.random(20000, 60000)
				until localPort ~= port and not modem.isOpen(localPort)
				modem.open(localPort)
				modem.broadcast(port, localPort, kod)
				wrt(2, 17, "Message sent")
				evv = {event.pull(2, "modem_message")}
				if evv[1] == nil then
					wrt(4, 18, "No reponse!")
					os.sleep(2)
				else
					status = serial.unserialize(evv[6])
					if status[1] then
						wrt(4, 18, status[2])
						local czas = status[3] + 1
						while czas > -1 do
							wrt(4, 19, "Time until iris is closed: " .. czas .. " ")
							os.sleep(1)
							czas = czas - 1
						end
					else
						wrt(4, 18, status[2])
						os.sleep(2)
					end
				end
				modem.close(localPort)
			else
				wrt(2, 17, "Wireless modem not detected!")
				os.sleep(2)
			end
		elseif ev[4] == key.keys.q then
			term.clear()
			term.setCursor(1, 1)
			return
		end
	end
end


ladujConfig()
main()
modem.close(port)
zapiszConfig()
