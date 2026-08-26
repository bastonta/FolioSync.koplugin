local _ = require("gettext")

local function script_path()
    local str = debug.getinfo(2, "S").source:sub(2)
    return str:match("(.*/)")
end

local function get_version()
    local dir = script_path()
    if dir then
        local ok, ver = pcall(dofile, dir .. "_version.lua")
        if ok and type(ver) == "string" then
            return ver
        end
    end
    local ok, ver = pcall(require, "_version")
    if ok and type(ver) == "string" then
        return ver
    end
    return "dev"
end

return {
    name = "foliosync",
    fullname = _("Folio Sync & Library"),
    description = _("Sync annotations, reading progress, and download books directly from your Folio server."),
    version = get_version(),
}

