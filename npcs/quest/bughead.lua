-- Quest NPC: Bug Catcher BugHead (Viridian Forest - Quest #2: Bye Bye Butterfree)
local NPC = require("src.world.NPC")
local TextBox = require("src.render.TextBox")
local ChoiceBox = require("src.ui.ChoiceBox")
local Pokemon = require("src.pokemon.Pokemon")
local Stats = require("src.pokemon.Stats")

local BugHead = {
  id = "BUGHEAD",
  name = "BUGHEAD",
  category = "quest",
  mapId = "VIRIDIAN_FOREST",
  sprite = "SPRITE_YOUNGSTER",
  x = 16,
  y = 19,
  movement = "STAY",
  range = "DOWN",
  facing = "down",
}

function BugHead.createNPC(data)
  local npc = NPC.new(data, BugHead.mapId, {
    index = 99904,
    name = BugHead.name,
    sprite = BugHead.sprite,
    movement = BugHead.movement,
    range = BugHead.range,
    x = BugHead.x,
    y = BugHead.y,
  })
  npc.isBugHeadNpc = true
  npc.facing = BugHead.facing
  npc.px = BugHead.x * 16
  npc.py = BugHead.y * 16
  npc.cellX = BugHead.x
  npc.cellY = BugHead.y
  npc.targetPx = BugHead.x * 16
  npc.targetPy = BugHead.y * 16
  return npc
end

local function createBugHeadCaterpie(game)
  local mon = Pokemon.new(game.data, "CATERPIE", 5)
  mon.ot = "BugHead"
  mon.otName = "BugHead"
  mon.originalTrainer = "BugHead"
  mon.otId = 99999
  return mon
end

local function createBugsyCaterpie(game)
  local mon = Pokemon.new(game.data, "CATERPIE", 5)
  mon.nickname = "BUGSY"
  mon.name = "BUGSY"
  mon.dvs = { hp = 15, attack = 15, defense = 15, speed = 15, special = 15 }
  mon.statExp = { hp = 65535, attack = 65535, defense = 65535, speed = 65535, special = 65535 }
  local def = game.data and game.data.pokemon and game.data.pokemon["CATERPIE"]
  if def and Stats and Stats.calc then
    mon.stats = Stats.calc(def, 5, mon.dvs, mon.statExp)
    mon.hp = mon.stats.hp
  end
  return mon
end

function BugHead.interact(game, npc, helpers)
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
  local findBugHeadButterfreeIndex = helpers.findBugHeadButterfreeIndex

  local tid = getTrainerId(game.save)
  local quests = fetchPlayerQuests(game)
  local q2 = quests["2"] or quests[2] or { state = 0, step_flags = {} }

  -- STATE 0: Not Started
  if q2.state == 0 then
    local introMsg = "Hi there! I'm Bug Catcher BugHead!\fI have a Caterpie that needs a good trainer to help it grow into a Butterfree.\fWill you take my Caterpie and help it evolve into Butterfree?"
    game.stack:push(TextBox.new(game, wrapText(introMsg), function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if yes then
          if not game.save or not game.save.party or #game.save.party >= 6 then
            game.stack:push(TextBox.new(game, wrapText("Your party is full! Please make room in your party first!"), unfreeze))
          else
            local res = questApiPost({
              action = "quest_accept",
              trainerId = tid,
              questId = 2
            })
            local caterpie = createBugHeadCaterpie(game)
            table.insert(game.save.party, caterpie)
            activeQuestsCache["2"] = { state = 1, step_flags = { caterpie_received = true } }

            local acceptMsg = "Bug Catcher BugHead handed over CATERPIE (OT: BugHead)!\fPlease raise it all the way up to a Butterfree and bring it back!"
            game.stack:push(TextBox.new(game, wrapText(acceptMsg), unfreeze))
          end
        else
          game.stack:push(TextBox.new(game, wrapText("Aww... come back if you change your mind!"), unfreeze))
        end
      end))
    end))

  -- STATE 1: In Progress
  elseif q2.state == 1 then
    local party = game.save and game.save.party
    local butterfreeIdx, butterfreeMon = findBugHeadButterfreeIndex(party)

    if not butterfreeIdx then
      local inProgMsg = "How is my Caterpie doing?\fRaise it until it evolves into a Butterfree (OT: BugHead), then bring it back to me!"
      game.stack:push(TextBox.new(game, wrapText(inProgMsg), unfreeze))
    else
      -- Found Butterfree with OT BugHead! Remove from party
      local removedMon = table.remove(party, butterfreeIdx)

      -- Check party capacity for reward (BUGSY)
      if #party >= 6 then
        table.insert(party, butterfreeIdx, removedMon)
        game.stack:push(TextBox.new(game, wrapText("Your party is full! Please make room so I can give you your reward!"), unfreeze))
      else
        local res = questApiPost({
          action = "quest_turn_in",
          trainerId = tid,
          questId = 2
        })

        local bugsy = createBugsyCaterpie(game)
        table.insert(party, bugsy)
        activeQuestsCache["2"] = { state = 2, step_flags = { completed = true } }

        local completeMsg = "Wow! You raised my Caterpie into a magnificent Butterfree!\fIt's time for it to fly free... Bye Bye Butterfree!\fAs a thank you, take this special MAX STAT Caterpie!\fObtained BUGSY!"
        game.stack:push(TextBox.new(game, wrapText(completeMsg), unfreeze))
      end
    end

  -- STATE 2: Completed
  elseif q2.state == 2 then
    local endMsg = "Butterfree is flying free in the sky!\fThanks to you, BUGSY is in great hands!"
    game.stack:push(TextBox.new(game, wrapText(endMsg), unfreeze))
  end
end

return BugHead
