-- Minimal zero-dependency test harness.
-- Interpreter used for this project: lua5.4 (Lua 5.4.8, /usr/bin/lua5.4)
local runner = {suites = {}}

function runner.suite(name)
  local t = {name = name, cases = {}}
  function t.test(desc, fn)
    table.insert(t.cases, {desc = desc, fn = fn})
  end
  table.insert(runner.suites, t)
  return t
end

local function fail(msg, extra)
  error(string.format("%s\n    %s", msg or "assertion failed", extra or ""), 2)
end

function runner.eq(actual, expected, msg)
  if actual ~= expected then
    fail(msg, string.format("expected %s, got %s",
      tostring(expected), tostring(actual)))
  end
end

function runner.isNil(actual, msg)
  if actual ~= nil then
    fail(msg, string.format("expected nil, got %s", tostring(actual)))
  end
end

function runner.isTrue(actual, msg)
  if actual ~= true then
    fail(msg, string.format("expected true, got %s", tostring(actual)))
  end
end

function runner.run()
  local passed, failed = 0, 0
  for _, suite in ipairs(runner.suites) do
    print("== " .. suite.name)
    for _, case in ipairs(suite.cases) do
      local ok, err = pcall(case.fn)
      if ok then
        passed = passed + 1
        print("  ok   " .. case.desc)
      else
        failed = failed + 1
        print("  FAIL " .. case.desc)
        print("       " .. tostring(err))
      end
    end
  end
  print(string.format("\n%d passed, %d failed", passed, failed))
  return failed
end

return runner

-- Every suite, from this directory:
--   lua5.4 -e 'require("test_resolver"); require("test_soundmap");
--     require("test_axpolicy"); require("test_rolemap"); require("test_fgate");
--     require("test_menugate"); os.exit(require("runner").run())'
--
-- Fallback when no lua CLI is available. In the Hammerspoon console:
--   package.path = hs.configdir ..
--     "/Spoons/PlatinumSnd.spoon/?.lua;" .. hs.configdir ..
--     "/Spoons/PlatinumSnd.spoon/tests/?.lua;" .. package.path
--   require("test_resolver"); require("runner").run()
