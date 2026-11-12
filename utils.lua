local ok_ro, reader_order = pcall(require, "ui/elements/reader_menu_order")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local json = require("json")

local M = {}

local unpack = unpack or table.unpack -- luacheck: ignore

function M.read_json(path)
    local f = io.open(path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return {}
    end

    if not M.isPossiblyJson(content) then
        return nil
    end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

function M.write_json(path, data)
    local ok, content = pcall(json.encode, data)
    if not ok or type(content) ~= "string" then return false end
    local f = io.open(path, "w")
    if not f then return false end
    local written = f:write(content)
    local closed = f:close()
    return written ~= nil and closed ~= nil and closed ~= false
end

function M.insert_after_statistics(key)
    if not ok_ro or not reader_order or not reader_order.tools then
        return
    end
    local pos = 1
    for index, value in ipairs(reader_order.tools) do
        if value == key then
            return
        end
        if value == "statistics" then
            pos = index + 1
        end
    end
    table.insert(reader_order.tools, pos, key)
end

function M.isPossiblyJson(content)
    if not content then return false end
    local first_char = content:match("^%s*(%S)")
    return first_char == "{" or first_char == "["
end

function M.show_msg(msg, timeout)
    UIManager:show(InfoMessage:new {
        text = msg,
        timeout = timeout or 3,
    })
end

-- A single path component that is safe to create inside a download directory: no
-- separators, no control characters, and never `.` / `..` (a series called `..` must not
-- lead out of the directory).
function M.sanitize_filename(name)
    if type(name) ~= "string" or name == "" then return "unnamed_book" end
    -- Remove characters invalid in Windows/Linux filenames
    local clean = name:gsub("%c", " "):gsub('[%\\%/%:%*%?%"%<%>%|]', "_")
    clean = clean:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    -- A name made of dots only is the directory itself or its parent
    if clean == "" or clean:match("^%.+$") then return "unnamed_book" end
    return clean
end

function M.trim_slash(url)
    if not url then return "" end
    return url:gsub("/+$", "")
end

function M.get_file_basename(path)
    if not path then return "" end
    return path:match("^.+[/\\](.+)$") or path
end

function M.clean_cfi(cfi)
    if not cfi or type(cfi) ~= "string" then return nil end
    local clean = cfi:gsub("epubcfi%((.-)%)", "%1")
    return clean
end

function M.build_book_target_dir(base_dir, series_path)
    local target = M.trim_slash(base_dir or "")
    if not series_path or series_path == "" then
        return target
    end

    for part in series_path:gmatch("[^/\\]+") do
        local clean_part = M.sanitize_filename(part)
        if clean_part ~= "" and clean_part ~= "unnamed_book" then
            if target == "" then
                target = clean_part
            else
                target = target .. "/" .. clean_part
            end
        end
    end
    return target
end

function M.ensure_dir(dir_path)
    if not dir_path or dir_path == "" then return false end
    local ok_lfs, lfs_mod = pcall(require, "lfs")
    if ok_lfs and lfs_mod and lfs_mod.mkdir then
        local path_acc = ""
        for part in dir_path:gmatch("[^/\\]+") do
            if dir_path:sub(1, 1) == "/" and path_acc == "" then
                path_acc = "/" .. part
            else
                path_acc = path_acc == "" and part or (path_acc .. "/" .. part)
            end
            lfs_mod.mkdir(path_acc)
        end
        return true
    else
        local clean_dir = dir_path:gsub('["`$\\]', "\\%1")
        os.execute("mkdir -p \"" .. clean_dir .. "\"")
        return true
    end
end

function M.url_encode(str)
    if not str then return "" end
    str = tostring(str)
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w%-_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

function M.get_parent_dir(path)
    if not path or path == "" then return nil end
    local clean = path:gsub("[/\\]+$", "")
    if clean == "" then
        return "/"
    end
    local parent = clean:match("^(.*)[/\\][^/\\]+$")
    if parent and parent ~= "" then
        return parent
    end
    if clean:sub(1, 1) == "/" then
        return "/"
    end
    return clean
end

function M.iso8601(epoch)
    local t = epoch or os.time()
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

-- Seconds since the epoch, with a fraction where a finer clock than os.time() is there.
function M.now()
    local ok, socket = pcall(require, "socket")
    if ok and type(socket) == "table" and type(socket.gettime) == "function" then
        local ok_time, value = pcall(socket.gettime)
        if ok_time and type(value) == "number" then
            return value
        end
    end
    return os.time()
end

-- RFC 3339 with milliseconds: `2026-11-12T10:00:00.250Z`. Times that order the changes
-- of several devices need more than whole seconds.
function M.iso8601_ms(epoch)
    epoch = epoch or M.now()
    local whole = math.floor(epoch)
    local ms = math.min(999, math.floor((epoch - whole) * 1000 + 0.5))
    return os.date("!%Y-%m-%dT%H:%M:%S", whole) .. string.format(".%03dZ", ms)
end

-- Seconds since the epoch of a UTC calendar date (os.time() reads its argument as local time).
local function utc_epoch(year, month, day, hour, min, sec)
    if month <= 2 then year = year - 1 end
    local era = math.floor(year / 400)
    local yoe = year - era * 400
    local mp = (month + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + hour * 3600 + min * 60 + sec
end

-- Seconds since the epoch (with fraction) of an RFC 3339 timestamp such as
-- `2026-11-11T10:00:00.123456Z` or `2026-11-11T12:00:00+02:00`; nil when it is not one.
function M.parse_iso8601(value)
    if type(value) ~= "string" then return nil end
    local year, month, day, hour, min, sec, rest =
        value:match("^%s*(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
    if not year then return nil end
    local epoch = utc_epoch(tonumber(year), tonumber(month), tonumber(day),
        tonumber(hour), tonumber(min), tonumber(sec))
    local fraction, zone = rest:match("^(%.%d+)(.*)$")
    if fraction then
        epoch = epoch + tonumber("0" .. fraction)
    else
        zone = rest
    end
    local sign, zone_hour, zone_min = zone:match("^%s*([%+%-])(%d%d):?(%d%d)%s*$")
    if sign then
        local offset = tonumber(zone_hour) * 3600 + tonumber(zone_min) * 60
        epoch = epoch - (sign == "+" and offset or -offset)
    end
    return epoch
end

local HTTP_MONTHS = {
    jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

-- Seconds since the epoch of an HTTP `Date` header (`Wed, 11 Nov 2026 10:00:00 GMT`).
function M.parse_http_date(value)
    if type(value) ~= "string" then return nil end
    local day, month_name, year, hour, min, sec =
        value:match("(%d+)%s+(%a+)%s+(%d%d%d%d)%s+(%d+):(%d+):(%d+)")
    local month = month_name and HTTP_MONTHS[month_name:sub(1, 3):lower()]
    if not month then return nil end
    return utc_epoch(tonumber(year), month, tonumber(day), tonumber(hour), tonumber(min), tonumber(sec))
end

-- KOReader reports reading progress as a fraction (0..1); Folio counts in percent
-- (0..100). This is the only place that converts, and it does so exactly once: a
-- value above 1 cannot be a fraction and is taken as a percentage already.
function M.fraction_to_percent(value)
    value = tonumber(value)
    if not value or value ~= value or value <= 0 then return 0 end
    if value > 1 then
        return math.min(value, 100)
    end
    return value * 100
end

-- Whether two values are equal, tables compared by content.
function M.same_value(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for key, value in pairs(a) do
        if not M.same_value(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

-- Whether a regular file can be opened for reading.
function M.file_exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

-- Size and modification time of a file; nil when it cannot be read. The modification
-- time is nil where no filesystem library is available.
function M.file_stat(path)
    if type(path) ~= "string" or path == "" then return nil end
    local lfs_mod = package.loaded["lfs"] or package.loaded["libs/libkoreader-lfs"]
    if not lfs_mod then
        local ok, mod = pcall(require, "libs/libkoreader-lfs")
        if not ok then ok, mod = pcall(require, "lfs") end
        lfs_mod = ok and mod or nil
    end
    if type(lfs_mod) == "table" and lfs_mod.attributes then
        local ok, attr = pcall(lfs_mod.attributes, path)
        if ok and type(attr) == "table" and attr.mode == "file" then
            return attr.size, attr.modification
        end
        if ok then return nil end
    end
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size, nil
end

-- ================= UUID =================

local function urandom_bytes(count)
    local f = io.open("/dev/urandom", "rb")
    if not f then return nil end
    local ok, bytes = pcall(f.read, f, count)
    f:close()
    if ok and type(bytes) == "string" and #bytes == count then
        return bytes
    end
    return nil
end

-- A stock LuaJIT starts math.random with the same sequence on every run, and KOReader
-- only seeds it (from the clock, in frontend/random.lua) when that module happens to be
-- loaded. Seed it once per interpreter from everything that differs between two runs.
local fallback_seeded = false
local function seed_fallback()
    if fallback_seeded then return end
    fallback_seeded = true
    local seed = os.time() % 65536
    local ok_socket, socket = pcall(require, "socket")
    if ok_socket and type(socket) == "table" and type(socket.gettime) == "function" then
        seed = seed * 31 + math.floor((socket.gettime() % 1) * 1e6)
    end
    seed = seed * 31 + math.floor((os.clock() * 1e6) % 1e6)
    -- Heap addresses move between runs (ASLR)
    for _ = 1, 2 do
        local address = tostring({}):match("0x(%x+)") or tostring({}):match("(%x+)%s*$")
        seed = seed * 31 + ((tonumber(address or "", 16) or 0) % 1000003)
    end
    math.randomseed(math.floor(seed) % 2147483647)
    -- The first values of some generators barely depend on the seed
    for _ = 1, 16 do math.random() end
end

local function format_uuid(bytes)
    -- Version 4, RFC 4122 variant
    bytes[7] = bytes[7] % 16 + 64
    bytes[9] = bytes[9] % 64 + 128
    return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        unpack(bytes))
end

-- UUID v4 from the seeded fallback generator (used when the system has no random device).
function M.uuid_from_seeded_fallback()
    -- Loading KOReader's own helper re-seeds math.random from the clock: load it first
    local ok_random, krandom = pcall(require, "random")
    seed_fallback()
    if ok_random and type(krandom) == "table" and type(krandom.uuid) == "function" then
        local ok, value = pcall(krandom.uuid, true)
        if ok and type(value) == "string" and #value == 36 then
            return value:lower()
        end
    end
    local bytes = {}
    for i = 1, 16 do
        bytes[i] = math.random(0, 255)
    end
    return format_uuid(bytes)
end

-- A random (version 4) UUID, in the lowercase form the Folio server returns.
function M.generate_uuid()
    local raw = urandom_bytes(16)
    if raw then
        return format_uuid({ raw:byte(1, 16) })
    end
    return M.uuid_from_seeded_fallback()
end

function M.is_uuid(value)
    return type(value) == "string"
        and value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

return M

