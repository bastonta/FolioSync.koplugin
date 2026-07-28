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

    -- 2. Try to match by title / filename via Folio API search
    local file_name = utils.get_file_basename(document.file)
    local title = file_name:gsub("%.%w+$", "")

    logger.info("FolioSync Manager: resolving book_id for " .. title)
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

return Manager
