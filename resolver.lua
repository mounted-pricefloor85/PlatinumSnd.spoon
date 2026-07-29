-- PURE. No hs dependency: the caller supplies `exists`.
local resolver = {}

function resolver.candidates(root, base)
  return {
    root .. "/wav/" .. base .. "_mp3-to.wav",
    root .. "/mp3/" .. base .. ".mp3",
  }
end

function resolver.resolve(root, base, exists)
  for _, path in ipairs(resolver.candidates(root, base)) do
    if exists(path) then return path end
  end
  return nil
end

function resolver.buildMap(root, semanticToBase, exists)
  local map, missing = {}, {}
  for semantic, base in pairs(semanticToBase) do
    local path = resolver.resolve(root, base, exists)
    if path then
      map[semantic] = path
    else
      table.insert(missing, semantic)
    end
  end
  table.sort(missing)
  return map, missing
end

return resolver
