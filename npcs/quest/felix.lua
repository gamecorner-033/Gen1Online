-- Quest NPC: Fixer Felix (Pallet Town - Quest #1: Magnemite Repair)
local NPC = require("src.world.NPC")
local TextBox = require("src.render.TextBox")
local ChoiceBox = require("src.ui.ChoiceBox")

local Felix = {
  id = "FIXER_FELIX",
  name = "FIXER FELIX",
  category = "quest",
  mapId = "PALLET_TOWN",
  sprite = "SPRITE_SCIENTIST",
  x = 6,
  y = 10,
  movement = "STAY",
  range = "DOWN",
  facing = "down",
}

function Felix.createNPC(data)
  local npc = NPC.new(data, Felix.mapId, {
    index = 99901,
    name = Felix.name,
    sprite = Felix.sprite,
    movement = Felix.movement,
    range = Felix.range,
    x = Felix.x,
    y = Felix.y,
  })
  npc.isFixerFelix = true
  npc.facing = Felix.facing
  npc.px = Felix.x * 16
  npc.py = Felix.y * 16
  npc.cellX = Felix.x
  npc.cellY = Felix.y
  npc.targetPx = Felix.x * 16
  npc.targetPy = Felix.y * 16
  return npc
end

function Felix.interact(game, npc, helpers)
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
  local getTrainerId = helpers.getTrainerId
  local fetchPlayerQuests = helpers.fetchPlayerQuests
  local questApiPost = helpers.questApiPost
  local activeQuestsCache = helpers.activeQuestsCache

  local tid = getTrainerId(game.save)
  local quests = fetchPlayerQuests(game)
  local q1 = quests["1"] or quests[1] or { state = 0, step_flags = {} }

  -- STATE 0: Not Started
  if q1.state == 0 then
    local introMsg = "The Power Plant is in disarray! A poor Magnemite is broken beyond repair.\fI need two brave trainers to retrieve a Magnetized Coil and a Conduit Lens.\fWill you work together?"
    game.stack:push(TextBox.new(game, wrapText(introMsg), function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if yes then
          local res = questApiPost({
            action = "quest_accept",
            trainerId = tid,
            questId = 1
          })
          activeQuestsCache["1"] = { state = 1, step_flags = { felix_talked = true, part_a_obtained = false, part_b_obtained = false } }
          local acceptMsg = "Thank you! Search the upper floor for the Coil and the basement for the Lens!\fRemember: each of you can only carry one part!"
          game.stack:push(TextBox.new(game, wrapText(acceptMsg), unfreeze))
        else
          game.stack:push(TextBox.new(game, wrapText("Oh dear... please return if you find a partner willing to help!"), unfreeze))
        end
      end))
    end))

  -- STATE 1: In Progress
  elseif q1.state == 1 then
    local res = questApiPost({
      action = "quest_turn_in",
      trainerId = tid,
      questId = 1,
      inventory = (game.save and game.save.inventory) or {}
    })

    if res and res.success then
      activeQuestsCache["1"] = { state = 2, step_flags = { completed = true } }
      local turnInMsg = (res.message or "Thanks to you two, this Magnemite is thriving! Look – it attracted a swarm! Here are two Magneton for your trouble!") .. "\fObtained MAGNETON LV30 and 1,000 MMO XP!"
      game.stack:push(TextBox.new(game, wrapText(turnInMsg), unfreeze))
    else
      local errReason = (res and res.error) or "NOT_READY"
      local errText = (res and res.message) or "Please find a partner! One of you must carry the Magnetized Coil and the other the Conduit Lens!"
      game.stack:push(TextBox.new(game, wrapText(errText), unfreeze))
    end

  -- STATE 2: Completed
  elseif q1.state == 2 then
    local doneMsg = "Thanks to you and your partner, the Power Plant is humming smoothly again!"
    game.stack:push(TextBox.new(game, wrapText(doneMsg), unfreeze))
  end
end

return Felix
