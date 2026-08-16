-- Quests framework — Gen 2 port (WIP)
--
-- This is a REGISTRY SKELETON. The old Gen 1 quest content (Magnemite
-- Repair co-op quest, Bye Bye Butterfree solo quest, and their in-world
-- items/NPCs) was removed during the migration to Gen 2. Nothing is active
-- yet.
--
-- The server remains authoritative for quest state (QUEST_DEFINITIONS and
-- QuestManager in gts_server.py; the quest_get / quest_accept / quest_pickup
-- / quest_turn_in endpoints). main.lua already fetches the player's quests
-- via fetchPlayerQuests() -> action "get_quests" and caches them in
-- activeQuestsCache, so new quest UI/content should read from that cache
-- rather than re-fetching.
--
-- HOW TO ADD CONTENT (the format):
--
--   Quests.register({
--     id     = "my_quest",       -- unique id
--     title  = "MY QUEST",
--     maps   = { "GOLDENROD_CITY" }, -- map ids where this quest's markers live
--     giver  = "my_npc_id",      -- optional: matches an id registered in
--                                -- npcs/init.lua
--     -- Run when the player interacts with the quest's in-world marker(s).
--     -- helpers is the same table main.lua hands NPC.interact().
--     interact = function(game, npc, helpers)
--       ...
--     end,
--   })
--
-- The quest-log UI (Start Menu -> QUEST, per the README) is NOT implemented
-- yet; it is the first piece to build on top of this registry.
--
-- GEN 2 CONSTRAINTS: same asset/battle rules as npcs/init.lua — no ROM-derived
-- cache path references, no BattleState.newTrainer/makeBattler calls.

return function(loadModFile, mod)
  local registry = {}   -- id -> def

  local Quests = {
    registry = registry,

    -- Content entry point. Register every quest definition once at load time.
    register = function(def)
      if type(def) ~= "table" or type(def.id) ~= "string" then
        print("[Gen1Online Quests] register() requires a table with a string id")
        return nil
      end
      registry[def.id] = def
      return def
    end,

    getActiveQuests = function()
      return {}
    end,

    -- Legacy helper the talk-to hook still references; returns nil now that
    -- the BugHead content is gone. Remove this once the talk-to hook is
    -- migrated to the new helpers surface.
    findBugHeadButterfreeIndex = function()
      return nil
    end,
  }

  return Quests
end
