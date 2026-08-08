-- Premium High-Detail Texas Hold'em & Casino Lounge Presentation for the 160x144 Canvas
-- Featuring Crystal-Clear Native Pixel Cards, Mahogany Brass Rail,
-- Emerald Diamond Felt, 3D Casino Chips, Labeled Trays, and Live Multiplayer Pods.

local View = {}

local C = {
  ink = { 0.06, 0.05, 0.08 },
  woodRail = { 0.28, 0.12, 0.08 },
  woodDark = { 0.16, 0.06, 0.04 },
  woodLight = { 0.44, 0.20, 0.12 },
  brass = { 0.95, 0.82, 0.40 },
  brassDark = { 0.50, 0.38, 0.12 },
  felt = { 0.03, 0.28, 0.18 },
  feltDark = { 0.015, 0.15, 0.10 },
  feltLight = { 0.06, 0.42, 0.28 },
  feltLine = { 0.88, 0.76, 0.32 },
  gold = { 0.96, 0.78, 0.22 },
  goldBright = { 1.00, 0.92, 0.48 },
  goldDark = { 0.48, 0.30, 0.08 },
  cream = { 1.00, 0.96, 0.80 },
  paper = { 0.98, 0.96, 0.88 },
  paperShade = { 0.84, 0.80, 0.68 },
  cardBack = { 0.58, 0.12, 0.18 },
  cardBackDark = { 0.32, 0.05, 0.09 },
  cardBackLight = { 0.88, 0.28, 0.35 },
  red = { 0.82, 0.15, 0.20 },
  black = { 0.10, 0.10, 0.14 },
  blue = { 0.18, 0.52, 0.82 },
  disabled = { 0.28, 0.35, 0.38 },
}

local GLYPHS = {
  A = { "010", "101", "111", "101", "101" },
  K = { "101", "110", "100", "110", "101" },
  Q = { "010", "101", "101", "111", "011" },
  J = { "111", "001", "001", "101", "010" },
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
}

local function color(value, alpha)
  love.graphics.setColor(value[1], value[2], value[3], alpha or 1)
end

local function rect(mode, x, y, w, h)
  love.graphics.rectangle(mode, math.floor(x), math.floor(y), math.floor(w), math.floor(h))
end

local function centered(Font, text, y)
  Font.draw(text, math.floor((160 - Font.width(text)) / 2), math.floor(y))
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
            rect("fill", cursor + (col - 1) * scale, y + (row - 1) * scale, scale, scale)
          end
        end
      end
    end
    cursor = cursor + 4 * scale
  end
end

local function pip(suitName, x, y, c)
  color(c)
  if suitName == "H" or suitName == "hearts" then
    rect("fill", x, y, 1, 1); rect("fill", x + 2, y, 1, 1)
    rect("fill", x, y + 1, 3, 1); rect("fill", x + 1, y + 2, 1, 1)
  elseif suitName == "D" or suitName == "diamonds" then
    rect("fill", x + 1, y, 1, 1); rect("fill", x, y + 1, 3, 1)
    rect("fill", x + 1, y + 2, 1, 1)
  elseif suitName == "C" or suitName == "clubs" then
    rect("fill", x + 1, y, 1, 1); rect("fill", x, y + 1, 3, 1)
    rect("fill", x + 1, y + 2, 1, 2)
  else -- Spades
    rect("fill", x + 1, y, 1, 1); rect("fill", x, y + 1, 3, 1)
    rect("fill", x + 1, y + 2, 1, 2)
  end
end

local function suitArt(s, x, y, c, scale)
  scale = scale or 1
  color(c)
  local function p(px, py, w, h) rect("fill", x + px * scale, y + py * scale, w * scale, h * scale) end
  if s == "H" or s == "hearts" then
    p(0, 0, 2, 2); p(3, 0, 2, 2); p(0, 1, 5, 2); p(1, 3, 3, 1); p(2, 4, 1, 1)
  elseif s == "D" or s == "diamonds" then
    p(2, 0, 1, 1); p(1, 1, 3, 1); p(0, 2, 5, 1); p(1, 3, 3, 1); p(2, 4, 1, 1)
  elseif s == "C" or s == "clubs" then
    p(1, 0, 3, 2); p(0, 1, 5, 3); p(2, 3, 1, 2); p(1, 4, 3, 1)
  else -- Spades
    p(2, 0, 1, 1); p(1, 1, 3, 1); p(0, 2, 5, 2); p(2, 3, 1, 2); p(1, 4, 3, 1)
  end
end

local PIPS = {
  [2] = { {9, 7}, {9, 18} },
  [3] = { {9, 6}, {9, 13}, {9, 19} },
  [4] = { {6, 6}, {12, 6}, {6, 19}, {12, 19} },
  [5] = { {6, 6}, {12, 6}, {9, 13}, {6, 19}, {12, 19} },
  [6] = { {6, 6}, {12, 6}, {6, 13}, {12, 13}, {6, 19}, {12, 19} },
  [7] = { {6, 6}, {12, 6}, {9, 10}, {6, 13}, {12, 13}, {6, 19}, {12, 19} },
  [8] = { {6, 6}, {12, 6}, {9, 10}, {6, 13}, {12, 13}, {9, 16}, {6, 19}, {12, 19} },
  [9] = { {6, 6}, {9, 6}, {12, 6}, {6, 13}, {9, 13}, {12, 13}, {6, 19}, {9, 19}, {12, 19} },
  [10] = { {6, 6}, {12, 6}, {9, 9}, {6, 12}, {12, 12}, {6, 15}, {12, 15}, {9, 18}, {6, 21}, {12, 21} },
}

-- =========================================================================
-- PREMIUM CASINO TABLE SURFACE
-- =========================================================================
local function drawCasinoTable()
  color(C.woodDark); rect("fill", 0, 0, 160, 144)
  color(C.woodRail); rect("fill", 1, 1, 158, 142)
  color(C.woodLight); rect("fill", 2, 2, 156, 1); rect("fill", 2, 2, 1, 140)

  -- Brass Stud Inlays
  color(C.brass)
  for x = 6, 154, 16 do
    rect("fill", x, 2, 2, 1); rect("fill", x, 141, 2, 1)
  end
  for y = 6, 138, 16 do
    rect("fill", 2, y, 1, 2); rect("fill", 157, y, 1, 2)
  end

  -- Emerald Felt Surface
  color(C.feltDark); rect("fill", 4, 4, 152, 136)
  color(C.felt); rect("fill", 5, 5, 150, 134)

  -- Diamond Pattern
  color(C.feltLight, 0.25)
  for y = 7, 137, 8 do
    local offset = (y % 16 == 7) and 0 or 4
    for x = 8 + offset, 150, 8 do
      rect("fill", x, y, 1, 1)
    end
  end

  color(C.feltLine, 0.45); rect("line", 8, 8, 144, 128)
  color(C.brassDark, 0.65); rect("line", 9, 9, 142, 126)
end

-- =========================================================================
-- 3D CASINO POKER CHIP RENDERING
-- =========================================================================
local function drawCasinoChip(x, y, value, active)
  local r = active and 10 or 8
  color(C.ink, 0.50); love.graphics.circle("fill", x + 1, y + 2, r)
  local rimColor = (value >= 500 and C.ink) or (value >= 100 and C.black) or (value >= 50 and C.blue) or C.red
  if active then rimColor = C.gold end
  color(rimColor); love.graphics.circle("fill", x, y, r)

  color(C.cream)
  for angle = 0, 7 do
    local rad = angle * math.pi / 4
    local px = x + math.floor(math.cos(rad) * (r - 2))
    local py = y + math.floor(math.sin(rad) * (r - 2))
    rect("fill", px, py, 2, 2)
  end

  color(C.paper); love.graphics.circle("fill", x, y, r - 3)
  color(active and C.goldDark or C.feltDark); love.graphics.circle("line", x, y, r - 3)
end

-- =========================================================================
-- 100% CRYSTAL-CLEAR NATIVE PIXEL PLAYING CARD RENDERER
-- =========================================================================
function View.drawCard(card, x, y, hidden, emphasis)
  local w, h = 18, 26
  if emphasis then
    color(C.goldBright, 0.95); rect("fill", x - 1, y - 1, w + 2, h + 2)
    color(C.goldDark); rect("line", x - 1, y - 1, w + 2, h + 2)
  end

  -- Card Drop Shadow & Backing
  color(C.ink, 0.60); rect("fill", x + 1, y + 1, w, h)
  color(C.ink); rect("fill", x, y, w, h)
  color(C.paper); rect("fill", x + 1, y + 1, w - 2, h - 2)

  -- 1. Face-Down Card Back with Royal Diamond Lattice & Brass Crest
  if hidden then
    color(C.cardBack); rect("fill", x + 1, y + 1, w - 2, h - 2)
    color(C.brass); rect("line", x + 2, y + 2, w - 4, h - 4)
    color(C.cardBackLight)
    for py = y + 4, y + h - 5, 4 do
      for px = x + 4, x + w - 5, 4 do
        rect("fill", px + ((py / 4) % 2), py, 2, 2)
      end
    end
    color(C.brass); rect("fill", x + 7, y + 10, 4, 6)
    color(C.cardBackDark); rect("fill", x + 8, y + 11, 2, 4)
    return
  end

  -- 2. 100% Crystal-Clear Procedural Native Pixel Card Face
  local sCode = (card.suit == "H" or card.suit == "hearts") and "H" or
                (card.suit == "D" or card.suit == "diamonds") and "D" or
                (card.suit == "C" or card.suit == "clubs") and "C" or "S"
  local isRed = (sCode == "H" or sCode == "D")
  local ink = isRed and C.red or C.black
  local rStr = tostring(card.rank):upper()

  -- Corner Rank & Pip (Top-Left)
  glyph(rStr, x + 2, y + 2, ink)
  pip(sCode, x + 2, y + 8, ink)

  local numeric = tonumber(rStr)
  if numeric then
    for _, pt in ipairs(PIPS[numeric] or {}) do
      pip(sCode, x + pt[1] - 1, y + pt[2], ink)
    end
  elseif rStr == "A" then
    suitArt(sCode, x + 6, y + 10, ink, 2)
  else
    -- Royal Court Cards (K, Q, J) with Gold Filigree Crown
    color(C.gold); rect("fill", x + 5, y + 8, 8, 2); rect("fill", x + 6, y + 7, 1, 1)
    rect("fill", x + 9, y + 6, 1, 2); rect("fill", x + 12, y + 7, 1, 1)
    color(C.paperShade); rect("fill", x + 4, y + 10, 10, 11)
    glyph(rStr, x + 6, y + 11, ink, 2)
    pip(sCode, x + 8, y + 21, ink)
  end
end

-- =========================================================================
-- COMMUNITY CARD TRAYS & CARD SLOTS
-- =========================================================================
local function drawCardTraySlot(x, y, label, active)
  color(C.feltDark, 0.90); rect("fill", x, y, 18, 26)
  color(active and C.gold or C.feltLight, active and 0.95 or 0.45)
  rect("line", x, y, 18, 26)
  if label then
    color(active and C.gold or C.feltLight, 0.75)
    love.graphics.print(label, x + 2, y + 10, 0, 0.55, 0.55)
  end
end

local function drawCommunityCards(CardView, cards)
  local xs = { 14, 40, 66, 96, 122 }
  local labels = { "FLOP", "FLOP", "FLOP", "TURN", "RVR" }
  for i = 1, 5 do
    local card = cards and cards[i]
    if card then
      View.drawCard(card, xs[i], 44, false, false)
    else
      drawCardTraySlot(xs[i], 44, labels[i], i <= (cards and #cards + 1 or 1))
    end
  end
end

-- =========================================================================
-- ACTION BUTTONS WITH SELECTION GLOW
-- =========================================================================
local function drawActionButton(Font, x, y, width, label, selected, enabled)
  local fill = enabled and (selected and C.gold or C.paper) or C.disabled
  color(C.ink, 0.60); rect("fill", x + 1, y + 1, width, 14)
  color(fill); rect("fill", x, y, width, 13)
  color(selected and C.goldBright or (enabled and C.brassDark or C.feltDark))
  rect("line", x, y, width, 13)
  color(enabled and (selected and C.ink or C.ink) or C.feltDark)
  Font.draw(label, x + math.floor((width - Font.width(label)) / 2), y + 2)
end

-- =========================================================================
-- 1. MODE SELECTION SCREEN (SOLO VS ONLINE MULTIPLAYER)
-- =========================================================================
function View.drawModeSelect(modeIndex, Font, CardView, coinCount)
  drawCasinoTable()
  centered(Font, "★ CELADON TEXAS HOLD'EM ★", 12)

  local coinStr = string.format("COINS: %d", coinCount or 0)
  color(C.goldBright); centered(Font, coinStr, 24)

  local modes = {
    { title = "1. SOLO PRACTICE TABLE", desc = "House Poker vs Celadon Dealer" },
    { title = "2. ONLINE MULTIPLAYER", desc = "Live Table with Online Trainers!" }
  }

  for i, m in ipairs(modes) do
    local isSel = (modeIndex == i)
    color(isSel and C.gold or C.feltDark, isSel and 1 or 0.85)
    rect("fill", 14, 48 + (i - 1) * 36, 132, 30)
    color(isSel and C.goldBright or C.brassDark)
    rect("line", 14, 48 + (i - 1) * 36, 132, 30)

    color(isSel and C.ink or C.paper)
    Font.draw(m.title, 18, 52 + (i - 1) * 36)
    color(isSel and C.feltDark or C.cream)
    Font.draw(m.desc, 18, 64 + (i - 1) * 36)
  end

  color(C.paper); centered(Font, "A: SELECT    B: EXIT", 124)
  love.graphics.setColor(1, 1, 1, 1)
end

-- =========================================================================
-- 2. ONLINE TABLE TIER SELECT SCREEN
-- =========================================================================
function View.drawTableSelect(tierIndex, tiers, Font, CardView, coinCount, notice)
  drawCasinoTable()
  centered(Font, "★ ONLINE POKER TABLES ★", 8)
  local coinStr = string.format("YOUR COINS: %d", coinCount or 0)
  color(C.gold); centered(Font, coinStr, 20)

  local y = 34
  for i, t in ipairs(tiers) do
    local isSel = (tierIndex == i)
    color(isSel and C.gold or C.feltDark, isSel and 1 or 0.85)
    rect("fill", 12, y, 136, 20)
    color(isSel and C.goldBright or C.brassDark)
    rect("line", 12, y, 136, 20)

    color(isSel and C.ink or C.paper)
    Font.draw(t.label, 16, y + 2)
    color(isSel and C.feltDark or C.cream)
    Font.draw(string.format("BLIND: %dc | BUY-IN: %dc", t.minBet, t.buyIn), 16, y + 10)
    y = y + 22
  end

  if notice then
    color(C.red); centered(Font, notice, 114)
  end

  color(C.paper); centered(Font, "A: JOIN TABLE    B: BACK", 126)
  love.graphics.setColor(1, 1, 1, 1)
end

-- =========================================================================
-- 3. LIVE ONLINE MULTIPLAYER TABLE VIEW
-- =========================================================================
function View.drawOnlineTable(st, actionIndex, raiseAmount, Font, CardView, coinCount, notice)
  drawCasinoTable()

  if not st then
    color(C.cream); centered(Font, "CONNECTING TO ONLINE TABLE...", 64)
    love.graphics.setColor(1, 1, 1, 1)
    return
  end

  -- Table Header & Pot Tray
  color(C.woodDark); rect("fill", 8, 6, 144, 14)
  color(C.brass); rect("line", 8, 6, 144, 14)

  local tName = (st.tableName or "POKER TABLE"):upper()
  color(C.cream); Font.draw(tName, 12, 9)

  local potStr = string.format("POT: %d COINS", st.pot or 0)
  color(C.goldBright); Font.draw(potStr, 148 - Font.width(potStr), 9)

  -- Opponent Pods (Seats 0 to 5)
  local seats = st.seats or {}
  local seatPositions = {
    { x = 10, y = 22 },
    { x = 58, y = 22 },
    { x = 106, y = 22 },
    { x = 8, y = 84 },
    { x = 108, y = 84 },
  }

  local oppIdx = 1
  for _, s in ipairs(seats) do
    if not s.cards or #s.cards == 0 then
      if oppIdx <= #seatPositions then
        local pos = seatPositions[oppIdx]
        oppIdx = oppIdx + 1

        color(s.isTurn and C.gold or C.feltDark, 0.90)
        rect("fill", pos.x, pos.y, 44, 18)
        color(s.isTurn and C.goldBright or C.brassDark)
        rect("line", pos.x, pos.y, 44, 18)

        color(s.isTurn and C.ink or C.paper)
        local sName = (s.name or "TRAINER"):sub(1, 6)
        if s.isDealer then sName = "(D) " .. sName end
        Font.draw(sName, pos.x + 2, pos.y + 1)

        local statusStr = string.format("%dc", s.chips or 0)
        if s.folded then statusStr = "FOLD"
        elseif s.allIn then statusStr = "ALL-IN"
        elseif s.currentBet and s.currentBet > 0 then statusStr = string.format("B:%d", s.currentBet) end
        color(s.isTurn and C.feltDark or C.cream)
        Font.draw(statusStr, pos.x + 2, pos.y + 9)
      end
    end
  end

  -- Community Board Cards (Flop, Turn, River)
  drawCommunityCards(CardView, st.communityCards)

  -- Player's Private Hole Cards (Bottom Center)
  local myCards = st.myCards or {}
  if #myCards >= 2 then
    View.drawCard(myCards[1], 54, 80, false, true)
    View.drawCard(myCards[2], 82, 80, false, true)
  else
    drawCardTraySlot(54, 80, "HOLE", true)
    drawCardTraySlot(82, 80, "HOLE", true)
  end

  -- Hand Strength Banner
  if st.myHandName and #st.myHandName > 0 then
    color(C.woodDark, 0.95); rect("fill", 14, 114, 132, 11)
    color(C.brass); rect("line", 14, 114, 132, 11)
    color(C.goldBright); centered(Font, "★ " .. st.myHandName .. " ★", 115)
  end

  -- Action Banner or Winner Announcement
  if st.state == "showdown" or st.state == "payout" then
    color(C.gold); rect("fill", 10, 126, 140, 16)
    color(C.ink); centered(Font, "SHOWDOWN! NEXT IN " .. tostring(st.timeRemaining or 3) .. "s", 129)
  elseif st.myTurn then
    local actions = st.allowedActions or { "check", "fold" }
    local gap = 2
    local btnWidth = math.floor((126 - gap * (#actions - 1)) / math.max(1, #actions))

    for i, act in ipairs(actions) do
      local label = act:upper()
      if act == "call" and st.callAmount then label = "CALL " .. st.callAmount
      elseif act == "raise" and raiseAmount then label = "RAISE " .. raiseAmount
      elseif act == "bet" and raiseAmount then label = "BET " .. raiseAmount end

      drawActionButton(Font, 6 + (i - 1) * (btnWidth + gap), 127, btnWidth, label, actionIndex == i, true)
    end
    -- Turn Timer Badge
    color(C.red); rect("fill", 134, 127, 20, 13)
    color(C.cream); Font.draw(string.format("%ds", st.timeRemaining or 15), 136, 129)
  else
    color(C.feltDark, 0.85); rect("fill", 12, 127, 136, 14)
    color(C.brassDark); rect("line", 12, 127, 136, 14)
    color(C.paper); centered(Font, "WAITING FOR OPPONENTS... (B LEAVE)", 129)
  end

  if notice then
    color(C.red); centered(Font, notice, 112)
  end

  love.graphics.setColor(1, 1, 1, 1)
end

-- =========================================================================
-- 4. SOLO PRACTICE TABLE VIEW
-- =========================================================================
function View.draw(state, Font, Rules, CardView, coinCount, stakes)
  drawCasinoTable()

  -- Table Header
  color(C.woodDark); rect("fill", 8, 6, 144, 14)
  color(C.brass); rect("line", 8, 6, 144, 14)
  color(C.cream); Font.draw("SOLO TEXAS HOLD'EM", 12, 9)
  local coinStr = string.format("COINS: %d", coinCount or 0)
  color(C.goldBright); Font.draw(coinStr, 148 - Font.width(coinStr), 9)

  if state.phase == "bet" then
    local stake = stakes[state.betIndex]
    color(C.goldBright); centered(Font, "CHOOSE STARTING WAGER", 28)
    local xs = { 24, 61, 99, 136 }
    for i, s in ipairs(stakes) do
      drawCasinoChip(xs[i], 58, s, i == state.betIndex)
      local lbl = tostring(s)
      color(i == state.betIndex and C.goldBright or C.paper)
      Font.draw(lbl, xs[i] - math.floor(Font.width(lbl) / 2), 72)
    end
    drawActionButton(Font, 16, 104, 88, "DEAL " .. stake, true, coinCount >= stake)
    drawActionButton(Font, 108, 104, 36, "EXIT", false, true)
    love.graphics.setColor(1, 1, 1, 1)
    return
  end

  local round = state.round
  local done = (round.state == "done")

  -- Dealer Hand
  color(C.paper); Font.draw("DEALER", 14, 23)
  if round.dealer and #round.dealer >= 2 then
    View.drawCard(round.dealer[1], 54, 16, not done, false)
    View.drawCard(round.dealer[2], 82, 16, not done, false)
  end

  -- Community Cards
  drawCommunityCards(CardView, round.board)

  -- Player Hand
  color(C.paper); Font.draw("PLAYER", 14, 86)
  if round.player and #round.player >= 2 then
    View.drawCard(round.player[1], 54, 78, false, true)
    View.drawCard(round.player[2], 82, 78, false, true)
  end

  if state.phase == "result" then
    local stake = Rules.totalStake(round)
    local delta = round.payout - stake
    local deltaText = delta > 0 and ("+" .. delta) or tostring(delta)
    local resText = (round.result == "win" and "YOU WIN!") or (round.result == "push" and "PUSH") or "HOUSE WINS"

    color(C.gold); rect("fill", 12, 114, 136, 24)
    color(C.ink); centered(Font, resText .. "  " .. deltaText .. " COINS", 116)
    local detail = round.playerEval and round.playerEval.name or "NO SHOWDOWN"
    centered(Font, detail, 126)
  else
    local info = string.format("WAGER: %d | POT: %d", round.start, round.start + round.play)
    color(C.goldBright); centered(Font, info, 116)
    local actions = state.actions or {}
    local gap = 3
    local width = math.floor((150 - gap * (#actions - 1)) / math.max(1, #actions))
    for i, action in ipairs(actions) do
      drawActionButton(Font, 5 + (i - 1) * (width + gap), 126, width, action.label,
        state.actionIndex == i, action.enabled ~= false)
    end
  end

  love.graphics.setColor(1, 1, 1, 1)
end

return View
