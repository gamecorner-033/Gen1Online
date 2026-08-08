package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Rules = assert(loadfile("mods/blackjack_corner/games/holdem/rules.lua"))()

local function card(rank, suit) return { rank = tostring(rank), suit = suit or "S" } end
local function cards(spec)
  local out = {}
  for token in spec:gmatch("%S+") do
    out[#out + 1] = card(token:sub(1, -2), token:sub(-1))
  end
  return out
end

do
  local hand = Rules.evaluate(cards("AS KS QS JS 10S 2D 3C"))
  T.eq(hand.category, 8, "a royal flush is a straight flush")
  T.eq(hand.name, "ROYAL FLUSH", "ace-high straight flush gets its casino name")
  T.eq(hand.tiebreak[1], 14, "royal flush is ace high")
end

do
  local hand = Rules.evaluate(cards("AS 2D 3C 4H 5S KD QC"))
  T.eq(hand.category, 4, "ace can play low in a wheel straight")
  T.eq(hand.tiebreak[1], 5, "wheel straight is five high")
end

do
  local examples = {
    { 7, "9S 9H 9D 9C AS" },
    { 6, "8S 8H 8D 4C 4S" },
    { 5, "AS JS 8S 5S 2S" },
    { 4, "9S 8H 7D 6C 5S" },
    { 3, "QS QH QD 8C 3S" },
    { 2, "JS JH 4D 4C AS" },
    { 1, "10S 10H AD 7C 3S" },
    { 0, "AS JD 8C 5H 2S" },
  }
  for _, example in ipairs(examples) do
    T.eq(Rules.evaluate(cards(example[2])).category, example[1],
      "five-card evaluator recognizes category " .. example[1])
  end
end

do
  local fullHouse = Rules.evaluate(cards("AH AD AC KS KD 2C 3H"))
  local flush = Rules.evaluate(cards("AS JS 9S 6S 3S KD QC"))
  T.eq(fullHouse.category, 6, "best five finds a full house")
  T.check(Rules.compare(fullHouse, flush) > 0, "full house beats a flush")
end

do
  local aces = Rules.evaluate(cards("AH AD KC QS 9D 4C 2H"))
  local kings = Rules.evaluate(cards("KH KD AC QS 9D 4C 2H"))
  T.check(Rules.compare(aces, kings) > 0, "pair rank breaks a tie before kickers")
end

do
  local deck = cards("AS KH AD KC 2C 3D 4H 5S 9C")
  local round = Rules.newRound(10, deck)
  T.eq(round.phase, "preflop", "holdem begins before the flop")
  T.eq(Rules.totalStake(round), 10, "the hand begins with one starting bet")
  T.check(Rules.check(round), "player can check pre-flop")
  T.eq(round.phase, "flop", "first check reveals the flop")
  T.eq(#round.board, 3, "the flop has three community cards")
  T.check(Rules.check(round), "player can check the flop")
  T.eq(round.phase, "river", "second check reveals turn and river")
  T.eq(#round.board, 5, "all community cards are visible at the river")
  T.check(Rules.bet(round, 1), "river play bet matches the starting bet")
  T.eq(round.play, 10, "river bet uses the 1x multiplier")
  T.eq(round.state, "done", "river bet goes to showdown")
end

do
  local round = Rules.newRound(25, cards("AS KH AD KC 2C 3D 4H 5S 9C"))
  T.check(Rules.bet(round, 4), "pre-flop supports a four-times play bet")
  T.eq(round.play, 100, "4x bet is based on the starting bet")
  T.eq(round.phase, "flop", "a pre-flop bet advances only to the flop")
  T.eq(#round.board, 3, "a pre-flop bet reveals only three community cards")
  T.eq(round.state, "playing", "betting pre-flop keeps the hand open")
  T.check(Rules.bet(round, 2), "the player can bet again on the flop")
  T.eq(round.play, 150, "flop bet is added to the earlier play wager")
  T.eq(round.phase, "river", "the flop bet advances to the river")
  T.check(Rules.bet(round, 1), "the player can bet again on the river")
  T.eq(round.play, 175, "river bet is added before showdown")
  T.eq(round.state, "done", "only the river bet ends the hand")
end

do
  local round = Rules.newRound(10, cards("AS KH AD KC 2C 3D 4H 5S 9C"))
  T.check(not Rules.bet(round, 2), "pre-flop refuses the flop-only multiplier")
  T.eq(round.state, "playing", "invalid actions do not end the hand")
end

local function settled(player, dealer, board, startingBet, play)
  local round = {
    start = startingBet or 10, play = play or 10,
    player = cards(player), dealer = cards(dealer), board = cards(board),
    deck = {}, phase = "river", state = "playing",
  }
  return Rules.settle(round)
end

do
  local round = settled("AS KS", "9C 9D", "QS JS 10S 2D 3C", 10, 40)
  T.eq(round.result, "win", "royal flush wins the showdown")
  T.eq(round.payout, 100, "a win pays all committed wagers one to one")
end

do
  local round = settled("9S 8H", "7C 7D", "7S 6D 5C 2H KC", 10, 20)
  T.eq(round.playerEval.category, 4, "player makes a straight")
  T.eq(round.payout, 60, "a straight win pays the complete stake one to one")
  T.eq(round.payout - Rules.totalStake(round), 30, "showdown reports net winnings")
end

do
  local round = settled("AS 8S", "KC KD", "2S 4S 6S 9C JD", 10, 10)
  T.eq(round.playerEval.category, 5, "player makes a flush at showdown")
  T.eq(round.payout, 40, "hand category does not change the standard win payout")
end

do
  local round = settled("AH 8D", "KH 7D", "2C 4S 6H 9C JD", 10, 10)
  T.eq(round.result, "win", "ace high beats king high")
  T.eq(round.payout, 40, "the house pays a high-card win without qualification")
end

do
  local round = settled("QH 8D", "KH 7D", "2C 4S 6H 9C JD", 10, 10)
  T.eq(round.result, "loss", "the dealer wins by normal hand comparison")
  T.eq(round.payout, 0, "a loss forfeits the complete stake")
end

do
  local round = settled("AH KD", "AS KC", "2C 4S 6H 9C JD", 10, 10)
  T.eq(round.result, "push", "equal seven-card hands push")
  T.eq(round.payout, Rules.totalStake(round), "a push returns every wager")
end

do
  local round = Rules.newRound(50, cards("AS KH AD KC 2C 3D 4H 5S 9C"))
  Rules.check(round)
  Rules.check(round)
  T.check(Rules.check(round), "the river can be checked for a free showdown")
  T.eq(round.state, "done", "checking the river ends the hand")
  T.check(round.result == "win" or round.result == "loss" or round.result == "push",
    "a river check settles by normal hand comparison")
end

T.finish("holdem_rules")
