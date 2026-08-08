return function(ctx)
  local mod, Rules, View = ctx.mod, ctx.rules, ctx.view
  local Screen = { isOpaque = true }
  Screen.__index = Screen

  function Screen.new(game, opts)
    return setmetatable({ game = game, onClose = opts and opts.onClose,
      phase = "ready" }, Screen)
  end

  function Screen:sgbPalettes()
    return { require("src.render.PaletteFX").trueColorZone(0, 0, 19, 17) }
  end

  function Screen:close()
    ctx.close(self.game, self)
    if self.onClose then self.onClose() end
  end

  function Screen:start()
    if ctx.coins(self.game) < Rules.COST then self.notice = "NEED 10 COINS"; return end
    self.game.save.coins = ctx.coins(self.game) - Rules.COST
    self.run = Rules.new(function(maximum) return love.math.random(1, maximum) end)
    self.run.earned = 0
    self.phase, self.notice = "playing", nil
    mod.save:set("flappy_rounds", mod.save:get("flappy_rounds", 0) + 1)
    ctx.play(self.game, "Slots_New_Spin")
  end

  function Screen:finish()
    if self.phase ~= "playing" then return end
    self.phase = "result"
    mod.save:set("flappy_best", math.max(mod.save:get("flappy_best", 0), self.run.score))
    ctx.play(self.game, "Slots_Stop_Wheel")
  end

  function Screen:update(dt)
    local input = self.game.input
    if self.phase == "ready" then
      if input:wasPressed("a") then self:start()
      elseif input:wasPressed("b") then self:close() end
      return
    end
    if self.phase == "playing" then
      if input:wasPressed("b") then self:finish(); return end
      if input:wasPressed("a") or input:wasPressed("up") then
        Rules.flap(self.run)
        ctx.play(self.game, "Press_AB")
      end
      local passed = Rules.update(self.run, dt or 1 / 60,
        function(maximum) return love.math.random(1, maximum) end)
      if passed > 0 then
        local paid = math.min(passed, ctx.coinCap - ctx.coins(self.game))
        self.game.save.coins = ctx.coins(self.game) + paid
        self.run.earned = self.run.earned + paid
        mod.save:set("flappy_coins", mod.save:get("flappy_coins", 0) + paid)
        ctx.play(self.game, "Slots_Reward")
      end
      if not self.run.alive then self:finish() end
    elseif input:wasPressed("a") then
      self.phase, self.notice = "ready", nil
      ctx.play(self.game, "Press_AB")
    elseif input:wasPressed("b") then self:close() end
  end

  function Screen:draw()
    View.draw(self, mod.ui.Font, ctx.coins(self.game))
  end

  return Screen
end
