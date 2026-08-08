package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")

local function loadRule(path)
  path = "mods/blackjack_corner/" .. path
  local file = assert(io.open(path, "r"))
  local chunk = assert(load(file:read("*a"), "@" .. path))
  file:close()
  return chunk()
end

local Crash = loadRule("games/crash/rules.lua")
local Flappy = loadRule("games/tube_flyer/rules.lua")
local Cases = loadRule("games/prize_case/rules.lua")
local UI = loadRule("games/shared/ui.lua")
local CrashView = loadRule("games/crash/view.lua")(UI)
local FlappyView = loadRule("games/tube_flyer/view.lua")(UI)
local CaseView = loadRule("games/prize_case/view.lua")(UI)

T.eq(Crash.crashPoint(0), 1, "the house-edge slice can crash immediately")
T.eq(Crash.crashPoint(0.5), 1.94, "crash points follow the house-edged distribution")
T.eq(Crash.crashPoint(0.999999), 50, "crash points respect the visual maximum")
T.eq(Crash.multiplier(0), 1, "every crash round begins at one times")
T.check(Crash.multiplier(5) > Crash.multiplier(2), "the crash multiplier rises with time")
T.eq(Crash.multiplier(5), 2.71, "crash uses the slower paced growth curve")
T.eq(Crash.payout(50, 2.37), 118, "crash payouts floor fractional coins")

local flight = Flappy.new(function() return 1 end)
T.eq(#flight.tubes, 3, "tube flyer maintains three scrolling obstacles")
Flappy.flap(flight)
T.eq(flight.velocity, Flappy.FLAP_VELOCITY, "flapping applies the upward impulse")
flight.y, flight.velocity = 65, 0
flight.tubes[1].x = Flappy.BIRD_X - Flappy.TUBE_WIDTH - 1
flight.tubes[1].gapY = 68
local passed = Flappy.update(flight, 0, function() return 1 end)
T.eq(passed, 1, "crossing a complete tube reports one payable point")
T.eq(flight.score, 1, "crossing a tube increments score once")
passed = Flappy.update(flight, 0, function() return 1 end)
T.eq(passed, 0, "the same tube cannot pay twice")
local collision = Flappy.new(function() return 1 end)
collision.y = 100
collision.tubes[1].x = Flappy.BIRD_X
collision.tubes[1].gapY = 50
Flappy.update(collision, 0, function() return 1 end)
T.check(not collision.alive, "touching a tube ends the flight")
local ceiling = Flappy.new(function() return 1 end)
ceiling.y = Flappy.TOP - 1
Flappy.update(ceiling, 0, function() return 1 end)
T.check(not ceiling.alive, "leaving the playfield ends the flight")

T.eq(Cases.SPIN_DURATION, 3.75, "the case reel runs roughly ten percent longer")
T.eq(Cases.REEL_STOP_OFFSET, 834,
  "the case reel stop derives from the configured winning card")
local premium = { "BULBASAUR", "CHARMANDER", "SQUIRTLE", "OMANYTE", "KABUTO",
  "AERODACTYL", "PIKACHU", "DRAGONITE", "MEW" }
local pokemonData = {}
for _, species in ipairs(premium) do pokemonData[species] = { name = species } end
local pool = Cases.pool({}, pokemonData)
T.check(#pool > 7, "the case combines fixed loot and Pokemon")
local casePokemon = {}
for _, reward in ipairs(pool) do
  if reward.kind == "pokemon" then casePokemon[reward.species] = reward end
end
for _, species in ipairs(premium) do
  T.check(casePokemon[species] ~= nil, "the premium case roster includes " .. species)
end
for _, species in ipairs({ "VULPIX", "NIDORINA", "NIDORINO" }) do
  T.eq(casePokemon[species], nil, "the case excludes low-tier " .. species)
end
T.eq(casePokemon.PIKACHU.moves[1], "SURF", "the Pikachu jackpot knows Surf")
T.eq(casePokemon.MEW.tier, "gold", "Mew is presented as a gold-tier prize")
local total, beforeMaster, master
total, beforeMaster = 0, 0
for _, reward in ipairs(pool) do
  if reward.id == "MASTER_BALL" then beforeMaster, master = total, reward end
  total = total + reward.weight
end
T.check(master ~= nil, "the Master Ball exists in the case pool")
T.check(master.weight / total < 0.002, "the Master Ball chance stays below 0.2 percent")
T.eq(Cases.choose(pool, function() return beforeMaster + 1 end), master,
  "the weighted selector can land on the Master Ball")
local winner = pool[1]
local strip = Cases.strip(pool, winner, function() return 1 end)
T.eq(#strip, Cases.STRIP_LENGTH, "the case reel has a full run of reward cards")
T.eq(strip[Cases.WINNER_INDEX], winner, "the predetermined reward lands under the marker")

local originalRectangle = love.graphics.rectangle
local rectangles, labels = {}, {}
love.graphics.rectangle = function(mode, x, y, width, height)
  local red, green, blue = love.graphics.getColor()
  rectangles[#rectangles + 1] = {
    mode = mode, x = x, y = y, width = width, height = height,
    luminance = red + green + blue,
  }
end
local FakeFont = {
  width = function(value) return #value * 8 end,
  draw = function(value, x, y)
    labels[#labels + 1] = { value = value, x = x, y = y }
  end,
}
local function drewLabel(value)
  for _, label in ipairs(labels) do
    if label.value == value then return true end
  end
  return false
end
local function drewRect(x, y, width, height)
  for _, rectangle in ipairs(rectangles) do
    if rectangle.x == x and rectangle.y == y
        and rectangle.width == width and rectangle.height == height then
      return true
    end
  end
  return false
end
local function rectLuminance(x, y, width, height)
  for _, rectangle in ipairs(rectangles) do
    if rectangle.x == x and rectangle.y == y
        and rectangle.width == width and rectangle.height == height then
      return rectangle.luminance
    end
  end
end
local function resetDraws()
  rectangles, labels = {}, {}
end

CrashView.draw({ phase = "bet", betIndex = 4 }, FakeFont, 2889, Crash.BETS)
T.check(rectangles[1].width == 160 and rectangles[1].height == 144
    and rectangles[1].luminance > 2,
  "the crash screen begins with a bright full-canvas backdrop")
for _, wager in ipairs({ "10", "50", "100", "500" }) do
  T.check(drewLabel(wager), "the crash opener visibly lists the " .. wager .. " wager")
end

resetDraws()
CrashView.draw({ phase = "bet", betIndex = 1 }, FakeFont, 1000000, Crash.BETS)
T.check(drewLabel("C 1M"),
  "arcade headers compact the expanded maximum without overlapping the title")

resetDraws()
FlappyView.draw({ phase = "ready" }, FakeFont, 2889)
T.check(rectangles[1].luminance > 2,
  "tube flyer's initial screen uses a bright full-canvas frame")
T.check(drewLabel("10 COINS TO FLY"),
  "tube flyer's initial screen explains its price and objective")

resetDraws()
local resultFlight = Flappy.new(function() return 1 end)
resultFlight.score, resultFlight.earned = 5, 5
FlappyView.draw({ phase = "result", run = resultFlight }, FakeFont, 2814)
T.check(rectangles[1].luminance > 2,
  "tube flyer uses a bright full-canvas frame")
T.check(drewLabel("S 5"), "tube flyer keeps the live score legible in its top HUD")
T.check(drewLabel("FLIGHT OVER  S 5"), "the compact result ribbon repeats the final score")
T.check(drewRect(14, 101, 132, 37),
  "tube flyer's result panel leaves most of the frozen playfield visible")
local sawTubeCap = false
for _, rectangle in ipairs(rectangles) do
  if rectangle.width == 28 and rectangle.height == 7 then sawTubeCap = true end
end
T.check(sawTubeCap, "tube openings end in clearly drawn seven-pixel caps")

resetDraws()
CaseView.draw({ phase = "ready" }, FakeFont, 2814)
T.check(rectangles[1].luminance > 2,
  "prize case's initial screen uses a bright full-canvas frame")
T.check(drewLabel("RARE PRIZES INSIDE"),
  "prize case's initial screen communicates its reward purpose")

resetDraws()
CaseView.draw({ phase = "result", strip = strip, reelOffset = Cases.REEL_STOP_OFFSET,
  winnerIndex = Cases.WINNER_INDEX, winner = winner, message = "RARE CANDY" }, FakeFont, 2314)
T.check(rectangles[1].luminance > 2,
  "prize case uses a bright full-canvas frame")
T.check(drewRect(12, 101, 136, 37),
  "the prize result uses a compact lower ribbon instead of a dark backdrop")
T.check(drewLabel("RARE CANDY"), "the prize result spells out the complete reward")

resetDraws()
local masterStrip = {}
for index = 1, Cases.STRIP_LENGTH do masterStrip[index] = master end
CaseView.draw({ phase = "result", strip = masterStrip,
  reelOffset = Cases.REEL_STOP_OFFSET, winnerIndex = Cases.WINNER_INDEX,
  message = "MASTER BALL" }, FakeFont, 2814)
T.check((rectLuminance(60, 36, 40, 54) or 9) < 0.5,
  "the winning Master Ball card has a black jackpot frame")
T.check((rectLuminance(62, 38, 36, 50) or 0) > 2,
  "the winning Master Ball card has a bright gold face")

love.graphics.rectangle = originalRectangle

T.finish("arcade_rules")
