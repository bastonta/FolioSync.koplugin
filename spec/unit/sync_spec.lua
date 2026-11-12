-- Synchronization rules: which local file is which server book, what is sent and when,
-- and what happens to bookmarks and highlights when a request fails.

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
local Manager = require("manager")

local tmp_counter = 0
local function tmp_dir()
    local base = os.getenv("TMPDIR") or "/tmp"
    tmp_counter = tmp_counter + 1
    -- (a name of its own even when the suite runs twice within a second)
    local unique = os.tmpname()
    os.remove(unique)
    local dir = string.format("%s/folio_sync_spec_%d_%d_%s", base, os.time(), tmp_counter, unique:match("[^/\\]+$") or "")
    require("lfs").mkdir(dir)
    return dir
end

local function write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function new_docsettings(data)
    data = data or {}
    return {
        data = data,
        flushed = 0,
        readSetting = function(_, key) return data[key] end,
        saveSetting = function(_, key, value) data[key] = value end,
        flush = function(self) self.flushed = self.flushed + 1 end,
    }
end

describe("Helpers", function()
    it("generates a different random UUID every time", function()
        local seen = {}
        for _ = 1, 200 do
            local id = utils.generate_uuid()
            assert.is_true(utils.is_uuid(id))
            assert.is_equal("4", id:sub(15, 15))
            assert.is_truthy(id:sub(20, 20):match("[89ab]"))
            assert.is_nil(seen[id])
            seen[id] = true
        end
        -- Where the system has no random device the generator is seeded first: a fresh
        -- interpreter must not repeat the ids of the previous run
        local fallback = utils.uuid_from_seeded_fallback()
        assert.is_true(utils.is_uuid(fallback))
        assert.are_not.equal(fallback, utils.uuid_from_seeded_fallback())
    end)

    it("converts KOReader's fraction to a percentage exactly once", function()
        -- Page 4 of 600
        assert.is_true(math.abs(utils.fraction_to_percent(4 / 600) - 0.6667) < 0.001)
        assert.is_equal(100, utils.fraction_to_percent(1))
        assert.is_equal(50, utils.fraction_to_percent(0.5))
        assert.is_equal(0, utils.fraction_to_percent(nil))
        -- Not a fraction: a percentage already
        assert.is_equal(42, utils.fraction_to_percent(42))
    end)

    it("reports the first pages of a long book as a fraction of a percent", function()
        local ui = {
            document = { file = "/books/long.epub", getPageCount = function() return 600 end },
            getCurrentPage = function() return 4 end,
            rolling = {
                getLastPercent = function() return 4 / 600 end,
                getLastProgress = function() return "/body/DocFragment[2]/body/p[1]/text().0" end,
            },
        }
        local mgr = Manager:new({ api = {}, settings = {} })
        local info = mgr:get_doc_info(ui, ui.document)
        assert.is_true(math.abs(info.percent - 0.6667) < 0.001)
    end)

    it("reads RFC 3339 times and HTTP dates", function()
        local epoch = 1794477600 -- 2026-11-12T10:00:00Z
        assert.is_equal("2026-11-12T10:00:00Z", utils.iso8601(epoch))
        assert.is_equal(epoch, utils.parse_iso8601("2026-11-12T10:00:00Z"))
        assert.is_equal(epoch + 0.25, utils.parse_iso8601("2026-11-12T10:00:00.250Z"))
        assert.is_equal(epoch, utils.parse_iso8601("2026-11-12T12:00:00+02:00"))
        assert.is_nil(utils.parse_iso8601("yesterday"))
        assert.is_nil(utils.parse_iso8601(nil))
        -- Changes of several devices are ordered by these: whole seconds are not enough
        assert.is_equal("2026-11-12T10:00:00.250Z", utils.iso8601_ms(epoch + 0.25))
        assert.is_equal("2026-11-12T10:00:00.000Z", utils.iso8601_ms(epoch))
        assert.is_true(math.abs(utils.parse_iso8601(utils.iso8601_ms(epoch + 0.999)) - (epoch + 0.999)) < 0.0011)
        assert.is_true(math.abs(utils.now() - os.time()) < 2)
        assert.is_equal(epoch, utils.parse_http_date("Thu, 12 Nov 2026 10:00:00 GMT"))
    end)

    it("never lets a series name lead out of the download folder", function()
        assert.is_equal("unnamed_book", utils.sanitize_filename(".."))
        assert.is_equal("unnamed_book", utils.sanitize_filename("."))
        assert.is_equal("/books", utils.build_book_target_dir("/books", ".."))
        assert.is_equal("/books/Saga", utils.build_book_target_dir("/books", "../Saga/.."))
        assert.is_equal("/books/.. and beyond", utils.build_book_target_dir("/books", ".. and beyond"))
    end)
end)

describe("Bookmarks and highlights as KOReader keeps them", function()
    it("builds a page bookmark that KOReader does not take for a highlight", function()
        local bookmark = annotations.folio_to_koreader_bookmark({
            id = "b1", location = "/body/DocFragment[2]/body/p[4]", title = "Bookmark",
            createdAt = "2026-11-12T10:00:00Z",
        })
        assert.is_equal("/body/DocFragment[2]/body/p[4]", bookmark.page)
        assert.is_nil(bookmark.drawer)
        assert.is_nil(bookmark.pos0)
        assert.is_nil(bookmark.pos1)
        assert.is_nil(bookmark.color)
        assert.is_true(annotations.is_bookmark(bookmark))
        assert.is_falsy(annotations.is_annotation(bookmark))
        assert.is_truthy(bookmark.datetime:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$"))
    end)

    it("undoes what earlier versions wrote into page bookmarks", function()
        local damaged = { page = "/body/DocFragment[2]/body/p[4]", pos0 = "/body/DocFragment[2]/body/p[4]",
            pos1 = "", drawer = "lighten", color = "yellow", text = "in Chapter 2", datetime = "2026-07-01 10:00:00" }
        assert.is_true(annotations.repair_bookmark(damaged))
        assert.are.same({ page = "/body/DocFragment[2]/body/p[4]", text = "in Chapter 2",
            datetime = "2026-07-01 10:00:00" }, damaged)
        assert.is_false(annotations.repair_bookmark(damaged))

        -- A highlight is left alone
        local highlight = { page = "/a", pos0 = "/a", pos1 = "/b", drawer = "underscore", color = "red", text = "x" }
        assert.is_false(annotations.repair_bookmark(highlight))
        assert.is_equal("underscore", highlight.drawer)
    end)

    it("tells two highlights of the same words apart", function()
        local first = { pos0 = "/body/DocFragment[2]/body/p[1]/text().0", pos1 = "/body/DocFragment[2]/body/p[1]/text().4", text = "word" }
        local second = { pos0 = "/body/DocFragment[5]/body/p[9]/text().7", pos1 = "/body/DocFragment[5]/body/p[9]/text().11", text = "word" }
        assert.is_false(annotations.is_same_annotation(first, second))
        assert.is_true(annotations.is_same_annotation(first,
            { locationStart = "/body/DocFragment[2]/body/p/text().0", locationEnd = "/body/DocFragment[2]/body/p/text().4" }))
        -- The start of an element as the server spells it
        assert.is_true(annotations.is_same_bookmark({ page = "/body/DocFragment[3]/body/p[10]/text().0" },
            { id = "b1", location = "/body/DocFragment[3]/body/p[10].0" }))
        assert.is_false(annotations.is_same_bookmark({ page = "/body/DocFragment[3]/body/p[10]/text().7" },
            { id = "b1", location = "/body/DocFragment[3]/body/p[10].0" }))
    end)

    it("takes only strings from a server item", function()
        -- What a JSON decoder may leave in the place of `null`
        local null = function() end
        local item = annotations.folio_to_koreader_annotation({
            id = "a1", locationStart = "/a", locationEnd = "/b", selectedText = "text",
            note = null, color = null, createdAt = null, updatedAt = null,
        })
        assert.is_nil(item.note)
        assert.is_equal("yellow", item.color)
        assert.is_equal("string", type(item.datetime))
        assert.is_equal("string", type(item.datetime_updated))

        local bookmark = annotations.folio_to_koreader_bookmark({ id = "b1", location = "/a", title = null })
        assert.is_nil(bookmark.text)
    end)
end)

describe("Folio API client", function()
    local requests, respond

    local function load_api(json_module)
        requests = {}
        package.loaded["socket.http"] = {
            request = function(req)
                local body
                if req.source then
                    local chunks = {}
                    while true do
                        local chunk = req.source()
                        if not chunk then break end
                        chunks[#chunks + 1] = chunk
                    end
                    body = table.concat(chunks)
                end
                requests[#requests + 1] = { url = req.url, method = req.method, body = body }
                return respond(req, body)
            end,
        }
        package.loaded["ltn12"] = {
            source = { string = function(s) return function() local r = s; s = nil; return r end end },
            sink = { table = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end end },
        }
        local real_json = package.loaded["json"]
        if json_module then package.loaded["json"] = json_module end
        package.loaded["folio_api"] = nil
        local FolioAPI = require("folio_api")
        package.loaded["json"] = real_json
        return FolioAPI:new({ server_url = "http://folio.test/api", api_key = "key" })
    end

    after_each(function()
        package.loaded["folio_api"] = nil
    end)

    it("sends the time a position was changed and never an empty location", function()
        respond = function(req)
            req.sink('{"location":"","progressPercent":40,"isRead":false,"updatedAt":"2026-11-12T10:00:00.000Z","applied":true}')
            return 1, 200, { date = "Thu, 12 Nov 2026 10:00:30 GMT" }
        end
        local api = load_api()
        assert.is_nil(api:clock_offset())
        local ok, data = api:update_progress("book", "", 40, nil, nil, { updated_at = "2026-11-12T10:00:00Z" })
        assert.is_true(ok)
        assert.is_true(data.applied)
        local sent = require("json").decode(requests[1].body)
        assert.is_nil(sent.location)
        assert.is_equal(40, sent.progressPercent)
        assert.is_equal("2026-11-12T10:00:00Z", sent.updatedAt)
        assert.is_true(api:conditional_progress())
        -- The server's clock, from the Date header of its answer
        assert.is_true(math.abs(api:clock_offset() - (utils.parse_http_date("Thu, 12 Nov 2026 10:00:30 GMT") - os.time())) <= 1)
    end)

    it("recognises a server that does not compare times", function()
        respond = function(req)
            req.sink('{"location":"/a","progressPercent":40,"isRead":false}')
            return 1, 200, {}
        end
        local api = load_api()
        api:update_progress("book", "/a", 40, nil, nil, { updated_at = "2026-11-12T10:00:00Z" })
        assert.is_false(api:conditional_progress())
    end)

    it("clears a note with an empty string and creates with the id chosen on the device", function()
        respond = function(req)
            req.sink('{"id":"0198c0de-0000-4000-8000-00000000000a","updatedAt":"2026-11-12T10:00:00Z"}')
            return 1, 200, {}
        end
        local api = load_api()
        local decode = require("json").decode
        local id = "0198c0de-0000-4000-8000-00000000000a"

        api:create_annotation("book", { id = id, locationStart = "/a", locationEnd = "/b", selectedText = "t", note = "" })
        local created = decode(requests[1].body)
        assert.is_equal(id, created.id)
        assert.is_nil(created.note)

        local ok, data = api:update_annotation("book", id, { locationStart = "/a", locationEnd = "/b", selectedText = "t", note = "" })
        assert.is_true(ok)
        assert.is_equal("2026-11-12T10:00:00Z", data.updatedAt)
        assert.is_equal("", decode(requests[2].body).note)

        api:create_bookmark("book", { id = id, location = "/a", title = "Mark" })
        assert.is_equal(id, decode(requests[3].body).id)
        -- Anything that is not a UUID is not sent as one
        api:create_bookmark("book", { id = "new-1", location = "/a", title = "Mark" })
        assert.is_nil(decode(requests[4].body).id)
    end)

    it("drops JSON nulls whatever the decoder puts in their place", function()
        local null = setmetatable({}, { __tostring = function() return "null" end })
        local placeholder = newproxy and newproxy() or function() end
        respond = function(req)
            req.sink("{}")
            return 1, 200, {}
        end
        local api = load_api({
            encode = require("json").encode,
            decode = function()
                return { { id = "a1", note = placeholder, color = placeholder, selectedText = "t", extra = { deep = placeholder } } }, null
            end,
        })
        local ok, list = api:list_annotations("book")
        assert.is_true(ok)
        assert.is_nil(list[1].note)
        assert.is_nil(list[1].color)
        assert.is_nil(list[1].extra.deep)
        assert.is_equal("t", list[1].selectedText)
    end)

    it("stops asking a server that does not answer", function()
        local answer = function() return nil, "timeout" end
        respond = function(req) return answer(req) end
        local api = load_api()

        assert.is_false(api:in_backoff())
        local ok, _, code = api:get_progress("book")
        assert.is_false(ok)
        assert.is_nil(code)
        assert.is_equal(1, #requests)
        assert.is_true(api:in_backoff())

        -- The rest of a sync that was running fails at once instead of waiting for
        -- one timeout per request
        api:list_annotations("book")
        api:list_bookmarks("book")
        assert.is_equal(1, #requests)

        -- A download the user is waiting for is still attempted
        api:get_chapter("book", "chapter")
        assert.is_equal(2, #requests)

        -- The user asks for something: try right away
        api:reset_backoff()
        assert.is_false(api:in_backoff())
        answer = function(req) req.sink("{}") return 1, 200, {} end
        assert.is_true((api:get_progress("book")))
        assert.is_equal(3, #requests)
        assert.is_false(api:in_backoff())

        -- An answer of the server is not a network failure, whatever it says
        answer = function(req) req.sink("oops") return 1, 500, {} end
        api:get_progress("book")
        assert.is_false(api:in_backoff())
    end)

    it("replaces a downloaded file only when the new one is complete", function()
        local dir = tmp_dir()
        local target = dir .. "/Book.epub"
        local content = string.rep("epub-bytes-", 1000)
        local api = load_api()

        respond = function(req)
            req.sink(content:sub(1, 4000))
            req.sink(content:sub(4001))
            req.sink(nil)
            return 1, 200, { ["content-length"] = tostring(#content) }
        end
        local ok, path = api:download_book("book", target)
        assert.is_true(ok)
        assert.is_equal(target, path)
        assert.is_equal(content, read_file(target))
        assert.is_nil(read_file(target .. ".part"))

        -- The connection breaks half way
        respond = function(req)
            req.sink("half of ")
            return nil, "closed"
        end
        local failed, message = api:download_book("book", target)
        assert.is_false(failed)
        assert.is_truthy(message:find("closed", 1, true))
        assert.is_equal(content, read_file(target))
        assert.is_nil(read_file(target .. ".part"))

        -- The server sends less than it announced
        respond = function(req)
            req.sink("short")
            return 1, 200, { ["content-length"] = "5000" }
        end
        assert.is_false((api:download_book("book", target)))
        assert.is_equal(content, read_file(target))

        -- The server refuses
        respond = function(req)
            req.sink('{"error":"nope"}')
            return 1, 500, {}
        end
        assert.is_false((api:download_book("book", target)))
        assert.is_equal(content, read_file(target))
        assert.is_nil(read_file(target .. ".part"))

        -- The disk is full
        local real_open = io.open
        io.open = function(file_path, mode) -- luacheck: ignore 122
            if file_path == target .. ".part" then
                return {
                    write = function() return nil, "No space left on device" end,
                    close = function() return true end,
                }
            end
            return real_open(file_path, mode)
        end
        respond = function(req)
            local sunk, err = req.sink(content)
            if not sunk then return nil, err end
            return 1, 200, {}
        end
        local ok_full, full_message = api:download_book("book", target)
        io.open = real_open -- luacheck: ignore 122
        assert.is_false(ok_full)
        assert.is_truthy(full_message:find("No space left", 1, true))
        assert.is_equal(content, read_file(target))
    end)
end)

describe("Matching a local file to a server book", function()
    local function new_manager(api)
        local mgr = Manager:new({ api = api, settings = {} })
        mgr.invalidate_sync_state = function() end
        mgr.get_chapters_layout = function() return nil end
        return mgr
    end

    local function info_for(file, title, authors, has_metadata_title)
        return { file = file, file_path = file, title = title, authors = authors,
            has_metadata_title = has_metadata_title ~= false, docsettings = new_docsettings() }
    end

    it("takes a title search result only when it is that book, and the only one", function()
        local items
        local searched
        local api = {
            find_book_by_hash = function(_, _hash, cb) cb(false, "not_found", 404) end,
            list_books = function(_, _page, _limit, search, cb)
                searched = search
                cb(true, { items = items })
            end,
        }
        local mgr = new_manager(api)
        mgr.compute_file_hash = function() return "abc" end
        local function resolve(info)
            mgr._unmatched = {}
            mgr.get_doc_info = function() return info end
            local resolved
            mgr:resolve_book_id(nil, nil, function(id) resolved = id end)
            return resolved, info.docsettings.data.folio_book_id
        end

        -- The search finds everything that contains the words
        items = {
            { id = "messiah", title = "Dune Messiah", author = "Frank Herbert" },
            { id = "children", title = "Children of Dune", author = "Frank Herbert" },
        }
        local resolved, stored = resolve(info_for("/books/Dune.epub", "Dune", "Frank Herbert"))
        assert.is_equal("Dune", searched)
        assert.is_nil(resolved)
        assert.is_nil(stored)

        items[#items + 1] = { id = "dune", title = "Dune", author = "Frank Herbert" }
        resolved, stored = resolve(info_for("/books/Dune.epub", "Dune", "Frank Herbert"))
        assert.is_equal("dune", resolved)
        assert.is_equal("dune", stored)

        -- Case, punctuation and spacing do not matter; several authors may be listed
        assert.is_equal("dune", (resolve(info_for("/books/x.epub", "  dune ", "Herbert, Frank\nFrank Herbert"))))

        -- Another author's book of the same title
        assert.is_nil((resolve(info_for("/books/Dune.epub", "Dune", "Somebody Else"))))

        -- Two books that both fit: nobody can tell which one this file is
        items[#items + 1] = { id = "dune-2", title = "Dune", author = "Frank Herbert" }
        assert.is_nil((resolve(info_for("/books/Dune.epub", "Dune", "Frank Herbert"))))
        items[#items] = nil

        -- A file without metadata is known by its name only
        assert.is_equal("dune", (resolve(info_for("/books/Dune - Frank Herbert.epub", "Dune - Frank Herbert", nil, false))))
        assert.is_equal("dune", (resolve(info_for("/books/Dune.epub", "Dune", nil, false))))
        assert.is_nil((resolve(info_for("/books/Dune Messiah (1).epub", "Dune Messiah (1)", nil, false))))
    end)

    it("hashes a file once and leaves a book the server does not know alone for a while", function()
        local dir = tmp_dir()
        local file = dir .. "/Unknown.epub"
        write_file(file, "content of an unknown book")
        package.loaded["datastorage"] = { getSettingsDir = function() return dir end }
        finally(function() package.loaded["datastorage"] = nil end)

        local asked = { hash = 0, title = 0 }
        local api = {
            find_book_by_hash = function(_, _hash, cb)
                asked.hash = asked.hash + 1
                cb(false, "not_found", 404)
            end,
            list_books = function(_, _page, _limit, _search, cb)
                asked.title = asked.title + 1
                cb(true, { items = {} })
            end,
        }
        local mgr = new_manager(api)
        local hashed = 0
        local real_hash = mgr.compute_file_hash
        mgr.compute_file_hash = function(self, path)
            hashed = hashed + 1
            return real_hash(self, path) or "0123abcd"
        end
        mgr.get_doc_info = function() return info_for(file, "Unknown", nil) end

        -- Page turn after page turn
        for _ = 1, 5 do
            local resolved = "unset"
            mgr:resolve_book_id(nil, nil, function(id) resolved = id end)
            assert.is_nil(resolved)
        end
        assert.is_equal(1, hashed)
        assert.are.same({ hash = 1, title = 1 }, asked)

        -- The user asks: the server is asked again, the file is not read again
        mgr:user_requested()
        mgr:resolve_book_id(nil, nil, function() end)
        assert.is_equal(1, hashed)
        assert.are.same({ hash = 2, title = 2 }, asked)

        -- Another plugin instance (the next opened book) knows the hash as well
        local other = new_manager(api)
        other.compute_file_hash = function() hashed = hashed + 1 return "other" end
        assert.is_equal(mgr:get_file_hash(file), other:get_file_hash(file))
        assert.is_equal(1, hashed)

        -- The file changed: its hash is computed again
        write_file(file, "content of an unknown book, second edition")
        mgr:get_file_hash(file)
        assert.is_equal(2, hashed)
    end)

    it("does not give up on a book while the server cannot be reached", function()
        local asked = 0
        local api = {
            find_book_by_hash = function(_, _hash, cb)
                asked = asked + 1
                cb(false, "timeout")
            end,
            list_books = function() error("the title must not be searched for") end,
        }
        local mgr = new_manager(api)
        mgr.compute_file_hash = function() return "abc" end
        mgr.get_doc_info = function() return info_for("/books/Dune.epub", "Dune", "Frank Herbert") end
        mgr:resolve_book_id(nil, nil, function() end)
        mgr:resolve_book_id(nil, nil, function() end)
        -- (the pause between attempts is the API client's business)
        assert.is_equal(2, asked)
    end)

    it("knows a downloaded file as the book it was downloaded as", function()
        local dir = tmp_dir()
        package.loaded["datastorage"] = { getSettingsDir = function() return dir end }
        finally(function() package.loaded["datastorage"] = nil end)
        local file = dir .. "/Dune - Frank Herbert.epub"
        write_file(file, "the file the server sent, which hashes to something the server may not find")

        local mgr = Manager:new({ api = {
            find_book_by_hash = function() error("no need to ask") end,
        }, settings = {} })
        mgr:relink_downloaded_file(file, "book-dune")
        mgr.get_doc_info = function() return info_for(file, "Dune", "Frank Herbert") end
        local resolved
        mgr:resolve_book_id(nil, nil, function(id) resolved = id end)
        assert.is_equal("book-dune", resolved)
        assert.is_equal("book-dune", mgr:local_file_book_id(file))

        -- Two books of the same title and author do not share a file
        local same_path, same_exists = mgr:resolve_download_target(dir, "Dune - Frank Herbert", "book-dune")
        assert.is_equal(file, same_path)
        assert.is_true(same_exists)
        local other_path, other_exists = mgr:resolve_download_target(dir, "Dune - Frank Herbert", "0198c0de-ffff-7000-8000-00000000000c")
        assert.is_equal(dir .. "/Dune - Frank Herbert (0198c0de).epub", other_path)
        assert.is_false(other_exists)

        -- A file nobody remembers downloading is identified by its content
        local stray = dir .. "/Stray.epub"
        write_file(stray, "some book")
        local asked_hash
        mgr.api.find_book_by_hash = function(_, hash)
            asked_hash = hash
            return true, { id = "book-stray" }
        end
        local stray_path, stray_exists = mgr:resolve_download_target(dir, "Stray", "book-stray", true)
        assert.is_equal(stray, stray_path)
        assert.is_true(stray_exists)
        assert.is_equal(mgr:get_file_hash(stray), asked_hash)
        local new_path, new_exists = mgr:resolve_download_target(dir, "Stray", "0198c0de-aaaa-7000-8000-00000000000d", true)
        assert.is_equal(dir .. "/Stray (0198c0de).epub", new_path)
        assert.is_false(new_exists)
    end)

    it("keeps reading sessions recorded offline when the snapshot is reset", function()
        local dir = tmp_dir()
        local file = dir .. "/Book.epub"
        require("lfs").mkdir(dir .. "/Book.sdr")
        local mgr = Manager:new({ api = {}, settings = {} })
        mgr:save_sync_state({
            has_synced_annos = true, has_synced_bms = true,
            annotations = { a1 = { folio_id = "a1", pos0 = "/a" } },
            bookmarks = { b1 = { folio_id = "b1", pos0 = "/b" } },
            pending_sessions = { { client_session_id = "s1", duration_seconds = 600 } },
        }, file)

        mgr:invalidate_sync_state(file)
        local state = mgr:load_sync_state(file)
        assert.is_false(state.has_synced_annos)
        assert.is_false(state.has_synced_bms)
        assert.are.same({}, state.annotations)
        assert.are.same({}, state.bookmarks)
        assert.is_equal("s1", state.pending_sessions[1].client_session_id)

        -- Nothing to keep: the file goes
        state.pending_sessions = {}
        mgr:save_sync_state(state, file)
        mgr:invalidate_sync_state(file)
        assert.is_nil(read_file(dir .. "/Book.sdr/folio_sync_state.json"))
    end)
end)

-- A Folio server as far as bookmarks and highlights go
local function new_item_server()
    local server = {
        annotations = {}, bookmarks = {},
        log = {},
        fail = {}, -- operation name -> { message, code } answered instead (once per entry)
        counter = 0,
        clock = 0,
    }
    local function failing(operation)
        local queue = server.fail[operation]
        if queue and #queue > 0 then
            return table.remove(queue, 1)
        end
    end
    local function stamp()
        server.clock = server.clock + 1
        return string.format("2026-11-12T10:00:%02d.000Z", server.clock)
    end
    local function find(list, id)
        for index, item in ipairs(list) do
            if item.id == id then return item, index end
        end
    end
    local function lister(list, operation)
        return function(_, _book_id, since, cb)
            server.log[#server.log + 1] = { operation, since }
            local failure = failing(operation)
            if failure then return cb(false, failure[1], failure[2]) end
            local copy = {}
            for _, item in ipairs(list) do
                local one = {}
                for key, value in pairs(item) do one[key] = value end
                copy[#copy + 1] = one
            end
            cb(true, copy)
        end
    end
    local function creator(list, operation, fields)
        return function(_, _book_id, payload, cb)
            server.log[#server.log + 1] = { operation, payload }
            local failure = failing(operation)
            if failure then return cb(false, failure[1], failure[2]) end
            local existing = payload.id and find(list, payload.id)
            if existing then return cb(true, existing) end
            server.counter = server.counter + 1
            local item = { id = payload.id or ("srv-" .. server.counter), createdAt = stamp() }
            item.updatedAt = item.createdAt
            for _, field in ipairs(fields) do item[field] = payload[field] end
            list[#list + 1] = item
            cb(true, item)
        end
    end
    local function deleter(list, operation)
        return function(_, _book_id, id, cb)
            server.log[#server.log + 1] = { operation, id }
            local failure = failing(operation)
            if failure then
                if cb then cb(false, failure[1], failure[2]) end
                return
            end
            local _, index = find(list, id)
            if index then table.remove(list, index) end
            if cb then cb(true) end
        end
    end

    server.api = {
        has_auth = function() return true end,
        list_annotations = lister(server.annotations, "list_annotations"),
        list_bookmarks = lister(server.bookmarks, "list_bookmarks"),
        create_annotation = creator(server.annotations, "create_annotation",
            { "locationStart", "locationEnd", "selectedText", "note", "color" }),
        create_bookmark = creator(server.bookmarks, "create_bookmark", { "location", "title" }),
        update_annotation = function(_, _book_id, id, payload, cb)
            server.log[#server.log + 1] = { "update_annotation", payload, id }
            local failure = failing("update_annotation")
            if failure then
                if cb then cb(false, failure[1], failure[2]) end
                return
            end
            local item = find(server.annotations, id)
            if not item then
                if cb then cb(false, "HTTP 404", 404) end
                return
            end
            item.note = payload.note ~= "" and payload.note or nil
            item.color = payload.color
            item.locationStart, item.locationEnd = payload.locationStart, payload.locationEnd
            item.updatedAt = stamp()
            if cb then cb(true, item) end
        end,
        delete_annotation = deleter(server.annotations, "delete_annotation"),
        delete_bookmark = deleter(server.bookmarks, "delete_bookmark"),
    }
    function server:edit(id, fields)
        local item = find(self.annotations, id)
        for key, value in pairs(fields) do item[key] = value end
        if fields.note == false then item.note = nil end
        item.updatedAt = stamp()
    end
    function server:remove(id)
        local _, index = find(self.annotations, id)
        if index then return table.remove(self.annotations, index) end
        _, index = find(self.bookmarks, id)
        if index then return table.remove(self.bookmarks, index) end
    end
    function server:count(operation)
        local n = 0
        for _, entry in ipairs(self.log) do
            if entry[1] == operation then n = n + 1 end
        end
        return n
    end
    return server
end

describe("Bookmark and highlight synchronization", function()
    local FILE = "/books/Novel.epub"

    local function highlight(fragment, text, note)
        local start = string.format("/body/DocFragment[%d]/body/p[2]/text().0", fragment)
        return { page = start, pos0 = start, pos1 = string.format("/body/DocFragment[%d]/body/p[2]/text().%d", fragment, #text),
            text = text, note = note, drawer = "lighten", color = "yellow",
            datetime = "2026-11-01 10:00:00", chapter = "Chapter", pageno = fragment * 10 }
    end

    local function page_bookmark(fragment)
        return { page = string.format("/body/DocFragment[%d]/body/p[1]", fragment), text = "in Chapter",
            datetime = "2026-11-01 10:00:00", chapter = "Chapter", pageno = fragment * 10 }
    end

    -- A manager for a book whose settings hold `items`; state snapshots are kept in memory
    local function setup(items, server)
        server = server or new_item_server()
        local docsettings = new_docsettings({ annotations = items, folio_book_id = "book-1" })
        local mgr = Manager:new({ api = server.api, settings = {} })
        local states = {}
        mgr.load_sync_state = function(_, path)
            return states[path] or { has_synced_annos = false, has_synced_bms = false, annotations = {},
                bookmarks = {}, pending_sessions = {} }
        end
        mgr.save_sync_state = function(_, state, path) states[path] = state end
        mgr.get_chapters_layout = function() return nil end
        mgr.get_doc_info = function()
            return { file = FILE, file_path = FILE, title = "Novel", docsettings = docsettings }
        end
        local function sync()
            local annos_ok, bms_ok
            mgr:sync_annotations(nil, nil, false, function(ok) annos_ok = ok end)
            mgr:sync_bookmarks(nil, nil, false, function(ok) bms_ok = ok end)
            return annos_ok, bms_ok
        end
        return mgr, server, docsettings, sync, states
    end

    it("leaves KOReader's own bookmarks exactly as they are", function()
        local bookmark = page_bookmark(2)
        local before = {}
        for key, value in pairs(bookmark) do before[key] = value end
        local mark = highlight(3, "marked words")
        local _, server, _, sync = setup({ bookmark, mark })

        assert.are.same({ true, true }, { sync() })
        assert.is_equal(1, #server.bookmarks)
        assert.is_equal(bookmark.page, server.bookmarks[1].location)
        assert.is_equal(1, #server.annotations)

        -- No `drawer`, no `pos0`: still a page bookmark for KOReader. Only the server id
        -- was added.
        local id = bookmark.folio_id
        assert.is_true(utils.is_uuid(id))
        bookmark.folio_id = nil
        assert.are.same(before, bookmark)
        bookmark.folio_id = id
        -- What the highlight is shown with in the bookmark list is still there
        assert.is_equal("Chapter", mark.chapter)
        assert.is_equal(30, mark.pageno)
        assert.is_equal("lighten", mark.drawer)

        -- Bookmarks damaged by an earlier version are repaired on the way
        local damaged = page_bookmark(5)
        damaged.pos0, damaged.pos1, damaged.drawer, damaged.color = damaged.page, "", "lighten", "yellow"
        local _, _, settings, sync_damaged = setup({ damaged })
        sync_damaged()
        assert.is_nil(damaged.drawer)
        assert.is_nil(damaged.pos1)
        assert.is_true(settings.flushed > 0)
    end)

    it("sends every highlight, also two of the same words", function()
        local first, second = highlight(2, "the same words", "first note"), highlight(7, "the same words")
        second.color = "red"
        local _, server, _, sync = setup({ first, second })
        sync()
        assert.is_equal(2, #server.annotations)
        assert.are_not.equal(first.folio_id, second.folio_id)
        assert.is_equal("first note", server.annotations[1].note)
        assert.is_equal("red", server.annotations[2].color)

        -- And nothing is sent twice
        sync()
        assert.is_equal(2, server:count("create_annotation"))
        assert.is_equal(0, server:count("update_annotation"))
        assert.is_equal(0, server:count("delete_annotation"))
    end)

    it("asks for the whole list, not for changes since a time of the device's clock", function()
        local _, server, _, sync, states = setup({ highlight(2, "words") })
        states[FILE] = { has_synced_annos = true, has_synced_bms = true, annotations = {}, bookmarks = {},
            pending_sessions = {}, last_annos_sync_at = "2031-01-01T00:00:00Z", last_bms_sync_at = "2031-01-01T00:00:00Z" }
        sync()
        for _, entry in ipairs(server.log) do
            if entry[1] == "list_annotations" or entry[1] == "list_bookmarks" then
                assert.is_nil(entry[2])
            end
        end
        assert.is_nil(states[FILE].last_annos_sync_at)
        assert.is_nil(states[FILE].last_bms_sync_at)
    end)

    it("sends again what the server did not get", function()
        local mark, bookmark = highlight(2, "words"), page_bookmark(4)
        local _, server, _, sync, states = setup({ mark, bookmark })
        server.fail.create_annotation = { { "timeout" }, { "HTTP 503", 503 } }
        server.fail.create_bookmark = { { "timeout" } }

        local annos_ok, bms_ok = sync()
        assert.is_false(annos_ok)
        assert.is_false(bms_ok)
        assert.is_equal(0, #server.annotations)
        -- Not recorded as synchronized
        assert.are.same({}, states[FILE].annotations)
        assert.are.same({}, states[FILE].bookmarks)
        local chosen_id = mark.folio_id
        assert.is_true(utils.is_uuid(chosen_id))

        sync()
        assert.is_equal(0, #server.annotations)
        assert.is_equal(1, #server.bookmarks)

        assert.are.same({ true, true }, { sync() })
        assert.is_equal(1, #server.annotations)
        -- The same id every time: an answer that got lost cannot create a second one
        assert.is_equal(chosen_id, server.annotations[1].id)
        for _, entry in ipairs(server.log) do
            if entry[1] == "create_annotation" then
                assert.is_equal(chosen_id, entry[2].id)
            end
        end
        assert.is_not_nil(states[FILE].annotations[chosen_id])

        sync()
        assert.is_equal(3, server:count("create_annotation"))
        assert.is_equal(2, server:count("create_bookmark"))
    end)

    it("takes the id of a server that picks its own", function()
        local mark = highlight(2, "words")
        local _, server, _, sync = setup({ mark })
        local create = server.api.create_annotation
        server.api.create_annotation = function(self, book_id, payload, cb)
            local copy = {}
            for key, value in pairs(payload) do copy[key] = value end
            copy.id = nil
            return create(self, book_id, copy, cb)
        end
        sync()
        assert.is_equal("srv-1", mark.folio_id)
        sync()
        assert.is_equal(1, #server.annotations)
        assert.is_equal(1, server:count("create_annotation"))
    end)

    it("does not send again what the server refuses", function()
        local mark = highlight(2, "words")
        local _, server, _, sync = setup({ mark })
        server.fail.create_annotation = { { "HTTP 400", 400 } }
        assert.are.same({ true, true }, { sync() })
        sync()
        sync()
        assert.is_equal(1, server:count("create_annotation"))

        -- Until it is edited
        mark.note = "now with a note"
        sync()
        assert.is_equal(2, server:count("create_annotation"))
        assert.is_equal(1, #server.annotations)
    end)

    it("keeps trying to delete what was deleted on the device", function()
        local mark, bookmark = highlight(2, "words"), page_bookmark(4)
        local items = { mark, bookmark }
        local _, server, _, sync = setup(items)
        sync()
        assert.is_equal(1, #server.annotations)
        assert.is_equal(1, #server.bookmarks)

        table.remove(items, 2)
        table.remove(items, 1)
        server.fail.delete_annotation = { { "timeout" } }
        server.fail.delete_bookmark = { { "HTTP 500", 500 } }
        local annos_ok, bms_ok = sync()
        assert.is_false(annos_ok)
        assert.is_false(bms_ok)
        assert.is_equal(1, #server.annotations)
        -- Not pulled back either
        assert.is_equal(0, #items)

        assert.are.same({ true, true }, { sync() })
        assert.is_equal(0, #server.annotations)
        assert.is_equal(0, #server.bookmarks)
        assert.is_equal(0, #items)

        sync()
        assert.is_equal(2, server:count("delete_annotation"))
        assert.is_equal(2, server:count("delete_bookmark"))
    end)

    it("follows deletions and edits made elsewhere", function()
        local kept, gone, bookmark = highlight(2, "kept words", "old note"), highlight(5, "words that go"), page_bookmark(4)
        local items = { kept, gone, bookmark }
        local _, server, docsettings, sync = setup(items)
        sync()
        local flushed = docsettings.flushed

        -- In the web reader: one highlight gets another note and colour, one is deleted,
        -- and so is the bookmark
        server:edit(kept.folio_id, { note = "new note", color = "blue" })
        server:remove(gone.folio_id)
        server:remove(bookmark.folio_id)
        assert.are.same({ true, true }, { sync() })

        assert.are.same({ kept }, items)
        assert.is_equal("new note", kept.note)
        assert.is_equal("blue", kept.color)
        assert.is_true(docsettings.flushed > flushed)
        -- Nothing is sent back
        assert.is_equal(0, server:count("update_annotation"))
        assert.is_equal(0, server:count("delete_annotation"))
        assert.is_equal(3, server:count("create_annotation") + server:count("create_bookmark"))

        -- The note is removed elsewhere
        server:edit(kept.folio_id, { note = false })
        sync()
        assert.is_nil(kept.note)

        -- A highlight made elsewhere arrives once
        server.api:create_annotation("book-1", { locationStart = "/body/DocFragment[8]/body/p[1]/text().0",
            locationEnd = "/body/DocFragment[8]/body/p[1]/text().9", selectedText = "from afar", color = "green" }, function() end)
        sync()
        sync()
        assert.is_equal(2, #items)
        local pulled = items[1] == kept and items[2] or items[1]
        assert.is_equal("from afar", pulled.text)
        assert.is_equal("green", pulled.color)
        assert.is_equal(server.annotations[#server.annotations].id, pulled.folio_id)
    end)

    it("sends local edits, also a note that was removed", function()
        local mark = highlight(2, "words", "a note")
        local _, server, _, sync = setup({ mark })
        sync()

        mark.note = nil
        mark.color = "red"
        sync()
        assert.is_equal(1, server:count("update_annotation"))
        assert.is_nil(server.annotations[1].note)
        assert.is_equal("red", server.annotations[1].color)
        -- The empty string is what clears a note on the server
        for _, entry in ipairs(server.log) do
            if entry[1] == "update_annotation" then assert.is_equal("", entry[2].note) end
        end

        sync()
        assert.is_equal(1, server:count("update_annotation"))

        -- An edit that fails is sent again
        mark.note = "second thoughts"
        server.fail.update_annotation = { { "timeout" } }
        assert.is_false((sync()))
        assert.is_true((sync()))
        assert.is_equal("second thoughts", server.annotations[1].note)
        assert.is_equal(3, server:count("update_annotation"))
    end)

    it("keeps the later edit when both sides changed a highlight", function()
        local mark = highlight(2, "words", "a note")
        local mgr, server, _, sync = setup({ mark })
        mgr.api.clock_offset = function() return 0 end
        sync()

        -- Edited elsewhere at 10:00:02 (UTC), and here a day later
        server:edit(mark.folio_id, { note = "from elsewhere" })
        mark.note = "from here"
        mark.datetime_updated = os.date("%Y-%m-%d %H:%M:%S", utils.parse_iso8601(server.annotations[1].updatedAt) + 86400)
        sync()
        assert.is_equal("from here", server.annotations[1].note)

        -- Edited here first, then elsewhere
        mark.note = "from here again"
        mark.datetime_updated = "2026-11-01 10:00:00"
        server:edit(mark.folio_id, { note = "the last word" })
        sync()
        assert.is_equal("the last word", mark.note)
        assert.is_equal("the last word", server.annotations[1].note)
    end)

    it("works on the list of the open book and keeps what is not saved yet", function()
        -- First session with this book: KOReader has not saved its list yet
        local unsaved = highlight(2, "made a minute ago")
        local live = { unsaved }
        local added = {}
        local ui = {
            document = { file = FILE },
            annotation = {
                annotations = live,
                addItem = function(self, item)
                    added[#added + 1] = item
                    item.pageno = 80
                    table.insert(self.annotations, item)
                    return #self.annotations
                end,
            },
        }
        local server = new_item_server()
        server.api:create_annotation("book-1", { locationStart = "/body/DocFragment[8]/body/p[1]/text().0",
            locationEnd = "/body/DocFragment[8]/body/p[1]/text().9", selectedText = "from afar" }, function() end)

        local docsettings = new_docsettings({ folio_book_id = "book-1" })
        local mgr = Manager:new({ api = server.api, settings = {} })
        local states = {}
        mgr.load_sync_state = function(_, path)
            return states[path] or { annotations = {}, bookmarks = {}, pending_sessions = {} }
        end
        mgr.save_sync_state = function(_, state, path) states[path] = state end
        mgr.get_chapters_layout = function() return nil end
        mgr.get_doc_info = function()
            return { file = FILE, file_path = FILE, title = "Novel", docsettings = docsettings, ui = ui }
        end

        local ok
        mgr:sync_annotations(ui, ui.document, false, function(result) ok = result end)
        assert.is_true(ok)
        -- The reader keeps its own list, with both highlights in it
        assert.is_equal(live, ui.annotation.annotations)
        assert.is_equal(2, #live)
        assert.is_equal(unsaved, live[1])
        assert.is_equal("from afar", live[2].text)
        assert.is_equal(80, live[2].pageno)
        assert.is_equal(1, #added)
        -- ...the unsaved one reached the server
        assert.is_equal(2, #server.annotations)
        assert.is_equal("made a minute ago", server.annotations[2].selectedText)
        -- ...and the list was saved before the snapshot was
        assert.is_equal(live, docsettings.data.annotations)
        assert.is_true(docsettings.flushed > 0)
    end)

    it("leaves alone what the open document cannot place", function()
        local live = {}
        local ui = {
            document = {
                file = FILE,
                getPageFromXPointer = function(_, xpointer)
                    return xpointer:find("DocFragment[99]", 1, true) and 0 or 12
                end,
            },
            rolling = {},
            annotation = {
                annotations = live,
                addItem = function(self, item) table.insert(self.annotations, item) end,
            },
        }
        local server = new_item_server()
        server.api:create_bookmark("book-1", { location = "/body/DocFragment[99]/body/p[1]", title = "Nowhere" }, function() end)
        server.api:create_bookmark("book-1", { location = "page_15", title = "A page of another edition" }, function() end)
        server.api:create_bookmark("book-1", { location = "/body/DocFragment[3]/body/p[1]", title = "Fine" }, function() end)

        local mgr = Manager:new({ api = server.api, settings = {} })
        local states = {}
        mgr.load_sync_state = function(_, path) return states[path] or { annotations = {}, bookmarks = {}, pending_sessions = {} } end
        mgr.save_sync_state = function(_, state, path) states[path] = state end
        mgr.get_chapters_layout = function() return nil end
        mgr.get_doc_info = function()
            return { file = FILE, file_path = FILE, title = "Novel", ui = ui,
                docsettings = new_docsettings({ folio_book_id = "book-1" }) }
        end
        mgr:sync_bookmarks(ui, ui.document, false)
        assert.is_equal(1, #live)
        assert.is_equal("/body/DocFragment[3]/body/p[1]", live[1].page)
        -- The others stay on the server
        mgr:sync_bookmarks(ui, ui.document, false)
        assert.is_equal(3, #server.bookmarks)
        assert.is_equal(0, server:count("delete_bookmark"))
    end)

    it("takes over the snapshot of an earlier version without losing or doubling anything", function()
        -- As 0.x left it: every local item recorded, whether the server got it or not
        local synced = highlight(2, "on the server")
        synced.folio_id = "old-1"
        local never_sent = highlight(5, "never reached the server")
        local deleted_elsewhere = highlight(7, "deleted in the web reader")
        deleted_elsewhere.folio_id = "old-2"
        local items = { synced, never_sent, deleted_elsewhere }
        local _, server, _, sync, states = setup(items)
        server.annotations[1] = { id = "old-1", locationStart = synced.pos0, locationEnd = synced.pos1,
            selectedText = synced.text, color = "yellow", updatedAt = "2026-10-01T10:00:00.000Z" }
        states[FILE] = {
            has_synced_annos = true, has_synced_bms = true, bookmarks = {}, pending_sessions = {},
            last_annos_sync_at = "2026-11-01T10:00:00Z",
            annotations = {
                ["old-1"] = { folio_id = "old-1", pos0 = synced.pos0, pos1 = synced.pos1, text = synced.text, color = "yellow" },
                [never_sent.pos0] = { pos0 = never_sent.pos0, pos1 = never_sent.pos1, text = never_sent.text, color = "yellow" },
                ["old-2"] = { folio_id = "old-2", pos0 = deleted_elsewhere.pos0, pos1 = deleted_elsewhere.pos1,
                    text = deleted_elsewhere.text, color = "yellow" },
            },
        }

        sync()
        -- The one that never arrived is sent now; the one deleted elsewhere goes here too
        assert.is_equal(2, #server.annotations)
        assert.is_equal("never reached the server", server.annotations[2].selectedText)
        assert.are.same({ synced, never_sent }, items)
        assert.is_equal(0, server:count("delete_annotation"))
        assert.is_equal(0, server:count("update_annotation"))
    end)
end)

describe("The plugin while a book is read", function()
    local function new_plugin(manager, settings)
        package.loaded["datastorage"] = package.loaded["datastorage"] or { getSettingsDir = function() return "/tmp" end }
        package.loaded["dispatcher"] = package.loaded["dispatcher"] or { registerAction = function() end }
        package.loaded["main"] = nil
        local FolioSync = require("main")
        local ui = { document = { file = "/books/test.epub" }, doc_settings = new_docsettings() }
        local plugin = setmetatable({
            settings = settings or { auto_progress_sync = true },
            ui = ui,
            manager = manager,
            get_ui = function() return ui end,
            onDispatcherRegisterActions = function() end,
        }, { __index = FolioSync })
        return plugin, ui
    end

    after_each(function()
        package.loaded["ui/network/manager"] = nil
    end)

    it("counts a page turn as reading, but not the pages the plugin opens itself", function()
        local stamped = 0
        local manager = {
            get_doc_info = function() return { percent = 10, current_page = 10 } end,
            note_position_changed = function() stamped = stamped + 1 end,
            pull_progress = function(_, _ui, _doc, _manual, cb) cb(true) end,
            sync_progress = function() end,
        }
        local plugin = new_plugin(manager)
        plugin:onReaderReady()

        -- The reader settling on the page it opened at
        plugin:onPageUpdate(10)
        assert.is_equal(0, stamped)

        plugin:onPageUpdate(11)
        assert.is_equal(1, stamped)

        -- The plugin opens the position it got from the server
        manager._applying_remote = true
        plugin:onPageUpdate(40)
        manager._applying_remote = false
        assert.is_equal(1, stamped)

        plugin:onPageUpdate(41)
        assert.is_equal(2, stamped)
    end)

    it("makes no request while there is no network or the server does not answer", function()
        local calls = {}
        local manager = {
            get_doc_info = function() return { percent = 10, current_page = 10 } end,
            note_position_changed = function() end,
            pull_progress = function() calls[#calls + 1] = "pull" end,
            sync_progress = function() calls[#calls + 1] = "progress" end,
            sync_reading_sessions = function() calls[#calls + 1] = "sessions" end,
            sync_annotations_and_bookmarks = function() calls[#calls + 1] = "annotations" end,
            record_reading_session = function() end,
        }
        local connected = false
        package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
        local plugin = new_plugin(manager)

        plugin:onReaderReady()
        plugin._last_progress_sync_time = nil
        plugin:onPageUpdate(11)
        plugin:onAnnotationsModified({})
        plugin:onSuspend()
        plugin:onCloseDocument()
        plugin:pull_and_sync_all()
        assert.are.same({}, calls)
        assert.is_falsy(plugin._is_pulling_on_open)

        -- Wi-Fi is on, but the server did not answer a moment ago
        connected = true
        local backoff = true
        plugin.api = { has_auth = function() return true end, in_backoff = function() return backoff end }
        plugin._last_progress_sync_time = nil
        plugin:onPageUpdate(12)
        plugin:onCloseDocument()
        assert.are.same({}, calls)

        backoff = false
        plugin._last_progress_sync_time = nil
        plugin:onPageUpdate(13)
        assert.are.same({ "progress" }, calls)
    end)

    it("starts a reading session when the device wakes up, not when it went to sleep", function()
        local recorded = {}
        local manager = {
            get_doc_info = function() return { percent = 10, current_page = 10, total_pages = 100 } end,
            record_reading_session = function(_, _ui, _doc, session) recorded[#recorded + 1] = session end,
        }
        local plugin = new_plugin(manager, { auto_progress_sync = false })
        local real_time = os.time
        local now = 1794477600
        os.time = function(t) if t then return real_time(t) end return now end -- luacheck: ignore 122
        finally(function() os.time = real_time end) -- luacheck: ignore 122

        plugin:onReaderReady()
        now = now + 60
        plugin:onPageUpdate(11)
        now = now + 60
        plugin:onPageUpdate(12)
        -- In the evening
        plugin:onSuspend()
        assert.is_equal(1, #recorded)
        assert.is_equal(120, recorded[1].duration_seconds)

        -- The next morning
        now = now + 10 * 3600
        plugin:onResume()
        local woke_at = now
        now = now + 30
        plugin:onPageUpdate(13)
        now = now + 30
        plugin:onPageUpdate(14)
        -- The reader is left lying open for an hour before the book is closed
        now = now + 3600
        plugin:onCloseDocument()

        assert.is_equal(2, #recorded)
        assert.is_equal(utils.iso8601(woke_at), recorded[2].start_time)
        assert.is_equal(60, recorded[2].duration_seconds)
        -- It ended with the last page turn
        assert.is_equal(utils.iso8601(woke_at + 60), recorded[2].end_time)
        assert.are_not.equal(recorded[1].client_session_id, recorded[2].client_session_id)
    end)
end)

describe("Opening a position sent by the server", function()
    it("finds the paragraph of a position that names a text node by number", function()
        local mgr = Manager:new({ api = {}, settings = {} })
        mgr.log_xpointer_error = function() end
        local tried = {}
        local went_to
        local ui = {
            document = {
                file = "/books/test.epub",
                getPageFromXPointer = function(_, xpointer)
                    tried[#tried + 1] = xpointer
                    return xpointer == "/body/DocFragment[2]/body/p[3]" and 7 or nil
                end,
            },
            handleEvent = function(_, event)
                if event.name == "GotoPage" then
                    went_to = event.arg
                    return true
                end
                return false
            end,
        }
        mgr.get_doc_info = function() return { file = "/books/test.epub", title = "Test" } end

        assert.is_true(mgr:goto_location(ui, "/body/DocFragment[2]/body/p[3]/text()[2].15", nil, 100, ui.document))
        assert.is_equal("/body/DocFragment[2]/body/p[3]", tried[#tried])
        assert.is_equal(7, went_to)
    end)
end)
