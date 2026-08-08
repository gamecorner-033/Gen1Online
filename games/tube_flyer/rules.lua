-- Deterministic physics for the ten-coin Game Corner flying game.
local Flappy = {}

Flappy.COST = 10
Flappy.BIRD_X = 32
Flappy.BIRD_SIZE = 7
Flappy.TOP = 18
Flappy.BOTTOM = 124
Flappy.GRAVITY = 190
Flappy.FLAP_VELOCITY = -72
Flappy.TUBE_WIDTH = 18
Flappy.TUBE_GAP = 38
Flappy.TUBE_SPEED = 44
Flappy.TUBE_SPACING = 64

local function nextGap(random)
  return 50 + (random and random(39) or math.random(39))
end

function Flappy.new(random)
  local state = { y = 68, velocity = 0, alive = true, score = 0, tubes = {} }
  for index = 1, 3 do
    state.tubes[index] = {
      x = 112 + (index - 1) * Flappy.TUBE_SPACING,
      gapY = nextGap(random),
      passed = false,
    }
  end
  return state
end

function Flappy.flap(state)
  if state and state.alive then state.velocity = Flappy.FLAP_VELOCITY end
end

local function overlapsTube(state, tube)
  local left = Flappy.BIRD_X
  local right = left + Flappy.BIRD_SIZE
  if right <= tube.x or left >= tube.x + Flappy.TUBE_WIDTH then return false end
  local top = state.y
  local bottom = top + Flappy.BIRD_SIZE
  local gapTop = tube.gapY - Flappy.TUBE_GAP / 2
  local gapBottom = tube.gapY + Flappy.TUBE_GAP / 2
  return top < gapTop or bottom > gapBottom
end

function Flappy.update(state, dt, random)
  if not (state and state.alive) then return 0 end
  dt = math.max(0, math.min(0.05, tonumber(dt) or 0))
  state.velocity = state.velocity + Flappy.GRAVITY * dt
  state.y = state.y + state.velocity * dt
  local passed = 0
  local farthest = 0
  for _, tube in ipairs(state.tubes) do
    tube.x = tube.x - Flappy.TUBE_SPEED * dt
    farthest = math.max(farthest, tube.x)
    if not tube.passed and tube.x + Flappy.TUBE_WIDTH < Flappy.BIRD_X then
      tube.passed = true
      state.score = state.score + 1
      passed = passed + 1
    end
    if overlapsTube(state, tube) then state.alive = false end
  end
  for _, tube in ipairs(state.tubes) do
    if tube.x + Flappy.TUBE_WIDTH < 0 then
      tube.x = farthest + Flappy.TUBE_SPACING
      tube.gapY = nextGap(random)
      tube.passed = false
      farthest = tube.x
    end
  end
  if state.y < Flappy.TOP or state.y + Flappy.BIRD_SIZE > Flappy.BOTTOM then
    state.alive = false
  end
  return passed
end

return Flappy
