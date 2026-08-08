package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local path = "mods/blackjack_corner/other/pawn/rules.lua"
local source = assert(io.open(path, "r"))
local Pawn = assert(load(source:read("*a"), "@" .. path))()
source:close()

local function mon(level, stat)
  return {
    level = level,
    stats = { hp = stat, attack = stat, defense = stat, speed = stat, special = stat },
  }
end

local function species(base, catchRate)
  return {
    baseStats = { hp = base, attack = base, defense = base, speed = base, special = base },
    catchRate = catchRate,
  }
end

T.check(Pawn.value(mon(20, 50), species(60, 45))
    > Pawn.value(mon(20, 30), species(60, 45)),
  "better current stats raise a Pokemon's pawn value")
T.check(Pawn.value(mon(20, 50), species(60, 20))
    > Pawn.value(mon(20, 50), species(60, 200)),
  "a lower catch rate makes a rarer Pokemon more valuable")
T.check(Pawn.value(mon(60, 50), species(60, 45))
    > Pawn.value(mon(10, 50), species(60, 45)),
  "higher-level Pokemon are worth more")
T.check(Pawn.value(mon(20, 50), species(100, 45))
    > Pawn.value(mon(20, 50), species(40, 45)),
  "stronger species base stats raise pawn value")
T.eq(Pawn.value(mon(1, 0), species(0, 255)), 50,
  "pawn values retain a useful minimum")
T.eq(Pawn.value(mon(100, 999), species(999, 1)), 7500,
  "pawn values cannot overflow the Coin Case economy")
T.eq(Pawn.value(mon(23, 47), species(63, 87)) % 10, 0,
  "pawn values use clean ten-coin increments")
T.eq(Pawn.redeemCost(100), 130,
  "redeeming costs exactly thirty percent more")
T.eq(Pawn.redeemCost(101), 132,
  "fractional redemption costs round up in the broker's favor")
T.eq(Pawn.LIMIT, 5, "the broker keeps five recoverable Pokemon")

T.finish("pawn_rules")
