---@diagnostic disable

---@class UtilModule
---@field bytesToString fun(bytes: number[]): string
---@field stringToBytes fun(str: string): number[]
---@field formatBytes fun(bytes: number[]): string
---@field try fun<T>(try: fun(): T, catch: fun(err: any): any): T | nil
---@field packInt fun(int: number, length: number): number[]
---@field unpackInt fun(bytes: number[]): number
---@field ipToInt fun(ip: string): number
---@field intToIp fun(int: number): string
---@field toIp fun(v: string | number): number
---@field bitAnd fun(a: number, b: number): number

---@type UtilModule
local util = {}

---@param bytes number[]
---@return string
function util.bytesToString(bytes)
    return string.char(table.unpack(bytes))
end

---@param str string
---@return number[]
function util.stringToBytes(str)
    local bytes = {}
    for i = 1, #str do
        bytes[i] = string.byte(str, i)
    end
    return bytes
end

---@param bytes number[]
---@return string
function util.formatBytes(bytes)
    local str = ""
    for i = 1, #bytes do
        str = str .. string.format("%02X", bytes[i])
        if i < #bytes then
            str = str .. " "
        end
    end
    return str
end

---@generic T
---@param try fun(): T
---@param catch fun(err: any): any
---@return T | nil
function util.try(try, catch)
    local status, result = pcall(try)
    if not status then
        catch(result)
    end
    return result
end

---@param int number
---@param length number
---@return number[]
function util.packInt(int, length)
    local bytes = {}
    for i = 1, length do
        local shift = (length - i) * 8
        bytes[i] = math.floor(int / 2 ^ shift) % 256
    end
    return bytes
end

---@param bytes number[]
---@return number
function util.unpackInt(bytes)
    local int = 0
    for i = 1, #bytes do
        int = int + bytes[i] * 2 ^ ((#bytes - i) * 8)
    end
    return int
end

---@param ip string
---@return number
function util.ipToInt(ip)
    local bytes = {}
    for byte in string.gmatch(ip, "%d+") do
        bytes[#bytes + 1] = tonumber(byte)
    end
    return util.unpackInt(bytes)
end

---@param int number
---@return string
function util.intToIp(int)
    local bytes = util.packInt(int, 4)
    return table.concat(bytes, ".")
end

---@param v string|number
---@return number
function util.toIp(v)
    if type(v) == "number" then
        return v
    end
    return util.ipToInt(v)
end

---@param a number
---@param b number
---@return number
function util.bitAnd(a, b)
    local result = 0
    local bit = 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then
            result = result + bit
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit = bit * 2
    end
    return result
end

return util
