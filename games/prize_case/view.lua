return function(UI)
  local View, C = {}, UI.colors
  local theme = { base = C.goldLight, header = C.redLight, action = C.gold }
  local tiers = { common = C.blue, rare = C.purple, epic = C.red,
    pokemon = C.green, gold = C.gold }

  local function shortReward(reward)
    local labels = {
      RARE_CANDY = { "RARE", "CANDY" }, PP_UP = { "PP", "UP" },
      MAX_REVIVE = { "MAX", "REV" }, TM_DRAGON_RAGE = { "TM", "DRGN" },
      TM_SUBSTITUTE = { "TM", "SUB" }, TM_HYPER_BEAM = { "TM", "HYPR" },
      MASTER_BALL = { "MSTR", "BALL" },
    }
    if labels[reward.id] then return labels[reward.id][1], labels[reward.id][2] end
    local label = (reward.label or "PRIZE"):gsub(" ", "")
    return label:sub(1, 4), label:sub(5, 8)
  end

  local function rewardIcon(reward, x, y)
    if reward.id == "MASTER_BALL" then
      UI.color(C.gold); love.graphics.circle("fill", x, y, 8)
      UI.color(C.ink); UI.rect("fill", x - 8, y - 2, 16, 4)
      love.graphics.circle("fill", x, y, 3)
      UI.color(C.goldLight); love.graphics.circle("fill", x, y, 1)
      return
    end
    UI.color(tiers[reward.tier] or C.blue)
    if reward.kind == "pokemon" then
      love.graphics.circle("fill", x, y, 7)
      UI.color(C.paper); UI.rect("fill", x - 7, y - 1, 14, 2)
      UI.color(C.outline); love.graphics.circle("fill", x, y, 2)
    elseif reward.id and reward.id:sub(1, 3) == "TM_" then
      love.graphics.circle("fill", x, y, 7)
      UI.color(C.paper); love.graphics.circle("fill", x, y, 3)
      UI.color(C.outline); UI.rect("fill", x - 1, y - 1, 2, 2)
    else
      UI.rect("fill", x - 2, y - 8, 4, 2); UI.rect("fill", x - 5, y - 6, 10, 2)
      UI.rect("fill", x - 8, y - 4, 16, 8); UI.rect("fill", x - 5, y + 4, 10, 2)
      UI.rect("fill", x - 2, y + 6, 4, 2)
      UI.color(C.paper); UI.rect("fill", x - 2, y - 2, 4, 4)
    end
  end

  local function rewardCard(reward, x, y, Font, winner)
    local tier = tiers[reward.tier] or C.blue
    local master = reward.id == "MASTER_BALL"
    UI.color(master and C.ink or (winner and C.gold or C.outline))
    UI.rect("fill", x, y, 40, 54)
    UI.color(master and C.goldLight or C.paper)
    UI.rect("fill", x + 2, y + 2, 36, 50)
    UI.color(master and C.ink or tier); UI.rect("fill", x + 3, y + 3, 34, 5)
    rewardIcon(reward, x + 20, y + 20)
    local first, second = shortReward(reward)
    UI.color(C.ink)
    Font.draw(first, x + math.floor((40 - Font.width(first)) / 2), y + 31)
    if second ~= "" then
      Font.draw(second, x + math.floor((40 - Font.width(second)) / 2), y + 42)
    end
  end

  local function caseGraphic()
    UI.color(C.outline); UI.rect("fill", 48, 30, 64, 46)
    UI.color(C.gold); UI.rect("fill", 51, 33, 58, 40)
    UI.color(C.red); UI.rect("fill", 55, 35, 50, 33)
    UI.color(C.redLight); UI.rect("fill", 58, 38, 44, 5)
    UI.color(C.paper); UI.rect("fill", 75, 47, 10, 12)
    UI.color(C.outline); UI.rect("fill", 78, 50, 4, 6)
  end

  function View.draw(state, Font, coinCount)
    UI.frame("PRIZE CASE", Font, coinCount, theme)
    if state.phase == "ready" then
      caseGraphic()
      UI.color(C.ink); UI.centered(Font, "500 COINS", 82)
      UI.button(Font, "A OPEN CASE", 96, coinCount >= 500, theme)
      UI.color(C.ink); UI.centered(Font, state.notice or "RARE PRIZES INSIDE", 120)
      UI.centered(Font, "B EXIT", 130)
    else
      UI.panel(8, 30, 144, 67, C.cream)
      love.graphics.setScissor(10, 32, 140, 63)
      for index, reward in ipairs(state.strip or {}) do
        local x = 58 + (index - 1) * 44 - (state.reelOffset or 0)
        if x > -42 and x < 160 then
          rewardCard(reward, x, 36, Font,
            state.phase == "result" and index == state.winnerIndex)
        end
      end
      love.graphics.setScissor()
      UI.color(C.outline)
      UI.rect("fill", 76, 27, 8, 2); UI.rect("fill", 77, 29, 6, 2)
      UI.rect("fill", 78, 31, 4, 2); UI.rect("fill", 79, 33, 2, 1)
      UI.rect("fill", 79, 93, 2, 1); UI.rect("fill", 78, 94, 4, 2)
      UI.rect("fill", 77, 96, 6, 2); UI.rect("fill", 76, 98, 8, 2)
      UI.color(C.gold); UI.rect("fill", 79, 27, 2, 6); UI.rect("fill", 79, 94, 2, 6)
      if state.phase == "spinning" then
        UI.panel(47, 108, 66, 19, C.paper)
        UI.color(C.ink); UI.centered(Font, "OPENING", 114)
      else
        UI.panel(12, 101, 136, 37, state.refunded and C.redLight or C.paper)
        UI.color(C.ink)
        UI.centered(Font, state.refunded and "500 REFUNDED" or "YOU GOT", 105)
        UI.centered(Font, state.message or "PRIZE", 117)
        UI.centered(Font, "A AGAIN  B EXIT", 129)
      end
    end
    love.graphics.setColor(1, 1, 1, 1)
  end

  return View
end
