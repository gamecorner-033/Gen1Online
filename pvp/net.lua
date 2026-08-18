-- PVP battle-message transport (non-blocking, via the mod's async HTTP engine).
-- Same shape as the overworld GtsNetAdapter (send/update/poll/close) so the
-- session/UI code does not care which transport is in use.

local PvpNet = {}
PvpNet.__index = PvpNet

-- opts: { send = function(payload, callback) ... , myId, theirId, roomId }
function PvpNet.new(opts)
  opts = opts or {}
  local s = {
    sendFn = opts.send,
    myId = tostring(opts.myId or ""),
    theirId = tostring(opts.theirId or ""),
    roomId = opts.roomId
      or ("ROOM_" .. tostring(opts.myId or "") .. "_" .. tostring(opts.theirId or "")),
    inbox = {},
    closed = false,
    pollTimer = 0,
    pollInterval = 0.25,
  }
  return setmetatable(s, PvpNet)
end

function PvpNet:send(msg)
  if self.closed then return end
  self.sendFn({
    action = "send_battle_msg",
    roomId = self.roomId,
    targetId = self.theirId,
    msg = msg,
  }, function() end)
end

function PvpNet:update()
  if self.closed then return end
  local now = (_G.love and _G.love.timer and _G.love.timer.getTime) and _G.love.timer.getTime() or os.time()
  if now - self.pollTimer < self.pollInterval then return end
  self.pollTimer = now
  self.sendFn({
    action = "poll_battle_msgs",
    roomId = self.roomId,
    myId = self.myId,
  }, function(res)
    if res and res.msgs then
      for _, m in ipairs(res.msgs) do
        table.insert(self.inbox, m)
      end
    end
  end)
end

function PvpNet:poll()
  local out = self.inbox
  self.inbox = {}
  return out
end

function PvpNet:hasPending()
  return #self.inbox > 0
end

function PvpNet:close()
  self.closed = true
end

return PvpNet
