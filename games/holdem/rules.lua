local Rules = {}

local RANKS = { "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A" }
local SUITS = { "C", "D", "H", "S" }
local VALUE = { ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5, ["6"] = 6,
  ["7"] = 7, ["8"] = 8, ["9"] = 9, ["10"] = 10,
  J = 11, Q = 12, K = 13, A = 14 }

local NAMES = {
  [0] = "HIGH CARD", [1] = "ONE PAIR", [2] = "TWO PAIR",
  [3] = "THREE OF A KIND", [4] = "STRAIGHT", [5] = "FLUSH",
  [6] = "FULL HOUSE", [7] = "FOUR OF A KIND", [8] = "STRAIGHT FLUSH",
}

local function draw(round)
  assert(#round.deck > 0, "holdem deck is empty")
  return table.remove(round.deck, 1)
end

local function descending(values)
  table.sort(values, function(a, b) return a > b end)
  return values
end

local function straightHigh(values)
  local present = {}
  for _, value in ipairs(values) do present[value] = true end
  if present[14] then present[1] = true end
  local run = 0
  for value = 14, 1, -1 do
    if present[value] then
      run = run + 1
      if run == 5 then return value + 4 end
    else
      run = 0
    end
  end
end

local function result(category, tiebreak)
  local name = category == 8 and tiebreak[1] == 14 and "ROYAL FLUSH"
    or NAMES[category]
  return { category = category, tiebreak = tiebreak, name = name }
end

local function evaluateFive(cards)
  assert(#cards == 5, "holdem evaluation needs five cards")
  local values, counts = {}, {}
  local flush = true
  for i, card in ipairs(cards) do
    local value = assert(VALUE[card.rank], "invalid holdem rank")
    values[i] = value
    counts[value] = (counts[value] or 0) + 1
    if i > 1 and card.suit ~= cards[1].suit then flush = false end
  end
  descending(values)
  local straight = straightHigh(values)
  if flush and straight then return result(8, { straight }) end

  local groups = {}
  for value, count in pairs(counts) do
    groups[#groups + 1] = { value = value, count = count }
  end
  table.sort(groups, function(a, b)
    return a.count == b.count and a.value > b.value or a.count > b.count
  end)

  if groups[1].count == 4 then
    return result(7, { groups[1].value, groups[2].value })
  end
  if groups[1].count == 3 and groups[2].count == 2 then
    return result(6, { groups[1].value, groups[2].value })
  end
  if flush then return result(5, values) end
  if straight then return result(4, { straight }) end
  if groups[1].count == 3 then
    local kickers = {}
    for _, group in ipairs(groups) do
      if group.count == 1 then kickers[#kickers + 1] = group.value end
    end
    return result(3, { groups[1].value, kickers[1], kickers[2] })
  end
  if groups[1].count == 2 and groups[2].count == 2 then
    local high = math.max(groups[1].value, groups[2].value)
    local low = math.min(groups[1].value, groups[2].value)
    return result(2, { high, low, groups[3].value })
  end
  if groups[1].count == 2 then
    local kickers = {}
    for _, group in ipairs(groups) do
      if group.count == 1 then kickers[#kickers + 1] = group.value end
    end
    descending(kickers)
    return result(1, { groups[1].value, kickers[1], kickers[2], kickers[3] })
  end
  return result(0, values)
end

function Rules.compare(left, right)
  if left.category ~= right.category then
    return left.category > right.category and 1 or -1
  end
  local length = math.max(#left.tiebreak, #right.tiebreak)
  for i = 1, length do
    local a, b = left.tiebreak[i] or 0, right.tiebreak[i] or 0
    if a ~= b then return a > b and 1 or -1 end
  end
  return 0
end

function Rules.evaluate(cards)
  assert(#cards >= 5 and #cards <= 7, "holdem needs five to seven cards")
  local best
  for a = 1, #cards - 4 do
    for b = a + 1, #cards - 3 do
      for c = b + 1, #cards - 2 do
        for d = c + 1, #cards - 1 do
          for e = d + 1, #cards do
            local candidate = evaluateFive({ cards[a], cards[b], cards[c], cards[d], cards[e] })
            if not best or Rules.compare(candidate, best) > 0 then best = candidate end
          end
        end
      end
    end
  end
  return best
end

function Rules.newDeck(rng)
  local deck = {}
  for _, suit in ipairs(SUITS) do
    for _, rank in ipairs(RANKS) do deck[#deck + 1] = { rank = rank, suit = suit } end
  end
  rng = rng or function(n) return math.random(n) end
  for i = #deck, 2, -1 do
    local j = rng(i)
    deck[i], deck[j] = deck[j], deck[i]
  end
  return deck
end

function Rules.newRound(startingBet, deck)
  assert(type(startingBet) == "number" and startingBet > 0 and startingBet % 1 == 0,
    "starting bet must be a positive integer")
  local round = {
    start = startingBet,
    play = 0,
    deck = deck or Rules.newDeck(),
    player = {},
    dealer = {},
    board = {},
    phase = "preflop",
    state = "playing",
  }
  round.player[1] = draw(round)
  round.dealer[1] = draw(round)
  round.player[2] = draw(round)
  round.dealer[2] = draw(round)
  return round
end

local function reveal(round, count)
  for _ = 1, count do round.board[#round.board + 1] = draw(round) end
end

function Rules.check(round)
  if round.state ~= "playing" then return false end
  if round.phase == "preflop" then
    reveal(round, 3)
    round.phase = "flop"
    return true
  elseif round.phase == "flop" then
    reveal(round, 2)
    round.phase = "river"
    return true
  elseif round.phase == "river" then
    Rules.settle(round)
    return true
  end
  return false
end

local function combined(hole, board)
  local cards = { hole[1], hole[2] }
  for _, card in ipairs(board) do cards[#cards + 1] = card end
  return cards
end

function Rules.totalStake(round)
  return round.start + round.play
end

function Rules.settle(round)
  if round.state == "done" then return round end
  while #round.board < 5 do reveal(round, 1) end
  round.playerEval = Rules.evaluate(combined(round.player, round.board))
  round.dealerEval = Rules.evaluate(combined(round.dealer, round.board))
  local comparison = Rules.compare(round.playerEval, round.dealerEval)
  round.state = "done"
  round.phase = "result"
  if comparison < 0 then
    round.result = "loss"
    round.reason = "dealer_wins"
    round.payout = 0
  elseif comparison == 0 then
    round.result, round.reason = "push", "equal_hands"
    round.payout = Rules.totalStake(round)
  else
    round.result = "win"
    round.reason = "player_wins"
    round.payout = Rules.totalStake(round) * 2
  end
  return round
end

function Rules.bet(round, multiplier)
  if round.state ~= "playing" then return false end
  local allowed = (round.phase == "preflop" and (multiplier == 3 or multiplier == 4))
    or (round.phase == "flop" and multiplier == 2)
    or (round.phase == "river" and multiplier == 1)
  if not allowed then return false end
  round.play = round.play + round.start * multiplier
  if round.phase == "river" then
    Rules.settle(round)
  else
    Rules.check(round)
  end
  return true
end

function Rules.actionMultipliers(phase)
  if phase == "preflop" then return { 3, 4 } end
  if phase == "flop" then return { 2 } end
  if phase == "river" then return { 1 } end
  return {}
end

return Rules
