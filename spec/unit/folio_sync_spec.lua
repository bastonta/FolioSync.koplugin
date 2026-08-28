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
    dbg = function(...) end,
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
        local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
        temp_dir = temp_dir:gsub("\\", "/")
        package.loaded["datastorage"] = {
            getSettingsDir = function() return temp_dir end
        }
        local Manager = require("manager")
        local mgr = setmetatable({}, { __index = Manager })
        local file_path = temp_dir .. "/test_book_123.epub"
        local sdr_dir = temp_dir .. "/test_book_123.sdr"
        local ok_lfs, lfs = pcall(require, "lfs")
        if ok_lfs and lfs and lfs.mkdir then
            lfs.mkdir(sdr_dir)
        else
            os.execute('mkdir "' .. sdr_dir:gsub("/", "\\") .. '" 2>nul || mkdir -p "' .. sdr_dir .. '" 2>/dev/null')
        end

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
        if ok_lfs and lfs and lfs.rmdir then
            lfs.rmdir(sdr_dir)
        else
            os.remove(sdr_dir)
        end
    end)

    it("sanitizes filenames correctly for downloading books", function()
        local clean1 = utils.sanitize_filename("Great Book: Edition 1 / Volume 2")
        assert.is_equal("Great Book_ Edition 1 _ Volume 2", clean1)

        local clean2 = utils.sanitize_filename("War & Peace")
        assert.is_equal("War & Peace", clean2)
    end)

    it("builds book target directories correctly with series and subseries", function()
        local base = "/sdcard/books/FolioSync"
        assert.is_equal("/sdcard/books/FolioSync", utils.build_book_target_dir(base, nil))
        assert.is_equal("/sdcard/books/FolioSync", utils.build_book_target_dir(base, ""))
        assert.is_equal("/sdcard/books/FolioSync/Harry Potter", utils.build_book_target_dir(base, "Harry Potter"))
        assert.is_equal("/sdcard/books/FolioSync/Cosmere/Stormlight Archive", utils.build_book_target_dir(base, "Cosmere/Stormlight Archive"))
        assert.is_equal("/sdcard/books/FolioSync/Sci-Fi_ Space/Book Series", utils.build_book_target_dir(base, "Sci-Fi: Space/Book Series"))
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
        FolioAPI = require("folio_api")
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

    it("does NOT call goto_location when local progress is behind remote progress (e.g. on page 1 or bookmark jump)", function()
        local goto_location_called = false
        local pushed = false

        local fake_api = {
            has_auth = function() return true end,
            get_progress = function(self, book_id, cb)
                cb(true, { progressPercent = 75, isRead = false, location = "/6/20" })
            end,
            update_progress = function(self, book_id, loc, pct, is_read, cb)
                pushed = true
                if cb then cb(true) end
            end
        }

        local mock_ds = {
            readSetting = function(self, k)
                if k == "summary" then return { status = "reading" } end
                if k == "folio_book_id" then return "uuid-book-123" end
                return nil
            end
        }

        local fake_ui = {
            document = { file = "/books/test.epub" },
            doc_settings = mock_ds,
            getCurrentPage = function() return 1 end,
            paging = {
                getLastPercent = function() return 0 end,
                getLastProgress = function() return "/6/1" end,
            }
        }

        local mgr = setmetatable({
            api = fake_api,
            ui = fake_ui,
            goto_location = function()
                goto_location_called = true
            end,
        }, { __index = Manager })

        mgr:sync_progress(fake_ui, fake_ui.document, true)

        assert.is_false(goto_location_called)
        assert.is_false(pushed)
    end)

    it("marks book as complete locally when remote_data.isRead is true during pull_all_data", function()
        local fake_api = {
            has_auth = function() return true end,
            get_progress = function(self, book_id, cb)
                cb(true, { progressPercent = 80, isRead = true, location = "/6/10" })
            end,
            list_annotations = function(self, book_id, since_or_cb, maybe_cb)
                local cb = type(since_or_cb) == "function" and since_or_cb or maybe_cb
                if cb then cb(true, {}) end
            end,
            list_bookmarks = function(self, book_id, since_or_cb, maybe_cb)
                local cb = type(since_or_cb) == "function" and since_or_cb or maybe_cb
                if cb then cb(true, {}) end
            end,
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
    it("registers set_autosync, toggle_autosync, toggle_series_folders, push, pull, toggle_read, sync, and browse actions", function()
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
        assert.is_not_nil(registered_actions["foliosync_toggle_series_folders"])
        assert.is_not_nil(registered_actions["foliosync_push_doc"])
        assert.is_not_nil(registered_actions["foliosync_pull_doc"])
        assert.is_not_nil(registered_actions["foliosync_toggle_read"])
        assert.is_not_nil(registered_actions["foliosync_sync_doc"])
        assert.is_not_nil(registered_actions["foliosync_browse"])
    end)
end)

describe("FolioSync Series and Subseries Resolution", function()
    local FolioBrowser = require("browser")

    it("resolves direct series and nested subseries paths", function()
        local fake_api = {
            get_series = function(self)
                return true, {
                    { id = "s1", name = "Fantasy Universe", parentId = nil },
                    { id = "s2", name = "The Archive Saga", parentId = "s1" },
                    { id = "s3", name = "Standalone Series", parentId = nil },
                }
            end,
            get_book = function(self, book_id)
                if book_id == "b1" then
                    return true, {
                        id = "b1",
                        title = "Book 1",
                        series = {
                            { id = "s2", name = "The Archive Saga", parentId = "s1" }
                        }
                    }
                elseif book_id == "b2" then
                    return true, {
                        id = "b2",
                        title = "Book 2",
                        series = {
                            { id = "s3", name = "Standalone Series", parentId = nil }
                        }
                    }
                elseif book_id == "b3" then
                    return true, {
                        id = "b3",
                        title = "Book 3",
                        series = {}
                    }
                end
                return false, "not found"
            end,
        }

        local fake_plugin = {
            settings = {
                create_series_folders = true,
                download_dir = "/sdcard/books/FolioSync",
            }
        }

        local browser = setmetatable({
            api = fake_api,
            plugin = fake_plugin,
            paths = {},
        }, { __index = FolioBrowser })

        -- Nested series (s1 -> s2)
        local path1 = browser:resolve_series_path({ id = "b1", title = "Book 1" })
        assert.is_equal("Fantasy Universe/The Archive Saga", path1)

        -- Single standalone series
        local path2 = browser:resolve_series_path({ id = "b2", title = "Book 2" })
        assert.is_equal("Standalone Series", path2)

        -- No series, empty breadcrumbs -> nil
        local path3 = browser:resolve_series_path({ id = "b3", title = "Book 3" })
        assert.is_nil(path3)

        -- No series, but user is currently browsing inside a series folder
        browser.paths = { { id = "s_active", name = "Active Folder" } }
        local path4 = browser:resolve_series_path({ id = "b3", title = "Book 3" })
        assert.is_equal("Active Folder", path4)

        -- When create_series_folders is false -> returns nil
        fake_plugin.settings.create_series_folders = false
        browser.paths = {}
        local path5 = browser:resolve_series_path({ id = "b1", title = "Book 1" })
        assert.is_nil(path5)
    end)

    it("matches active breadcrumb folder when book has multiple series", function()
        local fake_api = {
            get_series = function(self)
                return true, {
                    { id = "s1", name = "Author Collection", parentId = nil },
                    { id = "s2", name = "Trilogy A", parentId = "s1" },
                    { id = "s3", name = "Anthology B", parentId = nil },
                }
            end,
            get_book = function(self, book_id)
                return true, {
                    id = "b_multi",
                    title = "Crossover Book",
                    series = {
                        { id = "s2", name = "Trilogy A", parentId = "s1" },
                        { id = "s3", name = "Anthology B", parentId = nil },
                    }
                }
            end,
        }

        local fake_plugin = {
            settings = {
                create_series_folders = true,
                download_dir = "/sdcard/books/FolioSync",
            }
        }

        local browser = setmetatable({
            api = fake_api,
            plugin = fake_plugin,
            paths = { { id = "s3", name = "Anthology B" } },
        }, { __index = FolioBrowser })

        -- Matches active folder "Anthology B"
        local matched_path = browser:resolve_series_path({ id = "b_multi", title = "Crossover Book" })
        assert.is_equal("Anthology B", matched_path)

        -- When at root (no active folder), picks longest candidate path ("Author Collection/Trilogy A")
        browser.paths = {}
        local longest_path = browser:resolve_series_path({ id = "b_multi", title = "Crossover Book" })
        assert.is_equal("Author Collection/Trilogy A", longest_path)
    end)
end)


describe("FolioSync Suspend & Resume & Event Handling", function()
    it("calls sync_progress ONLY onSuspend when auto_progress_sync is enabled", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local progress_synced = false
        local annotations_synced = false
        local fake_ui = { document = { file = "/books/test.epub" } }

        local fake_manager = {
            sync_progress = function(self, ui, doc, silent)
                progress_synced = true
            end,
            sync_annotations_and_bookmarks = function(self, ui, doc, force_manual)
                annotations_synced = true
            end,
        }

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        instance:onSuspend()

        assert.is_true(progress_synced)
        assert.is_false(annotations_synced)
    end)

    it("does not sync onSuspend when auto_progress_sync is disabled", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local progress_synced = false
        local annotations_synced = false
        local fake_ui = { document = { file = "/books/test.epub" } }

        local fake_manager = {
            sync_progress = function(self, ui, doc, silent) progress_synced = true end,
            sync_annotations_and_bookmarks = function(self, ui, doc, force_manual) annotations_synced = true end,
        }

        local instance = setmetatable({
            settings = { auto_progress_sync = false },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        instance:onSuspend()

        assert.is_false(progress_synced)
        assert.is_false(annotations_synced)
    end)

    it("pulls progress first, then syncs annotations once onResume when auto_progress_sync is enabled", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local call_sequence = {}
        local fake_ui = { document = { file = "/books/test.epub" } }

        local fake_manager = {
            pull_progress = function(self, ui, doc, force_manual, callback)
                table.insert(call_sequence, "pull_progress")
                if callback then callback(true) end
            end,
            sync_annotations_and_bookmarks = function(self, ui, doc, force_manual)
                table.insert(call_sequence, "sync_annotations_and_bookmarks")
            end,
        }

        local UIManager = package.loaded["ui/uimanager"]
        UIManager.scheduleIn = function(self, delay, cb)
            cb()
        end

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        instance:onResume()

        assert.is_equal(2, #call_sequence)
        assert.is_equal("pull_progress", call_sequence[1])
        assert.is_equal("sync_annotations_and_bookmarks", call_sequence[2])
    end)

    it("pulls progress first, then syncs annotations once onReaderReady when opening a book with auto_progress_sync enabled", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local call_sequence = {}
        local fake_ui = { document = { file = "/books/test.epub" } }

        local fake_manager = {
            pull_progress = function(self, ui, doc, force_manual, callback)
                table.insert(call_sequence, "pull_progress")
                if callback then callback(true) end
            end,
            sync_annotations_and_bookmarks = function(self, ui, doc, force_manual)
                table.insert(call_sequence, "sync_annotations_and_bookmarks")
            end,
        }

        local UIManager = package.loaded["ui/uimanager"]
        UIManager.scheduleIn = function(self, delay, cb)
            cb()
        end

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
            onDispatcherRegisterActions = function(self) end,
        }, { __index = FolioSync })

        instance:onReaderReady()

        assert.is_equal(2, #call_sequence)
        assert.is_equal("pull_progress", call_sequence[1])
        assert.is_equal("sync_annotations_and_bookmarks", call_sequence[2])
    end)

    it("syncs ONLY progress in onPageUpdate every 5s (annotations not synced on page turn)", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local progress_count = 0
        local annotations_count = 0
        local fake_ui = { document = { file = "/books/test.epub" } }

        local fake_manager = {
            sync_progress = function(self, ui, doc, silent)
                progress_count = progress_count + 1
            end,
            sync_annotations_and_bookmarks = function(self, ui, doc, force_manual)
                annotations_count = annotations_count + 1
            end,
        }

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        -- 1. First page update: syncs progress only
        instance:onPageUpdate(1)
        assert.is_equal(1, progress_count)
        assert.is_equal(0, annotations_count)

        -- 2. Page update <5s later: throttled
        instance:onPageUpdate(2)
        assert.is_equal(1, progress_count)
        assert.is_equal(0, annotations_count)

        -- 3. Page update >=5s later: progress syncs again, annotations remain 0
        instance._last_progress_sync_time = os.time() - 6
        instance:onPageUpdate(3)
        assert.is_equal(2, progress_count)
        assert.is_equal(0, annotations_count)
    end)

    it("syncs ONLY progress in onCloseDocument when auto_progress_sync is enabled", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local progress_synced = false
        local annotations_synced = false
        local fake_ui = { document = { file = "/books/test.epub" } }

        local fake_manager = {
            sync_progress = function(self, ui, doc, silent)
                progress_synced = true
            end,
            sync_annotations_and_bookmarks = function(self, ui, doc, force_manual)
                annotations_synced = true
            end,
        }

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        instance:onCloseDocument()

        assert.is_true(progress_synced)
        assert.is_false(annotations_synced)
    end)

    it("immediately syncs annotations on onAnnotationsModified / onBookmarksModified when auto_progress_sync is enabled", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local annotations_sync_count = 0
        local fake_ui = { document = { file = "/books/test.epub" } }

        local fake_manager = {
            is_syncing_annotations = false,
            sync_annotations_and_bookmarks = function(self, ui, doc, force_manual)
                annotations_sync_count = annotations_sync_count + 1
            end,
        }

        local UIManager = package.loaded["ui/uimanager"]
        UIManager.scheduleIn = function(self, delay, cb)
            cb()
        end

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        -- 1. User adds annotation
        instance:onAnnotationsModified({ { pos0 = "1", pos1 = "2" } })
        assert.is_equal(1, annotations_sync_count)

        -- 2. User adds bookmark
        instance:onBookmarksModified({ { pos0 = "10" } })
        assert.is_equal(2, annotations_sync_count)

        -- 3. While syncing (is_syncing_annotations = true), events are ignored to prevent loops
        fake_manager.is_syncing_annotations = true
        instance:onAnnotationsModified({ { pos0 = "1", pos1 = "2" } })
        assert.is_equal(2, annotations_sync_count)
    end)

    it("appends since parameter to list_annotations and list_bookmarks when since is provided", function()
        local requested_urls = {}
        package.loaded["socket.http"] = {
            request = function(req)
                table.insert(requested_urls, req.url)
                return "[]", 200, {}
            end
        }
        package.loaded["folio_api"] = nil
        local FolioAPI = require("folio_api")
        local api = FolioAPI:new({ server_url = "http://localhost:8080", api_key = "key123" })

        -- Call without since
        api:list_annotations("book1", function(ok, data) end)
        assert.is_equal("http://localhost:8080/books/book1/annotations?format=xpointer", requested_urls[1])

        -- Call with since
        api:list_annotations("book1", "2026-08-28T02:00:00Z", function(ok, data) end)
        assert.is_equal("http://localhost:8080/books/book1/annotations?format=xpointer&since=2026-08-28T02%3A00%3A00Z", requested_urls[2])

        -- Call bookmarks without since
        api:list_bookmarks("book1", function(ok, data) end)
        assert.is_equal("http://localhost:8080/books/book1/bookmarks?format=xpointer", requested_urls[3])

        -- Call bookmarks with since
        api:list_bookmarks("book1", "2026-08-28T02:00:00Z", function(ok, data) end)
        assert.is_equal("http://localhost:8080/books/book1/bookmarks?format=xpointer&since=2026-08-28T02%3A00%3A00Z", requested_urls[4])
    end)
end)

describe("FolioSync Footnote, Bookmark and Link Navigation Guards (Option 4)", function()
    it("skips progress sync in onPageUpdate when user is inside a jump stack (ui.link.location_stack)", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local progress_synced = false
        local fake_ui = {
            document = { file = "/books/test.epub" },
            link = { location_stack = { { page = 50 } } },
        }

        local fake_manager = {
            get_doc_info = function(self, ui, doc)
                return { percent = 95, location = "page_300" }
            end,
            sync_progress = function(self, ui, doc, silent)
                progress_synced = true
            end,
        }

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        -- 1. In jump stack: onPageUpdate must NOT sync
        instance:onPageUpdate(300)
        assert.is_false(progress_synced)

        -- 2. User presses Back -> stack emptied
        fake_ui.link.location_stack = {}
        instance._last_progress_sync_time = os.time() - 10
        instance:onPageUpdate(50)
        assert.is_true(progress_synced)
    end)

    it("skips progress sync in onPageUpdate when user is inside readerback location_stack", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local progress_synced = false
        local fake_ui = {
            document = { file = "/books/test.epub" },
            readerback = { location_stack = { { page = 20 } } },
        }

        local fake_manager = {
            get_doc_info = function(self, ui, doc)
                return { percent = 80, location = "page_200" }
            end,
            sync_progress = function(self, ui, doc, silent)
                progress_synced = true
            end,
        }

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        instance:onPageUpdate(200)
        assert.is_false(progress_synced)
    end)

    it("applies smart jump dwell guard on large jumps and cancels on return to reading base", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local synced_percents = {}
        local current_percent = 20
        local fake_ui = { document = { file = "/books/test.epub" } }

        local fake_manager = {
            get_doc_info = function(self, ui, doc)
                return { percent = current_percent, location = "pos" }
            end,
            sync_progress = function(self, ui, doc, silent)
                table.insert(synced_percents, current_percent)
            end,
        }

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        -- 1. Normal reading at 20%
        instance:onPageUpdate(50)
        assert.is_equal(1, #synced_percents)
        assert.is_equal(20, synced_percents[1])

        -- 2. Sudden large jump to 95% (footnote / appendix)
        current_percent = 95
        instance._last_progress_sync_time = os.time() - 10
        instance:onPageUpdate(300)
        -- Dwell guard should prevent sync immediately
        assert.is_equal(1, #synced_percents)
        assert.is_not_nil(instance._jump_pending_since)
        assert.is_equal(20, instance._jump_base_percent)

        -- 3. Return back to 20% within dwell window
        current_percent = 20
        instance._last_progress_sync_time = os.time() - 10
        instance:onPageUpdate(50)
        -- Jump guard should cancel and sync normal 20%
        assert.is_equal(2, #synced_percents)
        assert.is_equal(20, synced_percents[2])
        assert.is_nil(instance._jump_pending_since)
    end)

    it("accepts large jump after dwell time or 3 consecutive pages in jumped section", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local synced_percents = {}
        local current_percent = 20
        local fake_ui = { document = { file = "/books/test.epub" } }

        local fake_manager = {
            get_doc_info = function(self, ui, doc)
                return { percent = current_percent, location = "pos" }
            end,
            sync_progress = function(self, ui, doc, silent)
                table.insert(synced_percents, current_percent)
            end,
        }

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        -- 1. Initial 20%
        instance:onPageUpdate(50)
        assert.is_equal(1, #synced_percents)

        -- 2. Large jump to 70%
        current_percent = 70
        instance._last_progress_sync_time = os.time() - 10
        instance:onPageUpdate(200)
        assert.is_equal(1, #synced_percents) -- not synced yet

        -- 3. Next page in new chapter (consecutive page 2)
        current_percent = 71
        instance._last_progress_sync_time = os.time() - 10
        instance:onPageUpdate(201)
        assert.is_equal(1, #synced_percents) -- still in dwell

        -- 4. Next page in new chapter (consecutive page 3)
        current_percent = 72
        instance._last_progress_sync_time = os.time() - 10
        instance:onPageUpdate(202)
        -- 3 consecutive pages in new section satisfied dwell condition!
        assert.is_equal(2, #synced_percents)
        assert.is_equal(72, synced_percents[2])
    end)

    it("skips progress sync on onCloseDocument and onSuspend if in jump stack or pending jump", function()
        package.loaded["main"] = nil
        local FolioSync = require("main")

        local sync_count = 0
        local fake_ui = {
            document = { file = "/books/test.epub" },
            link = { location_stack = { { page = 10 } } },
        }

        local fake_manager = {
            sync_progress = function(self, ui, doc, silent)
                sync_count = sync_count + 1
            end,
        }

        local instance = setmetatable({
            settings = { auto_progress_sync = true },
            ui = fake_ui,
            manager = fake_manager,
            get_ui = function(self) return fake_ui end,
        }, { __index = FolioSync })

        instance:onSuspend()
        assert.is_equal(0, sync_count)

        instance:onCloseDocument()
        assert.is_equal(0, sync_count)

        -- Clear stack, but with active pending jump
        fake_ui.link.location_stack = {}
        instance._jump_pending_since = os.time()
        instance:onSuspend()
        assert.is_equal(0, sync_count)

        instance:onCloseDocument()
        assert.is_equal(0, sync_count)
    end)

    it("allows rollback in Manager:sync_progress if remote ahead progress was pushed by this session", function()
        local Manager = require("manager")
        local pushed_percent = nil

        local fake_api = {
            has_auth = function(self) return true end,
            get_progress = function(self, book_id, callback)
                -- Remote server has 95%
                callback(true, { progressPercent = 95, isRead = false })
            end,
            update_progress = function(self, book_id, location, percent, is_read, callback)
                pushed_percent = percent
                callback(true)
            end,
        }

        local mgr = Manager:new({ api = fake_api })
        mgr.resolve_book_id = function(self, ui, doc, cb) cb("book_uuid_1") end
        mgr.get_doc_read_status = function(self, info) return false end
        mgr.get_doc_info = function(self, ui, doc)
            return {
                file = "/books/test.epub",
                percent = 20,
                location = "page_50",
                total_pages = 250,
                current_page = 50,
            }
        end

        -- Record that this session previously pushed 95%
        mgr._last_pushed_percent["book_uuid_1"] = 95

        -- Now sync progress at 20%
        mgr:sync_progress({}, {}, true)

        -- Since 95% was our own push, rollback to 20% should be ALLOWED
        assert.is_equal(20, pushed_percent)
        assert.is_equal(20, mgr._last_pushed_percent["book_uuid_1"])
    end)

    it("blocks rollback in Manager:sync_progress if remote ahead progress was pushed by another device", function()
        local Manager = require("manager")
        local pushed_percent = nil

        local fake_api = {
            has_auth = function(self) return true end,
            get_progress = function(self, book_id, callback)
                -- Remote server has 95% from another device
                callback(true, { progressPercent = 95, isRead = false })
            end,
            update_progress = function(self, book_id, location, percent, is_read, callback)
                pushed_percent = percent
                callback(true)
            end,
        }

        local mgr = Manager:new({ api = fake_api })
        mgr.resolve_book_id = function(self, ui, doc, cb) cb("book_uuid_1") end
        mgr.get_doc_read_status = function(self, info) return false end
        mgr.get_doc_info = function(self, ui, doc)
            return {
                file = "/books/test.epub",
                percent = 20,
                location = "page_50",
                total_pages = 250,
                current_page = 50,
            }
        end

        -- This session only pushed 15% previously (95% came from another device)
        mgr._last_pushed_percent["book_uuid_1"] = 15

        -- Now sync progress at 20%
        mgr:sync_progress({}, {}, true)

        -- Remote 95% from another device is protected -> push blocked
        assert.is_nil(pushed_percent)
    end)
end)

