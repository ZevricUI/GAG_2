/* ============================================================
   Zev Hub — Data
   Sample games, exploits, and executors.
   ============================================================ */

const DATA = {
  games: [
    {
      id: "blox-fruits",
      name: "Blox Fruits",
      emoji: "🍎",
      gradient: "linear-gradient(135deg, #ff6b6b, #c44569)",
      sub: "Sail the seas & grind fruits",
      exploits: [
        {
          id: "bf-aura",
          title: "Blox Fruits — Auto Farm Aura",
          emoji: "⚔️",
          gradient: "linear-gradient(135deg, #f093fb, #f5576c)",
          short: "Auto-targets nearest enemies, activates your fighting style, and grinds levels while AFK.",
          description: "A full auto-farm script that automatically targets the nearest enemies, activates your fighting style, and grinds levels while you're AFK. Includes auto-buy fruits, auto-stats allocation, and a clean toggle UI. Optimized to avoid rubber-banding and detection.",
          loadstring: 'loadstring(game:HttpGet("https://raw.githubusercontent.com/scriptexer/blox-fruits/main/aura.lua"))()',
          verified: true,
          updated: "2h ago",
          downloads: "1.2M",
          level: 7,
          requirements: [
            "Any executor supporting UNC Level 7 or higher",
            "Stable internet connection",
            "Windows 10/11 or Android (via Hydrogen)",
            "Disable antivirus if injection fails"
          ]
        },
        {
          id: "bf-race",
          title: "Blox Fruits — Race V4 Unlocker",
          emoji: "🧬",
          gradient: "linear-gradient(135deg, #4facfe, #00f2fe)",
          short: "Automates the Race V4 questline — pulls levers, defeats trials, solves puzzles.",
          description: "Automates the Race V4 questline — pulls levers, defeats trials, and completes the puzzle in record time. Works with all races and remembers your progress between sessions.",
          loadstring: 'loadstring(game:HttpGet("https://raw.githubusercontent.com/scriptexer/blox-fruits/main/racev4.lua"))()',
          verified: true,
          updated: "5h ago",
          downloads: "847K",
          level: 7,
          requirements: [
            "Any executor supporting UNC Level 7 or higher",
            "Race V4 quest unlocked in-game",
            "Stable internet connection"
          ]
        }
      ]
    },
    {
      id: "pet-sim-99",
      name: "Pet Simulator 99",
      emoji: "🐾",
      gradient: "linear-gradient(135deg, #a18cd1, #fbc2eb)",
      sub: "Hatch, trade & collect pets",
      exploits: [
        {
          id: "ps99-autofarm",
          title: "PS99 — Auto Farm & Hatch",
          emoji: "🥚",
          gradient: "linear-gradient(135deg, #fa709a, #fee140)",
          short: "Hatches eggs, auto-sells duplicates, collects coins, and farms the best zones automatically.",
          description: "Hatches eggs, auto-sells duplicates, collects coins, and farms the best zones automatically. Includes an auto-trade blocker safety, ping-based zone switching, and a huge pet inventory.",
          loadstring: 'loadstring(game:HttpGet("https://raw.githubusercontent.com/scriptexer/ps99/main/farm.lua"))()',
          verified: true,
          updated: "1h ago",
          downloads: "654K",
          level: 6,
          requirements: [
            "Any executor supporting UNC Level 6 or higher",
            "Stable internet connection",
            "Enough free inventory space for eggs"
          ]
        },
        {
          id: "ps99-coin",
          title: "PS99 — Infinite Coin Collector",
          emoji: "💰",
          gradient: "linear-gradient(135deg, #ffd200, #f7971e)",
          short: "Teleports to every coin spawn across the map and collects them instantly.",
          description: "Teleports to every coin spawn across the map and collects them instantly. Smart pathfinding avoids other players for maximum speed and lower kick risk.",
          loadstring: 'loadstring(game:HttpGet("https://raw.githubusercontent.com/scriptexer/ps99/main/coins.lua"))()',
          verified: false,
          updated: "1d ago",
          downloads: "312K",
          level: 5,
          requirements: [
            "Any executor supporting UNC Level 5 or higher",
            "Stable internet connection"
          ]
        }
      ]
    },
    {
      id: "doors",
      name: "DOORS",
      emoji: "🚪",
      gradient: "linear-gradient(135deg, #0f2027, #203a43)",
      sub: "Survive the haunted hotel",
      exploits: [
        {
          id: "doors-esp",
          title: "DOORS — Entity ESP & Predictor",
          emoji: "👁️",
          gradient: "linear-gradient(135deg, #434343, #000000)",
          short: "Highlights entities, items & doors through walls; predicts Rush and Ambush early.",
          description: "Highlights every entity, item, and door through walls. Predicts Rush and Ambush events 3 seconds early so you can hide in time. Shows locker locations during hunts.",
          loadstring: 'loadstring(game:HttpGet("https://raw.githubusercontent.com/scriptexer/doors/main/esp.lua"))()',
          verified: true,
          updated: "3h ago",
          downloads: "498K",
          level: 6,
          requirements: [
            "Any executor supporting UNC Level 6 or higher",
            "Stable internet connection",
            "Recommended: lower graphics for smoother ESP"
          ]
        }
      ]
    },
    {
      id: "brookhaven",
      name: "Brookhaven RP",
      emoji: "🏠",
      gradient: "linear-gradient(135deg, #89f7fe, #66a6ff)",
      sub: "Life-sim roleplay town",
      exploits: [
        {
          id: "bh-fly",
          title: "Brookhaven — Fly & Speed Hub",
          emoji: "🕊️",
          gradient: "linear-gradient(135deg, #667eea, #764ba2)",
          short: "Unlimited fly, walk-speed modifier, infinite jump, and noclip through walls.",
          description: "Unlimited fly, walk-speed modifier, infinite jump, and noclip through walls. Includes a clean command bar and saved preferences per server.",
          loadstring: 'loadstring(game:HttpGet("https://raw.githubusercontent.com/scriptexer/brookhaven/main/hub.lua"))()',
          verified: true,
          updated: "6h ago",
          downloads: "2.1M",
          level: 4,
          requirements: [
            "Any executor supporting UNC Level 4 or higher",
            "Works on Windows, Android & iOS"
          ]
        }
      ]
    },
    {
      id: "grow-a-garden",
      name: "Grow a Garden",
      emoji: "🌱",
      gradient: "linear-gradient(135deg, #11998e, #38ef7d)",
      sub: "Idle farming simulator",
      exploits: [
        {
          id: "gag-autoplant",
          title: "Grow a Garden — Auto Plant & Sell",
          emoji: "🌾",
          gradient: "linear-gradient(135deg, #38ef7d, #11998e)",
          short: "Auto-plants seeds, waters crops, harvests ripe produce, and sells to the shop.",
          description: "Auto-plants seeds, waters crops, harvests ripe produce, and sells to the shop automatically. Tracks crop value and rotates to the most profitable seed each cycle.",
          loadstring: 'loadstring(game:HttpGet("https://raw.githubusercontent.com/scriptexer/garden/main/auto.lua"))()',
          verified: false,
          updated: "8h ago",
          downloads: "189K",
          level: 5,
          requirements: [
            "Any executor supporting UNC Level 5 or higher",
            "At least one seed purchased in-game"
          ]
        }
      ]
    },
    {
      id: "arsenal",
      name: "Arsenal",
      emoji: "🔫",
      gradient: "linear-gradient(135deg, #f12711, #f5af19)",
      sub: "Fast-paced FPS chaos",
      exploits: [
        {
          id: "ars-aimbot",
          title: "Arsenal — Silent Aim & ESP",
          emoji: "🎯",
          gradient: "linear-gradient(135deg, #ee0979, #ff6a00)",
          short: "Silent-aim headshots with FOV slider; ESP outlines enemies with health bars.",
          description: "Silent-aim headshots with FOV slider and smoothness control. ESP outlines enemies with health bars and weapon names. Fully client-side and configurable.",
          loadstring: 'loadstring(game:HttpGet("https://raw.githubusercontent.com/scriptexer/arsenal/main/aim.lua"))()',
          verified: true,
          updated: "12m ago",
          downloads: "377K",
          level: 7,
          requirements: [
            "Any executor supporting UNC Level 7 or higher",
            "Stable, low-ping connection recommended",
            "Disable antivirus if injection fails"
          ]
        }
      ]
    },
    {
      id: "murder-mystery",
      name: "Murder Mystery 2",
      emoji: "🔪",
      gradient: "linear-gradient(135deg, #232526, #414345)",
      sub: "Find the murderer",
      exploits: [
        {
          id: "mm2-esp",
          title: "MM2 — Murderer & Sheriff ESP",
          emoji: "🔴",
          gradient: "linear-gradient(135deg, #cb356b, #bd3f32)",
          short: "Reveals who is the murderer and sheriff with color-coded ESP; shows dropped gun.",
          description: "Instantly reveals who is the murderer and who is the sheriff with color-coded ESP. Shows dropped gun location, distance, and warns you when the murderer is nearby.",
          loadstring: 'loadstring(game:HttpGet("https://raw.githubusercontent.com/scriptexer/mm2/main/esp.lua"))()',
          verified: true,
          updated: "4h ago",
          downloads: "723K",
          level: 6,
          requirements: [
            "Any executor supporting UNC Level 6 or higher",
            "Stable internet connection"
          ]
        }
      ]
    },
    {
      id: "adopt-me",
      name: "Adopt Me",
      emoji: "🦄",
      gradient: "linear-gradient(135deg, #ff9a9e, #fad0c4)",
      sub: "Raise & trade pets",
      exploits: [
        {
          id: "am-autotrade",
          title: "Adopt Me — Auto Tasks & Trade Helper",
          emoji: "🍼",
          gradient: "linear-gradient(135deg, #ffecd2, #fcb69f)",
          short: "Auto-completes daily tasks, feeds pets, ages them up; flags unfair trades.",
          description: "Auto-completes daily tasks, feeds pets, and ages them up automatically. Includes a trade-value calculator that flags unfair offers in real time.",
          loadstring: 'loadstring(game:HttpGet("https://raw.githubusercontent.com/scriptexer/adoptme/main/tasks.lua"))()',
          verified: true,
          updated: "2h ago",
          downloads: "445K",
          level: 5,
          requirements: [
            "Any executor supporting UNC Level 5 or higher",
            "Stable internet connection",
            "Works on Windows & Android"
          ]
        }
      ]
    }
  ],

  executors: [
    {
      id: "synapse",
      name: "Synapse X",
      emoji: "⚡",
      gradient: "linear-gradient(135deg, #7c5cff, #00e0c6)",
      description: "The industry-standard premium executor. Known for industry-leading stability, a massive function library, and best-in-class script compatibility. Supports UNC, drawing APIs, and custom environment patches.",
      features: ["UNC compliant (100% score)", "Drawing & ImGui APIs", "Custom script environment", "Frequent auto-updates", "Windows 10/11 supported"],
      download: "https://example.com/synapse-x-download"
    },
    {
      id: "wave",
      name: "Wave",
      emoji: "🌊",
      gradient: "linear-gradient(135deg, #0093e9, #80d0c7)",
      description: "A modern, lightweight executor with a clean UI and rock-solid performance. Great for users who want a fast boot time and minimal overhead while still running advanced scripts.",
      features: ["Lightweight & fast", "Clean modern UI", "Good UNC coverage", "Low CPU usage", "Active community support"],
      download: "https://example.com/wave-download"
    },
    {
      id: "swift",
      name: "Swift",
      emoji: "🚀",
      gradient: "linear-gradient(135deg, #f7971e, #ffd200)",
      description: "A free-to-use executor focused on accessibility. Solid script execution for casual users with a straightforward attach-and-execute flow. Updated regularly to patch detection.",
      features: ["Free to use", "One-click attach", "Tabbed multi-script editor", "Auto-update on launch", "Beginner friendly"],
      download: "https://example.com/swift-download"
    },
    {
      id: "krampus",
      name: "Krampus",
      emoji: "🦌",
      gradient: "linear-gradient(135deg, #cb356b, #bd3f32)",
      description: "A rising executor with strong UNC support and a feature-rich script hub built in. Popular for advanced drawing scripts and UI libraries. Frequent stability patches.",
      features: ["Built-in script hub", "UNC 98% score", "Drawing API support", "Key-system with daily refresh", "Windows 10/11 supported"],
      download: "https://example.com/krampus-download"
    },
    {
      id: "hydrogen",
      name: "Hydrogen",
      emoji: "💧",
      gradient: "linear-gradient(135deg, #2193b0, #6dd5ed)",
      description: "A cross-platform executor available on both Android and Windows. The go-to choice for mobile exploiters thanks to its touch-optimized interface and reliable script execution on the go.",
      features: ["Android & Windows", "Touch-optimized UI", "Mobile UNC support", "Cloud-saved scripts", "Free with key system"],
      download: "https://example.com/hydrogen-download"
    },
    {
      id: "delta",
      name: "Delta",
      emoji: "🔺",
      gradient: "linear-gradient(135deg, #8e2de2, #4a00e0)",
      description: "A long-standing free executor trusted by millions. Reliable execution across a huge range of scripts, with a built-in script library and one of the most active communities in the space.",
      features: ["Completely free", "Massive script library", "iOS, Android & Windows", "Easy key system", "Huge active community"],
      download: "https://example.com/delta-download"
    }
  ]
};

window.DATA = DATA;

/* ============================================================
   Store — Supabase persistence layer
   The main site and the admin panel both read/write straight to
   Supabase, so games/scripts/executors are shared across every
   visitor and device instead of being stuck in one browser.
   ============================================================ */
const SUPABASE_URL = "https://fscazttvhgwaqxkdphsp.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZzY2F6dHR2aGd3YXF4a2RwaHNwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU1MzI0NTYsImV4cCI6MjEwMTEwODQ1Nn0.WWKLNM6ZQZKF2DVne0diOaT3ZB7apbbbuk1lTH-b4L8";

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const Store = {
  /** Load games (with their scripts nested as .exploits) and executors from Supabase. */
  async load() {
    try {
      const [gamesRes, scriptsRes, executorsRes] = await Promise.all([
        sb.from("games").select("*").order("created_at", { ascending: true }),
        sb.from("scripts").select("*").order("created_at", { ascending: true }),
        sb.from("executors").select("*").order("created_at", { ascending: true }),
      ]);
      if (gamesRes.error) throw gamesRes.error;
      if (scriptsRes.error) throw scriptsRes.error;
      if (executorsRes.error) throw executorsRes.error;

      // First run — tables exist but are empty. Seed with the built-in defaults.
      if (gamesRes.data.length === 0 && executorsRes.data.length === 0) {
        await this.seedDefaults();
        return this.load();
      }

      const games = gamesRes.data.map((g) => ({
        ...g,
        exploits: scriptsRes.data.filter((s) => s.game_id === g.id),
      }));
      return { games, executors: executorsRes.data };
    } catch (e) {
      console.error("Store.load failed, falling back to built-in defaults:", e);
      return { games: DATA.games, executors: DATA.executors };
    }
  },

  /** One-time seed of the empty Supabase tables from the bundled defaults. */
  async seedDefaults() {
    const gamesToInsert = DATA.games.map((g) => ({
      id: g.id, name: g.name, sub: g.sub || "", emoji: g.emoji || "🎮",
      image: g.image || "", gradient: g.gradient || "",
    }));
    const scriptsToInsert = DATA.games.flatMap((g) =>
      (g.exploits || []).map((e) => ({
        id: e.id, game_id: g.id, title: e.title, emoji: e.emoji || "📜",
        image: e.image || "", short: e.short || "", description: e.description || "",
        loadstring: e.loadstring || "", level: e.level || null,
        verified: !!e.verified, downloads: e.downloads || "—",
        updated: e.updated || "now", requirements: e.requirements || [],
      }))
    );
    const executorsToInsert = DATA.executors.map((ex) => ({
      id: ex.id, name: ex.name, emoji: ex.emoji || "⚡", image: ex.image || "",
      gradient: ex.gradient || "", description: ex.description || "",
      download: ex.download || "", features: ex.features || [],
    }));

    const gamesRes = await sb.from("games").insert(gamesToInsert);
    if (gamesRes.error) throw gamesRes.error;
    const scriptsRes = await sb.from("scripts").insert(scriptsToInsert);
    if (scriptsRes.error) throw scriptsRes.error;
    const executorsRes = await sb.from("executors").insert(executorsToInsert);
    if (executorsRes.error) throw executorsRes.error;
  },

  /** Wipe everything and reseed from defaults. */
  async reset() {
    await sb.from("scripts").delete().neq("game_id", "__none__");
    await sb.from("games").delete().neq("id", "__none__");
    await sb.from("executors").delete().neq("id", "__none__");
    await this.seedDefaults();
    return this.load();
  },

  /* ---------- Games ---------- */
  async insertGame(game) {
    const { error } = await sb.from("games").insert(game);
    if (error) throw error;
  },
  async updateGame(id, patch) {
    const { error } = await sb.from("games").update(patch).eq("id", id);
    if (error) throw error;
  },
  async deleteGame(id) {
    const { error } = await sb.from("games").delete().eq("id", id);
    if (error) throw error;
  },

  /* ---------- Scripts ---------- */
  async insertScript(script) {
    const { error } = await sb.from("scripts").insert(script);
    if (error) throw error;
  },
  async updateScript(gameId, id, patch) {
    const { error } = await sb.from("scripts").update(patch).eq("game_id", gameId).eq("id", id);
    if (error) throw error;
  },
  async deleteScript(gameId, id) {
    const { error } = await sb.from("scripts").delete().eq("game_id", gameId).eq("id", id);
    if (error) throw error;
  },

  /* ---------- Executors ---------- */
  async insertExecutor(executor) {
    const { error } = await sb.from("executors").insert(executor);
    if (error) throw error;
  },
  async updateExecutor(id, patch) {
    const { error } = await sb.from("executors").update(patch).eq("id", id);
    if (error) throw error;
  },
  async deleteExecutor(id) {
    const { error } = await sb.from("executors").delete().eq("id", id);
    if (error) throw error;
  },

  /** Generate a unique kebab-case id from a name. */
  slugify(name, existing = []) {
    let base = String(name || "item")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 40);
    if (!base) base = "item";
    let id = base;
    let n = 2;
    while (existing.includes(id)) {
      id = `${base}-${n++}`;
    }
    return id;
  },
};

/**
 * Remote control link.
 *
 * The in-game script registers itself under a short code and polls its
 * own row for config. The site writes to that row — nothing here talks
 * to the game directly, so a closed tab or a dropped connection just
 * means the script keeps its last settings.
 */
const Control = {
  async fetchSession(code) {
    const { data, error } = await sb
      .from("sessions")
      .select("code, config, status, updated_at")
      .eq("code", String(code || "").trim().toUpperCase())
      .maybeSingle();
    if (error) throw error;
    return data;
  },

  /** Merge a patch into the session's config, leaving other keys alone. */
  async updateConfig(code, patch) {
    const key = String(code || "").trim().toUpperCase();
    const session = await Control.fetchSession(key);
    if (!session) throw new Error("No script is linked to that code.");
    const config = Object.assign({}, session.config || {}, patch);
    const { error } = await sb
      .from("sessions")
      .update({ config, updated_at: new Date().toISOString() })
      .eq("code", key);
    if (error) throw error;
    return config;
  },
};

/**
 * Saved presets. A preset is a config blob under a name, owned by the
 * Roblox player the linked script reports. One per owner may be starred
 * as autoload, which the script applies at startup.
 */
const Presets = {
  async list(owner) {
    const { data, error } = await sb
      .from("presets")
      .select("id, name, config, autoload, created_at")
      .eq("owner", owner)
      .order("created_at", { ascending: true });
    if (error) throw error;
    return data || [];
  },

  async save(owner, name, config) {
    const { error } = await sb
      .from("presets")
      .upsert({ owner, name, config }, { onConflict: "owner,name" });
    if (error) throw error;
  },

  async remove(id) {
    const { error } = await sb.from("presets").delete().eq("id", id);
    if (error) throw error;
  },

  /** Exactly one preset per owner is the autoload one. */
  async setAutoload(owner, id) {
    const clear = await sb.from("presets").update({ autoload: false }).eq("owner", owner);
    if (clear.error) throw clear.error;
    if (!id) return;
    const { error } = await sb.from("presets").update({ autoload: true }).eq("id", id);
    if (error) throw error;
  },
};

window.Store = Store;
window.Control = Control;
window.Presets = Presets;

