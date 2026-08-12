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

            -- Only show browse on the main FileManager screen (no document open)
            if not self.plugin.ui.document then
                table.insert(items, {
                    text = _("📚 Browse & Download Books from Folio"),
                    callback = function()
                        self.plugin.browser:show()
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
            table.insert(items, {
                text = _("⚙️ Settings & Account"),
                sub_item_table = self:get_settings_sub_menu(),
            })

            return items
        end,
    }
end

function Menus:get_settings_sub_menu()
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
            text = _("Auto-sync Reading Progress"),
            checked_func = function()
                return self.plugin.settings.auto_progress_sync == true
            end,
            callback = function()
                self.plugin.settings.auto_progress_sync = not self.plugin.settings.auto_progress_sync
                self.plugin:save_settings()
            end,
        },
    }
end

function Menus:prompt_server_url()
    local dialog
    dialog = InputDialog:new {
        title = _("Folio Server URL"),
        input = self.plugin.settings.server_url or "http://192.168.1.100:8080",
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

return Menus
