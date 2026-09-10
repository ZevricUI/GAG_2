--[[
  Zev Hub — Networking explorer

  Lists everything inside the game's Networking module so we can see
  the real remote names (and their types) instead of guessing them.
  Shows on screen — no console needed — and copies the full dump to
  your clipboard if your executor supports setclipboard.

  Run this by itself, then paste (or screenshot) the output.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local okReq, Networking = pcall(function()
	return require(ReplicatedStorage.SharedModules.Networking)
end)

--========================================================
-- Walk the module and build a flat list of "path — type" lines.
--========================================================
local lines = {}

local function describe(value)
	local t = typeof(value)
	if t == "Instance" then
		return value.ClassName
	end
	return t
end

local function walk(node, prefix, depth)
	if depth > 3 then return end
	local keys = {}
	local ok = pcall(function()
		for key in pairs(node) do
			table.insert(keys, key)
		end
	end)
	if not ok then return end

	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

	for _, key in ipairs(keys) do
		local okVal, value = pcall(function() return node[key] end)
		if okVal then
			local path = prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
			table.insert(lines, { path = path, kind = describe(value) })
			if typeof(value) == "table" then
				walk(value, path, depth + 1)
			end
		end
	end
end

if okReq and typeof(Networking) == "table" then
	walk(Networking, "", 1)
else
	table.insert(lines, { path = "require(Networking) FAILED: " .. tostring(Networking), kind = "error" })
end

-- Anything whose name hints at planting, sorted to the top of the UI.
local function isInteresting(path)
	local lower = path:lower()
	return lower:match("plant") or lower:match("seed") or lower:match("garden") or lower:match("place")
end

--========================================================
-- Build the plain-text dump (for clipboard) up front.
--========================================================
local dumpParts = { "Zev Hub — Networking dump", "" }
for _, entry in ipairs(lines) do
	table.insert(dumpParts, entry.path .. "  [" .. entry.kind .. "]")
end
local dumpText = table.concat(dumpParts, "\n")

local copied = false
if setclipboard then
	copied = pcall(setclipboard, dumpText)
end

--========================================================
-- UI
--========================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerRemotesUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0, 380, 0, 440)
frame.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
frame.BackgroundTransparency = 0.04
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 16)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Transparency = 0.88
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 16, 0, 12)
title.Size = UDim2.new(1, -60, 0, 20)
title.Font = Enum.Font.GothamBold
title.Text = "⚡ Networking explorer"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Active = true
title.Parent = frame

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.new(0, 16, 0, 32)
subtitle.Size = UDim2.new(1, -32, 0, 16)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = copied and (#lines .. " entries · copied to clipboard") or (#lines .. " entries · clipboard unavailable, screenshot this")
subtitle.TextColor3 = copied and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(200, 200, 205)
subtitle.TextSize = 11
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Position = UDim2.new(1, -12, 0, 12)
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.BackgroundTransparency = 1
closeBtn.Text = "×"
closeBtn.TextColor3 = Color3.fromRGB(200, 200, 205)
closeBtn.TextSize = 20
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = frame
closeBtn.MouseButton1Click:Connect(function()
	gui:Destroy()
end)

-- Drag
do
	local dragging, dragStart, startPos = false, nil, nil
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

local scroll = Instance.new("ScrollingFrame")
scroll.Position = UDim2.new(0, 16, 0, 54)
scroll.Size = UDim2.new(1, -32, 1, -66)
scroll.BackgroundTransparency = 1
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.ScrollBarThickness = 4
scroll.BorderSizePixel = 0
scroll.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 2)
layout.Parent = scroll

local function addLine(text, color)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Font = Enum.Font.Code
	label.Text = text
	label.TextColor3 = color or Color3.fromRGB(200, 200, 205)
	label.TextSize = 12
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = scroll
end

local GREEN = Color3.fromRGB(120, 255, 170)
local GREY = Color3.fromRGB(170, 170, 175)
local WHITE = Color3.fromRGB(235, 235, 240)

-- Plant/seed-related entries first, since that's what we're after.
local hits = {}
for _, entry in ipairs(lines) do
	if isInteresting(entry.path) then table.insert(hits, entry) end
end

if #hits > 0 then
	addLine("— plant / seed / garden related —", GREEN)
	for _, entry in ipairs(hits) do
		addLine(entry.path .. "  [" .. entry.kind .. "]", WHITE)
	end
	addLine("", GREY)
end

addLine("— everything —", GREEN)
for _, entry in ipairs(lines) do
	addLine(entry.path .. "  [" .. entry.kind .. "]", GREY)
end
