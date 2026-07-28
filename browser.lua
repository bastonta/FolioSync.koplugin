local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local T = require("ffi/util").template
local logger = require("logger")
local utils = require("utils")

local FolioBrowser = {}

function FolioBrowser:new(plugin_instance)
    local o = {
        plugin = plugin_instance,
        api = plugin_instance.api,
        current_page = 1,
        limit = 15,
        search_query = "",
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function FolioBrowser:show()
    self.current_page = 1
    self.search_query = ""
    self:load_and_render()
end

function FolioBrowser:load_and_render()
    if not self.plugin.settings.token or self.plugin.settings.token == "" then
        UIManager:show(InfoMessage:new{
            text = _("Please log in to your Folio server first in Settings."),
            timeout = 4,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Fetching library from Folio..."),
        timeout = 2,
    })

    self.api:list_books(self.current_page, self.limit, self.search_query, function(success, response)
        if not success or not response then
            UIManager:show(InfoMessage:new{
                text = _("Failed to load books from Folio server."),
                timeout = 4,
            })
            return
        end

        local books = response.items or {}
        local total = response.total or #books

        self:render_menu(books, total)
    end)
end

function FolioBrowser:render_menu(books, total)
    local item_table = {}

    -- Top controls: Search & Refresh
    table.insert(item_table, {
        text = self.search_query == "" and _("🔍 Search books...") or T(_("🔍 Filter: %1 (tap to clear)"), self.search_query),
        callback = function()
            if self.search_query ~= "" then
                self.search_query = ""
                self.current_page = 1
                self:load_and_render()
            else
                self:prompt_search()
            end
        end,
    })

    if #books == 0 then
        table.insert(item_table, {
            text = _("No books found on Folio server."),
            enabled = false,
        })
    else
        for _, book in ipairs(books) do
            local title = book.title or _("Untitled")
            local author = book.author or _("Unknown Author")
            local progress_str = ""
            if book.progress and book.progress.progressPercent then
                progress_str = string.format(" [%d%%]", math.floor(book.progress.progressPercent))
            end

            local display_text = string.format("%s - %s%s", title, author, progress_str)

            table.insert(item_table, {
                text = display_text,
                callback = function()
                    self:on_book_selected(book)
                end,
            })
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

    local title_str = T(_("Folio Library (%1 books)"), total)
    local menu = Menu:new{
        title = title_str,
        item_table = item_table,
        on_close = function() end,
    }

    UIManager:show(menu)
end

function FolioBrowser:prompt_search()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Folio Library"),
        input = self.search_query,
        buttons = {
            {
                text = _("Cancel"),
                id = "cancel",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Search"),
                is_default = true,
                callback = function()
                    self.search_query = dialog:getInputText()
                    self.current_page = 1
                    UIManager:close(dialog)
                    self:load_and_render()
                end,
            },
        },
    }
    UIManager:show(dialog)
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

    local menu = Menu:new{
        title = _("Select Page"),
        item_table = item_table,
    }
    UIManager:show(menu)
end

function FolioBrowser:on_book_selected(book)
    local download_dir = self.plugin.settings.download_dir or "/sdcard/books/FolioSync"
    local clean_title = utils.sanitize_filename(book.title or "book")
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
        confirm_text = T(_("'%1' already exists on device. Redownload from Folio?"), filename)
    else
        confirm_text = T(_("Download '%1' from Folio server to '%2'?"), book.title, download_dir)
    end

    local confirm = ConfirmBox:new{
        text = confirm_text,
        ok_text = file_exists and _("Redownload") or _("Download"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            -- Ensure directory exists
            lfs = pcall(require, "lfs")
            os.execute("mkdir -p \"" .. download_dir .. "\"")

            UIManager:show(InfoMessage:new{
                text = T(_("Downloading '%1'..."), book.title),
                timeout = 5,
            })

            self.api:download_book(book.id, target_path, function(success, res)
                if success then
                    local open_box = ConfirmBox:new{
                        text = T(_("'%1' downloaded successfully!\n\nDo you want to open it now?"), book.title),
                        ok_text = _("Open Book"),
                        cancel_text = _("Close"),
                        ok_callback = function()
                            local Dispatcher = require("dispatcher")
                            Dispatcher:sendEvent(Event:new("OpenDocument", target_path))
                        end,
                    }
                    UIManager:show(open_box)
                else
                    UIManager:show(InfoMessage:new{
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
