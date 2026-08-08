-- Pixel-native house-banked & Online Multiplayer Texas Hold'em presentation for the 160x144 canvas.
local View = {}

local C = {
  ink = { 0.08, 0.07, 0.10 },
  felt = { 0.035, 0.20, 0.27 },
  feltDark = { 0.02, 0.10, 0.16 },
  feltLight = { 0.07, 0.33, 0.40 },
  gold = { 0.94, 0.67, 0.18 },
  goldDark = { 0.40, 0.22, 0.06 },
  cream = { 1.00, 0.94, 0.70 },
  paper = { 0.94, 0.88, 0.67 },
  red = { 0.66, 0.10, 0.17 },
  disabled = { 0.30, 0.39, 0.43 },
  blue = { 0.18, 0.52, 0.78 },
  green = { 0.18, 0.74, 0.28 },
}

local function color(value, alpha)
  love.graphics.setColor(value[1], value[2], value[3], alpha or 1)
end

local function rect(mode, x, y, w, h)
  love.graphics.rectangle(mode, math.floor(x), math.floor(y), w, h)
end

local function centered(Font, text, y)
  Font.draw(text, math.floor((160 - Font.width(text)) / 2), y)
end

local function centeredGlyph(CardView, text, y, shade, scale)
  scale = scale or 1
  CardView.glyph(text, math.floor((160 - CardView.glyphWidth(text, scale)) / 2), y, shade, scale)
end

local function tableSurface()
  color(C.goldDark); rect("fill", 0, 0, 160, 144)
  color(C.gold); rect("fill", 0, 2, 160, 3); rect("fill", 0, 139, 160, 3)
  color(C.feltDark); rect("fill", 3, 5, 154, 134)
  color(C.felt); rect("fill", 6, 7, 148, 129)
  color(C.feltLight, 0.35)
  for y = 9, 133, 8 do
    for x = 8 + (y % 16 == 9 and 0 or 4), 150, 8 do rect("fill", x, y, 1, 1) end
  end
  color(C.goldDark); rect("line", 8, 8, 144, 126)
end

local function chip(x, y, active)
  color(C.ink, 0.55); love.graphics.circle("fill", x + 1, y + 2, active and 12 or 10)
  color(active and C.gold or C.paper); love.graphics.circle("fill", x, y, active and 12 or 10)
  color(active and C.red or C.goldDark); love.graphics.circle("fill", x, y, active and 9 or 7)
  color(C.cream); love.graphics.circle("line", x, y, active and 7 or 5)
  for angle = 0, 7 do
    local radians = angle * math.pi / 4
    local radius = active and 10 or 8
    rect("fill", x + math.floor(math.cos(radians) * radius),
      y + math.floor(math.sin(radians) * radius), 2, 2)
  end
end

local function button(Font, x, y, width, label, selected, enabled)
  local fill = enabled and (selected and C.gold or C.paper) or C.disabled
  color(C.ink, 0.6); rect("fill", x + 1, y + 1, width, 15)
  color(fill); rect("fill", x, y, width, 14)
  color(selected and C.cream or C.goldDark); rect("line", x, y, width, 14)
  color(enabled and C.ink or C.feltDark)
  Font.draw(label, x + math.floor((width - Font.width(label)) / 2), y + 3)
end

local function cardSlot(x, y, visible)
  color(visible and C.gold or C.feltLight, visible and 0.8 or 0.45)
  rect("line", x + 1, y + 1, 18, 27)
  if not visible then
    rect("fill", x + 8, y + 12, 4, 5)
    color(C.felt); rect("fill", x + 9, y + 13, 2, 3)
  end
end

local function drawCards(CardView, cards, xs, y, hidden)
  for i, x in ipairs(xs) do
    local card = cards and cards[i]
    if card then CardView.drawCard(card, x, y, hidden, false) else cardSlot(x, y, false) end
  end
end

local function drawBetScreen(state, Font, CardView, stakes, coinCount)
  local stake = stakes[state.betIndex]
  centeredGlyph(CardView, "CHOOSE BET", 31, C.cream, 2)
  local xs = { 24, 61, 99, 136 }
  for i, stake in ipairs(stakes) do
    chip(xs[i], 64, i == state.betIndex)
    local label = tostring(stake)
    CardView.glyph(label,
      xs[i] - math.floor(CardView.glyphWidth(label, 2) / 2), 79,
      i == state.betIndex and C.gold or C.paper, 2)
  end
  if state.notice then
    centeredGlyph(CardView, state.notice, 99, C.cream, 2)
  end
  button(Font, 16, 112, 88, "DEAL " .. stake, true, coinCount >= stake)
  CardView.glyph("B EXIT", 118, 116, C.paper)
end

local function resultText(round)
  if round.result == "win" then return "YOU WIN" end
  if round.result == "push" then return "PUSH" end
  return "HOUSE WINS"
end

-- =========================================================================
-- MODE SELECTION (SOLO VS ONLINE MULTIPLAYER)
-- =========================================================================
function View.drawModeSelect(modeIndex, Font, CardView, coinCount)
  tableSurface()
  centeredGlyph(CardView, "TEXAS HOLD EM", 14, C.gold, 2)
  local coinLabel = "COINS " .. tostring(coinCount)
  CardView.glyph(coinLabel, 152 - CardView.glyphWidth(coinLabel), 32, C.cream)

  color(C.feltDark, 0.9); rect("fill", 14, 48, 132, 72)
  color(C.goldDark); rect("line", 14, 48, 132, 72)

  local modes = {
    { title = "1. SOLO PRACTICE", desc = "Fast house poker vs dealer" },
    { title = "2. ONLINE MULTIPLAYER", desc = "Live table with other trainers!" }
  }

  for i, m in ipairs(modes) do
    local isSel = (modeIndex == i)
    color(isSel and C.gold or C.paper)
    rect("fill", 20, 54 + (i - 1) * 32, 120, 26)
    color(isSel and C.cream or C.goldDark)
    rect("line", 20, 54 + (i - 1) * 32, 120, 26)

    color(C.ink)
    Font.draw(m.title, 26, 58 + (i - 1) * 32)
    Font.draw(m.desc, 26, 68 + (i - 1) * 32)
  end

  centeredGlyph(CardView, "A SELECT   B EXIT", 126, C.paper)
  love.graphics.setColor(1, 1, 1, 1)
end

-- =========================================================================
-- ONLINE TABLE SELECTION
-- =========================================================================
function View.drawTableSelect(tierIndex, tiers, Font, CardView, coinCount, notice)
  tableSurface()
  centeredGlyph(CardView, "ONLINE POKER TABLES", 10, C.gold, 2)
  local coinLabel = "COINS " .. tostring(coinCount)
  CardView.glyph(coinLabel, 152 - CardView.glyphWidth(coinLabel), 26, C.cream)

  local y = 38
  for i, t in ipairs(tiers) do
    local isSel = (tierIndex == i)
    color(isSel and C.gold or C.feltDark, isSel and 1 or 0.8)
    rect("fill", 12, y, 136, 20)
    color(isSel and C.cream or C.goldDark)
    rect("line", 12, y, 136, 20)

    color(isSel and C.ink or C.paper)
    Font.draw(t.label, 16, y + 3)
    Font.draw(string.format("BLIND: %dc | BUYIN: %dc", t.minBet, t.buyIn), 16, y + 11)
    y = y + 22
  end

  if notice then
    centeredGlyph(CardView, notice, 116, C.cream)
  end

  centeredGlyph(CardView, "A JOIN TABLE   B BACK", 128, C.paper)
  love.graphics.setColor(1, 1, 1, 1)
end

-- =========================================================================
-- LIVE ONLINE MULTIPLAYER TABLE RENDERING
-- =========================================================================
function View.drawOnlineTable(st, actionIndex, raiseAmount, Font, CardView, coinCount, notice)
  tableSurface()

  if not st then
    centeredGlyph(CardView, "CONNECTING TO TABLE...", 64, C.cream, 2)
    love.graphics.setColor(1, 1, 1, 1)
    return
  end

  -- 1. Table Name & Pot Header
  local tName = (st.tableName or "POKER TABLE"):sub(1, 16)
  CardView.glyph(tName, 8, 8, C.cream)
  local potStr = string.format("POT: %d", st.pot or 0)
  CardView.glyph(potStr, 152 - CardView.glyphWidth(potStr), 8, C.gold)

  -- 2. Opponents Seated Around the Table (Seats 0 to 5)
  local seats = st.seats or {}
  local seatPositions = {
    { x = 10, y = 20 },
    { x = 58, y = 18 },
    { x = 106, y = 20 },
    { x = 10, y = 62 },
    { x = 106, y = 62 },
  }

  local oppIdx = 1
  for _, s in ipairs(seats) do
    if not s.cards or #s.cards == 0 then
      -- Opponent seat
      if oppIdx <= #seatPositions then
        local pos = seatPositions[oppIdx]
        oppIdx = oppIdx + 1

        color(s.isTurn and C.gold or C.feltDark, 0.85)
        rect("fill", pos.x, pos.y, 44, 22)
        color(s.isTurn and C.cream or C.goldDark)
        rect("line", pos.x, pos.y, 44, 22)

        color(s.isTurn and C.ink or C.paper)
        local sName = (s.name or "TR"):sub(1, 6)
        if s.isDealer then sName = "[D] " .. sName end
        Font.draw(sName, pos.x + 2, pos.y + 2)

        local statusStr = string.format("%dc", s.chips or 0)
        if s.folded then statusStr = "FOLD"
        elseif s.allIn then statusStr = "ALL-IN"
        elseif s.currentBet and s.currentBet > 0 then statusStr = string.format("B:%d", s.currentBet) end
        Font.draw(statusStr, pos.x + 2, pos.y + 11)
      end
    end
  end

  -- 3. Community Board Cards (Center of Table)
  local board = st.communityCards or {}
  drawCards(CardView, board, { 24, 47, 70, 93, 116 }, 44, false)

  -- 4. Player's Private Hole Cards & Hand Strength (Bottom Center)
  local myCards = st.myCards or {}
  drawCards(CardView, myCards, { 58, 82 }, 76, false)

  if st.myHandName and #st.myHandName > 0 then
    color(C.feltDark, 0.9); rect("fill", 18, 106, 124, 12)
    color(C.goldDark); rect("line", 18, 106, 124, 12)
    color(C.gold); centered(Font, st.myHandName, 108)
  end

  -- 5. Last Action / Winner Announcement Banner
  if st.lastActionText and #st.lastActionText > 0 then
    color(C.ink, 0.8); rect("fill", 10, 2, 140, 10)
    color(C.cream); centered(Font, st.lastActionText, 3)
  end

  -- 6. Action Buttons Bar at Bottom
  if st.state == "showdown" or st.state == "payout" then
    color(C.gold); rect("fill", 14, 119, 132, 20)
    color(C.ink); centered(Font, "SHOWDOWN! NEXT HAND IN " .. tostring(st.timeRemaining or 3) .. "s", 124)
  elseif st.myTurn then
    local actions = st.allowedActions or { "check", "fold" }
    local gap = 2
    local btnWidth = math.floor((154 - gap * (#actions - 1)) / math.max(1, #actions))

    for i, act in ipairs(actions) do
      local label = act:upper()
      if act == "call" and st.callAmount then label = "CALL " .. st.callAmount
      elseif act == "raise" and raiseAmount then label = "RAISE " .. raiseAmount
      elseif act == "bet" and raiseAmount then label = "BET " .. raiseAmount end

      button(Font, 3 + (i - 1) * (btnWidth + gap), 120, btnWidth, label, actionIndex == i, true)
    end
    -- Turn Timer Badge
    color(C.red); rect("fill", 136, 108, 20, 10)
    color(C.cream); Font.draw(string.format("%ds", st.timeRemaining or 15), 138, 109)
  else
    color(C.feltDark, 0.85); rect("fill", 14, 122, 132, 16)
    color(C.goldDark); rect("line", 14, 122, 132, 16)
    local waitMsg = string.format("WAITING FOR OPPONENTS... (B LEAVE)")
    color(C.paper); centered(Font, waitMsg, 126)
  end

  if notice then
    centeredGlyph(CardView, notice, 112, C.cream)
  end

  love.graphics.setColor(1, 1, 1, 1)
end

-- =========================================================================
-- SOLO PRACTICE TABLE RENDERING (Original House Game)
-- =========================================================================
function View.draw(state, Font, Rules, CardView, coinCount, stakes)
  tableSurface()
  CardView.glyph("SOLO HOLD EM", 8, 8, C.cream, 2)
  local coinLabel = "COINS " .. tostring(coinCount)
  CardView.glyph(coinLabel, 152 - CardView.glyphWidth(coinLabel), 10, C.gold)

  if state.phase == "bet" then
    drawBetScreen(state, Font, CardView, stakes, coinCount)
    love.graphics.setColor(1, 1, 1, 1)
    return
  end

  local round = state.round
  local done = round.state == "done"
  CardView.glyph("HOUSE", 8, 27, C.paper)
  drawCards(CardView, round.dealer, { 54, 78 }, 17, not done)

  drawCards(CardView, round.board, { 24, 47, 70, 93, 116 }, 47, false)
  CardView.glyph("YOU", 8, 91, C.paper)
  drawCards(CardView, round.player, { 54, 78 }, 78, false)

  if state.phase == "result" then
    local stake = Rules.totalStake(round)
    local delta = round.payout - stake
    local deltaText = delta > 0 and ("+" .. delta) or tostring(delta)
    color(C.gold); rect("fill", 12, 110, 136, 22)
    color(C.ink); centered(Font, resultText(round) .. "  " .. deltaText, 113)
    local detail = round.playerEval and round.playerEval.name or "NO SHOWDOWN"
    centered(Font, detail, 122)
    centeredGlyph(CardView, "A AGAIN   B EXIT", 134, C.paper)
  else
    local info = ("START %d  BETS %d"):format(round.start, round.play)
    centeredGlyph(CardView, info, 108, C.paper)
    local actions = state.actions or {}
    local gap = 3
    local width = math.floor((154 - gap * (#actions - 1)) / math.max(1, #actions))
    for i, action in ipairs(actions) do
      button(Font, 3 + (i - 1) * (width + gap), 119, width, action.label,
        state.actionIndex == i, action.enabled ~= false)
    end
    if state.notice then
      centeredGlyph(CardView, state.notice, 134, C.cream)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return View
