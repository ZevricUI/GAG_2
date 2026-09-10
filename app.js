/* ============================================================
   Zev Hub — App logic (hash router + views)
   ============================================================ */

(function () {
  "use strict";

  const app = document.getElementById("app");
  const toast = document.getElementById("toast");
  const yearEl = document.getElementById("year");
  if (yearEl) yearEl.textContent = new Date().getFullYear();

  const DATA = { games: [], executors: [] };
  // Keep a live reference that the admin panel can mutate + re-render.
  async function refreshData() {
    const fresh = await window.Store.load();
    DATA.games = fresh.games;
    DATA.executors = fresh.executors;
  }

  /* ---------- Helpers ---------- */
  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function highlightLoadstring(code) {
    let html = escapeHtml(code);
    html = html.replace(/(--[^\n]*)/g, '<span class="tok-com">$1</span>');
    html = html.replace(/(&quot;[^&]*?&quot;)/g, '<span class="tok-str">$1</span>');
    html = html.replace(/\b(loadstring|game|HttpGet)\b/g, '<span class="tok-fn">$1</span>');
    return html;
  }

  /* Universal Loader — detects the current game via PlaceId and runs
     the best matching script from the Zev Hub catalog. Mirrors loader.lua. */
  const LOADER_SCRIPT = `--[[
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
`;

  /* Build a single exploit card markup. Shared by viewGame and live filtering. */
  function exploitCardHtml(game, e) {
    return `
        <a class="card exploit-card" href="#/game/${game.id}/${e.id}">
          <div class="card-img">
            <span class="img-gradient"></span>
            ${thumbDisplay(e)}
          </div>
          <div class="card-body">
            <div class="exploit-row-head">
              <span class="card-title">${escapeHtml(e.title)}</span>
              ${e.verified
                ? `<span class="verified-badge">✓ Verified</span>`
                : `<span class="unverified-badge">Unverified</span>`}
            </div>
            <span class="card-sub">↓ ${escapeHtml(e.downloads || "—")} · 🛡 Level ${e.level || "—"}</span>
          </div>
        </a>`;
  }

  /* Build the markup for a list of exploits (for a given game). */
  function cardsHtmlStatic(game, list) {
    return list.map((e) => exploitCardHtml(game, e)).join("");
  }

  function showToast(msg) {
    toast.textContent = msg;
    toast.classList.add("show");
    clearTimeout(showToast._t);
    showToast._t = setTimeout(() => toast.classList.remove("show"), 2200);
  }

  async function copyText(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (_) { /* fall through */ }
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      const ok = document.execCommand("copy");
      document.body.removeChild(ta);
      return ok;
    } catch (_) {
      return false;
    }
  }

  /* ---------- Router ---------- */
  function getRoute() {
    let hash = location.hash.replace(/^#/, "");
    if (!hash.startsWith("/")) hash = "/" + hash;
    return hash;
  }

  function navigate(path) {
    if (location.hash !== "#" + path) {
      location.hash = path;
    } else {
      render();
    }
    window.scrollTo({ top: 0, behavior: "smooth" });
    closeMobileNav();
  }

  function setActiveNav(route) {
    // Cover all nav tabs (both nav-links and nav-actions)
    document.querySelectorAll(".nav-tab").forEach((tab) => {
      const r = tab.getAttribute("data-route");
      tab.classList.toggle("active", !!r && r === route);
    });
    positionNavIndicator(route);
  }

  /* Sliding nav indicator — only for nav-links (Home) */
  const navIndicator = document.getElementById("navIndicator");
  function positionNavIndicator(route) {
    const navLinks = document.getElementById("navLinks");
    if (!navIndicator || !navLinks) return;
    if (window.innerWidth <= 820) { navIndicator.classList.remove("visible"); return; }
    const tab = Array.from(navLinks.querySelectorAll(".nav-tab[data-route]")).find(
      (t) => t.getAttribute("data-route") === route
    );
    if (!tab) return;
    const parentRect = navLinks.getBoundingClientRect();
    const rect = tab.getBoundingClientRect();
    navIndicator.style.width = rect.width + "px";
    navIndicator.style.transform = `translate(${rect.left - parentRect.left}px, -50%)`;
    navIndicator.classList.add("visible");
  }

  function initNavHoverIndicator() {
    const navLinks = document.getElementById("navLinks");
    if (!navLinks || !navIndicator) return;
    navLinks.addEventListener("mouseover", (e) => {
      const tab = e.target.closest(".nav-tab[data-route]");
      if (!tab || window.innerWidth <= 820) return;
      const parentRect = navLinks.getBoundingClientRect();
      const rect = tab.getBoundingClientRect();
      navIndicator.style.width = rect.width + "px";
      navIndicator.style.transform = `translate(${rect.left - parentRect.left}px, -50%)`;
    });
    navLinks.addEventListener("mouseleave", () => {
      const active = navLinks.querySelector(".nav-tab.active[data-route]");
      if (active && window.innerWidth > 820) {
        positionNavIndicator(active.getAttribute("data-route"));
      }
    });
  }

  /* ---------- Views ---------- */

  // HOME
  function viewHome(query) {
    const q = (query || "").trim().toLowerCase();
    const games = DATA.games.filter(
      (g) => !q || g.name.toLowerCase().includes(q) || (g.sub || "").toLowerCase().includes(q)
    );

    const cards = games
      .map(
        (g) => `
        <a class="card" href="#/game/${g.id}">
          <div class="card-img">
            <span class="img-gradient" style="background:${g.gradient}"></span>
            ${thumbDisplay(g)}
          </div>
          <div class="card-body">
            <span class="card-title">${escapeHtml(g.name)}</span>
            <span class="card-sub">${escapeHtml(g.sub || "")}</span>
            <span class="card-badge">${g.exploits.length} script${g.exploits.length === 1 ? "" : "s"}</span>
          </div>
        </a>`
      )
      .join("");

    const gridHtml = games.length
      ? `<div class="grid grid-games">${cards}</div>`
      : `<div class="empty-state">
           <span class="emoji">🔍</span>
           <p>No games found for "<strong>${escapeHtml(query)}</strong>". Try another name.</p>
         </div>`;

    return `
      <section class="view">
        <div class="page-hero">
          <span class="eyebrow">Zev Hub · Library</span>
          <h1>Find the perfect script</h1>
          <p>Search thousands of Roblox scripts by game name. Copy a loadstring and you're ready to run.</p>
        </div>
        <div class="search-wrap">
          <svg class="search-icon" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>
          <input id="search" class="search-input" type="text" placeholder="Search by game name… (e.g. Blox Fruits)" autocomplete="off" value="${escapeHtml(query || "")}" />
        </div>
        <p class="section-label">${q ? "Results" : "Popular games"} · ${games.length}</p>
        ${gridHtml}
      </section>`;
  }

  // GAME DETAIL — grid of exploit cards
  function viewGame(gameId) {
    const game = DATA.games.find((g) => g.id === gameId);
    if (!game) return notFound("Game");

    const gridHtml = game.exploits.length
      ? `<div class="game-search">
           <svg class="game-search-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>
           <input id="exploit-search" class="game-search-input" type="text" placeholder="Search scripts in ${escapeHtml(game.name)}…" autocomplete="off" />
         </div>
         <p class="section-label" id="exploit-count">Available scripts · ${game.exploits.length}</p>
         <div class="grid grid-exploits" id="exploits-grid">${cardsHtmlStatic(game, game.exploits)}</div>`
      : `<div class="empty-state"><span class="emoji">📦</span><p>No scripts available for this game yet.</p></div>`;

    return `
      <section class="view">
        <a class="back-btn" href="#/">← Back to games</a>
        <div class="detail-header">
          <div class="detail-thumb glass">
            <span class="img-gradient" style="position:absolute;inset:0;border-radius:18px;opacity:0.85"></span>
            <span style="position:relative">${thumbDisplay(game)}</span>
          </div>
          <div class="detail-title-block">
            <h1>${escapeHtml(game.name)}</h1>
            <p>${escapeHtml(game.sub || "")} · ${game.exploits.length} exploit${game.exploits.length === 1 ? "" : "s"} available</p>
          </div>
        </div>
        ${gridHtml}
      </section>`;
  }

  // EXPLOIT DETAIL — two-column layout
  function viewExploit(gameId, exploitId) {
    const game = DATA.games.find((g) => g.id === gameId);
    if (!game) return notFound("Game");
    const exploit = game.exploits.find((e) => e.id === exploitId);
    if (!exploit) return notFound("Exploit");

    const reqList = exploit.requirements && exploit.requirements.length
      ? `<div class="detail-panel glass">
          <h2>Requirements</h2>
          <ul class="req-list">
            ${exploit.requirements.map((r) => `<li>${escapeHtml(r)}</li>`).join("")}
          </ul>
        </div>`
      : "";

    return `
      <section class="view">
        <a class="back-btn" href="#/game/${game.id}">← Back to ${escapeHtml(game.name)}</a>

        <div class="detail-header">
          <div class="detail-thumb glass">
            <span class="img-gradient" style="position:absolute;inset:0;border-radius:18px;opacity:0.85"></span>
            <span style="position:relative">${thumbDisplay(exploit)}</span>
          </div>
          <div class="detail-title-block">
            <div class="detail-tags">
              ${exploit.verified
                ? `<span class="tag tag-verified">✓ Verified</span>`
                : `<span class="tag">Unverified</span>`}
              <span class="tag tag-level">🛡 Level ${exploit.level || "—"}</span>
              <span class="tag tag-strong">${escapeHtml(game.name)}</span>
            </div>
            <h1>${escapeHtml(exploit.title)}</h1>
            <p>↓ ${escapeHtml(exploit.downloads || "—")} downloads · Updated ${escapeHtml(exploit.updated || "—")}</p>
          </div>
        </div>

        <div class="detail-grid">
          <div class="detail-col">
            <div class="detail-panel glass">
              <h2>About this script</h2>
              <p>${escapeHtml(exploit.description)}</p>
            </div>

            <div class="detail-panel glass">
              <h2>Loadstring</h2>
              <p style="margin-bottom:14px;color:var(--text-dim);font-size:0.88rem">Paste this into your executor and press Execute.</p>
              <div class="code-block">
                <div class="code-block-header">
                  <span class="code-label">
                    <span class="code-dots"><span></span><span></span><span></span></span>
                    Lua
                  </span>
                  <button class="copy-btn" id="copyBtn" aria-label="Copy loadstring">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
                    <span class="copy-label">Copy</span>
                  </button>
                </div>
                <pre><code id="loadstringCode">${highlightLoadstring(exploit.loadstring)}</code></pre>
              </div>
            </div>
          </div>

          <div class="detail-col">
            <div class="detail-panel glass">
              <h2>Details</h2>
              <ul class="detail-stats">
                <li><span>Status</span><strong>${exploit.verified ? "✓ Verified" : "Unverified"}</strong></li>
                <li><span>UNC Level</span><strong>${exploit.level || "—"}</strong></li>
                <li><span>Downloads</span><strong>${escapeHtml(exploit.downloads || "—")}</strong></li>
                <li><span>Last updated</span><strong>${escapeHtml(exploit.updated || "—")}</strong></li>
                <li><span>Game</span><strong>${escapeHtml(game.name)}</strong></li>
              </ul>
            </div>
            ${reqList}
          </div>
        </div>
      </section>`;
  }

  // EXECUTORS grid
  function viewExecutors() {
    const cards = DATA.executors
      .map(
        (ex) => `
        <a class="card executor-card" href="#/executor/${ex.id}">
          <div class="executor-img">
            <span class="img-gradient" style="position:absolute;inset:0;background:${ex.gradient};opacity:0.6"></span>
            <span style="position:relative">${thumbDisplay(ex)}</span>
          </div>
          <div class="card-body" style="align-items:center;text-align:center">
            <span class="card-title">${escapeHtml(ex.name)}</span>
            <span class="card-sub">View details & download</span>
          </div>
        </a>`
      )
      .join("");

    return `
      <section class="view">
        <div class="page-hero">
          <span class="eyebrow">Zev Hub · Tools</span>
          <h1>Roblox Executors</h1>
          <p>Trusted executors to run your scripts. Pick one, view the specs, and download.</p>
        </div>
        <p class="section-label">All executors · ${DATA.executors.length}</p>
        <div class="grid grid-executors">${cards}</div>
      </section>`;
  }

  // UNIVERSAL LOADER
  const LOADER_URL = "https://raw.githubusercontent.com/ForgeApc/scriptEXEr/main/loader.lua";
  const LOADER_LOADSTRING = `loadstring(game:HttpGet("${LOADER_URL}"))()`;

  function viewLoader() {
    return `
      <section class="view">
        <div class="page-hero">
          <span class="eyebrow">Zev Hub · Tools</span>
          <h1>Universal Loader</h1>
          <p>One line for every game. Paste it into your executor — it detects which Roblox game you're in and automatically runs the best script for it.</p>
        </div>

        <div class="detail-panel glass">
          <h2>Loadstring</h2>
          <p style="margin-bottom:14px;color:var(--text-dim);font-size:0.88rem">
            Paste this single line into your executor and press Execute. It fetches the latest loader straight from Zev Hub every time you run it.
          </p>
          <div class="code-block">
            <div class="code-block-header">
              <span class="code-label">
                <span class="code-dots"><span></span><span></span><span></span></span>
                Lua
              </span>
              <button class="copy-btn" id="loaderLoadstringCopyBtn" aria-label="Copy loadstring">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
                <span class="copy-label">Copy</span>
              </button>
            </div>
            <pre><code id="loaderLoadstringCode">${highlightLoadstring(LOADER_LOADSTRING)}</code></pre>
          </div>
        </div>

        <div class="detail-panel glass">
          <h2>How it works</h2>
          <p style="margin-bottom:14px;color:var(--text-dim);font-size:0.88rem">
            The loader reads <code>game.PlaceId</code>, looks it up against the Zev Hub catalog, and runs the verified script with the most downloads for that game. If a game has no scripts yet, it'll tell you instead of failing silently. Expand the <strong>Scripts ▾</strong> panel to see every script registered for the game you're in.
          </p>
          <p style="color:var(--text-dim);font-size:0.88rem">
            <strong>Switching scripts rejoins the server.</strong> That's intentional, not a bug — most real scripts spawn their own background loops the moment they run, completely outside anything a loader can control, so there's no generic way to "unload" one without a fresh game session. A rejoin is the only thing that reliably guarantees the previous script is fully stopped before the next one starts.
          </p>
        </div>

        <div class="detail-panel glass">
          <h2>Requirements</h2>
          <ul class="req-list">
            <li>Any executor supporting UNC-level HttpGet or a raw HTTP request function (syn.request / http.request / http_request / request)</li>
            <li>Stable internet connection</li>
            <li>The game must have at least one script added on the admin panel, with its Roblox Place ID set</li>
            <li>To have your chosen script resume automatically after switching, add this loadstring to your executor's Auto Execute list for the game — otherwise just re-run it manually after the rejoin</li>
          </ul>
        </div>

        <div class="detail-panel glass">
          <div class="code-block-header" style="margin-bottom:12px">
            <h2 style="margin:0">Full source</h2>
            <button class="copy-btn" id="loaderCopyBtn" aria-label="Copy loader script">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
              <span class="copy-label">Copy</span>
            </button>
          </div>
          <p style="margin-bottom:14px;color:var(--text-dim);font-size:0.88rem">
            This is exactly what the loadstring above fetches and runs — nothing hidden. Read it, or paste it directly into your executor instead of using the loadstring.
          </p>
          <div class="code-block">
            <div class="code-block-header">
              <span class="code-label">
                <span class="code-dots"><span></span><span></span><span></span></span>
                Lua
              </span>
            </div>
            <pre><code id="loaderCode">${highlightLoadstring(LOADER_SCRIPT)}</code></pre>
          </div>
        </div>
      </section>`;
  }

  /* ---------- Remote control ---------- */

  // The tab layout mirrors the in-game panel exactly — same tabs, same
  // order, same controls on each — so the site is the script, remotely.
  const CONTROL_TABS = [
    {
      name: "Buy",
      controls: [
        { key: "buyInterval", label: "Buy interval", type: "slider", min: 0.001, max: 10, step: 0.001, unit: "s" },
      ],
      // Sub-tabs, bulk buttons and per-item switches, same as in game.
      list: "buy",
    },
    {
      name: "Plant",
      controls: [
        { key: "plantEnabled", label: "Enable Auto Plant", type: "toggle" },
        { key: "plantInterval", label: "Plant delay", type: "slider", min: 0.001, max: 10, step: 0.001, unit: "s" },
      ],
      modes: true,
      list: "plant",
    },
    {
      name: "Shovel",
      controls: [
        { key: "shovelEnabled", label: "Enable Auto Shovel", type: "toggle" },
        { key: "shovelInterval", label: "Shovel delay", type: "slider", min: 0.001, max: 10, step: 0.001, unit: "s" },
      ],
      shovel: true,
      list: "shovel",
    },
    {
      name: "Drops",
      controls: [
        { key: "collectEnabled", label: "Enable Auto Collect", type: "toggle" },
        { key: "collectReturn", label: "Return to my spot after", type: "toggle" },
        { key: "collectEverything", label: "Collect everything dropped", type: "toggle" },
        { key: "collectDwell", label: "Pickup dwell", type: "slider", min: 0.01, max: 2, step: 0.01, unit: "s" },
      ],
      list: "drops",
    },
    {
      name: "Harvest",
      controls: [
        { key: "harvestEnabled", label: "Enable Auto Harvest", type: "toggle" },
        { note: "Harvests ripe crops first, then attempts still-growing ones too." },
        { key: "harvestInterval", label: "Harvest delay", type: "slider", min: 0.001, max: 10, step: 0.001, unit: "s" },
      ],
      list: "harvest",
    },
    {
      name: "Sell",
      controls: [
        { key: "sellEnabled", label: "Enable Auto Sell", type: "toggle" },
        { key: "sellInterval", label: "Sell delay", type: "slider", min: 0.001, max: 10, step: 0.001, unit: "s" },
      ],
    },
    {
      name: "Stats",
      stats: true,
      controls: [{ key: "lowPower", label: "Low power (stop drawing the world)", type: "toggle" }],
    },
    { name: "Presets", presets: true },
  ];

  // Same formatting rules as the script's Stats tab, so a number never
  // reads one way in game and another way here.
  function hudNumber(n) {
    if (typeof n !== "number" || !isFinite(n)) return "—";
    return Math.round(n).toLocaleString("en-US");
  }
  function hudRate(n) {
    if (typeof n !== "number" || !isFinite(n)) return "—";
    return Math.abs(n) < 100 ? n.toFixed(2) : hudNumber(n);
  }
  function hudElapsed(seconds) {
    if (typeof seconds !== "number" || !isFinite(seconds)) return "—";
    const s = Math.floor(seconds);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    return h > 0 ? `${h}h ${m}m ${s % 60}s` : m > 0 ? `${m}m ${s % 60}s` : `${s}s`;
  }

  function hudControlHtml(control, config) {
    if (control.note) return `<div class="hud-note">${escapeHtml(control.note)}</div>`;
    const value = config[control.key];
    if (control.type === "toggle") {
      return `
        <div class="hud-row">
          <span class="hud-row-label">${escapeHtml(control.label)}</span>
          <button class="hud-toggle${value ? " on" : ""}" data-control="${control.key}" data-type="toggle"
                  role="switch" aria-checked="${!!value}" aria-label="${escapeHtml(control.label)}">
            <span class="hud-knob"></span>
          </button>
        </div>`;
    }
    const current = typeof value === "number" ? value : control.min;
    return `
      <div class="hud-slider-row">
        <div class="hud-slider-head">
          <span class="hud-row-label">${escapeHtml(control.label)} (${control.unit}):</span>
          <input class="hud-value" type="text" data-box="${control.key}" value="${current.toFixed(3)}">
        </div>
        <input class="hud-range" type="range" data-control="${control.key}" data-type="slider"
               min="${control.min}" max="${control.max}" step="${control.step}" value="${current}">
      </div>`;
  }

  function hudStatsHtml(status) {
    const s = status || {};
    const rate = typeof s.perSecond === "number" ? s.perSecond : null;
    const rows = [
      ["FPS", typeof s.fps === "number" ? String(s.fps) : "—", s.fps >= 45 ? "good" : s.fps >= 20 ? "" : "bad"],
      ["Elapsed time", hudElapsed(s.elapsed), ""],
      ["Earned so far", hudNumber(s.earned), "good"],
      ["Spent so far", hudNumber(s.spent), "bad"],
      ["Net so far", hudNumber(s.net), (s.net || 0) >= 0 ? "good" : "bad"],
      ["Per second", hudRate(rate), ""],
      ["Per minute", hudRate(rate === null ? null : rate * 60), ""],
      ["Per hour", hudRate(rate === null ? null : rate * 3600), ""],
      ["Per day", hudRate(rate === null ? null : rate * 86400), ""],
    ];
    const head = s.statsReady
      ? `<div class="hud-note good">Tracking · ${escapeHtml(s.statsSource || "?")}</div>`
      : `<div class="hud-note bad">Exact Sheckles value not found — Stats unavailable</div>`;
    return (
      head +
      rows
        .map(
          ([label, value, tone]) => `
        <div class="hud-stat">
          <span class="hud-row-label">${label}</span>
          <span class="hud-stat-value ${tone}">${value}</span>
        </div>`
        )
        .join("")
    );
  }

  // The selectable rows for a tab, drawn from the catalogue the script
  // publishes — real in-game item names and live stock, not a guess.
  function hudListItems(kind, status, subTab) {
    const items = (status && status.items) || {};
    if (kind === "buy") {
      const cats = subTab === "All" ? ["Seeds", "Gears", "Crates"] : [subTab];
      const out = [];
      cats.forEach((cat) => {
        (items[cat] || []).forEach((it) =>
          out.push({ name: it.name, category: cat, inStock: it.inStock })
        );
      });
      return out;
    }
    // Shovel lists what's growing on the plot, not the shop: you can
    // only dig up what you planted.
    if (kind === "shovel") {
      return ((status && status.gardenPlants) || []).map((name) => ({ name, category: "Garden" }));
    }
    // Plant, Drops and Harvest all list seeds.
    return (items.Seeds || []).map((it) => ({ name: it.name, category: "Seeds" }));
  }

  function hudSelectedSet(kind, status, subTab) {
    const sel = (status && status.selected) || {};
    if (kind === "plant") return new Set(sel.plant || []);
    if (kind === "drops") return new Set(sel.drops || []);
    if (kind === "harvest") return new Set(sel.harvestExcluded || []);
    if (kind === "shovel") return new Set(sel.shovel || []);
    const cats = subTab === "All" ? ["Seeds", "Gears", "Crates"] : [subTab];
    const set = new Set();
    cats.forEach((cat) => (sel[cat] || []).forEach((n) => set.add(cat + "\u0000" + n)));
    return set;
  }

  function hudListHtml(kind, status, subTab) {
    const query = (controlState.query[kind] || "").toLowerCase();
    const items = hudListItems(kind, status, subTab).filter(
      (it) => !query || it.name.toLowerCase().includes(query)
    );
    const selected = hudSelectedSet(kind, status, subTab);
    if (!hudListItems(kind, status, subTab).length) {
      return `<div class="hud-note">${
        kind === "shovel"
          ? "Nothing growing on your plot yet."
          : "Waiting for the script's item list…"
      }</div>`;
    }
    const subTabs =
      kind === "buy"
        ? `<div class="hud-subtabs">${["All", "Seeds", "Gears", "Crates"]
            .map(
              (t) =>
                `<button class="hud-pill${t === subTab ? " active" : ""}" data-subtab="${t}">${t}</button>`
            )
            .join("")}</div>`
        : "";
    const heading =
      kind === "harvest"
        ? `<div class="hud-note">Don't harvest these:</div>`
        : kind === "shovel"
        ? `<div class="hud-note">Dig up these crops:</div>`
        : "";
    const bulk = `
      <div class="hud-bulk">
        <button class="hud-pill" data-bulk="all">${kind === "harvest" ? "Exclude All" : "Select All"}</button>
        <button class="hud-pill" data-bulk="none">None</button>
        ${kind === "buy"
          ? ["Seeds", "Gears", "Crates"]
              .map((c) => `<button class="hud-pill" data-bulk="cat:${c}">All ${c}</button>`)
              .join("")
          : ""}
        <input class="hud-preset-name" type="search" data-search="${kind}"
               placeholder="Search…" value="${escapeHtml(controlState.query[kind] || "")}">
      </div>`;
    const rows = items
      .map((it) => {
        const id = kind === "buy" ? it.category + "\u0000" + it.name : it.name;
        const on = selected.has(id);
        return `
        <div class="hud-item">
          <span class="hud-item-name">${escapeHtml(it.name)}</span>
          ${it.inStock === undefined
            ? ""
            : `<span class="hud-stock ${it.inStock ? "in" : "out"}">${it.inStock ? "In stock" : "Out of stock"}</span>`}
          <button class="hud-toggle${on ? (kind === "harvest" || kind === "shovel" ? " on exclude" : " on") : ""}" data-item="${escapeHtml(it.name)}"
                  data-category="${it.category}" role="switch" aria-checked="${on}"
                  aria-label="${escapeHtml(it.name)}"><span class="hud-knob"></span></button>
        </div>`;
      })
      .join("");
    return (
      heading +
      subTabs +
      bulk +
      `<div class="hud-list">${rows || `<div class="hud-note">Nothing matches that search.</div>`}</div>`
    );
  }

  function hudModesHtml(status) {
    const current = (status && status.plantMode) || "me";
    const modes = [
      ["me", "At me"],
      ["random", "Random"],
      ["fixed", "Fixed"],
    ];
    return `
      <div class="hud-bulk">
        ${modes
          .map(
            ([key, label]) =>
              `<button class="hud-pill${key === current ? " active" : ""}" data-mode="${key}">${label}</button>`
          )
          .join("")}
      </div>
      ${current === "fixed" && !(status && status.hasFixedSpot)
        ? `<div class="hud-note bad">No fixed spot set — pin one from the in-game panel.</div>`
        : ""}`;
  }

  function hudPresetsHtml(status) {
    const owner = (status && status.player) || null;
    if (!owner) {
      return `<div class="hud-note">Link a running script first — presets are saved per player.</div>`;
    }
    const rows = controlState.presets
      .map(
        (preset) => `
        <div class="hud-item">
          <span class="hud-item-name">${escapeHtml(preset.name)}</span>
          <button class="hud-pill${preset.autoload ? " active" : ""}" data-autoload="${preset.id}"
                  title="Apply this automatically when the script starts">${preset.autoload ? "★ Auto" : "☆ Auto"}</button>
          <button class="hud-pill" data-load="${preset.id}">Load</button>
          <button class="hud-pill" data-delete="${preset.id}">✕</button>
        </div>`
      )
      .join("");
    return `
      <div class="hud-note">Saved for ${escapeHtml(owner)}. The ★ preset is applied automatically when the script starts.</div>
      <div class="hud-bulk">
        <input class="hud-preset-name" id="presetName" type="text" placeholder="Preset name" maxlength="40">
        <button class="hud-pill active" data-save="1">Save current</button>
      </div>
      <div class="hud-list">${rows || `<div class="hud-note">No presets saved yet.</div>`}</div>`;
  }

  function hudShovelHtml(status) {
    const s = status || {};
    const found = (s.shoveled || 0) > 0;
    return `<div class="hud-note ${found ? "good" : ""}">Dug up: ${s.shoveled || 0} · ${escapeHtml(s.shovelStatus || "idle")}</div>`;
  }

  function hudHtml(config, status, activeTab) {
    const tab = CONTROL_TABS.find((t) => t.name === activeTab) || CONTROL_TABS[0];
    return `
      <div class="hud-panel">
        <div class="hud-title">⚡ Zev Hub</div>
        <div class="hud-code" id="hudCode">—</div>
        <div class="hud-tabs">
          ${CONTROL_TABS.map(
            (t) =>
              `<button class="hud-tab${t.name === tab.name ? " active" : ""}" data-tab="${t.name}">${t.name}</button>`
          ).join("")}
        </div>
        <div class="hud-body">
          ${tab.stats
            ? hudStatsHtml(status) + (tab.controls || []).map((c) => hudControlHtml(c, config)).join("")
            : tab.presets
            ? hudPresetsHtml(status)
            : (tab.controls || []).map((c) => hudControlHtml(c, config)).join("") +
              (tab.modes ? hudModesHtml(status) : "") +
              (tab.shovel ? hudShovelHtml(status) : "") +
              (tab.list ? hudListHtml(tab.list, status, controlState.subTab) : "")}
        </div>
      </div>`;
  }

  function viewControl() {
    const saved = localStorage.getItem("scriptexer_control_code") || "";
    return `
      <section class="view">
        <div class="page-hero">
          <span class="eyebrow">Zev Hub · Tools</span>
          <h1>Remote Control</h1>
          <p>Your script shows a short link code in its panel. Enter it here to drive the exact same panel from anywhere — same tabs, same switches, live stats.</p>
        </div>

        <div class="detail-panel glass">
          <h2>Link a script</h2>
          <div class="control-link-row">
            <input type="text" id="controlCode" class="admin-input" placeholder="Link code (e.g. K7QP2M)"
                   maxlength="6" autocomplete="off" spellcheck="false" value="${escapeHtml(saved)}">
            <button class="admin-btn" id="controlLinkBtn">Link</button>
          </div>
          <p class="control-status" id="controlStatus">Not linked yet.</p>
        </div>

        <div id="controlPanels"></div>
      </section>`;
  }

  // Live state for the control page. Kept out of the DOM so a re-render
  // never loses which session we're talking to or which tab you're on.
  const controlState = { code: null, config: {}, status: {}, tab: "Buy", subTab: "All", presets: [], query: {}, timer: null };

  function renderControlStatus(session) {
    const el = document.getElementById("controlStatus");
    if (!el) return;
    if (!session) {
      el.textContent = "No script is linked to that code. Check it's still running.";
      el.className = "control-status bad";
      return;
    }
    const s = session.status || {};
    const age = session.updated_at
      ? Math.round((Date.now() - new Date(session.updated_at).getTime()) / 1000)
      : null;
    const parts = [`Linked to ${s.player || "unknown player"}`];
    if (s.planted !== undefined) parts.push(`${s.planted} planted`);
    if (s.bought !== undefined) parts.push(`${s.bought} bought`);
    // A stale heartbeat is the difference between "your settings will
    // apply" and "you're editing a row nothing is reading."
    // While the heartbeat is fresh, how long it has been running is the
    // useful number; "last seen" only means anything once it stops.
    if (age !== null) {
      parts.push(age < 4 ? `working for ${hudElapsed(s.elapsed)}` : `last seen ${age}s ago`);
    }
    el.textContent = parts.join(" · ");
    el.className = "control-status" + (age !== null && age < 4 ? " good" : " bad");
  }

  // A cheap fingerprint of what the panel is currently showing, so a
  // selection changed from inside the game gets picked up on the next
  // poll without repainting (and fighting) anything else.
  function hudSelectionSignature() {
    const st = controlState.status;
    const sel = st.selected || {};
    // Settings are in here too: a switch flipped inside the game has to
    // show up on the site the same way a remote change does.
    return JSON.stringify([sel.Seeds, sel.Gears, sel.Crates, sel.plant, sel.drops, sel.harvestExcluded, sel.shovel, st.gardenPlants, st.plantMode, st.settings]);
  }

  function paintHud(rebuild) {
    const panels = document.getElementById("controlPanels");
    if (!panels) return;
    const onStats = controlState.tab === "Stats";
    const signature = hudSelectionSignature();
    if (!rebuild && signature !== controlState.signature && !controlState.dragging) {
      rebuild = true;
    }
    controlState.signature = signature;
    // Controls are rebuilt only on demand — repainting them under a
    // finger mid-drag would fight the user. Stats are read-only, so
    // they refresh every poll.
    if (rebuild || onStats) {
      const focused = document.activeElement;
      const refocus = focused && focused.hasAttribute && focused.hasAttribute("data-search")
        ? focused.getAttribute("data-search")
        : null;

      panels.innerHTML = hudHtml(controlState.config, controlState.status, controlState.tab);
      const code = document.getElementById("hudCode");
      if (code) code.textContent = "link code: " + (controlState.code || "—");

      // A rebuild replaces the very input being typed into, so put the
      // caret back or the search box loses focus on every keystroke.
      if (refocus) {
        const box = panels.querySelector(`[data-search="${refocus}"]`);
        if (box) {
          box.focus();
          const end = box.value.length;
          try {
            box.setSelectionRange(end, end);
          } catch (_) {
            /* type=search may reject setSelectionRange in some browsers */
          }
        }
      }
    }
  }

  async function refreshControl(code, rebuild) {
    let session;
    try {
      session = await Control.fetchSession(code);
    } catch (e) {
      renderControlStatus(null);
      return;
    }
    renderControlStatus(session);
    if (!session) return;

    controlState.code = code;
    controlState.status = session.status || {};
    if (rebuild) {
      localStorage.setItem("scriptexer_control_code", code);
    }
    // The script is the source of truth: whatever it reports is what the
    // site shows, so changes made on the in-game panel appear here on
    // their own. Our config copy only carries writes still in flight.
    controlState.config = Object.assign(
      {},
      session.config || {},
      controlState.status.settings || {}
    );

    // Drop pending selection writes the script has confirmed, so its
    // own state takes over again and an in-game change isn't masked by
    // a stale local copy.
    const sel = controlState.status.selected || {};
    const confirmed = {
      buySeeds: sel.Seeds,
      buyGears: sel.Gears,
      buyCrates: sel.Crates,
      plantSeeds: sel.plant,
      collectItems: sel.drops,
      harvestExcluded: sel.harvestExcluded,
      shovelPlants: sel.shovel,
    };
    Object.keys(confirmed).forEach((key) => {
      const pending = controlState.config[key];
      if (Array.isArray(pending) && JSON.stringify(pending.slice().sort()) === JSON.stringify((confirmed[key] || []).slice().sort())) {
        delete controlState.config[key];
      }
    });

    paintHud(rebuild);

    // Presets belong to the player, which we only learn from a linked
    // script — so they're fetched once the link resolves, not on load.
    const owner = controlState.status.player;
    if (owner && owner !== controlState.presetOwner) {
      controlState.presetOwner = owner;
      refreshPresets();
    }
  }

  async function refreshPresets() {
    const owner = controlState.presetOwner;
    if (!owner) return;
    try {
      controlState.presets = await Presets.list(owner);
    } catch (e) {
      controlState.presets = [];
    }
    if (controlState.tab === "Presets") paintHud(true);
  }

  // Save / load / delete / autoload. Saving captures the script's own
  // reported settings and selections, not our local copy, so a preset
  // records what the game is actually doing.
  async function handlePresetClick(btn, panels) {
    const owner = controlState.presetOwner;
    if (!owner) return;

    try {
      if (btn.hasAttribute("data-save")) {
        const input = panels.querySelector("#presetName");
        const name = (input && input.value.trim()) || "";
        if (!name) {
          showToast("Give the preset a name first");
          return;
        }
        const st = controlState.status;
        const sel = st.selected || {};
        const config = Object.assign({}, st.settings || {}, {
          plantMode: st.plantMode,
          buySeeds: sel.Seeds || [],
          buyGears: sel.Gears || [],
          buyCrates: sel.Crates || [],
          plantSeeds: sel.plant || [],
          collectItems: sel.drops || [],
          harvestExcluded: sel.harvestExcluded || [],
          shovelPlants: sel.shovel || [],
        });
        await Presets.save(owner, name, config);
        if (input) input.value = "";
        showToast(`Saved "${name}"`);
      } else if (btn.hasAttribute("data-load")) {
        const preset = controlState.presets.find((p) => p.id === btn.getAttribute("data-load"));
        if (!preset) return;
        await Control.updateConfig(controlState.code, preset.config);
        showToast(`Loaded "${preset.name}"`);
      } else if (btn.hasAttribute("data-delete")) {
        await Presets.remove(btn.getAttribute("data-delete"));
      } else if (btn.hasAttribute("data-autoload")) {
        const id = btn.getAttribute("data-autoload");
        const already = controlState.presets.find((p) => p.id === id && p.autoload);
        // Clicking the current ★ clears it, so autoload can be turned off.
        await Presets.setAutoload(owner, already ? null : id);
      }
      await refreshPresets();
      paintHud(true);
    } catch (err) {
      showToast(err.message || "Preset action failed");
    }
  }

  function bindControlEvents() {
    const linkBtn = document.getElementById("controlLinkBtn");
    const codeInput = document.getElementById("controlCode");
    if (!linkBtn || !codeInput) return;

    const link = () => {
      const code = codeInput.value.trim().toUpperCase();
      if (!code) return;
      refreshControl(code, true);
      clearInterval(controlState.timer);
      // Matches the script's own poll, so a change made in game shows
      // here about as fast as one made here reaches the game.
      controlState.timer = setInterval(() => refreshControl(code, false), 500);
    };

    linkBtn.addEventListener("click", link);
    codeInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") link();
    });
    if (codeInput.value.trim()) link();

    const panels = document.getElementById("controlPanels");
    if (!panels) return;

    const send = async (key, value) => {
      if (!controlState.code) return;
      controlState.config[key] = value;
      try {
        await Control.updateConfig(controlState.code, { [key]: value });
      } catch (e) {
        showToast(e.message || "Couldn't reach the script");
      }
    };

    // Selections live in status (the script owns them) but are sent as
    // config. Keep a local copy so a click shows immediately instead of
    // waiting out the next poll.
    const selectionKey = (kind, category) =>
      kind === "buy"
        ? "buy" + category
        : kind === "plant"
        ? "plantSeeds"
        : kind === "harvest"
        ? "harvestExcluded"
        : kind === "shovel"
        ? "shovelPlants"
        : "collectItems";

    const currentSelection = (kind, category) => {
      const key = selectionKey(kind, category);
      if (Array.isArray(controlState.config[key])) return controlState.config[key].slice();
      const sel = controlState.status.selected || {};
      const fromStatus =
        kind === "buy"
          ? sel[category]
          : kind === "plant"
          ? sel.plant
          : kind === "harvest"
          ? sel.harvestExcluded
          : kind === "shovel"
          ? sel.shovel
          : sel.drops;
      return (fromStatus || []).slice();
    };

    const setSelection = (kind, category, names) => {
      const key = selectionKey(kind, category);
      controlState.config[key] = names;
      send(key, names);
    };

    const listKind = () => {
      const tab = CONTROL_TABS.find((t) => t.name === controlState.tab);
      return tab && tab.list;
    };

    panels.addEventListener("click", (e) => {
      const tabBtn = e.target.closest("[data-tab]");
      if (tabBtn) {
        controlState.tab = tabBtn.getAttribute("data-tab");
        paintHud(true);
        return;
      }

      const subTabBtn = e.target.closest("[data-subtab]");
      if (subTabBtn) {
        controlState.subTab = subTabBtn.getAttribute("data-subtab");
        paintHud(true);
        return;
      }

      const modeBtn = e.target.closest("[data-mode]");
      if (modeBtn) {
        const mode = modeBtn.getAttribute("data-mode");
        controlState.status.plantMode = mode;
        send("plantMode", mode);
        paintHud(true);
        return;
      }

      const presetBtn = e.target.closest("[data-load], [data-delete], [data-autoload], [data-save]");
      if (presetBtn) {
        handlePresetClick(presetBtn, panels);
        return;
      }

      const kind = listKind();

      const bulkBtn = e.target.closest("[data-bulk]");
      if (bulkBtn && kind) {
        const action = bulkBtn.getAttribute("data-bulk");
        const q = (controlState.query[kind] || "").toLowerCase();
        const shown = hudListItems(kind, controlState.status, controlState.subTab).filter(
          (it) => !q || it.name.toLowerCase().includes(q)
        );
        if (kind === "buy") {
          // Each category is its own config key, so bulk actions have to
          // be applied per category rather than as one flat list.
          ["Seeds", "Gears", "Crates"].forEach((cat) => {
            const inCat = shown.filter((it) => it.category === cat).map((it) => it.name);
            if (action === "none") setSelection(kind, cat, []);
            else if (action === "all" && inCat.length) setSelection(kind, cat, inCat);
            else if (action === "cat:" + cat) setSelection(kind, cat, (controlState.status.items[cat] || []).map((i) => i.name));
          });
        } else {
          setSelection(kind, null, action === "all" ? shown.map((it) => it.name) : []);
        }
        // Repaint from our own copy; the script's echo arrives later.
        controlState.status.selected = Object.assign({}, controlState.status.selected, {
          Seeds: controlState.config.buySeeds || (controlState.status.selected || {}).Seeds,
          Gears: controlState.config.buyGears || (controlState.status.selected || {}).Gears,
          Crates: controlState.config.buyCrates || (controlState.status.selected || {}).Crates,
          plant: controlState.config.plantSeeds || (controlState.status.selected || {}).plant,
          drops: controlState.config.collectItems || (controlState.status.selected || {}).drops,
          harvestExcluded:
            controlState.config.harvestExcluded || (controlState.status.selected || {}).harvestExcluded,
        });
        paintHud(true);
        return;
      }

      const itemToggle = e.target.closest("[data-item]");
      if (itemToggle && kind) {
        const name = itemToggle.getAttribute("data-item");
        const category = itemToggle.getAttribute("data-category");
        const list = currentSelection(kind, category);
        const at = list.indexOf(name);
        const next = !itemToggle.classList.contains("on");
        if (next && at === -1) list.push(name);
        if (!next && at !== -1) list.splice(at, 1);
        itemToggle.classList.toggle("on", next);
        itemToggle.setAttribute("aria-checked", String(next));
        setSelection(kind, category, list);
        return;
      }

      const toggle = e.target.closest('[data-type="toggle"]');
      if (toggle) {
        const key = toggle.getAttribute("data-control");
        const next = !toggle.classList.contains("on");
        toggle.classList.toggle("on", next);
        toggle.setAttribute("aria-checked", String(next));
        send(key, next);
      }
    });

    // A poll must never repaint a slider you're holding.
    panels.addEventListener("pointerdown", (e) => {
      if (e.target.closest('[data-type="slider"]')) controlState.dragging = true;
    });
    window.addEventListener("pointerup", () => {
      controlState.dragging = false;
    });

    panels.addEventListener("input", (e) => {
      const search = e.target.closest("[data-search]");
      if (!search) return;
      controlState.query[search.getAttribute("data-search")] = search.value;
      paintHud(true);
    });

    // Sliders track the number while dragging but only send the settled
    // value, so a drag doesn't fire dozens of writes.
    panels.addEventListener("input", (e) => {
      const input = e.target.closest('[data-type="slider"]');
      if (!input) return;
      const box = panels.querySelector(`[data-box="${input.getAttribute("data-control")}"]`);
      if (box) box.value = parseFloat(input.value).toFixed(3);
    });

    panels.addEventListener("change", (e) => {
      const slider = e.target.closest('[data-type="slider"]');
      if (slider) {
        send(slider.getAttribute("data-control"), parseFloat(slider.value));
        return;
      }
      // Typed exact values, same as the in-game text box.
      const box = e.target.closest("[data-box]");
      if (box) {
        const key = box.getAttribute("data-box");
        const control = CONTROL_TABS.flatMap((t) => t.controls || []).find((c) => c.key === key);
        const parsed = parseFloat(box.value);
        if (!control || isNaN(parsed)) return;
        const clamped = Math.min(control.max, Math.max(control.min, parsed));
        box.value = clamped.toFixed(3);
        const slider = panels.querySelector(`[data-control="${key}"]`);
        if (slider) slider.value = clamped;
        send(key, clamped);
      }
    });
  }

  // EXECUTOR DETAIL
  function viewExecutor(executorId) {
    const ex = DATA.executors.find((e) => e.id === executorId);
    if (!ex) return notFound("Executor");

    const features = ex.features
      ? `<div class="detail-panel glass"><h2>Features & compatibility</h2><ul>${ex.features.map((f) => `<li>${escapeHtml(f)}</li>`).join("")}</ul></div>`
      : "";

    return `
      <section class="view">
        <a class="back-btn" href="#/executors">← Back to executors</a>
        <div class="detail-header">
          <div class="detail-thumb glass">
            <span class="img-gradient" style="position:absolute;inset:0;border-radius:18px;background:${ex.gradient};opacity:0.85"></span>
            <span style="position:relative">${thumbDisplay(ex)}</span>
          </div>
          <div class="detail-title-block">
            <h1>${escapeHtml(ex.name)}</h1>
            <p>Roblox executor</p>
          </div>
        </div>

        <div class="detail-panel glass">
          <h2>About ${escapeHtml(ex.name)}</h2>
          <p>${escapeHtml(ex.description)}</p>
        </div>

        ${features}

        <div class="detail-panel glass" style="text-align:center">
          <h2>Get ${escapeHtml(ex.name)}</h2>
          <p style="margin-bottom:8px">Download the latest build and start running scripts in seconds.</p>
          <a class="btn btn-download" href="${escapeHtml(ex.download)}" target="_blank" rel="noopener noreferrer">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
            Download ${escapeHtml(ex.name)}
          </a>
        </div>
      </section>`;
  }

  /* ============================================================
     Admin Panel — add/edit/delete games, exploits, executors
     ============================================================ */

  // Helper: pick the image to display. Custom image takes priority; else emoji.
  function thumbDisplay(item) {
    if (item.image && /^https?:\/\//.test(item.image)) {
      return `<img src="${escapeHtml(item.image)}" alt="${escapeHtml(item.name || item.title || "")}" class="thumb-img" onerror="this.style.display='none';this.nextElementSibling.style.display=''"/><span class="emoji" style="display:none">${escapeHtml(item.emoji || "🎮")}</span>`;
    }
    return `<span class="emoji">${escapeHtml(item.emoji || "🎮")}</span>`;
  }

  /* Small circular icon button overlaid on an admin card (edit / delete). */
  function adminCardActions(editAction, delAction, dataAttrs) {
    return `
      <div class="admin-card-actions">
        <button class="admin-icon-btn edit" data-action="${editAction}" ${dataAttrs} aria-label="Edit" title="Edit">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>
        </button>
        <button class="admin-icon-btn del" data-action="${delAction}" ${dataAttrs} aria-label="Delete" title="Delete">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m3 0-1 14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2L4 6"/></svg>
        </button>
      </div>`;
  }

  function viewAdmin() {
    const games = DATA.games;
    const executors = DATA.executors;
    const totalExploits = games.reduce((n, g) => n + (g.exploits ? g.exploits.length : 0), 0);

    const gameCards = games
      .map((g) => {
        const count = g.exploits ? g.exploits.length : 0;
        return `
        <div class="card admin-card">
          ${adminCardActions("edit-game", "delete-game", `data-id="${escapeHtml(g.id)}"`)}
          <div class="card-img">
            <span class="img-gradient" style="background:${g.gradient || "linear-gradient(135deg,#1a1a1a,#050505)"}"></span>
            ${thumbDisplay(g, 0)}
          </div>
          <div class="card-body">
            <span class="card-title">${escapeHtml(g.name)}</span>
            <span class="card-sub">${escapeHtml(g.sub || "")}</span>
            <span class="card-badge">${count} script${count === 1 ? "" : "s"}</span>
          </div>
        </div>`;
      })
      .join("");

    const exploitCards = games
      .map((g) =>
        (g.exploits || [])
          .map(
            (e) => `
        <div class="card admin-card">
          ${adminCardActions("edit-exploit", "delete-exploit", `data-game="${escapeHtml(g.id)}" data-id="${escapeHtml(e.id)}"`)}
          <div class="card-img">
            <span class="img-gradient"></span>
            ${thumbDisplay(e, 0)}
          </div>
          <div class="card-body">
            <span class="card-title">${escapeHtml(e.title)}</span>
            <span class="card-sub">${escapeHtml(g.name)}${e.verified ? " · ✓ Verified" : " · Unverified"}${e.level ? ` · Lvl ${e.level}` : ""}</span>
          </div>
        </div>`
          )
          .join("")
      )
      .join("");

    const executorCards = executors
      .map(
        (ex) => `
        <div class="card admin-card">
          ${adminCardActions("edit-executor", "delete-executor", `data-id="${escapeHtml(ex.id)}"`)}
          <div class="card-img executor-img">
            <span class="img-gradient" style="background:${ex.gradient || "linear-gradient(135deg,#1a1a1a,#050505)"}"></span>
            ${thumbDisplay(ex, 0)}
          </div>
          <div class="card-body" style="align-items:center;text-align:center">
            <span class="card-title">${escapeHtml(ex.name)}</span>
            <span class="card-sub">${ex.features ? ex.features.length : 0} features · ${ex.download ? "has download link" : "no download link"}</span>
          </div>
        </div>`
      )
      .join("");

    return `
      <section class="view admin-view">
        <a class="back-btn" href="#/">← Back to site</a>
        <div class="page-hero">
          <span class="eyebrow">Zev Hub · Admin</span>
          <h1>Admin Panel</h1>
          <p>Manage games, scripts, and executors. Changes are saved in your browser.</p>
        </div>

        <div class="admin-stats">
          <div class="admin-stat"><span class="admin-stat-num">${games.length}</span><span class="admin-stat-label">Games</span></div>
          <div class="admin-stat"><span class="admin-stat-num">${totalExploits}</span><span class="admin-stat-label">Scripts</span></div>
          <div class="admin-stat"><span class="admin-stat-num">${executors.length}</span><span class="admin-stat-label">Executors</span></div>
        </div>

        <div class="admin-section">
          <div class="admin-section-head">
            <p class="section-label">🎮 Games · ${games.length}</p>
            <button class="admin-fab" data-action="add-game" aria-label="Add game" title="Add game">+</button>
          </div>
          <div class="grid grid-games">${gameCards || ""}</div>
          ${gameCards ? "" : '<div class="empty-state"><span class="emoji">🎮</span><p>No games yet — hit + to add one.</p></div>'}
        </div>

        <div class="admin-section">
          <div class="admin-section-head">
            <p class="section-label">📜 Scripts · ${totalExploits}</p>
            <button class="admin-fab" data-action="add-exploit" aria-label="Add script" title="Add script">+</button>
          </div>
          <div class="grid grid-exploits">${exploitCards || ""}</div>
          ${exploitCards ? "" : '<div class="empty-state"><span class="emoji">📜</span><p>No scripts yet — hit + to add one.</p></div>'}
        </div>

        <div class="admin-section">
          <div class="admin-section-head">
            <p class="section-label">🛠 Executors · ${executors.length}</p>
            <button class="admin-fab" data-action="add-executor" aria-label="Add executor" title="Add executor">+</button>
          </div>
          <div class="grid grid-executors">${executorCards || ""}</div>
          ${executorCards ? "" : '<div class="empty-state"><span class="emoji">🛠</span><p>No executors yet — hit + to add one.</p></div>'}
        </div>

        <div class="admin-section">
          <div class="admin-section-head">
            <p class="section-label">🔧 Data</p>
          </div>
          <div class="admin-data-actions">
            <button class="admin-btn admin-btn-secondary" data-action="reset-data">Reset to defaults</button>
          </div>
        </div>
      </section>`;
  }

  /* ---------- Admin modal builder ---------- */
  function openAdminModal(title, innerHtml) {
    let overlay = document.getElementById("adminModal");
    if (!overlay) {
      overlay = document.createElement("div");
      overlay.id = "adminModal";
      overlay.className = "modal-overlay";
      overlay.innerHTML = `<div class="modal glass admin-modal" role="dialog" aria-modal="true">
        <button class="modal-close" data-admin-close aria-label="Close">×</button>
        <h2 class="admin-modal-title"></h2>
        <div class="admin-modal-body"></div>
      </div>`;
      document.body.appendChild(overlay);
      overlay.addEventListener("click", (e) => {
        if (e.target === overlay || e.target.matches("[data-admin-close]")) closeAdminModal();
      });
    }
    overlay.querySelector(".admin-modal-title").textContent = title;
    overlay.querySelector(".admin-modal-body").innerHTML = innerHtml;
    overlay.classList.add("open");
    overlay.setAttribute("aria-hidden", "false");
    document.body.style.overflow = "hidden";
  }

  function closeAdminModal() {
    const overlay = document.getElementById("adminModal");
    if (overlay) {
      overlay.classList.remove("open");
      overlay.setAttribute("aria-hidden", "true");
      document.body.style.overflow = "";
    }
  }

  /* ---------- Field generators for forms ---------- */
  function fieldText(id, label, value, placeholder) {
    return `<label class="admin-field"><span>${escapeHtml(label)}</span><input type="text" id="f-${id}" data-field="${escapeHtml(id)}" value="${escapeHtml(value || "")}" placeholder="${escapeHtml(placeholder || "")}"/></label>`;
  }
  function fieldTextarea(id, label, value, placeholder) {
    return `<label class="admin-field"><span>${escapeHtml(label)}</span><textarea id="f-${id}" data-field="${escapeHtml(id)}" rows="3" placeholder="${escapeHtml(placeholder || "")}">${escapeHtml(value || "")}</textarea></label>`;
  }
  function fieldNumber(id, label, value) {
    return `<label class="admin-field"><span>${escapeHtml(label)}</span><input type="number" id="f-${id}" data-field="${escapeHtml(id)}" value="${value != null ? value : ""}" placeholder="0"/></label>`;
  }
  function fieldCheckbox(id, label, checked) {
    return `<label class="admin-field admin-field-inline"><input type="checkbox" id="f-${id}" data-field="${escapeHtml(id)}" ${checked ? "checked" : ""}/><span>${escapeHtml(label)}</span></label>`;
  }
  function fieldList(id, label, value) {
    const text = Array.isArray(value) ? value.join("\n") : value || "";
    return `<label class="admin-field"><span>${escapeHtml(label)} <em>(one per line)</em></span><textarea id="f-${id}" data-field="${escapeHtml(id)}" rows="4" placeholder="Item 1&#10;Item 2">${escapeHtml(text)}</textarea></label>`;
  }
  function fieldImage(id, label, value, emojiVal) {
    return `<label class="admin-field">
      <span>${escapeHtml(label)} <em>(PNG URL — optional)</em></span>
      <input type="text" id="f-${id}" data-field="${escapeHtml(id)}" value="${escapeHtml(value || "")}" placeholder="https://example.com/image.png"/>
      <div class="admin-image-preview" id="preview-${id}"></div>
    </label>`;
  }

  /** Collect form values from an admin modal body into an object. */
  function collectForm(container) {
    const out = {};
    container.querySelectorAll("[data-field]").forEach((el) => {
      const key = el.getAttribute("data-field");
      if (el.type === "checkbox") {
        out[key] = el.checked;
      } else if (el.type === "number") {
        out[key] = el.value === "" ? "" : Number(el.value);
      } else if (el.tagName === "TEXTAREA" && el.getAttribute("data-list") === "1") {
        out[key] = el.value.split("\n").map((s) => s.trim()).filter(Boolean);
      } else {
        out[key] = el.value.trim();
      }
    });
    return out;
  }

  async function saveAndRefresh() {
    await refreshData();
    closeAdminModal();
    render();
  }

  /* ---------- Image preview live updater ---------- */
  function bindImagePreview(container) {
    container.querySelectorAll('input[type="text"][data-field$="-image"], input[type="text"][data-field="image"]').forEach((input) => {
      const previewId = "preview-" + input.getAttribute("data-field");
      function update() {
        const box = container.querySelector("#" + CSS.escape(previewId));
        if (!box) return;
        const url = input.value.trim();
        if (url && /^https?:\/\//.test(url)) {
          box.innerHTML = `<img src="${escapeHtml(url)}" alt="preview" onerror="this.parentElement.innerHTML='<span class=&quot;admin-preview-err&quot;>⚠️ failed to load</span>'"/>`;
        } else {
          box.innerHTML = "";
        }
      }
      input.addEventListener("input", update);
      update();
    });
  }

  /* ---------- Admin: Games ---------- */
  function adminAddGame() {
    openAdminModal("Add Game", `
      ${fieldImage("image", "Thumbnail", "", "🎮")}
      ${fieldText("name", "Name", "", "Blox Fruits")}
      ${fieldText("sub", "Subtitle", "", "Sail the seas & grind fruits")}
      ${fieldNumber("place_id", "Roblox Place ID", "")}
      <label class="admin-field"><span>&nbsp;</span><em>Used by the Universal Loader to detect this game. Find it in the game's Roblox URL: roblox.com/games/<strong>PLACE_ID</strong>/name</em></label>
      <button class="admin-btn admin-btn-save" data-admin-save="game-new">Create Game</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
  }

  function adminEditGame(gameId) {
    const g = DATA.games.find((x) => x.id === gameId);
    if (!g) return;
    openAdminModal("Edit Game", `
      ${fieldImage("image", "Thumbnail", g.image, g.emoji)}
      ${fieldText("name", "Name", g.name)}
      ${fieldText("sub", "Subtitle", g.sub || "")}
      ${fieldNumber("place_id", "Roblox Place ID", g.place_id)}
      <label class="admin-field"><span>&nbsp;</span><em>Used by the Universal Loader to detect this game. Find it in the game's Roblox URL: roblox.com/games/<strong>PLACE_ID</strong>/name</em></label>
      <button class="admin-btn admin-btn-save" data-admin-save="game" data-id="${escapeHtml(gameId)}">Save Changes</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
  }

  async function adminDeleteGame(gameId) {
    const g = DATA.games.find((x) => x.id === gameId);
    if (!g) return;
    if (!confirm(`Delete "${g.name}" and all its scripts? This cannot be undone.`)) return;
    try {
      await window.Store.deleteGame(gameId);
      await saveAndRefresh();
      showToast("Game deleted");
    } catch (e) {
      showToast("Failed to delete game");
    }
  }

  /* ---------- Admin: Exploits ---------- */
  function adminAddExploit(presetGameId) {
    const gameOptions = DATA.games
      .map((g) => `<option value="${escapeHtml(g.id)}" ${g.id === presetGameId ? "selected" : ""}>${escapeHtml(g.name)}</option>`)
      .join("");
    openAdminModal("Add Script", `
      <label class="admin-field"><span>Game</span>
        <select id="f-game-select" data-field="_game">
          ${gameOptions || '<option value="">No games — add one first</option>'}
        </select>
      </label>
      ${fieldImage("image", "Thumbnail", "", "📜")}
      ${fieldText("title", "Title", "", "Auto Farm Aura")}
      ${fieldTextarea("short", "Short summary", "", "One-line description")}
      ${fieldTextarea("description", "Full description", "", "Detailed description of what the script does.")}
      ${fieldText("loadstring", "Loadstring", "", 'loadstring(game:HttpGet("..."))()')}
      ${fieldNumber("level", "UNC Level", 7)}
      ${fieldCheckbox("verified", "Verified", true)}
      ${fieldText("downloads", "Downloads", "", "1.2M")}
      ${fieldText("updated", "Updated", "", "2h ago")}
      ${fieldList("requirements", "Requirements", [], "Any executor supporting UNC Level 7 or higher")}
      <button class="admin-btn admin-btn-save" data-admin-save="exploit-new">Create Script</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
    // Mark requirements textarea as a list
    const req = document.querySelector('#f-requirements');
    if (req) req.setAttribute("data-list", "1");
  }

  function adminEditExploit(gameId, exploitId) {
    const g = DATA.games.find((x) => x.id === gameId);
    if (!g) return;
    const e = (g.exploits || []).find((x) => x.id === exploitId);
    if (!e) return;
    openAdminModal("Edit Script", `
      ${fieldImage("image", "Thumbnail", e.image, e.emoji)}
      ${fieldText("title", "Title", e.title)}
      ${fieldTextarea("short", "Short summary", e.short)}
      ${fieldTextarea("description", "Full description", e.description)}
      ${fieldText("loadstring", "Loadstring", e.loadstring)}
      ${fieldNumber("level", "UNC Level", e.level)}
      ${fieldCheckbox("verified", "Verified", e.verified)}
      ${fieldText("downloads", "Downloads", e.downloads)}
      ${fieldText("updated", "Updated", e.updated)}
      ${fieldList("requirements", "Requirements", e.requirements)}
      <button class="admin-btn admin-btn-save" data-admin-save="exploit" data-game="${escapeHtml(gameId)}" data-id="${escapeHtml(exploitId)}">Save Changes</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
    const req = document.querySelector('#f-requirements');
    if (req) req.setAttribute("data-list", "1");
  }

  async function adminDeleteExploit(gameId, exploitId) {
    const g = DATA.games.find((x) => x.id === gameId);
    if (!g) return;
    const e = (g.exploits || []).find((x) => x.id === exploitId);
    if (!e) return;
    if (!confirm(`Delete "${e.title}"?`)) return;
    try {
      await window.Store.deleteScript(gameId, exploitId);
      await saveAndRefresh();
      showToast("Script deleted");
    } catch (err) {
      showToast("Failed to delete script");
    }
  }

  /* ---------- Admin: Executors ---------- */
  function adminAddExecutor() {
    openAdminModal("Add Executor", `
      ${fieldImage("image", "Thumbnail", "", "⚡")}
      ${fieldText("name", "Name", "", "Synapse X")}
      ${fieldTextarea("description", "Description", "", "What this executor offers.")}
      ${fieldText("download", "Download URL", "", "https://example.com/download")}
      ${fieldList("features", "Features", [], "UNC compliant (100% score)")}
      <button class="admin-btn admin-btn-save" data-admin-save="executor-new">Create Executor</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
    const feat = document.querySelector('#f-features');
    if (feat) feat.setAttribute("data-list", "1");
  }

  function adminEditExecutor(executorId) {
    const ex = DATA.executors.find((x) => x.id === executorId);
    if (!ex) return;
    openAdminModal("Edit Executor", `
      ${fieldImage("image", "Thumbnail", ex.image, ex.emoji)}
      ${fieldText("name", "Name", ex.name)}
      ${fieldTextarea("description", "Description", ex.description)}
      ${fieldText("download", "Download URL", ex.download)}
      ${fieldList("features", "Features", ex.features)}
      <button class="admin-btn admin-btn-save" data-admin-save="executor" data-id="${escapeHtml(executorId)}">Save Changes</button>
    `);
    bindImagePreview(document.getElementById("adminModal"));
    const feat = document.querySelector('#f-features');
    if (feat) feat.setAttribute("data-list", "1");
  }

  async function adminDeleteExecutor(executorId) {
    const ex = DATA.executors.find((x) => x.id === executorId);
    if (!ex) return;
    if (!confirm(`Delete "${ex.name}"?`)) return;
    try {
      await window.Store.deleteExecutor(executorId);
      await saveAndRefresh();
      showToast("Executor deleted");
    } catch (e) {
      showToast("Failed to delete executor");
    }
  }

  /* ---------- Admin: handle save button clicks ---------- */
  async function handleAdminSave(btn) {
    const modalBody = document.querySelector(".admin-modal-body");
    const data = collectForm(modalBody);
    const mode = btn.getAttribute("data-admin-save");

    try {
      if (mode === "game-new") {
        if (!data.name) return showToast("Name is required");
        const id = window.Store.slugify(data.name, DATA.games.map((g) => g.id));
        await window.Store.insertGame({
          id, name: data.name, sub: data.sub || "", emoji: "🎮",
          image: data.image || "", gradient: "linear-gradient(135deg, #1a1a1a, #050505)",
          place_id: data.place_id || null,
        });
        await saveAndRefresh();
        showToast("Game added");
      } else if (mode === "game") {
        const id = btn.getAttribute("data-id");
        const g = DATA.games.find((x) => x.id === id);
        if (!g) return;
        await window.Store.updateGame(id, {
          name: data.name || g.name,
          sub: data.sub || "",
          image: data.image || "",
          place_id: data.place_id || null,
        });
        await saveAndRefresh();
        showToast("Game saved");
      } else if (mode === "exploit-new") {
        const gameId = data._game;
        const g = DATA.games.find((x) => x.id === gameId);
        if (!g) return showToast("Select a game first");
        if (!data.title) return showToast("Title is required");
        const id = window.Store.slugify(data.title, (g.exploits || []).map((e) => e.id));
        await window.Store.insertScript({
          id, game_id: gameId, title: data.title, emoji: "📜", image: data.image || "",
          short: data.short || "", description: data.description || "",
          loadstring: data.loadstring || "", level: data.level || null,
          verified: !!data.verified, downloads: data.downloads || "—",
          updated: data.updated || "now", requirements: data.requirements || [],
        });
        await saveAndRefresh();
        showToast("Script added");
      } else if (mode === "exploit") {
        const gameId = btn.getAttribute("data-game");
        const id = btn.getAttribute("data-id");
        const g = DATA.games.find((x) => x.id === gameId);
        const e = g && (g.exploits || []).find((x) => x.id === id);
        if (!e) return;
        await window.Store.updateScript(gameId, id, {
          title: data.title || e.title,
          short: data.short || "",
          description: data.description || "",
          loadstring: data.loadstring || "",
          level: data.level || null,
          verified: !!data.verified,
          downloads: data.downloads || "—",
          updated: data.updated || "now",
          requirements: data.requirements || [],
          image: data.image || "",
        });
        await saveAndRefresh();
        showToast("Script saved");
      } else if (mode === "executor-new") {
        if (!data.name) return showToast("Name is required");
        const id = window.Store.slugify(data.name, DATA.executors.map((e) => e.id));
        await window.Store.insertExecutor({
          id, name: data.name, emoji: "⚡", image: data.image || "",
          description: data.description || "", download: data.download || "",
          features: data.features || [],
        });
        await saveAndRefresh();
        showToast("Executor added");
      } else if (mode === "executor") {
        const id = btn.getAttribute("data-id");
        const ex = DATA.executors.find((x) => x.id === id);
        if (!ex) return;
        await window.Store.updateExecutor(id, {
          name: data.name || ex.name,
          description: data.description || "",
          download: data.download || "",
          features: data.features || [],
          image: data.image || "",
        });
        await saveAndRefresh();
        showToast("Executor saved");
      }
    } catch (err) {
      console.error("Admin save failed:", err);
      showToast("Save failed — check your connection and try again");
    }
  }

  /* ---------- Admin: event wiring ----------
     Bound once on document (not per-render on .admin-view) because the
     admin modal is appended directly to <body>, outside the .admin-view
     subtree, so a listener scoped to .admin-view would never see clicks
     inside the modal. */
  let adminEventsBound = false;
  function bindAdminEvents() {
    if (adminEventsBound) return;
    adminEventsBound = true;
    document.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-action], [data-admin-save]");
      if (!btn) return;
      if (!btn.closest(".admin-view") && !btn.closest("#adminModal")) return;
      const action = btn.getAttribute("data-action");
      const saveMode = btn.getAttribute("data-admin-save");

      if (saveMode) { handleAdminSave(btn); return; }

      const id = btn.getAttribute("data-id");
      const gameId = btn.getAttribute("data-game");

      if (action === "add-game") adminAddGame();
      else if (action === "edit-game") adminEditGame(id);
      else if (action === "delete-game") adminDeleteGame(id);
      else if (action === "add-exploit") adminAddExploit(gameId);
      else if (action === "edit-exploit") adminEditExploit(gameId, id);
      else if (action === "delete-exploit") adminDeleteExploit(gameId, id);
      else if (action === "add-executor") adminAddExecutor();
      else if (action === "edit-executor") adminEditExecutor(id);
      else if (action === "delete-executor") adminDeleteExecutor(id);
      else if (action === "reset-data") {
        if (confirm("Reset ALL data back to defaults? This deletes everyone's changes.")) {
          showToast("Resetting…");
          window.Store.reset().then((fresh) => {
            DATA.games = fresh.games;
            DATA.executors = fresh.executors;
            render();
            showToast("Data reset to defaults");
          }).catch(() => showToast("Reset failed — check your connection"));
        }
      }
    });
  }

  function notFound(kind) {
    return `
      <section class="view">
        <div class="empty-state">
          <span class="emoji">🤷</span>
          <p>${escapeHtml(kind)} not found.</p>
          <a class="back-btn" href="#/" style="margin-top:18px">← Back home</a>
        </div>
      </section>`;
  }

  /* ---------- Render dispatch ---------- */
  function render() {
    const route = getRoute();
    let html = "";
    let activeRoute = "/";

    if (route === "/" || route === "") {
      html = viewHome("");
      activeRoute = "/";
    } else if (route.startsWith("/search")) {
      const m = route.match(/[?&]q=([^&]*)/);
      const q = m ? decodeURIComponent(m[1].replace(/\+/g, " ")) : "";
      html = viewHome(q);
      activeRoute = "/";
    } else if (route.startsWith("/game/")) {
      const parts = route.split("/");
      const gameId = parts[2];
      const exploitId = parts[3];
      if (exploitId) {
        html = viewExploit(gameId, exploitId);
      } else {
        html = viewGame(gameId);
      }
    } else if (route === "/executors") {
      html = viewExecutors();
      activeRoute = "/executors";
    } else if (route.startsWith("/executor/")) {
      const executorId = route.split("/")[2];
      html = viewExecutor(executorId);
      activeRoute = "/executors";
    } else if (route === "/loader") {
      html = viewLoader();
      activeRoute = "/loader";
    } else if (route === "/control") {
      html = viewControl();
      activeRoute = "/control";
    } else if (route === "/discord" || route === "discord") {
      html = viewHome("");
      activeRoute = "/";
    } else if (route === "/admin2014" || route.startsWith("/admin2014")) {
      html = viewAdmin();
      activeRoute = "/";
    } else {
      html = notFound("Page");
    }

    app.innerHTML = html;
    setActiveNav(activeRoute);
    bindViewEvents();
    bindAdminEvents();
    if (route === "/control") bindControlEvents();
    else clearInterval(controlState.timer);
    initMotion(app);

    const view = app.querySelector(".view");
    if (view && !prefersReduced) {
      view.style.animation = "none";
      // eslint-disable-next-line no-unused-expressions
      view.offsetHeight;
      view.style.animation = "";
    }
    // Always reveal the nav on a fresh page render
    const navEl2 = document.querySelector(".nav");
    if (navEl2) navEl2.classList.add("visible");
  }

  /* ---------- Per-view event binding ---------- */
  function bindViewEvents() {
    const route = getRoute();

    if (route === "/" || route === "" || route.startsWith("/search")) {
      const input = document.getElementById("search");
      if (input) {
        let debounce;
        input.addEventListener("input", (e) => {
          clearTimeout(debounce);
          const val = e.target.value;
          debounce = setTimeout(() => {
            const games = DATA.games.filter(
              (g) =>
                !val.trim() ||
                g.name.toLowerCase().includes(val.trim().toLowerCase()) ||
                (g.sub || "").toLowerCase().includes(val.trim().toLowerCase())
            );
            const q = val.trim();
            const cards = games
              .map(
                (g) => `
                <a class="card" href="#/game/${g.id}">
                  <div class="card-img">
                    <span class="img-gradient" style="background:${g.gradient}"></span>
                    ${thumbDisplay(g)}
                  </div>
                  <div class="card-body">
                    <span class="card-title">${escapeHtml(g.name)}</span>
                    <span class="card-sub">${escapeHtml(g.sub || "")}</span>
                    <span class="card-badge">${g.exploits.length} script${g.exploits.length === 1 ? "" : "s"}</span>
                  </div>
                </a>`
              )
              .join("");
            const listHtml = games.length
              ? `<div class="grid grid-games">${cards}</div>`
              : `<div class="empty-state"><span class="emoji">🔍</span><p>No games found for "<strong>${escapeHtml(q)}</strong>". Try another name.</p></div>`;
            const grid = app.querySelector(".grid, .empty-state");
            const label = app.querySelector(".section-label");
            if (label) label.textContent = `${q ? "Results" : "Popular games"} · ${games.length}`;
            if (grid) {
              grid.outerHTML = listHtml;
            } else if (label) {
              label.insertAdjacentHTML("afterend", listHtml);
            }
            input.focus();
            const len = input.value.length;
            input.setSelectionRange(len, len);
            initMotion(app);
          }, 160);
        });
      }
    }

    const exploitSearch = document.getElementById("exploit-search");
    if (exploitSearch) {
      const countLabel = document.getElementById("exploit-count");
      const route = getRoute();
      const gameId = route.split("/")[2];
      const game = DATA.games.find((g) => g.id === gameId);
      let debounce;
      exploitSearch.addEventListener("input", (e) => {
        clearTimeout(debounce);
        const q = e.target.value.trim().toLowerCase();
        debounce = setTimeout(() => {
          const matches = game.exploits.filter(
            (ex) =>
              !q ||
              ex.title.toLowerCase().includes(q) ||
              (ex.short || "").toLowerCase().includes(q)
          );
          // Re-query each time: outerHTML replaces the live node, so the old
          // reference would become detached after the first filter.
          const grid = document.getElementById("exploits-grid");
          if (grid) {
            grid.outerHTML = `<div class="grid grid-exploits" id="exploits-grid">${cardsHtmlStatic(game, matches)}</div>`;
          }
          if (countLabel) {
            countLabel.textContent = `${q ? "Results" : "Available scripts"} · ${matches.length}`;
          }
          initMotion(app);
        }, 140);
      });
    }

    const copyBtn = document.getElementById("copyBtn");
    if (copyBtn) {
      copyBtn.addEventListener("click", async () => {
        const codeEl = document.getElementById("loadstringCode");
        const route = getRoute();
        const parts = route.split("/");
        const game = DATA.games.find((g) => g.id === parts[2]);
        const exploit = game && game.exploits.find((e) => e.id === parts[3]);
        const text = exploit ? exploit.loadstring : codeEl.textContent;
        const ok = await copyText(text);
        const label = copyBtn.querySelector(".copy-label");
        if (ok) {
          copyBtn.classList.add("copied");
          if (label) label.textContent = "Copied!";
          showToast("Loadstring copied to clipboard");
          setTimeout(() => {
            copyBtn.classList.remove("copied");
            if (label) label.textContent = "Copy";
          }, 1800);
        } else {
          showToast("Copy failed — select and copy manually");
        }
      });
    }

    const loaderCopyBtn = document.getElementById("loaderCopyBtn");
    if (loaderCopyBtn) {
      loaderCopyBtn.addEventListener("click", async () => {
        const ok = await copyText(LOADER_SCRIPT);
        const label = loaderCopyBtn.querySelector(".copy-label");
        if (ok) {
          loaderCopyBtn.classList.add("copied");
          if (label) label.textContent = "Copied!";
          showToast("Loader script copied to clipboard");
          setTimeout(() => {
            loaderCopyBtn.classList.remove("copied");
            if (label) label.textContent = "Copy";
          }, 1800);
        } else {
          showToast("Copy failed — select and copy manually");
        }
      });
    }

    const loaderLoadstringCopyBtn = document.getElementById("loaderLoadstringCopyBtn");
    if (loaderLoadstringCopyBtn) {
      loaderLoadstringCopyBtn.addEventListener("click", async () => {
        const ok = await copyText(LOADER_LOADSTRING);
        const label = loaderLoadstringCopyBtn.querySelector(".copy-label");
        if (ok) {
          loaderLoadstringCopyBtn.classList.add("copied");
          if (label) label.textContent = "Copied!";
          showToast("Loadstring copied to clipboard");
          setTimeout(() => {
            loaderLoadstringCopyBtn.classList.remove("copied");
            if (label) label.textContent = "Copy";
          }, 1800);
        } else {
          showToast("Copy failed — select and copy manually");
        }
      });
    }

    // Drag-to-scroll + shift+wheel for the code block
    enableCodeScroll();
  }

  /* Drag-to-scroll & wheel hijack for code blocks (re-bound every render) */
  function enableCodeScroll() {
    const pre = document.querySelector(".code-block pre");
    if (!pre || pre.__scrollBound) return;
    pre.__scrollBound = true;

    // Shift + vertical wheel = horizontal scroll
    pre.addEventListener("wheel", (e) => {
      if (e.shiftKey) {
        if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
          pre.scrollLeft += e.deltaY;
          e.preventDefault();
        }
        return;
      }
      // If content is scrollable and wheel is vertical, convert to horizontal
      const canScroll = pre.scrollWidth > pre.clientWidth;
      if (canScroll && Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
        const maxScroll = pre.scrollWidth - pre.clientWidth;
        const atStart = pre.scrollLeft <= 0 && e.deltaY < 0;
        const atEnd = pre.scrollLeft >= maxScroll && e.deltaY > 0;
        if (!atStart && !atEnd) {
          pre.scrollLeft += e.deltaY;
          e.preventDefault();
        }
      }
    }, { passive: false });

    // Click-and-drag to scroll (desktop)
    let isDown = false;
    let startX = 0;
    let startScroll = 0;
    let moved = false;

    pre.addEventListener("pointerdown", (e) => {
      // Don't hijack if user is trying to select text (shift) or it's a touch (handled natively)
      if (e.pointerType === "touch") return;
      isDown = true;
      moved = false;
      startX = e.clientX;
      startScroll = pre.scrollLeft;
      pre.setPointerCapture(e.pointerId);
    });
    pre.addEventListener("pointermove", (e) => {
      if (!isDown) return;
      const dx = e.clientX - startX;
      if (Math.abs(dx) > 4) moved = true;
      pre.scrollLeft = startScroll - dx;
    });
    function endDrag(e) {
      if (!isDown) return;
      isDown = false;
      try { pre.releasePointerCapture(e.pointerId); } catch (_) {}
      // Suppress the click that follows a drag so we don't trigger card nav etc.
      if (moved) {
        pre.addEventListener("click", (ev) => ev.stopPropagation(), { capture: true, once: true });
      }
    }
    pre.addEventListener("pointerup", endDrag);
    pre.addEventListener("pointercancel", endDrag);
  }

  /* ---------- Nav interactions ---------- */
  const navToggle = document.getElementById("navToggle");
  const navLinks = document.getElementById("navLinks");

  function closeMobileNav() {
    navLinks.classList.remove("open");
    navToggle.classList.remove("open");
    navToggle.setAttribute("aria-expanded", "false");
  }

  if (navToggle) {
    navToggle.addEventListener("click", () => {
      const open = navLinks.classList.toggle("open");
      navToggle.classList.toggle("open", open);
      navToggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  navLinks.querySelectorAll("a").forEach((a) => {
    a.addEventListener("click", closeMobileNav);
  });

  // Discord button -> modal
  const discordBtn = document.getElementById("discordBtn");
  const discordModal = document.getElementById("discordModal");
  const discordModalClose = document.getElementById("discordModalClose");

  function openDiscordModal(e) {
    if (e) { e.preventDefault(); }
    discordModal.classList.add("open");
    discordModal.setAttribute("aria-hidden", "false");
    if (location.hash === "#discord" || location.hash === "#/discord") {
      history.replaceState(null, "", location.pathname + location.search);
    }
  }
  function closeDiscordModal() {
    discordModal.classList.remove("open");
    discordModal.setAttribute("aria-hidden", "true");
  }

  if (discordBtn) discordBtn.addEventListener("click", openDiscordModal);
  if (discordModalClose) discordModalClose.addEventListener("click", closeDiscordModal);
  discordModal.addEventListener("click", (e) => { if (e.target === discordModal) closeDiscordModal(); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeDiscordModal(); });

  /* ---------- Init ---------- */

  /* Motion engine — faint cursor glow + magnetic buttons (no tilt) */
  const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const isCoarse = window.matchMedia("(pointer: coarse)").matches;

  function initCardGlow(scope) {
    if (prefersReduced || isCoarse) return;
    const cards = (scope || document).querySelectorAll(".card");
    cards.forEach((card) => {
      if (card.__glowBound) return;
      card.__glowBound = true;
      let raf = null;
      card.addEventListener("pointermove", (e) => {
        const rect = card.getBoundingClientRect();
        const px = ((e.clientX - rect.left) / rect.width) * 100;
        const py = ((e.clientY - rect.top) / rect.height) * 100;
        if (raf) cancelAnimationFrame(raf);
        raf = requestAnimationFrame(() => {
          card.style.setProperty("--mx", px.toFixed(1) + "%");
          card.style.setProperty("--my", py.toFixed(1) + "%");
        });
      });
    });
  }

  function initMagnetic() {
    if (prefersReduced || isCoarse) return;
    document.querySelectorAll(".btn, .btn-discord-lg, .nav-discord, .copy-btn, .back-btn").forEach((el) => {
      if (el.__magBound) return;
      el.__magBound = true;
      let raf = null;
      el.addEventListener("pointermove", (e) => {
        const rect = el.getBoundingClientRect();
        const dx = e.clientX - (rect.left + rect.width / 2);
        const dy = e.clientY - (rect.top + rect.height / 2);
        if (raf) cancelAnimationFrame(raf);
        raf = requestAnimationFrame(() => {
          el.style.translate = `${(dx * 0.18).toFixed(1)}px ${(dy * 0.18).toFixed(1)}px`;
        });
      });
      el.addEventListener("pointerleave", () => {
        if (raf) cancelAnimationFrame(raf);
        el.style.translate = "0 0";
      });
    });
  }

  function initMotion(scope) {
    initCardGlow(scope);
    initMagnetic();
  }

  initNavHoverIndicator();
  initMotion();
  window.addEventListener("resize", () => {
    const route = getRoute();
    // Determine active route for indicator
    let activeRoute = "/";
    if (route === "/executors" || route.startsWith("/executor/")) activeRoute = "/executors";
    else if (route === "/loader") activeRoute = "/loader";
    else if (route === "/control") activeRoute = "/control";
    positionNavIndicator(activeRoute);
  });

  window.addEventListener("hashchange", render);

  /* ---------- Scroll-aware nav: hide on scroll down, show on scroll up ---------- */
  const navEl = document.querySelector(".nav");
  let lastScrollY = window.scrollY;
  let ticking = false;

  function updateNavOnScroll() {
    const currentY = window.scrollY;
    // Always show nav near the top of the page
    if (currentY <= 80) {
      navEl.classList.add("visible");
    } else if (currentY > lastScrollY + 8) {
      // Scrolling down — hide
      navEl.classList.remove("visible");
      closeMobileNav();
    } else if (currentY < lastScrollY - 8) {
      // Scrolling up — show
      navEl.classList.add("visible");
    }
    lastScrollY = currentY;
    ticking = false;
  }

  window.addEventListener(
    "scroll",
    () => {
      if (!ticking) {
        window.requestAnimationFrame(updateNavOnScroll);
        ticking = true;
      }
    },
    { passive: true }
  );

  // Start visible
  navEl.classList.add("visible");

  /* ---------- Boot: fetch from Supabase, then render ---------- */
  app.innerHTML = `<section class="view"><div class="empty-state"><span class="emoji">⏳</span><p>Loading Zev Hub…</p></div></section>`;

  async function boot() {
    await refreshData();
    if (location.hash === "#discord" || location.hash === "#/discord") {
      history.replaceState(null, "", location.pathname + location.search);
      render();
      setTimeout(openDiscordModal, 100);
    } else {
      render();
    }
  }
  boot();
})();
