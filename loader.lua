--[[
  Zev Hub — Universal Loader
  Detects the Roblox game you're currently in (via game.PlaceId), shows
  a small clean dark HUD in the top-right corner, and runs the best
  matching script from the Zev Hub catalog. Expand the panel to see
  every script registered for that game and switch between them.

  Switching REJOINS the server. That's not a limitation of this loader —
  it's the only way to guarantee a previously injected script is fully
  gone. Most real script hubs (Polluted Hub included) spawn their own
  background loops via task.spawn()/RunService connections the instant
  they run, completely outside anything this loader controls. There is
  no generic executor API to reach into arbitrary foreign code and kill
  everything it started; the only thing that reliably wipes all of it is
  a fresh Lua VM, which a rejoin gives you for free.

  On executors that support queue_on_teleport (most UNC-compliant ones
  do), the loader re-queues itself automatically so it comes back on
  its own right after the rejoin — no manual re-paste needed. On
  executors without it, add this loadstring to your executor's Auto
  Execute list for this game, or just re-run it manually once you're
  back in.

  Every script's code is fetched live from the Zev Hub database each
  time you launch or switch — nothing is ever bundled into this loader.

  Usage: paste this whole script into your executor and run it.
--]]

local SUPABASE_URL = "https://fscazttvhgwaqxkdphsp.supabase.co"
local ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZzY2F6dHR2aGd3YXF4a2RwaHNwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1MzI0NTYsImV4cCI6MjEwMTEwODQ1Nn0.WWKLNM6ZQZKF2DVne0diOaT3ZB7apbbbuk1lTH-b4L8"
local LOADER_URL = "https://raw.githubusercontent.com/ForgeApc/scriptEXEr/main/loader.lua"

local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local player = Players.LocalPlayer
local placeId = game.PlaceId

--========================================================
-- Networking
--========================================================
local function httpGet(url)
	local ok, res = pcall(function()
		return game:HttpGet(url)
	end)
	if ok and res then return res end

	local req = (syn and syn.request) or (http and http.request) or http_request or request
	if req then
		local ok2, res2 = pcall(function()
			return req({ Url = url, Method = "GET" }).Body
		end)
		if ok2 then return res2 end
	end
	return nil
end

-- Turns "1.2M" / "847K" / "312" into a comparable number.
local function parseDownloads(s)
	if not s then return 0 end
	local num, suffix = s:match("([%d%.]+)%s*([KMB]?)")
	num = tonumber(num) or 0
	if suffix == "K" then num = num * 1e3
	elseif suffix == "M" then num = num * 1e6
	elseif suffix == "B" then num = num * 1e9 end
	return num
end

-- Which script (if any) we were asked to run after a rejoin.
local requestedScriptId = nil
do
	local ok, joinData = pcall(function() return player:GetJoinData() end)
	if ok and joinData and joinData.TeleportData and joinData.TeleportData.scriptexerScriptId then
		requestedScriptId = joinData.TeleportData.scriptexerScriptId
	end
end

--========================================================
-- UI — solid dark HUD, top-right corner, draggable
--========================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerLoaderUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

-- Solid dark card — nearly opaque black, thin subtle border, no gradient
-- or transparency tricks. Reads clean and legible over any game scene.
local COMPACT_HEIGHT = 104
local ROW_HEIGHT = 30
local MAX_VISIBLE_ROWS = 4

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(1, 0)
frame.Position = UDim2.new(1, -18, 0, 18)
frame.Size = UDim2.new(0, 270, 0, COMPACT_HEIGHT)
frame.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
frame.BackgroundTransparency = 0.04
frame.BorderSizePixel = 0
frame.ClipsDescendants = false
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 16)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Transparency = 0.88
stroke.Thickness = 1
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 16, 0, 12)
title.Size = UDim2.new(1, -32, 0, 18)
title.Font = Enum.Font.GothamBold
title.Text = "⚡ Zev Hub"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.ZIndex = 2
title.Parent = frame

local status = Instance.new("TextLabel")
status.Name = "Status"
status.BackgroundTransparency = 1
status.Position = UDim2.new(0, 16, 0, 32)
status.Size = UDim2.new(1, -32, 0, 34)
status.Font = Enum.Font.Gotham
status.Text = "Detecting game..."
status.TextColor3 = Color3.fromRGB(180, 180, 185)
status.TextSize = 12
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.ZIndex = 2
status.Parent = frame

-- Toggle row: expands/collapses the script list below it.
local scriptsToggle = Instance.new("TextButton")
scriptsToggle.Name = "ScriptsToggle"
scriptsToggle.Position = UDim2.new(0, 16, 1, -38)
scriptsToggle.Size = UDim2.new(1, -32, 0, 26)
scriptsToggle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
scriptsToggle.BackgroundTransparency = 0.94
scriptsToggle.AutoButtonColor = false
scriptsToggle.Font = Enum.Font.GothamBold
scriptsToggle.Text = "Scripts ▾"
scriptsToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
scriptsToggle.TextSize = 12
scriptsToggle.Visible = false
scriptsToggle.ZIndex = 2
scriptsToggle.Parent = frame

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(1, 0)
toggleCorner.Parent = scriptsToggle

local toggleStroke = Instance.new("UIStroke")
toggleStroke.Color = Color3.fromRGB(255, 255, 255)
toggleStroke.Transparency = 0.82
toggleStroke.Thickness = 1
toggleStroke.Parent = scriptsToggle

scriptsToggle.MouseEnter:Connect(function()
	scriptsToggle.BackgroundTransparency = 0.85
end)
scriptsToggle.MouseLeave:Connect(function()
	scriptsToggle.BackgroundTransparency = 0.94
end)

-- Script list: a small scrollable panel of rows, one per script,
-- revealed below the toggle when expanded.
local listHolder = Instance.new("Frame")
listHolder.Name = "ScriptList"
listHolder.Position = UDim2.new(0, 16, 1, -8)
listHolder.Size = UDim2.new(1, -32, 0, 0)
listHolder.BackgroundTransparency = 1
listHolder.ClipsDescendants = true
listHolder.Visible = false
listHolder.ZIndex = 2
listHolder.Parent = frame

local scroll = Instance.new("ScrollingFrame")
scroll.Name = "Scroll"
scroll.BackgroundTransparency = 1
scroll.Size = UDim2.new(1, 0, 1, 0)
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.ScrollBarThickness = 3
scroll.ScrollBarImageTransparency = 0.4
scroll.BorderSizePixel = 0
scroll.ZIndex = 2
scroll.Parent = listHolder

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = scroll

local expanded = false
local function setExpanded(value)
	expanded = value
	local rowCount = math.min(#scroll:GetChildren() - 1, MAX_VISIBLE_ROWS) -- minus UIListLayout
	local listHeight = expanded and (math.max(rowCount, 1) * ROW_HEIGHT + (rowCount - 1) * 4) or 0
	listHolder.Visible = expanded
	listHolder.Size = UDim2.new(1, -32, 0, math.max(listHeight, 0))
	scriptsToggle.Text = expanded and "Scripts ▴" or "Scripts ▾"
	frame.Size = UDim2.new(0, 270, 0, COMPACT_HEIGHT + (expanded and (listHeight + 12) or 0))
end

scriptsToggle.MouseButton1Click:Connect(function()
	setExpanded(not expanded)
end)

-- Drag support
do
	local dragging, dragStart, startPos = false, nil, nil
	frame.Active = true
	title.Active = true
	title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
end

local function setStatus(text)
	status.Text = text
end

--========================================================
-- Script catalog + execution
--========================================================
local matchedGame = nil
local scripts = {}
local scriptRows = {}

local function refreshRowHighlights(activeId)
	for _, entry in ipairs(scriptRows) do
		local active = entry.id == activeId
		entry.frame.BackgroundTransparency = active and 0.6 or 0.9
		entry.dot.TextColor3 = active and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(150, 150, 155)
	end
end

-- Rejoins the server, asking the loader (on rejoin) to run this specific
-- script. This is the only reliable way to guarantee whatever script is
-- running right now — including its background loops/connections/GUIs —
-- is actually gone before the new one starts.
local function switchToScript(s)
	setStatus("Rejoining to switch to " .. s.title .. "...")

	-- queue_on_teleport (a widely supported UNC extension) re-queues this
	-- exact loadstring to run automatically the instant the new server
	-- loads, so the panel comes back on its own without you having to
	-- manually re-paste anything. Not every executor has it, so this is
	-- best-effort — we fall back to telling you to re-run it manually.
	local requeued = false
	if queue_on_teleport then
		requeued = pcall(function()
			queue_on_teleport('loadstring(game:HttpGet("' .. LOADER_URL .. '"))()')
		end)
	end

	local ok, err = pcall(function()
		TeleportService:Teleport(placeId, player, { scriptexerScriptId = s.id })
	end)
	if not ok then
		setStatus("Couldn't rejoin automatically: " .. tostring(err) .. ". Rejoin the game manually and re-run the loadstring.")
	elseif not requeued then
		setStatus("Rejoining... your executor doesn't support auto-requeue, so re-run the loadstring once you're back in.")
	end
end

local function runScript(s)
	setStatus("Running: " .. s.title)
	refreshRowHighlights(s.id)
	task.spawn(function()
		local ok, err = pcall(function()
			loadstring(s.loadstring)()
		end)
		if not ok then
			setStatus("Failed: " .. s.title .. " — " .. tostring(err))
		end
	end)
end

local function buildScriptRows(activeId)
	for _, entry in ipairs(scriptRows) do
		entry.frame:Destroy()
	end
	scriptRows = {}

	for i, s in ipairs(scripts) do
		local row = Instance.new("TextButton")
		row.Name = "Row" .. i
		row.LayoutOrder = i
		row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT - 4)
		row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		row.BackgroundTransparency = 0.9
		row.AutoButtonColor = false
		row.Text = ""
		row.ZIndex = 2
		row.Parent = scroll

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 8)
		rowCorner.Parent = row

		local dot = Instance.new("TextLabel")
		dot.Name = "dot"
		dot.BackgroundTransparency = 1
		dot.Position = UDim2.new(0, 8, 0, 0)
		dot.Size = UDim2.new(0, 16, 1, 0)
		dot.Font = Enum.Font.GothamBold
		dot.Text = s.verified and "✓" or "•"
		dot.TextColor3 = Color3.fromRGB(150, 150, 155)
		dot.TextSize = 12
		dot.ZIndex = 2
		dot.Parent = row

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(0, 26, 0, 0)
		label.Size = UDim2.new(1, -34, 1, 0)
		label.Font = Enum.Font.Gotham
		label.Text = s.title
		label.TextColor3 = Color3.fromRGB(235, 235, 240)
		label.TextSize = 12
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.ZIndex = 2
		label.Parent = row

		row.MouseButton1Click:Connect(function()
			setExpanded(false)
			if s.id == activeId then return end
			switchToScript(s)
		end)

		table.insert(scriptRows, { frame = row, dot = dot, id = s.id })
	end
	refreshRowHighlights(activeId)
end

--========================================================
-- Boot — fetch game + its scripts live from Supabase
--========================================================
setStatus("Detecting game (PlaceId " .. tostring(placeId) .. ")...")

local gamesUrl = string.format(
	"%s/rest/v1/games?place_id=eq.%d&select=id,name&apikey=%s",
	SUPABASE_URL, placeId, ANON_KEY
)
local gamesBody = httpGet(gamesUrl)
if not gamesBody then
	setStatus("Couldn't reach the script database. Check your internet connection.")
	return
end

local okGames, games = pcall(function() return HttpService:JSONDecode(gamesBody) end)
if not okGames or #games == 0 then
	setStatus("No scripts registered for this game yet.")
	return
end

matchedGame = games[1]
setStatus("Script for " .. matchedGame.name .. " launching...")

local scriptsUrl = string.format(
	"%s/rest/v1/scripts?game_id=eq.%s&select=id,title,loadstring,verified,downloads&apikey=%s",
	SUPABASE_URL, HttpService:UrlEncode(matchedGame.id), ANON_KEY
)
local scriptsBody = httpGet(scriptsUrl)
if not scriptsBody then
	setStatus("Failed to fetch scripts for " .. matchedGame.name)
	return
end

local okScripts, fetchedScripts = pcall(function() return HttpService:JSONDecode(scriptsBody) end)
if not okScripts or #fetchedScripts == 0 then
	setStatus(matchedGame.name .. " has no scripts uploaded yet.")
	return
end

-- Prefer verified scripts, then the highest download count.
table.sort(fetchedScripts, function(a, b)
	if a.verified ~= b.verified then
		return a.verified
	end
	return parseDownloads(a.downloads) > parseDownloads(b.downloads)
end)
scripts = fetchedScripts

-- If we just rejoined to switch to a specific script, run that one.
-- Otherwise run the best pick (verified + most downloads).
local toRun = scripts[1]
if requestedScriptId then
	for _, s in ipairs(scripts) do
		if s.id == requestedScriptId then
			toRun = s
			break
		end
	end
end

buildScriptRows(toRun.id)
scriptsToggle.Visible = #scripts > 1
runScript(toRun)
