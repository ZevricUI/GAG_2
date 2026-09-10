--[[
  Zev Hub — PlantSeed spy

  Stop guessing the argument shape. This hooks Networking.Plant.PlantSeed
  and records the EXACT arguments the game itself sends.

  How to use:
    1. Run this.
    2. Plant ONE seed by hand, the normal way.
    3. Read the panel (also copied to clipboard) and paste it back.

  The hook passes everything straight through, so your manual plant
  still works normally.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local lines = {}
local captured = 0

local function add(text, kind)
	table.insert(lines, { text = text, kind = kind or "info" })
end

--========================================================
-- Describe a value precisely enough to rebuild it.
--========================================================
local function describe(value)
	local t = typeof(value)
	if t == "Instance" then
		return string.format("Instance %s (%s) @ %s", value.ClassName, value.Name, value:GetFullName())
	elseif t == "Vector3" then
		return string.format("Vector3(%.2f, %.2f, %.2f)", value.X, value.Y, value.Z)
	elseif t == "CFrame" then
		local p = value.Position
		return string.format("CFrame at (%.2f, %.2f, %.2f)", p.X, p.Y, p.Z)
	elseif t == "table" then
		local parts = {}
		for k, v in pairs(value) do
			table.insert(parts, tostring(k) .. "=" .. typeof(v) .. "(" .. tostring(v) .. ")")
		end
		table.sort(parts)
		return "table { " .. table.concat(parts, ", ") .. " }"
	elseif t == "string" then
		return string.format("string %q", value)
	end
	return t .. " " .. tostring(value)
end

--========================================================
-- Hook
--========================================================
local okReq, Networking = pcall(function()
	return require(ReplicatedStorage.SharedModules.Networking)
end)

local refresh -- forward declaration; the UI defines it below

if not okReq then
	add("require(SharedModules.Networking) FAILED", "bad")
	add(tostring(Networking), "bad")
else
	local PlantSeed = Networking.Plant.PlantSeed
	local originalFire = PlantSeed.Fire

	if type(originalFire) ~= "function" then
		add("PlantSeed.Fire is not a function — cannot hook", "bad")
	else
		PlantSeed.Fire = function(self, ...)
			local args = table.pack(...)
			captured += 1
			add("")
			add("=== CAPTURE #" .. captured .. " — " .. args.n .. " argument(s) ===", "good")
			for i = 1, args.n do
				add("  arg[" .. i .. "]: " .. describe(args[i]), "good")
			end
			if refresh then pcall(refresh) end
			-- Pass through untouched so the real plant still happens.
			return originalFire(self, ...)
		end
		add("Hook installed on Plant.PlantSeed", "good")
		add("")
		add("Now plant ONE seed by hand.", "info")
		add("The exact arguments will appear below.", "info")
	end
end

--========================================================
-- UI
--========================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerPlantSpy"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0, 380, 0, 420)
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
title.Text = "⚡ PlantSeed spy"
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
subtitle.Text = "Plant one seed by hand…"
subtitle.TextColor3 = Color3.fromRGB(200, 200, 205)
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
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

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

local COLORS = {
	good = Color3.fromRGB(120, 255, 170),
	bad = Color3.fromRGB(255, 140, 140),
	info = Color3.fromRGB(200, 200, 205),
}

-- Redraws the whole list. Cheap here, and it keeps captures arriving
-- live without any bookkeeping about which lines were already drawn.
refresh = function()
	for _, child in ipairs(scroll:GetChildren()) do
		if child:IsA("TextLabel") then child:Destroy() end
	end
	for _, entry in ipairs(lines) do
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, 0, 0, 0)
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.Font = Enum.Font.Code
		label.Text = entry.text
		label.TextColor3 = COLORS[entry.kind] or COLORS.info
		label.TextSize = 12
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = scroll
	end

	if captured > 0 then
		local dumpParts = { "Zev Hub — PlantSeed spy", "" }
		for _, entry in ipairs(lines) do
			table.insert(dumpParts, entry.text)
		end
		local copied = false
		if setclipboard then
			copied = pcall(setclipboard, table.concat(dumpParts, "\n"))
		end
		subtitle.Text = captured .. " capture(s)" .. (copied and " · copied to clipboard" or " · screenshot this")
		subtitle.TextColor3 = COLORS.good
	end
end

refresh()
