-- Zev Hub minimal test — if this doesn't show a giant red box with
-- "Zev Hub TEST" on it, the problem is upstream of any of our
-- other scripts (the loadstring itself isn't running, or your
-- executor can't create GUI at all).

local player = game:GetService("Players").LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerHelloTest"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(1, 0, 1, 0)
frame.BackgroundColor3 = Color3.fromRGB(220, 30, 30)
frame.Parent = gui

local label = Instance.new("TextLabel")
label.Size = UDim2.new(1, 0, 1, 0)
label.BackgroundTransparency = 1
label.Text = "Zev Hub TEST\nIf you can see this, tap anywhere to close."
label.TextColor3 = Color3.new(1, 1, 1)
label.TextScaled = true
label.Font = Enum.Font.GothamBold
label.Parent = frame

local btn = Instance.new("TextButton")
btn.Size = UDim2.new(1, 0, 1, 0)
btn.BackgroundTransparency = 1
btn.Text = ""
btn.Parent = frame
btn.MouseButton1Click:Connect(function()
	gui:Destroy()
end)
