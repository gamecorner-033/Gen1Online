-- Trade NPC: Creepy Trainer (Pewter City - Haunter -> Gengar Trade Evolution)
local NPC = require("src.world.NPC")
local TextBox = require("src.render.TextBox")
local ChoiceBox = require("src.ui.ChoiceBox")
local Pokemon = require("src.pokemon.Pokemon")

local HaunterTrader = {
  id = "HAUNTER_TRADER",
  name = "CREEPY_TRAINER",
  category = "trade",
  mapId = "PEWTER_CITY",
  sprite = "SPRITE_SUPER_NERD",
  x = 20,
  y = 17,
  movement = "STAY",
  range = "DOWN",
  facing = "down",
}

function HaunterTrader.createNPC(data)
  local npc = NPC.new(data, HaunterTrader.mapId, {
    index = 99905,
    name = HaunterTrader.name,
    sprite = HaunterTrader.sprite,
    movement = HaunterTrader.movement,
    range = HaunterTrader.range,
    x = HaunterTrader.x,
    y = HaunterTrader.y,
  })
  npc.isHaunterTrader = true
  npc.facing = HaunterTrader.facing
  npc.px = HaunterTrader.x * 16
  npc.py = HaunterTrader.y * 16
  npc.cellX = HaunterTrader.x
  npc.cellY = HaunterTrader.y
  npc.targetPx = HaunterTrader.x * 16
  npc.targetPy = HaunterTrader.y * 16
  return npc
end

function HaunterTrader.interact(game, npc, helpers)
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

  if game.save and game.save.haunterTradeDone then
    local doneMsg = "How is GENGAR doing?\fI'm so glad it's not haunting my dreams anymore!"
    game.stack:push(TextBox.new(game, wrapText(doneMsg), unfreeze))
    return
  end

  local introMsg = "Eek! My HAUNTER is way too creepy!\fIt keeps floating around and moving my things while I sleep...\fWould you trade one of your POKéMON for my HAUNTER?"
  game.stack:push(TextBox.new(game, wrapText(introMsg), function()
    game.stack:push(ChoiceBox.new(game, function(yes)
      if not yes then
        game.stack:push(TextBox.new(game, wrapText("Oh... guess I'll have to sleep with the lights on..."), unfreeze))
        return
      end

      if not game.save or not game.save.party or #game.save.party == 0 then
        game.stack:push(TextBox.new(game, wrapText("You don't have any POKéMON in your party to trade!"), unfreeze))
        return
      end

      local PartyMenu = require("src.ui.PartyMenu")
      local TradeAnim = require("src.ui.TradeAnim")
      local Evolution = require("src.pokemon.Evolution")

      game.stack:push(PartyMenu.new(game, {
        pickOnly = true,
        onCancel = function()
          game.stack:push(TextBox.new(game, wrapText("Oh... guess I'll have to sleep with the lights on..."), unfreeze))
        end,
        onSwitch = function(pickedMon, partyMenuObj)
          local slotIndex = partyMenuObj and partyMenuObj.index
          if not slotIndex or not game.save.party[slotIndex] then
            for i, m in ipairs(game.save.party) do
              if m == pickedMon then slotIndex = i break end
            end
          end

          if not slotIndex then
            unfreeze()
            return
          end

          local sentMon = pickedMon
          local sentLevel = math.max(5, sentMon.level or 25)
          local newMon = Pokemon.new(game.data, "HAUNTER", sentLevel)
          newMon.nickname = "HAUNTER"
          newMon.ot = "CREEPY"
          newMon.otName = "CREEPY"
          newMon.originalTrainer = "CREEPY"
          newMon.otId = 42069
          newMon.traded = true

          -- Replace traded mon in party
          table.remove(game.save.party, slotIndex)
          table.insert(game.save.party, newMon)

          -- Update Pokédex for Haunter
          if game.save and game.save.pokedex then
            game.save.pokedex.seen["HAUNTER"] = true
            game.save.pokedex.owned["HAUNTER"] = true
          end

          -- Launch Vanilla Trade Sequence
          game.stack:push(TradeAnim.new(game, {
            sent = sentMon,
            received = newMon,
            enemyName = "CREEPY",
            playerOt = (game.save.player and game.save.player.name) or "RED",
            playerOtId = sentMon.otId or (game.save.player and game.save.player.id) or 0,
            enemyOtId = newMon.otId,
            onDone = function()
              game.save.haunterTradeDone = true

              -- Trigger Trade Evolution: HAUNTER -> GENGAR!
              Evolution.evolve(game, newMon, "GENGAR", function()
                if game.save and game.save.pokedex then
                  game.save.pokedex.seen["GENGAR"] = true
                  game.save.pokedex.owned["GENGAR"] = true
                end
                unfreeze()
              end, "TRADE")
            end
          }))
        end
      }))
    end))
  end))
end

return HaunterTrader
