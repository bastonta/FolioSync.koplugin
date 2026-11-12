local _ = require("gettext")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local Event = require("ui/event")
local logger = require("logger")
local annotations_helper = require("annotations")
local ChaptersBook = require("chapters_book")
local ChaptersEpub = require("chapters_epub")
local utils = require("utils")

local Manager = {}

function Manager:new(plugin_instance)
    local o = {
        plugin = plugin_instance,
        api = plugin_instance.api,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Load sync state snapshot from <book>.sdr/folio_sync_state.json
function Manager:load_sync_state(file_path)
    local empty = { has_synced_annos = false, has_synced_bms = false, annotations = {}, bookmarks = {}, pending_sessions = {} }
    if not file_path or type(file_path) ~= "string" or file_path == "" then return empty end

    local sdr_dir = file_path:match("^(.*)%.%w+$") and (file_path:match("^(.*)%.%w+$") .. ".sdr")
    if not sdr_dir then return empty end

    local sdr_path = sdr_dir .. "/folio_sync_state.json"
    local f = io.open(sdr_path, "r")
    if not f then return empty end

    local content = f:read("*a")
    f:close()
    if not content or content == "" then return empty end

    local json = require("json")
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
        data.annotations = data.annotations or {}
        data.bookmarks = data.bookmarks or {}
        data.pending_sessions = data.pending_sessions or {}
        return data
    end
    return empty
end

-- Save sync state snapshot to <book>.sdr/folio_sync_state.json
function Manager:save_sync_state(state_or_path, file_path_or_state)
    local state = type(state_or_path) == "table" and state_or_path or file_path_or_state
    local file_path = type(state_or_path) == "string" and state_or_path or file_path_or_state
    if not file_path or type(file_path) ~= "string" or file_path == "" or type(state) ~= "table" then return false end
    local sdr_dir = file_path:match("^(.*)%.%w+$") and (file_path:match("^(.*)%.%w+$") .. ".sdr")
    if not sdr_dir then return false end

    local json = require("json")
    local ok, encoded = pcall(json.encode, state)
    if not ok or not encoded then return false end

    pcall(function()
        local lfs_mod = package.loaded["lfs"] or package.loaded["libs/libkoreader-lfs"]
        if lfs_mod and lfs_mod.mkdir then lfs_mod.mkdir(sdr_dir) end
    end)

    local sdr_path = sdr_dir .. "/folio_sync_state.json"
    local f = io.open(sdr_path, "w")
    if not f then return false end
    f:write(encoded)
    f:close()
    return true
end

-- Invalidate the annotation / bookmark snapshot when folio_book_id is missing from
-- docsettings (the next sync then starts as an initial, safe merge). Reading sessions
-- recorded while offline are not part of the snapshot: they stay queued.
function Manager:invalidate_sync_state(file_path)
    if not file_path or file_path == "" then return end
    local sdr_dir = file_path:match("^(.*)%.%w+$") and (file_path:match("^(.*)%.%w+$") .. ".sdr")
    if not sdr_dir then return end
    local sdr_path = sdr_dir .. "/folio_sync_state.json"
    if not utils.file_exists(sdr_path) then return end

    local state = self:load_sync_state(file_path)
    local pending = type(state.pending_sessions) == "table" and state.pending_sessions or {}
    if #pending == 0 then
        os.remove(sdr_path)
        return
    end
    if not (state.has_synced_annos or state.has_synced_bms or next(state.annotations) or next(state.bookmarks)) then
        return
    end
    self:save_sync_state({
        has_synced_annos = false,
        has_synced_bms = false,
        annotations = {},
        bookmarks = {},
        pending_sessions = pending,
    }, file_path)
end

-- ================= LOCAL FILE INDEX =================
-- What the plugin knows about files on this device, by path: the SHA-256 of the content
-- (hashing a book takes seconds on an e-reader, so it is done once per version of the
-- file) and the server book a file was downloaded as. An entry is only valid for the
-- size and modification time it was recorded with. One index for every plugin instance
-- (the file browser and each opened book have their own).

local file_index

local function file_index_path()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and type(DataStorage) == "table" and DataStorage.getSettingsDir then
        local ok_dir, dir = pcall(DataStorage.getSettingsDir, DataStorage)
        if ok_dir and type(dir) == "string" and dir ~= "" then
            return dir .. "/folio_file_index.json"
        end
    end
    return nil
end

function Manager:load_file_index()
    if not file_index then
        local path = file_index_path()
        local data = path and utils.file_exists(path) and utils.read_json(path) or nil
        file_index = type(data) == "table" and data or {}
    end
    return file_index
end

-- The index entry of a file, or nil when there is none for the file as it is now.
function Manager:file_index_entry(file_path)
    if type(file_path) ~= "string" or file_path == "" then return nil end
    local entry = self:load_file_index()[file_path]
    if type(entry) ~= "table" then return nil end
    local size, mtime = utils.file_stat(file_path)
    if not size or entry.size ~= size or (entry.mtime ~= nil and mtime ~= nil and entry.mtime ~= mtime) then
        return nil
    end
    return entry
end

-- Records `fields` (sha256, book_id) for the file as it is now.
function Manager:update_file_index(file_path, fields)
    local size, mtime = utils.file_stat(file_path)
    if not size then return false end
    local index = self:load_file_index()
    local entry = self:file_index_entry(file_path) or {}
    entry.size, entry.mtime = size, mtime
    for key, value in pairs(fields) do entry[key] = value end
    index[file_path] = entry

    -- Files that are gone do not need an entry
    local count = 0
    for _ in pairs(index) do count = count + 1 end
    if count > 500 then
        for path in pairs(index) do
            if path ~= file_path and not utils.file_exists(path) then index[path] = nil end
        end
    end

    local path = file_index_path()
    return path ~= nil and utils.write_json(path, index)
end

-- SHA-256 of a file, computed once per version of the file.
function Manager:get_file_hash(file_path)
    local entry = self:file_index_entry(file_path)
    if entry and type(entry.sha256) == "string" and entry.sha256 ~= "" then
        return entry.sha256
    end
    local file_hash = self:compute_file_hash(file_path)
    if type(file_hash) == "string" and file_hash ~= "" then
        pcall(self.update_file_index, self, file_path, { sha256 = file_hash })
        return file_hash
    end
    return nil
end

-- Compute SHA-256 hash of a file (matches Folio server algorithm)
function Manager:compute_file_hash(file_path)
    -- Try to load sha2 from KOReader's ffi/sha2 or fallback to external
    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok or not sha2 or not sha2.sha256 then
        sha2 = nil
    end

    if sha2 then
        local f = io.open(file_path, "rb")
        if not f then return nil end

        local CHUNK_SIZE = 65536

        if type(sha2.new) == "function" then
            local success, hash_obj = pcall(sha2.new)
            if success and hash_obj then
                while true do
                    local chunk = f:read(CHUNK_SIZE)
                    if not chunk or #chunk == 0 then break end
                    hash_obj:update(chunk)
                end
                f:close()
                return hash_obj:digest("hex")
            end
        end

        local content = f:read("*a")
        f:close()
        if content then
            return sha2.sha256(content)
        end
    end

    -- Fallback: use sha256sum command if available
    local safe_path = file_path:gsub('["`$]', '\\%1')
    local cmd = string.format('sha256sum "%s" 2>/dev/null', safe_path)
    local handle = io.popen(cmd)
    if not handle then return nil end

    local result = handle:read("*a")
    handle:close()

    if result and result ~= "" then
        return result:match("^(%x+)")
    end

    return nil
end

-- Extract document metadata and settings from whatever object is available (ReaderUI, Document, or DocSettings)
function Manager:get_doc_info(ui, document)
    local target_ui = ui or (self.plugin and self.plugin.get_ui and self.plugin:get_ui()) or self.ui
    local target_doc = document or (target_ui and target_ui.document)

    local file_path = nil
    local title = nil
    local total_pages = 1
    local current_page = 1
    local location = nil
    local percent = 0
    local docsettings = nil
    local authors = nil

    -- 1. Try target_doc
    if target_doc then
        if type(target_doc) == "table" or type(target_doc) == "userdata" then
            if target_doc.file then file_path = target_doc.file end
            if target_doc.getPageCount then
                local ok, count = pcall(function() return target_doc:getPageCount() end)
                if ok and count then total_pages = count end
            end
            if target_doc.docsettings then docsettings = target_doc.docsettings end
        end
    end

    -- 2. Try target_ui
    if target_ui then
        if not file_path and target_ui.document and target_ui.document.file then
            file_path = target_ui.document.file
        end
        if total_pages == 1 and target_ui.document and target_ui.document.getPageCount then
            local ok, count = pcall(function() return target_ui.document:getPageCount() end)
            if ok and count then total_pages = count end
        end
        if target_ui.getCurrentPage then
            local ok, page = pcall(function() return target_ui:getCurrentPage() end)
            if ok and page then current_page = page end
        end

        local paging_module = target_ui.paging or target_ui.rolling
        if paging_module then
            if paging_module.getLastPercent then
                local ok, p = pcall(function() return paging_module:getLastPercent() end)
                if ok and p then
                    percent = utils.fraction_to_percent(p)
                end
            end
            if paging_module.getLastProgress then
                local ok, pos = pcall(function() return paging_module:getLastProgress() end)
                if ok and pos then location = pos end
            end
        end
        -- While a page turn is being announced, ReaderRolling still holds the XPointer of
        -- the page that was left: ask the document where it is now.
        if target_ui.rolling and target_ui.document and target_ui.document.getXPointer then
            local ok, xpointer = pcall(function() return target_ui.document:getXPointer() end)
            if ok and type(xpointer) == "string" and xpointer ~= "" then
                location = xpointer
            end
        end
        if type(target_ui.doc_props) == "table" then
            title = type(target_ui.doc_props.title) == "string" and target_ui.doc_props.title ~= ""
                and target_ui.doc_props.title or title
            authors = type(target_ui.doc_props.authors) == "string" and target_ui.doc_props.authors or authors
        end

        if not docsettings and target_ui.doc_settings then
            docsettings = target_ui.doc_settings
        end
        if not docsettings and target_ui.docsettings then
            docsettings = target_ui.docsettings
        end
    end

    -- 3. Check DocSettings object directly (if target_ui or target_doc IS a DocSettings instance)
    local ds_candidate = docsettings or (target_ui and target_ui.data and target_ui) or
        (target_doc and target_doc.data and target_doc)
    if ds_candidate and ds_candidate.data then
        local data = ds_candidate.data
        if not file_path and data.doc_path then
            file_path = data.doc_path
        end
        if not title and data.doc_props and data.doc_props.title then
            title = data.doc_props.title
        end
        if not authors and type(data.doc_props) == "table" and type(data.doc_props.authors) == "string" then
            authors = data.doc_props.authors
        end
        if total_pages == 1 and data.doc_pages then
            total_pages = data.doc_pages
        end
        if not location and data.last_xpointer then
            location = data.last_xpointer
        end
        if percent == 0 and data.percent_finished then
            percent = utils.fraction_to_percent(data.percent_finished)
        end
        if not docsettings then
            docsettings = ds_candidate
        end
    end

    -- Fallbacks: try UIManager stack if file_path is still missing
    if not file_path then
        local ok, UIMgr = pcall(require, "ui/uimanager")
        if ok and UIMgr then
            local stack = UIMgr._stack or UIMgr.stack or {}
            for i = #stack, 1, -1 do
                local widget = stack[i]
                if widget then
                    if widget.document and widget.document.file then
                        file_path = widget.document.file
                        target_ui = widget
                        target_doc = widget.document
                        if widget.getCurrentPage then
                            local ok_p, page = pcall(function() return widget:getCurrentPage() end)
                            if ok_p and page then current_page = page end
                        end
                        local paging = widget.paging or widget.rolling
                        if paging then
                            if percent == 0 and paging.getLastPercent then
                                local ok_pct, p = pcall(function() return paging:getLastPercent() end)
                                if ok_pct and p then
                                    percent = utils.fraction_to_percent(p)
                                end
                            end
                            if not location and paging.getLastProgress then
                                local ok_pos, pos = pcall(function() return paging:getLastProgress() end)
                                if ok_pos and pos then location = pos end
                            end
                        end
                        break
                    elseif widget.doc_settings and widget.doc_settings.data and widget.doc_settings.data.doc_path then
                        file_path = widget.doc_settings.data.doc_path
                        docsettings = widget.doc_settings
                        target_ui = widget
                        break
                    end
                end
            end
        end
    end

    if not file_path then
        return nil
    end

    -- Whether the title comes from the book's metadata (a file name is not one)
    local has_metadata_title = type(title) == "string" and title ~= ""
    if not has_metadata_title then
        title = utils.get_file_basename(file_path):gsub("%.%w+$", "")
    end
    if type(location) == "table" then
        location = location.xpointer or location.location or (location.page and string.format("page_%d", location.page)) or
            tostring(location)
    elseif type(location) == "number" then
        -- Paged documents report their position as a page number
        location = string.format("page_%d", location)
    end
    if not location and current_page then
        location = string.format("page_%d", current_page)
    end
    -- `percent` is in 0..100 from here on (converted where it was read, see
    -- utils.fraction_to_percent): it must not be scaled again.
    if current_page == 1 and total_pages > 1 then
        percent = 0.0
    elseif percent == 0 and total_pages > 0 and current_page > 1 then
        percent = ((current_page - 1) / total_pages) * 100
    end

    local is_read = false
    if docsettings and docsettings.readSetting then
        local summary = docsettings:readSetting("summary")
        if summary and summary.status == "complete" then
            is_read = true
        end
    end
    if not is_read and percent >= 100 then
        is_read = true
    end

    return {
        file = file_path,
        file_path = file_path,
        title = title,
        has_metadata_title = has_metadata_title,
        authors = authors,
        total_pages = total_pages,
        current_page = current_page,
        location = location,
        percent = percent,
        is_read = is_read,
        docsettings = docsettings,
        ui = target_ui,
        document = target_doc,
    }
end

-- Check if document is marked as read/finished locally in KOReader
function Manager:get_doc_read_status(info)
    if not info then return false end
    if info.docsettings and info.docsettings.readSetting then
        local summary = info.docsettings:readSetting("summary")
        if summary and summary.status then
            if summary.status == "complete" then
                return true
            elseif summary.status == "reading" or summary.status == "abandoned" then
                return false
            end
        end
    end
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl and BookList and BookList.getBookStatus and (info.file or info.file_path) then
        local status = BookList.getBookStatus(info.file or info.file_path)
        if status == "complete" then
            return true
        elseif status == "reading" or status == "abandoned" then
            return false
        end
    end
    if info.percent and info.percent >= 100 then
        return true
    end
    return false
end

-- Update KOReader local sidecar and BookList cache read status
function Manager:set_local_read_status(info_or_file, is_read, docsettings)
    local file_path = nil
    local ds = docsettings
    if type(info_or_file) == "table" then
        file_path = info_or_file.file or info_or_file.file_path
        ds = ds or info_or_file.docsettings
    elseif type(info_or_file) == "string" then
        file_path = info_or_file
    end

    local status = is_read and "complete" or "reading"

    -- 1. Update docsettings
    if not ds and file_path then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and DocSettings and DocSettings.open then
            pcall(function() ds = DocSettings:open(file_path) end)
        end
    end

    if ds and ds.readSetting and ds.saveSetting then
        local summary = ds:readSetting("summary") or {}
        summary.status = status
        summary.modified = os.date("%Y-%m-%d", os.time())
        ds:saveSetting("summary", summary)
        if ds.flush then
            pcall(function() ds:flush() end)
        end
    end

    -- 2. Update KOReader BookList cache
    if file_path then
        local ok_bl, BookList = pcall(require, "ui/widget/booklist")
        if ok_bl and BookList and BookList.setBookInfoCacheProperty then
            pcall(function() BookList.setBookInfoCacheProperty(file_path, "status", status) end)
        end
    end
end

-- How long background sync leaves a file alone after the server did not know it
local UNMATCHED_RETRY_SECONDS = 600

-- The user asked for something: earlier failures must not hold it back.
function Manager:user_requested()
    self._unmatched = {}
    self._scope_checked = {}
    if type(self.api.reset_backoff) == "function" then
        self.api:reset_backoff()
    end
end

-- Get or resolve Folio book_id for current document
function Manager:resolve_book_id(ui_or_doc, callback_or_doc, maybe_callback)
    local ui = self.ui
    local document
    local callback

    if type(callback_or_doc) == "function" then
        callback = callback_or_doc
        if ui_or_doc and (type(ui_or_doc) == "table" or type(ui_or_doc) == "userdata") and ui_or_doc.file then
            document = ui_or_doc
        else
            ui = ui_or_doc
        end
    else
        ui = ui_or_doc
        document = callback_or_doc
        callback = maybe_callback
    end

    local info = self:get_doc_info(ui, document)
    if not info or not info.file then
        if callback then callback(nil) end
        return nil
    end

    -- 1. Check if stored in docsettings
    if info.docsettings and info.docsettings.readSetting then
        local stored_id = info.docsettings:readSetting("folio_book_id")
        if stored_id and stored_id ~= "" then
            if callback then callback(stored_id) end
            return stored_id
        end
    end

    -- folio_book_id was not found in docsettings — metadata was deleted/reset
    -- Invalidate sync state so next sync starts as initial merge (safe merge)
    self:invalidate_sync_state(info.file or info.file_path)

    local function bind(book_id)
        if self._unmatched then self._unmatched[info.file] = nil end
        if info.docsettings and info.docsettings.saveSetting then
            info.docsettings:saveSetting("folio_book_id", book_id)
        end
        if callback then callback(book_id) end
        return book_id
    end

    -- 1b. A book assembled on this device from Folio chapters knows its book id
    -- (its file exists nowhere on the server, so the hash would never match)
    local layout = self:get_chapters_layout(info.file)
    if layout and layout.book_id then
        return bind(layout.book_id)
    end

    -- 1c. A file this plugin downloaded is the book it was downloaded as
    local entry = self:file_index_entry(info.file)
    if entry and type(entry.book_id) == "string" and entry.book_id ~= "" then
        return bind(entry.book_id)
    end

    -- The server did not know this file a moment ago: asking again on every page turn
    -- would only block the reader
    self._unmatched = self._unmatched or {}
    local failed_at = self._unmatched[info.file]
    if failed_at and os.time() - failed_at < UNMATCHED_RETRY_SECONDS then
        if callback then callback(nil) end
        return nil
    end

    local function unmatched()
        self._unmatched[info.file] = os.time()
        if callback then callback(nil) end
    end

    -- 2. Try to match by file hash via Folio API
    local file_hash = self:get_file_hash(info.file)
    if file_hash then
        self.api:find_book_by_hash(file_hash, function(success, response, code)
            if success and type(response) == "table" and response.id then
                bind(response.id)
            elseif response == "not_found" or code == 404 then
                -- 3. Fallback: the same book in another edition, by title and author
                self:resolve_book_id_by_info(info, function(book_id)
                    if book_id then bind(book_id) else unmatched() end
                end)
            elseif code ~= nil then
                unmatched()
            else
                -- The server could not be reached: nothing is known yet
                if callback then callback(nil) end
            end
        end)
    else
        -- Hash computation failed, fall back to title search
        self:resolve_book_id_by_info(info, function(book_id)
            if book_id then bind(book_id) else unmatched() end
        end)
    end
end

-- One spelling for titles and names that are compared: case, punctuation and spacing
-- differ between a file's metadata, its name and the server's catalog.
local function match_key(value)
    if type(value) ~= "string" then return "" end
    local key = value:lower():gsub("[%c%p]+", " "):gsub("%s+", " ")
    return (key:gsub("^ ", ""):gsub(" $", ""))
end

-- Whether a catalog item is the book described by `info`: the title must be the same,
-- and so must the author where both sides name one.
local function is_same_book(info, item)
    local item_title = match_key(item.title or item.name)
    if item_title == "" then return false end
    local item_author = match_key(item.author)

    if not info.has_metadata_title then
        -- Only the file name is known: `<title>` or `<title> - <author>`, as this plugin
        -- and the Folio server name the files they write
        local stem = match_key(info.title)
        return stem == item_title
            or (item_author ~= "" and stem == match_key((item.title or item.name) .. " - " .. item.author))
    end

    if match_key(info.title) ~= item_title then return false end
    local authors = match_key(info.authors)
    if authors == "" or item_author == "" then return true end
    return authors:find(item_author, 1, true) ~= nil or item_author:find(authors, 1, true) ~= nil
end

-- Fallback: resolve book_id by title search using doc info. A search returns everything
-- that merely contains the words ("Dune" finds "Dune Messiah"), so a result only counts
-- when it is the same book, and the only such book.
function Manager:resolve_book_id_by_info(info, callback)
    self.api:list_books(1, 50, info.title, function(success, response)
        local matched
        if success and type(response) == "table" and type(response.items) == "table" then
            for _, item in ipairs(response.items) do
                if type(item) == "table" and item.id and is_same_book(info, item) then
                    if matched and matched ~= item.id then
                        logger.info("FolioSync: several books on the server are called", info.title)
                        matched = nil
                        break
                    end
                    matched = item.id
                end
            end
        end
        if callback then callback(matched) end
    end)
end

-- Chapter layout of a book assembled on this device from Folio chapters (a `Chapters`
-- book); nil for regular files. Cached: it is consulted on every progress sync.
function Manager:get_chapters_layout(file_path)
    if type(file_path) ~= "string" or file_path == "" then return nil end
    self._chapters_layouts = self._chapters_layouts or {}
    local cached = self._chapters_layouts[file_path]
    if cached == nil then
        local ok, layout = pcall(ChaptersBook.load_layout, file_path)
        cached = (ok and layout) or false
        self._chapters_layouts[file_path] = cached
    end
    return cached or nil
end

-- Location to send to the server for the current reading position. The server knows the
-- position of a Chapters book only as `ch:<chapterId>`; nil means "percentage only".
function Manager:outgoing_location(info)
    local layout = self:get_chapters_layout(info.file or info.file_path)
    if not layout then
        return info.location
    end
    return ChaptersBook.outgoing_location(layout, info.location)
end

-- Percentage to send to the server for a local one. The server counts in the whole book,
-- a copy of a single volume counts in itself; any other book is sent as it is.
function Manager:outgoing_percent(info, percent)
    if percent == nil then percent = info.percent end
    local layout = self:get_chapters_layout(info.file or info.file_path)
    if not layout then
        return percent
    end
    return ChaptersBook.to_book_percent(layout, percent)
end

-- Whether the document is a copy of a volume that ends before the book does: finishing
-- it says nothing about the book, so its read status stays on the device.
function Manager:is_partial_copy(info)
    local layout = info and self:get_chapters_layout(info.file or info.file_path)
    return layout ~= nil and not ChaptersBook.ends_book(layout)
end

-- ================= READING POSITION =================
-- The server keeps one position per book and the time it was changed; the newer change
-- wins on both sides. What this device knows is kept in the book's settings, next to the
-- position itself (so both are saved, and lost, together):
--   at     — device time (epoch) when the position was last changed by reading here;
--            nil when it never was while this plugin was looking
--   server — `updatedAt` of the server's row while the local position is the same one;
--            nil once the reader moved on
--   read   — the read flag as of the last exchange with the server

local PROGRESS_KEY = "folio_progress"
-- Two clocks are compared (device and server, brought together by the `Date` header of
-- the server's responses, which has a resolution of one second)
local CLOCK_SLACK_SECONDS = 2
-- How long the place of a volume copy in its book is trusted before it is asked again
local SCOPE_REFRESH_SECONDS = 600

function Manager:progress_state(docsettings)
    local state = docsettings and docsettings.readSetting and docsettings:readSetting(PROGRESS_KEY)
    return type(state) == "table" and state or {}
end

function Manager:save_progress_state(docsettings, state, flush)
    if not (docsettings and docsettings.saveSetting) then return end
    docsettings:saveSetting(PROGRESS_KEY, state)
    if flush and docsettings.flush then
        pcall(function() docsettings:flush() end)
    end
end

-- The reader moved (a page was turned): the local position is newer than anything the
-- server was told. Costs nothing: KOReader saves it with the position.
function Manager:note_position_changed(ui)
    local docsettings = ui and (ui.doc_settings or ui.docsettings)
    if not (docsettings and docsettings.saveSetting) then return end
    local state = self:progress_state(docsettings)
    state.at = utils.now()
    state.server = nil
    self:save_progress_state(docsettings, state)
end

-- Server clock minus device clock, in seconds (0 until a response told us).
function Manager:clock_offset()
    local offset = type(self.api.clock_offset) == "function" and self.api:clock_offset() or nil
    return tonumber(offset) or 0
end

-- Whether a pushed position has to be checked against the server first: the server
-- is one that writes whatever it is sent, or its clock is not known yet.
function Manager:needs_remote_check()
    if type(self.api.conditional_progress) == "function" and self.api:conditional_progress() == false then
        return true
    end
    return type(self.api.clock_offset) == "function" and self.api:clock_offset() == nil
end

local function remote_updated_at(remote)
    local value = type(remote) == "table" and (remote.updatedAt or remote.updated_at) or nil
    return type(value) == "string" and value ~= "" and value or nil
end

-- Whether the server's position was changed after the local one.
function Manager:remote_is_newer(state, remote)
    local updated_at = remote_updated_at(remote)
    if state.server ~= nil then
        -- Nothing moved here since the last exchange: any other row is a later one
        return updated_at ~= state.server
    end
    if not state.at then
        -- The local position was never changed by reading while the plugin was looking
        return true
    end
    local remote_epoch = utils.parse_iso8601(updated_at)
    if not remote_epoch then
        return false
    end
    return remote_epoch > state.at + self:clock_offset() + CLOCK_SLACK_SECONDS
end

--[[--
Brings what a volume copy knows about its place in the book up to date (see
ChaptersBook.current_scope). Returns false when the server could not be asked: the copy
then must not call the book finished, nor shift bookmarks and annotations.
]]
function Manager:refresh_volume_scope(file_path)
    local layout = self:get_chapters_layout(file_path)
    if not ChaptersBook.is_volume_copy(layout) then return true end

    self._scope_checked = self._scope_checked or {}
    local checked_at = self._scope_checked[file_path]
    if checked_at and os.time() - checked_at < SCOPE_REFRESH_SECONDS then
        return true
    end

    local ok, scope, changed, code = pcall(ChaptersBook.current_scope, self.api, layout)
    if not ok then
        return false
    end
    if type(scope) ~= "table" then
        -- A server that cannot list volumes (any more) has nothing newer to say
        if code == 403 or code == 404 then
            self._scope_checked[file_path] = os.time()
            return true
        end
        return false
    end
    self._scope_checked[file_path] = os.time()
    if changed == true then
        logger.info("FolioSync: the book of", file_path, "changed around this volume")
        ChaptersBook.save_layout(file_path, layout.book_id, layout.chapter_ids, scope)
        if self._chapters_layouts then self._chapters_layouts[file_path] = nil end
    end
    return true
end

--[[--
Sends the local reading position to the server.

opts.force: the user asked for it — the position is sent as changed right now.
opts.read: set the read flag to this value (the user toggled it).
opts.flush: write the book's settings afterwards (KOReader has already saved them).

callback(ok, applied, data): `applied` is false when the server kept a newer position of
its own; `data` is the server's row.
]]
function Manager:push_progress(info, book_id, opts, callback)
    opts = opts or {}
    local function done(...)
        if callback then callback(...) end
    end

    local file_path = info.file or info.file_path
    local scope_known = self:refresh_volume_scope(file_path)
    local docsettings = info.docsettings
    local state = self:progress_state(docsettings)

    local local_read = self:get_doc_read_status(info)
    if opts.read ~= nil then local_read = opts.read end
    -- A finished volume is not a finished book: the book's read flag is left alone
    local partial = self:is_partial_copy(info) or not scope_known
    local read_changed = not partial
        and (opts.read ~= nil or (state.read == nil and local_read) or (state.read ~= nil and state.read ~= local_read))

    local changed_at
    if opts.force or opts.read ~= nil then
        changed_at = utils.now()
    elseif state.server ~= nil and not read_changed then
        -- The server has this position already
        return done(true, true)
    elseif state.at and state.server == nil then
        changed_at = state.at
    elseif read_changed then
        -- (the book was finished, or opened again, without the position moving)
        changed_at = utils.now()
    else
        -- The position on screen was not produced by reading here: not ours to send
        return done(true, false)
    end

    local percent = self:outgoing_percent(info)
    local location = self:outgoing_location(info)
    local read_flag = nil
    if read_changed or (opts.force and not partial) then
        read_flag = local_read
    end

    local function put()
        local updated_at = utils.iso8601_ms(changed_at + self:clock_offset())
        self.api:update_progress(book_id, location, percent, read_flag, function(ok, data)
            if not ok then
                return done(false)
            end
            data = type(data) == "table" and data or nil
            local applied = not (data and data.applied == false)
            -- Read again: the request ran on the UI thread, but be safe about what moved
            local current = self:progress_state(docsettings)
            if applied then
                if current.at == state.at then
                    current.server = remote_updated_at(data)
                    if opts.force or opts.read ~= nil or not current.at then
                        current.at = changed_at
                    end
                end
                if read_flag ~= nil then current.read = read_flag end
            end
            if data and read_flag == nil and not partial and type(data.isRead) == "boolean" then
                -- Nothing was claimed about the flag here: it is the server's
                if data.isRead ~= local_read then
                    self:set_local_read_status(info, data.isRead, docsettings)
                end
                current.read = data.isRead
            end
            self:save_progress_state(docsettings, current, opts.flush)
            done(true, applied, data)
        end, { updated_at = updated_at })
    end

    if not opts.force and opts.read == nil and self:needs_remote_check() then
        self.api:get_progress(book_id, function(ok, remote, code)
            if ok and type(remote) == "table" then
                if self:remote_is_newer(state, remote) then
                    return done(true, false, remote)
                end
                put()
            elseif code == 404 then
                put()
            else
                done(false)
            end
        end)
    else
        put()
    end
end

-- Synchronize reading progress for current document
function Manager:sync_progress(ui, document, is_silent, opts)
    if not self.api:has_auth() then
        return
    end

    local info = self:get_doc_info(ui, document)
    if not info then
        if not is_silent then
            utils.show_msg(_("No active document open."))
        end
        return
    end

    self:resolve_book_id(ui, document, function(book_id)
        if not book_id then
            if not is_silent then
                utils.show_msg(_("Document not matched on Folio server."))
            end
            return
        end

        local push_opts = { force = not is_silent, flush = opts and opts.flush }
        self:push_progress(info, book_id, push_opts, function(ok, applied)
            if is_silent then return end
            if ok and applied then
                utils.show_msg(T(_("Progress synced to Folio (%1%)"), math.floor(self:outgoing_percent(info) or 0)))
            elseif not ok then
                utils.show_msg(_("Failed to push progress to Folio."))
            end
        end)
    end)
end

-- Sets the read flag of the book on the server and on the device (the user toggled it).
function Manager:push_read_status(info, book_id, is_read, callback)
    self:push_progress(info, book_id, { read = is_read, flush = true }, callback)
end

-- Record a completed reading session locally in folio_sync_state.json
function Manager:record_reading_session(ui, document, session_data)
    if not session_data or not session_data.duration_seconds or session_data.duration_seconds < 10 then
        return
    end

    local info = self:get_doc_info(ui, document)
    if not info or not info.file_path then return end

    local sync_state = self:load_sync_state(info.file_path)
    sync_state.pending_sessions = sync_state.pending_sessions or {}

    table.insert(sync_state.pending_sessions, session_data)
    self:save_sync_state(sync_state, info.file_path)
end

-- Push pending reading sessions to Folio server
function Manager:sync_reading_sessions(ui, document, callback)
    if not self.api:has_auth() then
        if callback then callback(false) end
        return
    end

    local info = self:get_doc_info(ui, document)
    if not info or not info.file_path then
        if callback then callback(false) end
        return
    end

    self:resolve_book_id(ui, document, function(book_id)
        if not book_id then
            if callback then callback(false) end
            return
        end

        local sync_state = self:load_sync_state(info.file_path)
        local pending = sync_state.pending_sessions or {}
        if #pending == 0 then
            if callback then callback(true) end
            return
        end

        -- Prepare payload with resolved book_id.
        -- Sessions are recorded in percentages of the file; the server counts in the book.
        local layout = self:get_chapters_layout(info.file_path)
        local function book_percent(value)
            if not layout then return value end
            return ChaptersBook.to_book_percent(layout, value)
        end
        local payload_sessions = {}
        for _, s in ipairs(pending) do
            table.insert(payload_sessions, {
                clientSessionId = s.client_session_id or utils.generate_uuid(),
                bookId = book_id,
                deviceName = s.device_name or "KOReader",
                startTime = s.start_time,
                endTime = s.end_time,
                durationSeconds = s.duration_seconds,
                startProgress = book_percent(s.start_progress),
                endProgress = book_percent(s.end_progress),
                pagesRead = s.pages_read or 0,
            })
        end

        self.api:push_reading_sessions(payload_sessions, function(success)
            if success then
                local current_state = self:load_sync_state(info.file_path)
                local current_pending = current_state.pending_sessions or {}
                local sent_ids = {}
                for _, s in ipairs(payload_sessions) do
                    if s.clientSessionId then sent_ids[s.clientSessionId] = true end
                end
                local remaining = {}
                for _, s in ipairs(current_pending) do
                    if not (s.client_session_id and sent_ids[s.client_session_id]) then
                        table.insert(remaining, s)
                    end
                end
                current_state.pending_sessions = remaining
                self:save_sync_state(current_state, info.file_path)
                if callback then callback(true) end
            else
                if callback then callback(false) end
            end
        end)
    end)
end

-- ================= ANNOTATIONS AND BOOKMARKS =================
-- A three-way merge between KOReader's list, the server's list and a snapshot of what
-- both held after the last sync (`<book>.sdr/folio_sync_state.json`). The snapshot only
-- ever records what the server confirmed: a request that failed is made again next time.

-- Requests the server will refuse again however often they are repeated
local function is_permanent_error(code)
    code = tonumber(code)
    return code ~= nil and code >= 400 and code < 500 and code ~= 408 and code ~= 429
end

local function note_of(item)
    return type(item.note) == "string" and item.note or ""
end

local function text_of(item)
    return (type(item.text) == "string" and item.text)
        or (type(item.selectedText) == "string" and item.selectedText) or ""
end

local function color_of(item)
    return type(item.color) == "string" and item.color ~= "" and item.color or "yellow"
end

local ANNOTATIONS = {
    state_key = "annotations",
    synced_key = "has_synced_annos",
    -- A highlight of a paged document (PDF) is placed by coordinates on a page, which the
    -- server cannot keep: only highlights placed by XPointers are synchronized
    is_kind = function(item)
        return annotations_helper.is_annotation(item)
            and type(item.pos0) == "string" and type(item.pos1) == "string"
    end,
    list = "list_annotations",
    create = "create_annotation",
    update = "update_annotation",
    delete = "delete_annotation",
    to_remote = annotations_helper.koreader_to_folio_annotation,
    to_local = annotations_helper.folio_to_koreader_annotation,
    pair_opts = { with_end = true, by_text = true },
    -- What a snapshot remembers of an item
    snapshot = function(item)
        return {
            pos0 = type(item.pos0) == "string" and item.pos0 or nil,
            pos1 = type(item.pos1) == "string" and item.pos1 or nil,
            text = text_of(item) ~= "" and text_of(item) or nil,
            note = note_of(item) ~= "" and note_of(item) or nil,
            color = color_of(item),
        }
    end,
    -- Whether the local item was edited since the snapshot was taken
    local_changed = function(item, snap)
        return note_of(item) ~= note_of(snap) or text_of(item) ~= text_of(snap)
            or color_of(item) ~= color_of(snap)
            or annotations_helper.start_key(item) ~= annotations_helper.start_key(snap)
            or annotations_helper.end_key(item) ~= annotations_helper.end_key(snap)
    end,
    -- Whether a local and a server item say the same
    same_content = function(item, remote)
        return note_of(item) == note_of(remote) and text_of(item) == text_of(remote)
            and color_of(item) == color_of(remote)
    end,
    -- Brings the server's edit to the local item
    apply_remote = function(item, remote)
        local note = note_of(remote)
        item.note = note ~= "" and note or nil
        if text_of(remote) ~= "" then item.text = text_of(remote) end
        item.color = color_of(remote)
    end,
}

local BOOKMARKS = {
    state_key = "bookmarks",
    synced_key = "has_synced_bms",
    is_kind = annotations_helper.is_bookmark,
    list = "list_bookmarks",
    create = "create_bookmark",
    delete = "delete_bookmark",
    to_remote = annotations_helper.koreader_to_folio_bookmark,
    to_local = annotations_helper.folio_to_koreader_bookmark,
    pair_opts = {},
    snapshot = function(item)
        return {
            pos0 = annotations_helper.start_key(item),
            text = text_of(item) ~= "" and text_of(item) or nil,
        }
    end,
    -- A bookmark is a place: there is nothing to edit (the server has no request for it)
    local_changed = function() return false end,
    same_content = function() return true end,
}

-- KOReader's list of bookmarks and highlights of the book: the reader's own list while
-- the book is open (what is saved in the book's settings may be older), the saved one
-- otherwise. Returns the list and the reader module that owns it (nil for a saved list).
local function annotation_list(info, target_ui)
    local module = target_ui and target_ui.annotation
    if type(module) == "table" and type(module.annotations) == "table" then
        return module.annotations, module
    end
    local docsettings = info.docsettings
    local stored = docsettings and docsettings.readSetting and docsettings:readSetting("annotations")
    return type(stored) == "table" and stored or {}, nil
end

-- Whether an item of the server can be shown in the open document: KOReader sorts and
-- draws its list by position, and one it cannot place would break both.
local function is_placeable(target_ui, item)
    local doc = target_ui and target_ui.document
    if target_ui and target_ui.paging then
        -- A paged document (PDF) knows page bookmarks by page number, and highlights by
        -- coordinates the server does not have
        return item.pos1 == nil and type(item.page) == "number"
    end
    if not (target_ui and target_ui.rolling and doc and doc.getPageFromXPointer) then
        return true
    end
    local function resolves(xpointer)
        if type(xpointer) ~= "string" then return false end
        local ok, page = pcall(doc.getPageFromXPointer, doc, xpointer)
        return ok and tonumber(page) ~= nil and tonumber(page) > 0
    end
    return resolves(item.page) and (item.pos1 == nil or resolves(item.pos1))
end

local function local_datetime_epoch(item)
    local value = type(item.datetime_updated) == "string" and item.datetime_updated
        or (type(item.datetime) == "string" and item.datetime) or nil
    local year, month, day, hour, min, sec = (value or ""):match("^(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")
    if not year then return nil end
    return os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec) })
end

-- Synchronizes one kind of items (see ANNOTATIONS / BOOKMARKS) of the current document.
function Manager:sync_items(kind, ui, document, force_manual, callback)
    local function finish(ok)
        if callback then callback(ok) end
    end
    if not self.api:has_auth() then
        if force_manual then
            utils.show_msg(_("Please set API Key in settings."))
        end
        return finish(false)
    end

    local info = self:get_doc_info(ui, document)
    if not info then
        if force_manual then
            utils.show_msg(_("No active document open."))
        end
        return finish(false)
    end

    self:resolve_book_id(ui, document, function(book_id)
        if not book_id then
            if force_manual then
                utils.show_msg(_("Book not found in Folio library."))
            end
            return finish(false)
        end
        local file_path = info.file or info.file_path

        -- A copy of a single volume: the server keeps positions by chapter of the whole
        -- book, and where the copy sits in it must be current before anything is shifted
        if not self:refresh_volume_scope(file_path) then
            return finish(false)
        end

        -- The whole list, every time: what was deleted or edited elsewhere shows as a
        -- difference to the snapshot, and no clock is involved
        self.api[kind.list](self.api, book_id, nil, function(success, all_remote)
            if not success or type(all_remote) ~= "table" then
                if force_manual then
                    utils.show_msg(_("Failed to fetch remote annotations."))
                end
                return finish(false)
            end

            local on_server = {}
            local remote = {}
            for _, item in ipairs(all_remote) do
                if type(item) == "table" and item.deleted ~= true then
                    local id = annotations_helper.item_id(item)
                    if id then on_server[id] = true end
                    remote[#remote + 1] = item
                end
            end
            -- Its items are translated to this copy and those of other volumes are left
            -- out, so they are neither pulled nor ever seen as deleted here
            local layout = self:get_chapters_layout(file_path)
            if layout then
                remote = ChaptersBook.localize_items(layout, remote)
            end
            local function to_server(payload)
                return layout and ChaptersBook.globalize_item(layout, payload) or payload
            end

            local docsettings = info.docsettings
            local target_ui = info.ui or (self.plugin and self.plugin.get_ui and self.plugin:get_ui()) or ui or self.ui
            local items, live = annotation_list(info, target_ui)
            -- KOReader's list was changed here and has to be saved
            local list_changed = false

            local repaired = false
            for _, item in ipairs(items) do
                if annotations_helper.repair_bookmark(item) then
                    repaired = true
                end
            end
            if repaired then
                list_changed = true
                -- KOReader keeps page bookmarks before the highlights of their page and
                -- searches the list accordingly
                if live and type(live.sortItems) == "function" then
                    pcall(live.sortItems, live, items)
                end
            end

            local locals = {}
            for _, item in ipairs(items) do
                if kind.is_kind(item) then locals[#locals + 1] = item end
            end

            local state = self:load_sync_state(file_path)
            local old_snapshot = type(state[kind.state_key]) == "table" and state[kind.state_key] or {}
            local snaps = {}
            for _, snap in pairs(old_snapshot) do
                if type(snap) == "table" then snaps[#snaps + 1] = snap end
            end

            local snap_by_id = {}
            for _, snap in ipairs(snaps) do
                if snap.folio_id then snap_by_id[snap.folio_id] = snap end
            end
            local local_to_snap = annotations_helper.pair_items(locals, snaps, { with_end = kind.pair_opts.with_end })
            -- An item the snapshot knows by its place is the server's item of that id,
            -- however the server spells the place
            for index, item in ipairs(locals) do
                local snap = snaps[local_to_snap[index]]
                if snap and snap.folio_id and item.folio_id == nil then
                    item.folio_id = snap.folio_id
                    list_changed = true
                end
            end
            local local_to_remote, remote_to_local = annotations_helper.pair_items(locals, remote, kind.pair_opts)

            local new_snapshot = {}
            local complete = true -- false when a request failed: it is made again next time
            local removed = {}    -- local items to take out of KOReader's list
            local added = {}      -- items of the server to put into it

            local function remember(item, remote_item)
                local entry = kind.snapshot(item)
                entry.folio_id = annotations_helper.item_id(remote_item)
                entry.updated = type(remote_item.updatedAt) == "string" and remote_item.updatedAt or nil
                if entry.folio_id then
                    new_snapshot[entry.folio_id] = entry
                end
            end

            local function keep(snap)
                if snap and snap.folio_id then
                    new_snapshot[snap.folio_id] = snap
                end
            end

            -- Whether the server's item was edited since the snapshot was taken
            local function remote_changed(remote_item, snap)
                if snap.updated ~= nil and type(remote_item.updatedAt) == "string" then
                    return remote_item.updatedAt ~= snap.updated
                end
                return not kind.same_content(snap, remote_item)
            end

            -- Both sides were edited (or met for the first time with different content):
            -- the later edit stays
            local function remote_is_later(item, remote_item)
                local local_epoch = local_datetime_epoch(item)
                local remote_epoch = utils.parse_iso8601(remote_item.updatedAt)
                if not local_epoch or not remote_epoch then return false end
                return remote_epoch - self:clock_offset() > local_epoch
            end

            local function create(item)
                local payload = kind.to_remote(item)
                if not payload then return end
                -- The id is chosen here and kept on the item: when the answer gets lost,
                -- the request is repeated with the same id and creates nothing twice
                local function attempt(may_retry)
                    if not utils.is_uuid(item.folio_id) then
                        item.folio_id = utils.generate_uuid()
                        list_changed = true
                    end
                    payload.id = item.folio_id
                    self.api[kind.create](self.api, book_id, to_server(payload), function(ok, data, code)
                        if ok and type(data) == "table" and data.id and data.deleted ~= true then
                            if item.folio_id ~= data.id then
                                item.folio_id = data.id
                                list_changed = true
                            end
                            remember(item, data)
                        elseif may_retry and ((ok and type(data) == "table" and data.deleted == true) or code == 409) then
                            -- The id belongs to something that was deleted on the server
                            -- (or to another book): this is a new item
                            item.folio_id = nil
                            attempt(false)
                        elseif is_permanent_error(code) then
                            -- The server will not take it (a position it cannot place):
                            -- remembered, so that it is not sent again as it is
                            local entry = kind.snapshot(item)
                            entry.rejected = true
                            new_snapshot["rejected:" .. tostring(annotations_helper.start_key(item))
                                .. ":" .. tostring(annotations_helper.end_key(item))] = entry
                        else
                            complete = false
                        end
                    end)
                end
                attempt(true)
            end

            local function update(item, remote_item, snap)
                local payload = kind.to_remote(item)
                local id = annotations_helper.item_id(remote_item)
                self.api[kind.update](self.api, book_id, id, to_server(payload), function(ok, data, code)
                    if ok then
                        remember(item, type(data) == "table" and data.id and data or { id = id })
                    elseif is_permanent_error(code) and code ~= 404 then
                        -- Refused as it is: not sent again until it is edited once more
                        local entry = kind.snapshot(item)
                        entry.folio_id = id
                        entry.updated = remote_item.updatedAt
                        new_snapshot[id] = entry
                    else
                        complete = false
                        keep(snap)
                    end
                end)
            end

            -- 1. Local items
            for index, item in ipairs(locals) do
                local remote_item = remote[local_to_remote[index]]
                local snap = snaps[local_to_snap[index]]
                if snap and not snap.folio_id and not snap.rejected then
                    -- Written by an earlier version for an item the server never got
                    snap = nil
                end

                if remote_item then
                    local id = annotations_helper.item_id(remote_item)
                    if id and item.folio_id ~= id then
                        item.folio_id = id
                        list_changed = true
                    end
                    snap = (snap and snap.folio_id == id and snap) or snap_by_id[id]
                    local edited_here = snap ~= nil and kind.local_changed(item, snap)
                    local edited_there = snap ~= nil and remote_changed(remote_item, snap)
                    local take_remote, send_local = false, false
                    if snap == nil then
                        if not kind.same_content(item, remote_item) then
                            take_remote = remote_is_later(item, remote_item)
                            send_local = not take_remote
                        end
                    elseif edited_here and edited_there then
                        take_remote = remote_is_later(item, remote_item)
                        send_local = not take_remote
                    elseif edited_here then
                        send_local = true
                    elseif edited_there then
                        take_remote = true
                    end

                    if send_local and kind.update then
                        update(item, remote_item, snap)
                    elseif take_remote and kind.apply_remote then
                        kind.apply_remote(item, remote_item)
                        list_changed = true
                        remember(item, remote_item)
                    else
                        remember(item, remote_item)
                    end
                elseif snap and snap.folio_id and on_server[snap.folio_id] then
                    -- Still on the server, in a part of the book this copy does not hold
                    keep(snap)
                elseif snap and snap.folio_id then
                    -- Was on the server and is gone: deleted elsewhere. An item that was
                    -- edited here in the meantime is kept and sent again as a new one.
                    if kind.local_changed(item, snap) then
                        item.folio_id = nil
                        create(item)
                    else
                        removed[item] = true
                    end
                elseif snap and snap.rejected and not kind.local_changed(item, snap) then
                    new_snapshot["rejected:" .. tostring(annotations_helper.start_key(item))
                        .. ":" .. tostring(annotations_helper.end_key(item))] = snap
                else
                    create(item)
                end
            end

            -- 2. Items of the server that have no local counterpart
            for index, remote_item in ipairs(remote) do
                if not remote_to_local[index] then
                    local id = annotations_helper.item_id(remote_item)
                    local snap = id and snap_by_id[id]
                    if snap and not remote_changed(remote_item, snap) then
                        -- Was here and is gone: deleted on this device
                        self.api[kind.delete](self.api, book_id, id, function(ok, _, code)
                            if not ok and code ~= 404 then
                                -- Kept in the snapshot: the deletion is tried again
                                complete = false
                                keep(snap)
                            end
                        end)
                    else
                        -- New on the server (or edited there after it was deleted here)
                        local converted = kind.to_local(remote_item)
                        if converted and is_placeable(target_ui, converted) then
                            added[#added + 1] = { item = converted, remote = remote_item }
                        end
                    end
                end
            end

            -- 3. KOReader's list
            if next(removed) then
                for index = #items, 1, -1 do
                    if removed[items[index]] then
                        table.remove(items, index)
                        list_changed = true
                    end
                end
            end
            local added_count = 0
            for _, entry in ipairs(added) do
                local inserted
                if live and type(live.addItem) == "function" then
                    -- Sorted in, with its page number, the way KOReader adds its own
                    inserted = pcall(live.addItem, live, entry.item)
                else
                    table.insert(items, entry.item)
                    inserted = true
                end
                if inserted then
                    remember(entry.item, entry.remote)
                    added_count = added_count + 1
                    list_changed = true
                end
            end
            if added_count > 0 and not (live and type(live.addItem) == "function") then
                annotations_helper.sort_by_position(items)
            end

            -- KOReader's list goes to disk before the snapshot does: a snapshot that knows
            -- more than the saved list would turn into deletions after a crash
            local snapshot_changed = not utils.same_value(old_snapshot, new_snapshot)
            if (list_changed or snapshot_changed) and docsettings and docsettings.saveSetting then
                docsettings:saveSetting("annotations", items)
                if docsettings.flush then
                    pcall(function() docsettings:flush() end)
                end
            end
            local state_changed = snapshot_changed or state[kind.synced_key] ~= true
                or state.last_annos_sync_at ~= nil or state.last_bms_sync_at ~= nil
            state[kind.synced_key] = true
            state[kind.state_key] = new_snapshot
            -- (earlier versions asked the server for changes since these device times)
            state.last_annos_sync_at = nil
            state.last_bms_sync_at = nil
            if state_changed then
                self:save_sync_state(state, file_path)
            end

            if added_count > 0 or next(removed) then
                self:refresh_annotation_views(target_ui)
            end

            finish(complete)
        end)
    end)
end

-- Highlights and the bookmark corner are drawn from KOReader's list: show what changed.
function Manager:refresh_annotation_views(target_ui)
    if not (target_ui and target_ui.document) then return end
    pcall(function()
        if target_ui.bookmark and target_ui.bookmark.setDogearVisibility then
            target_ui.bookmark:setDogearVisibility(target_ui.bookmark:getCurrentPageNumber())
        end
        if target_ui.view and target_ui.view.footer and target_ui.view.footer.maybeUpdateFooter then
            target_ui.view.footer:maybeUpdateFooter()
        end
        if UIManager.setDirty then
            UIManager:setDirty(target_ui.dialog or target_ui, "ui")
        end
    end)
end

-- Synchronize annotations for current document (State-Aware 2-Way Sync)
function Manager:sync_annotations(ui, document, force_manual, callback)
    if force_manual then
        self:user_requested()
        if self.api:has_auth() then
            utils.show_msg(_("Syncing annotations with Folio..."))
        end
    end
    self:sync_items(ANNOTATIONS, ui, document, force_manual, function(ok)
        if force_manual and ok then
            utils.show_msg(_("Annotations synchronized with Folio!"))
        end
        if callback then callback(ok) end
    end)
end

-- Synchronize bookmarks for current document (State-Aware 2-Way Sync)
function Manager:sync_bookmarks(ui, document, _force_manual, callback)
    self:sync_items(BOOKMARKS, ui, document, false, callback)
end

-- Synchronize both annotations and bookmarks for current document
function Manager:sync_annotations_and_bookmarks(ui, document, force_manual, callback)
    if force_manual then
        self:user_requested()
        utils.show_msg(_("Syncing annotations & bookmarks with Folio..."))
    end

    self.is_syncing_annotations = true

    self:sync_annotations(ui, document, false, function(annos_ok)
        self:sync_bookmarks(ui, document, false, function(bms_ok)
            self.is_syncing_annotations = false
            if force_manual then
                if annos_ok and bms_ok then
                    utils.show_msg(_("Annotations & bookmarks synchronized with Folio!"))
                else
                    utils.show_msg(_("Failed to synchronize annotations or bookmarks."))
                end
            end

            if callback then callback(annos_ok and bms_ok) end
        end)
    end)
end

-- Push all data (progress + annotations + bookmarks) for current document to Folio
function Manager:push_all_data(ui, document, force_manual)
    if force_manual == nil then force_manual = true end
    if not self.api:has_auth() then
        if force_manual then
            utils.show_msg(_("Please set API Key in settings."))
        end
        return
    end

    local info = self:get_doc_info(ui, document)
    if not info then
        if force_manual then
            utils.show_msg(_("No active document open."))
        end
        return
    end

    if force_manual then
        self:user_requested()
    end
    if self.plugin and self.plugin._finalize_and_record_session then
        self.plugin:_finalize_and_record_session(ui, document)
    end

    self:resolve_book_id(ui, document, function(book_id)
        if not book_id then
            if force_manual then
                utils.show_msg(_("Document not matched on Folio server."))
            end
            return
        end

        if force_manual then
            utils.show_msg(_("Pushing all document data to Folio..."))
        end

        -- Asked for by the user: the position on this device is the one that counts
        self:push_progress(info, book_id, { force = force_manual }, function(push_prog_ok)
            self:sync_annotations_and_bookmarks(ui, document, false)
            self:sync_reading_sessions(ui, document)
            if force_manual then
                if push_prog_ok then
                    local book_pct = math.floor(self:outgoing_percent(info) or 0)
                    local layout = self:get_chapters_layout(info.file or info.file_path)
                    if ChaptersBook.is_volume_copy(layout) then
                        -- The server counts in the whole book, the reader in this volume
                        utils.show_msg(T(_("All document data sent to Folio (volume %1: %2%, book: %3%)!"),
                            layout.volume, math.floor(tonumber(info.percent) or 0), book_pct))
                    else
                        utils.show_msg(T(_("All document data sent to Folio (%1%)!"), book_pct))
                    end
                else
                    utils.show_msg(_("Failed to push progress to Folio."))
                end
            end
        end)
    end)
end

-- Log XPointer navigation errors to a file located above the selected download directory
function Manager:log_xpointer_error(book_title, remote_pos, details, doc_path, candidates, remote_percent)
    local chosen_dir = (self.plugin and self.plugin.settings and self.plugin.settings.download_dir)
        or (doc_path and doc_path:match("^(.*)[/\\]"))
        or "/sdcard/books/FolioSync"
    local target_dir = utils.get_parent_dir(chosen_dir) or chosen_dir
    utils.ensure_dir(target_dir)

    local log_file_path = target_dir .. "/xpointer_errors.txt"
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")

    local lines = {}
    table.insert(lines, "========================================")
    table.insert(lines, string.format("[%s] XPointer Navigation Error", timestamp))
    if book_title and book_title ~= "" then
        table.insert(lines, string.format("Book Title: %s", tostring(book_title)))
    end
    if doc_path and doc_path ~= "" then
        table.insert(lines, string.format("File Path: %s", tostring(doc_path)))
    end
    table.insert(lines, string.format("Received Location: %s", tostring(remote_pos)))
    if remote_percent then
        table.insert(lines, string.format("Received Progress: %s%%", tostring(remote_percent)))
    end
    if details and details ~= "" then
        table.insert(lines, string.format("Details: %s", tostring(details)))
    end
    if candidates and #candidates > 0 then
        table.insert(lines, "Candidate XPointers tried:")
        for _, c in ipairs(candidates) do
            table.insert(lines, string.format("  - %s", tostring(c)))
        end
    end
    table.insert(lines, "========================================\n")

    local content = table.concat(lines, "\n")

    local f = io.open(log_file_path, "a")
    if f then
        f:write(content)
        f:close()
    else
        logger.warn("FolioSync Manager: failed to open log file " .. tostring(log_file_path))
    end

    logger.warn(string.format("FolioSync Manager: XPointer navigation error for '%s': %s (logged to %s)",
        tostring(book_title or "unknown"), tostring(remote_pos), tostring(log_file_path)))
end

-- Navigate reader UI to position/page specified by location or percentage
function Manager:goto_location(target_ui, remote_pos, remote_percent, total_pages, target_doc, book_title, book_info)
    local UIMgr = require("ui/uimanager")

    -- 1. Robust UI Resolution: find an active ReaderUI instance with document and handleEvent
    local ui = nil
    if target_ui and target_ui.document and target_ui.handleEvent then
        ui = target_ui
    elseif self.plugin and self.plugin.ui and self.plugin.ui.document and self.plugin.ui.handleEvent then
        ui = self.plugin.ui
    elseif self.plugin and self.plugin.get_ui then
        local got = self.plugin:get_ui()
        if got and got.document and got.handleEvent then ui = got end
    end

    if not ui and UIMgr then
        local stack = UIMgr._stack or UIMgr.stack or {}
        for i = #stack, 1, -1 do
            local widget = stack[i]
            if widget and widget.document and widget.handleEvent then
                ui = widget
                break
            end
        end
    end

    if not ui then
        return false
    end

    local doc = target_doc or ui.document

    -- Resolve title and file path for logging if not provided
    local title = book_title
    local doc_file_path = nil
    if type(book_info) == "table" then
        title = title or book_info.title
        doc_file_path = book_info.file or book_info.file_path
    end
    if not title or not doc_file_path then
        local info = self:get_doc_info(ui, doc)
        if info then
            title = title or info.title
            doc_file_path = doc_file_path or info.file or info.file_path
        end
    end

    -- 2. If remote_pos is an XPointer string (starts with '/' or contains 'DocFragment' / 'text()')
    if type(remote_pos) == "string" and remote_pos ~= "" and not remote_pos:match("^page_%d+$") then
        local target_page = nil
        local best_xp = nil
        local last_err = nil

        -- Generate candidate XPointers from most specific to least specific
        local candidates = {}
        table.insert(candidates, remote_pos)

        -- 1. Try stripping /text().0 or /text()[N].offset
        -- (two patterns: Lua has no optional groups)
        local no_text, stripped = remote_pos:gsub("/text%(%)%.%d+$", "")
        if stripped == 0 then
            no_text = remote_pos:gsub("/text%(%)%b[]%.%d+$", "")
        end
        if no_text ~= remote_pos then
            table.insert(candidates, no_text)
            table.insert(candidates, no_text .. ".0")
        end

        -- 2. Progressively strip DOM segments from right to left
        local trimmed = no_text
        while true do
            local parent = trimmed:match("^(.*)/[^/]+$")
            if parent and parent:find("DocFragment") then
                table.insert(candidates, parent)
                table.insert(candidates, parent .. ".0")
                trimmed = parent
            else
                break
            end
        end

        -- 3. DocFragment root as ultimate chapter fallback
        local doc_frag = remote_pos:match("(/body/DocFragment%[%d+%])") or remote_pos:match("(DocFragment%[%d+%])")
        if doc_frag then
            table.insert(candidates, doc_frag .. ".0")
            table.insert(candidates, doc_frag)
        end

        -- Validate candidates against document DOM
        if doc and doc.getPageFromXPointer then
            for _, xp in ipairs(candidates) do
                local ok, p = pcall(function() return doc:getPageFromXPointer(xp) end)
                if ok and p and tonumber(p) and tonumber(p) > 0 then
                    target_page = tonumber(p)
                    best_xp = xp
                    break
                elseif not ok and p then
                    last_err = tostring(p)
                end
            end
        end

        -- Method A: KOReader's native ReaderLink widget (best precision: moves page AND scrolls to element)
        if best_xp and ui.link and ui.link.onGotoLink then
            local curr_page_before = doc and doc.getCurrentPage and doc:getCurrentPage()
            local ok, res = pcall(function() return ui.link:onGotoLink({ xpointer = best_xp }) end)
            local curr_page_after = doc and doc.getCurrentPage and doc:getCurrentPage()
            if ok and (res == nil or res == true) and (not target_page or curr_page_after == target_page or (curr_page_before and curr_page_after ~= curr_page_before)) then
                return true
            elseif not ok and res then
                last_err = tostring(res)
            end
        end

        -- Method B: GotoPos event
        if best_xp then
            local ok_event, res_event = pcall(function()
                local r1 = ui:handleEvent(Event:new("GotoPos", best_xp))
                local r2 = UIMgr:broadcastEvent(Event:new("GotoPos", best_xp))
                return r1 or r2
            end)
            if ok_event and res_event then
                return true
            elseif not ok_event and res_event then
                last_err = tostring(res_event)
            end
        end

        -- Method C: Direct page jump via validated target_page
        if target_page and target_page > 0 then
            local ok_page = pcall(function()
                return ui:handleEvent(Event:new("GotoPage", target_page))
            end)
            if ok_page then
                return true
            end
        end

        -- If XPointer navigation failed, log the error to file above download directory
        local reason = last_err or "XPointer could not be resolved to any page in document DOM"
        self:log_xpointer_error(title, remote_pos, reason, doc_file_path, candidates, remote_percent)
    end

    -- 3. Check if remote_pos is a page_N string (e.g. "page_15")
    if type(remote_pos) == "string" then
        local target_page = remote_pos:match("^page_(%d+)$")
        if target_page then
            target_page = tonumber(target_page)
            ui:handleEvent(Event:new("GotoPage", target_page))
            return true
        end
    end

    -- 4. Fallback: navigate by percentage (0..100)
    if remote_percent and total_pages and total_pages > 1 then
        local pct = tonumber(remote_percent) or 0
        local target_page = math.max(1, math.min(total_pages, math.floor((pct / 100) * total_pages + 0.5)))
        ui:handleEvent(Event:new("GotoPage", target_page))
        return true
    end

    return false
end

-- Takes over the server's reading position: opens it, and follows its read flag.
-- Returns a short description for the user.
function Manager:adopt_remote_progress(info, remote, ui, document)
    local remote_pos = type(remote.location) == "string" and remote.location or nil
    local remote_percent = tonumber(remote.progressPercent or remote.progress_percent)
    local remote_is_read = remote.isRead
    if remote_is_read == nil then remote_is_read = remote.is_read end

    local target_ui = info.ui or (self.plugin and self.plugin.get_ui and self.plugin:get_ui()) or ui or self.ui
    local target_doc = info.document or (target_ui and target_ui.document) or document
    local docsettings = info.docsettings
    local file_path = info.file or info.file_path

    -- Page turns made by the jump are not the user reading
    self._applying_remote = true
    local ok_goto, goto_err = pcall(function()
        local layout = self:get_chapters_layout(file_path)
        if layout then
            -- Chapters book: the server position is a chapter reference
            if remote_pos and remote_pos ~= "" then
                local kind, xpointer = ChaptersBook.incoming_location(layout, remote_pos, info.location)
                if kind == "at" then
                    -- No percentage fallback: it is counted differently by every client
                    self:goto_location(target_ui, xpointer, nil, info.total_pages, target_doc, info.title, info)
                elseif kind == "unknown" and not ChaptersBook.is_volume_copy(layout) then
                    -- (a copy of one volume expects the position to be in another
                    -- volume now and then: nothing to tell the user)
                    self:notify_missing_chapter(file_path)
                end
                -- "same": already in that chapter, the local position is more precise
            end
        elseif remote_pos and remote_pos ~= "" then
            -- An empty location is "no position": there is nothing to open
            if annotations_helper.position_key(remote_pos) ~= annotations_helper.position_key(info.location) then
                self:goto_location(target_ui, remote_pos, remote_percent, info.total_pages, target_doc, info.title, info)
            end
        elseif remote_percent and remote_percent > 0 and math.abs(remote_percent - (info.percent or 0)) >= 0.5 then
            self:goto_location(target_ui, nil, remote_percent, info.total_pages, target_doc, info.title, info)
        end
    end)
    self._applying_remote = false
    if not ok_goto then
        logger.warn("FolioSync: could not open the position from Folio:", goto_err)
    end

    local state = self:progress_state(docsettings)
    local local_read = self:get_doc_read_status(info)
    if remote_is_read == true then
        if not local_read then
            self:set_local_read_status(info, true, docsettings)
        end
        state.read = true
    elseif remote_is_read == false and not self:is_partial_copy(info) then
        -- Marked unread elsewhere — unless the book was finished here and the server
        -- has not been told yet
        if local_read and state.read == true then
            self:set_local_read_status(info, false, docsettings)
        end
        if not local_read or state.read == true then
            state.read = false
        end
    end

    local remote_epoch = utils.parse_iso8601(remote.updatedAt or remote.updated_at)
    state.at = remote_epoch and (remote_epoch - self:clock_offset()) or utils.now()
    state.server = remote.updatedAt or remote.updated_at
    self:save_progress_state(docsettings, state)

    if remote_is_read == true then
        return _("Marked as Read")
    elseif remote_percent then
        return T(_("Progress: %1%"), math.floor(remote_percent))
    end
    return ""
end

-- Fetch/pull reading progress only for current document from Folio.
-- The position is opened when it was changed after the local one (or when the user
-- asked for it: `force_manual`, or `opts.force` without the messages); a local position
-- that is newer is sent to the server instead.
function Manager:pull_progress(ui, document, force_manual, callback, opts)
    if force_manual == nil then force_manual = false end
    local force = force_manual or (opts ~= nil and opts.force == true)
    if not self.api:has_auth() then
        if force_manual then
            utils.show_msg(_("Please set API Key in settings."))
        end
        if callback then callback(false) end
        return
    end

    local info = self:get_doc_info(ui, document)
    if not info then
        if force_manual then
            utils.show_msg(_("No active document open."))
        end
        if callback then callback(false) end
        return
    end

    self:resolve_book_id(ui, document, function(book_id)
        if not book_id then
            if force_manual then
                utils.show_msg(_("Document not matched on Folio server."))
            end
            if callback then callback(false) end
            return
        end

        if force_manual then
            utils.show_msg(_("Fetching reading progress from Folio..."))
        end

        self.api:get_progress(book_id, function(prog_ok, remote_data, code)
            local progress_msg = ""
            local state = self:progress_state(info.docsettings)
            if prog_ok and type(remote_data) == "table" then
                if force or self:remote_is_newer(state, remote_data) then
                    progress_msg = self:adopt_remote_progress(info, remote_data, ui, document)
                else
                    -- The local position is the newer one (nothing is sent when the
                    -- server has it already)
                    self:push_progress(info, book_id, {})
                end
            elseif not prog_ok and code == 404 then
                -- The server has no position for this book yet
                prog_ok = true
                self:push_progress(info, book_id, {})
            end

            if force_manual then
                utils.show_msg(T(_("Fetched progress: %1"),
                    progress_msg ~= "" and progress_msg or _("Up to date")))
            end

            if callback then callback(prog_ok) end
        end)
    end)
end

-- The server position is in a chapter the local copy does not have: tell the user once
-- per opened book that the copy needs an update.
function Manager:notify_missing_chapter(file_path)
    self._missing_chapter_notified = self._missing_chapter_notified or {}
    if self._missing_chapter_notified[file_path] then return end
    self._missing_chapter_notified[file_path] = true
    utils.show_msg(_("The reading position on Folio is in a chapter this copy does not have yet. Update the book chapters from Folio."), 5)
end

-- Fetch/pull all data (progress + annotations + bookmarks) for current document from Folio
function Manager:pull_all_data(ui, document, force_manual, callback)
    if force_manual == nil then force_manual = true end
    if not self.api:has_auth() then
        if force_manual then
            utils.show_msg(_("Please set API Key in settings."))
        end
        if callback then callback(false) end
        return
    end

    local info = self:get_doc_info(ui, document)
    if not info then
        if force_manual then
            utils.show_msg(_("No active document open."))
        end
        if callback then callback(false) end
        return
    end

    if force_manual then
        self:user_requested()
        utils.show_msg(_("Fetching document data from Folio..."))
    end

    -- Asked for by the user: the position on the server is opened even when the one on
    -- this device is newer
    self:pull_progress(ui, document, false, function(prog_ok)
        self:sync_annotations_and_bookmarks(ui, document, false, function(annos_ok)
            if force_manual then
                if prog_ok or annos_ok then
                    utils.show_msg(_("All document data fetched from Folio!"))
                else
                    utils.show_msg(_("Failed to fetch document data from Folio."))
                end
            end
            if callback then callback(prog_ok and annos_ok) end
        end)
    end, { force = force_manual })
end

-- ================= CHAPTERS BOOKS =================

local function same_file(path_a, path_b)
    if not path_a or not path_b then return false end
    if path_a == path_b then return true end
    local ok, equal = pcall(function()
        local ffiutil = require("ffi/util")
        local real_a, real_b = ffiutil.realpath(path_a), ffiutil.realpath(path_b)
        return real_a ~= nil and real_a == real_b
    end)
    return ok and equal == true
end

-- Message for a failed download of a Chapters book
local function chapters_error_text(err)
    if err == ChaptersBook.ERR_CANCELLED then
        return _("Download cancelled.")
    elseif err == ChaptersBook.ERR_NO_CHAPTERS then
        return _("This book has no chapters on the server yet.")
    elseif err == ChaptersBook.ERR_FORBIDDEN then
        return _("The Folio server does not let API keys read chapters. Update the Folio server.")
    elseif err == ChaptersBook.ERR_NAME_TAKEN then
        return _("Another book already uses this file name in the download folder.")
    end
    return T(_("Failed to download book: %1"), tostring(err))
end

-- What a finished download did, for the user
function Manager:chapters_result_text(title, result)
    local text
    if not result.updated then
        text = T(_("'%1' downloaded: %2 chapters."), title, result.chapters_total)
    elseif result.chapters_fetched == 0 then
        text = T(_("'%1' is up to date: %2 chapters."), title, result.chapters_total)
    else
        text = T(_("'%1' updated: %2 new or changed chapters, %3 in total."), title,
            result.chapters_fetched, result.chapters_total)
    end
    local missing = tonumber(result.images_missing) or 0
    if missing > 0 then
        text = text .. "\n" .. T(_("Illustrations missing on the server: %1."), missing)
    end
    return text
end

-- Chapters that changed their place in the book take the reading position, the
-- annotations and the sync snapshot with them.
function Manager:remap_chapter_positions(file_path, moved)
    pcall(function()
        local DocSettings = require("docsettings")
        if DocSettings.hasSidecarFile and not DocSettings:hasSidecarFile(file_path) then
            return
        end
        local docsettings = DocSettings:open(file_path)
        if ChaptersBook.remap_docsettings(docsettings, moved) and docsettings.flush then
            docsettings:flush()
        end
    end)

    local state = self:load_sync_state(file_path)
    if ChaptersBook.remap_sync_state(state, moved) then
        self:save_sync_state(state, file_path)
    end
end

-- Puts a built EPUB in place. When the book is open in the reader, the file is swapped
-- while the reader is closed and the book is opened again.
-- Returns ok, error, reopened.
function Manager:install_chapters_build(result)
    if result.unchanged then
        -- The copy on the device is current: nothing to swap, nothing to reopen
        self._chapters_layouts = {}
        return ChaptersBook.commit(result), nil, false
    end

    local function install()
        local ok, err = ChaptersBook.commit(result)
        if not ok then
            return false, err
        end
        self._chapters_layouts = {}
        if result.has_moved then
            self:remap_chapter_positions(result.target_path, result.moved)
        end
        return true
    end

    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok_reader and type(ReaderUI) == "table" and ReaderUI.instance or nil
    if reader and reader.document and reader.reloadDocument and same_file(reader.document.file, result.target_path) then
        local installed, err
        result.target_path = reader.document.file
        reader:reloadDocument(function()
            installed, err = install()
        end)
        return installed == true, err, true
    end

    local installed, err = install()
    return installed, err, false
end

-- The server book a file on this device is known to be; nil when nothing says so.
function Manager:local_file_book_id(file_path)
    local entry = self:file_index_entry(file_path)
    if entry and type(entry.book_id) == "string" and entry.book_id ~= "" then
        return entry.book_id
    end
    local layout = self:get_chapters_layout(file_path)
    if layout and layout.book_id then
        return layout.book_id
    end
    local stored
    pcall(function()
        local DocSettings = require("docsettings")
        if DocSettings.hasSidecarFile and DocSettings:hasSidecarFile(file_path) then
            stored = DocSettings:open(file_path):readSetting("folio_book_id")
        end
    end)
    return type(stored) == "string" and stored ~= "" and stored or nil
end

--[[--
Picks the file a book is downloaded to in `dir`: `<stem>.epub`, or `<stem> (<id>).epub`
when the plain name belongs to another book (two books may share title and author).

Returns the path and whether a copy of this very book is already there. `ask_server`
lets a file nobody remembers downloading be identified by its content.
]]
function Manager:resolve_download_target(dir, stem, book_id, ask_server)
    local candidates = {
        string.format("%s/%s.epub", dir, stem),
        string.format("%s/%s (%s).epub", dir, stem, tostring(book_id):sub(1, 8)),
    }
    for index, path in ipairs(candidates) do
        if not utils.file_exists(path) then
            return path, false
        end
        local owner = self:local_file_book_id(path)
        if not owner and ask_server and index == 1 then
            local file_hash = self:get_file_hash(path)
            local found, book = false, nil
            if file_hash then
                found, book = self.api:find_book_by_hash(file_hash)
            end
            owner = found and type(book) == "table" and book.id or nil
        end
        if owner == book_id or index == #candidates then
            return path, true
        end
    end
end

-- A book file was downloaded to `file_path`. It may have replaced a copy assembled from
-- chapters (the book got its EPUB on the server, which is another book there): what the
-- sidecar knew about the old file must not be applied to the new one.
function Manager:relink_downloaded_file(file_path, book_id)
    self._chapters_layouts = {}
    if self._unmatched then self._unmatched[file_path] = nil end
    local layout_path = ChaptersBook.layout_path(file_path)
    if layout_path then os.remove(layout_path) end
    -- The file is this book whatever its content hashes to and whatever it is called
    pcall(self.update_file_index, self, file_path, { book_id = book_id })

    pcall(function()
        local DocSettings = require("docsettings")
        if not (DocSettings.hasSidecarFile and DocSettings:hasSidecarFile(file_path)) then
            return
        end
        local docsettings = DocSettings:open(file_path)
        local stored_id = docsettings:readSetting("folio_book_id")
        if stored_id and stored_id ~= book_id then
            docsettings:saveSetting("folio_book_id", book_id)
            docsettings:flush()
            self:invalidate_sync_state(file_path)
        end
    end)
end

--[[--
Downloads a Folio `Chapters` book (a book that has no EPUB file on the server) chapter by
chapter and assembles it into a local EPUB at `target_path`; a copy that is already there
is updated with the new and changed chapters.

`book.volume` downloads that volume only, as a file of its own (`book.display_title` then
overrides the "<title> — Volume N" shown while downloading).

Long running: shows progress and can be cancelled by tapping it.
`on_done(success, result, reopened)` is called once everything is in place.
]]
function Manager:download_chapters_book(book, target_path, on_done)
    local title = book.name or book.title or _("book")
    local volume = tonumber(book.volume)
    if book.display_title then
        title = book.display_title
    elseif volume then
        title = T(_("%1 — Volume %2"), title, ChaptersEpub.format_number(volume))
    end
    local previous = self:get_chapters_layout(target_path)
    local ok_trapper, Trapper = pcall(require, "ui/trapper")
    local use_trapper = ok_trapper and type(Trapper) == "table" and Trapper.wrap and Trapper.info

    local function finish(result, err)
        if not result then
            utils.show_msg(chapters_error_text(err), 5)
            if on_done then on_done(false, err) end
            return
        end
        local installed, install_err, reopened = self:install_chapters_build(result)
        if not installed then
            utils.show_msg(chapters_error_text(install_err), 5)
            if on_done then on_done(false, install_err) end
            return
        end
        UIManager:broadcastEvent(Event:new("Refresh"))
        if on_done then on_done(true, result, reopened) end
    end

    local job
    local function start()
        if use_trapper then
            Trapper:wrap(job)
        else
            job()
        end
    end

    job = function()
        local last_phase, last_shown = nil, 0
        local function on_progress(phase, done, total)
            -- Every update costs an e-ink refresh: show phase changes, then one every 2 s
            local now = os.time()
            if phase == last_phase and done < total and (now - last_shown) < 2 then
                return true
            end
            last_phase, last_shown = phase, now

            local text
            if phase == "chapters" then
                text = T(_("Downloading '%1'\nChapters: %2 / %3"), title, done, total)
            elseif phase == "images" then
                text = T(_("Downloading '%1'\nIllustrations: %2 / %3"), title, done, total)
            else
                text = T(_("Building '%1'…"), title)
            end
            if use_trapper then
                -- false when the user tapped the message and chose to stop
                return Trapper:info(text) ~= false
            end
            return true
        end

        if use_trapper then
            if Trapper.setPausedText then
                Trapper:setPausedText(_("Download paused"), _("Cancel download"), _("Continue"))
            end
            -- Shown while the chapter list is being loaded
            Trapper:info(T(_("Downloading '%1'..."), title))
        end
        -- The server went away in the middle (Wi-Fi switched, the device slept): what
        -- was downloaded so far is kept while the user decides
        local on_stalled
        if use_trapper and Trapper.confirm then
            on_stalled = function(message)
                return Trapper:confirm(
                    T(_("The connection to Folio was lost while downloading '%1'.\n%2\n\nTry again?"),
                        title, tostring(message)),
                    _("Cancel download"), _("Try again")) == true
            end
        end
        local ok, result, err = pcall(ChaptersBook.build, self.api, {
            book_id = book.id,
            target_path = target_path,
            volume = volume,
            title = book.name or book.title,
            author = book.author,
            previous_chapter_ids = previous and previous.chapter_ids or nil,
            on_progress = on_progress,
            on_stalled = on_stalled,
        })
        if not ok then
            logger.warn("FolioSync: chapters download failed:", result)
            os.remove(target_path .. ".tmp")
            result, err = nil, result
        end
        if use_trapper and Trapper.reset then
            Trapper:reset()
        end

        -- Leave the job's coroutine before touching the reader
        if UIManager.nextTick then
            UIManager:nextTick(function() finish(result, err) end)
        else
            finish(result, err)
        end
    end

    -- Let the dialog or menu that started the download close first
    if UIManager.nextTick then
        UIManager:nextTick(start)
    else
        start()
    end
end

-- Updates the open book with the chapters added or changed on the server.
function Manager:update_active_chapters_book()
    local ui = self.plugin and self.plugin.get_ui and self.plugin:get_ui() or self.ui
    local info = self:get_doc_info(ui, ui and ui.document)
    local layout = info and self:get_chapters_layout(info.file)
    if not layout then
        utils.show_msg(_("This book was not assembled from Folio chapters."))
        return
    end
    if not self.api:has_auth() then
        utils.show_msg(_("Please set API Key in settings."))
        return
    end

    local title = info.title
    -- A copy of a single volume is updated as that volume (its title already names it)
    local book = { id = layout.book_id, title = title }
    if layout.volume then
        book = { id = layout.book_id, volume = layout.volume, display_title = title }
    end
    self:download_chapters_book(book, info.file, function(success, result, reopened)
        if not success then return end
        local function report()
            utils.show_msg(self:chapters_result_text(result.title or title, result), 4)
        end
        if reopened and UIManager.scheduleIn then
            -- The book is being opened again: let the reader settle first
            UIManager:scheduleIn(2, report)
        else
            report()
        end
    end)
end

return Manager
