-- Books assembled on the device from Folio chapters (Chapters kind):
-- EPUB rendering, download / update, chapter layout and reading position translation.

local ok_dk, dkjson = pcall(require, "dkjson")
if ok_dk and dkjson then
    package.loaded["json"] = {
        encode = dkjson.encode,
        decode = dkjson.decode,
    }
end
local json = require("json")

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

local ChaptersEpub = require("chapters_epub")
local ChaptersBook = require("chapters_book")

local BOOK_ID = "0198c0de-0000-7000-8000-00000000000a"
local OTHER_BOOK_ID = "0198c0de-1111-7000-8000-00000000000b"
local PREFIX = "/api/books/" .. BOOK_ID .. "/images/"
local PNG = "\137PNG\r\n\26\n\1\2\3\4"
local JPEG = "\255\216\255\224cover"

-- ---- Test doubles ----

-- An "archive" kept as a plain file (name, length, store flag, bytes per entry), so that
-- renames and updates behave like on a device without needing a zip library.
local function open_fake_sink(path)
    local f = io.open(path, "wb")
    if not f then return nil, "Cannot create file " .. path end
    return {
        add = function(_, name, content, store)
            f:write(name, "\n", tostring(#content), "\n", store and "1" or "0", "\n", content)
            return true
        end,
        close = function()
            if f then f:close() end
            f = nil
        end,
    }
end

-- Entries of a fake archive: list (in archive order) and map by name.
local function read_fake_archive(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    local list, by_name = {}, {}
    local pos = 1
    while pos <= #data do
        local name_end = data:find("\n", pos, true)
        local len_end = name_end and data:find("\n", name_end + 1, true)
        if not len_end then return nil end -- not an archive
        local name = data:sub(pos, name_end - 1)
        local len = tonumber(data:sub(name_end + 1, len_end - 1))
        local store = data:sub(len_end + 1, len_end + 1) == "1"
        local content = data:sub(len_end + 3, len_end + 2 + len)
        local entry = { name = name, content = content, store = store }
        list[#list + 1] = entry
        by_name[name] = entry
        pos = len_end + 3 + len
    end
    return list, by_name
end

local function fake_reader(path)
    local _, by_name = read_fake_archive(path)
    if not by_name then return nil end
    local entries = {}
    for name in pairs(by_name) do entries[name] = true end
    return {
        entries = entries,
        extract = function(_, name) return by_name[name] and by_name[name].content or nil end,
        close = function() end,
    }
end

local function read_fake_existing(path)
    return ChaptersEpub.read_existing(path, fake_reader)
end

-- The parts of the Folio API the download uses, served from memory.
local function new_fake_api(chapters)
    local api = {
        chapters = chapters,
        images = {},
        cover = nil,
        requests = {},
        failures = {}, -- request key -> list of { message, code } to answer first
        book = { id = BOOK_ID, kind = "Chapters", title = "Server Title", author = "Server Author",
            language = "ru", description = "About <the> book" },
    }
    local function intercept(key)
        table.insert(api.requests, key)
        local queue = api.failures[key]
        if queue and #queue > 0 then
            local failure = table.remove(queue, 1)
            return true, failure[1], failure[2]
        end
        return false
    end
    function api:list_chapters(_book_id, offset, limit)
        local failed, message, code = intercept("list:" .. offset)
        if failed then return false, message, code end
        local items = {}
        for i = offset + 1, math.min(offset + limit, #self.chapters) do
            local c = self.chapters[i]
            items[#items + 1] = { id = c.id, volume = c.volume or 1, chapter = c.chapter, name = c.name, updated = c.updated }
        end
        return true, { items = items, more = offset + limit < #self.chapters, total = #self.chapters }
    end
    function api:get_chapter(_book_id, chapter_id)
        local failed, message, code = intercept("chapter:" .. chapter_id)
        if failed then return false, message, code end
        for _, c in ipairs(self.chapters) do
            if c.id == chapter_id then
                return true, { id = c.id, volume = c.volume or 1, chapter = c.chapter, name = c.name,
                    content = c.content, updated = c.updated }
            end
        end
        return false, "HTTP 404", 404
    end
    function api:get_book(_book_id)
        table.insert(self.requests, "book")
        return true, self.book
    end
    function api:get_book_image(_book_id, filename)
        local failed, message, code = intercept("image:" .. filename)
        if failed then return false, message, code end
        if self.images[filename] then return true, self.images[filename] end
        return false, "HTTP 404", 404
    end
    function api:get_book_cover(_book_id)
        table.insert(self.requests, "cover")
        if self.cover then return true, self.cover end
        return false, "HTTP 404", 404
    end
    function api:count(prefix)
        local n = 0
        for _, key in ipairs(self.requests) do
            if key:sub(1, #prefix) == prefix then n = n + 1 end
        end
        return n
    end
    return api
end

local function chapter(id, number, name, text, updated)
    return { id = id, chapter = number, name = name, content = { text }, updated = updated }
end

local tmp_counter = 0
local function tmp_dir()
    local base = os.getenv("TMPDIR") or "/tmp"
    tmp_counter = tmp_counter + 1
    local dir = string.format("%s/folio_chapters_spec_%d_%d", base, os.time(), tmp_counter)
    require("lfs").mkdir(dir)
    return dir
end

local function build(api, target, extra)
    local opts = {
        book_id = BOOK_ID,
        target_path = target,
        title = "Catalog Title",
        author = "Catalog Author",
        open_sink = open_fake_sink,
        read_existing = read_fake_existing,
    }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return ChaptersBook.build(api, opts)
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

-- ---- Rendering ----

describe("Chapters EPUB rendering", function()
    it("renders paragraphs: escaping, line breaks, embedded and external images", function()
        local doc, images = ChaptersEpub.render_chapter("en", 3, "Third",
            { "Intro <tag> ![pic](" .. PREFIX .. "a1.png) tail\nline2 <img src=\"https://x/y.jpg\" alt=\"ext\">" },
            PREFIX)
        assert.is_truthy(doc:find("<p>Intro &lt;tag&gt;</p>", 1, true))
        assert.is_truthy(doc:find('<figure><img src="images/a1.png" alt="pic"/></figure>', 1, true))
        assert.is_truthy(doc:find("<p>tail<br/>line2</p>", 1, true))
        assert.is_truthy(doc:find("<p><em>ext</em></p>", 1, true))
        assert.are.same({ "a1.png" }, images)
        assert.is_truthy(doc:find("<h2>Third</h2>", 1, true))
        assert.is_truthy(doc:find('xml:lang="en"', 1, true))
    end)

    it("keeps broken image markers as text and trims unicode spaces", function()
        local doc, images = ChaptersEpub.render_chapter("en", 1, "A & B",
            { "\227\128\128\227\128\128Indented\194\160", "not ![an image", "x <img alt=none> y", "   " }, PREFIX)
        assert.is_truthy(doc:find("<p>Indented</p>", 1, true))
        assert.is_truthy(doc:find("<p>not ![an image</p>", 1, true))
        assert.is_truthy(doc:find("<p>x &lt;img alt=none&gt; y</p>", 1, true))
        assert.is_truthy(doc:find("<h2>A &amp; B</h2>", 1, true))
        assert.are.same({}, images)
    end)

    it("accepts only plain illustration names from the book's own image store", function()
        assert.is_equal("x.jpg", ChaptersEpub.local_image_name(PREFIX .. "x.jpg?v=1", PREFIX))
        assert.is_equal("x.jpg", ChaptersEpub.local_image_name("https://folio.example" .. PREFIX .. "x.jpg#f", PREFIX))
        assert.is_nil(ChaptersEpub.local_image_name(PREFIX .. "../secret.jpg", PREFIX))
        assert.is_nil(ChaptersEpub.local_image_name(PREFIX .. "dir/x.jpg", PREFIX))
        assert.is_nil(ChaptersEpub.local_image_name(PREFIX .. ".hidden", PREFIX))
        assert.is_nil(ChaptersEpub.local_image_name("/api/books/other/images/x.jpg", PREFIX))
        assert.is_nil(ChaptersEpub.local_image_name("relative/x.jpg", PREFIX))
    end)

    it("gives an untitled chapter a heading and an empty one a body", function()
        local doc = ChaptersEpub.render_chapter("ru", 12, "  ", {}, PREFIX)
        assert.is_truthy(doc:find("<h2>Глава 12</h2>", 1, true))
        assert.is_truthy(doc:find("<p></p>", 1, true))
    end)

    it("labels chapters for the table of contents", function()
        assert.is_equal("Chapter 5", ChaptersEpub.chapter_label("en", 5, ""))
        assert.is_equal("5. Storm", ChaptersEpub.chapter_label("en", 5, "Storm"))
        assert.is_equal("5 - Storm", ChaptersEpub.chapter_label("en", 5, "5 - Storm"))
        assert.is_equal("10.5. Extra", ChaptersEpub.chapter_label("en", 10.5, "Extra"))
    end)

    it("normalises the language tag", function()
        assert.is_equal("ru", ChaptersEpub.normalize_language(" ru "))
        assert.is_equal("zh-Hans", ChaptersEpub.normalize_language("zh-Hans"))
        assert.is_equal("en", ChaptersEpub.normalize_language(nil))
        assert.is_equal("en", ChaptersEpub.normalize_language("ru\"><x"))
    end)

    it("converts between XPointers and chapter positions", function()
        assert.is_equal(3, ChaptersEpub.xpointer_spine_index("/body/DocFragment[4]/body/section/p[2]/text().15"))
        assert.is_equal(0, ChaptersEpub.xpointer_spine_index("/body/DocFragment/body/section/p[2]/text().15"))
        assert.is_equal(9, ChaptersEpub.xpointer_spine_index("/body/DocFragment[10].0"))
        assert.is_nil(ChaptersEpub.xpointer_spine_index("page_15"))
        assert.is_nil(ChaptersEpub.xpointer_spine_index(nil))
        assert.is_equal("/body/DocFragment[3]/body", ChaptersEpub.chapter_start_xpointer(2))

        local moved = { [1] = 2, [2] = 1, [5] = 5 }
        assert.is_equal("/body/DocFragment[3]/body/section/p[4]/text().7",
            ChaptersEpub.remap_xpointer_spine("/body/DocFragment[2]/body/section/p[4]/text().7", moved))
        assert.is_nil(ChaptersEpub.remap_xpointer_spine("/body/DocFragment[1]/body/p", moved))
        assert.is_nil(ChaptersEpub.remap_xpointer_spine("/body/DocFragment[6]/body/p", moved))
        assert.is_nil(ChaptersEpub.remap_xpointer_spine("page_3", moved))
    end)
end)

-- ---- Download ----

describe("Chapters book download", function()
    it("assembles an EPUB from chapters, illustrations and the cover", function()
        local dir = tmp_dir()
        local target = dir .. "/Book.epub"
        local api = new_fake_api({
            chapter("ch-a", 1, "First", "Text ![i](" .. PREFIX .. "pic.png) more"),
            chapter("ch-b", 2, "", "Second & last"),
        })
        api.images["pic.png"] = PNG
        api.cover = JPEG

        local phases = {}
        local result, err = build(api, target, {
            on_progress = function(phase, done, total)
                phases[#phases + 1] = string.format("%s %d/%d", phase, done, total)
                return true
            end,
        })
        assert.is_nil(err)
        assert.is_false(result.updated)
        assert.is_equal(2, result.chapters_total)
        assert.is_equal(2, result.chapters_fetched)
        assert.is_equal(1, result.images_fetched)
        assert.is_equal(0, result.images_missing)
        assert.are.same({ "ch-a", "ch-b" }, result.chapter_ids)
        assert.is_false(result.has_moved)
        assert.are.same({ "chapters 0/2", "chapters 1/2", "chapters 2/2", "images 0/1", "images 1/1", "building 2/2" }, phases)

        -- Nothing is in place until commit
        assert.is_false(exists(target))
        assert.is_true(ChaptersBook.commit(result))
        assert.is_true(exists(target))
        assert.is_false(exists(target .. ".tmp"))

        local list, by_name = read_fake_archive(target)
        assert.is_equal("mimetype", list[1].name)
        assert.is_equal("application/epub+zip", list[1].content)
        assert.is_true(list[1].store)
        assert.is_truthy(by_name["META-INF/container.xml"].content:find('full-path="OEBPS/content.opf"', 1, true))
        assert.is_equal(PNG, by_name["OEBPS/images/pic.png"].content)
        assert.is_true(by_name["OEBPS/images/pic.png"].store)
        assert.is_equal(JPEG, by_name["OEBPS/cover.jpg"].content)
        assert.is_truthy(by_name["OEBPS/ch-ch-a.xhtml"].content:find('<img src="images/pic.png" alt="i"/>', 1, true))
        assert.is_truthy(by_name["OEBPS/ch-ch-b.xhtml"].content:find("<h2>Глава 2</h2>", 1, true))
        assert.is_truthy(by_name["OEBPS/ch-ch-b.xhtml"].content:find("Second &amp; last", 1, true))

        -- Package document: server metadata wins, the spine holds only the chapters, in order
        local opf = by_name["OEBPS/content.opf"].content
        assert.is_truthy(opf:find("<dc:identifier id=\"pub-id\">urn:uuid:" .. BOOK_ID .. "</dc:identifier>", 1, true))
        assert.is_truthy(opf:find("<dc:title>Server Title</dc:title>", 1, true))
        assert.is_truthy(opf:find('<dc:creator id="creator">Server Author</dc:creator>', 1, true))
        assert.is_truthy(opf:find("<dc:language>ru</dc:language>", 1, true))
        assert.is_truthy(opf:find("<dc:description>About &lt;the&gt; book</dc:description>", 1, true))
        assert.is_truthy(opf:find('href="cover.jpg" media-type="image/jpeg" properties="cover-image"', 1, true))
        assert.is_truthy(opf:find('href="images/pic.png" media-type="image/png"', 1, true))
        local spine = opf:match("<spine>(.-)</spine>")
        local refs = {}
        for idref in spine:gmatch('idref="([^"]+)"') do refs[#refs + 1] = idref end
        assert.are.same({ "ch-ch-a", "ch-ch-b" }, refs)

        local nav = by_name["OEBPS/nav.xhtml"].content
        assert.is_truthy(nav:find('<li><a href="ch-ch-a.xhtml">1. First</a></li>', 1, true))
        assert.is_truthy(nav:find('<li><a href="ch-ch-b.xhtml">Глава 2</a></li>', 1, true))

        -- Manifest: what the file holds
        local manifest = json.decode(by_name[ChaptersEpub.MANIFEST_PATH].content)
        assert.is_equal(1, manifest.version)
        assert.is_equal(BOOK_ID, manifest.bookId)
        assert.is_equal("cover.jpg", manifest.cover)
        assert.is_equal("ch-a", manifest.chapters[1].id)
        assert.are.same({ "pic.png" }, manifest.chapters[1].images)
        assert.is_equal("ch-b", manifest.chapters[2].id)

        -- The chapter layout is recorded next to the book
        local layout = ChaptersBook.load_layout(target)
        assert.is_equal(BOOK_ID, layout.book_id)
        assert.are.same({ "ch-a", "ch-b" }, layout.chapter_ids)
        assert.is_equal(1, layout.positions["ch-b"])
    end)

    it("groups the table of contents by volume", function()
        local dir = tmp_dir()
        local target = dir .. "/Volumes.epub"
        local api = new_fake_api({
            { id = "v1c1", volume = 1, chapter = 1, name = "One", content = { "a" } },
            { id = "v2c1", volume = 2, chapter = 1, name = "Two", content = { "b" } },
        })
        local result = build(api, target)
        assert.is_true(ChaptersBook.commit(result))
        local _, by_name = read_fake_archive(target)
        local nav = by_name["OEBPS/nav.xhtml"].content
        assert.is_truthy(nav:find('<li><a href="ch-v1c1.xhtml">Том 1</a>', 1, true))
        assert.is_truthy(nav:find('<li><a href="ch-v2c1.xhtml">Том 2</a>', 1, true))
        assert.is_truthy(nav:find('<li><a href="ch-v2c1.xhtml">1. Two</a></li>', 1, true))
    end)

    it("updates a local copy by downloading only new and changed chapters", function()
        local dir = tmp_dir()
        local target = dir .. "/Book.epub"
        local api = new_fake_api({
            chapter("ch-a", 1, "First", "one ![i](" .. PREFIX .. "pic.png)", "2026-11-01T00:00:00Z"),
            chapter("ch-b", 2, "Second", "two", "2026-11-01T00:00:00Z"),
            chapter("ch-c", 3, "Third", "three", nil),
        })
        api.images["pic.png"] = PNG
        api.cover = JPEG
        assert.is_true(ChaptersBook.commit(build(api, target)))

        -- On the server: ch-b was edited, ch-d was inserted before ch-c, the cover is gone
        api.chapters = {
            chapter("ch-a", 1, "First", "one ![i](" .. PREFIX .. "pic.png)", "2026-11-01T00:00:00Z"),
            chapter("ch-b", 2, "Second", "two, edited", "2026-11-05T00:00:00Z"),
            chapter("ch-d", 2.5, "Inserted", "new", nil),
            chapter("ch-c", 3, "Third", "three", nil),
        }
        api.cover = nil
        api.images = {} -- must not be needed again
        api.requests = {}

        local result, err = build(api, target)
        assert.is_nil(err)
        assert.is_true(result.updated)
        assert.is_equal(4, result.chapters_total)
        assert.is_equal(2, result.chapters_fetched)
        assert.is_equal(0, result.images_fetched)
        assert.is_equal(0, result.images_missing)
        assert.is_equal(1, api:count("chapter:ch-b"))
        assert.is_equal(1, api:count("chapter:ch-d"))
        assert.is_equal(0, api:count("chapter:ch-a"))
        assert.is_equal(0, api:count("chapter:ch-c"))
        assert.is_equal(0, api:count("image:"))

        -- ch-c moved from the third place to the fourth
        assert.is_true(result.has_moved)
        assert.are.same({ [2] = 3 }, result.moved)

        assert.is_true(ChaptersBook.commit(result))
        local _, by_name = read_fake_archive(target)
        assert.is_truthy(by_name["OEBPS/ch-ch-b.xhtml"].content:find("two, edited", 1, true))
        assert.is_truthy(by_name["OEBPS/ch-ch-a.xhtml"].content:find("<p>one</p>", 1, true))
        assert.is_equal(PNG, by_name["OEBPS/images/pic.png"].content)
        -- The previous cover is kept when the server has none
        assert.is_equal(JPEG, by_name["OEBPS/cover.jpg"].content)
        assert.are.same({ "ch-a", "ch-b", "ch-d", "ch-c" }, ChaptersBook.load_layout(target).chapter_ids)

        -- Nothing changed since: nothing is downloaded and the file is left alone
        api.requests = {}
        local before = io.open(target, "rb"):read("*a")
        local again = build(api, target)
        assert.is_true(again.unchanged)
        assert.is_equal(0, again.chapters_fetched)
        assert.is_equal(0, api:count("chapter:"))
        assert.is_equal(0, api:count("cover"))
        assert.is_false(again.has_moved)
        assert.is_false(exists(target .. ".tmp"))
        assert.is_true(ChaptersBook.commit(again))
        assert.is_equal(before, io.open(target, "rb"):read("*a"))
        assert.are.same({ "ch-a", "ch-b", "ch-d", "ch-c" }, ChaptersBook.load_layout(target).chapter_ids)

        -- A chapter removed on the server is removed from the book
        api.chapters = { api.chapters[1], api.chapters[2], api.chapters[4] }
        local shorter = build(api, target)
        assert.is_false(shorter.unchanged)
        assert.is_equal(0, shorter.chapters_fetched)
        assert.are.same({ "ch-a", "ch-b", "ch-c" }, shorter.chapter_ids)
        assert.are.same({ [3] = 2 }, shorter.moved)
        ChaptersBook.discard(shorter)
        assert.is_false(exists(target .. ".tmp"))
    end)

    it("downloads everything again when the previous copy cannot be read", function()
        local dir = tmp_dir()
        local target = dir .. "/Book.epub"
        local api = new_fake_api({ chapter("ch-a", 1, "First", "one"), chapter("ch-b", 2, "Second", "two") })
        assert.is_true(ChaptersBook.commit(build(api, target)))

        api.chapters = { chapter("ch-b", 2, "Second", "two"), chapter("ch-a", 3, "First", "one") }
        api.requests = {}
        -- KOReader without an archive reader: the layout known from the sidecar still
        -- tells which chapters moved
        local result = build(api, target, {
            read_existing = function() return nil end,
            previous_chapter_ids = { "ch-a", "ch-b" },
        })
        assert.is_true(result.updated)
        assert.is_equal(2, result.chapters_fetched)
        assert.are.same({ [0] = 1, [1] = 0 }, result.moved)
    end)

    it("stops when cancelled and leaves the existing copy intact", function()
        local dir = tmp_dir()
        local target = dir .. "/Book.epub"
        local api = new_fake_api({ chapter("ch-a", 1, "First", "one"), chapter("ch-b", 2, "Second", "two") })
        assert.is_true(ChaptersBook.commit(build(api, target)))
        local before = io.open(target, "rb"):read("*a")

        api.chapters[3] = chapter("ch-c", 3, "Third", "three")
        local result, err = build(api, target, {
            on_progress = function(phase, done) return not (phase == "chapters" and done == 2) end,
        })
        assert.is_nil(result)
        assert.is_equal(ChaptersBook.ERR_CANCELLED, err)
        assert.is_false(exists(target .. ".tmp"))
        assert.is_equal(before, io.open(target, "rb"):read("*a"))
    end)

    it("reports books without chapters and servers that refuse API keys", function()
        local dir = tmp_dir()
        local result, err = build(new_fake_api({}), dir .. "/Empty.epub")
        assert.is_nil(result)
        assert.is_equal(ChaptersBook.ERR_NO_CHAPTERS, err)

        local api = new_fake_api({ chapter("ch-a", 1, "First", "one") })
        api.failures["list:0"] = { { "HTTP 403", 403 } }
        result, err = build(api, dir .. "/Forbidden.epub")
        assert.is_nil(result)
        assert.is_equal(ChaptersBook.ERR_FORBIDDEN, err)
        -- A refusal is final: no retries
        assert.is_equal(1, api:count("list:"))

        result, err = ChaptersBook.build(api, { book_id = "../etc", target_path = dir .. "/x.epub" })
        assert.is_nil(result)
        assert.is_truthy(tostring(err):find("not a Folio book id", 1, true))

        -- Without the book details (language above all) nothing is built
        api = new_fake_api({ chapter("ch-a", 1, "First", "one") })
        api.get_book = function(self)
            table.insert(self.requests, "book")
            return false, "timeout"
        end
        result, err = build(api, dir .. "/NoDetails.epub")
        assert.is_nil(result)
        assert.is_truthy(tostring(err):find("Failed to load the book details", 1, true))
        assert.is_equal(3, api:count("book"))
        assert.is_false(exists(dir .. "/NoDetails.epub.tmp"))
    end)

    it("retries failed requests and tolerates illustrations the server lost", function()
        local dir = tmp_dir()
        local target = dir .. "/Book.epub"
        local api = new_fake_api({
            chapter("ch-a", 1, "First", "![a](" .. PREFIX .. "gone.png) ![b](" .. PREFIX .. "ok.png)"),
        })
        api.images["ok.png"] = PNG
        api.failures["chapter:ch-a"] = { { "timeout", nil }, { "HTTP 502", 502 } }
        api.failures["image:ok.png"] = { { "HTTP 500", 500 } }

        local result, err = build(api, target)
        assert.is_nil(err)
        assert.is_equal(3, api:count("chapter:ch-a"))
        assert.is_equal(2, api:count("image:ok.png"))
        -- 404 is an answer, not a failure
        assert.is_equal(1, api:count("image:gone.png"))
        assert.is_equal(1, result.images_fetched)
        assert.is_equal(1, result.images_missing)
        ChaptersBook.discard(result)

        -- A chapter that keeps failing fails the book and leaves nothing behind
        api.failures["chapter:ch-a"] = { { "timeout", nil }, { "timeout", nil }, { "timeout", nil } }
        result, err = build(api, target)
        assert.is_nil(result)
        assert.is_truthy(tostring(err):find("Failed to download chapter 1", 1, true))
        assert.is_false(exists(target .. ".tmp"))
        assert.is_false(exists(target))
    end)

    it("never overwrites a file that belongs to another book", function()
        local dir = tmp_dir()
        local api = new_fake_api({ chapter("ch-a", 1, "First", "one") })

        -- A regular EPUB with the same name
        local plain = dir .. "/Book.epub"
        local f = io.open(plain, "wb")
        f:write("not ours")
        f:close()
        local load = function(path) return ChaptersBook.load_layout(path, read_fake_existing) end

        local path, existing = ChaptersBook.resolve_target(dir, "Book", BOOK_ID, load)
        assert.is_equal(dir .. "/Book (0198c0de).epub", path)
        assert.is_nil(existing)

        -- Our own build under the alternative name is found again and updated
        assert.is_true(ChaptersBook.commit(build(api, path)))
        local again, layout = ChaptersBook.resolve_target(dir, "Book", BOOK_ID, load)
        assert.is_equal(path, again)
        assert.is_equal(BOOK_ID, layout.book_id)

        -- ...also after the plain name became free: no second copy of the book
        os.rename(plain, dir .. "/Elsewhere.epub")
        again, layout = ChaptersBook.resolve_target(dir, "Book", BOOK_ID, load)
        assert.is_equal(path, again)
        assert.is_equal(BOOK_ID, layout.book_id)
        os.rename(dir .. "/Elsewhere.epub", plain)

        -- Both names taken by other books
        local other_path, err = ChaptersBook.resolve_target(dir, "Book", "0198c0de-ffff-7000-8000-00000000000f", load)
        assert.is_nil(other_path)
        assert.is_equal(ChaptersBook.ERR_NAME_TAKEN, err)

        -- build refuses a target that holds another book
        local result
        result, err = ChaptersBook.build(new_fake_api({ chapter("x", 1, "X", "x") }), {
            book_id = OTHER_BOOK_ID,
            target_path = path,
            open_sink = open_fake_sink,
            read_existing = read_fake_existing,
        })
        assert.is_nil(result)
        assert.is_equal(ChaptersBook.ERR_NAME_TAKEN, err)
    end)

    it("recovers the chapter layout from the EPUB when the sidecar copy is gone", function()
        local dir = tmp_dir()
        local target = dir .. "/Book.epub"
        local api = new_fake_api({ chapter("ch-a", 1, "First", "one"), chapter("ch-b", 2, "Second", "two") })
        assert.is_true(ChaptersBook.commit(build(api, target)))
        os.remove(ChaptersBook.layout_path(target))

        assert.is_nil(ChaptersBook.load_layout(target, function() return nil end))
        local layout = ChaptersBook.load_layout(target, read_fake_existing)
        assert.is_equal(BOOK_ID, layout.book_id)
        assert.are.same({ "ch-a", "ch-b" }, layout.chapter_ids)
        -- ...and writes the sidecar copy back
        assert.is_true(exists(ChaptersBook.layout_path(target)))

        assert.is_nil(ChaptersBook.load_layout(dir .. "/missing.epub", read_fake_existing))
        assert.is_nil(ChaptersBook.load_layout(dir .. "/notes.pdf", read_fake_existing))
    end)

    it("forgets the chapter layout once another file takes the book's place", function()
        local dir = tmp_dir()
        local target = dir .. "/Book.epub"
        local api = new_fake_api({ chapter("ch-a", 1, "First", "one") })
        assert.is_true(ChaptersBook.commit(build(api, target)))
        assert.is_not_nil(ChaptersBook.load_layout(target, read_fake_existing))

        -- The book got a real EPUB on the server and it was downloaded over the built copy
        local f = io.open(target, "wb")
        f:write("a regular EPUB from the library")
        f:close()
        assert.is_nil(ChaptersBook.load_layout(target, read_fake_existing))
        assert.is_false(exists(ChaptersBook.layout_path(target)))
    end)
end)

-- ---- Reading position ----

describe("Chapters book reading position", function()
    local layout = ChaptersBook.make_layout(BOOK_ID, { "ch-a", "ch-b", "ch-c" })
    local in_b = "/body/DocFragment[2]/body/section/p[7]/text().10"

    it("sends the chapter the reader is in", function()
        assert.is_equal("ch:ch-b", ChaptersBook.outgoing_location(layout, in_b))
        assert.is_equal("ch:ch-a", ChaptersBook.outgoing_location(layout, "/body/DocFragment[1]/body/section/h2/text().0"))
        -- Positions that cannot be expressed: only the percentage is pushed
        assert.is_nil(ChaptersBook.outgoing_location(layout, "/body/DocFragment[40]/body/p"))
        assert.is_nil(ChaptersBook.outgoing_location(layout, "page_12"))
        assert.is_nil(ChaptersBook.outgoing_location(layout, nil))
    end)

    it("turns a server chapter into the start of that chapter in the local EPUB", function()
        local kind, xpointer = ChaptersBook.incoming_location(layout, "ch:ch-c", in_b)
        assert.is_equal("at", kind)
        assert.is_equal("/body/DocFragment[3]/body", xpointer)

        kind, xpointer = ChaptersBook.incoming_location(layout, "ch:ch-a", nil)
        assert.is_equal("at", kind)
        assert.is_equal("/body/DocFragment[1]/body", xpointer)

        -- Already inside that chapter: the precise local position stays
        assert.is_equal("same", (ChaptersBook.incoming_location(layout, "ch:ch-b", in_b)))
        -- A chapter this copy does not have
        assert.is_equal("unknown", (ChaptersBook.incoming_location(layout, "ch:ch-new", in_b)))
        -- Not a chapter reference: the server placeholder, another edition, JSON null
        assert.is_equal("other", (ChaptersBook.incoming_location(layout, "cfl:/6/2", in_b)))
        assert.is_equal("other", (ChaptersBook.incoming_location(layout, in_b, in_b)))
        assert.is_equal("other", (ChaptersBook.incoming_location(layout, nil, in_b)))
        assert.is_equal("other", (ChaptersBook.incoming_location(layout, function() end, in_b)))
    end)

    it("compares positions by chapter, not by percentage", function()
        assert.is_true(ChaptersBook.remote_is_ahead(layout, "ch:ch-c", in_b))
        assert.is_false(ChaptersBook.remote_is_ahead(layout, "ch:ch-b", in_b))
        assert.is_false(ChaptersBook.remote_is_ahead(layout, "ch:ch-a", in_b))
        -- Nothing to compare: the caller falls back to percentages. A chapter this copy
        -- does not have may be new or deleted on the server.
        assert.is_nil(ChaptersBook.remote_is_ahead(layout, "ch:ch-new", in_b))
        assert.is_nil(ChaptersBook.remote_is_ahead(layout, "", in_b))
        assert.is_nil(ChaptersBook.remote_is_ahead(layout, nil, in_b))
        assert.is_nil(ChaptersBook.remote_is_ahead(layout, "ch:ch-c", "page_3"))
    end)

    it("moves stored positions along with their chapters", function()
        local store = {
            last_xpointer = "/body/DocFragment[3]/body/section/p[2]/text().4",
            annotations = {
                { page = "/body/DocFragment[3]/body/section/p[1]/text().0",
                    pos0 = "/body/DocFragment[3]/body/section/p[1]/text().0",
                    pos1 = "/body/DocFragment[3]/body/section/p[1]/text().9", text = "moved" },
                { page = "/body/DocFragment[1]/body/section/p[1]/text().0",
                    pos0 = "/body/DocFragment[1]/body/section/p[1]/text().0", text = "stays" },
            },
        }
        local docsettings = {
            readSetting = function(_, key) return store[key] end,
            saveSetting = function(_, key, value) store[key] = value end,
        }
        local moved = { [2] = 3 }
        assert.is_true(ChaptersBook.remap_docsettings(docsettings, moved))
        assert.is_equal("/body/DocFragment[4]/body/section/p[2]/text().4", store.last_xpointer)
        assert.is_equal("/body/DocFragment[4]/body/section/p[1]/text().0", store.annotations[1].pos0)
        assert.is_equal("/body/DocFragment[4]/body/section/p[1]/text().9", store.annotations[1].pos1)
        assert.is_equal("/body/DocFragment[4]/body/section/p[1]/text().0", store.annotations[1].page)
        assert.is_equal("/body/DocFragment[1]/body/section/p[1]/text().0", store.annotations[2].pos0)
        assert.is_false(ChaptersBook.remap_docsettings(docsettings, { [7] = 8 }))

        local state = {
            annotations = {
                ["folio-1"] = { folio_id = "folio-1", pos0 = "/body/DocFragment[3]/body/p", pos1 = "/body/DocFragment[3]/body/p.5" },
            },
            bookmarks = {
                ["/body/DocFragment[3]/body/p[2]"] = { pos0 = "/body/DocFragment[3]/body/p[2]" },
                ["/body/DocFragment[1]/body/p"] = { pos0 = "/body/DocFragment[1]/body/p" },
            },
        }
        assert.is_true(ChaptersBook.remap_sync_state(state, moved))
        assert.is_equal("/body/DocFragment[4]/body/p", state.annotations["folio-1"].pos0)
        assert.is_equal("/body/DocFragment[4]/body/p.5", state.annotations["folio-1"].pos1)
        assert.is_not_nil(state.bookmarks["/body/DocFragment[4]/body/p[2]"])
        assert.is_nil(state.bookmarks["/body/DocFragment[3]/body/p[2]"])
        assert.is_not_nil(state.bookmarks["/body/DocFragment[1]/body/p"])
        assert.is_false(ChaptersBook.remap_sync_state(state, { [7] = 8 }))
    end)
end)

describe("Annotations of a book whose chapters moved", function()
    local annotations = require("annotations")

    it("still match their server items by id after the local position was remapped", function()
        -- Snapshot / local item (position already follows the chapter) vs the server item
        local local_bm = { folio_id = "bm-1", pos0 = "/body/DocFragment[4]/body/section/p[2]" }
        local remote_bm = { id = "bm-1", location = "/body/DocFragment[3]/body/section/p[2]" }
        assert.is_true(annotations.is_same_bookmark(local_bm, remote_bm))
        assert.is_false(annotations.is_same_bookmark(local_bm, { id = "bm-2", location = "/body/DocFragment[3]/body/section/p[2]" }))

        local local_hl = { folio_id = "hl-1", pos0 = "/body/DocFragment[4]/body/section/p[2]/text().0", pos1 = "x" }
        assert.is_true(annotations.is_same_annotation(local_hl, { id = "hl-1", locationStart = "/body/DocFragment[3]/body/section/p[2]/text().0" }))
    end)
end)

-- ---- Manager integration ----

describe("Manager with a Chapters book", function()
    local Manager = require("manager")
    local layout = ChaptersBook.make_layout(BOOK_ID, { "ch-a", "ch-b", "ch-c" })
    local FILE = "/books/Novel.epub"

    local function new_manager(api)
        local mgr = Manager:new({ api = api, settings = {} })
        mgr._chapters_layouts = { [FILE] = layout, ["/books/Regular.epub"] = false }
        return mgr
    end

    local function doc_info(file, location, percent)
        return { file = file, file_path = file, title = "Novel", location = location, percent = percent or 40,
            total_pages = 100, current_page = 40 }
    end

    it("pushes the chapter reference instead of the XPointer", function()
        local pushed = {}
        local api = {
            has_auth = function() return true end,
            get_progress = function(_, _id, cb) cb(false) end,
            update_progress = function(_, id, location, percent, _is_read, cb)
                pushed[#pushed + 1] = { id = id, location = location, percent = percent }
                if cb then cb(true) end
            end,
        }
        local mgr = new_manager(api)
        mgr.resolve_book_id = function(_, _ui, _doc, cb) cb(BOOK_ID) end
        mgr.get_doc_read_status = function() return false end

        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[2]/body/section/p[3]/text().1") end
        mgr:sync_progress(nil, nil, true)
        assert.is_equal("ch:ch-b", pushed[1].location)
        assert.is_equal(40, pushed[1].percent)

        -- A regular book keeps sending its XPointer
        mgr.get_doc_info = function() return doc_info("/books/Regular.epub", "/body/DocFragment[2]/body/p[3]") end
        mgr:sync_progress(nil, nil, true)
        assert.is_equal("/body/DocFragment[2]/body/p[3]", pushed[2].location)

        -- A position outside the known chapters: percentage only
        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[9]/body/p") end
        mgr:sync_progress(nil, nil, true)
        assert.is_nil(pushed[3].location)
        assert.is_equal(40, pushed[3].percent)
    end)

    it("decides whether the server is ahead by chapter", function()
        -- The web reader counts chapters (2 of 3 = 66.7%), KOReader counts pages
        local remote = { location = "ch:ch-b", progressPercent = 66.7, isRead = false }
        local pushed = {}
        local api = {
            has_auth = function() return true end,
            get_progress = function(_, _id, cb) cb(true, remote) end,
            update_progress = function(_, _id, location, percent, _is_read, cb)
                pushed[#pushed + 1] = { location = location, percent = percent }
                if cb then cb(true) end
            end,
        }
        local mgr = new_manager(api)
        mgr.resolve_book_id = function(_, _ui, _doc, cb) cb(BOOK_ID) end
        mgr.get_doc_read_status = function() return false end

        -- Reading on in the next chapter although the page percentage is still lower
        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[3]/body/section/p[2]/text().0", 61) end
        mgr:sync_progress(nil, nil, true)
        assert.is_equal(1, #pushed)
        assert.is_equal("ch:ch-c", pushed[1].location)

        -- The server is in a later chapter: it is not overwritten, whatever the percentages say
        remote.location, remote.progressPercent = "ch:ch-c", 10
        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[1]/body/section/p[2]/text().0", 30) end
        mgr:sync_progress(nil, nil, true)
        assert.is_equal(1, #pushed)

        -- A regular book keeps comparing percentages
        remote.location, remote.progressPercent = "/body/DocFragment[9]/body/p", 80
        mgr.get_doc_info = function() return doc_info("/books/Regular.epub", "/body/DocFragment[2]/body/p", 30) end
        mgr:sync_progress(nil, nil, true)
        assert.is_equal(1, #pushed)
    end)

    it("opens the chapter the server position points to", function()
        local remote = { location = "ch:ch-c", progressPercent = 90, isRead = false }
        local api = {
            has_auth = function() return true end,
            get_progress = function(_, _id, cb) cb(true, remote) end,
        }
        local mgr = new_manager(api)
        mgr.resolve_book_id = function(_, _ui, _doc, cb) cb(BOOK_ID) end
        local jumps = {}
        mgr.goto_location = function(_, _ui, pos, percent)
            jumps[#jumps + 1] = { pos = pos, percent = percent }
            return true
        end
        local notices = 0
        mgr.notify_missing_chapter = function() notices = notices + 1 end
        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[2]/body/section/p[3]/text().1") end

        mgr:pull_progress(nil, nil, false)
        assert.is_equal(1, #jumps)
        assert.is_equal("/body/DocFragment[3]/body", jumps[1].pos)
        -- No percentage fallback for chapter references
        assert.is_nil(jumps[1].percent)

        -- Same chapter: stay where the reader is
        remote.location = "ch:ch-b"
        mgr:pull_progress(nil, nil, false)
        assert.is_equal(1, #jumps)
        assert.is_equal(0, notices)

        -- A chapter this copy does not have: no jump, the user is told to update
        remote.location = "ch:ch-z"
        mgr:pull_progress(nil, nil, false)
        assert.is_equal(1, #jumps)
        assert.is_equal(1, notices)

        -- The server has no position yet (its placeholder): nothing happens
        remote.location = "cfl:/6/2"
        mgr:pull_progress(nil, nil, false)
        assert.is_equal(1, #jumps)
        assert.is_equal(1, notices)

        -- A regular book still navigates by XPointer with the percentage fallback
        remote.location = "/body/DocFragment[5]/body/p[1]"
        mgr.get_doc_info = function() return doc_info("/books/Regular.epub", "/body/DocFragment[2]/body/p") end
        mgr:pull_progress(nil, nil, false)
        assert.is_equal("/body/DocFragment[5]/body/p[1]", jumps[2].pos)
        assert.is_equal(90, jumps[2].percent)
    end)

    it("links an assembled book to its server id without hashing the file", function()
        local saved = {}
        local hashed = false
        local mgr = new_manager({})
        mgr.invalidate_sync_state = function() end
        mgr.compute_file_hash = function() hashed = true end
        mgr.get_doc_info = function()
            local info = doc_info(FILE, "/body/DocFragment[1]/body")
            info.docsettings = {
                readSetting = function() return nil end,
                saveSetting = function(_, key, value) saved[key] = value end,
            }
            return info
        end

        local resolved
        mgr:resolve_book_id(nil, nil, function(id) resolved = id end)
        assert.is_equal(BOOK_ID, resolved)
        assert.is_equal(BOOK_ID, saved.folio_book_id)
        assert.is_false(hashed)
    end)

    it("relinks a file downloaded over a copy assembled from chapters", function()
        local dir = tmp_dir()
        local target = dir .. "/Novel.epub"
        local api = new_fake_api({ chapter("ch-a", 1, "First", "one") })
        assert.is_true(ChaptersBook.commit(build(api, target)))

        local store = { folio_book_id = BOOK_ID }
        local flushed = false
        package.loaded["docsettings"] = {
            hasSidecarFile = function() return true end,
            open = function()
                return {
                    readSetting = function(_, key) return store[key] end,
                    saveSetting = function(_, key, value) store[key] = value end,
                    flush = function() flushed = true end,
                }
            end,
        }
        finally(function() package.loaded["docsettings"] = nil end)

        local mgr = Manager:new({ api = api, settings = {} })
        assert.is_not_nil(mgr:get_chapters_layout(target))
        local invalidated
        mgr.invalidate_sync_state = function(_, path) invalidated = path end

        mgr:relink_downloaded_file(target, OTHER_BOOK_ID)
        assert.is_false(exists(ChaptersBook.layout_path(target)))
        assert.is_equal(OTHER_BOOK_ID, store.folio_book_id)
        assert.is_true(flushed)
        assert.is_equal(target, invalidated)

        -- The same book downloaded again: nothing to forget
        flushed, invalidated = false, nil
        mgr:relink_downloaded_file(target, OTHER_BOOK_ID)
        assert.is_false(flushed)
        assert.is_nil(invalidated)
    end)

    it("downloads a book, puts it in place and reports the outcome", function()
        local dir = tmp_dir()
        local target = dir .. "/Novel.epub"
        local api = new_fake_api({ chapter("ch-a", 1, "First", "one"), chapter("ch-b", 2, "Second", "two") })
        api.has_auth = function() return true end

        local real_build = ChaptersBook.build
        ChaptersBook.build = function(a, opts)
            opts.open_sink = open_fake_sink
            opts.read_existing = read_fake_existing
            return real_build(a, opts)
        end
        finally(function() ChaptersBook.build = real_build end)

        local mgr = Manager:new({ api = api, settings = {} })
        local done
        mgr:download_chapters_book({ id = BOOK_ID, name = "Novel" }, target, function(success, result, reopened)
            done = { success = success, result = result, reopened = reopened }
        end)
        assert.is_true(done.success)
        assert.is_false(done.reopened)
        assert.is_true(exists(target))
        assert.is_equal("'Novel' downloaded: 2 chapters.", mgr:chapters_result_text("Novel", done.result))
        assert.are.same({ "ch-a", "ch-b" }, mgr:get_chapters_layout(target).chapter_ids)

        -- Nothing new on the server
        mgr:download_chapters_book({ id = BOOK_ID, name = "Novel" }, target, function(success, result)
            done = { success = success, result = result }
        end)
        assert.is_equal("'Novel' is up to date: 2 chapters.", mgr:chapters_result_text("Novel", done.result))

        -- A new chapter
        api.chapters[3] = chapter("ch-c", 3, "Third", "three")
        mgr:download_chapters_book({ id = BOOK_ID, name = "Novel" }, target, function(success, result)
            done = { success = success, result = result }
        end)
        assert.is_equal("'Novel' updated: 1 new or changed chapters, 3 in total.",
            mgr:chapters_result_text("Novel", done.result))
        assert.are.same({ "ch-a", "ch-b", "ch-c" }, mgr:get_chapters_layout(target).chapter_ids)

        -- Failures are reported to the user and to the caller
        local shown = {}
        local UIManager = require("ui/uimanager")
        local real_show = UIManager.show
        UIManager.show = function(_, widget) shown[#shown + 1] = widget end
        finally(function() UIManager.show = real_show end)
        api.chapters = {}
        mgr:download_chapters_book({ id = BOOK_ID, name = "Novel" }, target, function(success, err)
            done = { success = success, err = err }
        end)
        assert.is_false(done.success)
        assert.is_equal(ChaptersBook.ERR_NO_CHAPTERS, done.err)
        assert.is_truthy(tostring(shown[#shown].text):find("no chapters", 1, true))
        -- The copy on the device is untouched
        assert.are.same({ "ch-a", "ch-b", "ch-c" }, mgr:get_chapters_layout(target).chapter_ids)
    end)
end)

-- ---- API client ----

describe("Folio API for Chapters books", function()
    local function install_http(handler)
        package.loaded["socket.http"] = { request = handler }
        package.loaded["ltn12"] = {
            source = { string = function(str) return function() local r = str; str = nil; return r end end },
            sink = { table = function(t) return function(chunk) if chunk then table.insert(t, chunk) end return 1 end end },
        }
        package.loaded["folio_api"] = nil
        return require("folio_api")
    end

    it("requests chapters, illustrations and the cover", function()
        local requests = {}
        local FolioAPI = install_http(function(req)
            requests[#requests + 1] = req
            if req.url:find("/images/", 1, true) or req.url:find("/cover", 1, true) then
                req.sink(PNG)
                return 1, 200, {}
            end
            req.sink('{"items":[{"id":"ch-a"}],"more":false,"total":1}')
            return 1, 200, {}
        end)
        local api = FolioAPI:new({ server_url = "http://localhost:5144/api/", api_key = "key123" })

        local ok, page = api:list_chapters(BOOK_ID, 500, 500)
        assert.is_true(ok)
        assert.is_equal("ch-a", page.items[1].id)
        assert.is_equal("http://localhost:5144/api/books/" .. BOOK_ID .. "/chapters?offset=500&limit=500", requests[1].url)
        assert.is_equal("key123", requests[1].headers["X-API-Key"])

        api:get_chapter(BOOK_ID, "ch-a")
        assert.is_equal("http://localhost:5144/api/books/" .. BOOK_ID .. "/chapters/ch-a", requests[2].url)

        local ok_img, bytes = api:get_book_image(BOOK_ID, "pic.png")
        assert.is_true(ok_img)
        assert.is_equal(PNG, bytes)
        assert.is_equal("http://localhost:5144/api/books/" .. BOOK_ID .. "/images/pic.png", requests[3].url)

        api:get_book_cover(BOOK_ID)
        assert.is_equal("http://localhost:5144/api/books/" .. BOOK_ID .. "/cover", requests[4].url)
    end)

    it("reports the HTTP status of a refused request and network errors", function()
        local FolioAPI = install_http(function() return 1, 403, {} end)
        local api = FolioAPI:new({ server_url = "http://localhost:5144/api", api_key = "key123" })
        local ok, message, code = api:get_chapter(BOOK_ID, "ch-a")
        assert.is_false(ok)
        assert.is_equal("HTTP 403", message)
        assert.is_equal(403, code)

        FolioAPI = install_http(function() return nil, "connection refused" end)
        api = FolioAPI:new({ server_url = "http://localhost:5144/api", api_key = "key123" })
        ok, message, code = api:list_chapters(BOOK_ID, 0, 500)
        assert.is_false(ok)
        assert.is_equal("connection refused", message)
        assert.is_nil(code)
    end)
end)
