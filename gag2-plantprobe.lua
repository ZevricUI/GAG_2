--[[
  Zev Hub — PlantSeed argument probe

  Auto-plant assumed PlantSeed takes 2 args and only probed their
  order. If it takes a different number, both probes fail and nothing
  plants. This reads the real arity from the remote's Writes
  serializers, using known-working remotes as a baseline.
--]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Networking = require(ReplicatedStorage.SharedModules.Networking)

local lines = {}
local function add(t, k) table.insert(lines, {text=t, kind=k or "info"}) end

local function describe(path, remote)
	if type(remote) ~= "table" then add(path .. ": missing", "bad") return end
	local w = rawget(remote, "Writes")
	local r = rawget(remote, "Reads")
	add(path .. "  Writes=" .. (type(w)=="table" and #w or "?") ..
	    "  Reads=" .. (type(r)=="table" and #r or "?"), "good")
	if type(w) == "table" then
		for i, fn in ipairs(w) do
			local info = "?"
			if type(fn) == "function" and debug and debug.info then
				local ok, n = pcall(debug.info, fn, "a")
				if ok then info = tostring(n) end
			end
			add("    Writes[" .. i .. "] params=" .. info)
		end
	end
end

add("Baselines (these already work):")
describe("SeedShop.PurchaseSeed", Networking.SeedShop and Networking.SeedShop.PurchaseSeed)
describe("Garden.CollectFruit", Networking.Garden and Networking.Garden.CollectFruit)
add("")
add("Target:")
describe("Plant.PlantSeed", Networking.Plant and Networking.Plant.PlantSeed)
add("")

add("Your Backpack (are seeds tools you must equip?):")
local bp = Players.LocalPlayer:FindFirstChild("Backpack")
if bp then
	local n = 0
	for _, item in ipairs(bp:GetChildren()) do
		n += 1
		if n <= 12 then add("  " .. item.Name .. " [" .. item.ClassName .. "]") end
	end
	if n == 0 then add("  (empty)", "bad") end
	if n > 12 then add("  ...and " .. (n-12) .. " more") end
else
	add("  no Backpack", "bad")
end
local char = Players.LocalPlayer.Character
if char then
	local tool = char:FindFirstChildWhichIsA("Tool")
	add("Equipped tool: " .. (tool and tool.Name or "none"), tool and "good" or "info")
end

local dump = "Zev Hub — PlantSeed probe\n\n"
for _, l in ipairs(lines) do dump = dump .. l.text .. "\n" end
local copied = setclipboard and pcall(setclipboard, dump) or false

local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerPlantProbe"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
local f = Instance.new("Frame")
f.AnchorPoint = Vector2.new(0.5,0.5); f.Position = UDim2.new(0.5,0,0.5,0)
f.Size = UDim2.new(0,360,0,420); f.BackgroundColor3 = Color3.fromRGB(14,14,16)
f.BackgroundTransparency = 0.04; f.BorderSizePixel = 0; f.Active = true; f.Parent = gui
local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0,16); c.Parent = f
local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(255,255,255); s.Transparency = 0.88; s.Parent = f
local t = Instance.new("TextLabel"); t.BackgroundTransparency = 1
t.Position = UDim2.new(0,16,0,12); t.Size = UDim2.new(1,-60,0,20)
t.Font = Enum.Font.GothamBold; t.Text = "⚡ PlantSeed probe"; t.TextColor3 = Color3.new(1,1,1)
t.TextSize = 15; t.TextXAlignment = Enum.TextXAlignment.Left; t.Parent = f
local sub = Instance.new("TextLabel"); sub.BackgroundTransparency = 1
sub.Position = UDim2.new(0,16,0,32); sub.Size = UDim2.new(1,-32,0,16); sub.Font = Enum.Font.Gotham
sub.Text = copied and "Copied — paste it back" or "Screenshot this"
sub.TextColor3 = copied and Color3.fromRGB(120,255,170) or Color3.fromRGB(200,200,205)
sub.TextSize = 11; sub.TextXAlignment = Enum.TextXAlignment.Left; sub.Parent = f
local x = Instance.new("TextButton"); x.AnchorPoint = Vector2.new(1,0)
x.Position = UDim2.new(1,-12,0,12); x.Size = UDim2.new(0,24,0,24); x.BackgroundTransparency = 1
x.Text = "×"; x.TextColor3 = Color3.fromRGB(200,200,205); x.TextSize = 20
x.Font = Enum.Font.GothamBold; x.Parent = f
x.MouseButton1Click:Connect(function() gui:Destroy() end)
local sc = Instance.new("ScrollingFrame"); sc.Position = UDim2.new(0,16,0,54)
sc.Size = UDim2.new(1,-32,1,-66); sc.BackgroundTransparency = 1
sc.CanvasSize = UDim2.new(0,0,0,0); sc.AutomaticCanvasSize = Enum.AutomaticSize.Y
sc.ScrollBarThickness = 4; sc.BorderSizePixel = 0; sc.Parent = f
local ly = Instance.new("UIListLayout"); ly.Padding = UDim.new(0,2); ly.Parent = sc
local COL = { good = Color3.fromRGB(120,255,170), bad = Color3.fromRGB(255,140,140), info = Color3.fromRGB(200,200,205) }
for _, l in ipairs(lines) do
	local lb = Instance.new("TextLabel"); lb.BackgroundTransparency = 1
	lb.Size = UDim2.new(1,0,0,0); lb.AutomaticSize = Enum.AutomaticSize.Y
	lb.Font = Enum.Font.Code; lb.Text = l.text; lb.TextColor3 = COL[l.kind] or COL.info
	lb.TextSize = 12; lb.TextWrapped = true; lb.TextXAlignment = Enum.TextXAlignment.Left; lb.Parent = sc
end
