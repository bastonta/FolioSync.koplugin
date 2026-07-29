-- Unit tests for FolioSync plugin logic and data conversions

local annotations = require("annotations")
local utils = require("utils")

describe("FolioSync Annotation Conversion", function()
    it("converts KOReader bookmark/highlight item to Folio REST annotation format", function()
        local kr_item = {
            datetime = "2026-07-28 12:00:00",
            text = "Highlighted text quote",
            notes = "My user note",
            pos0 = "/6/4[chapter1]!/4/2/1:0",
            pos1 = "/6/4[chapter1]!/4/2/1:50",
            color = "yellow",
        }

        local folio_item = annotations.koreader_to_folio_annotation(kr_item)

        assert.is_not_nil(folio_item)
        assert.is_equal("/6/4[chapter1]!/4/2/1:0-/6/4[chapter1]!/4/2/1:50", folio_item.cfiRange)
        assert.is_equal("Highlighted text quote", folio_item.selectedText)
        assert.is_equal("My user note", folio_item.note)
        assert.is_equal("yellow", folio_item.color)
    end)

    it("converts Folio REST annotation response item to KOReader bookmark format", function()
        local folio_item = {
            id = "12345678-1234-1234-1234-123456789abc",
            cfiRange = "epubcfi(/6/4!/4/2/1:0)",
            selectedText = "Sample quote from ebook",
            note = "Important reflection",
            color = "blue",
            updatedAt = "2026-07-28T12:00:00Z",
        }

        local kr_item = annotations.folio_to_koreader_annotation(folio_item)

        assert.is_not_nil(kr_item)
        assert.is_equal("Sample quote from ebook", kr_item.text)
        assert.is_equal("Important reflection", kr_item.notes)
        assert.is_equal("epubcfi(/6/4!/4/2/1:0)", kr_item.pos0)
        assert.is_equal("blue", kr_item.color)
        assert.is_equal("12345678-1234-1234-1234-123456789abc", kr_item.folio_id)
    end)

    it("sanitizes filenames correctly for downloading books", function()
        local clean1 = utils.sanitize_filename("Great Book: Edition 1 / Volume 2")
        assert.is_equal("Great Book_ Edition 1 _ Volume 2", clean1)

        local clean2 = utils.sanitize_filename("War & Peace")
        assert.is_equal("War & Peace", clean2)
    end)

    it("trims slashes from URLs properly", function()
        assert.is_equal("http://localhost:8080", utils.trim_slash("http://localhost:8080/"))
        assert.is_equal("http://localhost:8080", utils.trim_slash("http://localhost:8080///"))
    end)
end)

describe("FolioSync API Key Authentication", function()
    local FolioAPI = require("folio_api")

    it("verifies auth status when API Key is set", function()
        local api = FolioAPI:new({ api_key = "test_api_key_123" })
        assert.is_true(api:has_auth())
    end)

    it("generates correct headers including X-API-Key", function()
        local api = FolioAPI:new({ api_key = "secret_key_xyz" })
        local headers = api:get_headers()
        assert.is_equal("secret_key_xyz", headers["X-API-Key"])
        assert.is_equal("application/json", headers["Content-Type"])
    end)
end)

describe("FolioSync Menu Structure", function()
    local Menus = require("menus")

    it("generates valid menu structure with tools sorting hint", function()
        local fake_plugin = {
            settings = {
                server_url = "http://localhost:8080",
                api_key = "test_key",
                download_dir = "/sdcard/books",
                auto_progress_sync = true,
            },
        }
        local menus = Menus:new(fake_plugin)
        local menu_structure = menus:get_menu_structure()

        assert.is_not_nil(menu_structure)
        assert.is_equal("tools", menu_structure.sorting_hint)
        assert.is_equal("Folio Sync & Library", menu_structure.text)
        assert.is_equal(4, #menu_structure.sub_item_table)
    end)
end)

describe("FolioSync Gesture Actions Registration", function()
    it("registers set_autosync, toggle_autosync, push, pull, sync, and browse actions via onDispatcherRegisterActions", function()
        local registered_actions = {}
        package.loaded["dispatcher"] = {
            registerAction = function(self, action_id, def)
                registered_actions[action_id] = def
            end
        }
        package.loaded["ui/widget/container/widgetcontainer"] = {
            extend = function(self, obj) return obj end
        }
        package.loaded["datastorage"] = {
            getSettingsDir = function() return "/tmp" end
        }
        package.loaded["gettext"] = function(s) return s end
        package.loaded["logger"] = { info = function() end, warn = function() end }

        -- Force reload main module
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local instance = setmetatable({
            load_settings = function() return {} end,
        }, { __index = FolioSync })

        instance:onDispatcherRegisterActions()

        assert.is_not_nil(registered_actions["foliosync_set_autosync"])
        assert.is_equal("string", registered_actions["foliosync_set_autosync"].category)
        assert.is_true(registered_actions["foliosync_set_autosync"].reader)

        assert.is_not_nil(registered_actions["foliosync_toggle_autosync"])
        assert.is_equal("none", registered_actions["foliosync_toggle_autosync"].category)
        assert.is_true(registered_actions["foliosync_toggle_autosync"].reader)

        assert.is_not_nil(registered_actions["foliosync_push_doc"])
        assert.is_equal("none", registered_actions["foliosync_push_doc"].category)
        assert.is_true(registered_actions["foliosync_push_doc"].reader)

        assert.is_not_nil(registered_actions["foliosync_pull_doc"])
        assert.is_equal("none", registered_actions["foliosync_pull_doc"].category)
        assert.is_true(registered_actions["foliosync_pull_doc"].reader)

        assert.is_not_nil(registered_actions["foliosync_sync_doc"])
        assert.is_equal("none", registered_actions["foliosync_sync_doc"].category)
        assert.is_true(registered_actions["foliosync_sync_doc"].reader)
        assert.is_true(registered_actions["foliosync_sync_doc"].separator)

        assert.is_not_nil(registered_actions["foliosync_browse"])
        assert.is_true(registered_actions["foliosync_browse"].general)
    end)
end)
