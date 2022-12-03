-- ###############################################
-- #                  SGCX                       #
-- #                                             #
-- #   12.2014                   by: IlynPayne   #
-- ###############################################

--[[
	## Description ##
	Allows to control SGCraft's Stargates.

	## Data storage format ##
	Main configuration file
	/etc/sgcx.cfg {
		version = 2, -- data storage format version
		address = "string", -- Stargate component address
		port = 0, -- remote iris authentication port
		autoIris = false, -- automatic iris status
		codes = { -- remote iris authentication codes
			"string",
			...
		},
		groups = { -- order of groups (names of group files)
			"string",
			...
		}
	}

	Files containing address groups
	/etc/sgcx.d/* {
		version = 2, -- data storage version
		name = "string", -- group name
		group = {
			[1] = { -- address entry
				name = "string",
				world = "string",
				address = "string",
			},
			...
		}
	}
]]

package.loaded.sgcx_graphics = nil

local version = "0.7.1"
local dataStorageVersion = 2
local startArgs = {...}

if startArgs[1] == "version_check" then return version end

local computer = require("computer")
local component = require("component")
local event = require("event")
local fs = require("filesystem")
local shell = require("shell")
local term = require("term")
local gml = require("gml")
local s1 = require("support_v1")
local colorGrid = require("color_grid")
local graphics = require("sgcx_graphics")

local serial = require("serialization")
local gpu = component.gpu
local res = {gpu.getResolution()}
if res[1] ~= 160 or res[2] ~= 50 then
	io.stderr:write("Application requires 3rd tier GPU and monitor in order to work")
	return
end
if not component.isAvailable("modem") then
	io.stderr:write("This application requires modem component to be installed")
	return
end
local modem = component.modem

local gui = nil
local darkStyle = nil
local element = {}
local sg = nil
local irisTimeout = 11
local sgChunk = {}

-- Loaded configuration data
local data = {
	config = {}, -- script-wide configuration
	groups = {},  -- address groups
	activeGroup = nil
}

local tmp = {}
local dialDialog = false
local countdownTimer = nil
local timerEneriga = nil
local irisTime = 0
local irisTimer = nil
local timeToClose = 0

-- Constants
local MIN_CONNECTION_TIME = 10 -- seconds
local MAX_CONNECTION_TIME = 300 -- seconds

-- Constants required for address calculation
local SYMBOLS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
local NUM_SYMBOLS = SYMBOLS:len()
local MIN_COORD = -139967
local MAX_COORD = 139967
local MC = 279937
local PC = 93563
local QC = 153742

local function hasArg(arg)
	for i, v in pairs(startArgs) do
		if v == arg then return true end
	end
	return false
end

local function chooseInterface()
	if not hasArg("init") then return "" end
	print(">> Choose new stargate interface address (type q to quit) <<")
	local componentList = component.list('stargate')
	local list = {}
	for address, _ in pairs(componentList) do
		table.insert(list, address)
	end
	if #list == 0 then
		io.stderr:write("Error: there is no connected stargate interfaces. Connect a stargate and rerun this program.")
		return nil
	end
	for i, address in pairs(list) do
		print(string.format("%d. %s", i, address))
	end
	print()
	local selection = nil
	while selection == nil do
		io.write("Choose the interface: ")
		selection = io.read()
		if selection:sub(1, 1) == "q" then return nil end
		selection = tonumber(selection)
		if selection ~= nil then
			selection = round(selection)
			if selection < 1 or selection > #list then selection = nil end
		end
		if selection ~= nil then
			return list[selection]
		end
	end
end

local function saveConfig()
	local file = io.open("/etc/sgcx.cfg", "w")
	file:write(serial.serialize(data.config))
	file:close()

	if not fs.isDirectory("/etc/sgcx.d") then
		fs.makeDirectory("/etc/sgcx.d")
	end

	-- remove unused group files
	for f in fs.list("/etc/sgcx.d") do
		if f:sub(-1) ~= "/" then
			local found = false
			for _, g in pairs(data.config.groups) do
				if g == f then 
					found = true
					break
				end
			end
			if not found then
				fs.remove(fs.concat("/etc/sgcx.d", f))
			end
		end
	end

	-- save the rest of groups
	for i, g in pairs(data.config.groups) do
		local file = io.open(fs.concat("/etc/sgcx.d", g), "w")
		file:write(serial.serialize(data.groups[i]))
		file:close()
	end
end

-- Storage format version 2
local function migrateStorageTo2()
	local oldFile = io.open("/etc/sg.cfg", "r")
	local oldData = serial.unserialize(oldFile:read())
	oldFile:close()

	data.config.version = 2
	data.config.address = oldData.address
	data.config.port = oldData.port
	data.config.portStatus = oldData.portStatus
	data.config.codes = {tostring(oldData.irisCode)}
	data.config.autoIris = oldData.autoIris
	data.config.groups = {"default.cfg"}

	data.groups[1] = {
		version = 2,
		name = "default",
		group = {}
	}
	for _, oldEntry in pairs(oldData.list) do
		table.insert(data.groups[1].group, oldEntry)
	end
end

local function loadConfig(overrideAddress)
	if fs.exists("/etc/sg.cfg") and not fs.exists("/etc/sgcx.cfg") then
		migrateStorageTo2()
		saveConfig()
	end

	if not fs.exists("/etc/sgcx.cfg") then
		if not overrideAddress then
			io.stderr:write("Configuration file not found. In order to create one, type 'sgcx init'")
			return false
		end
		data.config.address = overrideAddress
		sg = component.proxy(overrideAddress)
		if not sg then
			io.stderr:write("Wrong stargate interface address. Type 'sgcx init' to choose a new one.")
			return false
		elseif sg.type ~= "stargate" then
			io.stderr:write("Chosen interface doesn't belong to a stargate interface.")
			return false
		end
	else
		local file = io.open("/etc/sgcx.cfg", "r")
		data.config = serial.unserialize(file:read()) or {}
		if overrideAddress then data.config.address = overrideAddress end
		file:close()

		sg = component.proxy(data.config.address or "")
		if not sg then
			io.stderr:write("Stargate component not found. Check connection with Stargate interface or run 'sgcx init' command to choose new interface.")
			return false
		elseif sg.type ~= "stargate" then
			io.stderr:write("Given interface address doesn't belong to a stargate interface.")
			return false
		end
	end

	-- default values
	data.config.groups = data.config.groups or {}
	data.config.port = data.config.port or math.random(10000, 50000)
	data.config.iris = data.config.iris or {math.random(1000, 9999)}
	if data.config.portStatus then modem.open(data.config.port) end
	data.config.codes = data.config.codes or {math.random(1000,9999)}

	-- first load defined groups
	local loadedGroups = {}
	data.groups = {}
	for _, g in pairs(data.config.groups) do
		local path = fs.concat("/etc/sgcx.d", g)
		if fs.exists(path) then
			local groupFile = io.open(path, "r")
			local status, fileData = pcall(serial.unserialize, groupFile:read())
			groupFile:close()
			if not status and not hasArg("force_load") then
				print(">> ERROR <<")
				print("Couldn't load file '" .. path .. "' due to a parsing error")
				print("File has invalid format. Delete it manually or run script with the 'force_load' parameter to ignore invalid files.")
				print("Warning! Corrupted data will be lost!")
				print("Example: sgcx force_load")
				require("os").exit()
			elseif not status and hasArg("force_load") then
				fs.remove(path)
				print("Removed invalid file " .. path)
			else
				table.insert(data.groups, fileData)
				table.insert(loadedGroups, g)
			end
		end
	end
	data.config.groups = loadedGroups

	-- load new groups
	for file in fs.list("/etc/sgcx.d") do
		if file:sub(-1) ~= "/" then
			local loaded = false
			for _, name in pairs(data.config.groups) do
				if name == file then
					loaded = true
					break
				end
			end
			if not loaded then
				local groupFile = io.open(file, "r")
				table.insert(data.groups, serial.unserialize(groupFile:read()))
				groupFile:close()
				table.insert(data.config.groups, file)
			end
		end
	end

	-- normalize ordering in groups
	for _, group in pairs(data.groups) do
		local normalized = {}
		for _, list in pairs(group.group) do
			table.insert(normalized, list)
		end
		group.group = normalized
	end

	if #data.groups == 0 then
		local default = {
			name = "default",
			version = dataStorageVersion,
			group = {}
		}
		data.groups = {default}
		data.config.groups = {"default.cfg"}
	end
	data.activeGroup = data.groups[1]
	
	return true
end

local function GMLcontains(element,x,y)
  local ex, ey, ew, eh = element.posX, element.posY, element.width, element.height
  return x >= ex and x <= ex + ew - 1 and y >= ey and y <= ey + eh - 1
end

function GMLgetAppliedStyles(element)
  local styleRoot=element.style
  assert(styleRoot)

  local depth, state, class, elementType = element.renderTarget.getDepth(), element.state or "*", element.class or "*", element.type

  local nodes = {styleRoot}
  local function filterDown(nodes, key)
    local newNodes = {}
    for i = 1, #nodes do
      if key ~= "*" and nodes[i][key] then
        newNodes[#newNodes + 1] = nodes[i][key]
      end
      if nodes[i]["*"] then
        newNodes[#newNodes + 1] = nodes[i]["*"]
      end
    end
    return newNodes
  end
  nodes = filterDown(nodes, depth)
  nodes = filterDown(nodes, state)
  nodes = filterDown(nodes, class)
  nodes = filterDown(nodes, elementType)
  return nodes
end

function GMLextractProperty(element, styles, property)
  if element[property] then
    return element[property]
  end
  for j = 1, #styles do
    local v = styles[j][property]
    if v ~= nil then
      return v
    end
  end
end

function GMLmessageBox(message, buttons)
  element.stargate:suspendDrawing()
  local buttons = buttons or {"OK"}
  local choice
  local lines = {}
  message:gsub("([^\n]+)", function(line) lines[#lines+1] = line end)
  local i = 1
  while i <= #lines do
    if #lines[i] > 26 then
      local s, rs = lines[i], lines[i]:reverse()
      local pos =- 26
      local prev = 1
      while #s > prev + 25 do
        local space = rs:find(" ", pos)
        if space then
          table.insert(lines, i, s:sub(prev, #s-space))
          prev = #s - space + 2
          pos =- (#s - space + 28)
        else
          table.insert(lines, i, s:sub(prev, prev+25))
          prev = prev + 26
          pos = pos - 26
        end
        i = i + 1
      end
      lines[i] = s:sub(prev)
    end
    i = i + 1
  end

  local gui = gml.create("center", "center", 30, 6 + #lines, gpu)
  local labels = {}
  for i = 1, #lines do
    labels[i] = gui:addLabel(2, 1 + i, 26, lines[i])
  end
  local buttonObjs = {}
  local xpos = 2
  for i = 1, #buttons do
    if i == #buttons then xpos =- 2 end
    buttonObjs[i]=gui:addButton(xpos, -2, #buttons[i] + 2, 1, buttons[i], function() choice = buttons[i] gui.close() end)
    xpos = xpos + #buttons[i] + 3
  end

  gui:changeFocusTo(buttonObjs[#buttonObjs])
  gui:run()
  element.stargate:activateDrawing()
  return choice
end

local function addBar(x, y, length, isHorizontal)
	local bar = {
		visible = false,
		hidden = false,
		gui = gui,
		style = gui.style,
		focusable = false,
		type = "label",
		renderTarget = gui.renderTarget,
		horizontal = isHorizontal
	}
	bar.posX = x
	bar.posY = y
	bar.width = isHorizontal and length or 1
	bar.height = isHorizontal and 1 or length
	bar.contains = GMLcontains
	bar.isHidden = function() return false end
	bar.draw = function(t)
		t.renderTarget.setBackground(tmp.GMLbgcolor)
		t.renderTarget.setForeground(0xffffff)
		if t.horizontal then
			t.renderTarget.set(t.posX + 1, t.posY + 1, string.rep(require("unicode").char(0x2550), t.width))
		else
			local uni = require("unicode")
			for i = 1, t.height do
				t.renderTarget.set(t.posX + 1, t.posY + i, uni.char(0x2551))
			end
		end
	end
	gui:addComponent(bar)
	return bar
end

local function addTitle()
	local grid = colorGrid.grid({
		["#"] = 0xff6600
	})
	grid:line(" ###     ####    ###  ##   ##")
	grid:line("#       #       #      ## ## ")
	grid:line(" ###   #  ###  #        ###  ")
	grid:line("    #   #   #   #      ## ## ")
	grid:line(" ###     ####    ###  ##   ##")
	return grid:generateComponent(gui, 3, 3)
end

local function separateAddress(addr)
	return string.sub(addr, 1, 4) .. "-" .. string.sub(addr, 5, 7) .. "-" .. string.sub(addr, 8, 9)
end

local function translateResponse(res)
	if res == "bad arguments #1 (string expected, got no value)" then
		return "Malformed stargate address"
	end
	return res
end

local function round(num, idp)
  local mult = 10 ^ (idp or 0)
  return math.floor(num * mult + 0.5) / mult
end

local function getEnergy()
	local percent = tostring(math.floor(100 * (sg.energyAvailable() * 80 / 4000000) + 0.5) - 1) .. "%"
	eu = string.reverse(tostring(round(sg.energyAvailable(), 0) * 80))
	eu2 = ""
	for i=1, string.len(eu) do
		if i % 3 == 0 and i ~= 0 then 
			eu2 = eu2 .. string.sub(eu, i, i) .. " "
		else
			eu2 = eu2 .. string.sub(eu, i, i)
		end
	end
	eu2 = string.reverse(eu2)
	return percent ..  "  /  " .. eu2 .. " RF"
end

local function energyRefresh()
	element.energy["text"] = "Energy: " .. getEnergy()
	element.energy:draw()
end

local function irisTimerFunction()
	if irisTime < 0 then
		sg.closeIris()
		event.cancel(irisTimer)
		irisTimer = nil
	else
		irisTime = irisTime - 1
	end
end

local function modifyList(action)
	element.stargate:suspendDrawing()
	local function isSelected()
		return element.list.selectedLabel ~= nil
	end
	if action == "add" then
		if element.name["text"] == "" or element.world["text"] == "" or element.address["text"] == "" then
			GMLmessageBox("Fill all fields", {"OK"})
		elseif element.name["text"]:len() > 20 or element.world["text"]:len() > 20 then
			GMLmessageBox("Names cannot be longer than 20 characters", {"OK"})
		elseif not sg.energyToDial(element.address["text"]) then
			GMLmessageBox("Address is incorrect or does not exist", {"OK"})
		else
			for _, v in pairs(data.activeGroup.group) do
				if v.name == element.name["text"] then
					GMLmessageBox("Address with given name is already on the list", {"OK"})
					return
				elseif v.address == element.address then
					GMLmessageBox("Given address is already on the list under the name " .. v.name, {"OK"})
					return
				end
			end
			local l = {
				name = element.name["text"],
				world = element.world["text"],
				address = element.address["text"]:upper()
			}
			table.insert(data.activeGroup.group, l)
			element.list:refreshList()
			saveConfig()
			GMLmessageBox("Address has been added to the list", {"OK"})
		end
	elseif action == "modify" and isSelected() then
		if element.name["text"] == "" or element.world["text"] == "" or element.address["text"] == "" then
			GMLmessageBox("Fill all fields", {"OK"})
		elseif element.name["text"]:len() > 20 or element.world["text"]:len() > 20 then
			GMLmessageBox("Names cannot be longer than 20 characters", {"OK"})
		elseif not sg.energyToDial(element.address["text"]) then
			GMLmessageBox("Address is incorrect or does not exist", {"OK"})
		else
			if GMLmessageBox("Are you sure you want to modify this entry", {"Yes", "No"}) == "Yes" then
				local selected = element.list:getSelected()
				for a, v in pairs(data.activeGroup.group) do
					if selected == tostring(a) .. ". " .. v.name .. " (" .. v.world .. ")" then
						v.name = element.name["text"]
						v.world = element.world["text"]
						v.address = element.address["text"]:upper()
						element.list:refreshList()
						saveConfig()
						GMLmessageBox("The entry has been modified", {"OK"})
						break
					end
				end
			end
		end
	elseif action == "remove" and isSelected() then
		if GMLmessageBox("Are you sure you want to remove selected entry?", {"Yes", "No"}) == "Yes" then
			local selected = element.list:getSelected()
			for k, v in pairs(data.activeGroup.group) do
				if selected == tostring(k) .. ". " .. v.name .. " (" .. v.world .. ")" then
					table.remove(data.activeGroup.group, k)
					element.list:refreshList()
					saveConfig()
					GMLmessageBox("The entry has been removed", {"OK"})
					break
				end
			end
		end
	elseif action == "up" and isSelected() then
		if element.list.selectedLabel > 1 then
			local ag = data.activeGroup.group
			local i = element.list.selectedLabel
			local tmp = ag[i]
			ag[i] = ag[i - 1]
			ag[i - 1] = tmp
			element.list:refreshList()
			element.list:select(i - 1)
			saveConfig()
		end
	elseif action == "down" and isSelected() then
		if element.list.selectedLabel < #data.activeGroup.group then
			local ag = data.activeGroup.group
			local i = element.list.selectedLabel
			local tmp = ag[i]
			ag[i] = ag[i + 1]
			ag[i + 1] = tmp
			element.list:refreshList()
			element.list:select(i + 1)
			saveConfig()
		end
	elseif action == "to" and isSelected() then
		local selectedGroup = nil
		local options = {}
		for _, g in pairs(data.groups) do
			if g.name ~= data.activeGroup.name then
				table.insert(options, g.name)
			end
		end
		local text = "Move the address '" .. data.activeGroup.group[element.list.selectedLabel].name .. "' to the group:"
		local mgui = gml.create("center", "center", 64, 25)
		mgui.style = darkStyle
		mgui:addLabel("center", 1, 17, "Move the address")
		mgui:addLabel(3, 19, 15, "Selected group:")
		local selected = mgui:addLabel(20, 19, 30, "")
		mgui:addLabel(3, 3, text:len(), text)
		local listbox = mgui:addListBox(9, 4, 44, 14, options)
		listbox.onChange = function(lb, prev, index)
			selectedGroup = options[index]
			selected.text = selectedGroup
			selected:draw()
		end
		mgui:addButton(48, 23, 12, 1, "Cancel", function() mgui:close() end)
		mgui:addButton(32, 23, 12, 1, "Move", function()
			if selectedGroup == nil then
				GMLmessageBox("No target group was selected")
			else
				local targetGroup = nil
				for _, g in pairs(data.groups) do
					if g.name == selectedGroup then
						targetGroup = g
						break
					end
				end
				if targetGroup ~= nil then
					local entry = table.remove(data.activeGroup.group, element.list.selectedLabel)
					table.insert(targetGroup.group, entry)
					element.list:refreshList()
					saveConfig()
				end
				mgui:close()
			end
		end)
		mgui:run()
		element.stargate:activateDrawing()
	end
end

local function manageGroups()
	element.stargate:suspendDrawing()
	local ggui = gml.create("center", "center", 70, 31)
	local groupsUpdated = false
	ggui.style = darkStyle

	ggui:addLabel("center", 1, 13, "Edit groups")
	ggui:addButton(56, 29, 10, 1, "Close", function () ggui:close() end)

	ggui:addLabel(39, 4, 6, "Name:")
	local name = ggui:addTextField(39, 5, 25)
	ggui:addLabel(39, 7, 14, "Address count:")
	local addressCount = ggui:addLabel(54, 7, 3, "")

	-- Listbox
	local list = {}
	local function refreshList()
		list = {}
		for _, group in pairs(data.groups) do
			local found = 0
			for _, n in pairs(list) do
				if n == group.name then
					found = found + 1
				end
			end
			if found > 0 then
				group.name = group.name .. "_" .. tostring(found)
				groupsUpdated = true
			end

			table.insert(list, group.name)
		end
	end
	refreshList()
	local listbox = ggui:addListBox(3, 4, 30, 20, list)
	listbox.onChange = function (lb, prev, index)
		name.text = data.groups[index].name
		name:draw()
		addressCount.text = tostring(#data.groups[index].group)
		addressCount:draw()
	end
	----------------------------

	-- Buttons
	local function updated()
		groupsUpdated = true
		refreshList()
		listbox:updateList(list)
		listbox:draw()
	end
	local function groupExists(name)
		for _, g in pairs(data.groups) do
			if g.name == name then return true end
		end
		return false
	end
	local function sanitizeGroupFile(name)
		local sanitized = ""
		for i = 1, name:len() do
			local code = string.byte(name:sub(i, i))
			if code >= 65 and code <= 90 or code >= 97 and code <= 122 or code >= 48 and code <= 57 then
				sanitized = sanitized .. name:sub(i, i)
			end
		end
		return sanitized .. ".cfg"
	end
	ggui:addButton(3, 25, 12, 2, "Add", function ()
		if name.text:len() == 0 then
			GMLmessageBox("Group name cannot be empty")
		elseif name.text:len() > 20 then
			GMLmessageBox("Group name cannot be longer than 20 characters")
		elseif groupExists(name.text) then
			GMLmessageBox("Group with the same name already exists")
		elseif #data.groups > 25 then
			GMLmessageBox("Maximum number of groups (25) has been reached")
		else
			local group = {
				name = name.text,
				version = dataStorageVersion,
				group = {}
			}
			table.insert(data.groups, group)
			table.insert(data.config.groups, sanitizeGroupFile(name.text))
			updated()
		end
	end)
	ggui:addButton(21, 25, 12, 2, "Delete", function ()
		if not listbox.selectedLabel then return end
		if #data.groups < 2 then
			GMLmessageBox("Cannot delete this group: at least one must exist")
			return
		end
		local toRemove = data.groups[listbox.selectedLabel]
		if #toRemove.group > 0 then
			if GMLmessageBox("Group is not empty. Do you want to delete it with all contained addresses?", {"Yes", "No"}) == "No" then return end
		end
		table.remove(data.groups, listbox.selectedLabel)
		table.remove(data.config.groups, listbox.selectedLabel)
		updated()
	end)
	ggui:addButton(54, 25, 12, 2, "Update", function ()
		if not listbox.selectedLabel then return end
		if name.text:len() == 0 then
			GMLmessageBox("Group name cannot be empty")
		elseif name.text:len() > 20 then
			GMLmessageBox("Group name cannot be longer than 20 characters")
		else
			local group = data.groups[listbox.selectedLabel]
			group.name = name.text
			list[listbox.selectedLabel] = name.text
			listbox:updateList(list)
			data.config.groups[listbox.selectedLabel] = sanitizeGroupFile(name.text)
			groupsUpdated = true
		end
	end)
	ggui:addButton(3, 28, 12, 1, "Move up", function ()
		local i = listbox.selectedLabel
		if not i or i < 2 then return end
		local tmp = data.groups[i]
		data.groups[i] = data.groups[i - 1]
		data.groups[i - 1] = tmp
		listbox:select(i - 1)
		tmp = data.config.groups[i]
		data.config.groups[i] = data.config.groups[i - 1]
		data.config.groups[i - 1] = tmp
		updated()
	end)
	ggui:addButton(21, 28, 12, 1, "Move down", function ()
		local i = listbox.selectedLabel
		if not i or i == #data.groups then return end
		local tmp = data.groups[i]
		data.groups[i] = data.groups[i + 1]
		data.groups[i + 1] = tmp
		listbox:select(i + 1)
		tmp = data.cnofig.groups[i]
		data.config.groups[i] = data.config.groups[i + 1]
		data.config.groups[i + 1] = tmp
		udpated()
	end)
	----------------------------

	ggui:run()
	if groupsUpdated then
		element.list:refreshList()
		element.groupSelector:refresh()
		saveConfig()
	end
	element.stargate:activateDrawing()
end

local function dial()
	if sg.stargateState() == "Idle" then
		local status, response = sg.dial(element.address["text"])
		if status then
			element.connectionType["text"] = "Outgoing connection"
			element.connectionType:show()
			local timeout = tonumber(element.time["text"])
			if timeout and timeout >= 10 and timeout <= 300 then
				timeToClose = timeout
			else
				timeToClose = 300
				element.time["text"] = ""
				element.time:draw()
			end
		else
			GMLmessageBox(translateResponse(response), {"OK"})
		end
	elseif sg.stargateState() == "Connected" or sg.stargateState() == "Dialling" then
		sg.disconnect()
		countdownTimer:stop()
	elseif sg.stargateState() ~= "Offline" then
		GMLmessageBox("Stargate is busy", {"OK"})
	end
end

local function hash(i1, i2, i3)
	local r = (((i1 + 1) * i2) % i3) - 1
	return r
end

local function chunkInRange(c)
	return c >= MIN_COORD and c <= MAX_COORD
end

local function getSymbols(i1, i2)
	local ret = ""
	while i2 > 0 do
		i2 = i2 - 1
		i = (i1 % NUM_SYMBOLS) + 1
		ret = ret .. SYMBOLS:sub(i, i)
		i1 = math.floor(i1 / NUM_SYMBOLS)
	end
	
	return ret:reverse()
end

local function getSymbolsValue(s)
	l = 0
	for x = 1, s:len() do
		local index = 0
		for i = 1, NUM_SYMBOLS do
			if SYMBOLS:sub(i, i) == s:sub(x, x) then
				index = i - 1
				break
			end
		end
		l = (l * NUM_SYMBOLS) + index
	end
	
	return l
end

local function interleave(i1, i2)
	l1 = 1
	l2 = 0
	while i1 > 0 or i2 > 0 do
		l2 = l2 + (l1 * (i1 % 6))
		i1 = math.floor(i1 / 6)
		l1 = l1 * 6
		l2 = l2 + (l1 * (i2 % 6))
		i2 = math.floor(i2 / 6)
		l1 = l1 * 6
	end
	
	return l2
end

local function fromBaseSix(s)
	local ret = 0
	for i = 1, s:len() do
		local f = tonumber(s:sub(i, i))
		ret = ret + f * math.pow(6, i - 1)
	end
	
	return ret
end

local function uninterleave(i)
	local i1 = ''
	local i2 = ''
	while i > 0 do
		i1 = i1 .. tostring(i % 6)
		i = math.floor(i / 6)
		i2 = i2 .. tostring(i % 6)
		i = math.floor(i / 6)
	end
	
	i1 = fromBaseSix(i1)
	i2 = fromBaseSix(i2)
	return {i1, i2}
end

local function chunkToAddress(cx, cz)
	if not chunkInRange(cx) then
		GMLmessageBox("The X coordinate is beyond the addressation range", {"OK"})
		return
	elseif not chunkInRange(cz) then
		GMLmessageBox("The Z coordinate is beyond the addressation range", {"OK"})
		return
	end
	
	local l = interleave(hash(cx - MIN_COORD, PC, MC), hash(cz - MIN_COORD, PC, MC))
	return getSymbols(l, 7)
end

local function addressToChunk(address)
	local l = getSymbolsValue(address:sub(1, 7))
	if not l then return end
	local a = uninterleave(l)
	local i = MIN_COORD + hash(a[1], QC, MC)
	local j = MIN_COORD + hash(a[2], QC, MC)
	return {i, j}
end

local function computeDistance(addressTarget, chunkTarget)
	if not chunkTarget then
		chunkTarget = addressToChunk(addressTarget)
		if not chunkTarget then return end
	end
	
	local dx = math.abs(sgChunk[1] - chunkTarget[1])
	local dz = math.abs(sgChunk[2] - chunkTarget[2])
	local dist = math.sqrt(dx * dx + dz * dz)
	dist = math.floor(dist * 160) / 10
	return dist
end

local function clearAddress(addr)
	if not addr or addr:len() < 7 then return nil end
	local clear = ""
	for i = 1, 7 do
		local c = string.byte(addr:sub(i, i))
		if (c >= 65 and c <= 90) or (c >= 48 and c <= 57) then
			clear = clear .. addr:sub(i, i)
		elseif c >= 97 and c <= 122 then
			clear = clear .. string.char(c - 32)
		else
			return nil
		end
	end
	return clear
end

local function coordsCalculator()
	element.stargate:suspendDrawing()
	local cgui = gml.create("center", "center", 60, 21)
	cgui.style = darkStyle
	cgui:addButton(42, 18, 12, 1, "Close", function() cgui:close() end)
	cgui:addLabel(3, 2, 4, "X:")
	cgui:addLabel(3, 5, 4, "Z:")
	cgui:addLabel(3, 8, 10, "Chunk X:")
	cgui:addLabel(3, 11, 10, "Chunk Z:")
	local posX = cgui:addTextField(3, 3, 14)
	local posZ = cgui:addTextField(3, 6, 14)
	local posCX = cgui:addTextField(3, 9, 14)
	local posCZ = cgui:addTextField(3, 12, 14)
	cgui:addLabel(38, 5, 10, "Address:")
	local address = cgui:addTextField(38, 6, 17)
	cgui:addButton(38, 8, 17, 1, "Copy from list", function()
		address.text = element.address.text
		address:draw()
	end)
	cgui:addLabel(38, 10, 13, "Distance:")
	local distance = cgui:addLabel(38, 11, 17, "0")
	cgui:addLabel(3, 15, 56, "* World symbols aren't generated deterministically")
	local function updateDistance(cx, cz)
		local dist = computeDistance(nil, {cx, cz})
		distance.text = tostring(dist)
		distance:draw()
	end
	local function updateAddress(cx, cz)
		local addr = chunkToAddress(cx, cz)
		if addr then
			address.text = addr
			address:draw()
		end
		updateDistance(cx, cz)
	end
	cgui:addButton(22, 5, 11, 2, "--->", function()
		if posX.text:len() > 0 and posZ.text:len() > 0 then
			local npx = tonumber(posX.text)
			local npz = tonumber(posZ.text)
			if not npx then
				GMLmessageBox("The X coordinate must be a number", {"OK"})
			elseif not npz then
				GMLmessageBox("The Z coordinate must be a number", {"OK"})
			else
				updateAddress(math.floor(npx / 16), math.floor(npz / 16))
			end
		elseif posCX.text:len() > 0 and posCZ.text:len() > 0 then
			local ncx = tonumber(posCX.text)
			local ncz = tonumber(posCZ.text)
			if not ncx then
				GMLmessageBox("The chunk X coordinate must be a number", {"OK"})
			elseif not ncz then
				GMLmessageBox("The chunk Z coordinate must be a number", {"OK"})
			else
				updateAddress(ncx, ncz)
			end
		else
			GMLmessageBox("Enter coordinates of a block or chunk", {"OK"})
		end
	end)
	cgui:addButton(22, 10, 11, 2, "<---", function()
		if address.text:len() >= 7 then
			local cleared = clearAddress(address.text)
			if not cleared then
				GMLmessageBox("Address field contains forbidden characters", {"OK"})
			else
				local chunk = addressToChunk(cleared)
				posCX.text = tostring(chunk[1])
				posCX:draw()
				posCZ.text = tostring(chunk[2])
				posCZ:draw()
				posX.text = tostring(chunk[1] * 16)
				posX:draw()
				posZ.text = tostring(chunk[2] * 16)
				posZ:draw()
				updateDistance(chunk[1], chunk[2])
			end
		else
			GMLmessageBox("The address field must contain 7 characters", {"OK"})
		end
	end)
	cgui:run()
	element.stargate:activateDrawing()
end

local function channelCodeChooser(isChannel)
	element.stargate:suspendDrawing()
	local what = isChannel and "the channel port" or "the security code"
	local rangeFrom = isChannel and 10000 or 1000
	local rangeTo = isChannel and 50000 or 9999

	local cgui = gml.create("center", "center", 40, 10)
	cgui.style = darkStyle

	cgui:addLabel("center", 1, 25, "Choose " .. what)
	local number = cgui:addTextField(4, 4, 12)
	number.text = tostring(isChannel and data.config.port or data.config.codes[1])
	cgui:addButton(23, 4, 10, 1, "Random", function()
		number.text = tostring(math.random(rangeFrom, rangeTo))
		number:draw()
	end)
	cgui:addLabel(4, 5, 32, "Value boundaries: [" .. tostring(rangeFrom) .. "," .. tostring(rangeTo) .. "]")

	cgui:addButton(6, 8, 12, 1, "OK", function()
		local newVal = tonumber(number.text)
		if number.text:len() == 0 then
			GMLmessageBox("Value cannot be empty")
		elseif not newVal then
			GMLmessageBox("Entered value is not a number")			
		elseif newVal < rangeFrom or newVal > rangeTo then
			GMLmessageBox("Entered value is not within the boundaries")
		else
			if isChannel then
				local isOpen = modem.isOpen(data.config.port)
				if isOpen then modem.close(data.config.port) end
				data.config.port = newVal
				if isOpen then modem.open(data.config.port) end
				saveConfig()
			else
				-- todo: support of multiple iris codes in the future
				data.config.codes[1] = newVal
				saveConfig()
				cgui:close()
			end
		end
	end)
	cgui:addButton(21, 8, 12, 1, "Cancel", function()
		cgui:close()
	end)
	cgui:run()
	element.stargate:activateDrawing()
end

local function countdown(timer)
	local minutes = tostring(math.floor(timer.count / 60))
	local seconds = tostring(60 * ((timer.count / 60) - math.floor(timer.count / 60)))
	if string.len(seconds) == 1 then seconds = "0" .. seconds end
	element.timeout["text"] = "Remaining time: " .. minutes .. ":" .. seconds
	element.timeout:draw()
end

local function onStargateStateChange(newState)
	element.status["text"] = "Status: " .. sg.stargateState()
	element.status:draw()
	if newState == "Idle" then
		if data.config.autoIris then
			event.timer(2, function()
				sg.openIris()
			end)
		end
		element.connectionType:hide()
		element.remoteAddress:hide()
		element.timeout:hide()
		element.dial["text"] = "Open a tunnel"
		element.dial:draw()
		countdownTimer:stop()
		timeToClose = 0
		element.stargate:onDisconnected()
	elseif newState == "Connected" then
		element.remoteAddress["text"] = "Remote address: " .. separateAddress(sg.remoteAddress())
		element.remoteAddress:show()
		element.timeout["text"] = "Remaining time: "
		element.timeout:show()
		element.dial["text"] = "Close the tunnel"
		element.dial:draw()
		countdownTimer:start(1, timeToClose)
		element.stargate:onConnected()
		element.distance.text = "Distance: " .. tostring(computeDistance(sg.remoteAddress()))
		element.distance:draw()
	end
end

function onStargateIrisStateChange(newState)
	element.iris["text"] = "Iris: " .. sg.irisState()
		element.iris:draw()
		if newState == "Closed" then
			element.irisButton["text"] = "Open the iris"
			element.irisButton:draw()
			element.stargate:onIrisClosed()
		elseif newState == "Open" then
			element.irisButton["text"] = "Close the iris"
			element.irisButton:draw()
			element.stargate:onIrisOpened()
		end
end

local function createUI()
	------------------------
	gui = gml.create(0, 0, res[1], res[2])
	gui.style = darkStyle
	countdownTimer = s1.timer(countdown, gui)
	countdownTimer.onStop = function () sg.disconnect() end
	------------------------

	-- Common elements
	addTitle()
	gui:addLabel(35, 2, 10, version)["text-color"] = 0x666666
	addBar(53, 1, 15, false)
	element.stargate = graphics.createStargateComponent(gui, 90, 14)
	gui:addButton("right", 1, 10, 1, "Exit", function() gui:close() end)
	gui:addLabel(56, 4, 22, "Address: " .. separateAddress(sg.localAddress()))
	element.status = gui:addLabel(56, 5, 25, "Status: " .. sg.stargateState())
	element.iris = gui:addLabel(56, 6, 25, "Iris: " .. sg.irisState())
	element.energy = gui:addLabel(56, 7, 35, "Energy: " .. getEnergy())
	element.distance = gui:addLabel(56, 8, 35, "Distance: ")
	element.connectionType = gui:addLabel(56, 11, 30, "")
	element.connectionType:hide()
	element.remoteAddress = gui:addLabel(56, 12, 32, "")
	element.remoteAddress:hide()
	element.timeout = gui:addLabel(56, 13, 30, "")
	element.timeout:hide()
	------------------------

	-- Address list
	gui:addLabel(3, 20, 16, "Address list:")
	local list = {}
	for a, v in pairs(data.activeGroup.group) do
		table.insert(list, tostring(a) .. ". " .. v.name .. " (" .. v.world .. ")")
	end
	element.list = gui:addListBox(3, 21, 40, 24, list)
	element.list.onChange = function(listBox)
		local sel = listBox:getSelected()
		if not sel then return end
		local index = tonumber(sel:match("^(%d+)%.%s"))
		if not index or not data.activeGroup.group[index] then return end
		element.name["text"] = data.activeGroup.group[index].name
		element.name:draw()
		element.world["text"] = data.activeGroup.group[index].world
		element.world:draw()
		element.address["text"] = data.activeGroup.group[index].address
		element.address:draw()
		local clear = clearAddress(element.address.text)
		if clear then
			element.distance.text = "Distance: " .. tostring(computeDistance(clear))
			element.distance:draw()
		end
	end
	element.list.refreshList = function ()
		local list = {}
		for a, v in pairs(data.activeGroup.group) do
			local f = element.addressFilter.text
			if not f or f:len() == 0 or v.name:find(f, nil, true) then
				table.insert(list, tostring(a) .. ". " .. v.name .. " (" .. v.world .. ")")
			end
		end
		element.list:updateList(list)
	end
	------------------------

	-- Address list management
	gui:addButton(4, 45, 10, 2, "Add", function() modifyList("add") end)
	gui:addButton(15, 45, 10, 2, "Delete", function() modifyList("remove") end)
	gui:addButton(27, 45, 15, 2, "Update", function() modifyList("modify") end)
	gui:addButton(4, 48, 15, 1, "Move up", function () modifyList("up") end)
	gui:addButton(27, 48, 15, 1, "Move down", function() modifyList("down") end)
	gui:addButton(48, 48, 15, 1, "Move to", function() modifyList("to") end)
	gui:addLabel(45, 22, 7, "Name:")["text-color"] = 0x999999
	gui:addLabel(45, 25, 9, "World:")["text-color"] = 0x999999
	gui:addLabel(45, 28, 11, "Address:")["text-color"] = 0x999999
	gui:addLabel(45, 37, 16, "Connection time:")["text-color"] = 0x999999
	element.name = gui:addTextField(45, 23, 25)
	element.world = gui:addTextField(45, 26, 25)
	element.address = gui:addTextField(45, 29, 25)
	element.dial = gui:addButton(45, 33, 25, 3, "Open a tunnel", dial)
	element.time = gui:addTextField(64, 37, 6)
	element.time.text = tostring(MAX_CONNECTION_TIME)
	element.time.onBlur = function (self)
		local number = tonumber(self.text)
		if not number or number > MAX_CONNECTION_TIME then
			self.text = tostring(MAX_CONNECTION_TIME)
			self:draw()
		elseif number < MIN_CONNECTION_TIME then
			self.text = tostring(MIN_CONNECTION_TIME)
			self:draw()
		elseif number ~= math.floor(number) then
			self.text = tostring(math.floor(number))
			self:draw()
		end
	end
	element.irisButton = gui:addButton(45, 40, 25, 3, "", function()
		if sg.irisState() == "Open" then
			sg.closeIris()
		elseif sg.irisState() == "Closed" then
			sg.openIris()
		end
	end)
	element.irisButton["text"] = sg.irisState() == "Closed" and "Open the iris" or (sg.irisState() == "Open" and "Close the iris" or "Switch the iris")
	element.autoIris = gui:addLabel(45, 44, 7, "Mode:")
	gui:addButton(52, 44, 18, 1, data.config.autoIris and "automatic" or "manual", function(self)
		data.config.autoIris = not data.config.autoIris
		self["text"] = data.config.autoIris and "automatic" or "manual"
		self:draw()
		saveConfig()
	end)
	------------------------

	-- Remote iris authentication
	gui:addLabel(110, 5, 7, "Port:")
	gui:addButton(120, 5, 15, 1, data.config.portStatus and "Open" or "Closed", function(self)
		if data.config.portStatus then
			modem.close(data.config.port)
			self["text"] = "Closed"
			self["text-color"] = 0xff0000
		else
			modem.open(data.config.port)
			self["text"] = "Open"
			self["text-color"] = 0x00ff00
		end
		data.config.portStatus = not data.config.portStatus
		self:draw()
		saveConfig()
	end)["text-color"] = data.config.portStatus and 0x00ff00 or 0xff0000
	gui:addLabel(110, 6, 10, "Channel:")
	gui:addButton(120, 6, 15, 1, tostring(data.config.port), function(self)
		channelCodeChooser(true)
		self.text = tostring(data.config.port)
		self:draw()
	end)
	gui:addLabel(110, 7, 6, "Code:")
	gui:addButton(120, 7, 15, 1, tostring(data.config.codes[1]), function(self)
		channelCodeChooser(false)
		self.text = tostring(data.config.codes[1])
		self:draw()
	end)
	------------------------

	-- Address calculator
	gui:addButton(110, 9, 25, 1, "Address calculator", function() coordsCalculator() end)
	------------------------

	-- Address groups
	gui:addLabel(3, 10, 16, "Address groups:")
	element.groupSelector = gui:addComboBox(3, 11, 40, {})
	element.groupSelector.onSelected = function (gs, pos, value)
		data.activeGroup = data.groups[pos]
		element.list:refreshList()
	end
	element.groupSelector.refresh = function (gs)
		local groups = {}
		for _, g in pairs(data.groups) do
			table.insert(groups, g.name)
		end

		gs:updateList(groups)
	end
	element.groupSelector:refresh()
	gui:addButton(33, 10, 10, 1, "Edit", manageGroups)
	------------------------

	-- Address search
	gui:addLabel(3, 16, 20, "Search for address:")
	element.addressFilter = gui:addTextField(3, 17, 25)
	gui:addButton(32, 17, 10, 1, "Filter", function ()
		element.list:refreshList()
	end)
	------------------------

	tmp.GMLbgcolor = GMLextractProperty(gui, GMLgetAppliedStyles(gui), "fill-color-bg")

	local remoteAddress = sg.remoteAddress()
	event.timer(2, function ()
		if #remoteAddress > 0 then
			timeToClose = 300
			onStargateStateChange(sg.stargateState())
			onStargateIrisStateChange(sg.irisState())
			element.stargate:onConnected(remoteAddress)
		end
	end)

	gui:run()
end

local function main()
	local address = sg.localAddress():sub(1, 7)
	sgChunk = addressToChunk(address)
	
	require("term").setCursorBlink(false)
	darkStyle = gml.loadStyle("dark")
	createUI()
end

local function __eventListener(...)
	local ev = {...}
	if ev[1] == "sgDialIn" then
		if data.config.autoIris then
			event.timer(5, function()
				sg.closeIris()
			end)
		end
		timeToClose = 300
		element.connectionType["text"] = "Incomming connection"
		element.connectionType:show()
		element.remoteAddress["text"] = "Remote address: " .. separateAddress(sg.remoteAddress())
		element.remoteAddress:show()
	elseif ev[1] == "sgIrisStateChange" then
		onStargateIrisStateChange(ev[3])
	elseif ev[1] == "sgStargateStateChange" then
		onStargateStateChange(ev[3])
	elseif ev[1] == "sgChevronEngaged" then
		element.stargate:onSymbolLocked(ev[3], ev[4])
	elseif ev[1] == "modem_message" then
		if ev[4] == data.config.port then
			local matches = false
			if type(data.config.codes) == "table" then
				for _, code in pairs(data.config.codes) do
					matches = matches or code == ev[7]
				end
			end
			if matches then
				os.sleep(0.1)
				modem.send(ev[3], ev[6], serial.serialize({true, "Iris open", irisTimeout}))
				if sg.irisState() == "Closed" then
					sg.openIris()
					irisTime = irisTimeout
					irisTimer = event.timer(1, irisTimerFunction, irisTimeout + 5)
				end
			else
				os.sleep(0.1)
				modem.send(ev[3], ev[6], serial.serialize({false, "Wrong iris code!", irisTimeout}))
			end
		end
	end
end

local function eventListener(...)
	local args = {...}
	local status, msg = pcall(__eventListener, table.unpack(args))
	if not status then
		GMLmessageBox("Error: " .. msg)
	end
end

local newAddress = chooseInterface()
if type(newAddress) == "string" and newAddress:len() == 0 then
	newAddress = nil
elseif type(newAddress) == "nil" then
	return
end
if not loadConfig(newAddress) then return end

local function starter()
	timerEneriga = event.timer(5, energyRefresh, math.huge)
	main()
	event.cancel(timerEneriga)
	if data.config.port and modem.isOpen(data.config.port) then modem.close(data.config.port) end
end

event.listen("sgDialIn", eventListener)
event.listen("sgIrisStateChange", eventListener)
event.listen("sgStargateStateChange", eventListener)
event.listen("sgChevronEngaged", eventListener)
event.listen("modem_message", eventListener)

local status, message = pcall(starter)
if not status then
	io.stderr:write(messsage)
end

event.ignore("sgDialIn", eventListener)
event.ignore("sgIrisStateChange", eventListener)
event.ignore("sgStargateStateChange", eventListener)
event.ignore("sgChevronEngaged", eventListener)
event.ignore("modem_message", eventListener)
saveConfig()
