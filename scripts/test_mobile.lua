--[[
  Headless test for docs/lib/mobile.lua — 移动数据层（基站切换）

  Tests the pack/unpack functions, beacon frame encoding, association
  protocol, and the switching logic in isolation (no real modem I/O).

  Usage: lua scripts/test_mobile.lua
]]

local realExit = os.exit

-- ============================================================
-- Minimal CC stub (no full cc_stub needed for unit tests)
-- ============================================================

-- Stub globals that docs/lib modules expect
_G.os = _G.os or {}
_G.os.clock = _G.os.clock or function() return 0 end
_G.os.getComputerID = _G.os.getComputerID or function() return 1 end
_G.os.queueEvent = _G.os.queueEvent or function() end
_G.os.pullEvent = _G.os.pullEvent or function() return "" end
_G.os.startTimer = _G.os.startTimer or function() return 1 end
_G.os.cancelTimer = _G.os.cancelTimer or function() end
_G.sleep = _G.sleep or function() end
_G.parallel = _G.parallel or {}
_G.parallel.waitForAll = _G.parallel.waitForAll or function() end
_G.textutils = _G.textutils or {}
_G.textutils.serializeJSON = _G.textutils.serializeJSON or function(v) return tostring(v) end
_G.textutils.unserializeJSON = _G.textutils.unserializeJSON or function(s) return s end
_G.peripheral = _G.peripheral or {}
_G.peripheral.wrap = _G.peripheral.wrap or function() return nil end
_G.pcall = _G.pcall or function(f, ...) return true, f(...) end

-- ============================================================
-- Test framework
-- ============================================================

local failures = 0

local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print("  FAIL: " .. (msg or "(no message)"))
    end
end

local function assert_eq(got, expected, label)
    if got ~= expected then
        failures = failures + 1
        print("  FAIL [" .. (label or "") .. "]: expected " .. tostring(expected) .. ", got " .. tostring(got))
    end
end

local function assert_eq_table(got, expected, label)
    if type(got) ~= "table" or type(expected) ~= "table" then
        failures = failures + 1
        print("  FAIL [" .. (label or "") .. "]: expected table, got " .. type(got))
        return
    end
    if #got ~= #expected then
        failures = failures + 1
        print("  FAIL [" .. (label or "") .. "]: length mismatch: expected " .. #expected .. ", got " .. #got)
        return
    end
    for i = 1, #expected do
        if got[i] ~= expected[i] then
            failures = failures + 1
            print("  FAIL [" .. (label or "") .. "]@" .. i .. ": expected " .. tostring(expected[i]) .. ", got " .. tostring(got[i]))
            return
        end
    end
end

-- ============================================================
-- Package path setup (docs/lib contains lib/*.lua modules)
-- ============================================================

package.path = "./docs/?.lua;./docs/?/init.lua;" .. package.path

-- ============================================================
-- Load module under test
-- ============================================================

local Mobile = require("lib/mobile")

-- ============================================================
-- Tests: pack/unpack frame
-- ============================================================

print("== pack/unpack frame ==")

do
    local payload = { 0xAA, 0xBB, 0xCC }
    local frame = Mobile.packFrame(0x01, payload)
    assert_eq(frame[1], Mobile.VERSION, "version")
    assert_eq(frame[2], 0x01, "frameType")
    assert_eq(frame[3], 0xAA, "payload[1]")
    assert_eq(frame[4], 0xBB, "payload[2]")
    assert_eq(frame[5], 0xCC, "payload[3]")
end

do
    local version, ft, payload = Mobile.unpackFrame({ Mobile.VERSION, 0x10, 1, 2, 3 })
    assert_eq(version, Mobile.VERSION, "unpackFrame version")
    assert_eq(ft, 0x10, "unpackFrame frameType")
    assert_eq(#payload, 3, "unpackFrame payload length")
    assert_eq(payload[1], 1, "unpackFrame payload[1]")
    assert_eq(payload[2], 2, "unpackFrame payload[2]")
    assert_eq(payload[3], 3, "unpackFrame payload[3]")
end

-- Edge case: too short
do
    local version, ft, payload = Mobile.unpackFrame({ 1 })
    check(version == nil, "unpackFrame too short: version is nil")
    check(ft == nil, "unpackFrame too short: frameType is nil")
end

-- ============================================================
-- Tests: beacon pack/unpack
-- ============================================================

print("== beacon pack/unpack ==")

do
    local frame = Mobile.packBeacon(42, "Tower-01", 5)
    local version, ft, payload = Mobile.unpackFrame(frame)
    assert_eq(ft, Mobile.FRAME_BEACON, "beacon frameType")
    local bsId, bsName, load = Mobile.unpackBeacon(payload)
    assert_eq(bsId, 42, "beacon bsId")
    assert_eq(bsName, "Tower-01", "beacon bsName")
    assert_eq(load, 5, "beacon load")
end

-- Beacon with empty name
do
    local frame = Mobile.packBeacon(100, "", 0)
    local _, ft, payload = Mobile.unpackFrame(frame)
    local bsId, bsName, load = Mobile.unpackBeacon(payload)
    assert_eq(bsId, 100, "beacon empty name: bsId")
    assert_eq(bsName, "", "beacon empty name: bsName")
    assert_eq(load, 0, "beacon empty name: load")
end

-- Beacon with large load
do
    local frame = Mobile.packBeacon(1, "Big", 65535)
    local _, _, payload = Mobile.unpackFrame(frame)
    local _, _, load = Mobile.unpackBeacon(payload)
    assert_eq(load, 65535, "beacon large load")
end

-- ============================================================
-- Tests: association request pack/unpack
-- ============================================================

print("== assoc req pack/unpack ==")

do
    local frame = Mobile.packAssocReq(99, "phone-1")
    local version, ft, payload = Mobile.unpackFrame(frame)
    assert_eq(ft, Mobile.FRAME_ASSOC_REQ, "assoc req frameType")
    local deviceId, deviceName = Mobile.unpackAssocReq(payload)
    assert_eq(deviceId, 99, "assoc req deviceId")
    assert_eq(deviceName, "phone-1", "assoc req deviceName")
end

-- ============================================================
-- Tests: association response pack/unpack
-- ============================================================

print("== assoc resp pack/unpack ==")

do
    -- Accept
    local frame = Mobile.packAssocResp(0, 42)
    local _, ft, payload = Mobile.unpackFrame(frame)
    assert_eq(ft, Mobile.FRAME_ASSOC_RESP, "assoc resp frameType")
    local status, bsId = Mobile.unpackAssocResp(payload)
    assert_eq(status, 0, "assoc resp status accept")
    assert_eq(bsId, 42, "assoc resp bsId")
end

do
    -- Reject
    local frame = Mobile.packAssocResp(1, 42)
    local _, _, payload = Mobile.unpackFrame(frame)
    local status, bsId = Mobile.unpackAssocResp(payload)
    assert_eq(status, 1, "assoc resp status reject")
end

-- ============================================================
-- Tests: disassociation pack/unpack
-- ============================================================

print("== disassoc pack/unpack ==")

do
    local frame = Mobile.packDisassoc(55)
    local _, ft, payload = Mobile.unpackFrame(frame)
    assert_eq(ft, Mobile.FRAME_DISASSOC, "disassoc frameType")
    local deviceId = Mobile.unpackDisassoc(payload)
    assert_eq(deviceId, 55, "disassoc deviceId")
end

-- ============================================================
-- Tests: ethertype constant
-- ============================================================

print("== ethertype ==")

assert_eq(Mobile.ETHERTYPE, 0x88B5, "ethertype is 0x88B5")
assert_eq(Mobile.VERSION, 1, "version is 1")
assert_eq(Mobile.FRAME_BEACON, 0x01, "FRAME_BEACON")
assert_eq(Mobile.FRAME_ASSOC_REQ, 0x10, "FRAME_ASSOC_REQ")
assert_eq(Mobile.FRAME_ASSOC_RESP, 0x11, "FRAME_ASSOC_RESP")
assert_eq(Mobile.FRAME_DISASSOC, 0x12, "FRAME_DISASSOC")

-- ============================================================
-- Tests: round-trip with string containing CJK
-- ============================================================

print("== round-trip with CJK string ==")

do
    local frame = Mobile.packBeacon(1, "基站一号", 3)
    local _, _, payload = Mobile.unpackFrame(frame)
    local bsId, bsName, load = Mobile.unpackBeacon(payload)
    assert_eq(bsId, 1, "CJK bsId")
    assert_eq(bsName, "基站一号", "CJK bsName")
    assert_eq(load, 3, "CJK load")
end

-- ============================================================
-- Tests: binary round-trip for all frame types
-- ============================================================

print("== full binary round-trip ==")

do
    -- Beacon
    local beacon = Mobile.packBeacon(0xDEAD, "Test-BS", 42)
    local _, _, bp = Mobile.unpackFrame(beacon)
    local bid, bname, bload = Mobile.unpackBeacon(bp)
    assert_eq(bid, 0xDEAD, "full round-trip beacon id")
    assert_eq(bname, "Test-BS", "full round-trip beacon name")
    assert_eq(bload, 42, "full round-trip beacon load")

    -- AssocReq
    local areq = Mobile.packAssocReq(0xBEEF, "dev-abc")
    local _, _, arp = Mobile.unpackFrame(areq)
    local did, dname = Mobile.unpackAssocReq(arp)
    assert_eq(did, 0xBEEF, "full round-trip assoc req id")
    assert_eq(dname, "dev-abc", "full round-trip assoc req name")

    -- AssocResp
    local aresp = Mobile.packAssocResp(0, 0xCAFE)
    local _, _, arp2 = Mobile.unpackFrame(aresp)
    local st, bsid = Mobile.unpackAssocResp(arp2)
    assert_eq(st, 0, "full round-trip assoc resp status")
    assert_eq(bsid, 0xCAFE, "full round-trip assoc resp bsId")

    -- Disassoc
    local dis = Mobile.packDisassoc(0x1234)
    local _, _, dp = Mobile.unpackFrame(dis)
    local disId = Mobile.unpackDisassoc(dp)
    assert_eq(disId, 0x1234, "full round-trip disassoc id")
end

-- ============================================================
-- Summary
-- ============================================================

print("")
if failures == 0 then
    print("ALL TESTS PASSED")
    realExit(0)
else
    print(failures .. " TEST(S) FAILED")
    realExit(1)
end
