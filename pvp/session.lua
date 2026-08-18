-- PVP lockstep session: coordinates the per-turn action exchange over the
-- async battle transport. Both sides submit their chosen action, wait until
-- BOTH are known, then resolve the turn deterministically (see engine.lua).

local PvpSession = {}
PvpSession.__index = PvpSession

-- opts: { net (PvpNet), role ("host"/"guest"), onResolve(myAction, theirAction) }
function PvpSession.new(opts)
  opts = opts or {}
  local s = {
    net = opts.net,
    role = opts.role,
    onResolve = opts.onResolve,
    myAction = nil,
    theirAction = nil,
    waiting = false,
    turn = 0,
    finished = false,
  }
  return setmetatable(s, PvpSession)
end

-- Called every frame: poll the transport, then resolve if both actions are in.
function PvpSession:update()
  if self.finished then return end
  if self.net then
    self.net:update()
    local msgs = self.net:poll()
    for _, m in ipairs(msgs or {}) do
      self:handleMessage(m)
    end
  end
  if self.waiting and self.theirAction ~= nil then
    self:resolve()
  end
end

function PvpSession:handleMessage(m)
  if not m then return end
  if m.type == "pvp_action" then
    self.theirAction = m.action
    self.turn = math.max(self.turn, tonumber(m.turn) or 0)
  elseif m.type == "pvp_end" then
    self.finished = true
  end
end

-- I chose an action: send it and wait for the opponent's.
function PvpSession:submitMyAction(action)
  if self.finished or self.waiting then return end
  self.myAction = action
  self.waiting = true
  self.turn = self.turn + 1
  if self.net then
    self.net:send({ type = "pvp_action", turn = self.turn, action = action })
  end
  -- Opponent's action may already be in hand (they chose first).
  if self.theirAction ~= nil then
    self:resolve()
  end
end

-- Both actions known: hand them to the flow, then clear for the next turn.
function PvpSession:resolve()
  self.waiting = false
  local my, theirs = self.myAction, self.theirAction
  self.myAction = nil
  -- Keep theirAction set until onResolve returns so the battle engine can
  -- read it during takeTurn; clear it after.
  if self.onResolve then
    self.onResolve(my, theirs)
  end
  self.theirAction = nil
end

function PvpSession:send(msg)
  if self.net then self.net:send(msg) end
end

function PvpSession:close()
  self.finished = true
  if self.net then self.net:close() end
end

return PvpSession
