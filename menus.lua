local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local T = require("ffi/util").template
local utils = require("utils")

local Menus = {}

function Menus:new(plugin_instance)
    local o = {
        plugin = plugin_instance,
        api = plugin_instance.api,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function Menus:get_menu_structure()
    return {
        text = _("Folio Sync & Library"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            local items = {}

            if not self.plugin.ui.document then
                table.insert(items, {
                    text = _("📚 Browse & Download Books from Folio"),
                    callback = function()
                        self.plugin:onFolioSyncBrowse()
                    end,
                })
            end

            table.insert(items, {
                text = _("📤 Push All Data of Active Document"),
                callback = function()
                    self.plugin.manager:push_all_data(self.plugin:get_ui(), nil, true)
                end,
            })
            table.insert(items, {
                text = _("📥 Fetch All Data of Active Document"),
                callback = function()
                    self.plugin.manager:pull_all_data(self.plugin:get_ui(), nil, true)
                end,
            })
            table.insert(items, {
                text = _("🔄 Sync Active Document Annotations"),
                callback = function()
                    self.plugin.manager:sync_annotations_and_bookmarks(self.plugin:get_ui(), nil, true)
                end,
            })
            if self.plugin.ui and self.plugin.ui.document then
                table.insert(items, {
                    text = _("✓ Toggle Read Status on Folio"),
                    callback = function()
                        self:toggle_active_doc_read_status()
                    end,
                })
            end
            table.insert(items, {
                text = _("⚙️ Settings & Account"),
                sub_item_table = self:get_settings_sub_menu(),
            })

            return items
        end,
    }
end

function Menus:get_settings_sub_menu()
    local ok_uc, UpdateChecker = pcall(require, "update_checker")
    local version = (ok_uc and UpdateChecker and UpdateChecker.getCurrentVersion and UpdateChecker.getCurrentVersion())
    if not version or type(version) ~= "string" then
        local ok_ver, ver = pcall(require, "_version")
        version = (ok_ver and type(ver) == "string") and ver or "dev"
    end
    return {
        {
            text_func = function()
                local url = self.plugin.settings.server_url or _("Not set")
                return T(_("Server URL: %1"), url)
            end,
            callback = function()
                self:prompt_server_url()
            end,
        },
        {
            text_func = function()
                local key = self.plugin.settings.api_key or ""
                if key ~= "" then
                    local prefix = string.len(key) > 10 and (string.sub(key, 1, 10) .. "...") or key
                    return T(_("API Key: %1"), prefix)
                else
                    return _("API Key: Not Set (Tap to Enter API Key)")
                end
            end,
            callback = function()
                self:prompt_api_key()
            end,
        },
        {
            text_func = function()
                local dir = self.plugin.settings.download_dir or "/sdcard/books/FolioSync"
                return T(_("Download Folder: %1"), dir)
            end,
            callback = function()
                self:prompt_download_dir()
            end,
        },
        {
            text = _("Automatically Create Series Folders"),
            checked_func = function()
                return self.plugin.settings.create_series_folders ~= false
            end,
            callback = function()
                self.plugin.settings.create_series_folders = not (self.plugin.settings.create_series_folders ~= false)
                self.plugin:save_settings()
            end,
        },
        {
            text = _("Auto-sync Reading Progress"),
            checked_func = function()
                return self.plugin.settings.auto_progress_sync == true
            end,
            callback = function()
                self.plugin.settings.auto_progress_sync = not self.plugin.settings.auto_progress_sync
                self.plugin:save_settings()
            end,
        },
        {
            text = _("Auto-check for Updates"),
            checked_func = function()
                return self.plugin.settings.auto_check_updates ~= false
            end,
            callback = function()
                self.plugin.settings.auto_check_updates = not (self.plugin.settings.auto_check_updates ~= false)
                self.plugin:save_settings()
            end,
            separator = true,
        },
        {
            text = _("Check for Updates"),
            callback = function()
                self.plugin:checkForUpdates()
            end,
        },
        {
            text_func = function()
                return T(_("Version: %1 (Tap to check updates)"), version)
            end,
            callback = function()
                self.plugin:checkForUpdates()
            end,
        },
    }
end

function Menus:prompt_server_url()
    local dialog
    dialog = InputDialog:new {
        title = _("Folio Server URL"),
        input = self.plugin.settings.server_url or "http://192.168.1.100:5144/api",
        description = _("Enter the base URL of your self-hosted Folio backend."),
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
                    text = _("Save"),
                    is_default = true,
                    callback = function()
                        local url = dialog:getInputText()
                        self.plugin.settings.server_url = utils.trim_slash(url)
                        self.plugin:save_settings()
                        UIManager:close(dialog)
                        utils.show_msg(_("Server URL saved!"))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Menus:prompt_download_dir()
    local dialog
    dialog = InputDialog:new {
        title = _("Download Folder Path"),
        input = self.plugin.settings.download_dir or "/sdcard/books/FolioSync",
        description = _("Location on device where downloaded books will be stored."),
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
                    text = _("Save"),
                    is_default = true,
                    callback = function()
                        local dir = dialog:getInputText()
                        if dir and dir ~= "" then
                            self.plugin.settings.download_dir = dir
                            self.plugin:save_settings()
                            utils.show_msg(_("Download folder path updated."))
                        end
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Menus:prompt_api_key()
    local dialog
    dialog = InputDialog:new {
        title = _("Folio API Key"),
        input = self.plugin.settings.api_key or "",
        description = _("Enter API key generated from your Folio profile."),
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
                    text = _("Save"),
                    is_default = true,
                    callback = function()
                        local key = dialog:getInputText()
                        if key then
                            key = key:gsub("^%s*(.-)%s*$", "%1")
                        end
                        self.plugin.settings.api_key = key or ""
                        self.plugin:save_settings()
                        UIManager:close(dialog)
                        utils.show_msg(_("API Key saved!"))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Menus:toggle_active_doc_read_status()
    local ui = self.plugin:get_ui()
    local doc = ui and ui.document
    local info = self.plugin.manager:get_doc_info(ui, doc)
    if not info then
        utils.show_msg(_("No active document open."))
        return
    end

    local current_read = self.plugin.manager:get_doc_read_status(info)
    local target_read = not current_read

    self.plugin.manager:resolve_book_id(ui, doc, function(book_id)
        if not book_id then
            self.plugin.manager:set_local_read_status(info, target_read, info.docsettings)
            local msg = target_read and _("Marked as read locally.") or _("Marked as unread locally.")
            utils.show_msg(msg)
            return
        end

        self.api:update_progress(book_id, info.location, info.percent, target_read, function(success)
            self.plugin.manager:set_local_read_status(info, target_read, info.docsettings)
            if success then
                local msg = target_read and _("Marked as read on Folio and device.")
                    or _("Marked as unread on Folio and device.")
                utils.show_msg(msg)
            else
                utils.show_msg(_("Updated locally, but failed to sync to Folio."))
            end
        end)
    end)
end

return Menus
