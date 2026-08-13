-- Battle NPC: Youngster Charlie (Route 1 - Northern End)
-- Features a Level 7 Growlithe trainer battle
local NPC = require("src.world.NPC")
local TextBox = require("src.render.TextBox")
local ChoiceBox = require("src.ui.ChoiceBox")
local BattleState = require("src.battle.BattleState")

local Route1Trainer = {
  id = "ROUTE1_CHARLIE",
  name = "YOUNGSTER CHARLIE",
  category = "battle",
  mapId = "ROUTE_1",
  sprite = "SPRITE_YOUNGSTER",
  x = 10,
  y = 3,
  movement = "STAY",
  range = "DOWN",
  facing = "down",
}

function Route1Trainer.createNPC(data)
  local npc = NPC.new(data, Route1Trainer.mapId, {
    index = 99906,
    name = Route1Trainer.name,
    sprite = Route1Trainer.sprite,
    movement = Route1Trainer.movement,
    range = Route1Trainer.range,
    x = Route1Trainer.x,
    y = Route1Trainer.y,
  })
  npc.isRoute1Charlie = true
  npc.facing = Route1Trainer.facing
  npc.px = Route1Trainer.x * 16
  npc.py = Route1Trainer.y * 16
  npc.cellX = Route1Trainer.x
  npc.cellY = Route1Trainer.y
  npc.targetPx = Route1Trainer.x * 16
  npc.targetPy = Route1Trainer.y * 16
  return npc
end

local function registerCharlieTrainerData(game)
  if game and game.data and game.data.trainers then
    if not game.data.trainers["OPP_ROUTE1_CHARLIE"] then
      game.data.trainers["OPP_ROUTE1_CHARLIE"] = {
        id = "OPP_ROUTE1_CHARLIE",
        index = 99,
        name = "YOUNGSTER CHARLIE",
        baseMoney = 15,
        aiMods = { 1 },
        pic = "assets/generated/battle/trainers/youngster.png",
        parties = {
          {
            { species = "GROWLITHE", level = 7 }
          }
        }
      }
    end
  end
end

function Route1Trainer.interact(game, npc, helpers)
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
  registerCharlieTrainerData(game)

  -- Check if already defeated this session
  if game.save and game.save.charlieDefeated then
    local defeatedMsg = "Whew! Your POKéMON are really strong!\fMy GROWLITHE and I are gonna train hard so we can win next time!"
    game.stack:push(TextBox.new(game, wrapText(defeatedMsg), unfreeze))
    return
  end

  local introMsg = "Hey there! I'm training my GROWLITHE on Route 1 before taking on the Gym!\fWant to have a quick battle with us?"
  game.stack:push(TextBox.new(game, wrapText(introMsg), function()
    game.stack:push(ChoiceBox.new(game, function(yes)
      if not yes then
        game.stack:push(TextBox.new(game, wrapText("Aww, alright. Let me know if you change your mind!"), unfreeze))
        return
      end

      -- Check healthy party
      local Party = require("src.pokemon.Party")
      local healthyMon = Party.firstHealthy(game.save and game.save.party)
      if not healthyMon then
        game.stack:push(TextBox.new(game, wrapText("You don't have any healthy POKéMON left to battle!"), unfreeze))
        return
      end

      -- Launch Trainer Battle
      local battle = BattleState.newTrainer(game, "OPP_ROUTE1_CHARLIE", 1)
      local origOnFinish = battle.onFinish
      battle.onFinish = function(result)
        if origOnFinish then origOnFinish(result) end
        if result == "win" then
          game.save.charlieDefeated = true
          if helpers.addMmoXp then
            helpers.addMmoXp(game, 150, "DEFECATED YOUNGSTER CHARLIE")
          end
          game.stack:push(TextBox.new(game, wrapText("YOUNGSTER CHARLIE: Great battle! Here's $105 for winning!\fObtained $105 and 150 MMO XP!"), unfreeze))
        else
          game.stack:push(TextBox.new(game, wrapText("YOUNGSTER CHARLIE: Yeah! GROWLITHE and I pulled it off!"), unfreeze))
        end
      end
      game.stack:push(battle)
    end))
  end))
end

return Route1Trainer
