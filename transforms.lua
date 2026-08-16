-- Generate per-instance shiny art from the player's imported cache. The mod
-- ships this recipe, never ROM-derived pixels.
local SPECIES = {
  "abra", "kadabra", "alakazam", "clefairy", "wigglytuff", "nidorina", "nidoqueen",
  "nidorino", "nidoking", "dratini", "dragonair", "dragonite", "porygon",
  "bulbasaur", "ivysaur", "venusaur", "charmander", "charmeleon", "charizard",
  "squirtle", "wartortle", "blastoise", "omanyte", "omastar", "kabuto",
  "kabutops", "aerodactyl", "sandshrew", "sandslash", "vulpix", "ninetales",
  "meowth", "persian", "bellsprout", "weepinbell", "victreebel", "pinsir",
  "magmar", "ekans", "arbok", "oddish", "gloom", "vileplume", "mankey",
  "primeape", "growlithe", "arcanine", "scyther", "electabuzz",
}

local GOLD = {
  { 248, 248, 224 },
  { 248, 216, 88 },
  { 208, 120, 32 },
  { 64, 32, 64 },
}

-- Build two ROM-clean 64x32 overworld tables from authored pixels, then slice
-- each into eight ordinary 16x16 overworld sprites. Keeping each cell separate
-- gives the existing entity sorter and collision system exactly the shape
-- they already understand, while trueColor preserves the green felt in
-- every palette mode.
local TABLE_COLORS = {
  outline = { 0.07, 0.04, 0.06, 1 },
  woodDark = { 0.24, 0.07, 0.08, 1 },
  wood = { 0.48, 0.16, 0.16, 1 },
  woodLight = { 0.68, 0.27, 0.22, 1 },
  rail = { 0.96, 0.91, 0.70, 1 },
  feltDark = { 0.035, 0.24, 0.10, 1 },
  felt = { 0.08, 0.62, 0.17, 1 },
  feltLight = { 0.35, 0.84, 0.29, 1 },
  card = { 0.96, 0.91, 0.72, 1 },
  red = { 0.70, 0.10, 0.16, 1 },
}

local HOLDEM_COLORS = {
  outline = { 0.05, 0.04, 0.08, 1 },
  woodDark = { 0.16, 0.08, 0.18, 1 },
  wood = { 0.34, 0.16, 0.34, 1 },
  woodLight = { 0.58, 0.30, 0.46, 1 },
  rail = { 0.96, 0.82, 0.44, 1 },
  feltDark = { 0.02, 0.12, 0.20, 1 },
  felt = { 0.03, 0.34, 0.43, 1 },
  feltLight = { 0.12, 0.58, 0.62, 1 },
  card = { 0.96, 0.91, 0.72, 1 },
  red = { 0.70, 0.10, 0.16, 1 },
}

local MACHINE_COLORS = {
  outline = { 0.05, 0.04, 0.07, 1 },
  bodyDark = { 0.18, 0.11, 0.22, 1 },
  body = { 0.42, 0.23, 0.42, 1 },
  trim = { 0.94, 0.68, 0.19, 1 },
  screen = { 0.03, 0.16, 0.20, 1 },
  green = { 0.18, 0.76, 0.26, 1 },
  blue = { 0.18, 0.56, 0.76, 1 },
  red = { 0.78, 0.14, 0.20, 1 },
  paper = { 0.95, 0.91, 0.70, 1 },
}

local function pixel(image, x, y, c)
  if x >= 0 and y >= 0 and x < image:getWidth() and y < image:getHeight() then
    image:setPixel(x, y, c[1], c[2], c[3], c[4])
  end
end

local function fill(image, x, y, width, height, c)
  for py = y, y + height - 1 do
    for px = x, x + width - 1 do pixel(image, px, py, c) end
  end
end

local function row(image, y, inset, c)
  fill(image, inset, y, image:getWidth() - inset * 2, 1, c)
end

local function bodyInset(y)
  if y <= 18 then return 0 end
  return math.min(12, math.floor((y - 18) * 1.15))
end

local function surfaceInset(y)
  if y <= 14 then return 1 end
  return math.min(14, 1 + math.floor((y - 14) * 1.65))
end

local function circle(image, cx, cy, radius, c)
  for y = -radius, radius do
    for x = -radius, radius do
      if x * x + y * y <= radius * radius then pixel(image, cx + x, cy + y, c) end
    end
  end
end

local function buildTable(ctx, id, c)
  local width = 64
  local image = ctx.blank(width, 32, 0, 0, 0, 0)

  -- Deep wooden cabinet and its curved front apron.
  for y = 5, 30 do row(image, y, bodyInset(y), c.outline) end
  for y = 7, 28 do row(image, y, bodyInset(y) + 2, c.woodDark) end
  for y = 8, 25 do row(image, y, bodyInset(y) + 3, c.wood) end
  fill(image, 5, 9, width - 10, 2, c.woodLight)

  -- Cream rail wrapping a green, semicircular felt surface.
  for y = 1, 24 do row(image, y, surfaceInset(y), c.outline) end
  for y = 2, 22 do row(image, y, surfaceInset(y) + 1, c.rail) end
  for y = 4, 20 do row(image, y, surfaceInset(y) + 3, c.feltDark) end
  for y = 5, 18 do row(image, y, surfaceInset(y) + 4, c.felt) end
  fill(image, 7, 5, width - 14, 1, c.feltLight)

  if id == "blackjack" then
    for _, box in ipairs({ {20, 8}, {30, 8}, {25, 15}, {35, 15} }) do
      fill(image, box[1], box[2], 6, 5, c.rail)
      fill(image, box[1] + 1, box[2] + 1, 4, 3, c.felt)
    end
    fill(image, 51, 6, 7, 9, c.outline)
    fill(image, 50, 5, 7, 8, c.card)
    fill(image, 50, 11, 7, 2, c.red)
  else
    -- Five community-card boxes make the Hold'em table distinct at a glance.
    for x = 13, 45, 8 do
      fill(image, x, 7, 6, 8, c.outline)
      fill(image, x + 1, 8, 4, 6, c.card)
    end
    circle(image, 8, 12, 4, c.rail)
    circle(image, 8, 12, 2, c.feltDark)
  end
  for _, chip in ipairs(id == "blackjack"
      and { {10, 10}, {16, 18}, {46, 18} }
      or { {8, 19}, {53, 18}, {57, 11} }) do
    circle(image, chip[1], chip[2], 3, c.rail)
    circle(image, chip[1], chip[2], 2, c.red)
    pixel(image, chip[1], chip[2], c.card)
  end

  for piece = 0, 7 do
    local part = ctx.blank(16, 16, 0, 0, 0, 0)
    local column, line = piece % 4, math.floor(piece / 4)
    ctx.blit(part, image, 0, 0, column * 16, line * 16, 16, 16)
    ctx.writeImage(part, ("world/%s_table_%02d.png"):format(id, piece + 1))
  end
end

local function buildMachine(ctx, id, c)
  local image = ctx.blank(16, 32, 0, 0, 0, 0)
  fill(image, 1, 0, 14, 30, c.outline)
  fill(image, 2, 1, 12, 28, c.bodyDark)
  fill(image, 3, 2, 10, 26, c.body)
  fill(image, 2, 2, 12, 3, c.trim)
  fill(image, 3, 6, 10, 10, c.outline)
  fill(image, 4, 7, 8, 8, c.screen)
  if id == "crash" then
    pixel(image, 5, 13, c.green); pixel(image, 6, 12, c.green)
    pixel(image, 7, 11, c.green); pixel(image, 8, 9, c.green)
    pixel(image, 9, 8, c.green); pixel(image, 10, 8, c.red)
  elseif id == "flappy" then
    fill(image, 5, 7, 2, 3, c.green); fill(image, 5, 13, 2, 2, c.green)
    fill(image, 10, 7, 2, 5, c.green); fill(image, 10, 14, 2, 1, c.green)
    fill(image, 7, 10, 3, 2, c.trim); pixel(image, 9, 10, c.paper)
  else
    for x = 4, 11, 3 do fill(image, x, 8, 2, 5, x == 10 and c.trim or c.paper) end
    fill(image, 4, 14, 8, 1, c.red)
  end
  fill(image, 4, 18, 8, 3, c.outline)
  fill(image, 5, 18, 3, 2, c.trim)
  circle(image, 10, 19, 1, c.red)
  fill(image, 3, 23, 10, 2, c.outline)
  fill(image, 5, 24, 6, 2, c.paper)
  fill(image, 2, 28, 12, 3, c.outline)
  for piece = 0, 1 do
    local part = ctx.blank(16, 16, 0, 0, 0, 0)
    ctx.blit(part, image, 0, 0, 0, piece * 16, 16, 16)
    ctx.writeImage(part, ("world/%s_machine_%02d.png"):format(id, piece + 1))
  end
end

return function(ctx)
  for _, species in ipairs(SPECIES) do
    local paths = {
      "battle/front/" .. species .. ".png",
      "battle/back/" .. species .. "b.png",
    }
    for _, source in ipairs(paths) do
      if ctx.exists(source) then
        ctx.writeImage(ctx.recolor(ctx.readImage(source), GOLD), "shiny/" .. source)
      end
    end
  end
  buildTable(ctx, "blackjack", TABLE_COLORS)
  buildTable(ctx, "holdem", HOLDEM_COLORS)
  for _, id in ipairs({ "crash", "flappy", "case" }) do
    buildMachine(ctx, id, MACHINE_COLORS)
  end
end
