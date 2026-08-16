-- Pure valuation rules for the Game Corner pawn broker.
local Pawn = {}

Pawn.LIMIT = 5
Pawn.REDEEM_NUMERATOR = 13
Pawn.REDEEM_DENOMINATOR = 10

local function bounded(value, low, high)
  return math.max(low, math.min(high, tonumber(value) or low))
end

local function total(values)
  local sum = 0
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "special" }) do
    sum = sum + math.max(0, tonumber(values and values[key]) or 0)
  end
  return sum
end

function Pawn.value(mon, speciesDef)
  assert(type(mon) == "table", "pawn valuation needs a Pokemon")
  assert(type(speciesDef) == "table", "pawn valuation needs species data")
  local level = bounded(mon.level, 1, 100)
  local baseTotal = total(speciesDef.baseStats)
  local statTotal = total(mon.stats)
  local rarity = 256 - bounded(speciesDef.catchRate, 1, 255)
  local raw = math.floor((baseTotal * 3 + rarity * 6 + statTotal * 2 + level * 20) / 2)
  return math.max(50, math.min(7500, math.floor(raw / 10) * 10))
end

function Pawn.redeemCost(value)
  value = math.max(0, math.floor(tonumber(value) or 0))
  return math.ceil(value * Pawn.REDEEM_NUMERATOR / Pawn.REDEEM_DENOMINATOR)
end

return Pawn
