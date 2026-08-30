local _ = require("gettext")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local Event = require("ui/event")
local logger = require("logger")
local annotations_helper = require("annotations")
local utils = require("utils")

local Manager = {}

function Manager:new(plugin_instance)
    local o = {
        plugin = plugin_instance,
        api = plugin_instance.api,
        _last_pushed_percent = {},
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

-- Invalidate (delete) sync state JSON when folio_book_id is missing from docsettings
function Manager:invalidate_sync_state(file_path)
    if not file_path or file_path == "" then return end
    local sdr_dir = file_path:match("^(.*)%.%w+$") and (file_path:match("^(.*)%.%w+$") .. ".sdr")
    if not sdr_dir then return end
    local sdr_path = sdr_dir .. "/folio_sync_state.json"
    os.remove(sdr_path)
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
                    percent = p <= 1 and (p * 100) or p
                end
            end
            if paging_module.getLastProgress then
                local ok, pos = pcall(function() return paging_module:getLastProgress() end)
                if ok and pos then location = pos end
            end
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
        if total_pages == 1 and data.doc_pages then
            total_pages = data.doc_pages
        end
        if not location and data.last_xpointer then
            location = data.last_xpointer
        end
        if percent == 0 and data.percent_finished then
            percent = data.percent_finished <= 1 and (data.percent_finished * 100) or data.percent_finished
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
                                    percent = p <= 1 and (p * 100) or p
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

    if not title then
        title = utils.get_file_basename(file_path):gsub("%.%w+$", "")
    end
    if type(location) == "table" then
        location = location.xpointer or location.location or (location.page and string.format("page_%d", location.page)) or
            tostring(location)
    end
    if not location and current_page then
        location = string.format("page_%d", current_page)
    end
    if current_page == 1 and total_pages > 1 then
        percent = 0.0
    elseif percent == 0 and total_pages > 0 and current_page > 1 then
        percent = ((current_page - 1) / total_pages) * 100
    end
    if percent > 0 and percent <= 1 then
        percent = percent * 100
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

    -- 2. Try to match by file hash via Folio API
    local file_hash = self:compute_file_hash(info.file)
    if file_hash then
        self.api:find_book_by_hash(file_hash, function(success, response)
            if success and response and response.id then
                local book_id = response.id
                if info.docsettings and info.docsettings.saveSetting then
                    info.docsettings:saveSetting("folio_book_id", book_id)
                end
                if callback then callback(book_id) end
                return
            end

            -- 3. Fallback: try to match by title / filename
            self:resolve_book_id_by_info(info, callback)
        end)
    else
        -- Hash computation failed, fall back to title search
        self:resolve_book_id_by_info(info, callback)
    end
end

-- Fallback: resolve book_id by title search using doc info
function Manager:resolve_book_id_by_info(info, callback)
    local title = info.title

    self.api:list_books(1, 10, title, function(success, response)
        if success and response and response.items and #response.items > 0 then
            local matched_book = response.items[1]
            local book_id = matched_book.id

            if info.docsettings and info.docsettings.saveSetting then
                info.docsettings:saveSetting("folio_book_id", book_id)
            end
            if callback then callback(book_id) end
        else
            if callback then callback(nil) end
        end
    end)
end

-- Synchronize reading progress for current document
function Manager:sync_progress(ui, document, is_silent)
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

        local percent = info.percent
        local location = info.location
        local is_read = self:get_doc_read_status(info)

        -- Fetch remote progress first
        self.api:get_progress(book_id, function(success, remote_data)
            local should_push = true
            if success and remote_data then
                local remote_percent = remote_data.progressPercent or remote_data.progress_percent or 0
                local remote_is_read = remote_data.isRead
                if remote_is_read == nil then remote_is_read = remote_data.is_read end

                -- If remote is marked as read and local is not marked as complete, update local status
                if remote_is_read == true and not is_read then
                    self:set_local_read_status(info, true, info.docsettings)
                    is_read = true
                end

                -- Do not overwrite remote progress if remote is ahead and local is not marked as read,
                -- UNLESS the remote progress matches our own last push in this session (local rollback/correction)
                if not is_read and (remote_percent > percent + 0.1) then
                    local my_last_pushed = self._last_pushed_percent and self._last_pushed_percent[book_id]
                    if my_last_pushed and math.abs(remote_percent - my_last_pushed) < 0.2 then
                        should_push = true
                    else
                        should_push = false
                    end
                end
            end

            if should_push then
                self.api:update_progress(book_id, location, percent, is_read, function(push_ok)
                    if push_ok then
                        self._last_pushed_percent = self._last_pushed_percent or {}
                        self._last_pushed_percent[book_id] = percent
                        if not is_silent then
                            utils.show_msg(T(_("Progress synced to Folio (%1%)"), math.floor(percent)))
                        end
                    end
                end)
            end
        end)
    end)
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

        -- Prepare payload with resolved book_id
        local payload_sessions = {}
        for _, s in ipairs(pending) do
            table.insert(payload_sessions, {
                clientSessionId = s.client_session_id or utils.generate_uuid(),
                bookId = book_id,
                deviceName = s.device_name or "KOReader",
                startTime = s.start_time,
                endTime = s.end_time,
                durationSeconds = s.duration_seconds,
                startProgress = s.start_progress,
                endProgress = s.end_progress,
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

-- Synchronize annotations for current document (State-Aware 2-Way Sync)
function Manager:sync_annotations(ui, document, force_manual, callback)
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
                utils.show_msg(_("Book not found in Folio library."))
            end
            if callback then callback(false) end
            return
        end

        if force_manual then
            utils.show_msg(_("Syncing annotations with Folio..."))
        end

        local state = self:load_sync_state(info.file or info.file_path)
        local since = nil
        if state.has_synced_annos and state.last_annos_sync_at and not force_manual then
            since = state.last_annos_sync_at
        end
        local sync_start_time = os.date("!%Y-%m-%dT%H:%M:%SZ")

        self.api:list_annotations(book_id, since, function(success, remote_annos)
            if not success or not remote_annos then
                if force_manual then
                    utils.show_msg(_("Failed to fetch remote annotations."))
                end
                if callback then callback(false) end
                return
            end

            local docsettings = info.docsettings
            local target_ui = info.ui or (self.plugin and self.plugin.get_ui and self.plugin:get_ui()) or ui or self.ui
            local raw_items = docsettings and docsettings.readSetting and docsettings:readSetting("annotations") or {}

            for _, l_item in ipairs(raw_items) do
                annotations_helper.sanitize_koreader_annotation(l_item)
            end

            local modified_raw = false
            local state_annos = state.annotations or {}

            if not state.has_synced_annos then
                -- INITIAL SYNC: Safe Merge
                for _, l_item in ipairs(raw_items) do
                    if annotations_helper.is_annotation(l_item) then
                        local found = false
                        for _, r_item in ipairs(remote_annos) do
                            if annotations_helper.is_same_annotation(l_item, r_item) then
                                l_item.folio_id = r_item.id or l_item.folio_id
                                found = true
                                break
                            end
                        end
                        if not found then
                            local folio_annot = annotations_helper.koreader_to_folio_annotation(l_item)
                            if folio_annot then
                                self.api:create_annotation(book_id, folio_annot, function(c_ok, c_data)
                                    if c_ok and c_data and c_data.id then
                                        l_item.folio_id = c_data.id
                                        modified_raw = true
                                    end
                                end)
                            end
                        end
                    end
                end

                for _, r_item in ipairs(remote_annos) do
                    local converted = annotations_helper.folio_to_koreader_annotation(r_item)
                    local found = false
                    for _, l_item in ipairs(raw_items) do
                        if annotations_helper.is_annotation(l_item) and (annotations_helper.is_same_annotation(l_item, r_item) or annotations_helper.is_same_annotation(l_item, converted)) then
                            found = true
                            break
                        end
                    end
                    if not found and converted then
                        table.insert(raw_items, converted)
                        modified_raw = true
                    end
                end

                state.has_synced_annos = true
            else
                -- SUBSEQUENT SYNC: State-aware 2-Way Sync (Local & Remote Deletions)
                local locally_deleted_ids = {} -- track folio_ids deleted in step 1

                -- 1. Local Deletions
                local snap_keys = {}
                for key, _ in pairs(state_annos) do
                    table.insert(snap_keys, key)
                end

                for _, key in ipairs(snap_keys) do
                    local snap_item = state_annos[key]
                    local found_local = false
                    for _, l_item in ipairs(raw_items) do
                        if annotations_helper.is_annotation(l_item) and annotations_helper.is_same_annotation(l_item, snap_item) then
                            found_local = true
                            break
                        end
                    end
                    if not found_local then
                        local fid = snap_item.folio_id
                        if not fid then
                            for _, r_item in ipairs(remote_annos) do
                                if annotations_helper.is_same_annotation(snap_item, r_item) then
                                    fid = r_item.id
                                    break
                                end
                            end
                        end
                        if fid then
                            self.api:delete_annotation(book_id, fid)
                            locally_deleted_ids[fid] = true
                        end
                        state_annos[key] = nil
                    end
                end

                -- 2. Remote Deletions (only on full sync, i.e. when since is nil)
                if not since then
                    snap_keys = {}
                    for key, _ in pairs(state_annos) do
                        table.insert(snap_keys, key)
                    end

                    for _, key in ipairs(snap_keys) do
                        local snap_item = state_annos[key]
                        local found_remote = false
                        for _, r_item in ipairs(remote_annos) do
                            if annotations_helper.is_same_annotation(snap_item, r_item) then
                                found_remote = true
                                break
                            end
                        end
                        if not found_remote then
                            for idx = #raw_items, 1, -1 do
                                local l_item = raw_items[idx]
                                if annotations_helper.is_annotation(l_item) and annotations_helper.is_same_annotation(l_item, snap_item) then
                                    table.remove(raw_items, idx)
                                    modified_raw = true
                                    break
                                end
                            end
                            state_annos[key] = nil
                        end
                    end
                end

                -- 3. New or modified local items -> push
                for _, l_item in ipairs(raw_items) do
                    if annotations_helper.is_annotation(l_item) then
                        local snap_item = nil
                        for _, snap in pairs(state_annos) do
                            if annotations_helper.is_same_annotation(l_item, snap) then
                                snap_item = snap
                                break
                            end
                        end
                        local in_remote = false
                        for _, r_item in ipairs(remote_annos) do
                            if annotations_helper.is_same_annotation(l_item, r_item) then
                                l_item.folio_id = r_item.id or l_item.folio_id
                                in_remote = true
                                break
                            end
                        end
                        if not snap_item and not in_remote then
                            local folio_annot = annotations_helper.koreader_to_folio_annotation(l_item)
                            if folio_annot then
                                self.api:create_annotation(book_id, folio_annot, function(c_ok, c_data)
                                    if c_ok and c_data and c_data.id then
                                        l_item.folio_id = c_data.id
                                        modified_raw = true
                                    end
                                end)
                            end
                        elseif snap_item and (l_item.folio_id or snap_item.folio_id) then
                            local fid = l_item.folio_id or snap_item.folio_id
                            if (l_item.note or "") ~= (snap_item.note or "") or (l_item.text or "") ~= (snap_item.text or "") or (l_item.color or "yellow") ~= (snap_item.color or "yellow") then
                                local folio_annot = annotations_helper.koreader_to_folio_annotation(l_item)
                                if folio_annot and fid then
                                    self.api:update_annotation(book_id, fid, folio_annot)
                                end
                            end
                        end
                    end
                end

                -- 4. New remote items -> pull
                for _, r_item in ipairs(remote_annos) do
                    -- Skip items we just deleted locally in step 1
                    if not (r_item.id and locally_deleted_ids[r_item.id]) then
                        local converted = annotations_helper.folio_to_koreader_annotation(r_item)
                        local in_state = false
                        for _, snap in pairs(state_annos) do
                            if annotations_helper.is_same_annotation(converted, snap) or (snap.folio_id and r_item.id and snap.folio_id == r_item.id) then
                                in_state = true
                                break
                            end
                        end
                        local in_local = false
                        for _, l_item in ipairs(raw_items) do
                            if annotations_helper.is_annotation(l_item) and (annotations_helper.is_same_annotation(l_item, r_item) or annotations_helper.is_same_annotation(l_item, converted)) then
                                l_item.folio_id = r_item.id or l_item.folio_id
                                in_local = true
                                break
                            end
                        end
                        if not in_state and not in_local and converted then
                            table.insert(raw_items, converted)
                            modified_raw = true
                        end
                    end
                end
            end

            if modified_raw then
                if target_ui and target_ui.annotation and target_ui.annotation.sortItems then
                    target_ui.annotation:sortItems(raw_items)
                else
                    annotations_helper.sort_by_position(raw_items)
                end
            end

            -- Update state snapshot with current active items
            local new_state_annos = {}
            for idx, l_item in ipairs(raw_items) do
                if annotations_helper.is_annotation(l_item) then
                    local key = l_item.folio_id or l_item.pos0 or string.format("idx_%d", idx)
                    new_state_annos[key] = {
                        folio_id = l_item.folio_id,
                        pos0 = l_item.pos0,
                        pos1 = l_item.pos1,
                        text = l_item.text,
                        note = l_item.note,
                        color = l_item.color,
                    }
                end
            end
            state.has_synced_annos = true
            state.last_annos_sync_at = sync_start_time
            state.annotations = new_state_annos
            self:save_sync_state(state, info.file or info.file_path)

            if modified_raw and docsettings and docsettings.saveSetting then
                docsettings:saveSetting("annotations", raw_items)
                if docsettings.flush then
                    docsettings:flush()
                elseif docsettings.save then
                    docsettings:save()
                end
                if target_ui and target_ui.annotation then
                    target_ui.annotation.annotations = raw_items
                    if target_ui.annotation.onSaveSettings then
                        target_ui.annotation:onSaveSettings()
                    end
                end
                UIManager:broadcastEvent(Event:new("AnnotationsModified", raw_items))
            end

            if force_manual then
                utils.show_msg(_("Annotations synchronized with Folio!"))
            end

            if callback then callback(true) end
        end)
    end)
end

-- Synchronize both annotations and bookmarks for current document
function Manager:sync_annotations_and_bookmarks(ui, document, force_manual, callback)
    if force_manual then
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

-- Synchronize bookmarks for current document (State-Aware 2-Way Sync)
function Manager:sync_bookmarks(ui, document, force_manual, callback)
    if not self.api:has_auth() then
        if callback then callback(false) end
        return
    end

    local info = self:get_doc_info(ui, document)
    if not info then
        if callback then callback(false) end
        return
    end

    self:resolve_book_id(ui, document, function(book_id)
        if not book_id then
            if callback then callback(false) end
            return
        end

        local state = self:load_sync_state(info.file or info.file_path)
        local since = nil
        if state.has_synced_bms and state.last_bms_sync_at and not force_manual then
            since = state.last_bms_sync_at
        end
        local sync_start_time = os.date("!%Y-%m-%dT%H:%M:%SZ")

        self.api:list_bookmarks(book_id, since, function(success, remote_bms)
            if not success or not remote_bms then
                if callback then callback(false) end
                return
            end

            local docsettings = info.docsettings
            local target_ui = info.ui or (self.plugin and self.plugin.get_ui and self.plugin:get_ui()) or ui or self.ui
            local raw_items = docsettings and docsettings.readSetting and docsettings:readSetting("annotations") or {}

            for _, l_item in ipairs(raw_items) do
                annotations_helper.sanitize_koreader_annotation(l_item)
            end

            local modified_raw = false
            local state_bms = state.bookmarks or {}

            if not state.has_synced_bms then
                -- INITIAL SYNC: Safe Merge
                for _, l_item in ipairs(raw_items) do
                    if annotations_helper.is_bookmark(l_item) then
                        local found = false
                        for _, r_bm in ipairs(remote_bms) do
                            if annotations_helper.is_same_bookmark(l_item, r_bm) then
                                l_item.folio_id = r_bm.id or l_item.folio_id
                                found = true
                                break
                            end
                        end
                        if not found then
                            local folio_bm = annotations_helper.koreader_to_folio_bookmark(l_item)
                            if folio_bm then
                                self.api:create_bookmark(book_id, folio_bm, function(c_ok, c_data)
                                    if c_ok and c_data and c_data.id then
                                        l_item.folio_id = c_data.id
                                        modified_raw = true
                                    end
                                end)
                            end
                        end
                    end
                end

                for _, r_bm in ipairs(remote_bms) do
                    local converted = annotations_helper.folio_to_koreader_bookmark(r_bm)
                    local found = false
                    for _, l_item in ipairs(raw_items) do
                        if annotations_helper.is_bookmark(l_item) and (annotations_helper.is_same_bookmark(l_item, r_bm) or annotations_helper.is_same_bookmark(l_item, converted)) then
                            found = true
                            break
                        end
                    end
                    if not found and converted then
                        table.insert(raw_items, converted)
                        modified_raw = true
                    end
                end

                state.has_synced_bms = true
            else
                -- SUBSEQUENT SYNC: State-aware 2-Way Sync (Local & Remote Deletions)
                local locally_deleted_ids = {} -- track folio_ids deleted in step 1

                -- 1. Local Deletions
                local snap_keys = {}
                for key, _ in pairs(state_bms) do
                    table.insert(snap_keys, key)
                end

                for _, key in ipairs(snap_keys) do
                    local snap_bm = state_bms[key]
                    local found_local = false
                    for _, l_item in ipairs(raw_items) do
                        if annotations_helper.is_bookmark(l_item) and annotations_helper.is_same_bookmark(l_item, snap_bm) then
                            found_local = true
                            break
                        end
                    end
                    if not found_local then
                        local fid = snap_bm.folio_id
                        if not fid then
                            for _, r_bm in ipairs(remote_bms) do
                                if annotations_helper.is_same_bookmark(snap_bm, r_bm) then
                                    fid = r_bm.id
                                    break
                                end
                            end
                        end
                        if fid then
                            self.api:delete_bookmark(book_id, fid)
                            locally_deleted_ids[fid] = true
                        end
                        state_bms[key] = nil
                    end
                end

                -- 2. Remote Deletions (only on full sync, i.e. when since is nil)
                if not since then
                    snap_keys = {}
                    for key, _ in pairs(state_bms) do
                        table.insert(snap_keys, key)
                    end

                    for _, key in ipairs(snap_keys) do
                        local snap_bm = state_bms[key]
                        local found_remote = false
                        for _, r_bm in ipairs(remote_bms) do
                            if annotations_helper.is_same_bookmark(snap_bm, r_bm) then
                                found_remote = true
                                break
                            end
                        end
                        if not found_remote then
                            for idx = #raw_items, 1, -1 do
                                local l_item = raw_items[idx]
                                if annotations_helper.is_bookmark(l_item) and annotations_helper.is_same_bookmark(l_item, snap_bm) then
                                    table.remove(raw_items, idx)
                                    modified_raw = true
                                    break
                                end
                            end
                            state_bms[key] = nil
                        end
                    end
                end

                -- 3. New local bookmarks -> push
                for _, l_item in ipairs(raw_items) do
                    if annotations_helper.is_bookmark(l_item) then
                        local in_state = false
                        for _, snap in pairs(state_bms) do
                            if annotations_helper.is_same_bookmark(l_item, snap) then
                                in_state = true
                                break
                            end
                        end
                        local in_remote = false
                        for _, r_bm in ipairs(remote_bms) do
                            if annotations_helper.is_same_bookmark(l_item, r_bm) then
                                l_item.folio_id = r_bm.id or l_item.folio_id
                                in_remote = true
                                break
                            end
                        end
                        if not in_state and not in_remote then
                            local folio_bm = annotations_helper.koreader_to_folio_bookmark(l_item)
                            if folio_bm then
                                self.api:create_bookmark(book_id, folio_bm, function(c_ok, c_data)
                                    if c_ok and c_data and c_data.id then
                                        l_item.folio_id = c_data.id
                                        modified_raw = true
                                    end
                                end)
                            end
                        end
                    end
                end

                -- 4. New remote bookmarks -> pull
                for _, r_bm in ipairs(remote_bms) do
                    -- Skip items we just deleted locally in step 1
                    if not (r_bm.id and locally_deleted_ids[r_bm.id]) then
                        local converted = annotations_helper.folio_to_koreader_bookmark(r_bm)
                        local in_state = false
                        for _, snap in pairs(state_bms) do
                            if annotations_helper.is_same_bookmark(converted, snap) or (snap.folio_id and r_bm.id and snap.folio_id == r_bm.id) then
                                in_state = true
                                break
                            end
                        end
                        local in_local = false
                        for _, l_item in ipairs(raw_items) do
                            if annotations_helper.is_bookmark(l_item) and (annotations_helper.is_same_bookmark(l_item, r_bm) or annotations_helper.is_same_bookmark(l_item, converted)) then
                                l_item.folio_id = r_bm.id or l_item.folio_id
                                in_local = true
                                break
                            end
                        end
                        if not in_state and not in_local and converted then
                            table.insert(raw_items, converted)
                            modified_raw = true
                        end
                    end
                end
            end

            if modified_raw then
                if target_ui and target_ui.annotation and target_ui.annotation.sortItems then
                    target_ui.annotation:sortItems(raw_items)
                else
                    annotations_helper.sort_by_position(raw_items)
                end
            end

            -- Update state snapshot with current active items
            local new_state_bms = {}
            for idx, l_item in ipairs(raw_items) do
                if annotations_helper.is_bookmark(l_item) then
                    local key = l_item.folio_id or l_item.pos0 or string.format("idx_%d", idx)
                    new_state_bms[key] = {
                        folio_id = l_item.folio_id,
                        pos0 = l_item.pos0,
                        text = l_item.text,
                    }
                end
            end
            state.has_synced_bms = true
            state.last_bms_sync_at = sync_start_time
            state.bookmarks = new_state_bms
            self:save_sync_state(state, info.file or info.file_path)

            if modified_raw and docsettings and docsettings.saveSetting then
                docsettings:saveSetting("annotations", raw_items)
                if docsettings.flush then
                    docsettings:flush()
                elseif docsettings.save then
                    docsettings:save()
                end
                if target_ui and target_ui.annotation then
                    target_ui.annotation.annotations = raw_items
                    if target_ui.annotation.onSaveSettings then
                        target_ui.annotation:onSaveSettings()
                    end
                end
                UIManager:broadcastEvent(Event:new("AnnotationsModified", raw_items))
                UIManager:broadcastEvent(Event:new("BookmarksModified", raw_items))
            end

            if callback then callback(true) end
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

        local percent = info.percent
        local location = info.location
        local is_read = self:get_doc_read_status(info)

        self.api:update_progress(book_id, location, percent, is_read, function(push_prog_ok)
            if push_prog_ok then
                self._last_pushed_percent = self._last_pushed_percent or {}
                self._last_pushed_percent[book_id] = percent
            end
            self:sync_annotations_and_bookmarks(ui, document, false)
            self:sync_reading_sessions(ui, document)
            if force_manual then
                if push_prog_ok then
                    utils.show_msg(T(_("All document data sent to Folio (%1%)!"), math.floor(percent)))
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
        local no_text = remote_pos:gsub("/text%(%)(%b[])?%.%d+$", "")
        if no_text ~= remote_pos then
            table.insert(candidates, no_text)
            table.insert(candidates, no_text .. ".0")
        end
        local text_dot0 = remote_pos:gsub("/text%(%)(%b[])?%.%d+$", ".0")
        if text_dot0 ~= remote_pos and text_dot0 ~= no_text .. ".0" then
            table.insert(candidates, text_dot0)
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

-- Fetch/pull reading progress only for current document from Folio
function Manager:pull_progress(ui, document, force_manual, callback)
    if force_manual == nil then force_manual = false end
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

        self.api:get_progress(book_id, function(prog_ok, remote_data)
            local progress_msg = ""
            if prog_ok and remote_data then
                local remote_pos = remote_data.location
                local remote_percent = remote_data.progressPercent or remote_data.progress_percent
                if remote_percent and tonumber(remote_percent) then
                    remote_percent = tonumber(remote_percent)
                end
                local remote_is_read = remote_data.isRead
                if remote_is_read == nil then remote_is_read = remote_data.is_read end

                local target_ui = info.ui or (self.plugin and self.plugin.get_ui and self.plugin:get_ui()) or ui or
                    self.ui
                local target_doc = info.document or (target_ui and target_ui.document) or document

                if (remote_pos and remote_pos ~= "") or (remote_percent and remote_percent > 0) then
                    self:goto_location(target_ui, remote_pos, remote_percent, info.total_pages, target_doc, info.title, info)
                end

                if remote_is_read == true then
                    self:set_local_read_status(info, true, info.docsettings)
                    progress_msg = _("Marked as Read")
                elseif remote_percent then
                    progress_msg = T(_("Progress: %1%"), math.floor(remote_percent))
                end
            end

            if force_manual then
                utils.show_msg(T(_("Fetched progress: %1"),
                    progress_msg ~= "" and progress_msg or _("Up to date")))
            end

            if callback then callback(prog_ok) end
        end)
    end)
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
        utils.show_msg(_("Fetching document data from Folio..."))
    end

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
    end)
end

return Manager
