-- Weighted rewards and reel construction for the Game Corner prize case.
local Cases = {}

Cases.COST = 500
Cases.WINNER_INDEX = 20
Cases.STRIP_LENGTH = 25
Cases.SPIN_DURATION = 3.75
Cases.CARD_STEP = 44
Cases.REEL_STOP_OFFSET = (Cases.WINNER_INDEX - 1) * Cases.CARD_STEP - 2

-- The case has its own premium roster; it deliberately does not inherit the
-- lower-cost Prize Corner shop catalogue.
Cases.POKEMON = {
  { species = "BULBASAUR", level = 20, label = "BULBASAUR", tier = "pokemon",
    weight = 180 },
  { species = "CHARMANDER", level = 20, label = "CHARMANDER", tier = "pokemon",
    weight = 180 },
  { species = "SQUIRTLE", level = 20, label = "SQUIRTLE", tier = "pokemon",
    weight = 180 },
  { species = "OMANYTE", level = 30, label = "OMANYTE", tier = "rare",
    weight = 150 },
  { species = "KABUTO", level = 30, label = "KABUTO", tier = "rare",
    weight = 150 },
  { species = "AERODACTYL", level = 35, label = "AERODACTYL", tier = "epic",
    weight = 150 },
  { species = "PIKACHU", level = 25, label = "SURF PIKACHU", tier = "epic",
    moves = { "SURF" }, weight = 120 },
  { species = "DRAGONITE", level = 55, label = "DRAGONITE", tier = "epic",
    weight = 70 },
  { species = "MEW", level = 30, label = "MEW", tier = "gold",
    weight = 25 },
}

local FIXED = {
  { kind = "item", id = "RARE_CANDY", quantity = 1, label = "RARE CANDY",
    tier = "common", weight = 2600 },
  { kind = "item", id = "PP_UP", quantity = 1, label = "PP UP",
    tier = "common", weight = 2000 },
  { kind = "item", id = "MAX_REVIVE", quantity = 2, label = "2 MAX REVIVE",
    tier = "common", weight = 1800 },
  { kind = "item", id = "TM_DRAGON_RAGE", quantity = 1, label = "TM DRAGON",
    tier = "rare", weight = 900 },
  { kind = "item", id = "TM_SUBSTITUTE", quantity = 1, label = "TM SUBSTITUTE",
    tier = "rare", weight = 700 },
  { kind = "item", id = "TM_HYPER_BEAM", quantity = 1, label = "TM HYPER BEAM",
    tier = "epic", weight = 400 },
  { kind = "item", id = "MASTER_BALL", quantity = 1, label = "MASTER BALL",
    tier = "gold", weight = 10 },
}

function Cases.pool(_, pokemonData)
  local pool = {}
  for _, reward in ipairs(FIXED) do
    local copy = {}
    for key, value in pairs(reward) do copy[key] = value end
    pool[#pool + 1] = copy
  end
  for _, prize in ipairs(Cases.POKEMON) do
    local def = pokemonData and pokemonData[prize.species]
    if def then
      local reward = { kind = "pokemon" }
      for key, value in pairs(prize) do reward[key] = value end
      reward.label = prize.label or def.name or prize.species
      pool[#pool + 1] = reward
    end
  end
  return pool
end

function Cases.choose(pool, random)
  local total = 0
  for _, reward in ipairs(pool) do total = total + reward.weight end
  assert(total > 0, "case reward pool cannot be empty")
  local roll = random and random(total) or math.random(total)
  roll = math.max(1, math.min(total, math.floor(roll)))
  for _, reward in ipairs(pool) do
    roll = roll - reward.weight
    if roll <= 0 then return reward end
  end
  return pool[#pool]
end

function Cases.strip(pool, winner, random)
  local strip = {}
  for index = 1, Cases.STRIP_LENGTH do
    strip[index] = Cases.choose(pool, random)
  end
  strip[Cases.WINNER_INDEX] = winner
  return strip
end

return Cases
