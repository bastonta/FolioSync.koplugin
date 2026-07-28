local reader_order = require("ui/elements/reader_menu_order")
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
    local pos = 1
    for index, value in ipairs(reader_order.tools) do
        if value == "statistics" then
            pos = index + 1
            break
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
    UIManager:show(InfoMessage:new{
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

return M
