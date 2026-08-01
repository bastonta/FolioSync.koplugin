local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local gettext = require("gettext")
local _ = gettext
local logger = require("logger")

local FolioAPI = require("folio_api")
local FolioBrowser = require("browser")
local Manager = require("manager")
local Menus = require("menus")
local utils = require("utils")

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/folio_settings.json"

local FolioSync = WidgetContainer:extend{
    name = "FolioSync",
    is_doc_only = false,
}

function FolioSync:init()
    self.settings = self:load_settings()
    self.api = FolioAPI:new(self.settings)
    self.manager = Manager:new(self)
    self.browser = FolioBrowser:new(self)
    self.menus = Menus:new(self)

    self.manager.ui = self.ui
    self.browser.ui = self.ui

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

    self:onDispatcherRegisterActions()

    -- Load plugin translations dynamically if available for the active locale
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

    utils.insert_after_statistics("folio_sync")
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function FolioSync:addToMainMenu(menu_items)
    menu_items.folio_sync = self.menus:get_menu_structure()
end

function FolioSync:onReaderReady()
    -- self.ui is already set by KOReader's WidgetContainer system before init()
    -- ReaderReady event has no arguments, so we must NOT overwrite self.ui
    self.manager.ui = self.ui
    self.browser.ui = self.ui
    self:onDispatcherRegisterActions()
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

function FolioSync:load_settings()
    local data = utils.read_json(SETTINGS_FILE) or {}
    if not data.server_url then
        data.server_url = "http://192.168.1.100:8080"
    end
    if not data.download_dir then
        data.download_dir = "/sdcard/books/FolioSync"
    end
    if data.auto_progress_sync == nil then
        data.auto_progress_sync = true
    end
    return data
end

function FolioSync:save_settings()
    utils.write_json(SETTINGS_FILE, self.settings)
end

function FolioSync:onPageUpdate(page_number)
    if self.settings.auto_progress_sync and self.ui and self.ui.document then
        self.manager:sync_progress(self.ui, self.ui.document, true)
    end
end

function FolioSync:onCloseDocument()
    if self.settings.auto_progress_sync and self.ui and self.ui.document then
        self.manager:sync_progress(self.ui, self.ui.document, true)
        self.manager:sync_annotations(self.ui, self.ui.document, false)
    end
end

function FolioSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("foliosync_set_autosync",
        { category="string", event="FolioSyncToggleAutoSync", title=_("FolioSync: Set auto progress sync"), reader=true,
        args={true, false}, toggle={_("on"), _("off")},})
    Dispatcher:registerAction("foliosync_toggle_autosync", { category="none", event="FolioSyncToggleAutoSync", title=_("FolioSync: Toggle auto progress sync"), reader=true,})
    Dispatcher:registerAction("foliosync_push_doc", { category="none", event="FolioSyncPushDoc", title=_("FolioSync: Push document data to server"), reader=true,})
    Dispatcher:registerAction("foliosync_pull_doc", { category="none", event="FolioSyncPullDoc", title=_("FolioSync: Pull document data from server"), reader=true,})
    Dispatcher:registerAction("foliosync_sync_doc", { category="none", event="FolioSyncCurrentDoc", title=_("FolioSync: Sync active document"), reader=true, separator=true,})
    Dispatcher:registerAction("foliosync_browse", { category="none", event="FolioSyncBrowse", title=_("FolioSync: Browse library"), general=true,})
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

function FolioSync:onFolioSyncBrowse()
    self.browser:show()
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

function FolioSync:onFolioSyncCurrentDoc()
    self.manager:pull_all_data(self:get_ui(), nil, false)
    self.manager:push_all_data(self:get_ui(), nil, true)
    return true
end

return FolioSync
