return function(UI)
  local View, C = {}, UI.colors
  local theme = { base = C.goldLight, header = C.gold, action = C.greenLight }

  local function betChoices(state, Font, bets)
    local width, gap, start = 31, 3, 11
    for index, bet in ipairs(bets) do
      local x = start + (index - 1) * (width + gap)
      if index == state.betIndex then
        UI.color(C.outline); UI.rect("fill", x - 1, 62, width + 2, 21)
        UI.color(theme.action); UI.rect("fill", x + 1, 64, width - 2, 17)
      else
        UI.color(C.paper); UI.rect("fill", x, 64, width, 17)
        UI.color(C.outline); UI.rect("line", x, 64, width, 17)
      end
      UI.color(C.ink)
      local label = tostring(bet)
      Font.draw(label, x + math.floor((width - Font.width(label)) / 2), 69)
    end
  end

  local function preview()
    UI.panel(15, 29, 130, 20, C.greenLight)
    UI.color(C.outline)
    for x = 20, 134, 19 do UI.rect("fill", x, 44, 2, 1) end
    local points = { {21, 44}, {42, 43}, {63, 41}, {84, 39}, {105, 35}, {129, 31} }
    UI.color(C.green)
    for index = 2, #points do love.graphics.line(points[index - 1][1],
      points[index - 1][2], points[index][1], points[index][2]) end
    UI.color(C.gold); UI.rect("fill", 126, 29, 7, 4)
    UI.color(C.red); UI.rect("fill", 123, 30, 2, 2)
  end

  function View.draw(state, Font, coinCount, bets)
    UI.frame("CRASH", Font, coinCount, theme)
    if state.phase == "bet" then
      preview()
      UI.color(C.ink); UI.centered(Font, "CHOOSE WAGER", 52)
      betChoices(state, Font, bets)
      UI.button(Font, "A LAUNCH", 86, coinCount >= bets[state.betIndex], theme)
      UI.color(C.ink); UI.centered(Font, state.notice or "LEFT RIGHT SELECT", 112)
      UI.centered(Font, "B EXIT", 128)
    else
      UI.panel(10, 30, 140, 73, C.paper)
      UI.color(C.muted)
      for x = 15, 145, 16 do UI.rect("fill", x, 97, 1, 2) end
      for y = 38, 94, 14 do UI.rect("fill", 14, y, 2, 1) end
      local multiplier, lastX, lastY = state.multiplier or 1, 15, 96
      local maxShown = math.max(2, multiplier)
      UI.color(state.phase == "crashed" and C.red or C.green)
      for step = 1, 32 do
        local fraction = step / 32
        local value = 1 + (multiplier - 1) * fraction * fraction
        local x = 15 + fraction * 130
        local y = 96 - math.min(1, (value - 1) / (maxShown - 1)) * 56
        love.graphics.line(lastX, lastY, x, y); UI.rect("fill", x, y, 2, 2)
        lastX, lastY = x, y
      end
      if state.phase == "crashed" then
        UI.color(C.red); UI.rect("fill", lastX - 4, lastY, 10, 2)
        UI.rect("fill", lastX, lastY - 4, 2, 10)
        UI.color(C.gold); UI.rect("fill", lastX - 1, lastY - 1, 4, 4)
      else
        UI.color(C.gold); UI.rect("fill", lastX - 3, lastY - 3, 7, 4)
        UI.color(C.paper); UI.rect("fill", lastX + 2, lastY - 2, 3, 2)
        UI.color(C.red); UI.rect("fill", lastX - 5, lastY - 2, 2, 2)
      end
      UI.panel(57, 37, 46, 16, C.goldLight)
      UI.color(C.ink); UI.centered(Font, string.format("%.2fX", multiplier), 42)
      if state.phase == "running" then UI.button(Font, "A CASH OUT", 109, true, theme)
      else
        UI.centered(Font, state.phase == "cashed"
          and ("CASHED " .. tostring(state.payout)) or "CRASHED", 108)
        UI.centered(Font, "A AGAIN  B EXIT", 125)
      end
    end
    love.graphics.setColor(1, 1, 1, 1)
  end

  return View
end
