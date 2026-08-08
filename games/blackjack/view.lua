-- Pixel-native blackjack presentation for the 160x144 game canvas.
-- Everything is drawn from primitives so the mod stays self-contained.

local View = {}

local C = {
  ink = { 0.10, 0.08, 0.10 },
  felt = { 0.06, 0.28, 0.20 },
  feltDark = { 0.035, 0.16, 0.13 },
  feltLight = { 0.10, 0.38, 0.26 },
  gold = { 0.91, 0.66, 0.20 },
  goldDark = { 0.43, 0.25, 0.08 },
  paper = { 0.96, 0.91, 0.73 },
  paperShade = { 0.74, 0.66, 0.48 },
  red = { 0.66, 0.10, 0.17 },
  black = { 0.09, 0.10, 0.13 },
  back = { 0.38, 0.07, 0.15 },
  backLight = { 0.77, 0.27, 0.30 },
  cream = { 1.00, 0.94, 0.70 },
  muted = { 0.40, 0.49, 0.41 },
}

local GLYPHS = {
  A = { "010", "101", "111", "101", "101" },
  B = { "110", "101", "110", "101", "110" },
  C = { "011", "100", "100", "100", "011" },
  D = { "110", "101", "101", "101", "110" },
  E = { "111", "100", "110", "100", "111" },
  F = { "111", "100", "110", "100", "100" },
  G = { "011", "100", "101", "101", "011" },
  H = { "101", "101", "111", "101", "101" },
  I = { "111", "010", "010", "010", "111" },
  J = { "111", "001", "001", "101", "010" },
  Q = { "010", "101", "101", "111", "011" },
  K = { "101", "110", "100", "110", "101" },
  L = { "100", "100", "100", "100", "111" },
  M = { "101", "111", "111", "101", "101" },
  N = { "101", "111", "111", "111", "101" },
  O = { "010", "101", "101", "101", "010" },
  P = { "110", "101", "110", "100", "100" },
  R = { "110", "101", "110", "101", "101" },
  S = { "011", "100", "010", "001", "110" },
  T = { "111", "010", "010", "010", "010" },
  U = { "101", "101", "101", "101", "111" },
  V = { "101", "101", "101", "101", "010" },
  W = { "101", "101", "111", "111", "101" },
  X = { "101", "101", "010", "101", "101" },
  Y = { "101", "101", "010", "010", "010" },
  Z = { "111", "001", "010", "100", "111" },
  ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "110", "001", "010", "100", "111" },
  ["3"] = { "110", "001", "010", "001", "110" },
  ["4"] = { "101", "101", "111", "001", "001" },
  ["5"] = { "111", "100", "110", "001", "110" },
  ["6"] = { "011", "100", "110", "101", "010" },
  ["7"] = { "111", "001", "010", "010", "010" },
  ["8"] = { "010", "101", "010", "101", "010" },
  ["9"] = { "010", "101", "011", "001", "110" },
  ["0"] = { "010", "101", "101", "101", "010" },
  ["!"] = { "010", "010", "010", "000", "010" },
  ["+"] = { "000", "010", "111", "010", "000" },
  ["-"] = { "000", "000", "111", "000", "000" },
  [":"] = { "000", "010", "000", "010", "000" },
  ["<"] = { "001", "010", "100", "010", "001" },
  [">"] = { "100", "010", "001", "010", "100" },
  ["?"] = { "110", "001", "010", "000", "010" },
}

local function color(c, alpha)
  love.graphics.setColor(c[1], c[2], c[3], alpha or 1)
end

local function rect(mode, x, y, w, h)
  love.graphics.rectangle(mode, math.floor(x), math.floor(y), w, h)
end

local function glyph(text, x, y, c, scale)
  scale = scale or 1
  color(c)
  local cursor = x
  for ch in tostring(text):gmatch(".") do
    local rows = GLYPHS[ch]
    if rows then
      for row, bits in ipairs(rows) do
        for col = 1, #bits do
          if bits:sub(col, col) == "1" then
            rect("fill", cursor + (col - 1) * scale, y + (row - 1) * scale,
              scale, scale)
          end
        end
      end
    end
    cursor = cursor + 4 * scale
  end
end

local function glyphWidth(text, scale)
  return #tostring(text) * 4 * (scale or 1)
end

local function suit(suit, x, y, c, scale)
  scale = scale or 1
  color(c)
  local function p(px, py, w, h) rect("fill", x + px * scale, y + py * scale, w * scale, h * scale) end
  if suit == "H" then
    p(0, 0, 2, 2); p(3, 0, 2, 2); p(0, 1, 5, 2); p(1, 3, 3, 1); p(2, 4, 1, 1)
  elseif suit == "D" then
    p(2, 0, 1, 1); p(1, 1, 3, 1); p(0, 2, 5, 1); p(1, 3, 3, 1); p(2, 4, 1, 1)
  elseif suit == "C" then
    p(1, 0, 3, 2); p(0, 1, 5, 3); p(2, 3, 1, 2); p(1, 4, 3, 1)
  else -- spade
    p(2, 0, 1, 1); p(1, 1, 3, 1); p(0, 2, 5, 2); p(2, 3, 1, 2); p(1, 4, 3, 1)
  end
end

-- Card-body pips deliberately use a different, much smaller mark than the
-- corner/ace suit. The old 5x5 marks touched each other and turned sevens,
-- eights and tens into one large ink blob at the game's real scale.
local function pip(suitName, x, y, c)
  color(c)
  if suitName == "H" then
    rect("fill", x, y, 1, 1); rect("fill", x + 2, y, 1, 1)
    rect("fill", x, y + 1, 3, 1); rect("fill", x + 1, y + 2, 1, 1)
  elseif suitName == "D" then
    rect("fill", x + 1, y, 1, 1); rect("fill", x, y + 1, 3, 1)
    rect("fill", x + 1, y + 2, 1, 1)
  elseif suitName == "C" then
    rect("fill", x + 1, y, 1, 1); rect("fill", x, y + 1, 3, 1)
    rect("fill", x + 1, y + 2, 1, 2)
  else
    rect("fill", x + 1, y, 1, 1); rect("fill", x, y + 1, 3, 1)
    rect("fill", x + 1, y + 2, 1, 2)
  end
end

local PIPS = {
  [2] = { {9, 7}, {9, 20} },
  [3] = { {9, 7}, {9, 14}, {9, 20} },
  [4] = { {7, 7}, {14, 7}, {7, 20}, {14, 20} },
  [5] = { {7, 7}, {14, 7}, {10, 14}, {7, 20}, {14, 20} },
  [6] = { {7, 7}, {14, 7}, {7, 14}, {14, 14}, {7, 20}, {14, 20} },
  [7] = { {7, 7}, {14, 7}, {10, 11}, {7, 14}, {14, 14}, {7, 20}, {14, 20} },
  [8] = { {7, 7}, {14, 7}, {10, 11}, {7, 14}, {14, 14}, {10, 17}, {7, 20}, {14, 20} },
  [9] = { {7, 7}, {10, 7}, {14, 7}, {7, 14}, {10, 14}, {14, 14}, {7, 20}, {10, 20}, {14, 20} },
  [10] = { {7, 7}, {14, 7}, {10, 10}, {7, 13}, {14, 13},
           {7, 16}, {14, 16}, {10, 19}, {7, 22}, {14, 22} },
}

function View.cardLayout(count)
  count = math.max(1, count or 1)
  local cardW = 20
  local step = count == 1 and 0 or math.min(23, math.floor((150 - cardW) / (count - 1)))
  local width = cardW + step * (count - 1)
  local out = {}
  local start = math.floor((160 - width) / 2)
  for i = 1, count do out[i] = start + (i - 1) * step end
  return out
end

function View.drawCard(card, x, y, hidden, emphasis)
  if emphasis then
    color(C.goldDark, 0.55)
    rect("fill", x - 2, y - 2, 24, 33)
  end
  -- Cut one pixel from each corner for a deliberate playing-card silhouette.
  color(C.ink, 0.55); rect("fill", x + 2, y + 2, 20, 29)
  color(C.ink); rect("fill", x + 1, y, 18, 29); rect("fill", x, y + 1, 20, 27)
  color(C.paperShade); rect("fill", x + 2, y + 1, 16, 27); rect("fill", x + 1, y + 2, 18, 25)
  color(hidden and C.back or C.paper)
  rect("fill", x + 2, y + 2, 16, 25); rect("fill", x + 3, y + 1, 14, 27)

  if hidden then
    color(C.gold); rect("line", x + 3, y + 3, 14, 23)
    color(C.backLight)
    for py = y + 5, y + 21, 4 do
      for px = x + 5, x + 13, 4 do
        rect("fill", px + ((py / 4) % 2), py, 2, 2)
      end
    end
    color(C.gold); rect("fill", x + 8, y + 12, 4, 5)
    color(C.back); rect("fill", x + 9, y + 13, 2, 3)
    return
  end

  local ink = (card.suit == "H" or card.suit == "D") and C.red or C.black
  glyph(card.rank, x + 2, y + 2, ink)
  pip(card.suit, x + 2, y + 8, ink)
  local numeric = tonumber(card.rank)
  if numeric then
    for _, pt in ipairs(PIPS[numeric] or {}) do pip(card.suit, x + pt[1] - 1, y + pt[2], ink) end
  elseif card.rank == "A" then
    suit(card.suit, x + 7, y + 10, ink, 2)
  else
    -- A crisp court-card monogram reads much better than a tiny pseudo-face.
    color(C.gold); rect("fill", x + 6, y + 8, 8, 2); rect("fill", x + 7, y + 7, 1, 1)
    rect("fill", x + 10, y + 6, 1, 2); rect("fill", x + 13, y + 7, 1, 1)
    color(C.paperShade); rect("fill", x + 5, y + 10, 10, 12)
    glyph(card.rank, x + 7, y + 11, ink, 2)
    pip(card.suit, x + 9, y + 22, ink)
  end
end

local function drawTable()
  color(C.goldDark); rect("fill", 0, 0, 160, 144)
  color(C.gold); rect("fill", 0, 2, 160, 3); rect("fill", 0, 138, 160, 4)
  color(C.feltDark); rect("fill", 3, 5, 154, 133)
  color(C.felt); rect("fill", 5, 7, 150, 129)
  color(C.feltLight, 0.35)
  for y = 9, 133, 8 do
    for x = 7 + (y % 16 == 9 and 0 or 4), 151, 8 do rect("fill", x, y, 1, 1) end
  end
  color(C.goldDark); rect("line", 7, 8, 146, 126)
end

local function chip(x, y, active)
  color(C.ink, 0.5); love.graphics.circle("fill", x + 1, y + 2, active and 12 or 10)
  color(active and C.gold or C.paperShade); love.graphics.circle("fill", x, y, active and 12 or 10)
  color(active and C.red or C.back); love.graphics.circle("fill", x, y, active and 9 or 7)
  color(C.paper); love.graphics.circle("line", x, y, active and 7 or 5)
  for a = 0, 7 do
    local angle = a * math.pi / 4
    local radius = active and 10 or 8
    rect("fill", x + math.floor(math.cos(angle) * radius), y + math.floor(math.sin(angle) * radius), 2, 2)
  end
end

local function button(Font, x, y, w, label, selected, enabled)
  local fill = enabled and (selected and C.gold or C.paperShade) or C.muted
  color(C.ink, 0.6); rect("fill", x + 1, y + 1, w, 15)
  color(fill); rect("fill", x, y, w, 14)
  color(selected and C.cream or C.goldDark); rect("line", x, y, w, 14)
  color(enabled and (selected and C.ink or C.cream) or C.feltDark)
  Font.draw(label, x + math.floor((w - #label * 8) / 2), y + 3)
end

local function hand(Font, cards, y, hideHole, lift)
  local xs = View.cardLayout(#cards)
  for i, card in ipairs(cards) do
    local dy = (i == #cards and lift or 0)
    View.drawCard(card, xs[i], y + dy, hideHole and i == 2, i == #cards and lift < 0)
  end
end

local RESULT = {
  blackjack = "BLACKJACK!", win = "YOU WIN!", push = "PUSH", loss = "DEALER WINS",
}
local REASON = {
  natural = "NATURAL", dealer_natural = "BLACKJACK",
  player_bust = "BUST", dealer_bust = "HOUSE BUST",
  higher = "HIGHER", lower = "LOWER", push = "EVEN",
}

function View.draw(state, Font, Rules, coinCount, bets)
  drawTable()
  glyph("BLACKJACK", 8, 8, C.cream, 2)
  local coinLabel = "C " .. tostring(coinCount)
  glyph(coinLabel, 152 - glyphWidth(coinLabel), 10, C.gold)

  if state.phase == "bet" then
    glyph("PLACE YOUR BET", 24, 28, C.cream, 2)
    local xs = { 25, 61, 99, 136 }
    for i, value in ipairs(bets) do
      chip(xs[i], 61, i == state.betIndex)
      local label = tostring(value)
      glyph(label, xs[i] - math.floor(glyphWidth(label) / 2), 76,
        i == state.betIndex and C.gold or C.paper)
    end
    glyph("<  PICK A CHIP  >", 48, 90, C.gold)
    if state.notice then
      glyph(state.notice, 46, 105, C.paper)
    else
      glyph("PAYS 3:2", 64, 105, C.paperShade)
    end
    button(Font, 25, 119, 62, "DEAL", true, true)
    glyph("B EXIT", 106, 123, C.paperShade)
  else
    local done = state.round.state == "done"
    local dealerValue = done and Rules.handValue(state.round.dealer) or "?"
    glyph("HOUSE " .. tostring(dealerValue), 8, 20, C.paperShade)
    hand(Font, state.round.dealer, 29, not done, state.cardLift or 0)
    glyph("YOU " .. tostring(Rules.handValue(state.round.player)), 8, 64, C.paperShade)
    hand(Font, state.round.player, 73, false, state.cardLift or 0)

    if state.phase == "play" then
      local labels = { "HIT", "STAND", "DOUBLE" }
      local widths, starts = { 42, 51, 51 }, { 5, 52, 106 }
      for i, label in ipairs(labels) do
        button(Font, starts[i], 118, widths[i], label, state.actionIndex == i,
          i < 3 or state.doubleEnabled)
      end
      local betLabel = "BET " .. state.round.stake
      glyph(betLabel, 152 - glyphWidth(betLabel), 64, C.gold)
    else
      local pulse = state.resultPulse or 0
      color(pulse > 0.5 and C.paper or C.gold)
      rect("fill", 13, 108, 134, 20)
      color(C.ink); Font.draw(RESULT[state.round.result] or "ROUND OVER", 20, 111)
      local delta = state.round.payout - state.round.stake
      local deltaText = delta > 0 and ("+" .. delta) or tostring(delta)
      Font.draw(deltaText .. "  " .. (REASON[state.round.reason] or ""), 20, 120)
      glyph("A AGAIN   B EXIT", 50, 130, C.paperShade)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

View.colors = C
View.glyph = glyph
View.glyphWidth = glyphWidth

return View
