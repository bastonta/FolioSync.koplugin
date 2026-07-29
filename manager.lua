local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local T = require("ffi/util").template
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

-- Get or resolve Folio book_id for current document
function Manager:resolve_book_id(document, callback)
    if not document or not document.file then
        if callback then callback(nil) end
        return nil
    end

    -- 1. Check if stored in docsettings
    local docsettings = document.docsettings
    if docsettings then
        local stored_id = docsettings:readSetting("folio_book_id")
        if stored_id and stored_id ~= "" then
            if callback then callback(stored_id) end
            return stored_id
        end
    end

    -- 2. Try to match by file hash via Folio API
    local file_hash = self:compute_file_hash(document.file)
    if file_hash then
        logger.info("FolioSync Manager: resolving book_id by hash " .. file_hash)
        self.api:find_book_by_hash(file_hash, function(success, response)
            if success and response and response.id then
                local book_id = response.id
                logger.info("FolioSync Manager: matched hash to Folio book_id " .. tostring(book_id))
                if docsettings then
                    docsettings:saveSetting("folio_book_id", book_id)
                end
                if callback then callback(book_id) end
                return
            end

            -- 3. Fallback: try to match by title / filename
            logger.info("FolioSync Manager: hash lookup failed, falling back to title search")
            self:resolve_book_id_by_title(document, callback)
        end)
    else
        -- Hash computation failed, fall back to title search
        logger.warn("FolioSync Manager: could not compute file hash, falling back to title search")
        self:resolve_book_id_by_title(document, callback)
    end
end

-- Fallback: resolve book_id by title search
function Manager:resolve_book_id_by_title(document, callback)
    local docsettings = document.docsettings
    local file_name = utils.get_file_basename(document.file)
    local title = file_name:gsub("%.%w+$", "")

    logger.info("FolioSync Manager: resolving book_id by title " .. title)
    self.api:list_books(1, 10, title, function(success, response)
        if success and response and response.items and #response.items > 0 then
            local matched_book = response.items[1]
            local book_id = matched_book.id
            logger.info("FolioSync Manager: matched " .. title .. " to Folio book_id " .. tostring(book_id))

            if docsettings then
                docsettings:saveSetting("folio_book_id", book_id)
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

    self:resolve_book_id(document, function(book_id)
        if not book_id then
            if not is_silent then
                utils.show_msg(_("Document not matched on Folio server."))
            end
            return
        end

        -- Get current local progress from KOReader
        local current_page = ui.link:getPage()
        local total_pages = ui.document:getPageCount()
        local percent = total_pages > 0 and ((current_page / total_pages) * 100) or 0
        local cfi = ui.link:calcCFI() or string.format("page_%d", current_page)

        -- Fetch remote progress first
        self.api:get_progress(book_id, function(success, remote_data)
            local should_push = true
            if success and remote_data and remote_data.progressPercent then
                local remote_percent = remote_data.progressPercent or 0
                -- If remote progress is ahead, offer to jump
                if remote_percent > percent and not is_silent then
                    logger.info(string.format("FolioSync: remote progress (%d%%) ahead of local (%d%%)", remote_percent, percent))
                end
            end

            if should_push then
                self.api:update_progress(book_id, cfi, percent, function(push_ok)
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

    self:resolve_book_id(document, function(book_id)
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
            local docsettings = document.docsettings
            local local_bookmarks = docsettings and docsettings:readSetting("bookmark") or {}

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

    if not document or not document.file then
        if force_manual then
            utils.show_msg(_("No active document open."))
        end
        return
    end

    self:resolve_book_id(document, function(book_id)
        if not book_id then
            if force_manual then
                utils.show_msg(_("Document not matched on Folio server."))
            end
            return
        end

        if force_manual then
            utils.show_msg(_("Pushing all document data to Folio..."))
        end

        local current_page = ui.link and ui.link:getPage() or 1
        local total_pages = ui.document and ui.document:getPageCount() or 1
        local percent = total_pages > 0 and ((current_page / total_pages) * 100) or 0
        local cfi = (ui.link and ui.link:calcCFI()) or string.format("page_%d", current_page)

        self.api:update_progress(book_id, cfi, percent, function(push_prog_ok)
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

    if not document or not document.file then
        if force_manual then
            utils.show_msg(_("No active document open."))
        end
        return
    end

    self:resolve_book_id(document, function(book_id)
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
                local remote_cfi = remote_data.cfi or remote_data.cfiRange
                local remote_percent = remote_data.progressPercent or remote_data.progress_percent
                if remote_cfi and remote_cfi ~= "" and ui.link and ui.link.onGoToCFI then
                    ui.link:onGoToCFI(remote_cfi)
                elseif remote_percent and ui.document then
                    local total_pages = ui.document:getPageCount()
                    if total_pages and total_pages > 0 then
                        local target_page = math.max(1, math.min(total_pages, math.floor((remote_percent / 100) * total_pages)))
                        if ui.link and ui.link.goToPage then
                            ui.link:goToPage(target_page)
                        end
                    end
                end
                if remote_percent then
                    progress_msg = T(_("Progress: %1%%"), math.floor(remote_percent))
                end
            end

            self.api:list_annotations(book_id, function(anno_ok, remote_annos)
                local added_count = 0
                if anno_ok and remote_annos then
                    local docsettings = document.docsettings
                    local local_bookmarks = docsettings and docsettings:readSetting("bookmark") or {}

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

                    if added_count > 0 and docsettings then
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
