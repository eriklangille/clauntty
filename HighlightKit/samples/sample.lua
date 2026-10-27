-- A review's notes
local M = {}

local PRIORITIES = { "critical", "review", "skim" }

---@param path string
function M.rank(path, priority)
  for i, p in ipairs(PRIORITIES) do
    if p == priority then return i end
  end
  return #PRIORITIES + 1, string.format("%s: unknown", path)
end

return M
