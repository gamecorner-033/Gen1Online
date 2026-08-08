local Catalog = {}

Catalog.SHINY_SURCHARGE = 2500
Catalog.MASTER_BALL_COST = 9999

local CORE = {
  { species = "ABRA", level = 10, cost = 250 },
  { species = "CLEFAIRY", level = 12, cost = 750 },
  { species = "DRATINI", level = 20, cost = 3500 },
  { species = "PORYGON", level = 25, cost = 7000 },
  { species = "BULBASAUR", level = 15, cost = 4000 },
  { species = "CHARMANDER", level = 15, cost = 4000 },
  { species = "SQUIRTLE", level = 15, cost = 4000 },
  { species = "OMANYTE", level = 20, cost = 5000 },
  { species = "KABUTO", level = 20, cost = 5000 },
  { species = "AERODACTYL", level = 25, cost = 6500 },
}

local RED = {
  { species = "NIDORINA", level = 17, cost = 1200 },
  { species = "SCYTHER", level = 25, cost = 4500 },
  { species = "SANDSHREW", level = 15, cost = 800 },
  { species = "VULPIX", level = 18, cost = 1200 },
  { species = "MEOWTH", level = 18, cost = 1200 },
  { species = "BELLSPROUT", level = 15, cost = 800 },
  { species = "PINSIR", level = 25, cost = 4000 },
  { species = "MAGMAR", level = 25, cost = 4500 },
}

local BLUE = {
  { species = "NIDORINO", level = 17, cost = 1200 },
  { species = "PINSIR", level = 25, cost = 4000 },
  { species = "EKANS", level = 15, cost = 800 },
  { species = "ODDISH", level = 15, cost = 800 },
  { species = "MANKEY", level = 18, cost = 1200 },
  { species = "GROWLITHE", level = 18, cost = 1200 },
  { species = "SCYTHER", level = 25, cost = 4500 },
  { species = "ELECTABUZZ", level = 25, cost = 4500 },
}

local YELLOW = {
  { species = "VULPIX", level = 18, cost = 1000 },
  { species = "WIGGLYTUFF", level = 22, cost = 2680 },
  { species = "SCYTHER", level = 30, cost = 4500 },
  { species = "PINSIR", level = 30, cost = 4000 },
}

Catalog.ITEMS = {
  { item = "TM_DRAGON_RAGE", cost = 3300 },
  { item = "TM_HYPER_BEAM", cost = 5500 },
  { item = "TM_SUBSTITUTE", cost = 7700 },
  { item = "RARE_CANDY", cost = 1500 },
  { item = "PP_UP", cost = 2500 },
  { item = "MAX_REVIVE", cost = 2000 },
  { item = "MASTER_BALL", cost = Catalog.MASTER_BALL_COST, once = true },
}

local function copyInto(out, rows)
  for _, row in ipairs(rows) do
    local entry = {}
    for key, value in pairs(row) do entry[key] = value end
    out[#out + 1] = entry
  end
end

function Catalog.pokemon(version)
  local out = {}
  copyInto(out, CORE)
  if version == "blue" then
    copyInto(out, BLUE)
  elseif version == "yellow" then
    copyInto(out, YELLOW)
  else
    copyInto(out, RED)
  end
  return out
end

return Catalog
