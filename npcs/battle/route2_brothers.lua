-- Battle NPC: Wonder Brothers (Dan & Dave) on Route 2
-- Features Gen 1 Online's first story 2v2 Double Battle!
local NPC = require("src.world.NPC")
local TextBox = require("src.render.TextBox")
local ChoiceBox = require("src.ui.ChoiceBox")
local BattleState = require("src.battle.BattleState")

local Route2Brothers = {
  mapId = "ROUTE_2",
  dan = {
    id = "ROUTE2_DAN",
    name = "YOUNGSTER DAN",
    sprite = "SPRITE_YOUNGSTER",
    x = 8,
    y = 65,
    facing = "right",
  },
  dave = {
    id = "ROUTE2_DAVE",
    name = "YOUNGSTER DAVE",
    sprite = "SPRITE_YOUNGSTER",
    x = 9,
    y = 65,
    facing = "left",
  }
}

function Route2Brothers.createDanNPC(data)
  local npc = NPC.new(data, Route2Brothers.mapId, {
    index = 99907,
    name = Route2Brothers.dan.name,
    sprite = Route2Brothers.dan.sprite,
    movement = "STAY",
    range = "RIGHT",
    x = Route2Brothers.dan.x,
    y = Route2Brothers.dan.y,
  })
  npc.isRoute2Dan = true
  npc.facing = Route2Brothers.dan.facing
  npc.px = Route2Brothers.dan.x * 16
  npc.py = Route2Brothers.dan.y * 16
  npc.cellX = Route2Brothers.dan.x
  npc.cellY = Route2Brothers.dan.y
  npc.targetPx = Route2Brothers.dan.x * 16
  npc.targetPy = Route2Brothers.dan.y * 16
  return npc
end

function Route2Brothers.createDaveNPC(data)
  local npc = NPC.new(data, Route2Brothers.mapId, {
    index = 99908,
    name = Route2Brothers.dave.name,
    sprite = Route2Brothers.dave.sprite,
    movement = "STAY",
    range = "LEFT",
    x = Route2Brothers.dave.x,
    y = Route2Brothers.dave.y,
  })
  npc.isRoute2Dave = true
  npc.facing = Route2Brothers.dave.facing
  npc.px = Route2Brothers.dave.x * 16
  npc.py = Route2Brothers.dave.y * 16
  npc.cellX = Route2Brothers.dave.x
  npc.cellY = Route2Brothers.dave.y
  npc.targetPx = Route2Brothers.dave.x * 16
  npc.targetPy = Route2Brothers.dave.y * 16
  return npc
end

local function registerBrothersTrainerData(game)
  local data = (game and game.data) or require("src.core.Data")
  if data and data.trainers then
    data.trainers["OPP_ROUTE2_DAN"] = {
      id = "OPP_ROUTE2_DAN",
      index = 101,
      name = "YOUNGSTER DAN",
      baseMoney = 18,
      aiMods = { 1 },
      pic = "assets/generated/battle/trainers/youngster.png",
      parties = {
        {
          { species = "PIDGEY", level = 8 },
          { species = "SPEAROW", level = 9 }
        }
      }
    }

    data.trainers["OPP_ROUTE2_DAVE"] = {
      id = "OPP_ROUTE2_DAVE",
      index = 102,
      name = "YOUNGSTER DAVE",
      baseMoney = 18,
      aiMods = { 1 },
      pic = "assets/generated/battle/trainers/youngster.png",
      parties = {
        {
          { species = "RATTATA", level = 8 },
          { species = "EKANS", level = 9 }
        }
      }
    }
  end
end

-- Eagerly register at module load
pcall(registerBrothersTrainerData)

local function countAblePokemon(party)
  if not party then return 0 end
  local count = 0
  for _, m in ipairs(party) do
    if m and (m.hp or 0) > 0 then
      count = count + 1
    end
  end
  return count
end

function Route2Brothers.interact(game, npc, helpers)
  if npc then
    npc.frozen = true
    if game.overworld and game.overworld.player then
      npc:facePlayer(game.overworld.player)
    end
  end
  local unfreeze = function()
    if npc then npc.frozen = false end
  end

  local wrapText = helpers.wrapText
  registerBrothersTrainerData(game)

  -- Check if already defeated
  if game.save and game.save.route2BrothersDefeated then
    local defeatedMsg = "DAN: Whoa! Your teamwork is incredible!\fDAVE: We need to practice our double battle combos more!"
    game.stack:push(TextBox.new(game, wrapText(defeatedMsg), unfreeze))
    return
  end

  local party = game.save and game.save.party
  local ableCount = countAblePokemon(party)

  if ableCount == 0 then
    game.stack:push(TextBox.new(game, wrapText("You don't have any healthy POKéMON left to battle!"), unfreeze))
    return
  end

  local function startBrothersDoubleBattle()
    unfreeze()
    local Doubles = helpers and helpers.Doubles
    if Doubles and Doubles.startTrainerPair then
      local ok, res = pcall(Doubles.startTrainerPair, "OPP_ROUTE2_DAN", 1, "OPP_ROUTE2_DAVE", 1)
      if ok and res then
        return
      end
    end

    -- Fallback to standard trainer battle
    local battle = BattleState.newTrainer(game, "OPP_ROUTE2_DAN", 1)
    if battle then
      battle.afterBattle = function(result)
        if result == "win" or result == "won" then
          if game.save then
            game.save.route2BrothersDefeated = true
          end
          if helpers and helpers.addMmoXp then
            helpers.addMmoXp(game, "trainer_battle", 250)
          end
          local winMsg = "DAN & DAVE: Unbelievable!\fYou took down both of us! You're a true Double Battle master!"
          game.stack:push(TextBox.new(game, wrapText(winMsg), nil))
        end
      end
      game.stack:push(battle)
    end
  end

  -- If only 1 healthy Pokémon in party, show special warning
  if ableCount == 1 then
    local warnMsg = "BROTHERS: We are the WONDER BROTHERS!\nWe only fight together in 2-on-2 DOUBLE BATTLES!\f...Wait! You only have 1 able POKéMON in your party!\fAre you sure you want to take both of us on 2-on-1?"
    game.stack:push(TextBox.new(game, wrapText(warnMsg), function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if not yes then
          game.stack:push(TextBox.new(game, wrapText("Come back with a partner POKéMON when you're ready!"), unfreeze))
          return
        end
        game.stack:push(TextBox.new(game, wrapText("Alright! That's courage!\nLet's see if you can withstand our combo!"), function()
          startBrothersDoubleBattle()
        end))
      end))
    end))
    return
  end

  -- Player has 2+ Pokémon: Standard 2v2 double battle invitation
  local introMsg = "BROTHERS: We are the WONDER BROTHERS!\nTwo heads are better than one!\fLet's see how you handle our combination attack in a DOUBLE BATTLE!"
  game.stack:push(TextBox.new(game, wrapText(introMsg), function()
    game.stack:push(ChoiceBox.new(game, function(yes)
      if not yes then
        game.stack:push(TextBox.new(game, wrapText("Aww! Double battles are super fun!\nLet us know when you're ready!"), unfreeze))
        return
      end
      game.stack:push(TextBox.new(game, wrapText("DAN: Go, PIDGEY!\nDAVE: Go, RATTATA!\nLet's do this!"), function()
        startBrothersDoubleBattle()
      end))
    end))
  end))
end

return Route2Brothers
