--[[
  Zev Hub diagnostic — shows results directly on screen (no console
  needed). Run this by itself, read the panel, then screenshot or type
  out what it says.
--]]

local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerDiagUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0, 340, 0, 400)
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
title.Size = UDim2.new(1, -32, 0, 20)
title.Font = Enum.Font.GothamBold
title.Text = "⚡ Zev Hub — Diagnostic"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

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

-- Drag support
do
	local dragging, dragStart, startPos = false, nil, nil
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
	game:GetService("UserInputService").InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
end

local scroll = Instance.new("ScrollingFrame")
scroll.Position = UDim2.new(0, 16, 0, 40)
scroll.Size = UDim2.new(1, -32, 1, -52)
scroll.BackgroundTransparency = 1
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.ScrollBarThickness = 4
scroll.BorderSizePixel = 0
scroll.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 4)
layout.Parent = scroll

local GREEN = Color3.fromRGB(120, 255, 170)
local RED = Color3.fromRGB(255, 140, 140)
local GREY = Color3.fromRGB(180, 180, 185)

local function addLine(text, color)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Font = Enum.Font.Code
	label.Text = text
	label.TextColor3 = color or GREY
	label.TextSize = 13
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = scroll
	return label
end

--========================================================
addLine("getgc exists: " .. tostring(getgc ~= nil), getgc and GREEN or RED)
addLine("debug.getupvalue exists: " .. tostring(debug ~= nil and debug.getupvalue ~= nil), (debug and debug.getupvalue) and GREEN or RED)
addLine("debug.info exists: " .. tostring(debug ~= nil and debug.info ~= nil), (debug and debug.info) and GREEN or RED)

if not getgc then
	addLine("", GREY)
	addLine("getgc is missing entirely on this executor.", RED)
	addLine("That's the whole problem — Stats can't work without it.", RED)
else
	local ok, list = pcall(getgc)
	if not ok then
		addLine("", GREY)
		addLine("Calling getgc() errored: " .. tostring(list), RED)
	else
		local totalFunctions = 0
		local matchedSources = {}

		for _, v in pairs(list) do
			if type(v) == "function" then
				totalFunctions += 1
				local ok2, src = pcall(debug.info, v, "s")
				if ok2 and src and src:match("RestockStoreController") then
					local ok3, line = pcall(debug.info, v, "l")
					table.insert(matchedSources, tostring(src) .. " @ line " .. tostring(ok3 and line or "?"))
				end
			end
		end

		addLine("", GREY)
		addLine("Total live functions from getgc(): " .. totalFunctions, GREY)
		addLine("Functions matching 'RestockStoreController': " .. #matchedSources, #matchedSources > 0 and GREEN or RED)
		for _, s in ipairs(matchedSources) do
			addLine("  -> " .. s, GREY)
		end

		if #matchedSources == 0 then
			addLine("", GREY)
			addLine("No match at all. Either RestockStoreController isn't", RED)
			addLine("the right script name in this game/version, or getgc()", RED)
			addLine("isn't seeing it (hasn't loaded yet, or limited getgc).", RED)
		end
	end
end

addLine("", GREY)
addLine("(Tap × top-right to close, or drag the title to move this.)", GREY)
