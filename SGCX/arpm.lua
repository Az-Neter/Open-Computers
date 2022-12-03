-- ###############################################
-- #                  ARPM                       #
-- #                                             #
-- #   08.2015                   by: IlynPayne   #
-- ###############################################

--[[
	.----------------.  .----------------.  .----------------.  .----------------. 
	| .--------------. || .--------------. || .--------------. || .--------------. |
	| |      __      | || |  _______     | || |   ______     | || | ____    ____ | |
	| |     /  \     | || | |_   __ \    | || |  |_   __ \   | || ||_   \  /   _|| |
	| |    / /\ \    | || |   | |__) |   | || |    | |__) |  | || |  |   \/   |  | |
	| |   / ____ \   | || |   |  __ /    | || |    |  ___/   | || |  | |\  /| |  | |
	| | _/ /    \ \_ | || |  _| |  \ \_  | || |   _| |_      | || | _| |_\/_| |_ | |
	| ||____|  |____|| || | |____| |___| | || |  |_____|     | || ||_____||_____|| |
	| |              | || |              | || |              | || |              | |
	| '--------------' || '--------------' || '--------------' || '--------------' |
	'----------------'  '----------------'  '----------------'  '----------------' 
	ARPM REPOSITORY PACKAGE MANAGER


	## Description ##
	Package manager that allows downloading applications from this repository. It uses global registry for application
	 management (setup-list). Its structure is described in the section below. Only the newest versions of applications
	can be downloaded: when the newer version is released, the older one becomes inaccessible because registry is
	overwriten.
	
	## Registry structure ##
	{
		{
			[1] = application name: string,
			[2] = version: string,
			[3] = download link: string,
			[4] = description: string,
			[5] = author: string,
			[6] = dependencies: table or nil,
			[7] = whether application is a library: bool or nil,
			[8] = manual file name: string or nil,
			[9] = alternate application name: string or nil,
			[10] = archived: bool or nil
		},
		...
	}

	Additional info:
	[6] - currently package manager doesn't resolve dependencies recursively, so a complete list of dependencies
		must be provided.
	[7] - information displayed in app list
	[8] - manual file name (with an extension, if has one). Manuals are downloaded from 'man' directory.
	[9] - the actual mame under which application is saved on disk (may contain directory path)
	[10] - whehter application is archived (not developed anymore); used for app list filtering
	
	## Application options ##
		* list [-r]
			Displays available packages. [r] also displays archived packages.
		* info <package>
			Displays detailed information about specified package.
		* install <package> [-f] [-n]
			Installs selected package. [f] forces installation, [n] disables installation of dependencies.
		* remove <package> [-d]
			Removes specified package. [d] also removes dependencies.
		* self-update
		   Updates this ARPM script
		* test <path>
			Tests offline registry (setup-list) for known errors before uploading.
]]

local version = "0.3.4"
local args = {...}
if args[1] == "version_check" then return version end

local component = require("component")

if not component.isAvailable("internet") then
	io.stderr:write("This application requires an internet card")
	return
end

local inter2 = component.internet
local gpu = component.gpu
local internet = require("internet")

if not inter2.isHttpEnabled() then
	io.stderr:write("Internet connections are currently disabled in game config")
	return
end

local fs = require("filesystem")
local serial = require("serialization")
local term = require("term")
local event = require("event")
local keyboard = require("keyboard")
local shell = require("shell")
local os = require("os")
local process = require("process")
local thread = require("thread")

local resolution = {gpu.getResolution()}
local args, options = shell.parse(...)

local setupListUrl = "https://gitlab.com/d_rzepka/oc-equipment/raw/master/installer/setup-list"
local selfUrl = "https://gitlab.com/d_rzepka/oc-equipment/raw/master/installer/arpm.lua"
local additionalHeaders = {
	["User-Agent"] = "ARPM/" .. version -- Gitlab returns HTTP 403 when default user agent is used (e.g. Java/1.8.0_131)
}

local appList = nil
local installed = {}

local colors = {
	white = 0xffffff,
	orange = 0xffa500,
	magenta = 0xff00ff,
	yellow = 0xffff00,
	red = 0xff0000,
	green = 0x00ff00,
	blue = 0x0000ff,
	cyan = 0x00ffff,
	brown = 0xa52a2a,
	gray = 0xc9c9c9,
	silver = 0xe0e0de,
	black = 0x000000
}

local function textColor(color)
	if gpu.maxDepth() > 1 and color then
		return gpu.setForeground(color)
	end
end

local function printCommand(com, desc)
	textColor(colors.orange)
	term.write("  arpm " .. com)
	textColor(colors.silver)
	print(" - " .. desc)
end

local function ok()
	textColor(colors.green)
	term.write("OK")
	textColor(colors.cyan)
end

local function usage()
	if args[1] and args[1]:len() > 0 then
		io.stderr:write("Action not found: " .. args[1] .. "\n\n")
	end
	local prev = nil
	prev = textColor(colors.green)
	print("ARPM - ARPM Repository Package Manager     version " .. version)
	textColor(colors.cyan)
	print("Usage:")
	printCommand("list [-r]", "Displays available packages. [r] also displays archived packages.")
	printCommand("info <package>", "Displays detailed information about specified package.")
	printCommand("install <package> [-f] [-d]", "Installs selected package. [f] forces installation, [n] disables installation of dependencies.")
	printCommand("remove <package> [-d]", "Removes specified package. [d] also removes dependencies.")
	printCommand("refresh", "Forces refresh of the registry (downloads it again from server).")
	printCommand("self-update", "Updates ARPM")
	printCommand("test <path>", "Tests offline registry (setup-list) for known errors before uploading.")
	textColor(prev)
end

local function getContent(url)
	local sContent = ""
	local result, response = pcall(internet.request, url, nil, additionalHeaders)
	if not result then
		return nil
	end
	for chunk in response do
		sContent = sContent .. chunk
	end
	return sContent
end

local function saveAppList(raw)
	local filename = "/tmp/setup-list"
	if fs.isDirectory(filename) then
		if not fs.remove(filename) then return end
	end
	local f = io.open(filename, "w")
	if f then
		f:write(raw)
		f:close()
	end
end

local function fetchAppList(force)
	local filename = "/tmp/setup-list"
	local currentTime = math.floor(os.time() * (1000 / 60 / 60) / 20)
	if fs.exists(filename) and not fs.isDirectory(filename) and not force then
		local lastUpdate = tonumber(os.getenv("sl_update"))
		if lastUpdate ~= nil and lastUpdate + 3600 > currentTime then 
			local f = io.open(filename, "r")
			if f then
				local s = serial.unserialize(f:read("*a"))
				f:close()
				if s then
					appList = s
					return true
				end
			end
		end
	end
	local resp = getContent(setupListUrl)
	if resp then
		local s, e = serial.unserialize(resp)
		if not s then
			io.stderr:write("Couldn't read the registry: " .. e)
			return false
		end
		appList = s
		saveAppList(resp)
		os.setenv("sl_update", tostring(currentTime))
	else
		io.stderr:write("Couldn't establish internet connection.")
		return false
	end
end

local function getApp(url)
	return getContent(url)
end

local function getAppData(appName)
	for _, nm in pairs(appList) do
		if nm[1] == appName then return nm end
	end
	return nil
end

local function testApp(app, all)
	local warn = {}
	if type(app[1]) ~= "string" then
		table.insert(warn, "application name (1) must be a string")
	elseif app[1]:len() == 0 then
		table.insert(warn, "application name (1) is too short")
	end
	if type(app[2]) ~= "string" then
		table.insert(warn, "version (2) must be a string")
	elseif app[2]:len() == 0 then
		table.insert(warn, "version (2) is too short")
	end
	if type(app[3]) ~= "string" then
		table.insert(warn, "download link (3) must be a string")
	else
		local s, i = pcall(component.internet.request, app[3])
		if s then
			local d, e = pcall(i.read, 1)
			if not d then
				table.insert(warn, "download link (3): " .. e)
			end
			i.close()
		else
			table.insert(warn, "download link (3): " .. i)
		end
	end
	if type(app[4]) ~= "string" then
		table.insert(warn, "description (4) must be a string")
	elseif app[4]:len() == 0 then
		table.insert(warn, "description (4) is empty")
	end
	if type(app[5]) ~= "string" then
		table.insert(warn, "author name (5) must be a string")
	elseif app[5]:len() == 0 then
		table.insert(warn, "author name (5) is empty")
	end
	if type(app[6]) == "table" then
		for _, dep in pairs(app[6]) do
			local found = false
			for _, a in pairs(all) do
				if a[1] == dep then
					found = true
					break
				end
			end
			if not found then
				table.insert(warn, "dependency '" .. dep .. "' not found")
			end
		end
	elseif type(app[6]) ~= "nil" then
		table.insert(warn, "dependency list (6) must be a table")
	end
	if type(app[7]) ~= "boolean" and type(app[7]) ~= "nil" then
		table.insert(warn, "library flag (7) must be boolean or nil")
	end
	if type(app[8]) == "string" then
		if app[8]:len() == 0 then
			table.insert(warn, "manual name (8) is too short")
		end
	elseif type(app[8]) ~= "nil" then
		table.insert(warn, "manual name (8) must be a string")
	end
	if type(app[9]) == "string" then
		if app[9]:len() == 0 then
			table.insert(warn, "alternate application name (9) is too short")
		end
	elseif type(app[9]) ~= "nil" then
		table.insert(warn, "alternate application name (9) must be a string or nil")
	end
	if type(app[10]) ~= "boolean" and type(app[10]) ~= "nil" then
		table.insert(warn, "archive flag (10) must be a boolean or nil")
	end
	return warn
end

local function testRepo(path)
	if not path or path:len() == 0 then
		io.stderr:write("Registry name must be supplied")
		return
	end
	if path:sub(1, 1) ~= "/" then
		path = fs.concat(shell.getWorkingDirectory(), path)
	end
	if not fs.exists(path) then
		io.stderr:write("File not found")
		return
	end
	if fs.isDirectory(path) then
		io.stderr:write("Given path is a directory")
		return
	end
	local file, e = io.open(path, "r")
	if not file then
		io.stderr:write("Couldn't open a file: " .. e)
		return
	end
	local tab, e = serial.unserialize(file:read("*a"))
	file:close()
	if not tab then
		io.stderr:write("Couldn't process the file: " .. e)
		return
	end
	textColor(colors.cyan)
	term.write("Testing entries:")
	local errors = 0
	for _, t in pairs(tab) do
		textColor(colors.silver)
		term.write("\n" .. t[1] .. "   ")
		local test = testApp(t, tab)
		if #test > 0 then
			textColor(colors.yellow)
			for _, s in pairs(test) do
				term.write("\n  " .. s)
				errors = errors + 1
			end
		else
			ok()
		end
	end
	textColor(colors.cyan)
	print("\n\nVerified " .. tostring(#tab) .. " applications.")
	if errors > 0 then
		textColor(colors.orange)
		print("Test completed. Found " .. tostring(errors) .. " errors.")
	else
		textColor(colors.green)
		print("Test completed succesfully.")
	end
end

local function selfUpdate()
	textColor(colors.blue)
	print("\nStarting ARPM update...\n")
	os.sleep(0.2)

	textColor(colors.cyan)
	io.write("Current version: ")
	textColor(colors.green)
	print(version)
	textColor(colors.cyan)
	io.write("New version: ")

	local newContent = getContent(selfUrl)
	local newPackage = load(newContent)
	local newVersion = newPackage("version_check")
	textColor(colors.green)
	print(newVersion)

	if version == newVersion then
		textColor(colors.orange)
		print("Versions match, no update will be performed")
		return
	end

	local tmpFilePath = "/tmp/arpm_update.lua"
	local tmpFile = io.open(tmpFilePath, "w")
	if not tmpFile then
		io.stderr:write("\nCannot create file: " .. tmpFile)
		tmpFile:close()
		return
	end
	tmpFile:write(newContent)
	tmpFile:close()

	local fullPath = shell.resolve(process.info().path)
	local extension = ".lua"
	if fullPath:sub(-#extension) ~= extension then
		fullPath = fullPath .. extension
	end

	local executable = thread.create(function (targetFilePath, updateFilePath)
		os.sleep(1)
		fs.copy(updateFilePath, targetFilePath)
		fs.remove(updateFilePath)
	end, fullPath, tmpFilePath)
	executable:detach()

	textColor(colors.green)
	print("Update successful")
end

local function packetInfo(packetName)
	if not packetName or packetName == "" then
		io.stderr:write("Package name not supplied.")
		return
	end
	fetchAppList()
	if appList then
		for _, packet in pairs(appList) do
			if type(packet) == "table" and packet[1] == packetName then
				textColor(colors.cyan)
				print("\n>> Package information <<")
				textColor(colors.yellow)
				io.write("\nPackage name: ")
				textColor(colors.gray)
				print(packet[1])
				if packet[9] then
					textColor(colors.yellow)
					io.write("File name: ")
					textColor(colors.gray)
					print(packet[9])
				end
				textColor(colors.yellow)
				io.write("Current version: ")
				textColor(colors.gray)
				print(packet[2])
				textColor(colors.yellow)
				io.write("Description: ")
				textColor(colors.gray)
				print(packet[4])
				textColor(colors.yellow)
				io.write("Author: ")
				textColor(colors.gray)
				print(packet[5])
				textColor(colors.yellow)
				io.write("Download link: ")
				textColor(colors.gray)
				do
					if packet[3]:len() > resolution[1] - 20 then
						print(packet[3]:sub(1, math.ceil(resolution[1] / 2) - 12) .. "..." .. packet[3]:sub(math.ceil(resolution[1] / 2) + 12, packet[3]:len()))
					else
						print(packet[3])
					end
				end
				if packet[6] then
					local deps = packet[6]
					textColor(colors.yellow)
					io.write("Dependencies: ")
					textColor(colors.gray)
					for i = 1, #deps do
						if i < #deps then io.write(deps[i] .. ", ")
						else print(deps[i]) end
					end
				end
				textColor(colors.yellow)
				io.write("Is library: ")
				textColor(colors.gray)
				if packet[7] then print("yes") else print("No") end
				textColor(colors.yellow)
				io.write("Has manual: ")
				textColor(colors.gray)
				if packet[8] then print("Yes") else print("No") end
				if packet[10] then
					textColor(colors.magenta)
					print("Is archive: Yes")
				end
				print()
				return
			end
		end
		io.stderr:write("Package with specified name not found")
	end
end

local function printAppList(archive)
	fetchAppList()
	if appList then
		local page = 1
		local apps = {}
		for _, a in pairs(appList) do
			if not a[10] then
				table.insert(apps, {a[1], a[4]})
			elseif a[10] and archive then
				table.insert(apps, {a[1], a[4], true})
			end
		end
		while true do
			term.clear()
			term.setCursor(1, 1)
			textColor(colors.green)
			io.write("Package list     ")
			textColor(colors.orange)
			print("page " .. tostring(page))
			for i = 1, resolution[2] - 3 do
				if i + (page - 1) * (resolution[2] - 3) > #apps then break end
				local app = apps[i + ((resolution[2] - 3) * (page - 1))]
				textColor(app[3] and colors.magenta or colors.yellow)
				io.write(i .. ". " .. app[1])
				textColor(colors.gray)
				print(" - " .. app[2])
			end
			term.setCursor(1, resolution[2])
			textColor(colors.green)
			term.write("Q - quit application ")
			if page > 1 then io.write(" [Left] - previous page") end
			if #apps > (resolution[2] * page) then io.write("[Right] - next page") end
			local ev = {event.pull("key_down")}
			if ev[4] == keyboard.keys.q then
				return
			elseif ev[4] == keyboard.keys.left and #apps > ((resolution[2] - 3) * page) then
				page = page + 1
			elseif ev[4] == keyboard.keys.right and page > 1 then
				page = page - 1
			end
		end
	else
		io.stderr:write("Couldn't download the registry")
	end
end

local function clearAfterFail(tab)
	for _, appl in pairs(tab) do
		fs.remove(appl)
	end
end

local generateList = nil
generateList = function(appData, deps, list)
	--[[
	list = {
		{
			[1] = package name:string
			[2] = download link:string,
			[3] = directory:string,
			[4] = file name:string,
			[5] = version:string
			[6] = manual:string or nil
		}
		...
	}
	]]
	if not list then list = {} end
	local found = false
	for _, b in pairs(list) do
		if b[1] == appData[1] then
			found = true
			break
		end
	end
	if not found then
		local saveLocation = appData[7] and "/lib/" or "/usr/bin/"
		if appData[9] then
			saveLocation = saveLocation .. appData[9]
		else
			saveLocation = saveLocation .. appData[1] .. ".lua"
		end
		local segments = fs.segments(saveLocation)
		local dir = ""
		for i = 1, #segments - 1 do
			dir = dir .. "/" .. segments[i]
		end
		dir = dir .. "/"
		local add = {
			[1] = appData[1],
			[2] = appData[3],
			[3] = dir,
			[4] = segments[#segments],
			[5] = appData[2],
			[6] = appData[8]
		}
		table.insert(list, add)
	end
	if deps then
		for _, b in pairs(appData[6] or {}) do
			local dependency = getAppData(b)
			if not dependency then
				io.stderr:write("Dependency not found: " .. b)
				return
			end
			if not generateList(dependency, true, list) then return end
		end
	end
	return list
end

local function installApp(appName, force_install, disable_dep_install)
	textColor(colors.blue)
	print("\nStarting installation...")
	os.sleep(0.2)
	textColor(colors.cyan)
	term.write("\nDownloading the registry...   ")
	fetchAppList()
	if appList then
		application = getAppData(appName)
		if not application then
			textColor(colors.red)
			term.write("\nError: application with specified name not found")
			return
		end
		ok()
		term.write("\nGenerating installation list...   ")
		local list = generateList(application, not disable_dep_install)
		if not list then
			textColor(colors.yellow)
			term.write("\nInstallation aborted.")
			return
		end
		ok()
		term.write("\nChecking directories...   ")
		for _, t in pairs(list) do
			if not fs.isDirectory(t[3]) then
				local s, e = fs.makeDirectory(t[3])
				if not s then
					io.stderr:write("Cannot create directory " .. t[3] .. ": " .. e)
					textColor(colors.yellow)
					term.write("\nInstallation aborted.")
					return
				end
			end
		end
		ok()
		term.write("\nCopying files:")
		for _, t in pairs(list) do
			local filename = fs.concat(t[3], t[4])
			textColor(colors.silver)
			term.write("\n" .. filename)
			if fs.exists(filename) then
				local localfile = loadfile(filename)
				local version = localfile and localfile("version_check") or ""
				if version == t[5] and not force_install then
					textColor(colors.orange)
					term.write("   (up-to-date)")
				elseif type(version) == "string" and version:len() > 0 then
					textColor(colors.green)
					term.write("   (update: " .. version .. " -> " .. t[5] .. ")")
				else
					textColor(colors.brown)
					term.write("   (version unknown)")
				end
			end
			local output = io.open(filename, "w")
			if not output then
				io.stderr:write("\nCannot create file: " .. t[4])
				if not force_install then
					io.stderr:write("\nInstallation failed!")
					output:close()
					clearAfterFail(installed)
				end
			end
			table.insert(installed, filename)
			local source = getApp(t[2])
			if source then
				output:write(source)
				output:close()
			else
				io.stderr:write("\nCouldn't download file " .. t[4])
				if not force_install then
					io.stderr:write("\nInstallation failed!")
					output:close()
					clearAfterFail(installed)
					return
				else
					output:close()
					fs.remove(filename)
				end
			end
		end
		local manuals = {}
		for _, t in pairs(list) do
			if t[5] then
				table.insert(manuals, t[6])
			end
		end
		if #manuals > 0 then
			local manaddr = "https://gitlab.com/d_rzepka/oc-equipment/raw/master/man/"
			local mandir = "/usr/man/"
			textColor(colors.cyan)
			term.write("\nPreparing manual...")
			textColor(colors.silver)
			for _, s in pairs(manuals) do
				term.write("\n" .. s)
				local mansource = getapp(manaddr .. s)
				if mansource then
					local manfile = io.open(fs.concat(mandir, s), "w")
					if manfile then
						manfile:write(mansource)
						manfile:close()
					else
						io.stderr:write("\nCouldn't create manual file.")
						fs.remove(fs.concat(mandir, s))
					end
				else
					io.stderr:write("\nManual file not found.")
				end
			end
		end
		textColor(colors.green)
		term.write("\nInstallation successful")
	else
		io.stderr:write("Couldn't download the registry.")
		return
	end
end

local function uninstallApp(appName, deps)
	if not appName then
		io.stderr:write("You must specifiy application name")
		return
	end
	local name = appName
	if string.sub(appName, string.len(appName) - 4, string.len(appName)) == ".lua" then
		name = string.sub(appName, 1, string.len(apppName) - 4)
	end
	textColor(colors.cyan)
	term.write("\nDownloading the registry...   ")
	fetchAppList()
	if not appList then
		textColor(colors.red)
		term.write("Error\nRegistry download failed.")
		textColor(colors.yellow)
		term.write("\nDeinistallation aborted.")
		return
	end
	local application = getAppData(name)
	if not application then
		textColor(colors.red)
		term.write("Error\nCouldn't find the application with specified name")
		textColor(colors.yellow)
		term.write("\nDeinstalacja przerwana.")
		return
	end
	ok()
	term.write("\nGenerating deinstallation list...   ")
	local list  = generateList(application, deps)
	if not list then
		textColor(colors.yellow)
		term.write("\nDeinstallation aborted")
		return
	end
	ok()
	term.write("\nRemoving applications:")
	textColor(colors.silver)
	for _, t in pairs(list) do
		local filename = fs.concat(t[3], t[4])
		term.write("\n" .. filename)
		if fs.exists(filename) then
			local s, e = fs.remove(filename)
			if not s then
				io.stderr:write("\nError: " .. e)
			end
		end
	end
	textColor(colors.green)
	print("\nDeinstallation successful.")
end

local function refreshRegistry()
	textColor(colors.cyan)
	print("\nRefreshing the registry...")
	fetchAppList(true)
	if not appList then
		io.stderr:write("Couldn't download the registry.")
	else
		textColor(colors.green)
		print("Update successful")
	end
end

local function main()
	if args[1] == "list" then
		printAppList(options.r)
	elseif args[1] == "info" then
		packetInfo(args[2])
	elseif args[1] == "install" then
		installApp(args[2], options.f, options.n)
	elseif args[1] == "remove" then
		uninstallApp(args[2], options.d)
	elseif args[1] == "refresh" then
		refreshRegistry()
	elseif args[1] == "test" then
		testRepo(args[2])
	elseif args[1] == "self-update" then
		selfUpdate()
	elseif args[1] == "version_check" then
		return version
	else
		usage()
	end
end

local pprev = gpu.getForeground()
main()
gpu.setForeground(pprev)