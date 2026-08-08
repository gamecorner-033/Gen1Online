local CoinCase = {}

local function configuredCap(game)
  local constants = game and game.data and game.data.constants
  return math.max(9999, math.floor(tonumber(constants and constants.coinCap) or 9999))
end

function CoinCase.installSlotCompatibility()
  local Font = require("src.render.Font")
  local SlotMachine = require("src.ui.SlotMachine")
  local state = SlotMachine._blackjackCornerMillionCoinCase
  if type(state) ~= "table" then
    state = { vanillaUpdate = SlotMachine.update, vanillaDraw = SlotMachine.draw }
    SlotMachine._blackjackCornerMillionCoinCase = state
    function SlotMachine:update(dt) return state.update(self, dt) end
    function SlotMachine:draw() return state.draw(self) end
  end

  state.update = function(self, dt)
    if configuredCap(self.game) <= 9999 then return state.vanillaUpdate(self, dt) end
    local beforeCoins = tonumber(self.game.save.coins) or 0
    local beforePayout = tonumber(self.payoutRemaining) or 0
    state.vanillaUpdate(self, dt)
    local paid = beforePayout - (tonumber(self.payoutRemaining) or 0)
    local activeCap = configuredCap(self.game)
    if activeCap > 9999 and beforeCoins >= 9999 and paid > 0
        and self.game.save.coins == 9999 then
      self.game.save.coins = math.min(activeCap, beforeCoins + paid)
    end
  end

  local function compact(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    if value >= 1000000 then return "1.0M" end
    if value >= 10000 then return tostring(math.floor(value / 1000)) .. "K" end
    return ("%4d"):format(value)
  end

  state.draw = function(self)
    if configuredCap(self.game) <= 9999 then return state.vanillaDraw(self) end
    state.vanillaDraw(self)
    local value = tonumber(self.game.save.coins) or 0
    if value <= 9999 then return end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 40, 8, 32, 8)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(compact(value), 40, 8)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

function CoinCase.installHiddenCoinCompatibility(_, OverworldState, Game)
  OverworldState = OverworldState or require("src.world.OverworldController")
  Game = Game or require("src.core.Game")
  local state = OverworldState._blackjackCornerMillionCoinCase
  if type(state) ~= "table" then
    state = { vanillaTryHiddenObject = OverworldState.tryHiddenObject }
    OverworldState._blackjackCornerMillionCoinCase = state
    function OverworldState:tryHiddenObject(fx, fy)
      return state.tryHiddenObject(self, fx, fy)
    end
  end

  state.tryHiddenObject = function(self, fx, fy)
    if configuredCap(Game) <= 9999 then
      return state.vanillaTryHiddenObject(self, fx, fy)
    end
    local save = Game.save
    local mapId = self.map and self.map.id
    local key = mapId and (mapId .. "_" .. fx .. "_" .. fy)
    local hiddenCoin
    for _, candidate in ipairs(Game.data.field.hiddenCoins
        and Game.data.field.hiddenCoins[mapId] or {}) do
      if candidate.x == fx and candidate.y == fy then hiddenCoin = candidate; break end
    end
    local eligible = hiddenCoin and save and save.inventory
      and save.inventory.COIN_CASE and not (save.hiddenTaken and save.hiddenTaken[key])
    local beforeCoins = eligible and math.max(0, tonumber(save.coins) or 0) or 0
    local handled = state.vanillaTryHiddenObject(self, fx, fy)
    local expected = beforeCoins + math.max(0, tonumber(hiddenCoin and hiddenCoin.coins) or 0)
    local activeCap = configuredCap(Game)
    if activeCap > 9999 and eligible and handled and expected > 9999
        and tonumber(save.coins) == 9999 then
      save.coins = math.min(activeCap, expected)
    end
    return handled
  end
end

return CoinCase
