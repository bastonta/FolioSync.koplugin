local json = require("json")
local logger = require("logger")
local ok_ffi, ffi = pcall(require, "ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

-- Constants
local GITHUB_API_URL = "https://api.github.com/repos/bastonta/FolioSync.koplugin/releases"
local USER_AGENT = "KOReader-FolioSync-Plugin"

-- Timeout constants in seconds
local AUTO_CHECK_TIMEOUT = 8    -- Silent background check timeout
local MANUAL_CHECK_TIMEOUT = 15 -- Manual check timeout
local DOWNLOAD_TIMEOUT = 120    -- 2 minutes for zip download

-- Determine plugin directory safely
local function script_path()
    local str = debug.getinfo(2, "S").source:sub(2)
    return str:match("(.*/)")
end

local plugin_dir = script_path() or "plugins/FolioSync.koplugin/"

local function loadMeta()
    if plugin_dir then
        local meta_path = plugin_dir .. "_meta.lua"
        local ok, result = pcall(dofile, meta_path)
        if ok and type(result) == "table" then
            return result
        end
    end
    local ok, meta = pcall(require, "_meta")
    if ok and type(meta) == "table" then
        return meta
    end
    return {
        name = "foliosync",
        fullname = _("Folio Sync & Library"),
        version = "dev",
    }
end

local meta = loadMeta()

-- Core modules always loaded
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

-- UI modules lazy-loaded on demand to speed up startup
local InfoMessage, ConfirmBox, Device, Screen, BD, ButtonDialog, Notification
local NetworkMgr, LuaSettings, DataStorage
local Blitbuffer, ButtonTable, CenterContainer, Font, FrameContainer, Geom
local InputContainer, MovableContainer, ScrollHtmlWidget, ScrollTextWidget
local Size, TitleBar, VerticalGroup, GestureRange, MD

local function loadUI()
    if Device then return end -- already loaded
    InfoMessage = require("ui/widget/infomessage")
    ConfirmBox = require("ui/widget/confirmbox")
    Device = require("device")
    Screen = Device.screen
    BD = require("ui/bidi")
    ButtonDialog = require("ui/widget/buttondialog")
    Notification = require("ui/widget/notification")
    NetworkMgr = require("ui/network/manager")
    LuaSettings = require("luasettings")
    DataStorage = require("datastorage")
    Blitbuffer = require("ffi/blitbuffer")
    ButtonTable = require("ui/widget/buttontable")
    CenterContainer = require("ui/widget/container/centercontainer")
    Font = require("ui/font")
    FrameContainer = require("ui/widget/container/framecontainer")
    Geom = require("ui/geometry")
    InputContainer = require("ui/widget/container/inputcontainer")
    MovableContainer = require("ui/widget/container/movablecontainer")
    ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
    ScrollTextWidget = require("ui/widget/scrolltextwidget")
    Size = require("ui/size")
    TitleBar = require("ui/widget/titlebar")
    VerticalGroup = require("ui/widget/verticalgroup")
    GestureRange = require("ui/gesturerange")
    MD = require("apps/filemanager/lib/md")
end

-- Session flags to prevent multiple concurrent or duplicate checks in one session
local _session_auto_check_done = false
local _session_auto_check_inflight = false

-- CSS for markdown rendering
local RELEASE_NOTES_CSS = [[
@page {
    margin: 0;
    font-family: 'Noto Sans';
}
body {
    margin: 0;
    padding: 0;
    line-height: 1.3;
}
h1, h2, h3, h4, h5, h6 {
    margin: 0.5em 0 0.3em 0;
    font-weight: bold;
}
h1 { font-size: 1.3em; }
h2 { font-size: 1.2em; }
h3 { font-size: 1.1em; }
p { margin: 0.4em 0; }
ul, ol { margin: 0.3em 0; padding-left: 1.5em; }
li { margin: 0.15em 0; }
code {
    font-family: monospace;
    background-color: #f0f0f0;
    padding: 0.1em 0.3em;
    border-radius: 3px;
    font-size: 0.9em;
}
pre {
    background-color: #f0f0f0;
    padding: 0.5em;
    border-radius: 3px;
    overflow-x: auto;
    margin: 0.5em 0;
}
pre code { background-color: transparent; padding: 0; }
strong, b { font-weight: bold; }
em, i { font-style: italic; }
hr { border: none; border-top: 1px solid #ccc; margin: 0.8em 0; }
blockquote {
    margin: 0.5em 0;
    padding-left: 1em;
    border-left: 3px solid #ccc;
}
a {
    color: #0366d6;
    text-decoration: underline;
}
]]

-- Auto-linkify plain URLs that aren't already part of markdown links
local function autoLinkUrls(text)
    if not text then return text end

    -- Step 1: Protect existing markdown links by storing them
    local links = {}
    local link_count = 0
    local result = text:gsub("%[([^%]]+)%]%(([^%)]+)%)", function(link_text, url)
        link_count = link_count + 1
        local placeholder = "XURLLINKX" .. link_count .. "XURLLINKX"
        links[link_count] = "[" .. link_text .. "](" .. url .. ")"
        return placeholder
    end)

    -- Step 2: Convert http:// and https:// URLs to markdown links
    result = result:gsub("(https?://[%w%-%./_~:?#@!$&'*+,;=%%]+)", function(url)
        local clean_url = url:gsub("[.,;:!?)]+$", "")
        local trailing = url:sub(#clean_url + 1)
        return "[" .. clean_url .. "](" .. clean_url .. ")" .. trailing
    end)

    -- Step 3: Restore protected links
    for i = 1, link_count do
        local placeholder = "XURLLINKX" .. i .. "XURLLINKX"
        result = result:gsub(placeholder, function() return links[i] end)
    end

    return result
end

-- Show link options dialog (matches KOReader's ReaderLink external link dialog)
local link_dialog
local function showLinkDialog(link_url)
    if not link_url then return end
    loadUI()

    local QRMessage = require("ui/widget/qrmessage")
    local buttons = {}

    -- Row 1: Copy | Show QR code
    table.insert(buttons, {
        {
            text = _("Copy"),
            callback = function()
                Device.input.setClipboardText(link_url)
                UIManager:close(link_dialog)
                UIManager:show(Notification:new{
                    text = _("Link copied to clipboard"),
                })
            end,
        },
        {
            text = _("Show QR code"),
            callback = function()
                UIManager:close(link_dialog)
                UIManager:show(QRMessage:new{
                    text = link_url,
                    width = Screen:getWidth(),
                    height = Screen:getHeight(),
                })
            end,
        },
    })

    -- Row 2: Open in browser (if supported)
    if Device:canOpenLink() then
        table.insert(buttons, {
            {
                text = _("Open in browser"),
                callback = function()
                    UIManager:close(link_dialog)
                    Device:openLink(link_url)
                end,
            },
        })
    end

    -- Row 3: Cancel
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(link_dialog)
            end,
        },
    })

    link_dialog = ButtonDialog:new{
        title = T(_("External link:\n\n%1"), BD.url(link_url)),
        buttons = buttons,
    }
    UIManager:show(link_dialog)
end

-- Handle link taps in HTML content
local function handleLinkTap(link)
    if link and link.uri then
        showLinkDialog(link.uri)
    end
end

-- Markdown Viewer widget for release notes
local MarkdownViewer

local function ensureMarkdownViewer()
    if MarkdownViewer then return end
    loadUI()
    MarkdownViewer = InputContainer:extend{
        title = _("Release Notes"),
        markdown_text = "",
        width = nil,
        height = nil,
        buttons_table = nil,
        text_padding = Size.padding.default,
        text_margin = 0,
    }

    function MarkdownViewer:init()
        self.width = self.width or math.floor(Screen:getWidth() * 0.85)
        self.height = self.height or math.floor(Screen:getHeight() * 0.85)

        local preprocessed_text = autoLinkUrls(self.markdown_text)

        local html_body, err = MD(preprocessed_text, {})
        if err then
            logger.warn("FolioSync MarkdownViewer: could not generate HTML", err)
            html_body = "<pre>" .. (self.markdown_text or _("No content.")) .. "</pre>"
        end

        local titlebar = TitleBar:new{
            title = self.title,
            width = self.width,
            with_bottom_line = true,
            close_callback = function()
                UIManager:close(self)
            end,
        }

        local button_table = ButtonTable:new{
            width = self.width - 2 * Size.padding.default,
            buttons = self.buttons_table or {{
                { text = _("Close"), callback = function() UIManager:close(self) end }
            }},
            zero_sep = true,
            show_parent = self,
        }

        local content_height = self.height - titlebar:getHeight() - button_table:getSize().h - 2 * self.text_padding

        local scroll_widget = ScrollHtmlWidget:new{
            html_body = html_body,
            css = RELEASE_NOTES_CSS,
            default_font_size = Screen:scaleBySize(16),
            width = self.width - 2 * self.text_padding,
            height = content_height,
            dialog = self,
            html_link_tapped_callback = handleLinkTap,
        }

        local text_container = FrameContainer:new{
            padding = self.text_padding,
            margin = 0,
            bordersize = 0,
            scroll_widget,
        }

        local frame_content = VerticalGroup:new{
            align = "left",
            titlebar,
            text_container,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = button_table:getSize().h },
                button_table,
            },
        }

        self.movable = MovableContainer:new{
            FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                radius = Size.radius.window,
                padding = 0,
                margin = 0,
                frame_content,
            }
        }

        self[1] = CenterContainer:new{
            dimen = Screen:getSize(),
            self.movable,
        }

        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(),
                    h = Screen:getHeight(),
                },
            },
        }
    end

    function MarkdownViewer:onTapClose(arg, ges)
        if ges.pos:notIntersectWith(self.movable.dimen) then
            UIManager:close(self)
            return true
        end
        return false
    end

    function MarkdownViewer:onCloseWidget()
        UIManager:setDirty(nil, "partial")
    end
end

local UpdateChecker = {}

--- Parse semantic version like "0.1.0-beta", "v1.0.0", "dev"
--- @param versionString string
--- @return table|nil
local function parseVersion(versionString)
    if type(versionString) ~= "string" then
        return nil
    end
    -- Strip leading 'v' or 'V'
    local clean = versionString:gsub("^[vV]%.?", "")
    if clean:lower() == "dev" or clean:lower():match("^dev") then
        return {
            major = 9999,
            minor = 9999,
            patch = 9999,
            prerelease = "dev",
            is_dev = true,
            original = versionString
        }
    end

    local major, minor, patch, prerelease = clean:match("^(%d+)%.(%d+)%.(%d+)%-?(.*)$")
    if not major then
        -- Try major.minor
        major, minor, prerelease = clean:match("^(%d+)%.(%d+)%-?(.*)$")
        patch = 0
    end

    if not major then
        return nil
    end

    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch) or 0,
        prerelease = (prerelease and prerelease ~= "") and prerelease or nil,
        original = versionString
    }
end

--- Compare two semantic versions
--- @param v1 string
--- @param v2 string
--- @return number -1 if v1 < v2, 0 if v1 == v2, 1 if v1 > v2
local function compareVersions(v1, v2)
    local ver1 = parseVersion(v1)
    local ver2 = parseVersion(v2)

    if not ver1 or not ver2 then
        if ver1 and not ver2 then return 1 end
        if not ver1 and ver2 then return -1 end
        return 0
    end

    -- Dev builds are considered higher than release versions
    if ver1.is_dev and not ver2.is_dev then return 1 end
    if ver2.is_dev and not ver1.is_dev then return -1 end
    if ver1.is_dev and ver2.is_dev then return 0 end

    -- Compare major.minor.patch
    if ver1.major ~= ver2.major then
        return ver1.major < ver2.major and -1 or 1
    end
    if ver1.minor ~= ver2.minor then
        return ver1.minor < ver2.minor and -1 or 1
    end
    if ver1.patch ~= ver2.patch then
        return ver1.patch < ver2.patch and -1 or 1
    end

    -- Handle prereleases: release > prerelease (1.0.0 > 1.0.0-beta)
    if not ver1.prerelease and ver2.prerelease then
        return 1
    elseif ver1.prerelease and not ver2.prerelease then
        return -1
    elseif ver1.prerelease and ver2.prerelease then
        local prereleaseOrder = {
            alpha = 1,
            beta = 2,
            rc = 3,
            release = 4
        }
        local pre1Type = ver1.prerelease:match("^(%a+)")
        local pre2Type = ver2.prerelease:match("^(%a+)")
        local order1 = prereleaseOrder[pre1Type] or 0
        local order2 = prereleaseOrder[pre2Type] or 0

        if order1 ~= order2 then
            return order1 < order2 and -1 or 1
        end

        return ver1.prerelease < ver2.prerelease and -1 or (ver1.prerelease > ver2.prerelease and 1 or 0)
    end

    return 0
end

-- Platform-specific binary paths
local mv_bin, cp_bin
local function getBinPaths()
    if mv_bin then return end
    local is_android = false
    if Device then
        is_android = Device:isAndroid()
    else
        local ok, D = pcall(require, "device")
        if ok and D and D.isAndroid then is_android = D:isAndroid() or false end
    end
    mv_bin = is_android and "/system/bin/mv" or "/bin/mv"
    cp_bin = is_android and "/system/bin/cp" or "/bin/cp"
end

-- Forward declaration
local performUpdate

--- Show the update available popup
--- @param update_info table: current_version, latest_version, release_notes, download_url, is_prerelease, zip_url
local function showUpdatePopup(update_info)
    ensureMarkdownViewer()
    local update_viewer

    local markdown_content = string.format(
        "**%s**\n\n**%s:** %s  \n**%s:** %s\n\n---\n\n%s",
        update_info.is_prerelease and _("New pre-release version available!") or _("New version available!"),
        _("Current"),
        update_info.current_version,
        _("Latest"),
        update_info.latest_version,
        update_info.release_notes or _("No release notes available.")
    )

    local buttons = {}

    -- Row 1: Later | Visit Release Page
    table.insert(buttons, {
        {
            text = _("Later"),
            callback = function()
                UIManager:close(update_viewer)
            end,
        },
        {
            text = _("Visit Release Page"),
            callback = function()
                UIManager:close(update_viewer)
                if Device:canOpenLink() then
                    Device:openLink(update_info.download_url)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Please visit:") .. "\n" .. update_info.download_url,
                        timeout = 10
                    })
                end
            end,
        },
    })

    -- Row 2: Update Now (only if zip available and not a git dev repo)
    local is_git = lfs.attributes(plugin_dir .. ".git", "mode") == "directory"
    if update_info.zip_url and not is_git then
        table.insert(buttons, {
            {
                text = _("Update Now"),
                callback = function()
                    UIManager:close(update_viewer)
                    performUpdate(update_info)
                end,
            },
        })
    end

    update_viewer = MarkdownViewer:new{
        title = update_info.is_prerelease and _("FolioSync Pre-release Update") or _("FolioSync Update Available"),
        markdown_text = markdown_content,
        width = math.floor(Screen:getWidth() * 0.85),
        height = math.floor(Screen:getHeight() * 0.85),
        buttons_table = buttons,
    }

    UIManager:broadcastEvent(require("ui/event"):new("CloseKeyboard"))
    UIManager:show(update_viewer)
    UIManager:setDirty(nil, "ui")
end

--- Wrap a file descriptor for ltn12 sink
local function wrap_fd(fd)
    local file_object = {}
    function file_object:write(chunk)
        ffiutil.writeToFD(fd, chunk)
        return self
    end
    function file_object:close()
        return true
    end
    return file_object
end

--- Perform HTTP request in subprocess with absolute timeout
--- @param url string URL to fetch
--- @param timeout number Absolute timeout in seconds
--- @param callback function Called with (success, data_or_error)
local function fetchWithAbsoluteTimeout(url, timeout, callback)
    local pid, parent_read_fd
    local completed = false
    local fd_closed = false
    local timeout_task = nil
    local poll_task = nil
    local accumulated_data = ""

    local function closeFd()
        if not fd_closed and parent_read_fd then
            fd_closed = true
            pcall(function()
                local remaining = ffiutil.readAllFromFD(parent_read_fd)
                if remaining and #remaining > 0 then
                    accumulated_data = accumulated_data .. remaining
                end
            end)
            if ffi and ffi.C and ffi.C.close then
                pcall(ffi.C.close, parent_read_fd)
            end
            parent_read_fd = nil
        end
    end

    local function cleanup(skip_fd_close)
        completed = true
        if timeout_task then
            UIManager:unschedule(timeout_task)
            timeout_task = nil
        end
        if poll_task then
            UIManager:unschedule(poll_task)
            poll_task = nil
        end
        if pid then
            ffiutil.terminateSubProcess(pid)
            local captured_pid = pid
            pid = nil
            local collect_and_clean
            collect_and_clean = function()
                if ffiutil.isSubProcessDone(captured_pid) then
                    if not skip_fd_close then
                        closeFd()
                    end
                else
                    UIManager:scheduleIn(0.1, collect_and_clean)
                end
            end
            UIManager:scheduleIn(0.1, collect_and_clean)
        end
    end

    local function subprocess_func(subprocess_pid, child_write_fd)
        if not subprocess_pid or not child_write_fd then return end

        local ok, err = pcall(function()
            local http = require("socket.http")
            local subprocess_ltn12 = require("ltn12")

            local su_ok, socketutil = pcall(require, "socketutil")
            if su_ok and socketutil then
                socketutil:set_timeout(8, 15)
            else
                local subprocess_https = require("ssl.https")
                subprocess_https.TIMEOUT = 8
            end

            local pipe_w = wrap_fd(child_write_fd)
            local request = {
                url = url,
                method = "GET",
                headers = {
                    ["Accept"] = "application/vnd.github.v3+json",
                    ["User-Agent"] = USER_AGENT,
                },
                sink = subprocess_ltn12.sink.file(pipe_w),
            }

            local req_ok, code = pcall(function()
                return select(2, http.request(request))
            end)

            if not req_ok or (code and code ~= 200) then
                ffiutil.writeToFD(child_write_fd, "\n__UPDATE_CHECK_ERROR__:" .. tostring(code or "connection failed"))
            end
        end)

        if not ok then
            ffiutil.writeToFD(child_write_fd, "\n__UPDATE_CHECK_ERROR__:" .. tostring(err))
        end

        if ffi and ffi.C and ffi.C.close then
            ffi.C.close(child_write_fd)
        end
        if ffi and ffi.C and ffi.C._exit then
            pcall(function() ffi.C._exit(0) end)
        end
    end

    timeout_task = UIManager:scheduleIn(timeout, function()
        if not completed then
            logger.info("FolioSync UpdateChecker: absolute timeout reached, killing subprocess")
            cleanup()
            callback(false, "Timeout")
        end
    end)

    local fork_ok
    fork_ok, pid, parent_read_fd = pcall(ffiutil.runInSubProcess, subprocess_func, true)

    if not fork_ok or not pid then
        cleanup()
        callback(false, fork_ok and "Failed to start subprocess" or ("Fork error: " .. tostring(pid)))
        return
    end

    if ffi and ffi.C and ffi.C.fcntl then
        local bit = require("bit")
        local O_NONBLOCK = (ffi.os == "OSX") and 0x0004 or (ffi.C.O_NONBLOCK or 2048)
        local nb_flags = ffi.C.fcntl(parent_read_fd, 3)
        if nb_flags >= 0 then
            ffi.C.fcntl(parent_read_fd, 4, ffi.cast("int", bit.bor(nb_flags, O_NONBLOCK)))
        end
    end

    local chunksize = 8192
    local buffer = (ffi and ffi.new) and ffi.new("char[?]", chunksize) or nil

    local function processResult()
        closeFd()
        cleanup(true)

        local error_msg = accumulated_data:match("__UPDATE_CHECK_ERROR__:(.+)")
        if error_msg then
            callback(false, error_msg)
        else
            callback(true, accumulated_data)
        end
    end

    local function pollForData()
        if completed then return end

        if ffi and ffi.C and ffi.C.read and buffer then
            while true do
                local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer, chunksize))
                if bytes_read and bytes_read > 0 then
                    accumulated_data = accumulated_data .. ffi.string(buffer, bytes_read)
                elseif bytes_read == 0 then
                    processResult()
                    return
                else
                    break
                end
            end
        end

        if ffiutil.isSubProcessDone(pid) then
            processResult()
            return
        end

        poll_task = UIManager:scheduleIn(0.1, pollForData)
    end

    poll_task = UIManager:scheduleIn(0.05, pollForData)
end

--- Download a file via HTTPS in subprocess writing directly to disk
--- @param url string URL to download
--- @param dest_path string Path to write the downloaded file
--- @param callback function Called with (success, error_msg_or_nil)
local function downloadFile(url, dest_path, callback)
    local pid, parent_read_fd
    local completed = false
    local fd_closed = false
    local timeout_task = nil
    local poll_task = nil
    local status_data = ""

    local function closeFd()
        if not fd_closed and parent_read_fd then
            fd_closed = true
            pcall(function()
                local remaining = ffiutil.readAllFromFD(parent_read_fd)
                if remaining and #remaining > 0 then
                    status_data = status_data .. remaining
                end
            end)
            if ffi and ffi.C and ffi.C.close then
                pcall(ffi.C.close, parent_read_fd)
            end
            parent_read_fd = nil
        end
    end

    local function cleanup(skip_fd_close)
        completed = true
        if timeout_task then
            UIManager:unschedule(timeout_task)
            timeout_task = nil
        end
        if poll_task then
            UIManager:unschedule(poll_task)
            poll_task = nil
        end
        if pid then
            ffiutil.terminateSubProcess(pid)
            local captured_pid = pid
            pid = nil
            local collect_and_clean
            collect_and_clean = function()
                if ffiutil.isSubProcessDone(captured_pid) then
                    if not skip_fd_close then
                        closeFd()
                    end
                else
                    UIManager:scheduleIn(0.1, collect_and_clean)
                end
            end
            UIManager:scheduleIn(0.1, collect_and_clean)
        end
    end

    timeout_task = UIManager:scheduleIn(DOWNLOAD_TIMEOUT, function()
        if not completed then
            logger.info("FolioSync UpdateChecker: download timeout reached, killing subprocess")
            cleanup()
            os.remove(dest_path)
            callback(false, _("Download timed out"))
        end
    end)

    pid, parent_read_fd = ffiutil.runInSubProcess(function(subprocess_pid, child_write_fd)
        if not subprocess_pid or not child_write_fd then return end

        local ok, sub_err = pcall(function()
            local subprocess_https = require("ssl.https")
            local subprocess_ltn12 = require("ltn12")
            subprocess_https.TIMEOUT = DOWNLOAD_TIMEOUT - 5

            local output_file = io.open(dest_path, "wb")
            if not output_file then
                ffiutil.writeToFD(child_write_fd, "ERROR:Failed to create file")
                return
            end

            local req_ok, code = pcall(function()
                return select(2, subprocess_https.request{
                    url = url,
                    method = "GET",
                    headers = {
                        ["User-Agent"] = USER_AGENT,
                    },
                    sink = subprocess_ltn12.sink.file(output_file),
                })
            end)

            if not req_ok or (code and code ~= 200) then
                os.remove(dest_path)
                ffiutil.writeToFD(child_write_fd, "ERROR:" .. tostring(code or "connection failed"))
            else
                ffiutil.writeToFD(child_write_fd, "OK")
            end
        end)

        if not ok then
            os.remove(dest_path)
            ffiutil.writeToFD(child_write_fd, "ERROR:" .. tostring(sub_err))
        end

        if ffi and ffi.C and ffi.C.close then
            ffi.C.close(child_write_fd)
        end
        if ffi and ffi.C and ffi.C._exit then
            pcall(function() ffi.C._exit(0) end)
        end
    end, true)

    if not pid then
        cleanup()
        callback(false, _("Failed to start download"))
        return
    end

    if ffi and ffi.C and ffi.C.fcntl then
        local bit = require("bit")
        local O_NONBLOCK = (ffi.os == "OSX") and 0x0004 or (ffi.C.O_NONBLOCK or 2048)
        local nb_flags = ffi.C.fcntl(parent_read_fd, 3)
        if nb_flags >= 0 then
            ffi.C.fcntl(parent_read_fd, 4, ffi.cast("int", bit.bor(nb_flags, O_NONBLOCK)))
        end
    end

    local chunksize = 256
    local buffer = (ffi and ffi.new) and ffi.new("char[?]", chunksize) or nil

    local function processResult()
        closeFd()
        cleanup(true)

        local error_msg = status_data:match("^ERROR:(.+)")
        if error_msg then
            os.remove(dest_path)
            callback(false, error_msg)
        else
            local attr = lfs.attributes(dest_path)
            if not attr or attr.size == 0 then
                os.remove(dest_path)
                callback(false, _("Downloaded file is empty"))
            else
                callback(true)
            end
        end
    end

    local function pollForData()
        if completed then return end

        if ffi and ffi.C and ffi.C.read and buffer then
            while true do
                local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer, chunksize))
                if bytes_read and bytes_read > 0 then
                    status_data = status_data .. ffi.string(buffer, bytes_read)
                elseif bytes_read == 0 then
                    processResult()
                    return
                else
                    break
                end
            end
        end

        if ffiutil.isSubProcessDone(pid) then
            processResult()
            return
        end

        poll_task = UIManager:scheduleIn(0.1, pollForData)
    end

    poll_task = UIManager:scheduleIn(0.05, pollForData)
end

--- Extract the update zip into staging_path stripping the top-level directory
--- @return boolean ok, string|nil error
local function extractUpdateArchive(archive_path, staging_path)
    if Device and Device.unpackArchive then
        return Device:unpackArchive(archive_path, staging_path, true)
    end
    local ok_mod, Archiver = pcall(require, "ffi/archiver")
    if not ok_mod or type(Archiver) ~= "table" or not Archiver.Reader then
        return false, "no archive extraction API in this KOReader version"
    end
    local arc = Archiver.Reader:new()
    if not arc:open(archive_path) then
        local open_err = arc.err
        arc:close()
        return false, open_err or "could not open archive"
    end
    for entry in arc:iterate() do
        local tail = entry.path:match("^[^/]+/(.+)$")
        if tail then
            if not arc:extractToPath(entry.path, staging_path .. "/" .. tail) then
                break
            end
        end
    end
    local ok = not arc.err
    local extract_err = arc.err
    arc:close()
    if not ok then
        return false, extract_err or "extraction failed"
    end
    return true
end

--- Verify extracted plugin directory
--- @param staging_dir string Path to the extracted plugin directory
--- @param expected_version string Expected version string from the release
--- @return boolean success, string|nil error_msg
local function verifyExtractedPlugin(staging_dir, expected_version)
    local meta_path = staging_dir .. "/_meta.lua"
    if lfs.attributes(meta_path, "mode") ~= "file" then
        return false, "_meta.lua not found in extracted plugin"
    end

    local main_path = staging_dir .. "/main.lua"
    if lfs.attributes(main_path, "mode") ~= "file" then
        return false, "main.lua not found in extracted plugin"
    end

    -- Verify version if _version.lua is present
    local ver_path = staging_dir .. "/_version.lua"
    if lfs.attributes(ver_path, "mode") == "file" then
        local load_ok, loaded_ver = pcall(dofile, ver_path)
        if load_ok and loaded_ver and type(loaded_ver) == "string" then
            local exp_clean = expected_version:gsub("^[vV]%.?", "")
            local loaded_clean = loaded_ver:gsub("^[vV]%.?", "")
            if exp_clean ~= loaded_clean and loaded_ver ~= "dev" then
                logger.warn("FolioSync UpdateChecker: version mismatch", exp_clean, loaded_clean)
            end
        end
    end

    return true
end

--- Find available backup directory path
--- @param base_path string Base path for the backup directory
--- @return string available_path
local function findAvailableBackupPath(base_path)
    if lfs.attributes(base_path, "mode") ~= "directory" then
        return base_path
    end

    for i = 2, 10 do
        local numbered_path = base_path .. "_" .. i
        if lfs.attributes(numbered_path, "mode") ~= "directory" then
            return numbered_path
        end
    end

    logger.warn("FolioSync UpdateChecker: too many leftover backups, purging", base_path)
    ffiutil.purgeDir(base_path)
    return base_path
end

--- Main auto-update orchestrator
--- @param update_info table Contains zip_url, latest_version, etc.
performUpdate = function(update_info)
    loadUI()
    getBinPaths()

    if lfs.attributes(plugin_dir .. ".git", "mode") == "directory" then
        UIManager:show(InfoMessage:new{
            text = _("Auto-update is disabled for git-based installs. Please use git pull instead."),
            timeout = 5,
        })
        return
    end

    if not update_info.zip_url then
        UIManager:show(InfoMessage:new{
            text = _("No download URL available for this release. Please update manually."),
            timeout = 5,
        })
        return
    end

    if not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new{
            text = _("No network connection. Please connect and try again."),
            timeout = 3,
        })
        return
    end

    local plugin_path = plugin_dir:gsub("/$", "")
    local plugins_parent = plugin_path:match("(.*/)") or "plugins/"
    local archive_path = plugins_parent .. "FolioSync.koplugin_update.zip"
    local staging_path = plugins_parent .. "FolioSync.koplugin_staging"
    local backup_base = plugins_parent .. "FolioSync.koplugin.backup"

    local function updateFailed(msg, cleanup_paths)
        for _idx, path in ipairs(cleanup_paths or {}) do
            local attr = lfs.attributes(path, "mode")
            if attr == "file" then
                os.remove(path)
            elseif attr == "directory" then
                ffiutil.purgeDir(path)
            end
        end
        UIManager:show(InfoMessage:new{
            text = T(_("Update failed: %1"), msg),
            timeout = 8,
        })
    end

    local progress_msg = InfoMessage:new{
        text = T(_("Downloading FolioSync update %1..."), update_info.latest_version),
    }
    UIManager:show(progress_msg)
    UIManager:forceRePaint()

    downloadFile(update_info.zip_url, archive_path, function(dl_success, dl_error)
        UIManager:close(progress_msg)

        if not dl_success then
            updateFailed(dl_error or _("Download failed"), { archive_path })
            return
        end

        local install_msg = InfoMessage:new{
            text = T(_("Installing FolioSync update %1..."), update_info.latest_version),
        }
        UIManager:show(install_msg)
        UIManager:forceRePaint()

        if lfs.attributes(staging_path, "mode") == "directory" then
            ffiutil.purgeDir(staging_path)
        end
        lfs.mkdir(staging_path)

        local extract_ok, extract_err = extractUpdateArchive(archive_path, staging_path)
        if not extract_ok then
            logger.err("FolioSync UpdateChecker: extract failed:", extract_err)
            UIManager:close(install_msg)
            updateFailed(_("Failed to extract update archive"), { archive_path, staging_path })
            return
        end

        local verify_ok, verify_err = verifyExtractedPlugin(staging_path, update_info.latest_version)
        if not verify_ok then
            UIManager:close(install_msg)
            updateFailed(verify_err, { archive_path, staging_path })
            return
        end

        local backup_path = findAvailableBackupPath(backup_base)
        local mv_ret = ffiutil.execute(mv_bin, plugin_path, backup_path)
        if mv_ret ~= 0 then
            UIManager:close(install_msg)
            updateFailed(_("Failed to move current plugin to backup"), { archive_path, staging_path })
            return
        end

        mv_ret = ffiutil.execute(mv_bin, staging_path, plugin_path)
        if mv_ret ~= 0 then
            logger.err("FolioSync UpdateChecker: CRITICAL - staging move failed, restoring backup")
            local restore_ret = ffiutil.execute(mv_bin, backup_path, plugin_path)
            UIManager:close(install_msg)
            if restore_ret ~= 0 then
                updateFailed(_("Failed to install update AND failed to restore previous version. Backup is at: ") .. backup_path, { archive_path })
            else
                updateFailed(_("Failed to install new plugin version. Previous version restored."), { archive_path })
            end
            return
        end

        pcall(os.remove, archive_path)
        pcall(ffiutil.purgeDir, backup_path)
        pcall(ffiutil.purgeDir, staging_path)

        UIManager:close(install_msg)

        local restart_msg = T(_("FolioSync updated to version %1.\n\nPlease restart KOReader to use the new version."), update_info.latest_version)
        UIManager:askForRestart(restart_msg)
    end)
end

--- Check for updates (auto background or manual)
--- @param auto boolean True for silent background check
--- @param include_prereleases boolean|nil Whether to include pre-releases (default false)
function UpdateChecker.checkForUpdates(auto, include_prereleases)
    if auto and (_session_auto_check_done or _session_auto_check_inflight) then
        logger.dbg("FolioSync UpdateChecker: skipping duplicate auto-check this session")
        return
    end
    if auto then
        _session_auto_check_inflight = true
    end

    if include_prereleases == nil then
        include_prereleases = false
    end

    local timeout = auto and AUTO_CHECK_TIMEOUT or MANUAL_CHECK_TIMEOUT

    local function extractVersion(tag)
        if not tag or type(tag) ~= "string" then return nil end
        return tag:gsub("^[vV]%.?", "")
    end

    local loading_msg = nil
    if not auto then
        loadUI()
        loading_msg = InfoMessage:new{
            text = _("Checking for FolioSync updates..."),
        }
        UIManager:show(loading_msg)
        UIManager:forceRePaint()
    end

    local function closeLoading()
        if loading_msg then
            UIManager:close(loading_msg)
        end
    end

    fetchWithAbsoluteTimeout(GITHUB_API_URL, timeout, function(fetch_success, response_data)
        closeLoading()
        _session_auto_check_inflight = false

        if not fetch_success then
            logger.warn("FolioSync UpdateChecker: failed to check for updates:", response_data)
            if not auto then
                local error_text = response_data == "Timeout"
                    and _("Failed to check for updates (timed out). Please try again.")
                    or _("Failed to check for updates. Please check your internet connection.")
                UIManager:show(InfoMessage:new{
                    text = error_text,
                    timeout = 3
                })
            end
            return
        end

        if not response_data or response_data == "" then
            logger.warn("FolioSync UpdateChecker: empty response from GitHub API")
            if not auto then
                loadUI()
                UIManager:show(InfoMessage:new{
                    text = _("Failed to check for updates: Empty response from server"),
                    timeout = 3
                })
            end
            return
        end

        local decode_success, releases = pcall(json.decode, response_data)
        if not decode_success or type(releases) ~= "table" then
            logger.warn("FolioSync UpdateChecker: invalid response format:", releases)
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = _("Failed to check for updates: Invalid response format"),
                    timeout = 3
                })
            end
            return
        end

        if auto then
            _session_auto_check_done = true
        end
        if G_reader_settings and G_reader_settings.saveSetting then
            G_reader_settings:saveSetting("foliosync_last_update_check", os.time())
        end

        local latest_release = nil
        local latest_version_str = nil

        for _idx, release in ipairs(releases) do
            if not release.draft then
                if include_prereleases or not release.prerelease then
                    local version_str = extractVersion(release.tag_name)
                    if version_str and parseVersion(version_str) then
                        if not latest_release then
                            latest_release = release
                            latest_version_str = version_str
                        else
                            if compareVersions(version_str, latest_version_str) > 0 then
                                latest_release = release
                                latest_version_str = version_str
                            end
                        end
                    end
                end
            end
        end

        if not latest_release then
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = _("No releases found"),
                    timeout = 3
                })
            end
            return
        end

        local latest_version = latest_version_str
        local current_version = meta.version or "dev"

        local comparison = compareVersions(current_version, latest_version)
        logger.info("FolioSync UpdateChecker: current=" .. tostring(current_version) .. ", latest=" .. tostring(latest_version) .. ", comparison=" .. tostring(comparison))

        local current_parsed = parseVersion(current_version)
        local is_dev = current_parsed and current_parsed.is_dev

        if comparison < 0 then
            local zip_url = nil
            if latest_release.assets then
                for _idx, asset in ipairs(latest_release.assets) do
                    if asset.name and asset.name:match("%.zip$") then
                        zip_url = asset.browser_download_url
                        break
                    end
                end
            end

            local update_info = {
                current_version = current_version,
                latest_version = latest_version,
                release_notes = latest_release.body or _("No release notes available."),
                download_url = latest_release.html_url,
                is_prerelease = latest_release.prerelease or false,
                zip_url = zip_url,
            }

            showUpdatePopup(update_info)
        elseif comparison == 0 or (comparison > 0 and not is_dev) then
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = T(_("You are running the latest version of FolioSync (%1)"), current_version),
                    timeout = 3
                })
            end
        else
            if not auto then
                UIManager:show(InfoMessage:new{
                    text = T(_("You are running a development version of FolioSync (%1)"), current_version),
                    timeout = 3
                })
            end
        end
    end)
end

function UpdateChecker.getCurrentVersion()
    return meta.version or "dev"
end

function UpdateChecker.checkForUpdatesInBackground()
    UpdateChecker.checkForUpdates(true)
end

-- Test seams
UpdateChecker._parseVersion = parseVersion
UpdateChecker._compareVersions = compareVersions
UpdateChecker._extractUpdateArchive = extractUpdateArchive
UpdateChecker._verifyExtractedPlugin = verifyExtractedPlugin
UpdateChecker._findAvailableBackupPath = findAvailableBackupPath

return UpdateChecker
