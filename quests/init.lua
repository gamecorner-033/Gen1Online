-- Quests Module Manager & UI System
-- Manages quest registry, custom quest items, network transport, and Quest Log UI

return function(loadModFile, mod)
  local Font = require("src.render.Font")
  local Menu = require("src.ui.Menu")
  local TextBox = require("src.render.TextBox")
  local Game = require("src.core.Game")

  local Quests = {}

  -- Load quest definitions dynamically using mod loader
  Quests.registry = {
    loadModFile(mod, "quests/quest_1.lua"),
    loadModFile(mod, "quests/quest_2.lua")
  }

  Quests.cache = {}

  -- Register custom quest items in game data
  function Quests.registerItems(game)
    game = game or Game
    if not game or not game.data or not game.data.items then return end

    if not game.data.items["MAGNET_COIL"] then
      game.data.items["MAGNET_COIL"] = {
        name = "MAGNET COIL",
        fullName = "Magnetized Coil",
        desc = "A conductive coil salvaged from a generator. Resonates with magnetic fields.",
        questItem = true,
        keyItem = false,
        price = 0
      }
    end

    if not game.data.items["CONDUIT_LENS"] then
      game.data.items["CONDUIT_LENS"] = {
        name = "CONDUIT LENS",
        fullName = "Conduit Lens",
        desc = "A polished glass lens used to focus electrical currents for optical circuits.",
        questItem = true,
        keyItem = false,
        price = 0
      }
    end
  end

  -- Helper to check if a Pokémon is BugHead's Butterfree
  function Quests.findBugHeadButterfreeIndex(party)
    if not party then return nil end
    for idx, mon in ipairs(party) do
      if mon and mon.species == "BUTTERFREE" then
        local ot = mon.ot or mon.otName or mon.originalTrainer
        if ot == "BugHead" then
          return idx, mon
        end
      end
    end
    return nil
  end

  -- Open Quest Details Screen (Tier 2)
  function Quests.openDetailsScreen(game, qDef, questsData)
    game = game or Game
    local qStatus = questsData[tostring(qDef.id)] or questsData[qDef.id] or { state = 0, step_flags = {} }
    local flags = qStatus.step_flags or {}

    local stateStr = "AVAILABLE"
    if qStatus.state == 1 then
      stateStr = "IN PROGRESS"
    elseif qStatus.state == 2 then
      stateStr = "COMPLETED"
    end

    local coilDone = flags.part_a_obtained or (game.save and game.save.inventory and game.save.inventory["MAGNET_COIL"])
    local lensDone = flags.part_b_obtained or (game.save and game.save.inventory and game.save.inventory["CONDUIT_LENS"])

    local container = {
      isOverworld = false,
      update = function(self, dt)
        local input = game.input
        if input:wasPressed("b") or input:wasPressed("a") or input:wasPressed("start") then
          game.stack:pop()
        elseif input:wasPressed("select") then
          local loreMsg = qDef.lore or "No additional information available."
          local wrapText = _G.wrapText or function(t) return t end
          game.stack:push(TextBox.new(game, wrapText(loreMsg)))
        end
      end,
      draw = function(self)
        Font.drawBox(0, 0, 20, 18)
        local hdr = "QUEST DETAILS"
        Font.draw(hdr, math.floor((160 - #hdr * 8) / 2), 10)
        Font.draw("==================", 8, 20)
        Font.draw(string.format("%s", qDef.title:sub(1, 18)), 8, 30)
        Font.draw(string.format("STATE: %s", stateStr), 8, 42)
        Font.draw("OBJECTIVES:", 8, 54)

        if qDef.id == 2 then
          local gotCat = (qStatus.state >= 1) or flags.caterpie_received
          local isBfree = (qStatus.state == 2) or (Quests.findBugHeadButterfreeIndex(game.save and game.save.party) ~= nil)
          local isDone = (qStatus.state == 2)
          Font.draw(string.format("[%s] TAKE CATERPIE", gotCat and "X" or " "), 8, 66)
          Font.draw(string.format("[%s] RAISE BUTTERFREE", isBfree and "X" or " "), 8, 78)
          Font.draw(string.format("[%s] RETURN TO BUGHEAD", isDone and "X" or " "), 8, 90)
          Font.draw("REWARD: BUGSY (MAX STAT)", 8, 104)
          Font.draw("BONUS:  +1,000 XP", 8, 114)
        else
          local returnDone = (qStatus.state == 2)
          Font.draw(string.format("[%s] COIL (UPPER)", coilDone and "X" or " "), 8, 66)
          Font.draw(string.format("[%s] LENS (BASEMENT)", lensDone and "X" or " "), 8, 78)
          Font.draw(string.format("[%s] RETURN W/ TEAM", returnDone and "X" or " "), 8, 90)
          Font.draw("REWARD: MAGNETON L30", 8, 104)
          Font.draw("BONUS:  +1,000 XP", 8, 114)
        end

        Font.draw("==================", 8, 122)
        Font.draw("SELECT:LORE  A:BACK", 8, 128)
      end
    }
    game.stack:push(container)
  end

  -- Open Quest Log Screen (Tier 1)
  function Quests.openLogScreen(game, fetchPlayerQuestsFn)
    game = game or Game
    local questsData = fetchPlayerQuestsFn and fetchPlayerQuestsFn(game) or Quests.cache
    local menuItems = {}

    for _, qDef in ipairs(Quests.registry) do
      local qStatus = questsData[tostring(qDef.id)] or questsData[qDef.id] or { state = 0 }
      local tag = "[NEW]"
      if qStatus.state == 1 then
        tag = "[ACTV]"
      elseif qStatus.state == 2 then
        tag = "[DONE]"
      end

      local labelStr = string.format("%s %s", qDef.shortLabel or qDef.title:sub(1, 10), tag)
      if #labelStr > 16 then labelStr = labelStr:sub(1, 16) end

      table.insert(menuItems, {
        label = labelStr,
        onSelect = function()
          Quests.openDetailsScreen(game, qDef, questsData)
        end
      })
    end

    table.insert(menuItems, { label = "BACK", onSelect = function() end })

    local menu = Menu.new(game, menuItems, { tx = 0, ty = 0, tw = 20, maxVisible = 7, startCloses = true })
    game.stack:push(menu)
  end

  return Quests
end
