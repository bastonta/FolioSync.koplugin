local ok_ro, reader_order = pcall(require, "ui/elements/reader_menu_order")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local json = require("json")

local M = {}

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
    if not ok then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
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

function M.sanitize_filename(name)
    if not name or name == "" then return "unnamed_book" end
    -- Remove characters invalid in Windows/Linux filenames
    local clean = name:gsub('[%\\%/%:%*%?%"%<%>%|]', "_")
    clean = clean:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if clean == "" then return "unnamed_book" end
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

return M

