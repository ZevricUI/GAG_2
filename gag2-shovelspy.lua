--[[
  Zev Hub — Shovel spy

  Hooks EVERY remote in the game's Networking module and records what
  gets fired. Dig up one plant by hand with the shovel and the exact
  remote and arguments show up below.

  Calls pass straight through, so your manual dig still works.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local lines = {}
local captured = 0
local refresh -- defined with the UI below

local function add(text, kind)
	table.insert(lines, { text = text, kind = kind or "info" })
end

local function describe(value)
	local t = typeof(value)
	if t == "Instance" then
		local seed = nil
		pcall(function() seed = value:GetAttribute("SeedName") end)
		return string.format(
			"Instance %s (%s)%s",
			value.ClassName,
			value.Name,
			seed and (" SeedName=" .. tostring(seed)) or ""
		)
	elseif t == "Vector3" then
		return string.format("Vector3(%.1f, %.1f, %.1f)", value.X, value.Y, value.Z)
	elseif t == "CFrame" then
		local p = value.Position
		return string.format("CFrame at (%.1f, %.1f, %.1f)", p.X, p.Y, p.Z)
	elseif t == "string" then
		return string.format("string %q", value)
	elseif t == "table" then
		local parts = {}
		for k, v in pairs(value) do
			table.insert(parts, tostring(k) .. "=" .. tostring(v))
		end
		table.sort(parts)
		return "table { " .. table.concat(parts, ", ") .. " }"
	end
	return t .. " " .. tostring(value)
end

--========================================================
-- Hook every remote we can find.
--========================================================
local okReq, Networking = pcall(function()
	return require(ReplicatedStorage.SharedModules.Networking)
end)

local hooked = 0

if not okReq then
	add("require(SharedModules.Networking) FAILED", "bad")
	add(tostring(Networking), "bad")
else
	local seen = {}

	local function hook(node, prefix, depth)
		if depth > 4 or type(node) ~= "table" or seen[node] then return end
		seen[node] = true

		pcall(function()
			for key, value in pairs(node) do
				local path = prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
				if type(value) == "table" then
					-- value.Fire, not rawget: these remote objects share
					-- a metatable and expose Fire through __index, so a
					-- raw lookup finds nothing and hooks nothing.
					local okFire, fire = pcall(function() return value.Fire end)
					if okFire and type(fire) == "function" then
						local original = fire
						value.Fire = function(self, ...)
							local args = table.pack(...)
							captured += 1
							add("")
							add("#" .. captured .. "  " .. path .. "  (" .. args.n .. " args)", "good")
							for i = 1, args.n do
								add("   arg[" .. i .. "]: " .. describe(args[i]), "good")
							end
							if refresh then pcall(refresh) end
							return original(self, ...)
						end
						hooked += 1
					end
					hook(value, path, depth + 1)
				end
			end
		end)
	end

	hook(Networking, "", 1)
	add("Hooked " .. hooked .. " remote(s).", hooked > 0 and "good" or "bad")
	if hooked == 0 then
		add("Nothing exposed a Fire function — the module is shaped", "bad")
		add("differently than expected.", "bad")
	end
	add("")
	add("Now dig up ONE plant by hand with the shovel.", "info")
	add("Whatever the game fires will appear below.", "info")
end

--========================================================
-- UI
--========================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerShovelSpy"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0, 400, 0, 440)
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
title.Text = "⚡ Shovel spy"
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
subtitle.Text = "Dig up one plant by hand…"
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

-- Only the tail is drawn: a busy farm fires plenty of unrelated
-- remotes, and the dig is whatever lands right after you press.
refresh = function()
	for _, child in ipairs(scroll:GetChildren()) do
		if child:IsA("TextLabel") then child:Destroy() end
	end

	local first = math.max(1, #lines - 60)
	for i = first, #lines do
		local entry = lines[i]
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
		label.LayoutOrder = i
		label.Parent = scroll
	end

	if captured > 0 then
		local dumpParts = {}
		for _, entry in ipairs(lines) do
			table.insert(dumpParts, entry.text)
		end
		local copied = false
		if setclipboard then
			copied = pcall(setclipboard, table.concat(dumpParts, "\n"))
		end
		subtitle.Text = captured .. " call(s)" .. (copied and " · copied to clipboard" or " · screenshot this")
		subtitle.TextColor3 = COLORS.good
	end
end

refresh()
