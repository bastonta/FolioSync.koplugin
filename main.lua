local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local gettext = require("gettext")
local _ = gettext

local FolioAPI = require("folio_api")
local FolioBrowser = require("browser")
local Manager = require("manager")
local Menus = require("menus")
local utils = require("utils")

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/folio_settings.json"

local FolioSync = WidgetContainer:extend {
    name = "FolioSync",
    is_doc_only = false,
}

function FolioSync:init()
    self.settings = self:load_settings()
    self.api = FolioAPI:new(self.settings)
    self.manager = Manager:new(self)
    self.menus = Menus:new(self)

    self.manager.ui = self.ui

    -- Ensure the plugin is in the ReaderUI event chain
    if self.ui then
        local found = false
        for _, child in ipairs(self.ui) do
            if child == self then
                found = true
                break
            end
        end
        if not found then
            table.insert(self.ui, self)
        end
    end

    -- Load plugin translations dynamically if available for the active locale
    -- NOTE: Must happen BEFORE onDispatcherRegisterActions() so that _() calls
    -- in dispatcher title strings pick up the translated text.
    local lang = gettext.current_lang
    if lang and lang ~= "C" and lang ~= "" then
        local path = self.path or "plugins/FolioSync.koplugin"
        local mo_path = string.format("%s/l10n/%s/folio_sync.mo", path, lang)
        local f = io.open(mo_path, "r")
        if f then
            f:close()
            gettext.loadMO(mo_path)
        end
    end

    self:onDispatcherRegisterActions()

    utils.insert_after_statistics("folio_sync")
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Auto-check for updates in background (20s delay, 24h interval, Wi-Fi check)
    if self.settings.auto_check_updates ~= false then
        local last_check = G_reader_settings and G_reader_settings:readSetting("foliosync_last_update_check")
        if type(last_check) ~= "number" or os.time() - last_check >= 24 * 60 * 60 then
            local UIManager = require("ui/uimanager")
            UIManager:scheduleIn(20, function()
                local NetworkMgr = require("ui/network/manager")
                if not NetworkMgr:isWifiOn() then
                    return
                end
                local ok, err = pcall(function()
                    local UpdateChecker = require("update_checker")
                    UpdateChecker.checkForUpdates(true)
                end)
                if not ok then
                    local logger = require("logger")
                    logger.warn("FolioSync: Auto update check failed:", err)
                end
            end)
        end
    end
end

function FolioSync:addToMainMenu(menu_items)
    menu_items.folio_sync = self.menus:get_menu_structure()
end

function FolioSync:onReaderReady()
    -- self.ui is already set by KOReader's WidgetContainer system before init()
    -- ReaderReady event has no arguments, so we must NOT overwrite self.ui
    self.manager.ui = self.ui
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:onDispatcherRegisterActions()

    self._last_reading_percent = nil
    self._jump_base_percent = nil
    self._jump_pending_since = nil
    self._jump_pending_percent = nil
    self._consecutive_jump_pages = nil

    if self.settings.auto_progress_sync then
        self._is_pulling_on_open = true
        self._last_progress_sync_time = os.time() + 5
        self:pull_and_sync_all()
    end
end

function FolioSync:pull_and_sync_all(target_ui)
    local ui = target_ui or self:get_ui()
    if not (self.settings.auto_progress_sync and ui and ui.document) then
        self._is_pulling_on_open = false
        return
    end

    local now = os.time()
    if self._last_pull_and_sync_time and (now - self._last_pull_and_sync_time) < 3 then
        self._is_pulling_on_open = false
        return
    end
    self._last_pull_and_sync_time = now

    self.manager:pull_progress(ui, nil, false, function(_prog_ok)
        self._is_pulling_on_open = false
        self._last_progress_sync_time = os.time()
        if self.settings.auto_progress_sync then
            local active_ui = self:get_ui()
            if active_ui and active_ui.document then
                self.manager:sync_annotations_and_bookmarks(active_ui, active_ui.document, false)
            end
        end
    end)
end

function FolioSync:get_ui()
    if self.ui and self.ui.document then
        return self.ui
    end
    local UIManager = require("ui/uimanager")
    if UIManager._window and UIManager._window.ui and UIManager._window.ui.document then
        return UIManager._window.ui
    end
    return self.ui
end

function FolioSync:is_in_jump_stack(ui)
    local target_ui = ui or self:get_ui()
    if not target_ui then return false end
    if target_ui.link and target_ui.link.location_stack and #target_ui.link.location_stack > 0 then
        return true
    end
    if target_ui.readerback and target_ui.readerback.location_stack and #target_ui.readerback.location_stack > 0 then
        return true
    end
    return false
end

function FolioSync:load_settings()
    local data = utils.read_json(SETTINGS_FILE) or {}
    if not data.server_url then
        data.server_url = "http://192.168.1.100:8080"
    end
    if not data.download_dir then
        data.download_dir = "/sdcard/books/FolioSync"
    end
    if data.auto_progress_sync == nil then
        data.auto_progress_sync = false
    end
    if data.create_series_folders == nil then
        data.create_series_folders = true
    end
    if data.auto_check_updates == nil then
        data.auto_check_updates = true
    end
    return data
end

function FolioSync:save_settings()
    utils.write_json(SETTINGS_FILE, self.settings)
end

function FolioSync:onPageUpdate(_page_number)
    if self._is_pulling_on_open then
        return
    end
    local ui = self:get_ui()
    if not (self.settings.auto_progress_sync and ui and ui.document) then
        return
    end

    -- 1. Check if user is currently in a link / footnote / bookmark jump stack
    if self:is_in_jump_stack(ui) then
        return
    end

    local now = os.time()
    local info = self.manager and self.manager.get_doc_info and self.manager:get_doc_info(ui, ui.document)
    local percent = info and info.percent

    -- 2. Smart Jump Dwell Guard: detect large position jumps (> 5%)
    if percent then
        if self._last_reading_percent and math.abs(percent - self._last_reading_percent) > 5.0 then
            -- Check if user returned back to the baseline reading position
            if self._jump_base_percent and math.abs(percent - self._jump_base_percent) <= 2.0 then
                -- Returned back to baseline reading position
                self._last_reading_percent = percent
                self._jump_base_percent = nil
                self._jump_pending_since = nil
                self._jump_pending_percent = nil
                self._consecutive_jump_pages = nil
            else
                -- In a large jump
                if not self._jump_pending_since or (self._jump_pending_percent and math.abs(percent - self._jump_pending_percent) > 5.0) then
                    self._jump_base_percent = self._last_reading_percent
                    self._jump_pending_percent = percent
                    self._jump_pending_since = now
                    self._consecutive_jump_pages = 1
                    return
                else
                    self._consecutive_jump_pages = (self._consecutive_jump_pages or 1) + 1
                    local dwell_time = now - self._jump_pending_since
                    if dwell_time < 45 and (self._consecutive_jump_pages or 1) < 3 then
                        -- Still in dwell period, do not push yet
                        return
                    end
                    -- Dwell period satisfied: accept new reading baseline
                    self._last_reading_percent = percent
                    self._jump_base_percent = nil
                    self._jump_pending_since = nil
                    self._jump_pending_percent = nil
                    self._consecutive_jump_pages = nil
                end
            end
        else
            self._last_reading_percent = percent
            self._jump_base_percent = nil
            self._jump_pending_since = nil
            self._jump_pending_percent = nil
            self._consecutive_jump_pages = nil
        end
    end

    if not self._last_progress_sync_time or (now - self._last_progress_sync_time) >= 5 then
        self._last_progress_sync_time = now
        self.manager:sync_progress(ui, ui.document, true)
    end
end

function FolioSync:onCloseDocument()
    local ui = self:get_ui()
    if self.settings.auto_progress_sync and ui and ui.document then
        if not self:is_in_jump_stack(ui) and not self._jump_pending_since then
            self.manager:sync_progress(ui, ui.document, true)
        end
    end
end

function FolioSync:onSuspend()
    local ui = self:get_ui()
    if self.settings.auto_progress_sync and ui and ui.document then
        if not self:is_in_jump_stack(ui) and not self._jump_pending_since then
            self.manager:sync_progress(ui, ui.document, true)
        end
    end
end

function FolioSync:onResume()
    if self.settings.auto_progress_sync then
        local UIManager = require("ui/uimanager")
        if UIManager and UIManager.scheduleIn then
            UIManager:scheduleIn(1, function()
                self:pull_and_sync_all()
            end)
        else
            self:pull_and_sync_all()
        end
    end
end

function FolioSync:onAnnotationsModified(_items)
    if self.manager and self.manager.is_syncing_annotations then
        return
    end
    if self.settings.auto_progress_sync then
        local ui = self:get_ui()
        if ui and ui.document then
            local UIManager = require("ui/uimanager")
            if self._pending_annotation_sync and UIManager and UIManager.unschedule then
                UIManager:unschedule(self._pending_annotation_sync)
                self._pending_annotation_sync = nil
            end
            local sync_action
            sync_action = function()
                self._pending_annotation_sync = nil
                local current_ui = self:get_ui()
                if self.settings.auto_progress_sync and current_ui and current_ui.document then
                    self.manager:sync_annotations_and_bookmarks(current_ui, current_ui.document, false)
                end
            end
            self._pending_annotation_sync = sync_action
            if UIManager and UIManager.scheduleIn then
                UIManager:scheduleIn(0.5, sync_action)
            else
                sync_action()
            end
        end
    end
end

function FolioSync:onBookmarksModified(items)
    return self:onAnnotationsModified(items)
end

function FolioSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("foliosync_set_autosync",
        {
            category = "string",
            event = "FolioSyncToggleAutoSync",
            title = _("FolioSync: Set auto progress sync"),
            general = true,
            args = { true, false },
            toggle = { _("on"), _("off") },
        })
    Dispatcher:registerAction("foliosync_toggle_autosync",
        { category = "none", event = "FolioSyncToggleAutoSync", title = _("FolioSync: Toggle auto progress sync"), general = true, })
    Dispatcher:registerAction("foliosync_toggle_series_folders",
        { category = "none", event = "FolioSyncToggleSeriesFolders", title = _("FolioSync: Toggle create series folders"), general = true, })
    Dispatcher:registerAction("foliosync_push_doc",
        { category = "none", event = "FolioSyncPushDoc", title = _("FolioSync: Push document data to server"), reader = true, })
    Dispatcher:registerAction("foliosync_pull_doc",
        { category = "none", event = "FolioSyncPullDoc", title = _("FolioSync: Pull document data from server"), reader = true, })
    Dispatcher:registerAction("foliosync_toggle_read",
        { category = "none", event = "FolioSyncToggleRead", title = _("FolioSync: Toggle read / finished status"), reader = true, })
    Dispatcher:registerAction("foliosync_sync_doc",
        { category = "none", event = "FolioSyncCurrentDoc", title = _("FolioSync: Sync active document"), reader = true, separator = true, })
    Dispatcher:registerAction("foliosync_browse",
        { category = "none", event = "FolioSyncBrowse", title = _("FolioSync: Browse library"), general = true, })
end

function FolioSync:onFolioSyncToggleAutoSync(enable)
    if enable == nil then
        self.settings.auto_progress_sync = not self.settings.auto_progress_sync
    else
        self.settings.auto_progress_sync = enable
    end
    self:save_settings()
    local status = self.settings.auto_progress_sync and _("ON") or _("OFF")
    utils.show_msg(string.format(_("Auto progress sync: %s"), status))
    return true
end

function FolioSync:onFolioSyncToggleSeriesFolders(enable)
    if enable == nil then
        self.settings.create_series_folders = self.settings.create_series_folders == false
    else
        self.settings.create_series_folders = enable
    end
    self:save_settings()
    local status = (self.settings.create_series_folders ~= false) and _("ON") or _("OFF")
    utils.show_msg(string.format(_("Create series folders: %s"), status))
    return true
end

function FolioSync:onFolioSyncBrowse()
    local UIManager = require("ui/uimanager")
    self.browser = FolioBrowser:new {
        plugin = self,
        api = self.api,
        title = _("Folio Library"),
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        close_callback = function()
            UIManager:close(self.browser)
            self.browser = nil
        end,
    }
    UIManager:show(self.browser)
    return true
end

function FolioSync:onFolioSyncPushDoc()
    self.manager:push_all_data(self:get_ui(), nil, true)
    return true
end

function FolioSync:onFolioSyncPullDoc()
    self.manager:pull_all_data(self:get_ui(), nil, true)
    return true
end

function FolioSync:onFolioSyncToggleRead()
    self.menus:toggle_active_doc_read_status()
    return true
end

function FolioSync:onFolioSyncCurrentDoc()
    self.manager:pull_all_data(self:get_ui(), nil, false)
    self.manager:push_all_data(self:get_ui(), nil, true)
    return true
end

function FolioSync:checkForUpdates()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        local UpdateChecker = require("update_checker")
        UpdateChecker.checkForUpdates(false)
    end)
end

return FolioSync
