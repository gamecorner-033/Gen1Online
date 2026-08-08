package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Rules = assert(loadfile("mods/blackjack_corner/games/blackjack/rules.lua"))()

local function card(rank, suit) return { rank = tostring(rank), suit = suit or "S" } end
local function deck(...)
  local out = { ... }
  while #out < 20 do out[#out + 1] = card(2, "C") end
  return out
end

do
  local total, soft = Rules.handValue({ card("A"), card(6) })
  T.eq(total, 17, "ace is high when the hand fits")
  T.check(soft, "ace-high seventeen is soft")
  total, soft = Rules.handValue({ card("A"), card(6), card(10) })
  T.eq(total, 17, "ace becomes low to prevent a bust")
  T.check(not soft, "adjusted ace is no longer soft")
end

do
  local round = Rules.newRound(100, deck(card("A"), card(9), card("K"), card(7)))
  T.eq(round.result, "blackjack", "a two-card 21 is blackjack")
  T.eq(round.reason, "natural", "a natural carries a specific result reason")
  T.eq(round.payout, 250, "blackjack returns stake plus a 3:2 win")
end

do
  local round = Rules.newRound(100, deck(card(10), card("A"), card(7), card(6)))
  Rules.stand(round)
  T.eq(round.result, "push", "dealer stands on soft seventeen")
  T.eq(#round.dealer, 2, "soft seventeen draws no extra card")
end

do
  local round = Rules.newRound(100,
    deck(card(10), card(10), card(6), card(6), card(5)))
  Rules.double(round)
  T.eq(round.stake, 200, "double down doubles the stake")
  T.eq(#round.player, 3, "double down draws exactly one player card")
  T.eq(round.result, "win", "the doubled twenty-one beats the dealer")
  T.eq(round.payout, 400, "a doubled win returns twice the doubled stake")
end

do
  local round = Rules.newRound(50,
    deck(card(10), card(9), card(8), card(7), card(10)))
  Rules.hit(round)
  T.eq(round.result, "loss", "a player bust loses immediately")
  T.eq(round.reason, "player_bust", "a bust is distinguished from a lower hand")
  T.eq(round.payout, 0, "a bust returns no coins")
end

do
  local round = Rules.newRound(50,
    deck(card(10), card(6), card(8), card(9), card(10)))
  Rules.stand(round)
  T.eq(round.result, "win", "a dealer bust wins the hand")
  T.eq(round.reason, "dealer_bust", "dealer busts are explained in the result")
end

T.finish("blackjack_rules")
