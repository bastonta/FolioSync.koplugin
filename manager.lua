local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
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
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Compute SHA-256 hash of a file (matches Folio server algorithm)
function Manager:compute_file_hash(file_path)
    local sha2 = nil
    -- Try to load sha2 from KOReader's ffi/sha2 or fallback to external
    local ok, mod = pcall(require, "ffi/sha2")
    if ok and mod then
        sha2 = mod
    end

    if sha2 and sha2.sha256 then
        local f = io.open(file_path, "rb")
        if not f then return nil end
        local content = f:read("*a")
        f:close()
        if not content then return nil end
        return sha2.sha256(content)
    end

    -- Fallback: use sha256sum command if available
    local cmd = string.format('sha256sum "%s"', file_path)
    local handle = io.popen(cmd)
    if not handle then return nil end
    local result = handle:read("*a")
    handle:close()
    if result and result ~= "" then
        local hash = result:match("^(%x+)")
        return hash
    end

    return nil
end

-- Extract document metadata and settings from whatever object is available (ReaderUI, Document, or DocSettings)
function Manager:get_doc_info(ui, document)
    local target_ui = ui or self.ui
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
        if target_ui.link and target_ui.link.getPage then
            local ok, page = pcall(function() return target_ui.link:getPage() end)
            if ok and page then current_page = page end
        end
        if target_ui.view and target_ui.view.getXPointer then
            local ok, xptr = pcall(function() return target_ui.view:getXPointer() end)
            if ok and xptr then location = xptr end
        end
        if not docsettings and target_ui.doc_settings then
            docsettings = target_ui.doc_settings
        end
        if not docsettings and target_ui.docsettings then
            docsettings = target_ui.docsettings
        end
    end

    -- 3. Check DocSettings object directly (if target_ui or target_doc IS a DocSettings instance)
    local ds_candidate = docsettings or (target_ui and target_ui.data and target_ui) or (target_doc and target_doc.data and target_doc)
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
            percent = data.percent_finished * 100
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
    if not location and current_page then
        location = string.format("page_%d", current_page)
    end
    if percent == 0 and total_pages > 0 and current_page > 1 then
        percent = (current_page / total_pages) * 100
    end

    return {
        file = file_path,
        title = title,
        total_pages = total_pages,
        current_page = current_page,
        location = location,
        percent = percent,
        docsettings = docsettings,
        ui = target_ui,
        document = target_doc,
    }
end

-- Get or resolve Folio book_id for current document
function Manager:resolve_book_id(ui_or_doc, callback_or_doc, maybe_callback)
    local ui = self.ui
    local document = nil
    local callback = nil

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

    -- 2. Try to match by file hash via Folio API
    local file_hash = self:compute_file_hash(info.file)
    if file_hash then
        logger.info("FolioSync Manager: resolving book_id by hash " .. file_hash)
        self.api:find_book_by_hash(file_hash, function(success, response)
            if success and response and response.id then
                local book_id = response.id
                logger.info("FolioSync Manager: matched hash to Folio book_id " .. tostring(book_id))
                if info.docsettings and info.docsettings.saveSetting then
                    info.docsettings:saveSetting("folio_book_id", book_id)
                end
                if callback then callback(book_id) end
                return
            end

            -- 3. Fallback: try to match by title / filename
            logger.info("FolioSync Manager: hash lookup failed, falling back to title search")
            self:resolve_book_id_by_info(info, callback)
        end)
    else
        -- Hash computation failed, fall back to title search
        logger.warn("FolioSync Manager: could not compute file hash, falling back to title search")
        self:resolve_book_id_by_info(info, callback)
    end
end

-- Fallback: resolve book_id by title search using doc info
function Manager:resolve_book_id_by_info(info, callback)
    local title = info.title

    logger.info("FolioSync Manager: resolving book_id by title " .. title)
    self.api:list_books(1, 10, title, function(success, response)
        if success and response and response.items and #response.items > 0 then
            local matched_book = response.items[1]
            local book_id = matched_book.id
            logger.info("FolioSync Manager: matched " .. title .. " to Folio book_id " .. tostring(book_id))

            if info.docsettings and info.docsettings.saveSetting then
                info.docsettings:saveSetting("folio_book_id", book_id)
            end
            if callback then callback(book_id) end
        else
            logger.warn("FolioSync Manager: could not match " .. title .. " on Folio server")
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

        local current_page = info.current_page
        local total_pages = info.total_pages
        local percent = info.percent
        local location = info.location

        -- Fetch remote progress first
        self.api:get_progress(book_id, function(success, remote_data)
            local should_push = true
            if success and remote_data and remote_data.progressPercent then
                local remote_percent = remote_data.progressPercent or 0
                if remote_percent > percent and not is_silent then
                    logger.info(string.format("FolioSync: remote progress (%d%%) ahead of local (%d%%)", remote_percent, percent))
                end
            end

            if should_push then
                self.api:update_progress(book_id, location, percent, function(push_ok)
                    if push_ok and not is_silent then
                        utils.show_msg(T(_("Progress synced to Folio (%1%%)"), math.floor(percent)))
                    end
                end)
            end
        end)
    end)
end

-- Synchronize annotations for current document
function Manager:sync_annotations(ui, document, force_manual)
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

    self:resolve_book_id(ui, document, function(book_id)
        if not book_id then
            if force_manual then
                utils.show_msg(_("Book not found in Folio library."))
            end
            return
        end

        if force_manual then
            utils.show_msg(_("Syncing annotations with Folio..."))
        end

        -- 1. Fetch remote annotations
        self.api:list_annotations(book_id, function(success, remote_annos)
            if not success or not remote_annos then
                if force_manual then
                    utils.show_msg(_("Failed to fetch remote annotations."))
                end
                return
            end

            -- 2. Read local bookmarks/annotations from KOReader docsettings
            local docsettings = info.docsettings
            local local_bookmarks = docsettings and docsettings.readSetting and docsettings:readSetting("bookmark") or {}

            local remote_map = {}
            for _, r_item in ipairs(remote_annos) do
                local converted = annotations_helper.folio_to_koreader_annotation(r_item)
                table.insert(remote_map, converted)
            end

            -- 3. Merge: Push local items that are missing on remote
            for _, l_item in ipairs(local_bookmarks) do
                local found = false
                for _, r_item in ipairs(remote_annos) do
                    if annotations_helper.is_same_annotation(l_item, r_item) then
                        found = true
                        break
                    end
                end
                if not found then
                    local folio_annot = annotations_helper.koreader_to_folio_annotation(l_item)
                    self.api:create_annotation(book_id, folio_annot)
                end
            end

            if force_manual then
                utils.show_msg(_("Annotations synchronized with Folio!"))
            end
        end)
    end)
end

-- Push all data (progress + annotations) for current document to Folio
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

        self.api:update_progress(book_id, location, percent, function(push_prog_ok)
            self:sync_annotations(ui, document, false)
            if force_manual then
                if push_prog_ok then
                    utils.show_msg(T(_("All document data sent to Folio (%1%%)!"), math.floor(percent)))
                else
                    utils.show_msg(_("Failed to push progress to Folio."))
                end
            end
        end)
    end)
end

-- Fetch/pull all data (progress + annotations) for current document from Folio
function Manager:pull_all_data(ui, document, force_manual)
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

    self:resolve_book_id(ui, document, function(book_id)
        if not book_id then
            if force_manual then
                utils.show_msg(_("Document not matched on Folio server."))
            end
            return
        end

        if force_manual then
            utils.show_msg(_("Fetching document data from Folio..."))
        end

        self.api:get_progress(book_id, function(prog_ok, remote_data)
            local progress_msg = ""
            if prog_ok and remote_data then
                local remote_pos = remote_data.location
                local remote_percent = remote_data.progressPercent or remote_data.progress_percent
                local target_ui = info.ui or ui or self.ui
                if remote_pos and remote_pos ~= "" and target_ui and target_ui.handleEvent then
                    target_ui:handleEvent(Event:new("GotoXPointer", remote_pos))
                elseif remote_percent and info.total_pages > 0 then
                    local target_page = math.max(1, math.min(info.total_pages, math.floor((remote_percent / 100) * info.total_pages)))
                    if target_ui and target_ui.link and target_ui.link.goToPage then
                        target_ui.link:goToPage(target_page)
                    end
                end
                if remote_percent then
                    progress_msg = T(_("Progress: %1%%"), math.floor(remote_percent))
                end
            end

            self.api:list_annotations(book_id, function(anno_ok, remote_annos)
                local added_count = 0
                local docsettings = info.docsettings
                if anno_ok and remote_annos and docsettings and docsettings.readSetting then
                    local local_bookmarks = docsettings:readSetting("bookmark") or {}

                    for _, r_item in ipairs(remote_annos) do
                        local converted = annotations_helper.folio_to_koreader_annotation(r_item)
                        local found = false
                        for _, l_item in ipairs(local_bookmarks) do
                            if annotations_helper.is_same_annotation(l_item, r_item) or annotations_helper.is_same_annotation(l_item, converted) then
                                found = true
                                break
                            end
                        end
                        if not found then
                            table.insert(local_bookmarks, converted)
                            added_count = added_count + 1
                        end
                    end

                    if added_count > 0 and docsettings.saveSetting then
                        docsettings:saveSetting("bookmark", local_bookmarks)
                    end
                end

                if force_manual then
                    if added_count > 0 then
                        utils.show_msg(T(_("Fetched remote data: %1 (%2 new annotations)"), progress_msg ~= "" and progress_msg or _("Progress updated"), added_count))
                    else
                        utils.show_msg(T(_("Fetched remote data: %1"), progress_msg ~= "" and progress_msg or _("Up to date")))
                    end
                end
            end)
        end)
    end)
end

return Manager
