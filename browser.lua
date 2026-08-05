local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local T = require("ffi/util").template
local utils = require("utils")

local FolioBrowser = {}

function FolioBrowser:new(plugin_instance)
    local o = {
        plugin = plugin_instance,
        api = plugin_instance.api,
        current_series_id = nil,
        series_stack = {},
        current_page = 1,
        limit = 15,
        sort_by = "name",
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function FolioBrowser:show()
    self.current_series_id = nil
    self.series_stack = {}
    self.current_page = 1
    self:load_and_render()
end

function FolioBrowser:load_and_render()
    if not self.api:has_auth() then
        UIManager:show(InfoMessage:new {
            text = _("Please enter your Folio API Key in Settings."),
            timeout = 4,
        })
        return
    end

    UIManager:show(InfoMessage:new {
        text = _("Fetching library from Folio..."),
        timeout = 2,
    })

    local offset = (self.current_page - 1) * self.limit

    self.api:browse(self.current_series_id, self.sort_by, offset, self.limit, function(success, response)
        if not success or not response then
            UIManager:show(InfoMessage:new {
                text = _("Failed to load library from Folio server."),
                timeout = 4,
            })
            return
        end

        local items = response.items or {}
        local total = response.total or #items

        self:render_menu(items, total)
    end)
end

function FolioBrowser:render_menu(items, total)
    local item_table = {}

    -- Folder navigation: Back to parent series / root
    if self.current_series_id and #self.series_stack > 0 then
        local current = self.series_stack[#self.series_stack]
        local current_name = current and current.name or _("Series")
        table.insert(item_table, {
            text = T(_("📁 .. (Back from %1)"), current_name),
            callback = function()
                table.remove(self.series_stack)
                if #self.series_stack > 0 then
                    self.current_series_id = self.series_stack[#self.series_stack].id
                else
                    self.current_series_id = nil
                end
                self.current_page = 1
                self:load_and_render()
            end,
        })
    end

    -- Sorting options
    local sort_label = self.sort_by == "recent" and _("Recent") or
        (self.sort_by == "sortOrder" and _("Sort Order") or _("Name"))
    table.insert(item_table, {
        text = T(_("🔃 Sort: %1 (tap to change)"), sort_label),
        callback = function()
            self:prompt_sort_by()
        end,
    })

    if #items == 0 then
        table.insert(item_table, {
            text = _("No items found in this location."),
            enabled = false,
        })
    else
        for _, item in ipairs(items) do
            local item_type = item.type or item.item_type or "book"
            local name = item.name or item.title or _("Untitled")

            if item_type == "series" then
                table.insert(item_table, {
                    text = string.format("📁 [Series] %s", name),
                    callback = function()
                        table.insert(self.series_stack, { id = item.id, name = name })
                        self.current_series_id = item.id
                        self.current_page = 1
                        self:load_and_render()
                    end,
                })
            else
                local author = item.author or ""
                local display_text = (author ~= "") and string.format("📖 %s - %s", name, author) or
                    string.format("📖 %s", name)

                table.insert(item_table, {
                    text = display_text,
                    callback = function()
                        self:on_book_selected(item)
                    end,
                })
            end
        end
    end

    -- Pagination controls
    local max_page = math.max(1, math.ceil(total / self.limit))
    if max_page > 1 then
        local nav_text = T(_("Page %1 of %2"), self.current_page, max_page)
        table.insert(item_table, {
            text = "◀ Prev Page | " .. nav_text .. " | Next Page ▶",
            callback = function()
                self:prompt_pagination(max_page)
            end,
        })
    end

    local location_title = (#self.series_stack > 0) and self.series_stack[#self.series_stack].name or _("Folio Library")
    local title_str = T(_("%1 (%2 items)"), location_title, total)
    local menu = Menu:new {
        title = title_str,
        item_table = item_table,
        on_close = function() end,
    }

    UIManager:show(menu)
end

function FolioBrowser:prompt_sort_by()
    local item_table = {
        {
            text = _("Sort by Name"),
            callback = function()
                self.sort_by = "name"
                self.current_page = 1
                self:load_and_render()
            end,
        },
        {
            text = _("Sort by Recently Added"),
            callback = function()
                self.sort_by = "recent"
                self.current_page = 1
                self:load_and_render()
            end,
        },
        {
            text = _("Sort by Series Order"),
            callback = function()
                self.sort_by = "sortOrder"
                self.current_page = 1
                self:load_and_render()
            end,
        },
    }
    local menu = Menu:new {
        title = _("Select Sorting Order"),
        item_table = item_table,
    }
    UIManager:show(menu)
end

function FolioBrowser:prompt_pagination(max_page)
    local item_table = {}
    if self.current_page > 1 then
        table.insert(item_table, {
            text = _("◀ Previous Page"),
            callback = function()
                self.current_page = self.current_page - 1
                self:load_and_render()
            end,
        })
    end
    if self.current_page < max_page then
        table.insert(item_table, {
            text = _("Next Page ▶"),
            callback = function()
                self.current_page = self.current_page + 1
                self:load_and_render()
            end,
        })
    end

    local menu = Menu:new {
        title = _("Select Page"),
        item_table = item_table,
    }
    UIManager:show(menu)
end

function FolioBrowser:on_book_selected(book)
    local book_title = book.name or book.title or "book"
    local default_dir = self.plugin.settings.download_dir

    local item_table = {
        {
            text = T(_("📥 Download to default folder (%1)"), default_dir),
            callback = function()
                self:start_download(book, default_dir)
            end,
        },
        {
            text = _("📁 Choose custom download folder..."),
            callback = function()
                self:prompt_custom_download_dir(book, default_dir)
            end,
        },
    }

    local menu = Menu:new {
        title = T(_("Download '%1'"), book_title),
        item_table = item_table,
    }
    UIManager:show(menu)
end

function FolioBrowser:prompt_custom_download_dir(book, current_dir)
    local dialog
    dialog = InputDialog:new {
        title = _("Custom Download Folder"),
        input = current_dir,
        description = _("Enter folder path on device to save this book:"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "cancel",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Download"),
                    is_default = true,
                    callback = function()
                        local dir = dialog:getInputText()
                        if dir and dir ~= "" then
                            UIManager:close(dialog)
                            self:start_download(book, utils.trim_slash(dir))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function FolioBrowser:start_download(book, download_dir)
    local book_title = book.name or book.title or "book"
    local clean_title = utils.sanitize_filename(book_title)
    local clean_author = utils.sanitize_filename(book.author or "")
    local filename = clean_author ~= "" and (clean_title .. " - " .. clean_author .. ".epub") or (clean_title .. ".epub")
    local target_path = download_dir .. "/" .. filename

    -- Check if file already exists
    local file_exists = false
    local f = io.open(target_path, "r")
    if f then
        f:close()
        file_exists = true
    end

    local confirm_text
    if file_exists then
        confirm_text = T(_("'%1' already exists in '%2'. Redownload from Folio?"), filename, download_dir)
    else
        confirm_text = T(_("Download '%1' to '%2'?"), book_title, download_dir)
    end

    local confirm = ConfirmBox:new {
        text = confirm_text,
        ok_text = file_exists and _("Redownload") or _("Download"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            -- Ensure directory exists safely
            local ok_lfs, lfs_mod = pcall(require, "lfs")
            if ok_lfs and lfs_mod and lfs_mod.mkdir then
                local path_acc = ""
                for part in download_dir:gmatch("[^/\\]+") do
                    if download_dir:sub(1, 1) == "/" and path_acc == "" then
                        path_acc = "/" .. part
                    else
                        path_acc = path_acc == "" and part or (path_acc .. "/" .. part)
                    end
                    lfs_mod.mkdir(path_acc)
                end
            else
                local clean_dir = download_dir:gsub('["`$\\]', "\\%1")
                os.execute("mkdir -p \"" .. clean_dir .. "\"")
            end

            UIManager:show(InfoMessage:new {
                text = T(_("Downloading '%1'..."), book_title),
                timeout = 5,
            })

            self.api:download_book(book.id, target_path, function(success, res)
                if success then
                    local open_box = ConfirmBox:new {
                        text = T(_("'%1' downloaded successfully to:\n%2\n\nDo you want to open it now?"), book_title, download_dir),
                        ok_text = _("Open Book"),
                        cancel_text = _("Close"),
                        ok_callback = function()
                            local Event = require("ui/event")
                            local ReaderUI = require("apps/reader/readerui")
                            UIManager:broadcastEvent(Event:new("SetupShowReader"))
                            ReaderUI:showReader(target_path)
                        end,
                    }
                    UIManager:show(open_box)
                else
                    UIManager:show(InfoMessage:new {
                        text = T(_("Failed to download book: %1"), tostring(res)),
                        timeout = 4,
                    })
                end
            end)
        end,
    }
    UIManager:show(confirm)
end

return FolioBrowser
