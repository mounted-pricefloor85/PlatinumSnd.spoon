local axprobe = dofile(hs.spoons.resourcePath("axprobe.lua"))
local rolemap = dofile(hs.spoons.resourcePath("rolemap.lua"))

local src = {}

function src:start(ctx)
  self.engine = ctx.engine
  self.tuning = ctx.tuning
  self.log = ctx.log
  self.probe = axprobe.new(ctx.tuning, ctx.log)
  self.cache = nil

  local types = hs.eventtap.event.types
  self.tap = hs.eventtap.new(
    {types.leftMouseDown, types.leftMouseUp},
    function(event)
      local action = (event:getType() == types.leftMouseDown)
        and "press" or "release"
      local point = event:location()
      -- Return immediately; all AX work happens on a later tick so a hung
      -- app can delay a sound but never the user's click.
      hs.timer.doAfter(0, function()
        local role = self.probe:roleAt(point.x, point.y)
        local semantic = rolemap.semantic(role, action)
        if semantic then self.engine:play(semantic) end
      end)
      return false
    end)
  self.tap:start()
end

function src:stop()
  if self.tap then self.tap:stop(); self.tap = nil end
  self.cache = nil
end

return src
