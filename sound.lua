local resolver = dofile(hs.spoons.resourcePath("resolver.lua"))
local soundmap = dofile(hs.spoons.resourcePath("soundmap.lua"))

local Sound = {}
Sound.__index = Sound

local function fileExists(path)
  return hs.fs.attributes(path, "mode") == "file"
end

function Sound.new(opts)
  local self = setmetatable({}, Sound)
  self.root = opts.root
  self.volume = opts.volume or 0.5
  self.poolSize = opts.poolSize or 3
  self.log = opts.log or hs.logger.new("PlatinumSnd", "info")
  self.pools = {}      -- semantic -> {objects, nextIndex}
  self.sustainers = {} -- semantic -> hs.sound
  self.paths = {}
  self.isDryRun = false
  return self
end

function Sound:load()
  -- Idempotent: start() may call this more than once. Silence and drop the
  -- previous objects first, otherwise a reload orphans looping sustainers
  -- that release() can no longer reach.
  for _, snd in pairs(self.sustainers) do
    if snd:isPlaying() then snd:stop() end
  end
  self.pools = {}
  self.sustainers = {}
  self.paths = {}
  local map, missing = resolver.buildMap(self.root, soundmap.bases, fileExists)
  self.paths = map
  for semantic, path in pairs(map) do
    if soundmap.sustained[semantic] then
      local snd = hs.sound.getByFile(path)
      if snd then
        snd:volume(self.volume)
        snd:loopSound(true)
        self.sustainers[semantic] = snd
      end
    else
      local objects = {}
      for _ = 1, self.poolSize do
        local snd = hs.sound.getByFile(path)
        if snd then
          snd:volume(self.volume)
          table.insert(objects, snd)
        end
      end
      if #objects > 0 then
        self.pools[semantic] = {objects = objects, nextIndex = 1}
      end
    end
  end
  if #missing > 0 then
    self.log.w("unresolved sounds: " .. table.concat(missing, ", "))
  end
  return self, missing
end

function Sound:dryRun(enabled)
  self.isDryRun = enabled and true or false
end

function Sound:play(semantic)
  if self.isDryRun then
    self.log.i(string.format("DRYRUN play %s (%s)", semantic,
      tostring(soundmap.bases[semantic])))
    return
  end
  local pool = self.pools[semantic]
  if not pool then return end
  local snd = pool.objects[pool.nextIndex]
  pool.nextIndex = (pool.nextIndex % #pool.objects) + 1
  snd:stop()
  snd:play()
end

function Sound:sustain(semantic)
  if self.isDryRun then
    self.log.i("DRYRUN sustain " .. semantic)
    return
  end
  local snd = self.sustainers[semantic]
  if snd and not snd:isPlaying() then snd:play() end
end

function Sound:release(semantic)
  local snd = self.sustainers[semantic]
  if snd and snd:isPlaying() then snd:stop() end
end

function Sound:audition()
  local names = {}
  for semantic in pairs(self.paths) do table.insert(names, semantic) end
  table.sort(names)
  local index = 1
  local function next_()
    if index > #names then
      print("audition complete")
      return
    end
    local semantic = names[index]
    print(string.format("%-22s %-14s %s", semantic,
      soundmap.bases[semantic], self.paths[semantic]))
    local snd = hs.sound.getByFile(self.paths[semantic])
    self.auditionSound = snd -- retain: a collected sound stops mid-playback
    if snd then snd:volume(self.volume); snd:play() end
    index = index + 1
    hs.timer.doAfter(1.2, next_)
  end
  next_()
end

return Sound
