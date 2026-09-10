--[[
  Grow A Garden 2 — Auto Buy / Harvest / Sell / Stats
  Clean, readable, no obfuscation, no external network calls beyond the
  game's own remotes. Everything it does is visible below.

  Tabs:
    Buy     — toggle exactly which seeds/gears/crates get auto-bought,
              item lists built live from the game's own stock folders
    Plant   — auto-plants selected seeds at you, randomly across your
              plot, or at one pinned spot
    Drops   — teleports to dropped items and holds E to pick them up
    Harvest — auto-harvests fruit, ripe ones first, then attempts
              still-growing ones too
    Sell    — auto-sells your inventory on an adjustable delay
    Stats   — Sheckles earned/spent/net so far, elapsed time, and your
              average income per second/minute/hour/day
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Networking = require(ReplicatedStorage.SharedModules.Networking)

local PurchaseSeeds = Networking.SeedShop.PurchaseSeed
local SeedsStock = ReplicatedStorage.StockValues.SeedShop.Items

local PurchaseGears = Networking.GearShop.PurchaseGear
local GearsStock = ReplicatedStorage.StockValues.GearShop.Items

local PurchaseCrates = Networking.CrateShop.PurchaseCrate
local CratesStock = ReplicatedStorage.StockValues.CrateShop.Items

local CollectFruit = Networking.Garden.CollectFruit
local SellAll = Networking.NPCS.SellAll
local PlantSeed = Networking.Plant.PlantSeed

-- Item prices, collected opportunistically while searching for the
-- Sheckles balance below. Only used by canAfford(), which the buy
-- loop no longer calls.
local prices = {}

-- Stats state — declared up here (not down in the STATS section)
-- because the search below needs to set these the moment the balance
-- resolves, which can happen well after script start.
local StatsStartTime = tick()
local StatsStartingSheckles = nil
local TotalEarned = 0
local TotalSpent = 0
local lastSheckles = nil

local function looksLikePrices(t)
	if type(t) ~= "table" then return false end
	for _, entry in pairs(t) do
		if type(entry) == "table" and type(entry.price) == "number" then
			return true
		end
	end
	return false
end

--========================================================
-- Finding the EXACT Sheckles balance.
--
-- The previous version only looked at upvalues of functions whose
-- source matched "RestockStoreController" — one hardcoded script
-- name. If that script was renamed, restructured, or simply hadn't
-- loaded, the search found nothing and Stats stayed dead with no way
-- to recover. This tries several independent strategies instead and
-- stops at the first that yields a live number.
--
-- Each strategy returns a *getter*, not a snapshot, so the value
-- stays live as the balance changes.
--========================================================
local sheckleGetter = nil -- function() -> number
local sheckleSource = nil -- short description of which strategy won
local SheckleSearchFailed = false

-- 1. A live table on the GC heap holding the balance. getgc(true)
--    includes tables (not just functions) on most executors, so this
--    can find the player's data table directly — no script name, no
--    upvalue traversal, nothing position-dependent.
local function findViaHeapTables()
	local ok, list = pcall(getgc, true)
	if not ok or type(list) ~= "table" then return nil end
	local scanned = 0
	for _, v in pairs(list) do
		-- getgc(true) can return tens of thousands of tables; yielding
		-- periodically keeps this from visibly freezing the game.
		scanned += 1
		if scanned % 2000 == 0 then task.wait() end
		if type(v) == "table" then
			local ok2, getter = pcall(function()
				local data = rawget(v, "Data")
				if type(data) == "table" and type(rawget(data, "Sheckles")) == "number" then
					return function() return v.Data.Sheckles end
				end
				if type(rawget(v, "Sheckles")) == "number" then
					return function() return v.Sheckles end
				end
				return nil
			end)
			if ok2 and getter then
				pcall(function()
					if #prices == 0 and looksLikePrices(v) then table.insert(prices, v) end
				end)
				return getter, "heap table"
			end
		end
	end
	return nil
end

-- 2. Upvalues of *any* function, not just one named script. Same
--    shape matching as before, just without the name restriction
--    that was likely causing the failure.
local function findViaUpvalues()
	local result, desc = nil, nil
	local scanned = 0
	pcall(function()
		for _, v in pairs(getgc()) do
			scanned += 1
			if scanned % 1000 == 0 then task.wait() end
			if type(v) == "function" then
				local i = 1
				while true do
					local ok, name, value = pcall(debug.getupvalue, v, i)
					if not ok or not name then break end
					if type(value) == "table" then
						local ok2 = pcall(function()
							local data = rawget(value, "Data")
							if type(data) == "table" and type(rawget(data, "Sheckles")) == "number" then
								result = function() return value.Data.Sheckles end
								desc = "upvalue .Data.Sheckles"
							elseif type(rawget(value, "Sheckles")) == "number" then
								result = function() return value.Sheckles end
								desc = "upvalue .Sheckles"
							end
						end)
						if ok2 and result then return end
						if #prices == 0 and looksLikePrices(value) then
							table.insert(prices, value)
						end
					end
					i += 1
				end
			end
		end
	end)
	if result then return result, desc end
	return nil
end

-- 3. A numeric attribute on the player (exact by definition).
local function findViaAttributes()
	local player = Players.LocalPlayer
	local ok, attrs = pcall(function() return player:GetAttributes() end)
	if not ok or type(attrs) ~= "table" then return nil end
	for name, value in pairs(attrs) do
		if type(value) == "number" and tostring(name):lower():match("sheckle") then
			return function() return player:GetAttribute(name) end, "attribute:" .. tostring(name)
		end
	end
	return nil
end

-- Parses a currency string from the game's own on-screen HUD, e.g.
-- "1,913,817" or "$1,913,817" -> 1913817. Deliberately REJECTS
-- abbreviated forms ("1.9M"), because stripping the suffix off those
-- would silently yield 1.9 instead of 1900000 — far worse than
-- reporting no value at all.
local function parseExactNumber(text)
	if type(text) ~= "string" then return nil end
	if text:match("%d%s*[KkMmBbTt]") then return nil end -- abbreviated, not exact
	local cleaned = text:gsub(",", ""):gsub("[^%d%.%-]", "")
	if cleaned == "" then return nil end
	return tonumber(cleaned)
end

-- 4. The game's own on-screen Sheckles counter. Roblox HUDs commonly
--    show the full comma-formatted number even when leaderstats only
--    carries the abbreviated version, so this can be exact where
--    leaderstats isn't.
local function findViaScreenText()
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return nil end

	-- Never match our own panel's number labels — this script formats
	-- its stats with commas too, and reading its own output back in
	-- would be a self-referential feedback loop. (Our GUI normally
	-- lives in CoreGui/gethui() rather than PlayerGui, but guard
	-- anyway in case that ever changes.)
	local function isOurs(inst)
		local node, depth = inst, 0
		while node and depth < 8 do
			if tostring(node.Name):lower():match("scriptexer") then return true end
			node = node.Parent
			depth += 1
		end
		return false
	end

	local named, commaFormatted = nil, nil
	pcall(function()
		for _, inst in ipairs(playerGui:GetDescendants()) do
			if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and not isOurs(inst) and parseExactNumber(inst.Text) then
				-- Prefer a label whose own name (or a nearby ancestor's)
				-- identifies it as the Sheckles display.
				if not named then
					local node, depth = inst, 0
					while node and depth < 4 do
						if tostring(node.Name):lower():match("sheckle") then
							named = inst
							break
						end
						node = node.Parent
						depth += 1
					end
				end
				-- Otherwise fall back to any comma-formatted number, which
				-- in practice is nearly always a currency readout.
				if not commaFormatted and inst.Text:match("%d,%d") then
					commaFormatted = inst
				end
			end
		end
	end)

	local target = named or commaFormatted
	if target then
		return function() return parseExactNumber(target.Text) end, "screen text:" .. tostring(target.Name)
	end
	return nil
end

-- 5. A NumberValue/IntValue somewhere under the player. Deliberately
--    excludes StringValue — a string balance is the abbreviated
--    display form ("1.9M") and isn't exact.
local function findViaValueObjects()
	local player = Players.LocalPlayer
	local ok, descendants = pcall(function() return player:GetDescendants() end)
	if not ok then return nil end
	for _, inst in ipairs(descendants) do
		if (inst:IsA("NumberValue") or inst:IsA("IntValue")) and inst.Name:lower():match("sheckle") then
			return function() return inst.Value end, "value object:" .. inst.Name
		end
	end
	return nil
end

local function getCurrentSheckles()
	if not sheckleGetter then return nil end
	local ok, value = pcall(sheckleGetter)
	if ok and type(value) == "number" then return value end
	return nil
end

task.spawn(function()
	-- Authoritative sources (the game's own data) before display
	-- scraping. Screen text is deliberately LAST: its fallback matches
	-- any comma-formatted number, so if PlayerGui happens to have
	-- rendered some other figure (a price, an inventory count) by the
	-- time we scan, it could win and silently feed Stats a wrong
	-- value. PlayerGui load timing varies between sessions, so letting
	-- it outrank the real data table would make correctness a race.
	-- The heap scan costs a few hundred ms with its yields — cheap
	-- insurance against reading the wrong number.
	local strategies = {
		{ fn = findViaHeapTables, name = "heap tables" },
		{ fn = findViaAttributes, name = "attributes" },
		{ fn = findViaValueObjects, name = "value objects" },
		{ fn = findViaUpvalues, name = "upvalues" },
		{ fn = findViaScreenText, name = "screen text" },
	}

	local attempts = 0
	while not sheckleGetter and attempts < 40 do
		for _, strategy in ipairs(strategies) do
			local ok, getter, desc = pcall(strategy.fn)
			if ok and getter then
				sheckleGetter = getter
				sheckleSource = desc or strategy.name
				break
			end
		end
		if sheckleGetter then break end
		attempts += 1
		task.wait(0.5)
	end

	local starting = getCurrentSheckles()
	if starting then
		StatsStartTime = tick()
		StatsStartingSheckles = starting
		lastSheckles = starting
	else
		SheckleSearchFailed = true
		warn("[Zev Hub] Couldn't find the exact Sheckles balance after trying player attributes, value objects, on-screen text, heap tables and upvalues for 20s. Buy still works (it doesn't need this). Stats will stay unavailable.")
	end
end)

-- Kept for reference/possible future use. The buy loop deliberately
-- does NOT call this — it fires unconditionally and lets the server
-- decide, which is what actually got Buy working.
local function canAfford(item)
	local balance = getCurrentSheckles()
	if not balance or #prices == 0 then return false end
	for _, options in pairs(prices) do
		local success, result = pcall(function()
			local itemData = options[item]
			if not itemData then return false end
			return balance >= itemData.price
		end)
		if success and result then return true end
	end
	return false
end

--========================================================
-- BUY — selection state + buy loop (one per shop)
--========================================================
local Selected = { Seeds = {}, Gears = {}, Crates = {} }

local function isSelected(category, name)
	local v = Selected[category][name]
	if v == nil then return false end -- default off until toggled
	return v
end

local function countSelected()
	local n = 0
	for _, items in pairs(Selected) do
		for _, on in pairs(items) do
			if on then n += 1 end
		end
	end
	return n
end

local BuyInterval = 0.5

-- Live proof-of-activity state.
local BuyFiredCount = 0 -- selected items that got a Fire() call
local BuyLastFired = ""

-- Fires the purchase remote for every selected item on every pass,
-- unconditionally — regardless of stock status or whether you can
-- currently afford it. The server decides whether the purchase goes
-- through; this just keeps asking. (canAfford still exists and is
-- used elsewhere, but is intentionally NOT checked here anymore.)
local function runBuyLoop(stockFolder, remote, category)
	-- The shop's contents barely change, but GetChildren allocates a
	-- fresh table on every call — at a 0.001s interval across three
	-- loops that is thousands of throwaway tables a second. Cache it and
	-- refresh only when the folder actually changes.
	local cached = stockFolder:GetChildren()
	local function recache()
		cached = stockFolder:GetChildren()
	end
	stockFolder.ChildAdded:Connect(recache)
	stockFolder.ChildRemoved:Connect(recache)

	task.spawn(function()
		while task.wait(BuyInterval) do
			for _, item in ipairs(cached) do
				if item and typeof(item) == "Instance" and isSelected(category, item.Name) then
					BuyFiredCount += 1
					BuyLastFired = category .. " · " .. item.Name
					-- No logging here. This runs once per selected item
					-- per tick, and at a 0.001s interval with a full
					-- selection that was tens of thousands of console
					-- writes a second — a large source of the lag people
					-- blamed on rendering. The Buy tab's counter already
					-- shows the same information.
					pcall(function()
						remote:Fire(item.Name)
					end)
				end
			end
		end
	end)
end

--========================================================
-- HARVEST — finds your plot, harvests ripe fruit first, then
-- attempts still-growing ones too.
--========================================================
-- Finding your plot.
--
-- This previously did WaitForChild("Gardens") with no timeout and
-- stopped searching once it found a plot. Both broke on other worlds:
-- a world without a folder literally named "Gardens" made it yield
-- forever (killing harvest AND random-mode planting with no error),
-- and travelling to another world left it pointing at the old world's
-- plot because the search had already exited.
--
-- Now it scans any Workspace container for a plot attributed to you,
-- and keeps re-checking so world travel is picked up.
local OwnerPlot = nil

local function findOwnerPlot()
	local myName = Players.LocalPlayer.Name
	for _, container in ipairs(Workspace:GetChildren()) do
		if container:IsA("Folder") or container:IsA("Model") then
			local ok, children = pcall(function() return container:GetChildren() end)
			if ok then
				for _, plot in ipairs(children) do
					if plot:GetAttribute("Owner") == myName then
						return plot
					end
				end
			end
		end
	end
	return nil
end

task.spawn(function()
	while true do
		-- Re-resolve if we've never found one, or if the one we had has
		-- been unparented (which is what happens on world travel).
		if not OwnerPlot or not OwnerPlot.Parent then
			OwnerPlot = findOwnerPlot()
		end
		task.wait(OwnerPlot and 2 or 0.25)
	end
end)

local function isGrown(plant)
	local maxAge = plant:GetAttribute("MaxAge")
	local currentAge = plant:GetAttribute("Age")
	if maxAge == nil or currentAge == nil then return false end
	return currentAge >= maxAge
end

-- Crops you never want picked. Keyed by the shop seed name the Harvest
-- tab lists; plot plants carry world-prefixed names ("Maple Corn"), so
-- matching is loose in the same way planting's is.
local HarvestExcluded = {}
local HarvestSkipped = 0 -- plants left alone by the exclusion list

-- What a plant "is" isn't reliably its instance name: plots often name
-- children by id and keep the crop type in an attribute. Matching only
-- on .Name meant exclusions silently never fired, so every plausible
-- identifying field is checked.
local function plantNames(plant)
	-- SeedName is where this game keeps the crop ("Strawberry"), matching
	-- the shop names the exclusion list shows. Everything else is a
	-- fallback for other worlds.
	local names = {}
	local seedName = plant:GetAttribute("SeedName")
	if type(seedName) == "string" and seedName ~= "" then
		table.insert(names, seedName)
	end
	table.insert(names, plant.Name)
	local ok, attrs = pcall(function() return plant:GetAttributes() end)
	if ok and attrs then
		for key, value in pairs(attrs) do
			if type(value) == "string" and value ~= "" then
				local k = tostring(key):lower()
				-- PlantId is a guid and PlantType is the literal word
				-- "Plant"; neither identifies a crop.
				local useless = k == "plantid" or k == "planttype" or k == "userid"
				if not useless and (k:find("name") or k:find("type") or k:find("seed") or k:find("plant") or k:find("crop")) then
					table.insert(names, value)
				end
			end
		end
	end
	return names
end

local function isHarvestExcluded(plant)
	-- Accepts an Instance or a plain string, since fruits are checked
	-- by name too.
	local names = typeof(plant) == "Instance" and plantNames(plant) or { tostring(plant) }
	for seedName, on in pairs(HarvestExcluded) do
		if on then
			local wanted = seedName:lower()
			for _, candidate in ipairs(names) do
				local name = tostring(candidate):lower()
				if name == wanted or name:find(wanted, 1, true) then return true end
			end
		end
	end
	return false
end

local function getHarvestTargets()
	local targets = {}
	local plantsFolder = OwnerPlot and OwnerPlot:FindFirstChild("Plants")
	if not plantsFolder then return targets end

	for _, plant in pairs(plantsFolder:GetChildren()) do
		if isHarvestExcluded(plant) then
			HarvestSkipped += 1
			continue
		end
		local fruitsFolder = plant:FindFirstChild("Fruits")
		if fruitsFolder then
			for _, fruit in pairs(fruitsFolder:GetChildren()) do
				-- Fruits are checked as well: on some plots the crop
				-- type shows up on the fruit rather than its parent.
				if fruit:IsA("Model") and not isHarvestExcluded(fruit) then
					table.insert(targets, fruit)
				end
			end
		elseif plant:IsA("Model") then
			table.insert(targets, plant)
		end
	end

	return targets
end


local function harvestOne(target)
	local id = target:GetAttribute("PlantId")
	local fruitId = target:GetAttribute("FruitId") or ""
	if id then
		CollectFruit:Fire(id, fruitId)
	end
end

local HarvestEnabled = false
local HarvestInterval = 0.5

task.spawn(function()
	-- Ripe first, still-growing after — as two passes rather than a sort.
	-- table.sort calls the comparator O(n log n) times and each call read
	-- two attributes off both plants; on a large garden that alone was
	-- tens of thousands of property reads per scan.
	local function orderHarvestTargets(targets)
		local ripe, growing = {}, {}
		for _, target in ipairs(targets) do
			if isGrown(target) then
				table.insert(ripe, target)
			else
				table.insert(growing, target)
			end
		end
		for _, target in ipairs(growing) do
			table.insert(ripe, target)
		end
		return ripe
	end

	-- Two separate costs on a big garden, both fixed here.
	--
	-- Scanning: walking every plant and fruit is far too expensive to
	-- redo every tick, so a scan is reused for a second.
	--
	-- Firing: the loop used to send a harvest request for EVERY fruit on
	-- the plot on EVERY tick. With thousands of plants at a 0.001s delay
	-- that is millions of remote calls a minute — the script flooding
	-- itself. It now works through the list a slice at a time, picking
	-- up where it left off, so a huge garden costs the same per tick as
	-- a small one and simply takes more ticks to come round again.
	local BATCH = 40
	local cachedTargets, cachedAt, cursor = {}, 0, 1

	while task.wait(HarvestInterval) do
		if HarvestEnabled and OwnerPlot then
			if tick() - cachedAt > 1 then
				cachedTargets = orderHarvestTargets(getHarvestTargets())
				cachedAt = tick()
				cursor = 1
			end

			local count = #cachedTargets
			if count > 0 then
				for _ = 1, math.min(BATCH, count) do
					local target = cachedTargets[cursor]
					if target and target.Parent then
						harvestOne(target)
					end
					cursor += 1
					if cursor > count then cursor = 1 end
				end
			end
		end
	end
end)

--========================================================
-- PLANT — fires Networking.Plant.PlantSeed for each selected seed.
--
-- The remote's argument ORDER isn't discoverable from the module dump
-- (its Writes serializers are opaque), and guessing wrong would fail
-- silently. So instead of hardcoding a guess, the first plant attempt
-- tries position-first, and if that errors, seed-name-first — then
-- remembers whichever succeeded for the rest of the session. The
-- game's typed serializers reject mismatched argument types, which is
-- what makes this detectable rather than a coin flip.
--========================================================
local PlantEnabled = false
local PlantInterval = 0.5
local PlantSelected = {} -- seed name -> true

-- Declared up here, not down in the SHOVEL section, because the plant
-- loop has to know whether shovelling wants the tool.
local Shovel = {
	enabled = false,
	interval = 0.5,
	selected = {}, -- plant name -> true
	removed = 0,
	status = "idle",
	names = {}, -- what's actually growing, for the picker
	pending = 0, -- plants matching your picks, right now
}

local PlantArgOrder = nil -- nil = not yet determined, then "pos_first" / "name_first"
local PlantFiredCount = 0
local PlantLastFired = ""
local PlantLastTool = "none"

local function isPlantSelected(name)
	return PlantSelected[name] == true
end

local function countPlantSelected()
	local n = 0
	for _, on in pairs(PlantSelected) do
		if on then n += 1 end
	end
	return n
end

-- Ground truth for "did a plant actually happen": the game tells the
-- client via Garden.PlantAdded. Without this, the counter only ever
-- proved we *sent* something — a fired request and a successful plant
-- looked identical, which is exactly why "it does not plant" was
-- invisible in the UI.
local PlantConfirmedCount = 0
pcall(function()
	Networking.Garden.PlantAdded.OnClientEvent:Connect(function()
		PlantConfirmedCount += 1
	end)
end)

-- How many arguments the remote actually takes. The Networking module
-- carries one serializer per argument in .Writes, so its length is the
-- arity — a fact, not a guess. Worlds added later (Maple) turned out to
-- differ here, which is why probing only the ORDER of two arguments was
-- never going to be enough.
local PlantArity = nil
pcall(function()
	local writes = PlantSeed.Writes
	if type(writes) == "table" then PlantArity = #writes end
end)

-- Seeds are Tools in the Backpack, and the world prefixes them ("Maple
-- Corn", not "Corn"), so the shop name the UI selects by is not the name
-- the plant remote expects. Resolve to the real Tool, equip it — the
-- server reads the held tool — and fire using its actual name.
local function resolveSeedTool(seedName)
	local player = Players.LocalPlayer
	local character = player.Character
	local backpack = player:FindFirstChildOfClass("Backpack")
	local wanted = seedName:lower()

	local function match(container)
		if not container then return nil end
		for _, tool in ipairs(container:GetChildren()) do
			if tool:IsA("Tool") then
				local n = tool.Name:lower()
				-- Skip harvested produce ("Maple Tulip [1.00kg]"), which
				-- is a different item from the plantable seed.
				if not n:find("%[") and (n == wanted or n:find(wanted, 1, true)) then
					return tool
				end
			end
		end
		return nil
	end

	local tool = match(character) or match(backpack)
	if not tool or not character then return nil end

	-- The captured call passes the Tool as it lives under the CHARACTER
	-- (Workspace.<player>.<tool>), i.e. equipped. Equipping is not
	-- instant, and swapping straight from one seed to another often
	-- doesn't take while another Tool is still held — which is why only
	-- whichever seed happened to be in hand was planting. So: unequip,
	-- equip, then confirm the reparent actually happened.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil end

	local function equipped()
		return tool.Parent == character
	end

	local function waitForEquip(seconds)
		local deadline = tick() + seconds
		while tick() < deadline and not equipped() do
			task.wait(0.03)
		end
		return equipped()
	end

	if not equipped() then
		-- Deliberately no UnequipTools here. Unequipping first left the
		-- character empty-handed whenever the follow-up equip did not
		-- take, and nothing could be planted at all until you swapped by
		-- hand. EquipTool swaps on its own; a failed swap now leaves the
		-- previous seed in hand, which is still plantable.
		pcall(function() humanoid:EquipTool(tool) end)
		if not waitForEquip(0.35) then
			-- EquipTool is unreliable in this game (tools carry custom
			-- equip behaviour). Reparenting is what equipping actually
			-- is, and the client may do it to its own Backpack tools —
			-- but only when nothing else is held, since forcing a second
			-- Tool into the character is what the game rejects.
			if not character:FindFirstChildOfClass("Tool") then
				pcall(function() tool.Parent = character end)
				waitForEquip(0.35)
			end
		end
	end

	-- Return it either way: firing while holding it is far more likely to
	-- work than not firing at all, and a refusal here is indistinguishable
	-- from a broken remote in the UI.
	return tool
end

-- Every plausible shape, each labelled so the winner can be shown in the
-- UI. Built per-call because they close over the actual values.
local function plantCandidates(seedName, position, tool)
	local cf = CFrame.new(position)
	local plot = OwnerPlot
	return {
		-- The real shape, captured off the game's own call with a hook on
		-- PlantSeed.Fire: (Vector3, seed name, the equipped Tool).
		{ name = "pos_name_tool", args = { position, seedName, tool }, n = 3 },
		-- Everything below is fallback for other worlds.
		{ name = "name_pos_plot", args = { seedName, position, plot } },
		{ name = "plot_name_pos", args = { plot, seedName, position } },
		{ name = "name_pos_rot", args = { seedName, position, 0 } },
		{ name = "name_cf_plot", args = { seedName, cf, plot } },
		{ name = "tool_pos_plot", args = { tool, position, plot } },
		{ name = "tool_name_pos", args = { tool, seedName, position } },
		{ name = "plot_tool_pos", args = { plot, tool, position } },
		{ name = "plot_pos_name", args = { plot, position, seedName } },
		{ name = "pos_name_plot", args = { position, seedName, plot } },
		{ name = "pos_plot_name", args = { position, plot, seedName } },
		{ name = "name_pos_tool", args = { seedName, position, tool } },
		{ name = "cf_name_plot", args = { cf, seedName, plot } },
		{ name = "name_cf_rot", args = { seedName, cf, 0 } },
		-- Fallbacks for other worlds.
		{ name = "pos_first", args = { position, seedName } },
		{ name = "name_first", args = { seedName, position } },
		{ name = "name_cf", args = { seedName, cf } },
		{ name = "cf_first", args = { cf, seedName } },
		{ name = "pos_only", args = { position } },
		{ name = "name_only", args = { seedName } },
	}
end

-- Argument counts are declared explicitly: a nil in the list (no plot
-- resolved yet, no Tool found) would otherwise shorten it silently and
-- make a 3-arg shape look like a 2-arg one.
local function argCount(candidate)
	return candidate.n or #candidate.args
end

local function fireCandidate(candidate)
	local n = argCount(candidate)
	return pcall(function() PlantSeed:Fire(table.unpack(candidate.args, 1, n)) end)
end

local function firePlant(seedName, position)
	local tool = resolveSeedTool(seedName)
	local character = Players.LocalPlayer.Character
	PlantLastTool = tool
		and (tool.Name .. (tool.Parent == character and " (held)" or " (NOT held)"))
		or "none"
	-- No equipped Tool means there's nothing to plant with — firing
	-- anyway would just spam the remote with a seed we don't hold.
	if not tool then return false end

	-- Use the Tool's real in-world name: the shop name and the item name
	-- differ in prefixed worlds like Maple.
	local candidates = plantCandidates(tool.Name, position, tool)

	if PlantArgOrder then
		for _, candidate in ipairs(candidates) do
			if candidate.name == PlantArgOrder then return fireCandidate(candidate) end
		end
	end

	-- Shape still unknown. pcall success alone is NOT proof it was right
	-- — the remote may accept mismatched arguments happily and simply do
	-- nothing server-side, which would lock in a silently broken shape
	-- forever. So each candidate is confirmed against PlantAdded before
	-- being committed to. When the arity is known, candidates that don't
	-- match it are skipped outright.
	for _, candidate in ipairs(candidates) do
		if not PlantArity or argCount(candidate) == PlantArity then
			local before = PlantConfirmedCount
			if fireCandidate(candidate) then
				local deadline = tick() + 0.6
				while tick() < deadline do
					if PlantConfirmedCount > before then
						PlantArgOrder = candidate.name
						return true
					end
					task.wait(0.05)
				end
			end
		end
	end
	return false
end

--------------------------------------------------------
-- Where to plant. Three modes:
--   "me"     — at your character, so it fills in as you walk
--   "random" — scattered randomly across your plot
--   "fixed"  — one pinned spot you set yourself
--------------------------------------------------------
local PlantMode = "me"
local PlantFixedPosition = nil

-- The plot's ground is taken to be its largest part by footprint,
-- which is what the farmland slab reliably is. Planting happens on
-- that part's top surface rather than at its centre, so seeds land on
-- the ground instead of inside it.
-- Cached, because this walks every descendant of the plot and random
-- planting asks for it on every tick. On a large garden that is tens of
-- thousands of instances per tick, for a slab that never changes.
-- The cache lives in a closure rather than a new local: the main chunk
-- is at Lua's 200-locals ceiling, so this adds none.
local getPlotGround
do
	local PlotGroundCache = { part = nil, plot = nil }

	function getPlotGround()
		if not OwnerPlot then return nil end
		if PlotGroundCache.part and PlotGroundCache.part.Parent and PlotGroundCache.plot == OwnerPlot then
			return PlotGroundCache.part
		end

		local best, bestArea = nil, 0
		for _, part in ipairs(OwnerPlot:GetDescendants()) do
			if part:IsA("BasePart") then
				local area = part.Size.X * part.Size.Z
				if area > bestArea then
					best, bestArea = part, area
				end
			end
		end

		PlotGroundCache.part, PlotGroundCache.plot = best, OwnerPlot
		return best
	end
end

local function randomPlotPosition()
	local ground = getPlotGround()
	if not ground then return nil end
	-- Inset from the edges so seeds don't land half off the plot.
	local offsetX = (math.random() * 2 - 1) * (ground.Size.X / 2) * 0.85
	local offsetZ = (math.random() * 2 - 1) * (ground.Size.Z / 2) * 0.85
	-- Go through the part's own CFrame so a rotated plot still works.
	local spot = ground.CFrame * CFrame.new(offsetX, 0, offsetZ)
	local topY = ground.Position.Y + (ground.Size.Y / 2)
	return Vector3.new(spot.Position.X, topY, spot.Position.Z)
end

local function getPlantPosition()
	if PlantMode == "fixed" then
		return PlantFixedPosition
	elseif PlantMode == "random" then
		return randomPlotPosition()
	end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then return root.Position end
	return nil
end

-- Is the Tool currently in your hands one of the seeds you selected?
-- Selection is by shop name ("Carrot"); the held Tool carries the
-- world-prefixed name ("Maple Carrot"), so match loosely, and ignore
-- harvested produce, whose name carries a [1.00kg] weight.
local function heldSelectedSeed()
	local character = Players.LocalPlayer.Character
	if not character then return nil end
	for _, tool in ipairs(character:GetChildren()) do
		if tool:IsA("Tool") and not tool.Name:find("%[") then
			local held = tool.Name:lower()
			for seedName, on in pairs(PlantSelected) do
				if on then
					local wanted = seedName:lower()
					if held == wanted or held:find(wanted, 1, true) then
						return tool
					end
				end
			end
		end
	end
	return nil
end

-- Selected seeds in a stable order, so rotation goes round the list
-- instead of jumping about (pairs order is arbitrary).
local function selectedSeedNames()
	local names = {}
	for seedName, on in pairs(PlantSelected) do
		if on then table.insert(names, seedName) end
	end
	table.sort(names)
	return names
end

-- Equips the seed after the one currently held, wrapping around. The
-- earlier failures came from equipping and firing in the same breath;
-- the swap does take, it just isn't ready that instant. So this only
-- ever equips, and the plant happens on a later tick once the Tool has
-- actually arrived in your hands.
local PlantRotateIndex = 0

-- Returns false when none of the selected seeds exist in your
-- inventory, which is how the caller knows to stop rotating rather than
-- churning through tool swaps that can never plant anything.
local function equipNextSelectedSeed()
	local names = selectedSeedNames()
	if #names == 0 then return false end
	for _ = 1, #names do
		PlantRotateIndex = (PlantRotateIndex % #names) + 1
		if resolveSeedTool(names[PlantRotateIndex]) then return true end
	end
	return false
end

-- How long to keep planting one seed before moving to the next. Short
-- enough that every selected seed gets planted, long enough that the
-- equip has time to land.
local PlantSwitchAfter = 1.5
local PlantCurrentSince = 0
local PlantCurrentName = nil

task.spawn(function()
	while task.wait(PlantInterval) do
		-- Both features fight over the equipped tool: planting equips a
		-- seed, shovelling equips the Shovel, and each undoes the other.
		-- Shovelling yields nothing useful without its tool, and it has
		-- a finite amount of work, so it wins while it has plants to
		-- dig. Planting also has no business swapping tools when none of
		-- the selected seeds are actually in your inventory.
		if PlantEnabled and not (Shovel.enabled and Shovel.pending > 0) then
			local names = selectedSeedNames()
			-- Plant whatever selected seed is actually in your hands.
			-- Only a settled equip makes the server accept a plant.
			local tool = heldSelectedSeed()
			if tool then
				if tool.Name ~= PlantCurrentName then
					PlantCurrentName = tool.Name
					PlantCurrentSince = tick()
				end

				local position = getPlantPosition()
				if position then
					if firePlant(tool.Name, position) then
						PlantFiredCount += 1
						PlantLastFired = tool.Name
					end
				end

				-- Rotate to the next selected seed so the whole selection
				-- gets planted without you switching by hand. If the swap
				-- doesn't land, the seed already in hand stays held and
				-- planting simply continues — rotation must never be able
				-- to leave you holding nothing.
				if #names > 1 and tick() - PlantCurrentSince >= PlantSwitchAfter then
					PlantCurrentSince = tick()
					equipNextSelectedSeed()
					if not heldSelectedSeed() then
						resolveSeedTool(tool.Name)
					end
				end
			elseif not equipNextSelectedSeed() then
				-- Out of seeds entirely. Swapping tools now would only
				-- take the Shovel out of your hands for nothing, so sit
				-- out until some are bought.
				PlantCurrentName = nil
				task.wait(1)
			end
		end
	end
end)

--========================================================
-- SHOVEL — digs up plants you pick from your own garden.
--
-- The removal remote isn't named in anything dumped from this game, so
-- rather than guess one name and fail silently — the trap that cost
-- several rounds on planting — the module is searched for remotes whose
-- path reads like a removal, and the first one the game confirms (by a
-- plant actually disappearing) is the one kept.
--
-- Everything lives on one table: the main chunk is at Lua's 200-locals
-- ceiling.
--========================================================

do
	-- This game stores the crop on the plant as SeedName ("Strawberry"),
	-- while the instance is named "<userid>_<guid>". Read the attribute;
	-- everything below it is a fallback for other worlds.
	local function identity(plant)
		local names = {}
		local seedName = plant:GetAttribute("SeedName")
		if type(seedName) == "string" and seedName ~= "" then
			table.insert(names, seedName)
		end
		table.insert(names, plant.Name)

		local ok, attrs = pcall(function() return plant:GetAttributes() end)
		if ok and attrs then
			for key, value in pairs(attrs) do
				if type(value) == "string" and value ~= "" then
					local k = tostring(key):lower()
					-- PlantId is a guid, PlantType is the literal word
					-- "Plant" — labelling a row "Plant" is no better
					-- than labelling it with the id.
					local useless = k == "plantid" or k == "planttype" or k == "userid" or k == "seedname"
					if not useless and (k:find("name") or k:find("type") or k:find("seed") or k:find("crop")) then
						table.insert(names, value)
					end
				end
			end
		end
		return names
	end

	-- "11297928402_f9875aaa-aebb-..." is an id, not a crop.
	local function looksLikeId(text)
		if text:find("%-") and text:len() >= 16 then return true end
		if text:find(" ") then return false end
		return text:len() >= 12 and text:find("%d") ~= nil and text:find("%a") ~= nil
	end

	local function labelFor(plant)
		for _, candidate in ipairs(identity(plant)) do
			if not looksLikeId(candidate) then return candidate end
		end
		return plant.Name
	end

	local function isSelectedPlant(plant)
		-- Fast path first: with ~900 plants scanned every tick, reading
		-- one attribute beats building a candidate list per plant.
		local seedName = plant:GetAttribute("SeedName")
		if type(seedName) == "string" and Shovel.selected[seedName] then
			return true
		end

		for wanted, on in pairs(Shovel.selected) do
			if on then
				local target = wanted:lower()
				local candidates = identity(plant)
				table.insert(candidates, labelFor(plant))
				for _, candidate in ipairs(candidates) do
					local name = tostring(candidate):lower()
					if name == target or name:find(target, 1, true) then return true end
				end
			end
		end
		return false
	end

	-- Captured off the game's own call with a hook on every remote:
	--   Shovel.UseShovel(<plant instance name>, "", "Shovel", <Tool>)
	-- The first argument is the plant's full instance name
	-- ("<userid>_<guid>"), not its PlantId attribute.
	local UseShovel = nil
	pcall(function() UseShovel = Networking.Shovel.UseShovel end)

	-- Ground truth for a removal, so the counter reflects plants that
	-- actually went away rather than requests sent.
	pcall(function()
		Networking.Garden.PlantRemoved.OnClientEvent:Connect(function()
			Shovel.removed += 1
		end)
	end)

	-- The server acts on what you're holding, same as seeds.
	local function equipShovel()
		local player = Players.LocalPlayer
		local character = player.Character
		if not character then return nil end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then return nil end

		local function find(container)
			if not container then return nil end
			for _, tool in ipairs(container:GetChildren()) do
				if tool:IsA("Tool") and tool.Name:lower():find("shovel") then return tool end
			end
			return nil
		end

		local tool = find(character) or find(player:FindFirstChildOfClass("Backpack"))
		if not tool then return nil end
		if tool.Parent ~= character then
			pcall(function() humanoid:EquipTool(tool) end)
			local deadline = tick() + 0.4
			while tick() < deadline and tool.Parent ~= character do
				task.wait(0.03)
			end
		end
		return tool
	end

	local function digUp(plant)
		if not UseShovel then
			Shovel.status = "this world has no Shovel.UseShovel remote"
			return false
		end

		local tool = equipShovel()
		if not tool then
			Shovel.status = "no Shovel in your inventory"
			return false
		end

		local ok = pcall(function()
			UseShovel:Fire(plant.Name, "", "Shovel", tool)
		end)
		if ok then
			Shovel.status = "digging"
		else
			Shovel.status = "UseShovel rejected the call"
		end
		return ok
	end

	-- What's growing right now, for the picker. Refreshed on a slow
	-- loop rather than per tick: on a large garden this walks every
	-- plant.
	task.spawn(function()
		while true do
			local plantsFolder = OwnerPlot and OwnerPlot:FindFirstChild("Plants")
			if plantsFolder then
				local seen, names = {}, {}
				for _, plant in ipairs(plantsFolder:GetChildren()) do
					local label = labelFor(plant)
					if label and not seen[label] then
						seen[label] = true
						table.insert(names, label)
					end
				end
				table.sort(names)
				Shovel.names = names
			end
			task.wait(3)
		end
	end)

	task.spawn(function()
		while task.wait(Shovel.interval) do
			if not Shovel.enabled then
				Shovel.pending = 0
				-- Say so plainly. "idle" left it ambiguous whether the
				-- feature was off, finding nothing, or broken.
				Shovel.status = "off — turn on Auto Shovel"
			else
				local plantsFolder = OwnerPlot and OwnerPlot:FindFirstChild("Plants")
				if not plantsFolder then
					Shovel.pending = 0
					Shovel.status = "locating your plot…"
				else
					local target, matching, total = nil, 0, 0
					for _, plant in ipairs(plantsFolder:GetChildren()) do
						total += 1
						if isSelectedPlant(plant) then
							matching += 1
							target = target or plant
						end
					end

					Shovel.pending = matching
					if target then
						digUp(target)
						if Shovel.status == "digging" then
							Shovel.status = string.format("digging · %d of %d match", matching, total)
						end
					else
						Shovel.status = string.format("none of %d plants match your picks", total)
					end
				end
			end
		end
	end)
end

--========================================================
-- DROPS — teleports to dropped items the moment they appear.
--
-- The Networking dump has DroppedItem.PickupFx and RequestDrop but no
-- "pick this up" remote, so collection is proximity-based: you hold E
-- on a ProximityPrompt. That means teleporting to it and triggering
-- the prompt, not firing a remote.
--
-- Detection watches for ProximityPrompts specifically, rather than any
-- new Model/BasePart. That's both more precise and much safer: an
-- earlier version matched every instance streamed into Workspace,
-- which with "collect everything" on would have teleported you to
-- essentially every part that loaded. Requiring a prompt means we only
-- ever target things that are genuinely pick-up-able, and it needs no
-- guesswork about which folder drops live in.
--========================================================

local CollectEnabled = false
local CollectEverything = true
local CollectSelected = {} -- item name -> true
local CollectReturn = true -- go back to where you were afterwards
local CollectDwell = 0.01 -- seconds to linger before triggering
local CollectedCount = 0
local CollectLast = ""
local CollectPending = {}

local function isCollectSelected(name)
	return CollectSelected[name] == true
end

local function countCollectSelected()
	local n = 0
	for _, on in pairs(CollectSelected) do
		if on then n += 1 end
	end
	return n
end

-- Exact (case-insensitive) name match. Gold / Rainbow / Mega are their
-- own distinct seeds here, not mutation prefixes on other seeds, so
-- substring matching would wrongly rope in unrelated items.
local function matchesCollectFilter(name)
	if CollectEverything then return true end
	local lower = tostring(name):lower()
	for selected, on in pairs(CollectSelected) do
		if on and tostring(selected):lower() == lower then
			return true
		end
	end
	return false
end

-- Drop helpers live on one table: the main chunk is at Lua's
-- 200-locals ceiling, and these would otherwise cost two.
local Drop = {}

function Drop.getRoot()
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- Anything growing on a plot is not a drop. Plants and their fruit carry
-- their own prompts (harvesting is a prompt too), so without this the
-- collector treats a whole garden as loot and teleports around
-- harvesting things you never asked it to touch.
function Drop.isGarden(prompt)
	local node = prompt.Parent
	local depth = 0
	while node and node ~= Workspace and depth < 8 do
		if node:GetAttribute("PlantId") ~= nil or node:GetAttribute("Owner") ~= nil then
			return true
		end
		local name = node.Name
		if name == "Plants" or name == "Gardens" or name == "Fruits" then
			return true
		end
		node = node.Parent
		depth += 1
	end
	return false
end

-- Pets and crates that spawn around the map are for sale, not loot:
-- walking up and triggering their prompt spends your Sheckles. Only
-- what a player dropped should be collected.
--
-- Purchasable things announce themselves — a Buy/Purchase prompt, or a
-- price on the object — so they're rejected outright. Dropped things
-- carry a drop marker, and are always accepted.
function Drop.isPurchase(prompt)
	local text = ((prompt.ActionText or "") .. " " .. (prompt.ObjectText or "")):lower()
	if text:find("buy") or text:find("purchase") or text:find("cost") or text:find("price") then
		return true
	end
	if text:find("%$") or text:find("¢") then return true end

	local node = prompt.Parent
	local depth = 0
	while node and node ~= Workspace and depth < 4 do
		if node:GetAttribute("Price") ~= nil or node:GetAttribute("Cost") ~= nil then
			return true
		end
		node = node.Parent
		depth += 1
	end
	return false
end

function Drop.isDropped(prompt)
	local node = prompt.Parent
	local depth = 0
	while node and node ~= Workspace and depth < 6 do
		if
			node:GetAttribute("DroppedBy") ~= nil
			or node:GetAttribute("DropId") ~= nil
			or node:GetAttribute("Dropped") ~= nil
		then
			return true
		end
		if node.Name:lower():find("drop") then return true end
		node = node.Parent
		depth += 1
	end
	return false
end

-- NPCs are triggered the same way loot is: a prompt. Walking up to a
-- shopkeeper and firing it opens menus, sells your crops, or starts
-- quests — none of which you asked for.
function Drop.isNpc(prompt)
	local text = ((prompt.ActionText or "") .. " " .. (prompt.ObjectText or "")):lower()
	if
		text:find("talk")
		or text:find("shop")
		or text:find("sell")
		or text:find("trade")
		or text:find("quest")
		or text:find("open")
	then
		return true
	end

	local node = prompt.Parent
	local depth = 0
	while node and node ~= Workspace and depth < 5 do
		-- A Humanoid is the giveaway: loot doesn't have one.
		if node:IsA("Model") and node:FindFirstChildOfClass("Humanoid") then
			return true
		end
		local name = node.Name:lower()
		if name:find("npc") or name:find("vendor") or name:find("merchant") or name:find("shop") then
			return true
		end
		node = node.Parent
		depth += 1
	end
	return false
end

-- One gate for every rule, so the live watcher and the sweep of things
-- already lying around can never disagree about what counts as loot.
function Drop.isCollectable(prompt)
	if Drop.isGarden(prompt) then return false end
	if Drop.isNpc(prompt) then return false end
	-- A drop marker outranks the price test: a pet a player dropped is
	-- loot even if its prompt still mentions a price.
	if not Drop.isDropped(prompt) and Drop.isPurchase(prompt) then return false end
	return true
end

-- What to call a prompt's item, for filtering and for the status line.
local function promptName(prompt)
	if prompt.ObjectText and prompt.ObjectText ~= "" then
		return prompt.ObjectText
	end
	local parent = prompt.Parent
	return parent and parent.Name or "?"
end

local function promptPosition(prompt)
	local node = prompt.Parent
	local depth = 0
	while node and depth < 4 do
		if node:IsA("BasePart") then return node.Position end
		if node:IsA("Model") then
			local part = node.PrimaryPart or node:FindFirstChildWhichIsA("BasePart")
			if part then return part.Position end
		end
		node = node.Parent
		depth += 1
	end
	return nil
end

-- Zeroing HoldDuration is what makes "hold E" instant. InputHoldBegin/
-- InputHoldEnd are ordinary LocalScript APIs, so this works even on
-- executors without fireproximityprompt — that's only the fallback.
local function triggerPrompt(prompt)
	pcall(function()
		prompt.HoldDuration = 0
		prompt.Enabled = true
		prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, 50)
	end)
	local ok = pcall(function()
		prompt:InputHoldBegin()
		task.wait()
		prompt:InputHoldEnd()
	end)
	if not ok and fireproximityprompt then
		pcall(fireproximityprompt, prompt)
	end
end

local function collectDrop(prompt)
	if not prompt or not prompt.Parent then return false end
	local root = Drop.getRoot()
	if not root then return false end
	local position = promptPosition(prompt)
	if not position then return false end

	local origin = root.CFrame
	root.CFrame = CFrame.new(position + Vector3.new(0, 3, 0))
	task.wait(CollectDwell)
	triggerPrompt(prompt)

	if CollectReturn then
		local rootNow = Drop.getRoot()
		if rootNow then rootNow.CFrame = origin end
	end
	return true
end

Workspace.DescendantAdded:Connect(function(inst)
	-- Cheapest possible early-out: this fires constantly as parts
	-- stream in, and the class check rejects almost everything.
	if not CollectEnabled then return end
	if not inst:IsA("ProximityPrompt") then return end
	if not Drop.isCollectable(inst) then return end
	if not matchesCollectFilter(promptName(inst)) then return end
	table.insert(CollectPending, inst)
end)

-- Everything already lying on the ground when you switch Auto Collect
-- on. Without this the collector only ever sees drops that appear
-- afterwards, so anything dropped before you enabled it sits there
-- forever.
--
-- Walked in slices: Workspace on a big farm is tens of thousands of
-- instances, and doing it in one go would stall the frame.
function Drop.sweep()
	local found = 0
	local scanned = 0
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if not CollectEnabled then return found end
		if inst:IsA("ProximityPrompt") then
			local ok, collectable = pcall(Drop.isCollectable, inst)
			if ok and collectable then
				local okName, name = pcall(promptName, inst)
				if okName and matchesCollectFilter(name) then
					table.insert(CollectPending, inst)
					found += 1
				end
			end
		end
		scanned += 1
		if scanned % 2000 == 0 then task.wait() end
	end
	return found
end

task.spawn(function()
	local wasEnabled = false
	while task.wait(0.05) do
		-- Rising edge only: sweeping on every tick would re-queue the
		-- whole map continuously.
		if CollectEnabled and not wasEnabled then
			wasEnabled = true
			task.spawn(Drop.sweep)
		elseif not CollectEnabled then
			wasEnabled = false
		end

		if CollectEnabled and #CollectPending > 0 then
			local target = table.remove(CollectPending, 1)
			-- Re-checked here as well: a prompt can be queued before its
			-- plant finishes parenting into the plot.
			if target and target.Parent and not Drop.isCollectable(target) then
				target = nil
			end
			local name = "?"
			pcall(function() name = promptName(target) end)
			local ok, collected = pcall(collectDrop, target)
			if ok and collected then
				CollectedCount += 1
				CollectLast = name
			end
		elseif #CollectPending > 0 then
			-- Disabled mid-queue; don't teleport to stale targets later.
			CollectPending = {}
		end
	end
end)

--========================================================
-- SELL — fires the game's own "sell everything" remote on a delay.
--========================================================
local SellEnabled = false
local SellInterval = 0.5

task.spawn(function()
	while task.wait(SellInterval) do
		if SellEnabled then
			SellAll:Fire()
		end
	end
end)

--========================================================
-- STATS — polls the exact Sheckles balance once a second and
-- accumulates every increase as earned and every decrease as spent,
-- so selling shows up as cumulative income. (State is declared
-- earlier, alongside the balance search that sets it up.)
--========================================================

local function formatElapsed(seconds)
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	local s = math.floor(seconds % 60)
	return string.format("%02d:%02d:%02d", h, m, s)
end

local function formatNumber(n)
	n = math.floor(n + 0.5)
	local sign = n < 0 and "-" or ""
	local digits = tostring(math.abs(n))
	local result = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return sign .. result
end

--========================================================
-- UI — solid dark panel, top-level tabs (Buy / Harvest / Sell / Stats)
--========================================================
local gui = Instance.new("ScreenGui")
gui.Name = "ScriptexerAutoBuyUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local PAGE_HEIGHTS = { Buy = 520, Plant = 506, Drops = 502, Harvest = 506, Sell = 90, Stats = 268, Shovel = 506 }
local TOP_OFFSET = 74 -- title + top tab bar

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(1, 0)
frame.Position = UDim2.new(1, -18, 0, 18)
frame.Size = UDim2.new(0, 420, 0, TOP_OFFSET + PAGE_HEIGHTS.Buy + 8)
frame.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
frame.BackgroundTransparency = 0.04
frame.BorderSizePixel = 0
frame.ClipsDescendants = true
-- Hidden until the splash has finished; the panel appearing half-built
-- while stock and the plot are still resolving is what made loading
-- look broken.
frame.Visible = false
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 16)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Transparency = 0.88
stroke.Thickness = 1
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
title.Active = true
title.Parent = frame

-- A hairline of colour along the top edge. Small thing, but it gives the
-- panel a top and stops the title floating on a flat black rectangle.
do
	local accent = Instance.new("Frame")
	accent.BackgroundColor3 = Color3.fromRGB(120, 255, 170)
	accent.BorderSizePixel = 0
	accent.Position = UDim2.new(0, 0, 0, 0)
	accent.Size = UDim2.new(1, 0, 0, 2)
	accent.ZIndex = 2
	accent.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 255, 170)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 210, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 255, 170)),
	})
	gradient.Parent = accent
end

-- Drag support
do
	local dragging, dragStart, startPos = false, nil, nil
	frame.Active = true
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

--========================================================
-- Shared UI helpers
--========================================================
local function pillButton(parent, text, width)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0, width, 1, 0)
	btn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	btn.BackgroundTransparency = 0.9
	btn.AutoButtonColor = false
	btn.Font = Enum.Font.GothamBold
	btn.Text = text
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextSize = 12
	btn.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = btn
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(255, 255, 255)
	s.Transparency = 0.8
	s.Parent = btn
	btn.MouseEnter:Connect(function() btn.BackgroundTransparency = 0.75 end)
	btn.MouseLeave:Connect(function() btn.BackgroundTransparency = 0.9 end)
	return btn
end

-- A draggable slider row: label + track + fill + knob. Calls onChange(value)
-- live while dragging, and once on creation with the default value.
-- Setters for the widgets the site can drive, keyed by the same names
-- the remote config uses. Populated at each widget's call site.
local RemoteWidgets = {}

-- Readers the remote-control status block calls for values that are
-- created further down the file than it is.
local RemoteReaders = { fps = nil, lowPower = nil }

-- Repaint hooks for the list-based tabs, which have no single widget to
-- set: applying a selection remotely has to redraw whole rows.
local RemoteRepaint = {}

-- A selection set ({name = true}) as a sorted array, which is what
-- travels over the wire and what the site draws from.
local function RemoteSelectedList(set)
	local names = {}
	for name, on in pairs(set or {}) do
		if on then table.insert(names, name) end
	end
	table.sort(names)
	return names
end

-- The live shop catalogue: every item the panel can list, with whether
-- it is in stock right now. Read fresh each time so the site shows the
-- same stock state the game does.
local function RemoteCatalogue()
	local out = {}
	for _, entry in ipairs({
		{ key = "Seeds", stock = SeedsStock },
		{ key = "Gears", stock = GearsStock },
		{ key = "Crates", stock = CratesStock },
	}) do
		local list = {}
		for _, item in ipairs(entry.stock:GetChildren()) do
			table.insert(list, {
				name = item.Name,
				inStock = (item.Value or 0) > 0,
			})
		end
		table.sort(list, function(a, b) return a.name < b.name end)
		out[entry.key] = list
	end
	return out
end

local function createSlider(parent, y, labelText, min, max, default, unit, onChange)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Position = UDim2.new(0, 16, 0, y)
	row.Size = UDim2.new(1, -32, 0, 40)
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -56, 0, 16)
	label.Font = Enum.Font.Gotham
	label.TextColor3 = Color3.fromRGB(200, 200, 205)
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	-- Type an exact value directly instead of dragging.
	local valueBox = Instance.new("TextBox")
	valueBox.Position = UDim2.new(1, -50, 0, -1)
	valueBox.Size = UDim2.new(0, 50, 0, 18)
	valueBox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	valueBox.BackgroundTransparency = 0.9
	valueBox.Font = Enum.Font.GothamBold
	valueBox.TextColor3 = Color3.fromRGB(255, 255, 255)
	valueBox.TextSize = 11
	valueBox.ClearTextOnFocus = false
	valueBox.Parent = row

	local valueBoxCorner = Instance.new("UICorner")
	valueBoxCorner.CornerRadius = UDim.new(0, 6)
	valueBoxCorner.Parent = valueBox

	-- Invisible, larger hit-zone around the thin visual track — 6px is
	-- fine for a mouse cursor but far too thin to reliably grab and
	-- drag with a finger on a touchscreen.
	local hitZone = Instance.new("Frame")
	hitZone.Active = true
	hitZone.BackgroundTransparency = 1
	hitZone.Position = UDim2.new(0, 0, 0, 16)
	hitZone.Size = UDim2.new(1, 0, 0, 24)
	hitZone.Parent = row

	local track = Instance.new("Frame")
	track.Position = UDim2.new(0, 0, 0.5, -3)
	track.Size = UDim2.new(1, 0, 0, 6)
	track.BackgroundColor3 = Color3.fromRGB(50, 50, 54)
	track.BorderSizePixel = 0
	track.Parent = hitZone

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = Color3.fromRGB(120, 255, 170)
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.new(0, 14, 0, 14)
	knob.Position = UDim2.new(0, 0, 0.5, 0)
	knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	knob.BorderSizePixel = 0
	knob.ZIndex = 2
	knob.Parent = track

	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob

	local currentValue = default
	local editingBox = false

	local function setFromAlpha(alpha)
		alpha = math.clamp(alpha, 0, 1)
		currentValue = min + (max - min) * alpha
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		label.Text = string.format("%s (%s):", labelText, unit)
		if not editingBox then
			valueBox.Text = string.format("%.3f", currentValue)
		end
		onChange(currentValue)
	end

	local dragging = false
	local function alphaFromX(x)
		return (x - hitZone.AbsolutePosition.X) / hitZone.AbsoluteSize.X
	end

	hitZone.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromAlpha(alphaFromX(input.Position.X))
		end
	end)
	hitZone.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	-- Two independent paths for drag continuation: InputChanged covers
	-- mouse movement, TouchMoved is Roblox's dedicated touch-drag event
	-- and is the more reliable of the two specifically for fingers.
	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			setFromAlpha(alphaFromX(input.Position.X))
		end
	end)
	UserInputService.TouchMoved:Connect(function(touch)
		if dragging then
			setFromAlpha(alphaFromX(touch.Position.X))
		end
	end)

	valueBox.Focused:Connect(function()
		editingBox = true
	end)
	valueBox.FocusLost:Connect(function()
		editingBox = false
		local num = tonumber(valueBox.Text)
		if num then
			setFromAlpha((math.clamp(num, min, max) - min) / (max - min))
		else
			valueBox.Text = string.format("%.3f", currentValue)
		end
	end)

	setFromAlpha((default - min) / (max - min))

	-- Second return is a setter, so something other than the user's
	-- finger — the site, over remote control — can move the slider and
	-- have it look moved.
	return row, function(value)
		setFromAlpha((math.clamp(value, min, max) - min) / (max - min))
	end
end

-- A labeled on/off switch row.
local function createToggleRow(parent, y, labelText, default, onChange)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Position = UDim2.new(0, 16, 0, y)
	row.Size = UDim2.new(1, -32, 0, 28)
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -46, 1, 0)
	label.Font = Enum.Font.Gotham
	label.Text = labelText
	label.TextColor3 = Color3.fromRGB(230, 230, 235)
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local toggle = Instance.new("TextButton")
	toggle.Position = UDim2.new(1, -34, 0.5, -9)
	toggle.Size = UDim2.new(0, 26, 0, 18)
	toggle.AutoButtonColor = false
	toggle.Text = ""
	toggle.Parent = row

	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(1, 0)
	toggleCorner.Parent = toggle

	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 14, 0, 14)
	knob.Position = UDim2.new(0, 2, 0.5, -7)
	knob.Parent = toggle

	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob

	local state = default
	local function paint()
		toggle.BackgroundColor3 = state and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(60, 60, 64)
		knob.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
		knob.Position = state and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
	end
	paint()

	toggle.MouseButton1Click:Connect(function()
		state = not state
		paint()
		onChange(state)
	end)

	-- Second return lets remote control flip the switch for real: the
	-- knob slides over, not just the underlying value.
	return row, function(value)
		if state == value then return end
		state = value
		paint()
		onChange(state)
	end
end

-- A "label ... value" stat row. Returns the value label so callers can
-- update its text later.
local function createStatRow(parent, y, labelText)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Position = UDim2.new(0, 16, 0, y)
	row.Size = UDim2.new(1, -32, 0, 20)
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(0.5, 0, 1, 0)
	label.Font = Enum.Font.Gotham
	label.Text = labelText
	label.TextColor3 = Color3.fromRGB(190, 190, 195)
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.Size = UDim2.new(0.5, 0, 1, 0)
	value.Font = Enum.Font.GothamBold
	value.Text = "—"
	value.TextColor3 = Color3.fromRGB(255, 255, 255)
	value.TextSize = 12
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = row

	return value
end

--========================================================
-- Top-level tabs + page containers
--========================================================
local topTabBar = Instance.new("Frame")
topTabBar.BackgroundTransparency = 1
topTabBar.Position = UDim2.new(0, 16, 0, 38)
topTabBar.Size = UDim2.new(1, -32, 0, 26)
topTabBar.Parent = frame

local topTabLayout = Instance.new("UIListLayout")
topTabLayout.FillDirection = Enum.FillDirection.Horizontal
topTabLayout.Padding = UDim.new(0, 4)
topTabLayout.Parent = topTabBar

local pageOrder = { "Buy", "Plant", "Shovel", "Drops", "Harvest", "Sell", "Stats" }
do
	local divider = Instance.new("Frame")
	divider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	divider.BackgroundTransparency = 0.92
	divider.BorderSizePixel = 0
	divider.Position = UDim2.new(0, 16, 0, 68)
	divider.Size = UDim2.new(1, -32, 0, 1)
	divider.Parent = frame
end

local pages = {}
local topTabButtons = {}
local activePage = "Buy"

local function paintTopTabs()
	for key, btn in pairs(topTabButtons) do
		local on = key == activePage
		-- The active tab is filled in the accent colour with dark text,
		-- rather than a slightly-less-transparent version of the others.
		-- Two shades of grey is not a state you can read at a glance.
		btn.BackgroundColor3 = on and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(255, 255, 255)
		btn.BackgroundTransparency = on and 0.08 or 0.94
		btn.TextColor3 = on and Color3.fromRGB(16, 20, 18) or Color3.fromRGB(185, 185, 190)
	end
end

local function setActivePage(name)
	activePage = name
	for key, page in pairs(pages) do
		page.Visible = key == name
	end
	frame.Size = UDim2.new(0, 420, 0, TOP_OFFSET + PAGE_HEIGHTS[name] + 8)
	paintTopTabs()
end

for _, key in ipairs(pageOrder) do
	-- 7 tabs across a 388px inner width with 4px gaps.
	local btn = pillButton(topTabBar, key, 51)
	btn.TextSize = 10
	topTabButtons[key] = btn
	btn.MouseButton1Click:Connect(function()
		setActivePage(key)
	end)

	local page = Instance.new("Frame")
	page.Name = key .. "Page"
	page.BackgroundTransparency = 1
	page.Position = UDim2.new(0, 0, 0, TOP_OFFSET)
	page.Size = UDim2.new(1, 0, 0, PAGE_HEIGHTS[key])
	page.Visible = key == "Buy"
	page.Parent = frame
	pages[key] = page
end

--========================================================
-- BUY page — sub-tabs (All/Seeds/Gears/Crates), interval slider,
-- scrollable item list, per-category quick-select, select all/none
--========================================================
local buyPage = pages.Buy

local subTabBar = Instance.new("Frame")
subTabBar.BackgroundTransparency = 1
subTabBar.Position = UDim2.new(0, 16, 0, 0)
subTabBar.Size = UDim2.new(1, -32, 0, 28)
subTabBar.Parent = buyPage

local subTabLayout = Instance.new("UIListLayout")
subTabLayout.FillDirection = Enum.FillDirection.Horizontal
subTabLayout.Padding = UDim.new(0, 6)
subTabLayout.Parent = subTabBar

local categories = {
	{ key = "Seeds", stock = SeedsStock, remote = PurchaseSeeds },
	{ key = "Gears", stock = GearsStock, remote = PurchaseGears },
	{ key = "Crates", stock = CratesStock, remote = PurchaseCrates },
}

local subTabButtons = {}
local activeSubTab = "All"

RemoteWidgets.buyInterval = select(2, createSlider(buyPage, 36, "Buy interval", 0.001, 10, BuyInterval, "s", function(v)
	BuyInterval = v
end))

-- Live proof the loop is actually running: Selected is counted
-- directly from your toggles (independent of whether the loop has run
-- yet), Fired is how many purchase requests have actually gone out.
-- If Selected > 0 but Fired stays 0, the loop itself isn't running —
-- that's now the only remaining failure mode here since firing no
-- longer depends on canAfford.
local buyStatusLabel = Instance.new("TextLabel")
buyStatusLabel.BackgroundTransparency = 1
buyStatusLabel.Position = UDim2.new(0, 16, 0, 146)
buyStatusLabel.Size = UDim2.new(1, -32, 0, 16)
buyStatusLabel.Font = Enum.Font.Gotham
buyStatusLabel.Text = "Selected: 0 · Fired: 0"
buyStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
buyStatusLabel.TextSize = 11
buyStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
buyStatusLabel.TextTruncate = Enum.TextTruncate.AtEnd
buyStatusLabel.Parent = buyPage

task.spawn(function()
	while task.wait(0.2) do
		local selectedCount = countSelected()
		local text = string.format("Selected: %d · Fired: %d", selectedCount, BuyFiredCount)
		if BuyFiredCount > 0 then
			text = text .. " · last: " .. BuyLastFired
			buyStatusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)
		elseif selectedCount > 0 then
			text = text .. " (loop hasn't fired yet — should within " .. string.format("%.2f", BuyInterval) .. "s)"
			buyStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
		else
			buyStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		end
		buyStatusLabel.Text = text
	end
end)

local listHolder = Instance.new("ScrollingFrame")
listHolder.BackgroundTransparency = 1
listHolder.Position = UDim2.new(0, 16, 0, 170)
listHolder.Size = UDim2.new(1, -32, 0, PAGE_HEIGHTS.Buy - 170 - 8)
listHolder.CanvasSize = UDim2.new(0, 0, 0, 0)
listHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
listHolder.ScrollBarThickness = 3
listHolder.ScrollBarImageTransparency = 0.4
listHolder.BorderSizePixel = 0
listHolder.Parent = buyPage

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.Parent = listHolder

local categoryBulkRow = Instance.new("Frame")
categoryBulkRow.BackgroundTransparency = 1
categoryBulkRow.Position = UDim2.new(0, 16, 0, 84)
categoryBulkRow.Size = UDim2.new(1, -32, 0, 26)
categoryBulkRow.Parent = buyPage

local categoryBulkLayout = Instance.new("UIListLayout")
categoryBulkLayout.FillDirection = Enum.FillDirection.Horizontal
categoryBulkLayout.Padding = UDim.new(0, 6)
categoryBulkLayout.Parent = categoryBulkRow

local bulkRow = Instance.new("Frame")
bulkRow.BackgroundTransparency = 1
bulkRow.Position = UDim2.new(0, 16, 0, 118)
bulkRow.Size = UDim2.new(1, -32, 0, 26)
bulkRow.Parent = buyPage

local bulkLayout = Instance.new("UIListLayout")
bulkLayout.FillDirection = Enum.FillDirection.Horizontal
bulkLayout.Padding = UDim.new(0, 8)
bulkLayout.Parent = bulkRow

local selectAllBtn = pillButton(bulkRow, "Select All", 90)
local selectNoneBtn = pillButton(bulkRow, "None", 90)
local buyQuery = ""

-- A search field. Lives in the bulk-button row so adding it doesn't
-- shift any list down the page.
local function searchBox(parent, onChange)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0, 118, 0, 22)
	box.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	box.BackgroundTransparency = 0.9
	box.Font = Enum.Font.Gotham
	box.PlaceholderText = "Search…"
	box.PlaceholderColor3 = Color3.fromRGB(140, 140, 145)
	box.Text = ""
	box.TextColor3 = Color3.fromRGB(255, 255, 255)
	box.TextSize = 11
	box.ClearTextOnFocus = false
	box.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = box

	box:GetPropertyChangedSignal("Text"):Connect(function()
		onChange(box.Text:lower())
	end)
	return box
end

-- Empty query matches everything; otherwise a plain substring, which is
-- what people actually type.
local function matchesQuery(name, query)
	if query == "" then return true end
	return name:lower():find(query, 1, true) ~= nil
end

local rowEntries = {}
local rowConnections = {}

local function buildList(tab)
	for _, child in ipairs(listHolder:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	rowEntries = {}

	for _, conn in ipairs(rowConnections) do
		conn:Disconnect()
	end
	rowConnections = {}

	local showAll = tab == "All"

	local items = {}
	for _, cat in ipairs(categories) do
		if showAll or cat.key == tab then
			for _, item in ipairs(cat.stock:GetChildren()) do
				if matchesQuery(item.Name, buyQuery) then
					table.insert(items, { instance = item, category = cat.key })
				end
			end
		end
	end
	table.sort(items, function(a, b)
		if showAll and a.category ~= b.category then
			return a.category < b.category
		end
		return a.instance.Name < b.instance.Name
	end)

	for _, entry in ipairs(items) do
		local item = entry.instance
		local name = item.Name
		local realCategory = entry.category

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 28)
		row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		row.BackgroundTransparency = 0.93
		row.Parent = listHolder

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 8)
		rowCorner.Parent = row

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(0, 10, 0, 0)
		label.Size = UDim2.new(1, showAll and -168 or -128, 1, 0)
		label.Font = Enum.Font.Gotham
		label.Text = name
		label.TextColor3 = Color3.fromRGB(230, 230, 235)
		label.TextSize = 12
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Parent = row

		if showAll then
			local tag = Instance.new("TextLabel")
			tag.BackgroundTransparency = 1
			tag.Position = UDim2.new(1, -158, 0, 0)
			tag.Size = UDim2.new(0, 44, 1, 0)
			tag.Font = Enum.Font.GothamBold
			tag.Text = realCategory
			tag.TextColor3 = Color3.fromRGB(150, 150, 155)
			tag.TextSize = 10
			tag.TextXAlignment = Enum.TextXAlignment.Left
			tag.Parent = row
		end

		local stockLabel = Instance.new("TextLabel")
		stockLabel.BackgroundTransparency = 1
		stockLabel.Position = UDim2.new(1, -114, 0, 0)
		stockLabel.Size = UDim2.new(0, 74, 1, 0)
		stockLabel.Font = Enum.Font.Gotham
		stockLabel.TextSize = 11
		stockLabel.TextXAlignment = Enum.TextXAlignment.Right
		stockLabel.Parent = row

		local toggle = Instance.new("TextButton")
		toggle.Position = UDim2.new(1, -34, 0.5, -9)
		toggle.Size = UDim2.new(0, 26, 0, 18)
		toggle.AutoButtonColor = false
		toggle.Text = ""
		toggle.Parent = row

		local toggleCorner = Instance.new("UICorner")
		toggleCorner.CornerRadius = UDim.new(1, 0)
		toggleCorner.Parent = toggle

		local knob = Instance.new("Frame")
		knob.Size = UDim2.new(0, 14, 0, 14)
		knob.Position = UDim2.new(0, 2, 0.5, -7)
		knob.Parent = toggle
		local knobCorner = Instance.new("UICorner")
		knobCorner.CornerRadius = UDim.new(1, 0)
		knobCorner.Parent = knob

		local function paint()
			local on = isSelected(realCategory, name)
			toggle.BackgroundColor3 = on and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(60, 60, 64)
			knob.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
			knob.Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
		end
		paint()

		local function paintStock()
			local inStock = item.Value and item.Value > 0
			stockLabel.Text = inStock and "In stock" or "Out of stock"
			stockLabel.TextColor3 = inStock and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(130, 130, 135)
		end
		paintStock()
		table.insert(rowConnections, item:GetPropertyChangedSignal("Value"):Connect(paintStock))

		toggle.MouseButton1Click:Connect(function()
			Selected[realCategory][name] = not isSelected(realCategory, name)
			paint()
		end)

		table.insert(rowEntries, { name = name, category = realCategory, paint = paint, frame = row })
	end
end

selectAllBtn.MouseButton1Click:Connect(function()
	-- rowEntries only holds what the current filter built, so a search
	-- narrows Select All to the visible rows, which is the point of it.
	for _, entry in ipairs(rowEntries) do
		Selected[entry.category][entry.name] = true
		entry.paint()
	end
end)
selectNoneBtn.MouseButton1Click:Connect(function()
	for _, entry in ipairs(rowEntries) do
		Selected[entry.category][entry.name] = false
		entry.paint()
	end
end)

local function selectAllInCategory(categoryKey)
	local cat = nil
	for _, c in ipairs(categories) do
		if c.key == categoryKey then cat = c break end
	end
	if not cat then return end

	for _, item in ipairs(cat.stock:GetChildren()) do
		Selected[categoryKey][item.Name] = true
	end

	for _, entry in ipairs(rowEntries) do
		if entry.category == categoryKey then
			entry.paint()
		end
	end
end

for _, cat in ipairs(categories) do
	local btn = pillButton(categoryBulkRow, "All " .. cat.key, 84)
	btn.MouseButton1Click:Connect(function()
		selectAllInCategory(cat.key)
	end)
end

local function paintSubTabs()
	for key, btn in pairs(subTabButtons) do
		local on = key == activeSubTab
		btn.BackgroundTransparency = on and 0.75 or 0.94
		btn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(190, 190, 195)
	end
end

local subTabKeys = { "All", "Seeds", "Gears", "Crates" }
for _, key in ipairs(subTabKeys) do
	local btn = pillButton(subTabBar, key, 60)
	subTabButtons[key] = btn
	btn.MouseButton1Click:Connect(function()
		activeSubTab = key
		paintSubTabs()
		buildList(key)
	end)
end

paintSubTabs()
buildList(activeSubTab)

-- Remote control redraws the same way a sub-tab switch does.
RemoteRepaint.buy = function()
	buildList(activeSubTab)
end

searchBox(bulkRow, function(text)
	buyQuery = text
	buildList(activeSubTab)
end)

--========================================================
-- PLANT page
--========================================================
local plantPage = pages.Plant

RemoteWidgets.plantEnabled = select(2, createToggleRow(plantPage, 0, "Enable Auto Plant", PlantEnabled, function(state)
	PlantEnabled = state
end))

RemoteWidgets.plantInterval = select(2, createSlider(plantPage, 32, "Plant delay", 0.001, 10, PlantInterval, "s", function(v)
	PlantInterval = v
end))

-- Placement mode selector
local plantModeRow = Instance.new("Frame")
plantModeRow.BackgroundTransparency = 1
plantModeRow.Position = UDim2.new(0, 16, 0, 76)
plantModeRow.Size = UDim2.new(1, -32, 0, 26)
plantModeRow.Parent = plantPage

local plantModeLayout = Instance.new("UIListLayout")
plantModeLayout.FillDirection = Enum.FillDirection.Horizontal
plantModeLayout.Padding = UDim.new(0, 8)
plantModeLayout.Parent = plantModeRow

local plantModeButtons = {}
local plantModes = {
	{ key = "me", label = "At me" },
	{ key = "random", label = "Random" },
	{ key = "fixed", label = "Fixed" },
}

local function paintPlantModes()
	for key, btn in pairs(plantModeButtons) do
		local on = key == PlantMode
		btn.BackgroundTransparency = on and 0.75 or 0.94
		btn.TextColor3 = on and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 180, 185)
	end
end

for _, mode in ipairs(plantModes) do
	local btn = pillButton(plantModeRow, mode.label, 84)
	plantModeButtons[mode.key] = btn
	btn.MouseButton1Click:Connect(function()
		PlantMode = mode.key
		paintPlantModes()
	end)
end
paintPlantModes()

RemoteRepaint.plantMode = function(mode)
	PlantMode = mode
	paintPlantModes()
end

-- Pins the fixed-mode spot to wherever you're standing right now.
local setFixedBtn = pillButton(plantPage, "Set fixed spot to where I'm standing", 268)
setFixedBtn.Position = UDim2.new(0, 16, 0, 108)
setFixedBtn.Size = UDim2.new(1, -32, 0, 26)
setFixedBtn.TextSize = 11
setFixedBtn.MouseButton1Click:Connect(function()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		PlantFixedPosition = root.Position
		PlantMode = "fixed"
		paintPlantModes()
	end
end)

local plantStatusLabel = Instance.new("TextLabel")
plantStatusLabel.BackgroundTransparency = 1
plantStatusLabel.Position = UDim2.new(0, 16, 0, 140)
plantStatusLabel.Size = UDim2.new(1, -32, 0, 28)
plantStatusLabel.Font = Enum.Font.Gotham
plantStatusLabel.Text = "Planting at your position as you move."
plantStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
plantStatusLabel.TextSize = 11
plantStatusLabel.TextWrapped = true
plantStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
plantStatusLabel.TextYAlignment = Enum.TextYAlignment.Top
plantStatusLabel.Parent = plantPage

task.spawn(function()
	while task.wait(0.2) do
		local selectedCount = countPlantSelected()
		if PlantConfirmedCount > 0 then
			plantStatusLabel.Text = string.format(
				"Planted: %d · sent: %d · last: %s (%s)",
				PlantConfirmedCount, PlantFiredCount, PlantLastFired, PlantArgOrder or "?"
			)
			plantStatusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)
		elseif PlantFiredCount > 0 then
			-- Requests are going out but the game never reported a plant:
			-- wrong spot, no seeds, or this world rejects it.
			plantStatusLabel.Text = string.format(
				"Sent %d requests · %s args · tool: %s — none planted yet.",
				PlantFiredCount, PlantArity and tostring(PlantArity) or "?", PlantLastTool
			)
			plantStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
		elseif PlantMode == "fixed" and not PlantFixedPosition then
			plantStatusLabel.Text = "No fixed spot set — tap the button above to pin one."
			plantStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
		elseif PlantMode == "random" and not OwnerPlot then
			plantStatusLabel.Text = "Still locating your plot for random placement…"
			plantStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
		elseif PlantEnabled and selectedCount > 0 then
			plantStatusLabel.Text = "Trying to plant… make sure you own the selected seeds."
			plantStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
		elseif PlantMode == "random" then
			plantStatusLabel.Text = "Scattering randomly across your plot."
			plantStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		elseif PlantMode == "fixed" then
			plantStatusLabel.Text = "Planting at your pinned spot."
			plantStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		else
			plantStatusLabel.Text = "Planting at your position as you move."
			plantStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		end
	end
end)

local plantBulkRow = Instance.new("Frame")
plantBulkRow.BackgroundTransparency = 1
plantBulkRow.Position = UDim2.new(0, 16, 0, 172)
plantBulkRow.Size = UDim2.new(1, -32, 0, 26)
plantBulkRow.Parent = plantPage

local plantBulkLayout = Instance.new("UIListLayout")
plantBulkLayout.FillDirection = Enum.FillDirection.Horizontal
plantBulkLayout.Padding = UDim.new(0, 8)
plantBulkLayout.Parent = plantBulkRow

local plantAllBtn = pillButton(plantBulkRow, "Select All", 90)
local plantNoneBtn = pillButton(plantBulkRow, "None", 90)

local plantList = Instance.new("ScrollingFrame")
plantList.BackgroundTransparency = 1
plantList.Position = UDim2.new(0, 16, 0, 206)
plantList.Size = UDim2.new(1, -32, 0, PAGE_HEIGHTS.Plant - 206 - 8)
plantList.CanvasSize = UDim2.new(0, 0, 0, 0)
plantList.AutomaticCanvasSize = Enum.AutomaticSize.Y
plantList.ScrollBarThickness = 3
plantList.ScrollBarImageTransparency = 0.4
plantList.BorderSizePixel = 0
plantList.Parent = plantPage

local plantListLayout = Instance.new("UIListLayout")
plantListLayout.Padding = UDim.new(0, 4)
plantListLayout.Parent = plantList

local plantRowEntries = {}

do
	-- Seed names come from the shop's stock folder, same source the Buy
	-- tab uses — it's the full catalog regardless of what you own, and
	-- the server rejects planting anything you don't have, consistent
	-- with how Buy fires unconditionally and lets the server decide.
	local names = {}
	for _, item in ipairs(SeedsStock:GetChildren()) do
		table.insert(names, item.Name)
	end
	table.sort(names)

	for _, name in ipairs(names) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 28)
		row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		row.BackgroundTransparency = 0.93
		row.Parent = plantList

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 8)
		rowCorner.Parent = row

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(0, 10, 0, 0)
		label.Size = UDim2.new(1, -46, 1, 0)
		label.Font = Enum.Font.Gotham
		label.Text = name
		label.TextColor3 = Color3.fromRGB(230, 230, 235)
		label.TextSize = 12
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Parent = row

		local toggle = Instance.new("TextButton")
		toggle.Position = UDim2.new(1, -34, 0.5, -9)
		toggle.Size = UDim2.new(0, 26, 0, 18)
		toggle.AutoButtonColor = false
		toggle.Text = ""
		toggle.Parent = row

		local toggleCorner = Instance.new("UICorner")
		toggleCorner.CornerRadius = UDim.new(1, 0)
		toggleCorner.Parent = toggle

		local knob = Instance.new("Frame")
		knob.Size = UDim2.new(0, 14, 0, 14)
		knob.Position = UDim2.new(0, 2, 0.5, -7)
		knob.Parent = toggle
		local knobCorner = Instance.new("UICorner")
		knobCorner.CornerRadius = UDim.new(1, 0)
		knobCorner.Parent = knob

		local function paint()
			local on = isPlantSelected(name)
			toggle.BackgroundColor3 = on and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(60, 60, 64)
			knob.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
			knob.Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
		end
		paint()

		toggle.MouseButton1Click:Connect(function()
			PlantSelected[name] = not isPlantSelected(name)
			paint()
		end)

		table.insert(plantRowEntries, { name = name, paint = paint, frame = row })
	end
end

RemoteRepaint.plant = function()
	for _, entry in ipairs(plantRowEntries) do
		entry.paint()
	end
end

searchBox(plantBulkRow, function(text)
	for _, entry in ipairs(plantRowEntries) do
		entry.frame.Visible = matchesQuery(entry.name, text)
	end
end)

plantAllBtn.MouseButton1Click:Connect(function()
	-- Visible rows only, so bulk actions under a search mean the
	-- filtered set rather than the whole list.
	for _, entry in ipairs(plantRowEntries) do
		if entry.frame.Visible then
			PlantSelected[entry.name] = true
			entry.paint()
		end
	end
end)
plantNoneBtn.MouseButton1Click:Connect(function()
	for _, entry in ipairs(plantRowEntries) do
		if entry.frame.Visible then
			PlantSelected[entry.name] = false
			entry.paint()
		end
	end
end)

--========================================================
-- DROPS page
--========================================================
local dropsPage = pages.Drops

RemoteWidgets.collectEnabled = select(2, createToggleRow(dropsPage, 0, "Enable Auto Collect", CollectEnabled, function(state)
	CollectEnabled = state
end))

RemoteWidgets.collectReturn = select(2, createToggleRow(dropsPage, 30, "Return to my spot after", CollectReturn, function(state)
	CollectReturn = state
end))

RemoteWidgets.collectEverything = select(2, createToggleRow(dropsPage, 60, "Collect everything dropped", CollectEverything, function(state)
	CollectEverything = state
end))

RemoteWidgets.collectDwell = select(2, createSlider(dropsPage, 94, "Pickup dwell", 0.01, 2, CollectDwell, "s", function(v)
	CollectDwell = v
end))

local dropsStatusLabel = Instance.new("TextLabel")
dropsStatusLabel.BackgroundTransparency = 1
dropsStatusLabel.Position = UDim2.new(0, 16, 0, 138)
dropsStatusLabel.Size = UDim2.new(1, -32, 0, 28)
dropsStatusLabel.Font = Enum.Font.Gotham
dropsStatusLabel.Text = "Teleports to drops and holds E for you."
dropsStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
dropsStatusLabel.TextSize = 11
dropsStatusLabel.TextWrapped = true
dropsStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
dropsStatusLabel.TextYAlignment = Enum.TextYAlignment.Top
dropsStatusLabel.Parent = dropsPage

task.spawn(function()
	while task.wait(0.2) do
		if CollectedCount > 0 then
			dropsStatusLabel.Text = string.format("Collected: %d · last: %s", CollectedCount, CollectLast)
			dropsStatusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)
		elseif CollectEnabled and not CollectEverything and countCollectSelected() == 0 then
			dropsStatusLabel.Text = "Nothing selected below, and 'collect everything' is off."
			dropsStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
		elseif CollectEnabled then
			dropsStatusLabel.Text = "Watching for drops…"
			dropsStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
		else
			dropsStatusLabel.Text = "Teleports to drops and holds E for you."
			dropsStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 155)
		end
	end
end)

local dropsBulkRow = Instance.new("Frame")
dropsBulkRow.BackgroundTransparency = 1
dropsBulkRow.Position = UDim2.new(0, 16, 0, 168)
dropsBulkRow.Size = UDim2.new(1, -32, 0, 26)
dropsBulkRow.Parent = dropsPage

local dropsBulkLayout = Instance.new("UIListLayout")
dropsBulkLayout.FillDirection = Enum.FillDirection.Horizontal
dropsBulkLayout.Padding = UDim.new(0, 8)
dropsBulkLayout.Parent = dropsBulkRow

local dropsAllBtn = pillButton(dropsBulkRow, "Select All", 90)
local dropsNoneBtn = pillButton(dropsBulkRow, "None", 90)

local dropsList = Instance.new("ScrollingFrame")
dropsList.BackgroundTransparency = 1
dropsList.Position = UDim2.new(0, 16, 0, 202)
dropsList.Size = UDim2.new(1, -32, 0, PAGE_HEIGHTS.Drops - 202 - 8)
dropsList.CanvasSize = UDim2.new(0, 0, 0, 0)
dropsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
dropsList.ScrollBarThickness = 3
dropsList.ScrollBarImageTransparency = 0.4
dropsList.BorderSizePixel = 0
dropsList.Parent = dropsPage

local dropsListLayout = Instance.new("UIListLayout")
dropsListLayout.Padding = UDim.new(0, 4)
dropsListLayout.Parent = dropsList

local dropsRowEntries = {}

do
	-- Filter names come from the live seed stock, same as everywhere
	-- else, so they're real in-game names rather than guesses. Matched
	-- exactly — Gold, Rainbow and Mega are their own seeds, not
	-- prefixes on other seeds.
	local names = {}
	for _, item in ipairs(SeedsStock:GetChildren()) do
		table.insert(names, item.Name)
	end
	table.sort(names)

	for _, name in ipairs(names) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 28)
		row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		row.BackgroundTransparency = 0.93
		row.Parent = dropsList

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 8)
		rowCorner.Parent = row

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(0, 10, 0, 0)
		label.Size = UDim2.new(1, -46, 1, 0)
		label.Font = Enum.Font.Gotham
		label.Text = name
		label.TextColor3 = Color3.fromRGB(230, 230, 235)
		label.TextSize = 12
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Parent = row

		local toggle = Instance.new("TextButton")
		toggle.Position = UDim2.new(1, -34, 0.5, -9)
		toggle.Size = UDim2.new(0, 26, 0, 18)
		toggle.AutoButtonColor = false
		toggle.Text = ""
		toggle.Parent = row

		local toggleCorner = Instance.new("UICorner")
		toggleCorner.CornerRadius = UDim.new(1, 0)
		toggleCorner.Parent = toggle

		local knob = Instance.new("Frame")
		knob.Size = UDim2.new(0, 14, 0, 14)
		knob.Position = UDim2.new(0, 2, 0.5, -7)
		knob.Parent = toggle
		local knobCorner = Instance.new("UICorner")
		knobCorner.CornerRadius = UDim.new(1, 0)
		knobCorner.Parent = knob

		local function paint()
			local on = isCollectSelected(name)
			toggle.BackgroundColor3 = on and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(60, 60, 64)
			knob.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
			knob.Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
		end
		paint()

		toggle.MouseButton1Click:Connect(function()
			CollectSelected[name] = not isCollectSelected(name)
			paint()
		end)

		table.insert(dropsRowEntries, { name = name, paint = paint, frame = row })
	end
end

RemoteRepaint.drops = function()
	for _, entry in ipairs(dropsRowEntries) do
		entry.paint()
	end
end

searchBox(dropsBulkRow, function(text)
	for _, entry in ipairs(dropsRowEntries) do
		entry.frame.Visible = matchesQuery(entry.name, text)
	end
end)

dropsAllBtn.MouseButton1Click:Connect(function()
	for _, entry in ipairs(dropsRowEntries) do
		if entry.frame.Visible then
			CollectSelected[entry.name] = true
			entry.paint()
		end
	end
end)
dropsNoneBtn.MouseButton1Click:Connect(function()
	for _, entry in ipairs(dropsRowEntries) do
		if entry.frame.Visible then
			CollectSelected[entry.name] = false
			entry.paint()
		end
	end
end)

--========================================================
-- HARVEST page
--========================================================
local harvestPage = pages.Harvest

RemoteWidgets.harvestEnabled = select(2, createToggleRow(harvestPage, 0, "Enable Auto Harvest", HarvestEnabled, function(state)
	HarvestEnabled = state
end))

local harvestNote = Instance.new("TextLabel")
harvestNote.BackgroundTransparency = 1
harvestNote.Position = UDim2.new(0, 16, 0, 34)
harvestNote.Size = UDim2.new(1, -32, 0, 32)
harvestNote.Font = Enum.Font.Gotham
harvestNote.Text = "Harvests ripe crops first, then attempts still-growing ones too."
harvestNote.TextColor3 = Color3.fromRGB(150, 150, 155)
harvestNote.TextSize = 11
harvestNote.TextWrapped = true
harvestNote.TextXAlignment = Enum.TextXAlignment.Left
harvestNote.TextYAlignment = Enum.TextYAlignment.Top
harvestNote.Parent = harvestPage

-- Without a console, a silently-ineffective exclusion looks identical
-- to a working one; this makes the difference visible.
task.spawn(function()
	while task.wait(0.5) do
		if HarvestSkipped > 0 then
			harvestNote.Text = string.format(
				"Harvests ripe crops first, then still-growing ones. Skipped %d excluded.",
				HarvestSkipped
			)
			harvestNote.TextColor3 = Color3.fromRGB(120, 255, 170)
		end
	end
end)

RemoteWidgets.harvestInterval = select(2, createSlider(harvestPage, 76, "Harvest delay", 0.001, 10, HarvestInterval, "s", function(v)
	HarvestInterval = v
end))

-- Exclusion list. Everything is harvested by default; ticking a crop
-- here leaves it in the ground.
do
	local excludeNote = Instance.new("TextLabel")
	excludeNote.BackgroundTransparency = 1
	excludeNote.Position = UDim2.new(0, 16, 0, 116)
	excludeNote.Size = UDim2.new(1, -32, 0, 16)
	excludeNote.Font = Enum.Font.Gotham
	excludeNote.Text = "Don't harvest these:"
	excludeNote.TextColor3 = Color3.fromRGB(200, 200, 205)
	excludeNote.TextSize = 12
	excludeNote.TextXAlignment = Enum.TextXAlignment.Left
	excludeNote.Parent = harvestPage

	local bulkRow = Instance.new("Frame")
	bulkRow.BackgroundTransparency = 1
	bulkRow.Position = UDim2.new(0, 16, 0, 136)
	bulkRow.Size = UDim2.new(1, -32, 0, 24)
	bulkRow.Parent = harvestPage

	local bulkLayout = Instance.new("UIListLayout")
	bulkLayout.FillDirection = Enum.FillDirection.Horizontal
	bulkLayout.Padding = UDim.new(0, 6)
	bulkLayout.Parent = bulkRow

	local excludeAllBtn = pillButton(bulkRow, "Exclude All", 90)
	local excludeNoneBtn = pillButton(bulkRow, "None", 90)

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.new(0, 16, 0, 166)
	-- Sized against the page height, not the parent's remaining space:
	-- the page is a fixed-height frame, so "1, -176" measured against a
	-- page that was still 130px tall left the list clipped to nothing.
	list.Size = UDim2.new(1, -32, 0, PAGE_HEIGHTS.Harvest - 166 - 8)
	list.BackgroundTransparency = 1
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 3
	list.ScrollBarImageTransparency = 0.4
	list.BorderSizePixel = 0
	list.Parent = harvestPage

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.Parent = list

	local entries = {}
	local names = {}
	for _, item in ipairs(SeedsStock:GetChildren()) do
		table.insert(names, item.Name)
	end
	table.sort(names)

	for _, name in ipairs(names) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 28)
		row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		row.BackgroundTransparency = 0.93
		row.Parent = list

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, 8)
		rowCorner.Parent = row

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(0, 10, 0, 0)
		label.Size = UDim2.new(1, -46, 1, 0)
		label.Font = Enum.Font.Gotham
		label.Text = name
		label.TextColor3 = Color3.fromRGB(230, 230, 235)
		label.TextSize = 12
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Parent = row

		local toggle = Instance.new("TextButton")
		toggle.Position = UDim2.new(1, -34, 0.5, -9)
		toggle.Size = UDim2.new(0, 26, 0, 18)
		toggle.AutoButtonColor = false
		toggle.Text = ""
		toggle.Parent = row

		local toggleCorner = Instance.new("UICorner")
		toggleCorner.CornerRadius = UDim.new(1, 0)
		toggleCorner.Parent = toggle

		local knob = Instance.new("Frame")
		knob.Size = UDim2.new(0, 14, 0, 14)
		knob.Position = UDim2.new(0, 2, 0.5, -7)
		knob.Parent = toggle
		local knobCorner = Instance.new("UICorner")
		knobCorner.CornerRadius = UDim.new(1, 0)
		knobCorner.Parent = knob

		local function paint()
			local on = HarvestExcluded[name] == true
			-- Red when on: this switch means "skip", not "do".
			toggle.BackgroundColor3 = on and Color3.fromRGB(255, 140, 140) or Color3.fromRGB(60, 60, 64)
			knob.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
			knob.Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
		end
		paint()

		toggle.MouseButton1Click:Connect(function()
			HarvestExcluded[name] = not (HarvestExcluded[name] == true)
			paint()
		end)

		table.insert(entries, { name = name, paint = paint, frame = row })
	end

	RemoteRepaint.harvestExcluded = function()
		for _, entry in ipairs(entries) do
			entry.paint()
		end
	end

	searchBox(bulkRow, function(text)
		for _, entry in ipairs(entries) do
			entry.frame.Visible = matchesQuery(entry.name, text)
		end
	end)

	excludeAllBtn.MouseButton1Click:Connect(function()
		for _, entry in ipairs(entries) do
			if entry.frame.Visible then
				HarvestExcluded[entry.name] = true
				entry.paint()
			end
		end
	end)
	excludeNoneBtn.MouseButton1Click:Connect(function()
		for _, entry in ipairs(entries) do
			if entry.frame.Visible then
				HarvestExcluded[entry.name] = false
				entry.paint()
			end
		end
	end)
end

--========================================================
-- SHOVEL page
--
-- Wrapped in a do-block so its locals don't count against the main
-- chunk, which is at Lua's 200-locals ceiling.
--========================================================
do
	local shovelPage = pages.Shovel

	RemoteWidgets.shovelEnabled = select(2, createToggleRow(shovelPage, 0, "Enable Auto Shovel", Shovel.enabled, function(state)
		Shovel.enabled = state
	end))

	RemoteWidgets.shovelInterval = select(2, createSlider(shovelPage, 32, "Shovel delay", 0.001, 10, Shovel.interval, "s", function(v)
		Shovel.interval = v
	end))

	local shovelStatusLabel = Instance.new("TextLabel")
	shovelStatusLabel.BackgroundTransparency = 1
	shovelStatusLabel.Position = UDim2.new(0, 16, 0, 76)
	shovelStatusLabel.Size = UDim2.new(1, -32, 0, 30)
	shovelStatusLabel.Font = Enum.Font.GothamBold
	shovelStatusLabel.Text = "Dug up: 0"
	shovelStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
	shovelStatusLabel.TextSize = 12
	shovelStatusLabel.TextWrapped = true
	shovelStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	shovelStatusLabel.TextYAlignment = Enum.TextYAlignment.Top
	shovelStatusLabel.Parent = shovelPage

	-- The picker lists what's actually growing on your plot, refreshed as
	-- the garden changes, rather than the shop catalogue — you can only dig
	-- up what you planted.
	do
		local bulkRow = Instance.new("Frame")
		bulkRow.BackgroundTransparency = 1
		bulkRow.Position = UDim2.new(0, 16, 0, 112)
		bulkRow.Size = UDim2.new(1, -32, 0, 24)
		bulkRow.Parent = shovelPage

		local bulkLayout = Instance.new("UIListLayout")
		bulkLayout.FillDirection = Enum.FillDirection.Horizontal
		bulkLayout.Padding = UDim.new(0, 6)
		bulkLayout.Parent = bulkRow

		local allBtn = pillButton(bulkRow, "Select All", 90)
		local noneBtn = pillButton(bulkRow, "None", 90)

		local list = Instance.new("ScrollingFrame")
		list.Position = UDim2.new(0, 16, 0, 142)
		list.Size = UDim2.new(1, -32, 0, PAGE_HEIGHTS.Shovel - 142 - 8)
		list.BackgroundTransparency = 1
		list.CanvasSize = UDim2.new(0, 0, 0, 0)
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.ScrollBarThickness = 3
		list.ScrollBarImageTransparency = 0.4
		list.BorderSizePixel = 0
		list.Parent = shovelPage

		local listLayout = Instance.new("UIListLayout")
		listLayout.Padding = UDim.new(0, 4)
		listLayout.Parent = list

		local entries = {}
		local query = ""

		local function rebuild()
			for _, child in ipairs(list:GetChildren()) do
				if child:IsA("Frame") then child:Destroy() end
			end
			entries = {}

			for _, name in ipairs(Shovel.names) do
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, 0, 0, 28)
				row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				row.BackgroundTransparency = 0.93
				row.Visible = matchesQuery(name, query)
				row.Parent = list

				local rowCorner = Instance.new("UICorner")
				rowCorner.CornerRadius = UDim.new(0, 8)
				rowCorner.Parent = row

				local label = Instance.new("TextLabel")
				label.BackgroundTransparency = 1
				label.Position = UDim2.new(0, 10, 0, 0)
				label.Size = UDim2.new(1, -46, 1, 0)
				label.Font = Enum.Font.Gotham
				label.Text = name
				label.TextColor3 = Color3.fromRGB(230, 230, 235)
				label.TextSize = 12
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.TextTruncate = Enum.TextTruncate.AtEnd
				label.Parent = row

				local toggle = Instance.new("TextButton")
				toggle.Position = UDim2.new(1, -34, 0.5, -9)
				toggle.Size = UDim2.new(0, 26, 0, 18)
				toggle.AutoButtonColor = false
				toggle.Text = ""
				toggle.Parent = row

				local toggleCorner = Instance.new("UICorner")
				toggleCorner.CornerRadius = UDim.new(1, 0)
				toggleCorner.Parent = toggle

				local knob = Instance.new("Frame")
				knob.Size = UDim2.new(0, 14, 0, 14)
				knob.Position = UDim2.new(0, 2, 0.5, -7)
				knob.Parent = toggle
				local knobCorner = Instance.new("UICorner")
				knobCorner.CornerRadius = UDim.new(1, 0)
				knobCorner.Parent = knob

				local function paint()
					local on = Shovel.selected[name] == true
					-- Red: this switch destroys the crop.
					toggle.BackgroundColor3 = on and Color3.fromRGB(255, 140, 140) or Color3.fromRGB(60, 60, 64)
					knob.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
					knob.Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
				end
				paint()

				toggle.MouseButton1Click:Connect(function()
					Shovel.selected[name] = not (Shovel.selected[name] == true)
					paint()
				end)

				table.insert(entries, { name = name, paint = paint, frame = row })
			end
		end

		searchBox(bulkRow, function(text)
			query = text
			for _, entry in ipairs(entries) do
				entry.frame.Visible = matchesQuery(entry.name, query)
			end
		end)

		allBtn.MouseButton1Click:Connect(function()
			for _, entry in ipairs(entries) do
				if entry.frame.Visible then
					Shovel.selected[entry.name] = true
					entry.paint()
				end
			end
		end)
		noneBtn.MouseButton1Click:Connect(function()
			for _, entry in ipairs(entries) do
				if entry.frame.Visible then
					Shovel.selected[entry.name] = false
					entry.paint()
				end
			end
		end)

		RemoteRepaint.shovel = function()
			for _, entry in ipairs(entries) do
				entry.paint()
			end
		end

		rebuild()

		task.spawn(function()
			local shown = ""
			while task.wait(0.5) do
				-- Rebuild only when the set of crops actually changes, so
				-- the list doesn't flicker under your finger.
				local signature = table.concat(Shovel.names, "|")
				if signature ~= shown then
					shown = signature
					rebuild()
				end
				shovelStatusLabel.Text = string.format("Dug up: %d · %s", Shovel.removed, Shovel.status)
				shovelStatusLabel.TextColor3 = Shovel.removed > 0 and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(200, 200, 205)
			end
		end)
	end
end

--========================================================
-- SELL page
--========================================================
local sellPage = pages.Sell

RemoteWidgets.sellEnabled = select(2, createToggleRow(sellPage, 0, "Enable Auto Sell", SellEnabled, function(state)
	SellEnabled = state
end))

RemoteWidgets.sellInterval = select(2, createSlider(sellPage, 36, "Sell delay", 0.001, 10, SellInterval, "s", function(v)
	SellInterval = v
end))

--========================================================
-- STATS page
--========================================================
local statsPage = pages.Stats

-- Explains *why* the numbers below aren't populating instead of just
-- showing dashes forever with no indication whether it's still
-- detecting, actually working, or has given up.
local statsStatusLabel = Instance.new("TextLabel")
statsStatusLabel.BackgroundTransparency = 1
statsStatusLabel.Position = UDim2.new(0, 16, 0, 0)
statsStatusLabel.Size = UDim2.new(1, -32, 0, 16)
statsStatusLabel.Font = Enum.Font.GothamBold
statsStatusLabel.Text = "Detecting game data..."
statsStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
statsStatusLabel.TextSize = 11
statsStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
statsStatusLabel.Parent = statsPage

local elapsedValue = createStatRow(statsPage, 20, "Elapsed time")
local earnedValue = createStatRow(statsPage, 44, "Earned so far")
local spentValue = createStatRow(statsPage, 68, "Spent so far")
local netValue = createStatRow(statsPage, 92, "Net so far")
local perSecValue = createStatRow(statsPage, 124, "Per second")
local perMinValue = createStatRow(statsPage, 148, "Per minute")
local perHourValue = createStatRow(statsPage, 172, "Per hour")
local perDayValue = createStatRow(statsPage, 196, "Per day")

local function refreshStatsUI()
	local elapsed = tick() - StatsStartTime
	elapsedValue.Text = formatElapsed(elapsed)

	if not StatsStartingSheckles then
		if SheckleSearchFailed then
			statsStatusLabel.Text = "Exact Sheckles value not found — Stats unavailable"
			statsStatusLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
		else
			statsStatusLabel.Text = "Detecting game data..."
			statsStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 205)
		end
		earnedValue.Text = "—"
		spentValue.Text = "—"
		netValue.Text = "—"
		perSecValue.Text = "—"
		perMinValue.Text = "—"
		perHourValue.Text = "—"
		perDayValue.Text = "—"
		return
	end

	statsStatusLabel.Text = "Tracking · " .. tostring(sheckleSource or "?")
	statsStatusLabel.TextColor3 = Color3.fromRGB(120, 255, 170)

	earnedValue.Text = formatNumber(TotalEarned)
	earnedValue.TextColor3 = Color3.fromRGB(120, 255, 170)

	spentValue.Text = formatNumber(TotalSpent)
	spentValue.TextColor3 = Color3.fromRGB(255, 140, 140)

	local net = TotalEarned - TotalSpent
	netValue.Text = formatNumber(net)
	netValue.TextColor3 = net >= 0 and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(255, 140, 140)

	-- Small rates need decimals: formatNumber rounds to whole Sheckles,
	-- so a real per-second rate of 0.4 was displaying as a flat 0 and
	-- reading like the tracking was broken.
	local function formatRate(n)
		if math.abs(n) < 100 then
			return string.format("%.2f", n)
		end
		return formatNumber(n)
	end

	local rate = elapsed > 0 and (net / elapsed) or 0
	perSecValue.Text = formatRate(rate)
	perMinValue.Text = formatRate(rate * 60)
	perHourValue.Text = formatRate(rate * 3600)
	perDayValue.Text = formatRate(rate * 86400)
end

-- Sampling runs every frame, NOT on the UI's refresh interval.
--
-- This used to poll once a second, which silently corrupted the
-- earned/spent split: with auto-buy and auto-sell running, many
-- transactions land inside a single second, and diffing only the
-- endpoints collapses them into one net figure. Earn 1,000 and spend
-- 800 in the same tick and it recorded +200 earned, 0 spent — both
-- totals wrong, while the net still looked plausible, which is what
-- made it hard to notice.
--
-- Reading a table field per frame is cheap; the expensive part is
-- redrawing text, so that stays on a slower loop below.
game:GetService("RunService").Heartbeat:Connect(function()
	local current = getCurrentSheckles()
	if not current then return end
	if lastSheckles then
		local delta = current - lastSheckles
		if delta > 0 then
			TotalEarned += delta
		elseif delta < 0 then
			TotalSpent += (-delta)
		end
	end
	lastSheckles = current
end)

task.spawn(function()
	while task.wait(0.2) do
		refreshStatsUI()
	end
end)

refreshStatsUI()

--========================================================
-- Start the buy loops
--========================================================
runBuyLoop(SeedsStock, PurchaseSeeds, "Seeds")
runBuyLoop(GearsStock, PurchaseGears, "Gears")
runBuyLoop(CratesStock, PurchaseCrates, "Crates")

--========================================================
-- LOADING SPLASH
--
-- The panel used to appear instantly, half-built, while stock and the
-- plot were still resolving — which read as broken rather than loading.
-- This shows what it's actually waiting for, and the steps tick off
-- against real state, not a timer pretending to be progress.
--========================================================
do
	local TweenService = game:GetService("TweenService")

	local card = Instance.new("Frame")
	card.Name = "Splash"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.new(0.5, 0, 0.5, 0)
	card.Size = UDim2.new(0, 280, 0, 150)
	card.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
	card.BackgroundTransparency = 0.04
	card.BorderSizePixel = 0
	card.Parent = gui

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 16)
	cardCorner.Parent = card

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = Color3.fromRGB(255, 255, 255)
	cardStroke.Transparency = 0.88
	cardStroke.Parent = card

	local brand = Instance.new("TextLabel")
	brand.BackgroundTransparency = 1
	brand.Position = UDim2.new(0, 0, 0, 26)
	brand.Size = UDim2.new(1, 0, 0, 24)
	brand.Font = Enum.Font.GothamBold
	brand.Text = "⚡ Zev Hub"
	brand.TextColor3 = Color3.fromRGB(255, 255, 255)
	brand.TextSize = 18
	brand.Parent = card

	local step = Instance.new("TextLabel")
	step.BackgroundTransparency = 1
	step.Position = UDim2.new(0, 0, 0, 56)
	step.Size = UDim2.new(1, 0, 0, 16)
	step.Font = Enum.Font.Gotham
	step.Text = "Injecting…"
	step.TextColor3 = Color3.fromRGB(180, 180, 185)
	step.TextSize = 12
	step.Parent = card

	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(0.5, 0)
	track.Position = UDim2.new(0.5, 0, 0, 88)
	track.Size = UDim2.new(1, -48, 0, 5)
	track.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
	track.BorderSizePixel = 0
	track.Parent = card

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(120, 255, 170)
	fill.BorderSizePixel = 0
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local hint = Instance.new("TextLabel")
	hint.BackgroundTransparency = 1
	hint.Position = UDim2.new(0, 0, 0, 108)
	hint.Size = UDim2.new(1, 0, 0, 30)
	hint.Font = Enum.Font.Gotham
	hint.Text = ""
	hint.TextColor3 = Color3.fromRGB(130, 130, 135)
	hint.TextSize = 10
	hint.TextWrapped = true
	hint.Parent = card

	task.spawn(function()
		-- Each step waits on the thing it names, with a cap so a world
		-- that never provides one can't hold the panel hostage.
		local steps = {
			{
				label = "Injecting…",
				wait = function() return true end,
			},
			{
				label = "Reading the shop…",
				wait = function() return #SeedsStock:GetChildren() > 0 end,
			},
			{
				label = "Locating your plot…",
				wait = function() return OwnerPlot ~= nil end,
				hint = "Takes a moment on a big farm.",
			},
			{
				label = "Reading your Sheckles…",
				wait = function() return getCurrentSheckles() ~= nil end,
				hint = "Stats need this; everything else works without it.",
			},
		}

		for index, entry in ipairs(steps) do
			step.Text = entry.label
			hint.Text = entry.hint or ""

			local deadline = tick() + 8
			while tick() < deadline and not entry.wait() do
				task.wait(0.1)
			end

			TweenService:Create(fill, TweenInfo.new(0.25), {
				Size = UDim2.new(index / #steps, 0, 1, 0),
			}):Play()
			task.wait(0.15)
		end

		step.Text = "Ready"
		step.TextColor3 = Color3.fromRGB(120, 255, 170)
		hint.Text = ""
		task.wait(0.35)

		-- Fade the card out, bring the panel in.
		frame.Visible = true
		for _, inst in ipairs({ card, cardStroke, brand, step, track, fill, hint }) do
			local property = inst:IsA("UIStroke") and "Transparency"
				or (inst:IsA("TextLabel") and "TextTransparency" or "BackgroundTransparency")
			TweenService:Create(inst, TweenInfo.new(0.35), { [property] = 1 }):Play()
		end
		task.wait(0.4)
		card:Destroy()
	end)
end

setActivePage("Buy")

--========================================================
-- REMOTE CONTROL
--
-- Shows a short link code in the panel. Enter that code at
-- scriptexer's /control page and the site can flip the same
-- switches from your phone or PC, without touching the game.
--
-- Config is a single row in Supabase keyed by the code. The script
-- polls it and applies whatever changed; it also writes back a little
-- status so the site can show what's actually happening in-game.
--========================================================
do
	local HttpService = game:GetService("HttpService")

	local SUPABASE_URL = "https://fscazttvhgwaqxkdphsp.supabase.co"
	local SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZzY2F6dHR2aGd3YXF4a2RwaHNwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1MzI0NTYsImV4cCI6MjEwMTEwODQ1Nn0.WWKLNM6ZQZKF2DVne0diOaT3ZB7apbbbuk1lTH-b4L8"

	-- Executors expose their raw HTTP function under several names.
	local httpRequest = (syn and syn.request)
		or (http and http.request)
		or http_request
		or request

	-- Ambiguous characters are left out so a code read off a screen and
	-- typed on a phone can't turn into a different one.
	local ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	local function makeCode()
		local out = {}
		for _ = 1, 6 do
			local i = math.random(1, #ALPHABET)
			table.insert(out, ALPHABET:sub(i, i))
		end
		return table.concat(out)
	end

	local Code = makeCode()

	local function call(method, path, body)
		if not httpRequest then return nil end
		local ok, res = pcall(httpRequest, {
			Url = SUPABASE_URL .. "/rest/v1/" .. path,
			Method = method,
			Headers = {
				["apikey"] = SUPABASE_KEY,
				["Authorization"] = "Bearer " .. SUPABASE_KEY,
				["Content-Type"] = "application/json",
				["Prefer"] = "resolution=merge-duplicates,return=representation",
			},
			Body = body and HttpService:JSONEncode(body) or nil,
		})
		if not ok or not res then return nil end
		local okDecode, decoded = pcall(function()
			return HttpService:JSONDecode(res.Body)
		end)
		return okDecode and decoded or nil
	end

	--------------------------------------------------------
	-- Applying config from the site.
	--
	-- Every key is optional: the site only sends what it changed, and a
	-- missing key must leave the in-game value alone rather than reset
	-- it to a default.
	--------------------------------------------------------
	local function num(value, current, min, max)
		if type(value) ~= "number" then return current end
		if value < min then return min end
		if value > max then return max end
		return value
	end

	local function bool(value, current)
		if type(value) ~= "boolean" then return current end
		return value
	end

	-- Drive the on-screen widget rather than the variable directly. The
	-- widget's own onChange sets the variable, so the switch and the
	-- value can never disagree — a remote change looks exactly like one
	-- made by hand.
	-- Selection lists arrive as arrays of names. Applying them means
	-- repainting the matching rows too, or the panel would show old
	-- switches over new behaviour.
	local function applySelection(target, names)
		if type(names) ~= "table" then return false end
		for key in pairs(target) do target[key] = nil end
		for _, name in ipairs(names) do
			if type(name) == "string" then target[name] = true end
		end
		return true
	end

	local function applyConfig(config)
		if type(config) ~= "table" then return end

		local function slider(key, value, current, min, max)
			local v = num(value, current, min, max)
			local set = RemoteWidgets[key]
			if set and v ~= current then set(v) end
			return v
		end

		local function switch(key, value, current)
			local v = bool(value, current)
			local set = RemoteWidgets[key]
			if set and v ~= current then set(v) end
			return v
		end

		BuyInterval = slider("buyInterval", config.buyInterval, BuyInterval, 0.001, 10)

		PlantEnabled = switch("plantEnabled", config.plantEnabled, PlantEnabled)
		PlantInterval = slider("plantInterval", config.plantInterval, PlantInterval, 0.001, 10)

		HarvestEnabled = switch("harvestEnabled", config.harvestEnabled, HarvestEnabled)
		HarvestInterval = slider("harvestInterval", config.harvestInterval, HarvestInterval, 0.001, 10)

		SellEnabled = switch("sellEnabled", config.sellEnabled, SellEnabled)
		SellInterval = slider("sellInterval", config.sellInterval, SellInterval, 0.001, 10)

		CollectEnabled = switch("collectEnabled", config.collectEnabled, CollectEnabled)
		CollectEverything = switch("collectEverything", config.collectEverything, CollectEverything)
		CollectReturn = switch("collectReturn", config.collectReturn, CollectReturn)
		CollectDwell = slider("collectDwell", config.collectDwell, CollectDwell, 0.01, 2)

		-- Low power lives further down the file than this block, so it's
		-- driven purely through its widget, which owns the variable.
		if type(config.lowPower) == "boolean" and RemoteWidgets.lowPower then
			RemoteWidgets.lowPower(config.lowPower)
		end

		-- Shop selection, per category.
		local rebuiltBuy = false
		for _, category in ipairs({ "Seeds", "Gears", "Crates" }) do
			local names = config["buy" .. category]
			if applySelection(Selected[category], names) then rebuiltBuy = true end
		end
		if rebuiltBuy and RemoteRepaint.buy then RemoteRepaint.buy() end

		if applySelection(PlantSelected, config.plantSeeds) and RemoteRepaint.plant then
			RemoteRepaint.plant()
		end

		if applySelection(CollectSelected, config.collectItems) and RemoteRepaint.drops then
			RemoteRepaint.drops()
		end

		if applySelection(HarvestExcluded, config.harvestExcluded) and RemoteRepaint.harvestExcluded then
			RemoteRepaint.harvestExcluded()
		end

		if applySelection(Shovel.selected, config.shovelPlants) and RemoteRepaint.shovel then
			RemoteRepaint.shovel()
		end

		Shovel.enabled = switch("shovelEnabled", config.shovelEnabled, Shovel.enabled)
		Shovel.interval = slider("shovelInterval", config.shovelInterval, Shovel.interval, 0.001, 10)

		if config.plantMode == "me" or config.plantMode == "random" or config.plantMode == "fixed" then
			if config.plantMode ~= PlantMode and RemoteRepaint.plantMode then
				RemoteRepaint.plantMode(config.plantMode)
			end
		end
	end

	local function currentStatus()
		-- Raw numbers only: the site formats them itself, so the two
		-- displays can't drift into showing the same figure differently.
		local elapsed = tick() - StatsStartTime
		local net = TotalEarned - TotalSpent
		return {
			place = tostring(game.PlaceId),
			player = Players.LocalPlayer.Name,
			planted = PlantConfirmedCount,
			plantSent = PlantFiredCount,
			lastSeed = PlantLastFired,
			bought = BuyFiredCount,
			plantEnabled = PlantEnabled,
			harvestEnabled = HarvestEnabled,
			sellEnabled = SellEnabled,
			collectEnabled = CollectEnabled,
			statsReady = StatsStartingSheckles ~= nil,
			statsSource = tostring(sheckleSource or "?"),
			elapsed = elapsed,
			earned = TotalEarned,
			spent = TotalSpent,
			net = net,
			perSecond = elapsed > 0 and (net / elapsed) or 0,
			plantMode = PlantMode,
			hasFixedSpot = PlantFixedPosition ~= nil,
			-- Every switch's live value, so the site mirrors the panel
			-- even when it was changed in game rather than remotely.
			settings = {
				buyInterval = BuyInterval,
				plantEnabled = PlantEnabled,
				plantInterval = PlantInterval,
				harvestEnabled = HarvestEnabled,
				harvestInterval = HarvestInterval,
				sellEnabled = SellEnabled,
				sellInterval = SellInterval,
				collectEnabled = CollectEnabled,
				collectEverything = CollectEverything,
				collectReturn = CollectReturn,
				collectDwell = CollectDwell,
				lowPower = RemoteReaders.lowPower and RemoteReaders.lowPower() or false,
				shovelEnabled = Shovel.enabled,
				shovelInterval = Shovel.interval,
			},
			shoveled = Shovel.removed,
			shovelStatus = Shovel.status,
			gardenPlants = Shovel.names,
			fps = RemoteReaders.fps and RemoteReaders.fps() or nil,
			-- The catalogue and the current selections, so the site can
			-- draw the same rows with the same switches rather than
			-- asking you to type item names.
			items = RemoteCatalogue(),
			selected = {
				Seeds = RemoteSelectedList(Selected.Seeds),
				Gears = RemoteSelectedList(Selected.Gears),
				Crates = RemoteSelectedList(Selected.Crates),
				plant = RemoteSelectedList(PlantSelected),
				drops = RemoteSelectedList(CollectSelected),
				harvestExcluded = RemoteSelectedList(HarvestExcluded),
				shovel = RemoteSelectedList(Shovel.selected),
			},
		}
	end

	--------------------------------------------------------
	-- The code label, tucked under the title.
	--------------------------------------------------------
	-- Sits on the title row, right-aligned. It used to be placed just
	-- below the title at y=30, which put it underneath the tab bar at
	-- y=38 — the code was being drawn, just hidden.
	local codeLabel = Instance.new("TextLabel")
	codeLabel.BackgroundTransparency = 1
	codeLabel.AnchorPoint = Vector2.new(1, 0)
	codeLabel.Position = UDim2.new(1, -16, 0, 12)
	codeLabel.Size = UDim2.new(0, 150, 0, 18)
	codeLabel.Font = Enum.Font.Code
	codeLabel.Text = httpRequest and ("code: " .. Code) or "no HTTP"
	codeLabel.TextColor3 = httpRequest and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(255, 140, 140)
	codeLabel.TextSize = 12
	codeLabel.TextXAlignment = Enum.TextXAlignment.Right
	codeLabel.Parent = frame

	if httpRequest then
		-- Register, then poll. Registration is retried by the same loop,
		-- so a hiccup at startup doesn't leave the code dead forever.
		-- A preset starred on the site is applied once at startup,
		-- before the first poll, so a fresh run comes up configured.
		task.spawn(function()
			local rows = call(
				"GET",
				"presets?owner=eq." .. HttpService:UrlEncode(Players.LocalPlayer.Name) .. "&autoload=is.true&select=config&limit=1",
				nil
			)
			if type(rows) == "table" and rows[1] then
				applyConfig(rows[1].config)
			end
		end)

		local registered = false
		task.spawn(function()
			while true do
				if not registered then
					local rows = call("POST", "sessions", {
						{ code = Code, config = {}, status = currentStatus() },
					})
					registered = rows ~= nil
				else
					local rows = call(
						"GET",
						"sessions?code=eq." .. Code .. "&select=config",
						nil
					)
					if type(rows) == "table" and rows[1] then
						applyConfig(rows[1].config)
					end
					-- updated_at has to be written explicitly: the column
					-- only defaults on insert, so without this it kept
					-- the registration time forever and the site read a
					-- healthy script as one that vanished long ago.
					call("PATCH", "sessions?code=eq." .. Code, {
						status = currentStatus(),
						updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
					})
				end
				-- 0.5s, so a switch flipped on the site lands almost
				-- immediately rather than after a visible pause.
				task.wait(0.5)
			end
		end)

		if setclipboard then
			pcall(setclipboard, Code)
		end
	end
end

--========================================================
-- PERFORMANCE — an FPS pill, and a mode that stops drawing the world.
--
-- 3D rendering is what costs frames; the game's own Sheckles display
-- and this panel are 2D, so switching off the world leaves everything
-- you actually watch while farming, at a fraction of the cost.
--========================================================
local LowPower = false

do
	local RunService = game:GetService("RunService")

	local perfGui = Instance.new("ScreenGui")
	perfGui.Name = "ScriptexerPerf"
	perfGui.ResetOnSpawn = false
	perfGui.IgnoreGuiInset = true
	perfGui.Parent = gui.Parent

	local pill = Instance.new("Frame")
	pill.AnchorPoint = Vector2.new(0, 0)
	pill.Position = UDim2.new(0, 18, 0, 18)
	pill.Size = UDim2.new(0, 74, 0, 24)
	pill.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
	pill.BackgroundTransparency = 0.04
	pill.BorderSizePixel = 0
	pill.Parent = perfGui

	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(1, 0)
	pillCorner.Parent = pill

	local pillStroke = Instance.new("UIStroke")
	pillStroke.Color = Color3.fromRGB(255, 255, 255)
	pillStroke.Transparency = 0.88
	pillStroke.Parent = pill

	local fpsLabel = Instance.new("TextLabel")
	fpsLabel.BackgroundTransparency = 1
	fpsLabel.Size = UDim2.new(1, 0, 1, 0)
	fpsLabel.Font = Enum.Font.GothamBold
	fpsLabel.Text = "-- fps"
	fpsLabel.TextColor3 = Color3.fromRGB(230, 230, 235)
	fpsLabel.TextSize = 12
	fpsLabel.Parent = pill

	-- Averaged over the last second rather than 1/delta per frame, which
	-- jitters far too much to read.
	task.spawn(function()
		local frames = 0
		RunService.RenderStepped:Connect(function()
			frames += 1
		end)
		while true do
			local started = tick()
			task.wait(1)
			local fps = frames / math.max(tick() - started, 0.001)
			frames = 0
			RemoteReaders.fps = function() return math.floor(fps + 0.5) end
			fpsLabel.Text = string.format("%d fps", math.floor(fps + 0.5))
			fpsLabel.TextColor3 = fps >= 45 and Color3.fromRGB(120, 255, 170)
				or fps >= 20 and Color3.fromRGB(255, 220, 130)
				or Color3.fromRGB(255, 140, 140)
		end
	end)

	--------------------------------------------------------
	-- Turning the world off.
	--
	-- Set3dRenderingEnabled is the real win and most executors expose
	-- it, but it isn't universal — so the quality/lighting fallbacks
	-- run too, and something still improves either way.
	--------------------------------------------------------
	local Lighting = game:GetService("Lighting")
	local saved = nil

	local function applyLowPower(on)
		pcall(function() RunService:Set3dRenderingEnabled(not on) end)

		pcall(function()
			local userSettings = settings()
			if on then
				saved = saved or {
					quality = userSettings.Rendering.QualityLevel,
					globalShadows = Lighting.GlobalShadows,
					fogEnd = Lighting.FogEnd,
				}
				userSettings.Rendering.QualityLevel = Enum.QualityLevel.Level01
				Lighting.GlobalShadows = false
				Lighting.FogEnd = 9e9
			elseif saved then
				userSettings.Rendering.QualityLevel = saved.quality
				Lighting.GlobalShadows = saved.globalShadows
				Lighting.FogEnd = saved.fogEnd
			end
		end)
	end

	RemoteReaders.lowPower = function() return LowPower end

	RemoteWidgets.lowPower = select(2, createToggleRow(statsPage, 232, "Low power (stop drawing the world)", LowPower, function(state)
		LowPower = state
		applyLowPower(state)
	end))
end

--========================================================
-- HIDE BUTTON — a small draggable pill that shows/hides the panel.
--========================================================
do
	local UIS = game:GetService("UserInputService")

	local toggleGui = Instance.new("ScreenGui")
	toggleGui.Name = "ScriptexerToggle"
	toggleGui.ResetOnSpawn = false
	toggleGui.IgnoreGuiInset = true
	toggleGui.Parent = gui.Parent

	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.Position = UDim2.new(0.5, 0, 0, 12)
	button.Size = UDim2.new(0, 56, 0, 28)
	button.BackgroundColor3 = Color3.fromRGB(14, 14, 16)
	button.BackgroundTransparency = 0.04
	button.AutoButtonColor = false
	button.Font = Enum.Font.GothamBold
	button.Text = "⚡ hide"
	button.TextColor3 = Color3.fromRGB(230, 230, 235)
	button.TextSize = 11
	button.BorderSizePixel = 0
	button.Active = true
	button.Parent = toggleGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.88
	stroke.Parent = button

	-- Dragging and clicking share the same press, so a click is defined
	-- as a press that barely moved. Without this, letting go after
	-- dragging would also toggle the panel.
	local dragging, dragStart, startPos, moved = false, nil, nil, 0

	local function press(input)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		dragging = true
		moved = 0
		dragStart = input.Position
		startPos = button.Position

		input.Changed:Connect(function()
			if input.UserInputState ~= Enum.UserInputState.End then return end
			dragging = false
			if moved <= 6 then
				frame.Visible = not frame.Visible
			end
		end)
	end

	button.InputBegan:Connect(press)

	-- The keybind can toggle the panel too, so the label follows the
	-- panel's actual state rather than only what this button did.
	task.spawn(function()
		while task.wait(0.3) do
			button.Text = frame.Visible and "⚡ hide" or "⚡ show"
		end
	end)

	UIS.InputChanged:Connect(function(input)
		if not dragging then return end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		local delta = input.Position - dragStart
		moved = math.max(moved, math.abs(delta.X) + math.abs(delta.Y))
		button.Position = UDim2.new(
			startPos.X.Scale,
			startPos.X.Offset + delta.X,
			startPos.Y.Scale,
			startPos.Y.Offset + delta.Y
		)
	end)
end

--========================================================
-- SETTINGS PERSISTENCE
--
-- Everything you tick is otherwise lost the moment you rejoin, and this
-- script rejoins often (script switching, server hops, crashes). Saved
-- to the executor's filesystem, so it needs no site and no link code.
--========================================================
do
	local HttpService = game:GetService("HttpService")
	local FILE = "scriptexer_gag2_settings.json"

	local function listOf(set)
		local out = {}
		for name, on in pairs(set or {}) do
			if on then table.insert(out, name) end
		end
		table.sort(out)
		return out
	end

	local function fill(set, names)
		if type(names) ~= "table" then return false end
		for key in pairs(set) do set[key] = nil end
		for _, name in ipairs(names) do
			if type(name) == "string" then set[name] = true end
		end
		return true
	end

	local function snapshot()
		return {
			buyInterval = BuyInterval,
			plantEnabled = PlantEnabled,
			plantInterval = PlantInterval,
			plantMode = PlantMode,
			harvestEnabled = HarvestEnabled,
			harvestInterval = HarvestInterval,
			sellEnabled = SellEnabled,
			sellInterval = SellInterval,
			collectEnabled = CollectEnabled,
			collectEverything = CollectEverything,
			collectReturn = CollectReturn,
			collectDwell = CollectDwell,
			shovelEnabled = Shovel.enabled,
			shovelInterval = Shovel.interval,
			buySeeds = listOf(Selected.Seeds),
			buyGears = listOf(Selected.Gears),
			buyCrates = listOf(Selected.Crates),
			plantSeeds = listOf(PlantSelected),
			collectItems = listOf(CollectSelected),
			harvestExcluded = listOf(HarvestExcluded),
			shovelPlants = listOf(Shovel.selected),
		}
	end

	local function apply(saved)
		if type(saved) ~= "table" then return end

		-- Driven through the widgets so the switches move too, exactly
		-- like a remote change.
		for key, setter in pairs(RemoteWidgets) do
			local value = saved[key]
			if type(value) == "boolean" or type(value) == "number" then
				pcall(setter, value)
			end
		end

		fill(Selected.Seeds, saved.buySeeds)
		fill(Selected.Gears, saved.buyGears)
		fill(Selected.Crates, saved.buyCrates)
		if RemoteRepaint.buy then pcall(RemoteRepaint.buy) end

		if fill(PlantSelected, saved.plantSeeds) and RemoteRepaint.plant then
			pcall(RemoteRepaint.plant)
		end
		if fill(CollectSelected, saved.collectItems) and RemoteRepaint.drops then
			pcall(RemoteRepaint.drops)
		end
		if fill(HarvestExcluded, saved.harvestExcluded) and RemoteRepaint.harvestExcluded then
			pcall(RemoteRepaint.harvestExcluded)
		end
		if fill(Shovel.selected, saved.shovelPlants) and RemoteRepaint.shovel then
			pcall(RemoteRepaint.shovel)
		end

		if saved.plantMode and RemoteRepaint.plantMode then
			pcall(RemoteRepaint.plantMode, saved.plantMode)
		end
	end

	-- Executors vary; every one of these may be missing.
	local canRead = type(readfile) == "function" and type(isfile) == "function"
	local canWrite = type(writefile) == "function"

	if canRead then
		pcall(function()
			if isfile(FILE) then
				apply(HttpService:JSONDecode(readfile(FILE)))
			end
		end)
	end

	if canWrite then
		-- Polled rather than hooked to every widget: one comparison a
		-- second is cheaper than threading a save through dozens of
		-- callbacks, and it catches remote changes for free.
		task.spawn(function()
			local last = nil
			while task.wait(1) do
				local ok, encoded = pcall(function()
					return HttpService:JSONEncode(snapshot())
				end)
				if ok and encoded ~= last then
					last = encoded
					pcall(writefile, FILE, encoded)
				end
			end
		end)
	end
end

--========================================================
-- ERRORS — surfaced in the panel, because there is no console.
--
-- Every silent failure this script has had looked identical to a
-- feature that simply did nothing. LogService reports errors from every
-- thread, including ones inside task.spawn that would otherwise vanish.
--========================================================
do
	local banner = Instance.new("TextButton")
	banner.AnchorPoint = Vector2.new(1, 1)
	banner.Position = UDim2.new(1, -18, 1, -18)
	banner.Size = UDim2.new(0, 300, 0, 46)
	banner.BackgroundColor3 = Color3.fromRGB(40, 14, 16)
	banner.BackgroundTransparency = 0.06
	banner.BorderSizePixel = 0
	banner.Visible = false
	banner.Font = Enum.Font.Code
	banner.Text = ""
	banner.TextColor3 = Color3.fromRGB(255, 160, 160)
	banner.TextSize = 11
	banner.TextWrapped = true
	banner.TextXAlignment = Enum.TextXAlignment.Left
	banner.Parent = gui

	local bannerCorner = Instance.new("UICorner")
	bannerCorner.CornerRadius = UDim.new(0, 10)
	bannerCorner.Parent = banner

	banner.MouseButton1Click:Connect(function()
		banner.Visible = false
	end)

	pcall(function()
		game:GetService("LogService").MessageOut:Connect(function(message, messageType)
			if messageType ~= Enum.MessageType.MessageError then return end
			-- Only ours: the game logs plenty of its own errors and they
			-- are not actionable here.
			if not tostring(message):lower():find("scriptexer") and not tostring(message):find("grow%-a%-garden") then
				return
			end
			banner.Text = "⚠ " .. tostring(message):sub(1, 220) .. "  (tap to dismiss)"
			banner.Visible = true
		end)
	end)
end

--========================================================
-- KEYBIND — RightShift hides/shows the panel.
--========================================================
do
	game:GetService("UserInputService").InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.RightShift then
			frame.Visible = not frame.Visible
		end
	end)
end

--========================================================
-- SURVIVING A REJOIN
--
-- Only the executor can run something the moment a game starts (its
-- autoexec folder), but a teleport or server hop is not a fresh start —
-- it kills every script without touching autoexec. queue_on_teleport
-- runs this again on the other side, so switching servers, hopping, or
-- being sent to another world brings the panel straight back with your
-- saved settings already applied.
--========================================================
do
	local SELF = "https://raw.githubusercontent.com/ForgeApc/scriptEXEr/main/scripts/grow-a-garden-2-autobuy.lua"
	local queue = queue_on_teleport or (syn and syn.queue_on_teleport)

	if type(queue) == "function" then
		pcall(queue, 'loadstring(game:HttpGet("' .. SELF .. '"))()')
	end
end
