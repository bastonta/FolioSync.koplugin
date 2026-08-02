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
    if not location and current_page then
        location = string.format("page_%d", current_page)
    end
    if percent == 0 and total_pages > 0 and current_page > 1 then
        percent = (current_page / total_pages) * 100
    end
    if percent > 0 and percent <= 1 then
        percent = percent * 100
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
            if success and remote_data and (remote_data.progressPercent or remote_data.progress_percent) then
                local remote_percent = remote_data.progressPercent or remote_data.progress_percent or 0
                if remote_percent <= 1 and remote_percent > 0 then
                    remote_percent = remote_percent * 100
                end
                if remote_percent > percent and not is_silent then
                    logger.info(string.format("FolioSync: remote progress (%d%%) ahead of local (%d%%)",
                        math.floor(remote_percent), math.floor(percent)))
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

            -- 2. Read local annotations from KOReader docsettings
            local docsettings = info.docsettings
            local target_ui = info.ui or (self.plugin and self.plugin.get_ui and self.plugin:get_ui()) or ui or self.ui
            local target_doc = info.document or (target_ui and target_ui.document) or document
            local raw_items = docsettings and docsettings.readSetting and docsettings:readSetting("annotations") or {}
            local local_annos = {}

            -- Sanitize pre-existing local annotations and filter only text highlights/annotations
            for _, l_item in ipairs(raw_items) do
                annotations_helper.sanitize_koreader_annotation(l_item, target_doc)
                if annotations_helper.is_annotation(l_item) then
                    table.insert(local_annos, l_item)
                end
            end

            -- 3. Merge: Push local items that are missing on remote
            for _, l_item in ipairs(local_annos) do
                local found = false
                for _, r_item in ipairs(remote_annos) do
                    if annotations_helper.is_same_annotation(l_item, r_item) then
                        found = true
                        break
                    end
                end
                if not found then
                    local folio_annot = annotations_helper.koreader_to_folio_annotation(l_item)
                    if folio_annot then
                        self.api:create_annotation(book_id, folio_annot)
                    end
                end
            end

            if force_manual then
                utils.show_msg(_("Annotations synchronized with Folio!"))
            end
        end)
    end)
end

-- Synchronize bookmarks (page dog-ears) for current document
function Manager:sync_bookmarks(ui, document, force_manual)
    if not self.api:has_auth() then return end

    local info = self:get_doc_info(ui, document)
    if not info then return end

    self:resolve_book_id(ui, document, function(book_id)
        if not book_id then return end

        self.api:list_bookmarks(book_id, function(success, remote_bms)
            if not success or not remote_bms then return end

            local docsettings = info.docsettings
            local target_ui = info.ui or (self.plugin and self.plugin.get_ui and self.plugin:get_ui()) or ui or self.ui
            local target_doc = info.document or (target_ui and target_ui.document) or document
            local raw_items = docsettings and docsettings.readSetting and docsettings:readSetting("annotations") or {}
            local legacy_bms = docsettings and docsettings.readSetting and docsettings:readSetting("bookmark") or {}
            local local_bms = {}

            for _, l_item in ipairs(raw_items) do
                annotations_helper.sanitize_koreader_annotation(l_item, target_doc)
                if annotations_helper.is_bookmark(l_item) then
                    table.insert(local_bms, l_item)
                end
            end
            for _, l_bm in ipairs(legacy_bms) do
                table.insert(local_bms, l_bm)
            end

            for _, l_bm in ipairs(local_bms) do
                local found = false
                for _, r_bm in ipairs(remote_bms) do
                    if annotations_helper.is_same_annotation(l_bm, r_bm) then
                        found = true
                        break
                    end
                end
                if not found then
                    local folio_bm = annotations_helper.koreader_to_folio_bookmark(l_bm)
                    if folio_bm then
                        self.api:create_bookmark(book_id, folio_bm)
                    end
                end
            end
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
            self:sync_bookmarks(ui, document, false)
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

-- Navigate reader UI to position/page specified by location or percentage
function Manager:goto_location(target_ui, remote_pos, remote_percent, total_pages, target_doc)
    local UIMgr = require("ui/uimanager")
    local Event = require("ui/event")

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
        logger.warn("FolioSync Manager: cannot perform goto_location, ReaderUI not found")
        return false
    end

    local doc = target_doc or ui.document

    -- 2. If remote_pos is an XPointer string (starts with '/' or contains 'DocFragment' / 'text()')
    if type(remote_pos) == "string" and remote_pos ~= "" and not remote_pos:match("^page_%d+$") then
        logger.info("FolioSync Manager: attempting jump to XPointer " .. tostring(remote_pos))

        -- Method A: KOReader's native ReaderLink widget (best precision: moves page AND scrolls to element)
        if ui.link and ui.link.onGotoLink then
            local ok = pcall(function() ui.link:onGotoLink({ xpointer = remote_pos }) end)
            if ok then
                logger.info("FolioSync Manager: successfully jumped via ui.link:onGotoLink")
                return true
            end
        end

        -- Method B: GotoPos event
        local ok_event = pcall(function()
            ui:handleEvent(Event:new("GotoPos", remote_pos))
            UIMgr:broadcastEvent(Event:new("GotoPos", remote_pos))
        end)
        if ok_event then
            logger.info("FolioSync Manager: successfully jumped via GotoPos event")
            return true
        end

        -- Method C: Resolve XPointer to page number as fallback
        if doc and doc.getPageFromXPointer then
            local ok, page_num = pcall(function() return doc:getPageFromXPointer(remote_pos) end)
            if ok and page_num and tonumber(page_num) and tonumber(page_num) > 0 then
                local target_page = tonumber(page_num)
                logger.info("FolioSync Manager: resolved XPointer fallback page " .. tostring(target_page))
                ui:handleEvent(Event:new("GotoPage", target_page))
                return true
            end
        end
    end

    -- 3. Check if remote_pos is a page_N string (e.g. "page_15")
    if type(remote_pos) == "string" then
        local target_page = remote_pos:match("^page_(%d+)$")
        if target_page then
            target_page = tonumber(target_page)
            logger.info("FolioSync Manager: restoring position page " .. tostring(target_page))
            ui:handleEvent(Event:new("GotoPage", target_page))
            return true
        end
    end

    -- 4. Fallback: navigate by percentage (0..1 or 0..100)
    if remote_percent and total_pages and total_pages > 1 then
        local pct = tonumber(remote_percent) or 0
        if pct <= 1 then pct = pct * 100 end
        local target_page = math.max(1, math.min(total_pages, math.floor((pct / 100) * total_pages + 0.5)))
        logger.info("FolioSync Manager: jumping to page " ..
            tostring(target_page) .. " via percentage fallback (" .. tostring(remote_percent) .. "%)")
        ui:handleEvent(Event:new("GotoPage", target_page))
        return true
    end

    logger.warn("FolioSync Manager: could not navigate to remote location/page")
    return false
end

-- Fetch/pull all data (progress + annotations + bookmarks) for current document from Folio
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
                if remote_percent and tonumber(remote_percent) then
                    remote_percent = tonumber(remote_percent)
                    if remote_percent <= 1 and remote_percent > 0 then
                        remote_percent = remote_percent * 100
                    end
                end
                local target_ui = info.ui or (self.plugin and self.plugin.get_ui and self.plugin:get_ui()) or ui or
                    self.ui
                local target_doc = info.document or (target_ui and target_ui.document) or document

                self:goto_location(target_ui, remote_pos, remote_percent, info.total_pages, target_doc)

                if remote_percent then
                    progress_msg = T(_("Progress: %1%%"), math.floor(remote_percent))
                end
            end

            -- 1. Pull Annotations
            self.api:list_annotations(book_id, function(anno_ok, remote_annos)
                local added_count = 0
                local docsettings = info.docsettings
                local target_ui = info.ui or (self.plugin and self.plugin.get_ui and self.plugin:get_ui()) or ui or
                    self.ui
                local target_doc = info.document or (target_ui and target_ui.document) or document

                if anno_ok and remote_annos and docsettings and docsettings.readSetting then
                    local local_annos = docsettings:readSetting("annotations") or
                        (target_ui and target_ui.annotation and target_ui.annotation.annotations) or {}

                    for _, l_item in ipairs(local_annos) do
                        annotations_helper.sanitize_koreader_annotation(l_item, target_doc)
                    end

                    for _, r_item in ipairs(remote_annos) do
                        local converted = annotations_helper.folio_to_koreader_annotation(r_item, target_doc)
                        local found_l_item = nil
                        for _, l_item in ipairs(local_annos) do
                            if annotations_helper.is_same_annotation(l_item, r_item) or annotations_helper.is_same_annotation(l_item, converted) then
                                found_l_item = l_item
                                break
                            end
                        end
                        if found_l_item then
                            found_l_item.folio_id = r_item.id or found_l_item.folio_id
                            if converted then
                                found_l_item.note = converted.note or found_l_item.note
                                found_l_item.color = converted.color or found_l_item.color
                                found_l_item.datetime_updated = converted.datetime_updated or
                                    found_l_item.datetime_updated
                            end
                            annotations_helper.sanitize_koreader_annotation(found_l_item, target_doc)
                        elseif converted then
                            table.insert(local_annos, converted)
                            added_count = added_count + 1
                        end
                    end

                    if (added_count > 0 or #local_annos > 0) and docsettings.saveSetting then
                        docsettings:saveSetting("annotations", local_annos)

                        if target_ui and target_ui.annotation then
                            target_ui.annotation.annotations = local_annos
                            if target_ui.annotation.onSaveSettings then
                                target_ui.annotation:onSaveSettings()
                            end
                        end

                        UIManager:broadcastEvent(Event:new("AnnotationsModified", local_annos))

                        if target_doc then
                            if not target_doc.is_pdf then
                                if target_doc.render then target_doc:render() end
                                if target_ui and target_ui.view and target_ui.view.recalculate then
                                    target_ui.view
                                        :recalculate()
                                end
                                if target_ui and target_ui.view and target_ui.view.dialog then
                                    UIManager:setDirty(
                                        target_ui.view.dialog, "partial")
                                end
                            else
                                if target_doc.resetTileCacheValidity then target_doc:resetTileCacheValidity() end
                                if target_ui and target_ui.view and target_ui.view.dialog then
                                    UIManager:setDirty(
                                        target_ui.view.dialog, "ui")
                                end
                            end
                        end
                    end
                end

                -- 2. Pull Bookmarks
                self.api:list_bookmarks(book_id, function(bm_ok, remote_bms)
                    local bm_added = 0
                    if bm_ok and remote_bms and docsettings and docsettings.readSetting then
                        local local_bms = docsettings:readSetting("bookmark") or
                            (target_ui and target_ui.bookmark and target_ui.bookmark.bookmark) or {}

                        for _, r_bm in ipairs(remote_bms) do
                            local converted_bm = annotations_helper.folio_to_koreader_bookmark(r_bm)
                            local found = false
                            for _, l_bm in ipairs(local_bms) do
                                if annotations_helper.is_same_annotation(l_bm, r_bm) or annotations_helper.is_same_annotation(l_bm, converted_bm) then
                                    found = true
                                    break
                                end
                            end
                            if not found and converted_bm then
                                table.insert(local_bms, converted_bm)
                                bm_added = bm_added + 1
                            end
                        end

                        if (bm_added > 0 or #local_bms > 0) and docsettings.saveSetting then
                            docsettings:saveSetting("bookmark", local_bms)
                            if target_ui and target_ui.bookmark then
                                target_ui.bookmark.bookmark = local_bms
                                if target_ui.bookmark.onSaveSettings then
                                    target_ui.bookmark:onSaveSettings()
                                end
                            end
                            UIManager:broadcastEvent(Event:new("BookmarksModified", local_bms))
                        end
                    end

                    if force_manual then
                        local total_added = added_count + bm_added
                        if total_added > 0 then
                            utils.show_msg(T(_("Fetched remote data: %1 (%2 new items)"),
                                progress_msg ~= "" and progress_msg or _("Progress updated"), total_added))
                        else
                            utils.show_msg(T(_("Fetched remote data: %1"),
                                progress_msg ~= "" and progress_msg or _("Up to date")))
                        end
                    end
                end)
            end)
        end)
    end)
end

return Manager
