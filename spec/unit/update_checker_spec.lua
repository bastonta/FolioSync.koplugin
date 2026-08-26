-- Mock common KOReader and Lua modules for standalone test execution
local ok_dk, dkjson = pcall(require, "dkjson")
if ok_dk and dkjson then
    package.loaded["json"] = {
        encode = dkjson.encode,
        decode = dkjson.decode,
    }
end

package.loaded["ffi"] = package.loaded["ffi"] or {
    os = "Linux",
    C = {
        close = function(fd) end,
        read = function(fd, buf, sz) return 0 end,
        O_NONBLOCK = 2048,
        fcntl = function(fd, cmd, arg) return 0 end,
        _exit = function(code) end,
    },
    new = function(t, sz) return {} end,
    string = function(buf, sz) return "" end,
    cast = function(t, val) return val end,
}

package.loaded["ui/uimanager"] = package.loaded["ui/uimanager"] or {
    show = function(self, widget) end,
    close = function(self, widget) end,
    broadcastEvent = function(self, evt) end,
    scheduleIn = function(self, delay, cb) end,
    unschedule = function(self, task) end,
    forceRePaint = function(self) end,
    setDirty = function(self, widget, mode) end,
    askForRestart = function(self, msg) end,
}
package.loaded["ui/widget/infomessage"] = package.loaded["ui/widget/infomessage"] or {
    new = function(self, o) return o end,
}
package.loaded["ui/widget/confirmbox"] = package.loaded["ui/widget/confirmbox"] or {
    new = function(self, o) return o end,
}
package.loaded["ui/widget/buttondialog"] = package.loaded["ui/widget/buttondialog"] or {
    new = function(self, o) return o end,
}
package.loaded["ui/widget/notification"] = package.loaded["ui/widget/notification"] or {
    new = function(self, o) return o end,
}
package.loaded["ui/network/manager"] = package.loaded["ui/network/manager"] or {
    isOnline = function(self) return true end,
    isWifiOn = function(self) return true end,
    runWhenConnected = function(self, cb) cb() end,
}
package.loaded["device"] = package.loaded["device"] or {
    screen = {
        getWidth = function() return 1080 end,
        getHeight = function() return 1440 end,
        getSize = function() return { w = 1080, h = 1440 } end,
        scaleBySize = function(self, size) return size end,
    },
    input = {
        setClipboardText = function(text) end,
    },
    canOpenLink = function(self) return true end,
    openLink = function(self, url) end,
    isAndroid = function(self) return false end,
}
package.loaded["logger"] = package.loaded["logger"] or {
    dbg = function(...) end,
    info = function(...) end,
    warn = function(...) end,
    err = function(...) end,
}
package.loaded["gettext"] = package.loaded["gettext"] or function(s) return s end
package.loaded["ffi/util"] = package.loaded["ffi/util"] or {
    template = function(tmpl, ...)
        local args = { ... }
        return (tmpl:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)] or "") end))
    end,
    runInSubProcess = function(fn, wait) return true, 1234, 5 end,
    terminateSubProcess = function(pid) end,
    isSubProcessDone = function(pid) return true end,
    writeToFD = function(fd, data) end,
    readAllFromFD = function(fd) return "" end,
    execute = function(bin, ...) return 0 end,
    purgeDir = function(dir) end,
    copyFile = function(src, dst) return nil end,
}
package.loaded["libs/libkoreader-lfs"] = package.loaded["libs/libkoreader-lfs"] or {
    attributes = function(path, key)
        if path:match("%.git") then
            return nil
        end
        return { mode = "file", size = 100 }
    end,
    mkdir = function(path) return true end,
}

local UpdateChecker = require("update_checker")

describe("FolioSync UpdateChecker", function()
    describe("Version Parsing", function()
        it("parses regular semver strings", function()
            local v = UpdateChecker._parseVersion("1.2.3")
            assert.is_not_nil(v)
            assert.is_equal(1, v.major)
            assert.is_equal(2, v.minor)
            assert.is_equal(3, v.patch)
            assert.is_nil(v.prerelease)
        end)

        it("parses semver with 'v' prefix", function()
            local v = UpdateChecker._parseVersion("v0.4.1")
            assert.is_not_nil(v)
            assert.is_equal(0, v.major)
            assert.is_equal(4, v.minor)
            assert.is_equal(1, v.patch)
            assert.is_nil(v.prerelease)
        end)

        it("parses semver with prerelease tags", function()
            local v = UpdateChecker._parseVersion("v1.0.0-beta.2")
            assert.is_not_nil(v)
            assert.is_equal(1, v.major)
            assert.is_equal(0, v.minor)
            assert.is_equal(0, v.patch)
            assert.is_equal("beta.2", v.prerelease)
        end)

        it("identifies dev version", function()
            local v = UpdateChecker._parseVersion("dev")
            assert.is_not_nil(v)
            assert.is_true(v.is_dev)
        end)

        it("returns nil for invalid version strings", function()
            assert.is_nil(UpdateChecker._parseVersion(nil))
            assert.is_nil(UpdateChecker._parseVersion(123))
            assert.is_nil(UpdateChecker._parseVersion("unknown-version"))
        end)
    end)

    describe("Version Comparison", function()
        it("detects newer minor version", function()
            assert.is_equal(-1, UpdateChecker._compareVersions("0.1.0", "0.2.0"))
            assert.is_equal(1, UpdateChecker._compareVersions("0.2.0", "0.1.0"))
        end)

        it("detects newer patch version", function()
            assert.is_equal(-1, UpdateChecker._compareVersions("1.0.0", "1.0.1"))
            assert.is_equal(1, UpdateChecker._compareVersions("1.0.1", "1.0.0"))
        end)

        it("detects equal versions with or without v prefix", function()
            assert.is_equal(0, UpdateChecker._compareVersions("1.0.0", "1.0.0"))
            assert.is_equal(0, UpdateChecker._compareVersions("v1.0.0", "1.0.0"))
            assert.is_equal(0, UpdateChecker._compareVersions("1.0.0", "v1.0.0"))
        end)

        it("compares release vs prerelease", function()
            assert.is_equal(1, UpdateChecker._compareVersions("1.0.0", "1.0.0-beta"))
            assert.is_equal(-1, UpdateChecker._compareVersions("1.0.0-beta", "1.0.0"))
        end)

        it("compares alpha vs beta vs rc", function()
            assert.is_equal(-1, UpdateChecker._compareVersions("1.0.0-alpha", "1.0.0-beta"))
            assert.is_equal(-1, UpdateChecker._compareVersions("1.0.0-beta", "1.0.0-rc"))
            assert.is_equal(1, UpdateChecker._compareVersions("1.0.0-rc", "1.0.0-beta"))
        end)

        it("handles dev version comparisons", function()
            assert.is_equal(1, UpdateChecker._compareVersions("dev", "1.0.0"))
            assert.is_equal(-1, UpdateChecker._compareVersions("1.0.0", "dev"))
            assert.is_equal(0, UpdateChecker._compareVersions("dev", "dev"))
        end)
    end)

    describe("Backup Path Resolution", function()
        it("returns available backup path", function()
            local base = "/test/plugins/FolioSync.koplugin.backup"
            local path = UpdateChecker._findAvailableBackupPath(base)
            assert.is_not_nil(path)
        end)
    end)
end)
