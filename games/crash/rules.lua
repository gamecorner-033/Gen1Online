-- Pure rules for the Game Corner Crash machine.
local Crash = {}

Crash.BETS = { 10, 50, 100, 500 }
Crash.HOUSE_EDGE = 0.03
Crash.MAX_MULTIPLIER = 50
Crash.GROWTH_RATE = 0.20

local function clamp(value, low, high)
  return math.max(low, math.min(high, tonumber(value) or low))
end

-- The familiar crash distribution: chance to survive to x is roughly
-- (1-house edge)/x. A three-percent slice crashes immediately at 1.00x.
function Crash.crashPoint(unit)
  local u = clamp(unit, 0, 0.999999)
  if u < Crash.HOUSE_EDGE then return 1 end
  local point = (1 - Crash.HOUSE_EDGE) / (1 - u)
  point = math.floor(point * 100) / 100
  return math.max(1, math.min(Crash.MAX_MULTIPLIER, point))
end

function Crash.multiplier(elapsed)
  elapsed = math.max(0, tonumber(elapsed) or 0)
  local value = math.exp(elapsed * Crash.GROWTH_RATE)
  return math.min(Crash.MAX_MULTIPLIER, math.floor(value * 100) / 100)
end

function Crash.payout(bet, multiplier)
  bet = math.max(0, math.floor(tonumber(bet) or 0))
  multiplier = math.max(1, tonumber(multiplier) or 1)
  return math.floor(bet * multiplier)
end

return Crash
