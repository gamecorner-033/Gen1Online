return function(UI)
  local View, C = {}, UI.colors
  local theme = { base = C.blueLight, header = C.greenLight, action = C.goldLight }

  local function drawTube(tube, offsetY)
    local x, top, bottom = math.floor(tube.x), 26, 132
    local gapTop = math.floor(tube.gapY - 19 + offsetY)
    local gapBottom = math.floor(tube.gapY + 19 + offsetY)
    local function body(y, height)
      if height <= 0 then return end
      UI.color(C.outline); UI.rect("fill", x - 2, y, 22, height)
      UI.color(C.green); UI.rect("fill", x, y, 18, height)
      UI.color(C.greenLight); UI.rect("fill", x + 2, y, 4, height)
    end
    body(top, gapTop - top - 4); body(gapBottom + 4, bottom - gapBottom - 4)
    UI.color(C.outline); UI.rect("fill", x - 5, gapTop - 5, 28, 7)
    UI.rect("fill", x - 5, gapBottom - 2, 28, 7)
    UI.color(C.green); UI.rect("fill", x - 3, gapTop - 3, 24, 4)
    UI.rect("fill", x - 3, gapBottom, 24, 4)
    UI.color(C.greenLight); UI.rect("fill", x, gapTop - 3, 4, 4)
    UI.rect("fill", x, gapBottom, 4, 4)
  end

  local function drawBird(state, offsetY)
    local y = math.floor(state.y + offsetY)
    UI.color(C.outline); UI.rect("fill", 30, y - 1, 11, 9)
    UI.color(C.gold); UI.rect("fill", 32, y, 7, 7)
    UI.color(C.paper); UI.rect("fill", 36, y + 1, 2, 2)
    UI.color(C.red); UI.rect("fill", 39, y + 4, 4, 2)
    UI.color(C.cream)
    UI.rect("fill", 28, y + (state.velocity < 0 and 1 or 5), 5, 2)
  end

  local function scene(state)
    UI.color(C.blue); UI.rect("fill", 8, 26, 144, 106)
    UI.color(C.blueLight)
    for x = 15, 145, 29 do UI.rect("fill", x, 36 + (x % 17), 12, 3) end
    for _, tube in ipairs(state.tubes) do drawTube(tube, 8) end
    drawBird(state, 8)
    UI.color(C.outline); UI.rect("fill", 8, 132, 144, 4)
    UI.color(C.greenLight); UI.rect("fill", 8, 132, 144, 2)
  end

  local function preview()
    UI.panel(17, 31, 126, 47, C.blue)
    local demo = { y = 44, velocity = -1,
      tubes = { { x = 27, gapY = 53 }, { x = 112, gapY = 61 } } }
    love.graphics.setScissor(19, 33, 122, 43)
    for _, tube in ipairs(demo.tubes) do drawTube(tube, 0) end
    drawBird(demo, 0)
    love.graphics.setScissor()
  end

  function View.draw(state, Font, coinCount)
    if state.phase == "ready" then
      UI.frame("TUBE FLYER", Font, coinCount, theme)
      preview()
      UI.color(C.ink); UI.centered(Font, "10 COINS TO FLY", 83)
      UI.button(Font, "A START", 96, coinCount >= 10, theme)
      UI.color(C.ink); UI.centered(Font, state.notice or "TUBE +1 COIN", 120)
      UI.centered(Font, "B EXIT", 130)
    else
      UI.frame("TUBE", Font, coinCount, theme)
      scene(state.run)
      UI.color(C.ink)
      local score = "S " .. tostring(state.run.score)
      Font.draw(score, 79 - math.floor(Font.width(score) / 2), 11)
      if state.phase == "result" then
        UI.panel(14, 101, 132, 37, C.paper)
        UI.color(C.ink)
        UI.centered(Font, "FLIGHT OVER  S " .. state.run.score, 106)
        UI.centered(Font, "+" .. (state.run.earned or state.run.score) .. " COINS", 118)
        UI.centered(Font, "A AGAIN  B EXIT", 130)
      end
    end
    love.graphics.setColor(1, 1, 1, 1)
  end

  return View
end
