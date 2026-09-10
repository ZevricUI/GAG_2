--[[
  Zev Hub — World diagnostic

  Run this IN the world where planting fails (e.g. Maple). It reports
  what that world actually looks like, so auto-plant can be fixed
  against facts instead of assumptions carried over from the main world.

  Shows on screen and copies to clipboard if your executor supports it.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local lines = {}

local function add(text, kind)
	table.insert(lines, { text = text, kind = kind or "info" })
end

--========================================================
-- Identity
--========================================================
add("PlaceId: " .. tostring(game.PlaceId))
add("JobId: " .. tostring(game.JobId))
add("Player: " .. tostring(player.Name))
add("")

--========================================================
-- Does this world expose the same remotes the script relies on?
--========================================================
local okReq, Networking = pcall(function()
	return require(ReplicatedStorage.SharedModules.Networking)
end)

if not okReq then
	add("require(SharedModules.Networking) FAILED", "bad")
	add(tostring(Networking), "bad")
else
	add("Networking module: OK", "good")
	local function probe(path)
		local node = Networking
		for part in tostring(path):gmatch("[^%.]+") do
			if type(node) ~= "table" then node = nil break end
			node = node[part]
		end
		add(path .. ": " .. (node and "present" or "MISSING"), node and "good" or "bad")
	end
	probe("Plant.PlantSeed")
	probe("Garden.PlantAdded")
	probe("Garden.CollectFruit")
	probe("NPCS.SellAll")
	probe("SeedShop.PurchaseSeed")
end
add("")

--========================================================
-- Stock folders (the script builds all its item lists from these)
--========================================================
local okStock, stock = pcall(function() return ReplicatedStorage.StockValues end)
if okStock and stock then
	add("StockValues: OK", "good")
	for _, shop in ipairs(stock:GetChildren()) do
		local items = shop:FindFirstChild("Items")
		local count = items and #items:GetChildren() or 0
		add("  " .. shop.Name .. " -> " .. count .. " items")
	end
else
	add("ReplicatedStorage.StockValues MISSING", "bad")
end
add("")

--========================================================
-- Where is the plot? This is what broke planting before.
--========================================================
add("Workspace top-level children:")
for _, child in ipairs(Workspace:GetChildren()) do
	add("  " .. child.Name .. "  [" .. child.ClassName .. "]")
end
add("")

add("Searching for a plot attributed to you...")
local found = false
for _, container in ipairs(Workspace:GetChildren()) do
	if container:IsA("Folder") or container:IsA("Model") then
		local ok, children = pcall(function() return container:GetChildren() end)
		if ok then
			for _, plot in ipairs(children) do
				local owner = plot:GetAttribute("Owner")
				if owner ~= nil then
					local mine = (owner == player.Name)
					add(
						"  " .. container.Name .. "/" .. plot.Name .. "  Owner=" .. tostring(owner) .. (mine and "  <-- YOURS" or ""),
						mine and "good" or "info"
					)
					if mine then
						found = true
						-- What's inside it? Planting needs to know.
						for _, sub in ipairs(plot:GetChildren()) do
							add("      " .. sub.Name .. "  [" .. sub.ClassName .. "]")
						end
					end
				end
			end
		end
	end
end
if not found then
	add("  No plot with an Owner attribute matching you.", "bad")
	add("  This world likely marks ownership a different way.", "bad")
end
add("")

--========================================================
-- Attributes on the plot-ish containers, in case ownership is
-- expressed under a different attribute name entirely.
--========================================================
add("Any Workspace child with attributes:")
for _, container in ipairs(Workspace:GetChildren()) do
	local ok, attrs = pcall(function() return container:GetAttributes() end)
	if ok and attrs then
		for name, value in pairs(attrs) do
			add("  " .. container.Name .. "." .. tostring(name) .. " = " .. tostring(value))
		end
	end
end

--========================================================
-- Clipboard + UI
--========================================================
local dumpParts = { "Zev Hub — World diagnostic", "" }
for _, entry in ipairs(lines) do
	table.insert(dumpParts, entry.text)
end
local dumpText = table.concat(dumpParts, "\n")

local copied = false
if setclipboard then
	copied = pcall(setclipboard, dumpText)
end

local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerWorldDiag"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0, 380, 0, 460)
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
title.Text = "⚡ World diagnostic"
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
subtitle.Text = copied and "Copied to clipboard — paste it back" or "Clipboard unavailable — screenshot this"
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
