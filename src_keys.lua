local src = {}

-- The keys that activate a default button. `dbtr` is
-- kThemeSoundDefaultButtonRelease, and nobody on a modern Mac clicks the
-- default button of a dialog -- they hit Return, which is the same act. The
-- pointer already owns the click, through the ordinary button sounds.
--
-- Built in a loop rather than written as a table literal: an unrecognised
-- key name would put a nil key in a constructor and take the whole Spoon
-- down at load, where here it is simply an entry that never arrives.
local ACTIVATORS = {}
for _, name in ipairs({"return", "padenter"}) do
  local code = hs.keycodes.map[name]
  if code then ACTIVATORS[code] = true end
end

-- The window subroles that actually have a default button. Return in a
-- document window inserts a newline, and a button release on every one of
-- those would make the Spoon unusable in a text editor -- which is the whole
-- reason this source is gated rather than sounding on every Return.
local DIALOGS = {AXDialog = true, AXSystemDialog = true, AXSheet = true}

-- One accessibility call: hs.window publishes the subrole itself, so going
-- through hs.axuielement would be the same round trip with a wrapper on it.
-- Guarded, because a window can die between the keystroke and this call, and
-- an unreadable subrole reads as "not a dialog" -- silence is the safe
-- answer for a sound this frequent.
local function focusedIsDialog()
  local win = hs.window.focusedWindow()
  if not win then return false end
  local ok, subrole = pcall(function() return win:subrole() end)
  return ok and DIALOGS[subrole] == true
end

function src:start(ctx)
  self.engine = ctx.engine
  self.tuning = ctx.tuning
  self.log = ctx.log

  -- Until when a Return may be answered without asking anything.
  --
  -- Set only by a check that came back "not a dialog", so a typist holding
  -- Return down asks once and then coasts for the rest of the burst instead
  -- of querying per keystroke. A check that came back "dialog" never
  -- suppresses the next one: dialogs are rare, and the commonest thing a
  -- default button does is dismiss the dialog it belongs to.
  self.quietUntil = 0

  local types = hs.eventtap.event.types
  self.tap = hs.eventtap.new({types.keyDown}, function(event)
    if not ACTIVATORS[event:getKeyCode()] then return false end
    if hs.timer.secondsSinceEpoch() < self.quietUntil then return false end
    -- Return immediately; the subrole read happens on a later tick, so a
    -- hung app can delay a sound but never the user's keystroke.
    hs.timer.doAfter(0, function()
      if not self.tap then return end
      if focusedIsDialog() then
        self.engine:play("defaultbutton.release")
      else
        self.quietUntil = hs.timer.secondsSinceEpoch()
          + self.tuning.defaultButtonRecheckSeconds
      end
    end)
    return false
  end)
  self.tap:start()
end

function src:stop()
  if self.tap then self.tap:stop(); self.tap = nil end
  self.quietUntil = 0
end

return src
