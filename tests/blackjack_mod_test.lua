package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Stats = require("src.pokemon.Stats")
local Pokemon = require("src.pokemon.Pokemon")
local SlotMachine = require("src.ui.SlotMachine")
local CoinCase = assert(loadfile("mods/blackjack_corner/other/coin_case.lua"))()

local data = T.fixtures.fresh()
local lobby = {}
for key, value in pairs(data.tilesets[T.fixtures.ids.tileset]) do lobby[key] = value end
lobby.id = "LOBBY"
data.tilesets.LOBBY = lobby
local blocks = {}
for i = 1, 90 do blocks[i] = 31 end
data.maps.GAME_CORNER = {
  id = "GAME_CORNER", label = "GameCorner", index = 135,
  tileset = "LOBBY", width = 10, height = 9,
  blocks = blocks, borderBlock = 15, connections = {}, signs = {},
  warps = {
    { x = 15, y = 17, destMap = "LAST_MAP", destWarp = 8 },
    { x = 16, y = 17, destMap = "LAST_MAP", destWarp = 8 },
    { x = 17, y = 4, destMap = "FIXTURE_MAP", destWarp = 2 },
  },
  objects = {
    { index = 7, name = "GAMECORNER_GYM_GUIDE", movement = "STAY", range = "LEFT",
      sprite = "SPRITE_FIXTURE", text = "TEXT_GAMECORNER_GYM_GUIDE", x = 8, y = 14 },
    { index = 8, name = "GAMECORNER_GAMBLER", movement = "STAY", range = "RIGHT",
      sprite = "SPRITE_FIXTURE", text = "TEXT_GAMECORNER_GAMBLER", x = 11, y = 15 },
  },
}

local run = T.sdk.loadMod("mods/blackjack_corner", { data = data, dev = true })
T.eq(#run.errors, 0, "blackjack mod loads cleanly")
T.eq(run.data.constants.coinCap, 1000000,
  "the mod expands the native Coin Case limit to one million")

local api = run.loader.exports.blackjack_corner
T.check(api and api.rules and api.holdem_rules and api.holdem_view and api.catalog and api.view
    and api.buyCoins and api.coinOffers and api.pawn and api.pawnPokemon
    and api.redeemPokemon and api.pawnLedger and api.crash_rules
    and api.flappy_rules and api.case_rules and api.giveCaseReward,
  "games, prizes, coin exchange, pawning, and arcade rules are exported")
T.check(run.data.screens.BlackjackCornerTable ~= nil, "blackjack screen is registered")
T.check(run.data.screens.BlackjackCornerHoldemTable ~= nil, "holdem screen is registered")
T.check(run.data.screens.BlackjackCornerPokemonPrizes ~= nil,
  "Pokemon prize screen is registered")
T.check(run.data.screens.BlackjackCornerItemPrizes ~= nil,
  "item prize screen is registered")
T.check(run.data.screens.BlackjackCornerCrash ~= nil, "crash screen is registered")
T.check(run.data.screens.BlackjackCornerTubeFlyer ~= nil,
  "tube flyer screen is registered")
T.check(run.data.screens.BlackjackCornerPrizeCase ~= nil,
  "prize case screen is registered")
T.check(run.data.maps.BLACKJACK_LOUNGE ~= nil,
  "blackjack has a dedicated lounge map")
T.eq(run.data.maps.GAME_CORNER.blocks[82], 61,
  "a double-door replaces one lower Game Corner floor block")
T.eq(run.data.maps.GAME_CORNER.blocks[75], 31,
  "the original slot-machine bank remains intact")
T.eq(#run.data.maps.GAME_CORNER.warps, 5,
  "the lounge entrance adds two reciprocal Game Corner warps")
T.eq(run.data.maps.GAME_CORNER.warps[4].destMap, "BLACKJACK_LOUNGE",
  "the first new door tile enters the lounge")
T.eq(run.data.maps.GAME_CORNER.warps[5].destWarp, 2,
  "the second new door tile preserves its side of the doorway")

local function objectNamed(mapId, name)
  for _, object in ipairs(run.data.maps[mapId].objects) do
    if object.name == name then return object end
  end
end

do
  local lounge = run.data.maps.BLACKJACK_LOUNGE
  T.eq(lounge.width, 10, "the casino lounge is twenty walk cells wide")
  T.eq(lounge.height, 6, "the casino lounge is twelve walk cells tall")
  T.eq(lounge.palette, "SLOTS1", "the lounge inherits the Game Corner palette")
  T.eq(lounge.warps[1].destWarp, 4, "the left exit returns to the left entrance tile")
  T.eq(lounge.warps[2].destWarp, 5, "the right exit returns to the right entrance tile")
  local dealer = objectNamed("BLACKJACK_LOUNGE", "BLACKJACK_DEALER")
  T.eq(dealer.x, 4, "the blackjack dealer is centered behind the left table")
  T.eq(dealer.y, 3, "the dealer stands one row behind the lounge table")
  local holdemDealer = objectNamed("BLACKJACK_LOUNGE", "HOLDEM_DEALER")
  T.eq(holdemDealer.x, 15, "the holdem dealer is centered behind the right table")
  T.eq(holdemDealer.y, 3, "the holdem dealer stands behind its table")
  local guide = objectNamed("GAME_CORNER", "GAMECORNER_GYM_GUIDE")
  T.eq(guide.x, 8, "the original Game Corner NPC layout is preserved")
  T.eq(guide.y, 14, "the Gym Guide remains in his canonical position")
  local broker = objectNamed("GAME_CORNER", "GAMECORNER_PAWN_BROKER")
  T.check(broker ~= nil, "the shady pawn broker appears at the original counter")
  T.eq(broker.sprite, "SPRITE_ROCKET", "the broker uses a shady Rocket sprite")
  T.eq(broker.text, "TEXT_PAWN_BROKER", "the broker opens the pawn service")
  T.eq(broker.x, 8, "the broker stands behind the original counter")
  T.eq(broker.y, 6, "the broker stays in the counter row")
  for index, machine in ipairs({
    { id = "CRASH", x = 8, text = "TEXT_CRASH_MACHINE" },
    { id = "FLAPPY", x = 10, text = "TEXT_FLAPPY_MACHINE" },
    { id = "CASE", x = 12, text = "TEXT_CASE_MACHINE" },
  }) do
    local top = objectNamed("BLACKJACK_LOUNGE", machine.id .. "_MACHINE_01")
    local controls = objectNamed("BLACKJACK_LOUNGE", machine.id .. "_MACHINE_02")
    T.check(top and controls, machine.id .. " has a two-tile arcade cabinet")
    T.eq(top.x, machine.x, machine.id .. " occupies its center-lounge column")
    T.eq(top.y, 3, machine.id .. " cabinet starts on the dealer row")
    T.eq(controls.y, 4, machine.id .. " controls face the player")
    T.eq(controls.text, machine.text, machine.id .. " opens its own minigame")
    T.check(run.data.sprites[("SPRITE_ARCADE_%s_01"):format(machine.id)] ~= nil,
      machine.id .. " has generated cabinet art")
    T.eq(index * 2 + 6, machine.x, machine.id .. " machines are evenly spaced")
  end
  for _, tableId in ipairs({ "BLACKJACK", "HOLDEM" }) do
    for piece = 1, 8 do
      local name = ("%s_TABLE_%02d"):format(tableId, piece)
      local object = objectNamed("BLACKJACK_LOUNGE", name)
      T.check(object ~= nil, name .. " is present in the casino lounge")
      T.check(run.data.sprites[("SPRITE_%s_TABLE_%02d"):format(tableId, piece)] ~= nil,
        name .. " has a registered true-color sprite")
      if piece > 4 then
        T.eq(object.text, "TEXT_" .. tableId .. "_TABLE",
          name .. " opens its game across the front edge")
      end
    end
  end
end

do
  local fakeGame = {
    data = { constants = { coinCap = 1000000 }, field = { hiddenCoins = { TEST_MAP = {
      { x = 4, y = 5, coins = 20 },
    } } } },
    save = { coins = 9990, inventory = { COIN_CASE = 1 }, hiddenTaken = {} },
  }
  local FakeOverworld = {}
  function FakeOverworld:tryHiddenObject(fx, fy)
    fakeGame.save.hiddenTaken["TEST_MAP_" .. fx .. "_" .. fy] = true
    fakeGame.save.coins = math.min(9999, fakeGame.save.coins + 20)
    return true
  end
  CoinCase.installHiddenCoinCompatibility(1000000, FakeOverworld, fakeGame)
  FakeOverworld.tryHiddenObject({ map = { id = "TEST_MAP" } }, 4, 5)
  T.eq(fakeGame.save.coins, 10010,
    "hidden coin pickups cross the original 9999-coin boundary")

  fakeGame.save.coins, fakeGame.save.hiddenTaken = 20000, {}
  FakeOverworld.tryHiddenObject({ map = { id = "TEST_MAP" } }, 4, 5)
  T.eq(fakeGame.save.coins, 20020,
    "hidden coin pickups preserve an existing five-digit balance")

  fakeGame.data.constants.coinCap = 9999
  fakeGame.save.coins, fakeGame.save.hiddenTaken = 20000, {}
  FakeOverworld.tryHiddenObject({ map = { id = "TEST_MAP" } }, 4, 5)
  T.eq(fakeGame.save.coins, 9999,
    "the hidden-coin wrapper becomes vanilla-equivalent when the cap is restored")
end

do
  local one = api.view.cardLayout(1)
  T.eq(one[1], 70, "a single pixel card is centered")
  local crowded = api.view.cardLayout(10)
  T.check(crowded[1] >= 0 and crowded[#crowded] + 20 <= 160,
    "a crowded hand remains inside the 160-pixel canvas")
  for i = 2, #crowded do
    T.check(crowded[i] > crowded[i - 1], "overlapped cards keep a readable order")
  end
end

local function contains(rows, species)
  for _, row in ipairs(rows) do if row.species == species then return true end end
  return false
end

local red = api.catalog.pokemon("red")
local blue = api.catalog.pokemon("blue")
for _, species in ipairs({ "SANDSHREW", "VULPIX", "MEOWTH", "BELLSPROUT", "PINSIR", "MAGMAR" }) do
  T.check(contains(red, species), "Red catalogue supplies Blue-exclusive " .. species)
end
for _, species in ipairs({ "EKANS", "ODDISH", "MANKEY", "GROWLITHE", "SCYTHER", "ELECTABUZZ" }) do
  T.check(contains(blue, species), "Blue catalogue supplies Red-exclusive " .. species)
end
for _, species in ipairs({ "BULBASAUR", "CHARMANDER", "SQUIRTLE", "OMANYTE", "KABUTO", "AERODACTYL", "DRATINI" }) do
  T.check(contains(red, species) and contains(blue, species), species .. " is sold in both versions")
end

local function gameWith(coins, money)
  return {
    data = run.data,
    save = {
      coins = coins,
      money = money or 0,
      inventory = {},
      party = {},
      flags = {},
      pokedex = { seen = {}, owned = {} },
      player = { name = "RED", id = 12345 },
    },
  }
end

local function clearPawnLedger()
  local ledger = api.pawnLedger()
  for index = #ledger, 1, -1 do table.remove(ledger, index) end
end

local function fixtureMon(species, level)
  return Pokemon.new(run.data, species or "FIXMON_A", level or 20,
    function() return 8 end)
end

local noInput = { wasPressed = function() return false end }

do
  local slot = setmetatable({
    game = { data = run.data, save = { coins = 10000 }, input = noInput },
    stage = "payout", payoutRemaining = 2, payoutDisplay = 2,
    dripTimer = 7, dripFrames = 8, dripFlash = 5, flash = false,
  }, SlotMachine)
  slot:update(0)
  T.eq(slot.game.save.coins, 10001,
    "a vanilla slot payout preserves and increments a five-digit balance")
  slot.game.save.coins = 9999
  slot.dripTimer, slot.payoutRemaining = 7, 1
  slot:update(0)
  T.eq(slot.game.save.coins, 10000,
    "a vanilla slot payout crosses the original 9999-coin boundary")
  slot.game.save.coins = 1000000
  slot.dripTimer, slot.payoutRemaining = 7, 1
  slot:update(0)
  T.eq(slot.game.save.coins, 1000000,
    "the original slots respect the expanded one-million-coin ceiling")
end

do
  local game = gameWith(0, 20000)
  game.save.inventory.COIN_CASE = 1
  local offers = api.coinOffers(game)
  T.eq(#offers, 4, "the clerk offers four useful denominations at ¥20000")
  T.eq(offers[1].amount, 50, "the original 50-coin purchase remains available")
  T.eq(offers[2].amount, 250, "the clerk offers a five-pack shortcut")
  T.eq(offers[3].amount, 500, "the clerk offers a ten-pack shortcut")
  T.eq(offers[4].amount, 1000, "the clerk offers a thousand coins at once")
  local ok, _, cost = api.buyCoins(game, 500)
  T.check(ok, "a larger coin purchase succeeds")
  T.eq(cost, 10000, "larger purchases preserve the ¥1000-per-50 exchange rate")
  T.eq(game.save.money, 10000, "the larger exchange deducts its full price")
  T.eq(game.save.coins, 500, "the larger exchange adds all selected coins")
end

do
  local game = gameWith(999001, 100000)
  game.save.inventory.COIN_CASE = 1
  local offers = api.coinOffers(game)
  local maximum = offers[#offers]
  T.eq(maximum.label, "MAX 999", "MAX fills the exact remaining Coin Case space")
  T.eq(maximum.cost, 20000, "a partial final bundle keeps the standard pack price")
  local ok = api.buyCoins(game, maximum.amount)
  T.check(ok, "the calculated maximum can be purchased")
  T.eq(game.save.coins, 1000000, "MAX reaches the expanded Coin Case cap exactly")
end

do
  local game = gameWith(0, 10000)
  local ok = api.buyCoins(game, 250)
  T.check(not ok, "the larger exchange still requires a Coin Case")
  T.eq(game.save.money, 10000, "a rejected exchange takes no money")
  T.eq(game.save.coins, 0, "a rejected exchange gives no coins")
end

do
  clearPawnLedger()
  local game = gameWith(100)
  game.save.inventory.COIN_CASE = 1
  local lead = fixtureMon("FIXMON_A", 10)
  local collateral = fixtureMon("FIXMON_C", 30)
  collateral.nickname = "SHELLY"
  collateral.moves[1].pp = 1
  game.save.party = { lead, collateral }
  local ok, entry = api.pawnPokemon(game, 2)
  T.check(ok, "a non-final party Pokemon can be pawned")
  T.eq(#game.save.party, 1, "pawning removes the selected party member")
  T.eq(game.save.party[1], lead, "pawning preserves the remaining party order")
  T.eq(game.save.coins, 100 + entry.value, "the full appraised value is paid in coins")
  T.eq(entry.mon, collateral, "the exact Pokemon record is held in pawn")
  T.eq(entry.mon.moves[1].pp, 1, "moves and PP survive pawn storage")
  T.eq(entry.name, "SHELLY", "the pawn ticket preserves the nickname")
  T.eq(entry.redeem, math.ceil(entry.value * 1.3),
    "the ticket locks in a thirty-percent redemption premium")

  game.save.coins = entry.redeem + 25
  ok, entry, _, destination = api.redeemPokemon(game, 1)
  T.check(ok, "a pawned Pokemon can be redeemed")
  T.eq(destination, "party", "redemption uses an open party slot first")
  T.eq(game.save.party[2], collateral, "redemption restores the exact Pokemon")
  T.eq(game.save.coins, 25, "redemption deducts only the ticket price")
  T.eq(#api.pawnLedger(), 0, "a redeemed ticket leaves the ledger")
end

do
  clearPawnLedger()
  local game = gameWith(0)
  game.save.inventory.COIN_CASE = 1
  game.save.party = { fixtureMon() }
  local ok = api.pawnPokemon(game, 1)
  T.check(not ok, "the broker refuses the player's final Pokemon")
  T.eq(#game.save.party, 1, "the refused final Pokemon remains in the party")
  T.eq(game.save.coins, 0, "a refused pawn pays no coins")
end

do
  clearPawnLedger()
  local game = gameWith(1000000)
  game.save.inventory.COIN_CASE = 1
  game.save.party = { fixtureMon(), fixtureMon("FIXMON_B", 30) }
  local ok = api.pawnPokemon(game, 2)
  T.check(not ok, "a full Coin Case refuses a pawn instead of underpaying")
  T.eq(#game.save.party, 2, "a capacity failure leaves the party untouched")
  T.eq(#api.pawnLedger(), 0, "a capacity failure creates no pawn ticket")
end

do
  clearPawnLedger()
  local game = gameWith(0)
  game.save.inventory.COIN_CASE = 1
  local lead = fixtureMon("FIXMON_A", 5)
  game.save.party = { lead }
  local oldest
  for index = 1, 6 do
    local collateral = fixtureMon(index % 2 == 0 and "FIXMON_B" or "FIXMON_C", 5 + index)
    collateral.nickname = "PAWN " .. index
    game.save.party[2] = collateral
    local ok, entry, sold = api.pawnPokemon(game, 2)
    T.check(ok, "FIFO pawn " .. index .. " succeeds")
    if index == 1 then oldest = entry end
    if index < 6 then
      T.eq(sold, nil, "the first five tickets remain recoverable")
    else
      T.eq(sold, oldest, "the sixth pawn permanently sells the oldest ticket")
    end
  end
  local ledger = api.pawnLedger()
  T.eq(#ledger, 5, "the recoverable pawn ledger never exceeds five")
  T.eq(ledger[1].name, "PAWN 2", "FIFO eviction advances the oldest ticket")
  T.eq(ledger[5].name, "PAWN 6", "the newest pawn is stored last")
end

do
  clearPawnLedger()
  local game = gameWith(0)
  game.save.inventory.COIN_CASE = 1
  game.save.party = { fixtureMon(), fixtureMon("FIXMON_C", 25) }
  local ok, entry = api.pawnPokemon(game, 2)
  T.check(ok, "a Pokemon can be pawned before a PC redemption")
  while #game.save.party < 6 do game.save.party[#game.save.party + 1] = fixtureMon() end
  game.save.coins = entry.redeem
  ok, _, _, destination = api.redeemPokemon(game, 1)
  T.check(ok, "redemption succeeds when only PC storage has room")
  T.eq(destination, "BOX 1", "a full party sends the exact Pokemon to the PC")
  T.eq(game.save.boxes[1][1], entry.mon, "the PC receives the pawned record unchanged")
end

do
  clearPawnLedger()
  local game = gameWith(0)
  game.save.inventory.COIN_CASE = 1
  game.save.party = { fixtureMon(), fixtureMon("FIXMON_C", 25) }
  local ok, entry = api.pawnPokemon(game, 2)
  while #game.save.party < 6 do game.save.party[#game.save.party + 1] = fixtureMon() end
  game.save.boxes = {}
  game.save.currentBox = 1
  for box = 1, 12 do
    game.save.boxes[box] = {}
    for slot = 1, 20 do game.save.boxes[box][slot] = fixtureMon() end
  end
  game.save.coins = entry.redeem
  ok = api.redeemPokemon(game, 1)
  T.check(not ok, "redemption is refused when party and PC are both full")
  T.eq(game.save.coins, entry.redeem, "failed redemption charges no coins")
  T.eq(api.pawnLedger()[1], entry, "failed redemption keeps the pawn recoverable")
end

do
  local game = gameWith(100)
  game.input = noInput
  local screen = run.data.screens.BlackjackCornerCrash.new(game, {})
  screen:launch()
  T.eq(screen.phase, "running", "crash launches when the wager is affordable")
  T.eq(game.save.coins, 90, "crash deducts the selected ten-coin wager once")
  screen.multiplier = 2.37
  screen:cashOut()
  T.eq(screen.phase, "cashed", "crash cash-out settles before the hidden crash point")
  T.eq(screen.payout, 23, "crash credits the floored live multiplier payout")
  T.eq(game.save.coins, 113, "crash returns the payout to the Coin Case")
  screen:draw()
  T.check(true, "the crash result renders without an engine error")

  local poor = gameWith(9)
  poor.input = noInput
  local refused = run.data.screens.BlackjackCornerCrash.new(poor, {})
  refused:launch()
  T.eq(refused.phase, "bet", "an unaffordable crash wager does not launch")
  T.eq(poor.save.coins, 9, "an unaffordable crash wager takes no coins")
end

do
  local game = gameWith(20)
  game.input = noInput
  local screen = run.data.screens.BlackjackCornerTubeFlyer.new(game, {})
  screen:start()
  T.eq(screen.phase, "playing", "tube flyer starts with ten available coins")
  T.eq(game.save.coins, 10, "tube flyer charges exactly ten coins")
  screen.run.y, screen.run.velocity = 65, 0
  screen.run.tubes[1].x = api.flappy_rules.BIRD_X - api.flappy_rules.TUBE_WIDTH - 1
  screen.run.tubes[1].gapY = 68
  screen:update(0)
  T.eq(screen.run.score, 1, "the screen records a passed tube")
  T.eq(game.save.coins, 11, "each passed tube immediately pays one coin")
  screen.run.y = api.flappy_rules.TOP - 1
  screen:update(0)
  T.eq(screen.phase, "result", "a collision ends the tube flyer round")
  screen:draw()
  T.check(true, "the tube flyer result renders without an engine error")
end

do
  local game = gameWith(1000)
  game.input = noInput
  game.save.inventory.COIN_CASE = 1
  local screen = run.data.screens.BlackjackCornerPrizeCase.new(game, {})
  T.eq(screen.duration, 3.75, "the prize reel uses the slower spin duration")
  screen:open()
  T.eq(screen.phase, "spinning", "a funded prize case starts its reel")
  T.eq(game.save.coins, 500, "opening a case charges exactly 500 coins")
  T.eq(screen.strip[api.case_rules.WINNER_INDEX], screen.winner,
    "the visible reel is locked to the selected reward")
  screen:settle()
  T.eq(screen.phase, "result", "the case settles after its reel")
  T.check(not screen.refunded, "a deliverable case prize is awarded")
  screen:draw()
  T.check(true, "the case-opening result renders without an engine error")

  local pokemonGame = gameWith(0)
  pokemonGame.save.inventory.COIN_CASE = 1
  local ok, message, destination = api.giveCaseReward(pokemonGame, {
    kind = "pokemon", species = "FIXMON_A", level = 20, label = "FIXMON A",
  })
  T.check(ok, "case Pokemon rewards use safe party and PC delivery")
  T.eq(#pokemonGame.save.party, 1, "a case Pokemon reaches an open party slot")
  T.eq(message, "FIXMON A", "the case result names the Pokemon reward")
  T.eq(destination, "party", "the delivery result identifies the party destination")

  local surfGame = gameWith(0)
  surfGame.save.inventory.COIN_CASE = 1
  ok = api.giveCaseReward(surfGame, {
    kind = "pokemon", species = "FIXMON_A", level = 20, label = "SURF TEST",
    moves = { "FIX_CUT" },
  })
  T.check(ok, "case Pokemon can carry a special prize move")
  local surfMove = surfGame.save.party[1].moves[#surfGame.save.party[1].moves]
  T.eq(surfMove.id, "FIX_CUT", "the special case move is installed on delivery")
  T.eq(surfMove.pp, run.data.moves.FIX_CUT.pp,
    "the special case move starts with full PP")

  local refundGame = gameWith(1000)
  refundGame.input = noInput
  refundGame.save.inventory.COIN_CASE = 1
  local refund = run.data.screens.BlackjackCornerPrizeCase.new(refundGame, {})
  refund:open()
  for index = 1, 19 do refundGame.save.inventory["FILLER_" .. index] = 1 end
  refund.winner = {
    kind = "item", id = "NEW_CASE_ITEM", quantity = 1,
    label = "NEW ITEM", tier = "rare",
  }
  refund:settle()
  T.check(refund.refunded, "an undeliverable case prize triggers a refund")
  T.eq(refundGame.save.coins, 1000, "failed case delivery refunds all 500 coins")
  T.eq(refundGame.save.inventory.NEW_CASE_ITEM, nil,
    "failed case delivery does not partially add the reward")
end

do
  local screen = run.data.screens.BlackjackCornerTable.new(gameWith(500), {})
  local zones = screen:sgbPalettes()
  T.eq(#zones, 1, "the blackjack screen owns one palette zone")
  T.eq(zones[1].colors, false,
    "the casino primitives bypass Game Boy shade remapping")
  T.eq(zones[1].w, 160, "the true-color zone covers the full native canvas")
  T.eq(zones[1].h, 144, "the true-color zone covers the full native height")
end

do
  local poorGame = gameWith(0)
  local poorScreen = run.data.screens.BlackjackCornerHoldemTable.new(poorGame, {})
  poorScreen:deal()
  T.eq(poorScreen.notice, "NEED 10 COINS",
    "holdem requires only the selected starting bet")
  T.eq(poorGame.save.coins, 0, "a rejected holdem deal takes no coins")
  poorScreen:draw()
  T.check(true, "holdem bet screen draws its cost explanation without an error")

  local minimumGame = gameWith(10)
  local minimumScreen = run.data.screens.BlackjackCornerHoldemTable.new(minimumGame, {})
  minimumScreen:deal()
  T.eq(minimumGame.save.coins, 0, "the minimum bankroll pays only the starting bet")
  minimumScreen:chooseAction(1)
  minimumScreen:chooseAction(1)
  T.eq(minimumScreen.round.phase, "river", "two checks reach the final decision")
  T.eq(minimumScreen:actions()[1].label, "CHECK",
    "a zero-balance player can check the river")
  T.check(not minimumScreen:actions()[2].enabled,
    "the optional river bet is disabled at zero coins")
  minimumScreen:chooseAction(1)
  T.eq(minimumScreen.phase, "result",
    "a player who started with ten coins can reach showdown")

  local tightGame = gameWith(40)
  local tightScreen = run.data.screens.BlackjackCornerHoldemTable.new(tightGame, {})
  tightScreen:deal()
  T.check(tightScreen:actions()[2].enabled,
    "an affordable early 3x bet does not require a river reserve")
  T.check(not tightScreen:actions()[3].enabled,
    "an unaffordable early 4x bet remains disabled")

  local stagedGame = gameWith(60)
  local stagedScreen = run.data.screens.BlackjackCornerHoldemTable.new(stagedGame, {})
  stagedScreen:deal()
  T.check(stagedScreen:actions()[2].enabled,
    "an affordable early 3x bet is enabled")
  stagedScreen:chooseAction(2)
  T.eq(stagedScreen.round.phase, "flop", "an affordable 3x bet reveals only the flop")
  T.check(stagedScreen:actions()[2].enabled,
    "an affordable flop 2x bet remains available")
  stagedScreen:chooseAction(2)
  T.eq(stagedScreen:actions()[1].label, "CHECK",
    "the river offers a free showdown instead of fold")
  T.check(not stagedScreen:actions()[2].enabled,
    "the optional river bet is disabled after spending the balance")
  stagedScreen:chooseAction(1)
  T.eq(stagedScreen.phase, "result", "checking the river reaches showdown")

  local game = gameWith(1000)
  local screen = run.data.screens.BlackjackCornerHoldemTable.new(game, {})
  local zones = screen:sgbPalettes()
  T.eq(zones[1].colors, false, "holdem screen also bypasses shade remapping")
  screen:deal()
  T.eq(game.save.coins, 990, "holdem posts one ten-coin starting bet")
  T.eq(screen.round.phase, "preflop", "holdem deal begins with the progressive choice")
  local actions = screen:actions()
  T.eq(actions[1].label, "CHECK", "pre-flop can check")
  T.eq(actions[2].multiplier, 3, "pre-flop offers a three-times play bet")
  T.eq(actions[3].multiplier, 4, "pre-flop offers a four-times play bet")
  screen:draw()
  T.check(true, "holdem pre-flop view draws without an engine error")
  screen:chooseAction(1)
  T.eq(screen.round.phase, "flop", "checking reveals three community cards")
  T.eq(#screen.round.board, 3, "holdem screen exposes the complete flop")
  actions = screen:actions()
  T.eq(actions[2].multiplier, 2, "flop offers the progressive two-times bet")
  screen:draw()
  screen:chooseAction(2)
  T.eq(screen.round.phase, "river", "a flop bet advances to the final betting round")
  T.eq(screen.phase, "play", "a flop bet keeps the hand open")
  screen:chooseAction(2)
  T.eq(screen.phase, "result", "the river bet advances to showdown")
  screen:draw()
  T.check(true, "holdem showdown view draws without an engine error")
end

do
  local game = gameWith(9999)
  local prize = { species = "FIXMON_A", level = 20, cost = 3500 }
  local ok = api.buyPokemon(game, prize, true)
  T.check(ok, "a shiny prize can be purchased")
  T.eq(game.save.coins, 3999, "base price and shiny surcharge are deducted")
  T.eq(#game.save.party, 1, "the prize enters an available party slot")
  T.check(Stats.isShiny(game.save.party[1].dvs), "the purchased Pokemon has canonical shiny DVs")
  T.check(game.save.pokedex.owned.FIXMON_A, "the prize updates owned dex state")
end

do
  local game = gameWith(100)
  local ok = api.buyPokemon(game, { species = "FIXMON_A", level = 20, cost = 3500 }, false)
  T.check(not ok, "an unaffordable Pokemon is refused")
  T.eq(game.save.coins, 100, "a refused Pokemon does not consume coins")
  T.eq(#game.save.party, 0, "a refused Pokemon is not created")
end

do
  local game = gameWith(9999)
  local filler = { species = "FIXMON_A" }
  for _ = 1, 6 do game.save.party[#game.save.party + 1] = filler end
  game.save.boxes = {}
  game.save.currentBox = 1
  for box = 1, 12 do
    game.save.boxes[box] = {}
    for slot = 1, 20 do game.save.boxes[box][slot] = filler end
  end
  local ok = api.buyPokemon(game,
    { species = "FIXMON_A", level = 20, cost = 3500 }, true)
  T.check(not ok, "a Pokemon is refused when the party and every box are full")
  T.eq(game.save.coins, 9999, "a storage failure consumes no coins")
end

do
  local game = gameWith(9999)
  local master = { item = "MASTER_BALL", cost = 9999, once = true }
  local ok = api.buyItem(game, master)
  T.check(ok, "the Master Ball can be redeemed")
  T.eq(game.save.inventory.MASTER_BALL, 1, "the Master Ball reaches the bag")
  T.eq(game.save.coins, 0, "the ultimate prize costs 9999 coins")
  game.save.coins = 9999
  ok = api.buyItem(game, master)
  T.check(not ok, "the Master Ball cannot be redeemed twice")
  T.eq(game.save.coins, 9999, "a sold-out redemption consumes no coins")
end

run.release()
do
  run.data.constants.coinCap = 9999
  local slot = setmetatable({
    game = { data = run.data, save = { coins = 9999 }, input = noInput },
    stage = "payout", payoutRemaining = 1, payoutDisplay = 1,
    dripTimer = 7, dripFrames = 8, dripFlash = 5, flash = false,
  }, SlotMachine)
  slot:update(0)
  T.eq(slot.game.save.coins, 9999,
    "releasing the mod restores vanilla slot payout behavior")
end
T.finish("blackjack_mod")
