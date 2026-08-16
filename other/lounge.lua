local Lounge = {}

function Lounge.register(mod, mapId)
  local gameCorner = mod.content.maps:get("GAME_CORNER")
  if not (gameCorner and type(gameCorner.blocks) == "table"
      and gameCorner.tileset == "LOBBY"
      and gameCorner.width == 10 and gameCorner.height == 9) then return end

  local blocks = {}
  for index, block in ipairs(gameCorner.blocks) do blocks[index] = block end
  blocks[82] = 61

  local warps = {}
  for _, original in ipairs(gameCorner.warps or {}) do
    local warp = {}
    for key, value in pairs(original) do warp[key] = value end
    warps[#warps + 1] = warp
  end
  local entryWarp = #warps + 1
  warps[#warps + 1] = { x = 2, y = 17, destMap = mapId, destWarp = 1 }
  warps[#warps + 1] = { x = 3, y = 17, destMap = mapId, destWarp = 2 }

  local signs = {}
  for _, sign in ipairs(gameCorner.signs or {}) do signs[#signs + 1] = sign end
  signs[#signs + 1] = { x = 2, y = 16, text = "TEXT_BLACKJACK_LOUNGE_SIGN" }

  local objects, nextIndex = {}, 1
  for _, original in ipairs(gameCorner.objects or {}) do
    local object = {}
    for key, value in pairs(original) do object[key] = value end
    objects[#objects + 1] = object
    nextIndex = math.max(nextIndex, (tonumber(object.index) or 0) + 1)
  end
  objects[#objects + 1] = { index = nextIndex, name = "GAMECORNER_PAWN_BROKER",
    movement = "STAY", range = "DOWN", sprite = "SPRITE_ROCKET",
    text = "TEXT_PAWN_BROKER", x = 8, y = 6 }
  mod.content.maps:patch("GAME_CORNER", {
    blocks = blocks, warps = warps, signs = signs, objects = objects,
  })

  local loungeObjects = {
    { index = 1, name = "BLACKJACK_DEALER", movement = "STAY", range = "DOWN",
      sprite = "SPRITE_GAMBLER", text = "TEXT_BLACKJACK_DEALER", x = 4, y = 3 },
    { index = 2, name = "HOLDEM_DEALER", movement = "STAY", range = "DOWN",
      sprite = "SPRITE_GAMBLER", text = "TEXT_HOLDEM_DEALER", x = 15, y = 3 },
    { index = 3, name = "CASINO_HOSTESS", movement = "STAY", range = "RIGHT",
      sprite = "SPRITE_BEAUTY", text = "TEXT_CASINO_HOSTESS", x = 1, y = 8 },
    { index = 4, name = "BLACKJACK_PATRON", movement = "STAY", range = "LEFT",
      sprite = "SPRITE_GENTLEMAN", text = "TEXT_BLACKJACK_PATRON", x = 8, y = 8 },
    { index = 5, name = "HOLDEM_PATRON", movement = "STAY", range = "RIGHT",
      sprite = "SPRITE_GENTLEMAN", text = "TEXT_HOLDEM_PATRON", x = 18, y = 8 },
  }
  for _, machine in ipairs({
    { id = "CRASH", x = 8, text = "TEXT_CRASH_MACHINE" },
    { id = "FLAPPY", x = 10, text = "TEXT_FLAPPY_MACHINE" },
    { id = "CASE", x = 12, text = "TEXT_CASE_MACHINE" },
  }) do
    for piece = 1, 2 do loungeObjects[#loungeObjects + 1] = {
      index = #loungeObjects + 1,
      name = ("%s_MACHINE_%02d"):format(machine.id, piece),
      movement = "STAY", range = "DOWN",
      sprite = ("SPRITE_ARCADE_%s_%02d"):format(machine.id, piece),
      x = machine.x, y = 2 + piece,
      text = piece == 2 and machine.text or nil,
    } end
  end
  for _, tableDef in ipairs({
    { id = "BLACKJACK", x = 2, text = "TEXT_BLACKJACK_TABLE" },
    { id = "HOLDEM", x = 14, text = "TEXT_HOLDEM_TABLE" },
  }) do
    for piece = 1, 8 do
      local column, line = (piece - 1) % 4, math.floor((piece - 1) / 4)
      loungeObjects[#loungeObjects + 1] = {
        index = #loungeObjects + 1,
        name = ("%s_TABLE_%02d"):format(tableDef.id, piece),
        movement = "STAY", range = "DOWN",
        sprite = ("SPRITE_%s_TABLE_%02d"):format(tableDef.id, piece),
        x = tableDef.x + column, y = 4 + line,
        text = line == 1 and tableDef.text or nil,
      }
    end
  end

  mod.content.maps:register(mapId, {
    id = mapId, label = "CasinoLounge", index = 1100,
    tileset = "LOBBY", width = 10, height = 6,
    blocks = {
      63, 64, 64, 64, 64, 64, 64, 64, 64, 63,
      32, 32, 32, 32, 32, 32, 32, 32, 32, 32,
      32, 32, 32, 32, 32, 32, 32, 32, 32, 32,
      32, 32, 32, 32, 32, 32, 32, 32, 32, 32,
      32, 32, 32, 32, 32, 32, 32, 32, 32, 32,
      27, 27, 27, 27, 61, 27, 27, 27, 27, 27,
    },
    borderBlock = 15, palette = "SLOTS1", connections = {}, signs = {},
    objects = loungeObjects,
    warps = {
      { x = 8, y = 11, destMap = "GAME_CORNER", destWarp = entryWarp },
      { x = 9, y = 11, destMap = "GAME_CORNER", destWarp = entryWarp + 1 },
    },
  })
end

return Lounge
