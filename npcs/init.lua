-- Central Custom NPC Manager
-- Organizes and routes custom NPCs across Categories: quest, trade, shop, battle

return function(loadModFile, mod)
  local Game = require("src.core.Game")

  local NPCs = {}

  -- Load categorized NPC definitions using mod file loader
  NPCs.quest = {
    felix = loadModFile(mod, "npcs/quest/felix.lua"),
    bughead = loadModFile(mod, "npcs/quest/bughead.lua"),
    items = loadModFile(mod, "npcs/quest/quest_items.lua")
  }

  NPCs.trade = {
    haunter = loadModFile(mod, "npcs/trade/haunter_trader.lua")
  }

  NPCs.shop = loadModFile(mod, "npcs/shop/index.lua")
  NPCs.battle = loadModFile(mod, "npcs/battle/index.lua")

  local function safeCreateAndInsert(ow, flagKey, createFn)
    for _, n in ipairs(ow.npcs) do
      if n[flagKey] then return end
    end
    local data = (ow.game and ow.game.data) or Game.data or require("src.core.Data")
    local ok, npc = pcall(createFn, data)
    if ok and npc then
      table.insert(ow.npcs, npc)
      table.insert(ow.entities, npc)
    else
      print("[Gen1Online NPCs] Warning: Failed to spawn custom NPC (" .. tostring(flagKey) .. "): " .. tostring(npc))
    end
  end

  -- Spawn all relevant custom NPCs for the current overworld map
  function NPCs.spawnForMap(ow)
    if not ow or not ow.map or not ow.npcs then return end
    local mapId = ow.map.id

    -- 1. Pallet Town: Fixer Felix
    if mapId == "PALLET_TOWN" and NPCs.quest.felix then
      safeCreateAndInsert(ow, "isFixerFelix", NPCs.quest.felix.createNPC)
    end

    -- 2. Viridian Forest: Bug Catcher BugHead
    if mapId == "VIRIDIAN_FOREST" and NPCs.quest.bughead then
      safeCreateAndInsert(ow, "isBugHeadNpc", NPCs.quest.bughead.createNPC)
    end

    -- 3. Power Plant: Quest Items (Coil & Lens)
    if mapId == "POWER_PLANT" and NPCs.quest.items then
      safeCreateAndInsert(ow, "isQuestCoil", NPCs.quest.items.createCoilNPC)
      safeCreateAndInsert(ow, "isQuestLens", NPCs.quest.items.createLensNPC)
    end

    -- 4. Pewter City: Creepy Trainer (Haunter Trade)
    if mapId == "PEWTER_CITY" and NPCs.trade.haunter then
      safeCreateAndInsert(ow, "isHaunterTrader", NPCs.trade.haunter.createNPC)
    end
  end

  -- Route player interaction to the custom NPC handler
  function NPCs.talkTo(ow, npc, helpers)
    if npc.isFixerFelix and NPCs.quest.felix then
      NPCs.quest.felix.interact(ow.game or Game, npc, helpers)
      return true
    end
    if npc.isBugHeadNpc and NPCs.quest.bughead then
      NPCs.quest.bughead.interact(ow.game or Game, npc, helpers)
      return true
    end
    if npc.isQuestCoil and NPCs.quest.items then
      NPCs.quest.items.interact(ow.game or Game, "MAGNET_COIL", "MAGNETIZED COIL", helpers)
      return true
    end
    if npc.isQuestLens and NPCs.quest.items then
      NPCs.quest.items.interact(ow.game or Game, "CONDUIT_LENS", "CONDUIT LENS", helpers)
      return true
    end
    if npc.isHaunterTrader and NPCs.trade.haunter then
      NPCs.trade.haunter.interact(ow.game or Game, npc, helpers)
      return true
    end
    return false
  end

  return NPCs
end
