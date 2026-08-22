local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local T = require("ffi/util").template
local utils = require("utils")

local FolioBrowser = Menu:extend {
    current_series_id = nil,
    series_stack = nil,
    current_page = 1,
    limit = 15,
    sort_by = "name",
    search_query = nil,
    search_by = nil,
    request_id = 0,
}

function FolioBrowser:init()
    self.paths = {}
    self.item_table = {}

    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function()
        self:prompt_sort_by()
    end

    Menu.init(self)

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

    self.request_id = self.request_id + 1
    self.has_more = true
    self:fetch_items(false)
end

function FolioBrowser:fetch_items(append)
    if self.is_loading then return false end
    if append and not self.has_more then return false end

    self.is_loading = true
    if not append then
        self.current_page = 1
        self.item_table = {}
        -- Folder navigation: Back to parent series / root
        if self.current_series_id and #self.paths > 0 then
            local current = self.paths[#self.paths]
            local current_name = current and current.name or _("Series")
            table.insert(self.item_table, {
                text = T(_("📁 .. (Back from %1)"), current_name),
                is_back = true,
            })
        end

        if self.search_query and self.search_query ~= "" then
            table.insert(self.item_table, {
                text = T(_("🔍 Filter: \"%1\" (Tap to clear)"), self.search_query),
                is_clear_search = true,
            })
        end
    else
        self.current_page = self.current_page + 1
    end

    local current_request = self.request_id
    local offset = (self.current_page - 1) * self.limit

    local success, response = self.api:browse(self.current_series_id, self.sort_by, offset, self.limit, self
        .search_query, self.search_by)
    self.is_loading = false

    -- If the user closed or changed directory while loading, abort rendering
    if current_request ~= self.request_id then return false end

    if not success or not response then
        if not append then
            UIManager:show(InfoMessage:new {
                text = _("Failed to load library from Folio server."),
                timeout = 4,
            })
        end
        self.has_more = false
        return false
    end

    local items = response.items or {}
    local total = response.total or #items

    if #items < self.limit then
        self.has_more = false
    else
        self.has_more = true
    end

    if not append and #items == 0 then
        table.insert(self.item_table, {
            text = _("No items found in this location."),
            enabled = false,
        })
    else
        for _, item in ipairs(items) do
            local item_type = item.type or item.item_type or "book"
            local name = item.name or item.title or _("Untitled")

            if item_type == "series" then
                table.insert(self.item_table, {
                    text = string.format("📁 [Series] %s", name),
                    is_series = true,
                    item = item,
                })
            else
                local is_read = item.progress and (item.progress.isRead or item.progress.is_read)
                local prefix = is_read and "✅ " or "📖 "
                local author = item.author or ""
                local display_text = (author ~= "") and string.format("%s%s - %s", prefix, name, author) or
                    string.format("%s%s", prefix, name)

                table.insert(self.item_table, {
                    text = display_text,
                    is_book = true,
                    item = item,
                })
            end
        end
    end

    local location_title = (#self.paths > 0) and self.paths[#self.paths].name or _("Folio Library")
    local title_str
    if self.search_query and self.search_query ~= "" then
        title_str = T(_("%1 [Search: '%2'] (%3 items)"), location_title, self.search_query, total)
    else
        title_str = T(_("%1 (%2 items)"), location_title, total)
    end

    self:switchItemTable(title_str, self.item_table, append and -1 or nil)
    return true
end

function FolioBrowser:onNextPage(fill_only)
    local page_num = self.page_num
    while page_num == self.page_num do
        if self.has_more then
            if not self:fetch_items(true) then
                break
            end
        else
            break
        end
    end
    if not fill_only then
        Menu.onNextPage(self)
    end
    return true
end

function FolioBrowser:onMenuSelect(item)
    if item.is_clear_search then
        self.search_query = nil
        self.current_page = 1
        self:load_and_render()
    elseif item.is_back then
        self:onReturn()
    elseif item.is_series then
        table.insert(self.paths, { id = item.item.id, name = item.item.name })
        self.current_series_id = item.item.id
        self:load_and_render()
    elseif item.is_book then
        self:on_book_selected(item.item)
    end
    return true
end

function FolioBrowser:onReturn()
    if #self.paths > 0 then
        table.remove(self.paths)
        if #self.paths > 0 then
            self.current_series_id = self.paths[#self.paths].id
        else
            self.current_series_id = nil
        end
        self:load_and_render()
        return true
    else
        if self.close_callback then
            self.close_callback()
        end
        return true
    end
end

function FolioBrowser:prompt_search()
    local dialog
    dialog = InputDialog:new {
        title = _("Search Library"),
        input = self.search_query or "",
        hint = _("Enter search query..."),
        description = _("Search books and series in Folio library"),
        buttons = {
            {
                {
                    text = _("Clear"),
                    callback = function()
                        UIManager:close(dialog)
                        self.search_query = nil
                        self.current_page = 1
                        self:load_and_render()
                    end,
                },
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
                        local query = dialog:getInputText()
                        UIManager:close(dialog)
                        if query and query ~= "" then
                            self.search_query = query
                        else
                            self.search_query = nil
                        end
                        self.current_page = 1
                        self:load_and_render()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function FolioBrowser:prompt_search_by()
    local menu
    local current = self.search_by or "all"
    local item_table = {
        {
            text = _("Search in All fields") .. (current == "all" and " ✓" or ""),
            callback = function()
                UIManager:close(menu)
                self.search_by = "all"
                if self.search_query and self.search_query ~= "" then
                    self.current_page = 1
                    self:load_and_render()
                end
            end,
        },
        {
            text = _("Search in Book Titles") .. (current == "title" and " ✓" or ""),
            callback = function()
                UIManager:close(menu)
                self.search_by = "title"
                if self.search_query and self.search_query ~= "" then
                    self.current_page = 1
                    self:load_and_render()
                end
            end,
        },
        {
            text = _("Search in Authors") .. (current == "author" and " ✓" or ""),
            callback = function()
                UIManager:close(menu)
                self.search_by = "author"
                if self.search_query and self.search_query ~= "" then
                    self.current_page = 1
                    self:load_and_render()
                end
            end,
        },
        {
            text = _("Search in Series Names") .. (current == "series" and " ✓" or ""),
            callback = function()
                UIManager:close(menu)
                self.search_by = "series"
                if self.search_query and self.search_query ~= "" then
                    self.current_page = 1
                    self:load_and_render()
                end
            end,
        },
    }
    menu = Menu:new {
        title = _("Select Search Target"),
        item_table = item_table,
        on_close = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end

function FolioBrowser:prompt_sort_by()
    local menu
    local search_by_label = _("All")
    if self.search_by == "title" then
        search_by_label = _("Titles")
    elseif self.search_by == "author" then
        search_by_label = _("Authors")
    elseif self.search_by == "series" then
        search_by_label = _("Series")
    end

    local item_table = {
        {
            text = (self.search_query and self.search_query ~= "")
                and T(_("🔍 Search: '%1'"), self.search_query)
                or _("🔍 Search Library..."),
            callback = function()
                UIManager:close(menu)
                self:prompt_search()
            end,
        },
        {
            text = T(_("🎯 Search Target: %1"), search_by_label),
            callback = function()
                UIManager:close(menu)
                self:prompt_search_by()
            end,
        },
    }

    if self.search_query and self.search_query ~= "" then
        table.insert(item_table, {
            text = _("❌ Clear Search"),
            callback = function()
                UIManager:close(menu)
                self.search_query = nil
                self.current_page = 1
                self:load_and_render()
            end,
        })
    end

    table.insert(item_table, {
        text = _("Sort by Name") .. (self.sort_by == "name" and " ✓" or ""),
        callback = function()
            UIManager:close(menu)
            self.sort_by = "name"
            self.current_page = 1
            self:load_and_render()
        end,
    })
    table.insert(item_table, {
        text = _("Sort by Recently Added") .. (self.sort_by == "recent" and " ✓" or ""),
        callback = function()
            UIManager:close(menu)
            self.sort_by = "recent"
            self.current_page = 1
            self:load_and_render()
        end,
    })
    table.insert(item_table, {
        text = _("Sort by Series Order") .. (self.sort_by == "sortOrder" and " ✓" or ""),
        callback = function()
            UIManager:close(menu)
            self.sort_by = "sortOrder"
            self.current_page = 1
            self:load_and_render()
        end,
    })
    table.insert(item_table, {
        text = _("Create Series Folders") .. (self.plugin.settings.create_series_folders ~= false and " ✓" or ""),
        callback = function()
            UIManager:close(menu)
            self.plugin.settings.create_series_folders = not (self.plugin.settings.create_series_folders ~= false)
            self.plugin:save_settings()
        end,
    })

    menu = Menu:new {
        title = _("Library Menu"),
        item_table = item_table,
        on_close = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end

function FolioBrowser:get_series_map()
    if self._series_map then
        return self._series_map
    end
    local map = {}
    local success, list = self.api:get_series()
    if success and type(list) == "table" then
        for _, s in ipairs(list) do
            if s.id then
                map[s.id] = s
            end
        end
    end
    self._series_map = map
    return map
end

function FolioBrowser:resolve_series_path(book)
    if self.plugin and self.plugin.settings and self.plugin.settings.create_series_folders == false then
        return nil
    end

    local current_breadcrumb_names = {}
    if self.paths and #self.paths > 0 then
        for _, p in ipairs(self.paths) do
            if p.name and p.name ~= "" then
                table.insert(current_breadcrumb_names, p.name)
            end
        end
    end

    local book_id = book and book.id
    if not book_id then
        if #current_breadcrumb_names > 0 then
            return table.concat(current_breadcrumb_names, "/")
        end
        return nil
    end

    local success, book_detail = self.api:get_book(book_id)
    local series_map = self:get_series_map()

    local series_list = (success and book_detail and type(book_detail.series) == "table") and book_detail.series or {}
    if #series_list == 0 then
        if #current_breadcrumb_names > 0 then
            return table.concat(current_breadcrumb_names, "/")
        end
        return nil
    end

    local function get_ancestor_path(series_id)
        local path = {}
        local curr_id = series_id
        local visited = {}

        while curr_id and not visited[curr_id] do
            visited[curr_id] = true
            local s = series_map[curr_id]
            if not s then
                for _, bs in ipairs(series_list) do
                    if bs.id == curr_id then
                        table.insert(path, 1, bs.name)
                        curr_id = bs.parentId or bs.parent_id
                        s = bs
                        break
                    end
                end
                if not s then
                    break
                end
            else
                table.insert(path, 1, s.name)
                curr_id = s.parentId or s.parent_id
            end
        end
        return path
    end

    local candidate_paths = {}
    for _, s in ipairs(series_list) do
        local p = get_ancestor_path(s.id)
        if #p > 0 then
            table.insert(candidate_paths, p)
        elseif s.name and s.name ~= "" then
            table.insert(candidate_paths, { s.name })
        end
    end

    if #candidate_paths == 0 then
        if #current_breadcrumb_names > 0 then
            return table.concat(current_breadcrumb_names, "/")
        end
        return nil
    end

    -- If currently inside a folder, find candidate path that contains active folder name
    if self.paths and #self.paths > 0 then
        local active_name = self.paths[#self.paths].name
        for _, p in ipairs(candidate_paths) do
            for _, name in ipairs(p) do
                if name == active_name then
                    return table.concat(p, "/")
                end
            end
        end
    end

    -- Otherwise pick the longest / most specific hierarchy path
    table.sort(candidate_paths, function(a, b)
        return #a > #b
    end)

    return table.concat(candidate_paths[1], "/")
end

function FolioBrowser:on_book_selected(book)
    local book_title = book.name or book.title or "book"
    local default_dir = self.plugin.settings.download_dir
    local is_read = book.progress and (book.progress.isRead or book.progress.is_read)

    local menu
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

    if is_read then
        table.insert(item_table, {
            text = _("✗ Mark as Unread on Folio"),
            callback = function()
                self:toggle_book_read_status(book, false, menu)
            end,
        })
    else
        table.insert(item_table, {
            text = _("✓ Mark as Read on Folio"),
            callback = function()
                self:toggle_book_read_status(book, true, menu)
            end,
        })
    end

    menu = Menu:new {
        title = T(_("Actions for '%1'"), book_title),
        item_table = item_table,
        on_close = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end

function FolioBrowser:toggle_book_read_status(book, is_read, parent_menu)
    if parent_menu then
        UIManager:close(parent_menu)
    end
    local book_title = book.name or book.title or _("book")
    self.api:update_progress(book.id, nil, nil, is_read, function(success)
        if success then
            if not book.progress then
                book.progress = {}
            end
            book.progress.isRead = is_read
            book.progress.is_read = is_read
            local msg = is_read and T(_("Marked '%1' as read on Folio."), book_title)
                or T(_("Marked '%1' as unread on Folio."), book_title)
            utils.show_msg(msg)

            -- Also try to update local document if it's already downloaded on device
            local default_dir = self.plugin.settings.download_dir
            local clean_title = utils.sanitize_filename(book_title)
            local clean_author = utils.sanitize_filename(book.author or "")
            local filename = clean_author ~= "" and (clean_title .. " - " .. clean_author .. ".epub") or (clean_title .. ".epub")
            local series_path = self:resolve_series_path(book)
            local target_dir = utils.build_book_target_dir(default_dir, series_path)
            local local_path = target_dir .. "/" .. filename
            if self.plugin.manager and self.plugin.manager.set_local_read_status then
                self.plugin.manager:set_local_read_status(local_path, is_read)
                if target_dir ~= default_dir then
                    self.plugin.manager:set_local_read_status(default_dir .. "/" .. filename, is_read)
                end
            end

            -- Re-render browser to update checkmarks
            self:load_and_render()
        else
            utils.show_msg(_("Failed to update read status on Folio."))
        end
    end)
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

    local series_path = self:resolve_series_path(book)
    local target_dir = utils.build_book_target_dir(download_dir, series_path)
    local target_path = target_dir .. "/" .. filename

    -- Check if file already exists
    local file_exists = false
    local f = io.open(target_path, "r")
    if f then
        f:close()
        file_exists = true
    end

    local confirm_text
    if file_exists then
        confirm_text = T(_("'%1' already exists in '%2'. Redownload from Folio?"), filename, target_dir)
    else
        confirm_text = T(_("Download '%1' to '%2'?"), book_title, target_dir)
    end

    local confirm = ConfirmBox:new {
        text = confirm_text,
        ok_text = file_exists and _("Redownload") or _("Download"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            utils.ensure_dir(target_dir)

            UIManager:show(InfoMessage:new {
                text = T(_("Downloading '%1'..."), book_title),
                timeout = 5,
            })

            self.api:download_book(book.id, target_path, function(success, res)
                if success then
                    -- Trigger a filemanager refresh so the downloaded book appears immediately
                    local Event = require("ui/event")
                    UIManager:broadcastEvent(Event:new("Refresh"))

                    local open_box = ConfirmBox:new {
                        text = T(_("'%1' downloaded successfully to:\n%2\n\nDo you want to open it now?"), book_title, target_dir),
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
