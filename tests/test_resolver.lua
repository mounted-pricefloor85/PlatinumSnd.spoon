package.path = "../?.lua;" .. package.path
local runner = require("runner")
local resolver = require("resolver")
local t = runner.suite("resolver")

local ROOT = "/snd"

-- Fake filesystem: only the listed paths exist.
local function fakeExists(present)
  local set = {}
  for _, p in ipairs(present) do set[p] = true end
  return function(path) return set[path] == true end
end

t.test("prefers WAV, using the _mp3-to suffix", function()
  local exists = fakeExists({
    "/snd/wav/btnp_mp3-to.wav",
    "/snd/mp3/btnp.mp3",
  })
  runner.eq(resolver.resolve(ROOT, "btnp", exists),
    "/snd/wav/btnp_mp3-to.wav")
end)

t.test("falls back to MP3 when the WAV is absent (bevp)", function()
  local exists = fakeExists({"/snd/mp3/bevp.mp3"})
  runner.eq(resolver.resolve(ROOT, "bevp", exists), "/snd/mp3/bevp.mp3")
end)

t.test("returns nil when neither format is present", function()
  local exists = fakeExists({})
  runner.isNil(resolver.resolve(ROOT, "nope", exists))
end)

t.test("handles base names containing spaces", function()
  local exists = fakeExists({"/snd/wav/wmov idle_mp3-to.wav"})
  runner.eq(resolver.resolve(ROOT, "wmov idle", exists),
    "/snd/wav/wmov idle_mp3-to.wav")
end)

t.test("buildMap reports unresolvable names instead of erroring", function()
  local exists = fakeExists({"/snd/wav/btnp_mp3-to.wav"})
  local map, missing = resolver.buildMap(ROOT,
    {["button.press"] = "btnp", ["ghost.thing"] = "zzzz"}, exists)
  runner.eq(map["button.press"], "/snd/wav/btnp_mp3-to.wav")
  runner.isNil(map["ghost.thing"])
  runner.eq(#missing, 1)
  runner.eq(missing[1], "ghost.thing")
end)

return t
