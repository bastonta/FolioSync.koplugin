-- Mock common KOReader and Lua modules for standalone test execution
local ok_dk, dkjson = pcall(require, "dkjson")
if ok_dk and dkjson then
    package.loaded["json"] = {
        encode = dkjson.encode,
        decode = dkjson.decode,
    }
end

package.loaded["ui/uimanager"] = package.loaded["ui/uimanager"] or {
    show = function(self, widget) end,
    close = function(self, widget) end,
    broadcastEvent = function(self, evt) end,
}
package.loaded["ui/widget/infomessage"] = package.loaded["ui/widget/infomessage"] or {
    new = function(self, o) return o end,
}
package.loaded["ui/widget/confirmbox"] = package.loaded["ui/widget/confirmbox"] or {
    new = function(self, o) return o end,
}
package.loaded["ui/widget/inputdialog"] = package.loaded["ui/widget/inputdialog"] or {
    new = function(self, o) return o end,
}
package.loaded["ui/widget/menu"] = package.loaded["ui/widget/menu"] or {
    extend = function(self, obj) return obj end,
    init = function(self) end,
    new = function(self, o) return o end,
}
package.loaded["ui/widget/container/widgetcontainer"] = package.loaded["ui/widget/container/widgetcontainer"] or {
    extend = function(self, obj) return obj end,
}
package.loaded["ui/event"] = package.loaded["ui/event"] or {
    new = function(self, name, arg)
        return { name = name, arg = arg }
    end
}
package.loaded["logger"] = package.loaded["logger"] or {
    info = function(...) end,
    warn = function(...) end,
    error = function(...) end,
}
package.loaded["gettext"] = package.loaded["gettext"] or function(s) return s end
package.loaded["ffi/util"] = package.loaded["ffi/util"] or {
    template = function(tmpl, ...)
        local args = { ... }
        return (tmpl:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)] or "") end))
    end
}

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
        assert.is_equal("/6/4[chapter1]!/4/2/1:0", folio_item.locationStart)
        assert.is_equal("/6/4[chapter1]!/4/2/1:50", folio_item.locationEnd)
        assert.is_equal("Highlighted text quote", folio_item.selectedText)
        assert.is_equal("My user note", folio_item.note)
        assert.is_equal("yellow", folio_item.color)
    end)

    it("converts Folio REST annotation response item to KOReader bookmark format", function()
        local folio_item = {
            id = "12345678-1234-1234-1234-123456789abc",
            locationStart = "/6/4!/4/2/1:0",
            selectedText = "Sample quote from ebook",
            note = "Important reflection",
            color = "blue",
            updatedAt = "2026-07-28T12:00:00Z",
        }

        local kr_item = annotations.folio_to_koreader_annotation(folio_item)

        assert.is_not_nil(kr_item)
        assert.is_equal("Sample quote from ebook", kr_item.text)
        assert.is_equal("Important reflection", kr_item.note)
        assert.is_equal("/6/4!/4/2/1:0", kr_item.pos0)
        assert.is_equal("blue", kr_item.color)
        assert.is_equal("12345678-1234-1234-1234-123456789abc", kr_item.folio_id)
    end)

    it("correctly identifies same bookmark by location or folio_id", function()
        local bm1 = { page = 15, pos0 = "page_15", text = "Chapter 2" }
        local bm2 = { page = 15, pos0 = "page_15", text = "Different title" }
        local bm3 = { page = 20, pos0 = "page_20", text = "Chapter 2" }

        assert.is_true(annotations.is_same_bookmark(bm1, bm2))
        assert.is_false(annotations.is_same_bookmark(bm1, bm3))

        local bm_with_id1 = { pos0 = "page_5", folio_id = "uuid-123" }
        local bm_with_id2 = { pos0 = "page_10", folio_id = "uuid-123" }
        assert.is_true(annotations.is_same_bookmark(bm_with_id1, bm_with_id2))
    end)

    it("manages sync state persistence", function()
        package.loaded["datastorage"] = {
            getSettingsDir = function() return "/tmp" end
        }
        local Manager = require("manager")
        local mgr = setmetatable({}, { __index = Manager })
        local file_path = "/tmp/test_book_123.epub"
        local sdr_dir = "/tmp/test_book_123.sdr"
        os.execute("mkdir -p " .. sdr_dir)

        local initial_state = mgr:load_sync_state(file_path)
        assert.is_false(initial_state.has_synced_annos)
        assert.is_false(initial_state.has_synced_bms)

        local new_state = {
            has_synced_annos = true,
            has_synced_bms = true,
            annotations = { ["a1"] = { pos0 = "page_1", text = "hello" } },
            bookmarks = { ["b1"] = { pos0 = "page_5", text = "bookmark" } },
        }
        assert.is_true(mgr:save_sync_state(file_path, new_state))

        local reloaded = mgr:load_sync_state(file_path)
        assert.is_true(reloaded.has_synced_annos)
        assert.is_true(reloaded.has_synced_bms)
        assert.is_equal("page_1", reloaded.annotations["a1"].pos0)
        assert.is_equal("page_5", reloaded.bookmarks["b1"].pos0)

        os.remove(sdr_dir .. "/folio_sync_state.json")
        os.remove(sdr_dir)
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

describe("FolioSync API Key Authentication and Read Status", function()
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

    it("sends isRead field in update_progress payload", function()
        local captured_payload = nil
        package.loaded["socket.http"] = {
            request = function(req)
                if req.source then
                    local chunks = {}
                    while true do
                        local chunk = req.source()
                        if not chunk then break end
                        table.insert(chunks, chunk)
                    end
                    captured_payload = table.concat(chunks)
                end
                return "{}", 200, {}
            end
        }
        package.loaded["ltn12"] = {
            source = {
                string = function(s)
                    return function()
                        local res = s
                        s = nil
                        return res
                    end
                end
            },
            sink = {
                table = function(t)
                    return function(chunk)
                        if chunk then table.insert(t, chunk) end
                        return 1
                    end
                end
            }
        }

        package.loaded["folio_api"] = nil
        local FolioAPI = require("folio_api")
        local api = FolioAPI:new({ server_url = "http://localhost:8080", api_key = "key123" })

        api:update_progress("book1", "/6/4", 50.5, true)
        assert.is_not_nil(captured_payload)
        local data = (package.loaded["json"]).decode(captured_payload)
        assert.is_equal(true, data.isRead)
        assert.is_equal(50.5, data.progressPercent)
        assert.is_equal("/6/4", data.location)

        api:set_read_status("book1", false)
        local data2 = (package.loaded["json"]).decode(captured_payload)
        assert.is_equal(false, data2.isRead)
    end)
end)

describe("FolioSync Manager Read Status Handling", function()
    local Manager = require("manager")

    it("detects local read status from summary or 100 percent", function()
        local mgr = setmetatable({}, { __index = Manager })

        local docsettings_complete = {
            readSetting = function(self, key)
                if key == "summary" then return { status = "complete" } end
                return nil
            end
        }
        local info_complete = { docsettings = docsettings_complete, percent = 50 }
        assert.is_true(mgr:get_doc_read_status(info_complete))

        local docsettings_reading = {
            readSetting = function(self, key)
                if key == "summary" then return { status = "reading" } end
                return nil
            end
        }
        local info_reading = { docsettings = docsettings_reading, percent = 45 }
        assert.is_false(mgr:get_doc_read_status(info_reading))

        local info_hundred = { percent = 100 }
        assert.is_true(mgr:get_doc_read_status(info_hundred))
    end)

    it("updates local read status in docsettings and cache", function()
        local mgr = setmetatable({}, { __index = Manager })

        local saved_key = nil
        local saved_val = nil
        local mock_ds = {
            readSetting = function(self, k) return {} end,
            saveSetting = function(self, k, v)
                saved_key = k
                saved_val = v
            end,
            flush = function() end,
        }

        mgr:set_local_read_status({ file = "/books/test.epub" }, true, mock_ds)
        assert.is_equal("summary", saved_key)
        assert.is_equal("complete", saved_val.status)

        mgr:set_local_read_status({ file = "/books/test.epub" }, false, mock_ds)
        assert.is_equal("reading", saved_val.status)
    end)

    it("sends is_read = true during sync_progress when local status is complete", function()
        local pushed_book_id = nil
        local pushed_location = nil
        local pushed_percent = nil
        local pushed_is_read = nil

        local fake_api = {
            has_auth = function() return true end,
            get_progress = function(self, book_id, cb)
                cb(true, { progressPercent = 50, isRead = false })
            end,
            update_progress = function(self, book_id, loc, pct, is_read, cb)
                pushed_book_id = book_id
                pushed_location = loc
                pushed_percent = pct
                pushed_is_read = is_read
                if cb then cb(true) end
            end
        }

        local mock_ds = {
            readSetting = function(self, k)
                if k == "summary" then return { status = "complete" } end
                if k == "folio_book_id" then return "uuid-book-123" end
                return nil
            end
        }

        local fake_ui = {
            document = { file = "/books/test.epub" },
            doc_settings = mock_ds,
            getCurrentPage = function() return 50 end,
            paging = {
                getLastPercent = function() return 50 end,
                getLastProgress = function() return "/6/4" end,
            }
        }

        local Manager = require("manager")
        local mgr = setmetatable({
            api = fake_api,
            ui = fake_ui,
        }, { __index = Manager })

        mgr:sync_progress(fake_ui, fake_ui.document, true)

        assert.is_equal("uuid-book-123", pushed_book_id)
        assert.is_equal("/6/4", pushed_location)
        assert.is_equal(50, pushed_percent)
        assert.is_equal(true, pushed_is_read)
    end)

    it("marks book as complete locally when remote_data.isRead is true during pull_all_data", function()
        local fake_api = {
            has_auth = function() return true end,
            get_progress = function(self, book_id, cb)
                cb(true, { progressPercent = 80, isRead = true, location = "/6/10" })
            end,
            list_annotations = function(self, book_id, cb) cb(true, {}) end,
            list_bookmarks = function(self, book_id, cb) cb(true, {}) end,
        }

        local local_status = "reading"
        local mock_ds = {
            readSetting = function(self, k)
                if k == "summary" then return { status = local_status } end
                if k == "folio_book_id" then return "uuid-book-456" end
                if k == "bookmarks" or k == "annotations" then return {} end
                return nil
            end,
            saveSetting = function(self, k, v)
                if k == "summary" then local_status = v.status end
            end,
            flush = function() end,
        }

        local fake_ui = {
            document = { file = "/books/test_pull.epub" },
            doc_settings = mock_ds,
            getCurrentPage = function() return 10 end,
            paging = {
                getLastPercent = function() return 10 end,
                getLastProgress = function() return "/6/2" end,
            }
        }

        local Manager = require("manager")
        local mgr = setmetatable({
            api = fake_api,
            ui = fake_ui,
        }, { __index = Manager })

        mgr:pull_all_data(fake_ui, fake_ui.document, false)

        assert.is_equal("complete", local_status)
    end)
end)

describe("FolioSync Menu Structure", function()
    local Menus = require("menus")

    it("generates valid menu structure with tools sorting hint", function()
        local fake_plugin = {
            ui = {},
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
        assert.is_equal(5, #menu_structure.sub_item_table_func())
    end)
end)

describe("FolioSync Gesture Actions Registration", function()
    it("registers set_autosync, toggle_autosync, push, pull, toggle_read, sync, and browse actions", function()
        local registered_actions = {}
        package.loaded["dispatcher"] = {
            registerAction = function(self, action_id, def)
                registered_actions[action_id] = def
            end
        }

        -- Force reload main module
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local instance = setmetatable({
            load_settings = function() return {} end,
        }, { __index = FolioSync })

        instance:onDispatcherRegisterActions()

        assert.is_not_nil(registered_actions["foliosync_set_autosync"])
        assert.is_not_nil(registered_actions["foliosync_toggle_autosync"])
        assert.is_not_nil(registered_actions["foliosync_push_doc"])
        assert.is_not_nil(registered_actions["foliosync_pull_doc"])
        assert.is_not_nil(registered_actions["foliosync_toggle_read"])
        assert.is_not_nil(registered_actions["foliosync_sync_doc"])
        assert.is_not_nil(registered_actions["foliosync_browse"])
    end)
end)
