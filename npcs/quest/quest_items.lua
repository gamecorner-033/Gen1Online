-- Quest Item Pickups: Power Plant (Coil & Lens)
local NPC = require("src.world.NPC")
local TextBox = require("src.render.TextBox")

local QuestItems = {}

function QuestItems.createCoilNPC(data)
  local ballA = NPC.new(data, "POWER_PLANT", {
    index = 99902,
    name = "BALL_COIL",
    sprite = "SPRITE_POKE_BALL",
    movement = "STAY",
    range = "NONE",
    x = 4,
    y = 9,
  })
  ballA.isQuestCoil = true
  ballA.px = 4 * 16
  ballA.py = 9 * 16
  ballA.cellX = 4
  ballA.cellY = 9
  return ballA
end

function QuestItems.createLensNPC(data)
  local ballB = NPC.new(data, "POWER_PLANT", {
    index = 99903,
    name = "BALL_LENS",
    sprite = "SPRITE_POKE_BALL",
    movement = "STAY",
    range = "NONE",
    x = 34,
    y = 32,
  })
  ballB.isQuestLens = true
  ballB.px = 34 * 16
  ballB.py = 32 * 16
  ballB.cellX = 34
  ballB.cellY = 32
  return ballB
end

function QuestItems.interact(game, itemId, itemName, helpers)
  game = game or _G.Game
  local wrapText = helpers.wrapText
  local getTrainerId = helpers.getTrainerId
  local fetchPlayerQuests = helpers.fetchPlayerQuests
  local questApiPost = helpers.questApiPost
  local activeQuestsCache = helpers.activeQuestsCache

  local tid = getTrainerId(game.save)
  local quests = fetchPlayerQuests(game)
  local q1 = quests["1"] or quests[1] or { state = 0 }

  if q1.state == 0 then
    game.stack:push(TextBox.new(game, wrapText("A strange electronic component is lodged here. You don't know what it's for.")))
    return
  elseif q1.state == 2 then
    game.stack:push(TextBox.new(game, wrapText("The container is empty.")))
    return
  end

  local res = questApiPost({
    action = "quest_pickup",
    trainerId = tid,
    questId = 1,
    itemId = itemId
  })

  if res and res.success then
    game.save.inventory = game.save.inventory or {}
    game.save.inventory[itemId] = (game.save.inventory[itemId] or 0) + 1
    if itemId == "MAGNET_COIL" then
      activeQuestsCache["1"] = activeQuestsCache["1"] or { state = 1, step_flags = {} }
      activeQuestsCache["1"].step_flags.part_a_obtained = true
    elseif itemId == "CONDUIT_LENS" then
      activeQuestsCache["1"] = activeQuestsCache["1"] or { state = 1, step_flags = {} }
      activeQuestsCache["1"].step_flags.part_b_obtained = true
    end
    game.stack:push(TextBox.new(game, wrapText(string.format("Obtained %s!", itemName))))
  else
    local msg = (res and res.message) or "You can't carry this item right now."
    game.stack:push(TextBox.new(game, wrapText(msg)))
  end
end

return QuestItems
