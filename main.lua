local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
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

    self:register_gestures()
    utils.insert_after_statistics("folio_sync")
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function FolioSync:addToMainMenu(menu_items)
    menu_items.folio_sync = self.menus:get_menu_structure()
end

function FolioSync:onReaderReady(ui)
    self.ui = ui
    self.manager.ui = ui
    self.browser.ui = ui
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

function FolioSync:register_gestures()
    Dispatcher:registerAction("foliosync_browse", {
        category = "none",
        event = "FolioSyncBrowse",
        title = _("FolioSync: Browse library"),
        general = true,
    })

    Dispatcher:registerAction("foliosync_sync_doc", {
        category = "none",
        event = "FolioSyncCurrentDoc",
        title = _("FolioSync: Sync active document"),
        general = true,
    })
end

function FolioSync:onFolioSyncBrowse()
    self.browser:show()
    return true
end

function FolioSync:onFolioSyncCurrentDoc()
    if self.ui and self.ui.document then
        self.manager:sync_annotations(self.ui, self.ui.document, true)
        self.manager:sync_progress(self.ui, self.ui.document, false)
    else
        utils.show_msg(_("No active document open."))
    end
    return true
end

return FolioSync
