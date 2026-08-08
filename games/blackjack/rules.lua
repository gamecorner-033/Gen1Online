local Rules = {}

local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
local SUITS = { "C", "D", "H", "S" }

local function draw(round)
  assert(#round.deck > 0, "blackjack deck is empty")
  return table.remove(round.deck, 1)
end

local function finish(round, result, reason)
  round.state = "done"
  round.result = result
  round.reason = reason
  if result == "blackjack" then
    round.payout = math.floor(round.stake * 5 / 2)
  elseif result == "win" then
    round.payout = round.stake * 2
  elseif result == "push" then
    round.payout = round.stake
  else
    round.payout = 0
  end
  return round
end

function Rules.newDeck(rng)
  local deck = {}
  for _, suit in ipairs(SUITS) do
    for _, rank in ipairs(RANKS) do
      deck[#deck + 1] = { rank = rank, suit = suit }
    end
  end
  rng = rng or function(n) return math.random(n) end
  for i = #deck, 2, -1 do
    local j = rng(i)
    deck[i], deck[j] = deck[j], deck[i]
  end
  return deck
end

function Rules.handValue(hand)
  local total, aces = 0, 0
  for _, card in ipairs(hand) do
    if card.rank == "A" then
      total, aces = total + 11, aces + 1
    elseif card.rank == "K" or card.rank == "Q" or card.rank == "J" then
      total = total + 10
    else
      total = total + assert(tonumber(card.rank), "invalid card rank")
    end
  end
  while total > 21 and aces > 0 do
    total, aces = total - 10, aces - 1
  end
  return total, aces > 0
end

function Rules.isBlackjack(hand)
  return #hand == 2 and Rules.handValue(hand) == 21
end

function Rules.cardLabel(card)
  return card.rank .. card.suit
end

function Rules.newRound(bet, deck)
  assert(type(bet) == "number" and bet > 0 and bet % 1 == 0, "bet must be a positive integer")
  local round = {
    bet = bet,
    stake = bet,
    deck = deck or Rules.newDeck(),
    player = {},
    dealer = {},
    state = "playing",
  }
  round.player[1] = draw(round)
  round.dealer[1] = draw(round)
  round.player[2] = draw(round)
  round.dealer[2] = draw(round)

  local playerNatural = Rules.isBlackjack(round.player)
  local dealerNatural = Rules.isBlackjack(round.dealer)
  if playerNatural and dealerNatural then return finish(round, "push", "push") end
  if playerNatural then return finish(round, "blackjack", "natural") end
  if dealerNatural then return finish(round, "loss", "dealer_natural") end
  return round
end

function Rules.canDouble(round)
  return round.state == "playing" and #round.player == 2
end

function Rules.hit(round)
  if round.state ~= "playing" then return round end
  round.player[#round.player + 1] = draw(round)
  if Rules.handValue(round.player) > 21 then finish(round, "loss", "player_bust") end
  return round
end

function Rules.stand(round)
  if round.state ~= "playing" then return round end
  local dealerTotal = Rules.handValue(round.dealer)
  while dealerTotal < 17 do
    round.dealer[#round.dealer + 1] = draw(round)
    dealerTotal = Rules.handValue(round.dealer)
  end
  local playerTotal = Rules.handValue(round.player)
  if dealerTotal > 21 or playerTotal > dealerTotal then
    return finish(round, "win", dealerTotal > 21 and "dealer_bust" or "higher")
  elseif playerTotal == dealerTotal then
    return finish(round, "push", "push")
  end
  return finish(round, "loss", "lower")
end

function Rules.double(round)
  if not Rules.canDouble(round) then return round end
  round.stake = round.bet * 2
  Rules.hit(round)
  if round.state == "playing" then Rules.stand(round) end
  return round
end

return Rules
