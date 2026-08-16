-- NPC framework — Gen 2 port (WIP)
--
-- This is a REGISTRY SKELETON. All of the old Gen 1 content (Fixer Felix,
-- Bug Catcher BugHead, the Power Plant quest items, the Haunter trader,
-- Route 1 Charlie, the Route 2 Wonder Brothers, and the doubles framework)
-- was removed during the migration to Gen 2. Nothing spawns yet.
--
-- HOW TO ADD CONTENT (the format):
--
--   NPCs.register({
--     id    = "my_npc",                        -- unique id, stamped on the
--                                              -- npc as npc.gen1onlineNpcId
--     maps  = { "GOLDENROD_CITY", "ECRUTEAK_CITY" }, -- map ids to spawn on,
--                                              -- or a single string
--     create = function(ow)                    -- build + insert the npc;
--                                              -- return the npc or nil
--       ...
--       return npc
--     end,
--     interact = function(game, npc, helpers)  -- run on talk-to; helpers is
--                                              -- the table main.lua passes
--       ...
--     end,
--   })
--
-- GEN 2 CONSTRAINTS (what the old Gen 1 content got wrong):
--   * Sprites must live under this mod's own assets/ (or be derived by
--     transforms.lua). Referencing the ROM-derived cache paths (the
--     `generated` subfolders) fails the modkit ROM-content gate (MK301) and
--     blocks modkit pack.
--   * Do NOT call BattleState.newTrainer / makeBattler / OverworldState
--     internals: on Gold those are absent (gen2check MK404). Route trainer
--     battles through the Gen 2 world/battle surfaces instead.
--   * Build npc objects via require("src.world.NPC") (aliased to the Gen 2
--     Npc on Gold) and honor its movement semantics (WALK_*/STANDING_*).
--   * Insert into the overworld exactly once per map transition; track
--     spawns with the marker field (npc.gen1onlineNpcId) so re-entering a
--     map does not duplicate.

return function(loadModFile, mod)
  local registry = {}   -- id -> def

  local function mapMatches(def, mapId)
    if not mapId then return false end
    local maps = def and def.maps
    if type(maps) == "string" then return maps == mapId end
    if type(maps) == "table" then
      for _, m in ipairs(maps) do
        if m == mapId then return true end
      end
    end
    return false
  end

  local function insertNpc(ow, npc)
    if not ow or not npc then return end
    if type(ow.npcs) == "table" and not tableContains(ow.npcs, npc) then
      table.insert(ow.npcs, npc)
    end
    if type(ow.entities) == "table" and not tableContains(ow.entities, npc) then
      table.insert(ow.entities, npc)
    end
  end

  local function tableContains(list, value)
    for _, v in ipairs(list or {}) do
      if v == value then return true end
    end
    return false
  end

  local NPCs = {
    registry = registry,

    -- Content entry point. Register every custom NPC once at load time.
    register = function(def)
      if type(def) ~= "table" or type(def.id) ~= "string" then
        print("[Gen1Online NPCs] register() requires a table with a string id")
        return nil
      end
      registry[def.id] = def
      return def
    end,

    -- Called by main.lua on every map transition / overworld spawn. Safe
    -- no-op while no content is registered.
    spawnForMap = function(ow)
      if not ow or not ow.map then return end
      local mapId = ow.map.id
      for _, def in pairs(registry) do
        if mapMatches(def, mapId) and type(def.create) == "function" then
          local ok, npc = pcall(def.create, ow)
          if ok and npc then
            npc.gen1onlineNpcId = def.id
            insertNpc(ow, npc)
          end
        end
      end
    end,

    -- Called by main.lua's OverworldState.talkTo hook; returns true when a
    -- registered NPC handled the interaction.
    talkTo = function(ow, npc, helpers)
      local id = npc and npc.gen1onlineNpcId
      if not id then return false end
      local def = registry[id]
      if not def or type(def.interact) ~= "function" then return false end
      local game = (ow and ow.game) or (npc and npc.game)
      local ok, err = pcall(def.interact, game, npc, helpers)
      if not ok then
        print("[Gen1Online NPCs] interact() error on '" .. tostring(id) .. "': " .. tostring(err))
      end
      return true
    end,
  }

  return NPCs
end
