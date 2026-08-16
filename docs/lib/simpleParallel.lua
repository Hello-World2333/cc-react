---@diagnostic disable
---@class SimpleParallelModule
---@field add fun(v: fun(): any): number
---@field remove fun(k: number): void
---@field start fun(): void
---@type SimpleParallelModule
local parallels = {}

local simpleParallel = {}

---@param v fun(): any
---@return number
function simpleParallel.add(v)
    parallels[#parallels + 1] = v
    return #parallels
end

---@param k number
function simpleParallel.remove(k)
    if type(k) == "number" and parallels[k] ~= nil then
        table.remove(parallels, k)
    end
end

---@return void
function simpleParallel.start()
    parallel.waitForAll(table.unpack(parallels))
end

return simpleParallel
