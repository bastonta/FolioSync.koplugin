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
    -- `volume` restricts the list like the server does; `api.ignores_volume` plays a
    -- server older than the volumes feature, which ignores the parameter.
    function api:list_chapters(_book_id, offset, limit, volume)
        local failed, message, code = intercept("list:" .. offset .. (volume and (":v" .. tostring(volume)) or ""))
        if failed then return false, message, code end
        local source = self.chapters
        if volume and not self.ignores_volume then
            source = {}
            for _, c in ipairs(self.chapters) do
                if (c.volume or 1) == volume then source[#source + 1] = c end
            end
        end
        local items = {}
        for i = offset + 1, math.min(offset + limit, #source) do
            local c = source[i]
            items[#items + 1] = { id = c.id, volume = c.volume or 1, chapter = c.chapter, name = c.name, updated = c.updated }
        end
        return true, { items = items, more = offset + limit < #source, total = #source }
    end
    function api:list_volumes(_book_id)
        local failed, message, code = intercept("volumes")
        if failed then return false, message, code end
        local counts, order = {}, {}
        for _, c in ipairs(self.chapters) do
            local v = c.volume or 1
            if not counts[v] then
                counts[v] = 0
                order[#order + 1] = v
            end
            counts[v] = counts[v] + 1
        end
        table.sort(order)
        local items = {}
        for _, v in ipairs(order) do
            items[#items + 1] = { volume = v, chaptersCount = counts[v] }
        end
        return true, { items = items, chaptersTotal = #self.chapters }
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

-- ---- Volumes ----

-- A book of three volumes: 2 + 3 + 1 chapters
local function volumes_book()
    local function vch(id, volume, number, name, text)
        local c = chapter(id, number, name, text)
        c.volume = volume
        return c
    end
    return {
        vch("v1-a", 1, 1, "One", "v1 a"),
        vch("v1-b", 1, 2, "Two", "v1 b ![pic](" .. PREFIX .. "one.png)"),
        vch("v2-a", 2, 3, "Three", "v2 a"),
        vch("v2-b", 2, 4, "Four", "v2 b ![pic](" .. PREFIX .. "two.png)"),
        vch("v2-c", 2, 5, "Five", "v2 c"),
        vch("v3-a", 3, 6, "Six", "v3 a"),
    }
end

describe("Chapters book volumes", function()
    it("builds a copy of one volume that knows its place in the book", function()
        local dir = tmp_dir()
        local target = dir .. "/Book - Vol 02.epub"
        local api = new_fake_api(volumes_book())
        api.images["one.png"] = PNG
        api.images["two.png"] = PNG

        local result = assert(build(api, target, { volume = 2 }))
        assert.is_true(ChaptersBook.commit(result))
        assert.are.same({ "v2-a", "v2-b", "v2-c" }, result.chapter_ids)
        assert.are.same({ volume = 2, chapters_before = 2, book_chapters = 6 }, result.scope)
        assert.is_equal("Server Title — Том 2", result.title)
        -- Only this volume was asked for and downloaded
        assert.is_equal(3, api:count("chapter:"))
        assert.is_equal(0, api:count("chapter:v1"))
        assert.is_equal(1, api:count("image:"))

        local _, entries = read_fake_archive(target)
        assert.is_nil(entries["OEBPS/ch-v1-a.xhtml"])
        assert.is_not_nil(entries["OEBPS/ch-v2-c.xhtml"])
        assert.is_nil(entries["OEBPS/images/one.png"])
        assert.is_not_nil(entries["OEBPS/images/two.png"])

        local opf = entries["OEBPS/content.opf"].content
        assert.is_truthy(opf:find("<dc:title>Server Title — Том 2</dc:title>", 1, true))
        assert.is_truthy(opf:find('<dc:identifier id="pub-id">urn:folio:' .. BOOK_ID .. ":volume:2</dc:identifier>", 1, true))
        assert.is_truthy(opf:find('<meta name="calibre:series" content="Server Title"/>', 1, true))
        assert.is_truthy(opf:find('<meta name="calibre:series_index" content="2"/>', 1, true))
        assert.is_truthy(opf:find('<meta property="belongs-to-collection" id="series">Server Title</meta>', 1, true))
        assert.is_truthy(opf:find('<meta refines="#series" property="collection-type">series</meta>', 1, true))
        assert.is_truthy(opf:find('<meta refines="#series" property="group-position">2</meta>', 1, true))

        -- One volume: a flat table of contents under the volume title
        local nav = entries["OEBPS/nav.xhtml"].content
        assert.is_truthy(nav:find("<h1>Server Title — Том 2</h1>", 1, true))
        assert.is_falsy(nav:find("<ol>\n          <li>", 1, true))

        local manifest = json.decode(entries[ChaptersEpub.MANIFEST_PATH].content)
        assert.is_equal(1, manifest.version)
        assert.is_equal(2, manifest.volume)
        assert.is_equal(2, manifest.chaptersBefore)
        assert.is_equal(6, manifest.bookChapters)
        assert.is_equal(3, #manifest.chapters)

        -- The sidecar layout mirrors it, and so does the manifest when the sidecar is gone
        local layout = ChaptersBook.load_layout(target, read_fake_existing)
        assert.is_equal(2, layout.volume)
        assert.is_equal(2, layout.chapters_before)
        assert.is_equal(6, layout.book_chapters)
        os.remove(ChaptersBook.layout_path(target))
        layout = ChaptersBook.load_layout(target, read_fake_existing)
        assert.are.same({ 2, 2, 6 }, { layout.volume, layout.chapters_before, layout.book_chapters })
    end)

    it("keeps a whole-book copy free of volume data", function()
        local dir = tmp_dir()
        local target = dir .. "/Book.epub"
        local api = new_fake_api(volumes_book())
        api.images["one.png"] = PNG
        api.images["two.png"] = PNG
        local result = assert(build(api, target))
        assert.is_true(ChaptersBook.commit(result))
        assert.is_nil(result.scope)
        assert.is_equal(0, api:count("volumes"))

        local _, entries = read_fake_archive(target)
        local opf = entries["OEBPS/content.opf"].content
        assert.is_truthy(opf:find('<dc:identifier id="pub-id">urn:uuid:' .. BOOK_ID .. "</dc:identifier>", 1, true))
        assert.is_falsy(opf:find("calibre:series", 1, true))
        assert.is_falsy(opf:find("belongs-to-collection", 1, true))
        local manifest = json.decode(entries[ChaptersEpub.MANIFEST_PATH].content)
        assert.is_nil(manifest.volume)
        assert.is_nil(manifest.chaptersBefore)
        assert.is_nil(manifest.bookChapters)
        local layout = ChaptersBook.load_layout(target, read_fake_existing)
        assert.is_nil(layout.volume)
        assert.is_false(ChaptersBook.is_volume_copy(layout))
    end)

    it("filters the chapter list itself when the server ignores the volume", function()
        local api = new_fake_api(volumes_book())
        api.ignores_volume = true
        local list = assert(ChaptersBook.fetch_chapter_list(api, BOOK_ID, 2))
        local ids = {}
        for i, c in ipairs(list) do ids[i] = c.id end
        assert.are.same({ "v2-a", "v2-b", "v2-c" }, ids)
        -- and a volume that does not exist is an empty book, not the whole one
        local dir = tmp_dir()
        local result, err = build(api, dir .. "/Book - Vol 09.epub", { volume = 9 })
        assert.is_nil(result)
        assert.is_equal(ChaptersBook.ERR_NO_CHAPTERS, err)
    end)

    it("lists volumes and reports servers that cannot", function()
        local api = new_fake_api(volumes_book())
        local volumes = assert(ChaptersBook.fetch_volumes(api, BOOK_ID))
        assert.is_equal(6, volumes.total)
        assert.are.same({ { volume = 1, chapters = 2 }, { volume = 2, chapters = 3 }, { volume = 3, chapters = 1 } },
            volumes.items)

        -- Older servers: the API key allow-list refuses the route, or the route does not exist
        for _, code in ipairs({ 403, 404 }) do
            api.failures["volumes"] = { { "HTTP " .. code, code } }
            local none, message, http_code = ChaptersBook.fetch_volumes(api, BOOK_ID)
            assert.is_nil(none)
            assert.is_equal("HTTP " .. code, message)
            assert.is_equal(code, http_code)
        end
        -- A client object without the method (should never happen, must not crash)
        assert.is_nil(ChaptersBook.fetch_volumes({}, BOOK_ID))

        -- A volume copy cannot be built without the volume list
        api.failures["volumes"] = { { "HTTP 404", 404 } }
        local dir = tmp_dir()
        local result, err = build(api, dir .. "/Book - Vol 02.epub", { volume = 2 })
        assert.is_nil(result)
        assert.is_truthy(tostring(err):find("volume list", 1, true))
        assert.is_false(exists(dir .. "/Book - Vol 02.epub"))
        assert.is_false(exists(dir .. "/Book - Vol 02.epub.tmp"))
    end)

    it("names volume files and keeps every copy to itself", function()
        assert.is_equal("Vol 03", ChaptersBook.volume_file_suffix(3))
        assert.is_equal("Vol 12", ChaptersBook.volume_file_suffix(12))
        assert.is_equal("Vol 03.5", ChaptersBook.volume_file_suffix(3.5))
        assert.is_equal("Vol 00", ChaptersBook.volume_file_suffix(0))
        assert.is_equal("Vol 120", ChaptersBook.volume_file_suffix(120))

        local dir = tmp_dir()
        local api = new_fake_api(volumes_book())
        api.images["one.png"] = PNG
        api.images["two.png"] = PNG
        local function load(path) return ChaptersBook.load_layout(path, read_fake_existing) end

        -- New files: the whole book and two volumes
        local whole = ChaptersBook.resolve_target(dir, "Book", BOOK_ID, load)
        local vol2 = ChaptersBook.resolve_target(dir, "Book", BOOK_ID, load, 2)
        local vol3 = ChaptersBook.resolve_target(dir, "Book", BOOK_ID, load, 3)
        assert.is_equal(dir .. "/Book.epub", whole)
        assert.is_equal(dir .. "/Book - Vol 02.epub", vol2)
        assert.is_equal(dir .. "/Book - Vol 03.epub", vol3)
        assert.is_true(ChaptersBook.commit(assert(build(api, whole))))
        assert.is_true(ChaptersBook.commit(assert(build(api, vol2, { volume = 2 }))))

        -- Each scope finds its own copy
        local path, layout = ChaptersBook.resolve_target(dir, "Book", BOOK_ID, load)
        assert.is_equal(whole, path)
        assert.is_nil(layout.volume)
        path, layout = ChaptersBook.resolve_target(dir, "Book", BOOK_ID, load, 2)
        assert.is_equal(vol2, path)
        assert.is_equal(2, layout.volume)
        path, layout = ChaptersBook.resolve_target(dir, "Book", BOOK_ID, load, 3)
        assert.is_equal(vol3, path)
        assert.is_nil(layout)

        -- A file of the same book but of another scope is never overwritten
        local result, err = build(api, vol2, { volume = 3 })
        assert.is_nil(result)
        assert.is_equal(ChaptersBook.ERR_NAME_TAKEN, err)
        result, err = build(api, vol2)
        assert.is_nil(result)
        assert.is_equal(ChaptersBook.ERR_NAME_TAKEN, err)
        result, err = build(api, whole, { volume = 2 })
        assert.is_nil(result)
        assert.is_equal(ChaptersBook.ERR_NAME_TAKEN, err)
        assert.are.same({ "v2-a", "v2-b", "v2-c" }, load(vol2).chapter_ids)
        assert.is_equal(6, #load(whole).chapter_ids)

        -- Another book that would get the same name: its volume goes next to it
        local other_path = ChaptersBook.resolve_target(dir, "Book", OTHER_BOOK_ID, load, 2)
        assert.is_equal(dir .. "/Book - Vol 02 (" .. OTHER_BOOK_ID:sub(1, 8) .. ").epub", other_path)
    end)

    it("updates a volume on its own and follows the book as it grows", function()
        local dir = tmp_dir()
        local target = dir .. "/Book - Vol 02.epub"
        local api = new_fake_api(volumes_book())
        api.images["two.png"] = PNG
        assert.is_true(ChaptersBook.commit(assert(build(api, target, { volume = 2 }))))
        local size = io.open(target, "rb"):seek("end")

        -- New chapters in other volumes: this file is not rewritten, but its place moves
        local extra = chapter("v1-c", 2.5, "Two and a half", "v1 c")
        extra.volume = 1
        table.insert(api.chapters, 3, extra)
        api.requests = {}
        local result = assert(build(api, target, { volume = 2 }))
        assert.is_true(result.unchanged)
        assert.is_equal(0, api:count("chapter:"))
        assert.is_true(ChaptersBook.commit(result))
        assert.is_equal(size, io.open(target, "rb"):seek("end"))
        local layout = ChaptersBook.load_layout(target, read_fake_existing)
        assert.are.same({ 2, 3, 7 }, { layout.volume, layout.chapters_before, layout.book_chapters })

        -- A new chapter in this volume: only that one is downloaded
        local added = chapter("v2-d", 5.5, "Five and a half", "v2 d")
        added.volume = 2
        table.insert(api.chapters, 7, added)
        api.requests = {}
        result = assert(build(api, target, { volume = 2 }))
        assert.is_false(result.unchanged)
        assert.is_equal(1, result.chapters_fetched)
        assert.is_equal(1, api:count("chapter:"))
        assert.is_equal(0, api:count("image:"))
        assert.is_true(ChaptersBook.commit(result))
        layout = ChaptersBook.load_layout(target, read_fake_existing)
        assert.are.same({ "v2-a", "v2-b", "v2-c", "v2-d" }, layout.chapter_ids)
        assert.are.same({ 2, 3, 8 }, { layout.volume, layout.chapters_before, layout.book_chapters })
    end)

    it("counts percentages in the whole book", function()
        local whole = ChaptersBook.make_layout(BOOK_ID, { "a", "b" })
        assert.is_equal(40, ChaptersBook.to_book_percent(whole, 40))
        assert.is_equal(40, ChaptersBook.from_book_percent(whole, 40))
        assert.is_true(ChaptersBook.ends_book(whole))

        -- Chapters 21..30 of 100
        local ids = {}
        for i = 1, 10 do ids[i] = "c" .. i end
        local volume = ChaptersBook.make_layout(BOOK_ID, ids, { volume = 3, chapters_before = 20, book_chapters = 100 })
        assert.is_true(ChaptersBook.is_volume_copy(volume))
        assert.is_false(ChaptersBook.ends_book(volume))
        assert.is_equal(20, ChaptersBook.to_book_percent(volume, 0))
        assert.is_equal(25, ChaptersBook.to_book_percent(volume, 50))
        assert.is_equal(30, ChaptersBook.to_book_percent(volume, 100))
        assert.is_equal(30, ChaptersBook.to_book_percent(volume, 250))
        assert.is_equal(50, ChaptersBook.from_book_percent(volume, 25))
        assert.is_equal(0, ChaptersBook.from_book_percent(volume, 5))
        assert.is_equal(100, ChaptersBook.from_book_percent(volume, 80))
        assert.is_nil(ChaptersBook.to_book_percent(volume, nil))

        -- The last volume ends the book; stale counts never put a copy past the end
        local last = ChaptersBook.make_layout(BOOK_ID, ids, { volume = 9, chapters_before = 90, book_chapters = 100 })
        assert.is_true(ChaptersBook.ends_book(last))
        assert.is_equal(100, ChaptersBook.to_book_percent(last, 100))
        local stale = ChaptersBook.make_layout(BOOK_ID, ids, { volume = 9, chapters_before = 95, book_chapters = 100 })
        assert.is_equal(105, stale.book_chapters)
        assert.is_equal(100, ChaptersBook.to_book_percent(stale, 100))
    end)

    it("translates bookmark and annotation positions to and from the whole book", function()
        local whole = ChaptersBook.make_layout(BOOK_ID, { "a", "b", "c" })
        local volume = ChaptersBook.make_layout(BOOK_ID, { "a", "b", "c" },
            { volume = 2, chapters_before = 10, book_chapters = 20 })
        local xp = "/body/DocFragment[2]/body/section/p[3]/text().7"

        assert.is_equal(xp, ChaptersBook.to_server_xpointer(whole, xp))
        assert.is_equal(xp, ChaptersBook.to_local_xpointer(whole, xp))
        assert.is_equal("/body/DocFragment[12]/body/section/p[3]/text().7", ChaptersBook.to_server_xpointer(volume, xp))
        assert.is_equal(xp, ChaptersBook.to_local_xpointer(volume, "/body/DocFragment[12]/body/section/p[3]/text().7"))
        -- crengine leaves the index out of a single-fragment book
        assert.is_equal("/body/DocFragment[11]/body/p", ChaptersBook.to_server_xpointer(volume, "/body/DocFragment/body/p"))
        -- Other volumes
        assert.is_nil(ChaptersBook.to_local_xpointer(volume, "/body/DocFragment[10]/body/p"))
        assert.is_nil(ChaptersBook.to_local_xpointer(volume, "/body/DocFragment[14]/body/p"))
        assert.is_nil(ChaptersBook.to_local_xpointer(volume, "/body/DocFragment/body/p"))
        -- Positions that name no chapter cannot be placed: left alone both ways
        assert.is_equal("page_4", ChaptersBook.to_server_xpointer(volume, "page_4"))
        assert.is_equal("page_4", ChaptersBook.to_local_xpointer(volume, "page_4"))

        local remote = {
            { id = "r1", locationStart = "/body/DocFragment[11]/body/p[1]/text().0", locationEnd = "/body/DocFragment[11]/body/p[1]/text().9" },
            { id = "r2", locationStart = "/body/DocFragment[3]/body/p[1]/text().0", locationEnd = "/body/DocFragment[3]/body/p[1]/text().9" },
            { id = "r3", location = "/body/DocFragment[13]/body/p[2]" },
            { id = "r4", location = "/body/DocFragment[40]/body/p[2]" },
            { id = "r5", location = "page_3" },
        }
        assert.is_equal(remote, ChaptersBook.localize_items(whole, remote))
        local localized = ChaptersBook.localize_items(volume, remote)
        assert.is_equal(3, #localized)
        assert.are.same({ id = "r1", locationStart = "/body/DocFragment[1]/body/p[1]/text().0",
            locationEnd = "/body/DocFragment[1]/body/p[1]/text().9" }, localized[1])
        assert.are.same({ id = "r3", location = "/body/DocFragment[3]/body/p[2]" }, localized[2])
        assert.are.same({ id = "r5", location = "page_3" }, localized[3])
        -- The server's own items are not touched
        assert.is_equal("/body/DocFragment[11]/body/p[1]/text().0", remote[1].locationStart)

        local payload = { locationStart = "/body/DocFragment[1]/body/p[1]/text().0", locationEnd = "", note = "n" }
        assert.is_equal(payload, ChaptersBook.globalize_item(whole, payload))
        assert.are.same({ locationStart = "/body/DocFragment[11]/body/p[1]/text().0", locationEnd = "", note = "n" },
            ChaptersBook.globalize_item(volume, payload))
        assert.is_equal("/body/DocFragment[1]/body/p[1]/text().0", payload.locationStart)
    end)
end)

describe("Manager with a copy of one volume", function()
    local Manager = require("manager")
    local FILE = "/books/Novel - Vol 02.epub"
    local LAST = "/books/Novel - Vol 03.epub"
    -- Chapters 5..8 of 10, and the last two
    local layout = ChaptersBook.make_layout(BOOK_ID, { "c5", "c6", "c7", "c8" },
        { volume = 2, chapters_before = 4, book_chapters = 10 })
    local last_layout = ChaptersBook.make_layout(BOOK_ID, { "c9", "c10" },
        { volume = 3, chapters_before = 8, book_chapters = 10 })

    local function new_manager(api)
        local mgr = Manager:new({ api = api, settings = {} })
        mgr._chapters_layouts = { [FILE] = layout, [LAST] = last_layout, ["/books/Regular.epub"] = false }
        mgr.resolve_book_id = function(_, _ui, _doc, cb) cb(BOOK_ID) end
        if not api.list_annotations then
            -- push_all_data goes on to annotations and sessions: not what these tests are about
            mgr.sync_annotations_and_bookmarks = function() end
        end
        if not api.push_reading_sessions then
            mgr.sync_reading_sessions = function() end
        end
        return mgr
    end

    local function doc_info(file, location, percent)
        return { file = file, file_path = file, title = "Novel", location = location, percent = percent or 50,
            total_pages = 100, current_page = 50 }
    end

    local function progress_api(remote, pushed)
        return {
            has_auth = function() return true end,
            get_progress = function(_, _id, cb) cb(remote ~= nil, remote) end,
            update_progress = function(_, _id, location, percent, is_read, cb)
                pushed[#pushed + 1] = { location = location, percent = percent, is_read = is_read,
                    has_read = is_read ~= nil }
                if cb then cb(true) end
            end,
        }
    end

    it("pushes the chapter and a percentage of the whole book", function()
        local pushed = {}
        local mgr = new_manager(progress_api(nil, pushed))
        mgr.get_doc_read_status = function() return false end
        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[2]/body/section/p[3]/text().1", 50) end
        mgr:sync_progress(nil, nil, true)
        assert.is_equal("ch:c6", pushed[1].location)
        -- Half of chapters 5..8 of 10
        assert.is_equal(60, pushed[1].percent)
        assert.is_false(pushed[1].has_read)

        mgr:push_all_data(nil, nil, false)
        assert.is_equal(60, pushed[2].percent)
        assert.is_false(pushed[2].has_read)
    end)

    it("does not call the book read when a volume is finished", function()
        local pushed = {}
        local remote = { location = "ch:c5", progressPercent = 45, isRead = false }
        local mgr = new_manager(progress_api(remote, pushed))
        local marked = {}
        mgr.set_local_read_status = function(_, info, is_read) marked[#marked + 1] = { info.file, is_read } end
        mgr.get_doc_read_status = function() return true end

        -- The volume is finished, the book goes on: the flag is not sent at all
        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[4]/body/p", 100) end
        mgr:sync_progress(nil, nil, true)
        assert.is_equal(1, #pushed)
        assert.is_equal(80, pushed[1].percent)
        assert.is_false(pushed[1].has_read)
        mgr:push_all_data(nil, nil, false)
        assert.is_false(pushed[2].has_read)

        -- A book that is read on the server stays read
        remote.isRead = true
        mgr:sync_progress(nil, nil, true)
        assert.is_true(pushed[3].is_read)
        assert.is_equal(0, #marked)
        -- ...and marks an unfinished volume as read, as it does with a whole book
        mgr.get_doc_read_status = function() return false end
        mgr:sync_progress(nil, nil, true)
        assert.are.same({ FILE, true }, marked[1])
        assert.is_true(pushed[4].is_read)

        -- The last volume ends the book: finishing it finishes the book
        remote.isRead = false
        mgr.get_doc_read_status = function() return true end
        mgr.get_doc_info = function() return doc_info(LAST, "/body/DocFragment[2]/body/p", 100) end
        mgr:sync_progress(nil, nil, true)
        assert.is_true(pushed[5].is_read)
        assert.is_equal(100, pushed[5].percent)
        assert.is_equal("ch:c10", pushed[5].location)
    end)

    it("leaves a position in a later volume alone and overtakes one in an earlier volume", function()
        local pushed = {}
        local remote = { location = "ch:c9", progressPercent = 85, isRead = false }
        local mgr = new_manager(progress_api(remote, pushed))
        mgr.get_doc_read_status = function() return false end
        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[4]/body/p", 99) end

        -- The server is in volume 3: 99% of volume 2 is 79.6% of the book
        mgr:sync_progress(nil, nil, true)
        assert.is_equal(0, #pushed)

        -- The server is in volume 1 at 30% of the book
        remote.location, remote.progressPercent = "ch:c2", 30
        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[1]/body/p", 1) end
        mgr:sync_progress(nil, nil, true)
        assert.is_equal(1, #pushed)
        assert.is_equal("ch:c5", pushed[1].location)
    end)

    it("opens a server position of this volume and stays quiet about other volumes", function()
        local remote = { location = "ch:c7", progressPercent = 65, isRead = false }
        local mgr = new_manager(progress_api(remote, {}))
        local jumps, notified = {}, 0
        mgr.goto_location = function(_, _ui, pos, percent) jumps[#jumps + 1] = { pos = pos, percent = percent } end
        mgr.notify_missing_chapter = function() notified = notified + 1 end
        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[1]/body/p", 10) end

        mgr:pull_progress(nil, nil, false)
        assert.are.same({ { pos = "/body/DocFragment[3]/body" } }, jumps)

        -- Another volume: nothing to open, and nothing the user has to do about it
        remote.location = "ch:c2"
        mgr:pull_progress(nil, nil, false)
        remote.location = "ch:c9"
        mgr:pull_progress(nil, nil, false)
        assert.is_equal(1, #jumps)
        assert.is_equal(0, notified)
    end)

    it("marks a volume in the document menu on the device only", function()
        package.loaded["menus"] = nil
        local Menus = require("menus")
        local pushed = {}
        local api = progress_api(nil, pushed)
        local mgr = new_manager(api)
        local marked = {}
        mgr.set_local_read_status = function(_, info, is_read) marked[#marked + 1] = { info.file, is_read } end
        mgr.get_doc_read_status = function() return false end
        local menus = setmetatable({ api = api, plugin = { manager = mgr, get_ui = function() return {} end } },
            { __index = Menus })

        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[4]/body/p", 100) end
        menus:toggle_active_doc_read_status()
        assert.are.same({ FILE, true }, marked[1])
        assert.is_equal(0, #pushed)

        -- The last volume speaks for the book
        mgr.get_doc_info = function() return doc_info(LAST, "/body/DocFragment[2]/body/p", 100) end
        menus:toggle_active_doc_read_status()
        assert.are.same({ LAST, true }, marked[2])
        assert.is_true(pushed[1].is_read)
        assert.is_equal(100, pushed[1].percent)
    end)

    it("sends reading sessions in percentages of the whole book", function()
        local sent
        local api = {
            has_auth = function() return true end,
            push_reading_sessions = function(_, sessions, cb) sent = sessions; cb(true) end,
        }
        local mgr = new_manager(api)
        local states = {}
        mgr.load_sync_state = function(_, path) return states[path] or { pending_sessions = {} } end
        mgr.save_sync_state = function(_, state, path) states[path] = state end
        mgr.get_doc_info = function() return doc_info(FILE, "/body/DocFragment[2]/body/p", 50) end
        states[FILE] = { pending_sessions = { { client_session_id = "s1", start_time = "t0", end_time = "t1",
            duration_seconds = 60, start_progress = 25, end_progress = 75, pages_read = 3 } } }

        mgr:sync_reading_sessions(nil, nil)
        assert.is_equal(50, sent[1].startProgress)
        assert.is_equal(70, sent[1].endProgress)
        assert.is_equal(0, #states[FILE].pending_sessions)

        -- Any other book is sent as recorded
        mgr.get_doc_info = function() return doc_info("/books/Regular.epub", "/body/DocFragment[2]/body/p", 50) end
        states["/books/Regular.epub"] = { pending_sessions = { { client_session_id = "s2", start_time = "t0",
            end_time = "t1", duration_seconds = 60, start_progress = 25, end_progress = 75 } } }
        mgr:sync_reading_sessions(nil, nil)
        assert.is_equal(25, sent[1].startProgress)
        assert.is_equal(75, sent[1].endProgress)
    end)

    -- A server with highlights and bookmarks all over the book
    local function annotations_api(remote_annos, remote_bms, log)
        return {
            has_auth = function() return true end,
            list_annotations = function(_, _id, _since, cb) cb(true, remote_annos) end,
            list_bookmarks = function(_, _id, _since, cb) cb(true, remote_bms) end,
            create_annotation = function(_, _id, payload, cb)
                log[#log + 1] = { "create_annotation", payload }
                if cb then cb(true, { id = "new-a" .. #log }) end
            end,
            update_annotation = function(_, _id, fid, payload) log[#log + 1] = { "update_annotation", payload, fid } end,
            delete_annotation = function(_, _id, fid) log[#log + 1] = { "delete_annotation", fid } end,
            create_bookmark = function(_, _id, payload, cb)
                log[#log + 1] = { "create_bookmark", payload }
                if cb then cb(true, { id = "new-b" .. #log }) end
            end,
            delete_bookmark = function(_, _id, fid) log[#log + 1] = { "delete_bookmark", fid } end,
        }
    end

    local function new_docsettings(items)
        local data = { annotations = items }
        return {
            data = data,
            readSetting = function(_, key) return data[key] end,
            saveSetting = function(_, key, value) data[key] = value end,
            flush = function() end,
        }
    end

    it("syncs only its own bookmarks and annotations, in whole-book positions", function()
        local remote_annos = {
            { id = "a-vol1", locationStart = "/body/DocFragment[2]/body/p[1]/text().0",
                locationEnd = "/body/DocFragment[2]/body/p[1]/text().5", selectedText = "early" },
            { id = "a-vol2", locationStart = "/body/DocFragment[6]/body/p[1]/text().0",
                locationEnd = "/body/DocFragment[6]/body/p[1]/text().5", selectedText = "mine" },
            { id = "a-vol3", locationStart = "/body/DocFragment[9]/body/p[1]/text().0",
                locationEnd = "/body/DocFragment[9]/body/p[1]/text().5", selectedText = "late" },
        }
        local remote_bms = {
            { id = "b-vol1", location = "/body/DocFragment[1]/body/p[4]", title = "Early" },
            { id = "b-vol2", location = "/body/DocFragment[8]/body/p[4]", title = "Mine" },
        }
        local log = {}
        local mgr = new_manager(annotations_api(remote_annos, remote_bms, log))
        local states = {}
        mgr.load_sync_state = function(_, path)
            return states[path] or { has_synced_annos = false, has_synced_bms = false, annotations = {}, bookmarks = {},
                pending_sessions = {} }
        end
        mgr.save_sync_state = function(_, state, path) states[path] = state end

        local docsettings = new_docsettings({
            { pos0 = "/body/DocFragment[3]/body/p[2]/text().0", pos1 = "/body/DocFragment[3]/body/p[2]/text().4",
                page = "/body/DocFragment[3]/body/p[2]/text().0", text = "local highlight" },
            { pos0 = "/body/DocFragment[1]/body/p[9]", page = "/body/DocFragment[1]/body/p[9]", text = "Local mark" },
        })
        local info = doc_info(FILE, "/body/DocFragment[2]/body/p", 50)
        info.docsettings = docsettings
        mgr.get_doc_info = function() return info end

        local function find(pos0)
            for _, item in ipairs(docsettings.data.annotations) do
                if item.pos0 == pos0 then return item end
            end
        end

        -- First sync: local items go up shifted by the four chapters before this volume,
        -- the server's items of this volume come down shifted back
        mgr:sync_annotations(nil, nil, false)
        mgr:sync_bookmarks(nil, nil, false)
        assert.is_equal(2, #log)
        assert.is_equal("create_annotation", log[1][1])
        assert.is_equal("/body/DocFragment[7]/body/p[2]/text().0", log[1][2].locationStart)
        assert.is_equal("/body/DocFragment[7]/body/p[2]/text().4", log[1][2].locationEnd)
        assert.is_equal("create_bookmark", log[2][1])
        assert.is_equal("/body/DocFragment[5]/body/p[9]", log[2][2].location)

        assert.is_equal(4, #docsettings.data.annotations)
        local pulled = find("/body/DocFragment[2]/body/p[1]/text().0")
        assert.is_equal("a-vol2", pulled.folio_id)
        assert.is_equal("/body/DocFragment[2]/body/p[1]/text().5", pulled.pos1)
        assert.is_equal("b-vol2", find("/body/DocFragment[4]/body/p[4]").folio_id)
        -- Nothing of the other volumes came in
        for _, item in ipairs(docsettings.data.annotations) do
            assert.is_falsy(item.folio_id == "a-vol1" or item.folio_id == "a-vol3" or item.folio_id == "b-vol1")
        end

        -- The server now has what was pushed (as it stores it) next to the rest
        remote_annos[#remote_annos + 1] = { id = find("/body/DocFragment[3]/body/p[2]/text().0").folio_id,
            locationStart = "/body/DocFragment[7]/body/p[2]/text().0", locationEnd = "/body/DocFragment[7]/body/p[2]/text().4",
            selectedText = "local highlight" }
        remote_bms[#remote_bms + 1] = { id = find("/body/DocFragment[1]/body/p[9]").folio_id,
            location = "/body/DocFragment[5]/body/p[9]", title = "Local mark" }

        -- Following full syncs: nothing to do — above all, the other volumes' items are
        -- neither deleted on the server nor missed here
        log = {}
        mgr.api = annotations_api(remote_annos, remote_bms, log)
        mgr:sync_annotations(nil, nil, true)
        mgr:sync_bookmarks(nil, nil, true)
        assert.are.same({}, log)
        assert.is_equal(4, #docsettings.data.annotations)

        -- A highlight removed on the device is removed on the server by its id only
        for index, item in ipairs(docsettings.data.annotations) do
            if item.folio_id == "a-vol2" then
                table.remove(docsettings.data.annotations, index)
                break
            end
        end
        mgr:sync_annotations(nil, nil, true)
        assert.are.same({ { "delete_annotation", "a-vol2" } }, log)

        -- A highlight removed on the server disappears here; the other volumes' stay there
        log = {}
        mgr.api = annotations_api({ remote_annos[1], remote_annos[3] }, remote_bms, log)
        mgr:sync_annotations(nil, nil, true)
        assert.are.same({}, log)
        assert.is_nil(find("/body/DocFragment[3]/body/p[2]/text().0"))
        assert.is_equal(2, #docsettings.data.annotations)
    end)

    it("downloads and updates a volume as a file of its own", function()
        local dir = tmp_dir()
        local target = dir .. "/Novel - Vol 02.epub"
        local api = new_fake_api(volumes_book())
        api.images["two.png"] = PNG
        api.has_auth = function() return true end

        local real_build = ChaptersBook.build
        local seen = {}
        ChaptersBook.build = function(a, opts)
            opts.open_sink = open_fake_sink
            opts.read_existing = read_fake_existing
            seen[#seen + 1] = { volume = opts.volume, title = opts.title }
            return real_build(a, opts)
        end
        finally(function() ChaptersBook.build = real_build end)

        local mgr = Manager:new({ api = api, settings = {} })
        local done
        mgr:download_chapters_book({ id = BOOK_ID, name = "Novel", volume = 2 }, target, function(success, result)
            done = { success = success, result = result }
        end)
        assert.is_true(done.success)
        assert.is_equal(2, seen[1].volume)
        local layout_now = mgr:get_chapters_layout(target)
        assert.are.same({ "v2-a", "v2-b", "v2-c" }, layout_now.chapter_ids)
        assert.are.same({ 2, 2, 6 }, { layout_now.volume, layout_now.chapters_before, layout_now.book_chapters })
        assert.is_equal(BOOK_ID, mgr:resolve_book_id({ document = { file = target } }, { file = target }))

        -- "Update Book Chapters" on the open volume updates that volume
        local added = chapter("v2-d", 5.5, "Five and a half", "v2 d")
        added.volume = 2
        table.insert(api.chapters, 6, added)
        mgr.get_doc_info = function()
            return { file = target, file_path = target, title = "Server Title — Том 2" }
        end
        local shown = {}
        local UIManager = require("ui/uimanager")
        local real_show = UIManager.show
        UIManager.show = function(_, widget) shown[#shown + 1] = widget end
        finally(function() UIManager.show = real_show end)
        mgr:update_active_chapters_book()
        assert.is_equal(2, seen[2].volume)
        assert.is_nil(seen[2].title)
        assert.are.same({ "v2-a", "v2-b", "v2-c", "v2-d" }, mgr:get_chapters_layout(target).chapter_ids)
        assert.is_truthy(tostring(shown[#shown].text):find("Server Title — Том 2", 1, true))
    end)
end)

describe("Library browser with a book of several volumes", function()
    local function new_browser(api, download_dir)
        package.loaded["browser"] = nil
        local FolioBrowser = require("browser")
        local browser = setmetatable({
            api = api,
            plugin = { settings = { download_dir = download_dir, create_series_folders = false } },
            paths = {},
        }, { __index = FolioBrowser })
        return browser
    end

    local function capture_shown()
        local shown = {}
        local UIManager = require("ui/uimanager")
        local real_show = UIManager.show
        UIManager.show = function(_, widget) shown[#shown + 1] = widget end
        finally(function() UIManager.show = real_show end)
        return shown
    end

    it("offers the whole book or a volume and marks the copies on the device", function()
        local dir = tmp_dir()
        local api = new_fake_api(volumes_book())
        api.images["one.png"] = PNG
        api.images["two.png"] = PNG
        local book = { id = BOOK_ID, name = "Novel", author = "Ann", kind = "Chapters" }

        -- Volume 2 is already on the device
        local real_load = ChaptersBook.load_layout
        ChaptersBook.load_layout = function(path) return real_load(path, read_fake_existing) end
        finally(function() ChaptersBook.load_layout = real_load end)
        local vol2 = dir .. "/Novel - Ann - Vol 02.epub"
        assert.is_true(ChaptersBook.commit(assert(build(api, vol2, { volume = 2 }))))

        local shown = capture_shown()
        local browser = new_browser(api, dir)
        local started = {}
        browser.plugin.manager = {
            download_chapters_book = function(_, request, target_path) started[#started + 1] = { request, target_path } end,
        }

        browser:start_download(book, dir)
        local menu = shown[#shown]
        assert.is_equal(4, #menu.item_table)
        assert.is_equal("Whole book (6 chapters)", menu.item_table[1].text)
        assert.is_nil(menu.item_table[1].mandatory)
        assert.is_equal("Volume 1 (2 chapters)", menu.item_table[2].text)
        assert.is_nil(menu.item_table[2].mandatory)
        assert.is_equal("Volume 2 (3 chapters)", menu.item_table[3].text)
        assert.is_equal("on device", menu.item_table[3].mandatory)
        assert.is_equal("Volume 3 (1 chapters)", menu.item_table[4].text)

        -- A new volume: asks, then downloads into its own file
        menu.item_table[4].callback()
        local confirm = shown[#shown]
        assert.is_truthy(tostring(confirm.text):find("Download 'Novel — Volume 3'", 1, true))
        confirm.ok_callback()
        assert.is_equal(3, started[1][1].volume)
        assert.is_equal("Novel — Volume 3", started[1][1].display_title)
        assert.is_equal(dir .. "/Novel - Ann - Vol 03.epub", started[1][2])

        -- The volume that is on the device: offers an update of that file
        menu.item_table[3].callback()
        confirm = shown[#shown]
        assert.is_truthy(tostring(confirm.text):find("'Novel — Volume 2' is already on this device", 1, true))
        confirm.ok_callback()
        assert.is_equal(2, started[2][1].volume)
        assert.is_equal(vol2, started[2][2])

        -- The whole book: the file it always had
        menu.item_table[1].callback()
        confirm = shown[#shown]
        assert.is_truthy(tostring(confirm.text):find("Download 'Novel' to", 1, true))
        confirm.ok_callback()
        assert.is_nil(started[3][1].volume)
        assert.is_nil(started[3][1].display_title)
        assert.is_equal(dir .. "/Novel - Ann.epub", started[3][2])
    end)

    it("downloads the whole book when there is nothing to choose from", function()
        local dir = tmp_dir()
        local book = { id = BOOK_ID, name = "Novel", kind = "Chapters" }
        local shown = capture_shown()

        -- One volume
        local api = new_fake_api({ chapter("ch-a", 1, "First", "one"), chapter("ch-b", 2, "Second", "two") })
        local browser = new_browser(api, dir)
        browser:start_download(book, dir)
        assert.is_equal(1, #shown)
        assert.is_truthy(tostring(shown[1].text):find("Download 'Novel' to", 1, true))
        assert.is_nil(shown[1].item_table)

        -- A server that cannot list volumes (older Folio): no question, no error
        for _, code in ipairs({ 403, 404 }) do
            api = new_fake_api(volumes_book())
            api.failures["volumes"] = { { "HTTP " .. code, code } }
            browser = new_browser(api, dir)
            local before = #shown
            browser:start_download(book, dir)
            assert.is_equal(before + 1, #shown)
            assert.is_nil(shown[#shown].item_table)
            assert.is_truthy(tostring(shown[#shown].text):find("Download 'Novel' to", 1, true))
        end
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

    it("requests the volumes of a book and the chapters of one volume", function()
        local requests = {}
        local FolioAPI = install_http(function(req)
            requests[#requests + 1] = req
            if req.url:find("/volumes", 1, true) then
                req.sink('{"items":[{"volume":1,"chaptersCount":2},{"volume":2.5,"chaptersCount":3}],"chaptersTotal":5}')
            else
                req.sink('{"items":[{"id":"ch-a","volume":2.5}],"more":false,"total":1}')
            end
            return 1, 200, {}
        end)
        local api = FolioAPI:new({ server_url = "http://localhost:5144/api/", api_key = "key123" })

        local ok, data = api:list_volumes(BOOK_ID)
        assert.is_true(ok)
        assert.is_equal(5, data.chaptersTotal)
        assert.is_equal("http://localhost:5144/api/books/" .. BOOK_ID .. "/volumes", requests[1].url)
        assert.is_equal("key123", requests[1].headers["X-API-Key"])

        api:list_chapters(BOOK_ID, 0, 500, 3)
        assert.is_equal("http://localhost:5144/api/books/" .. BOOK_ID .. "/chapters?offset=0&limit=500&volume=3", requests[2].url)
        api:list_chapters(BOOK_ID, 500, 500, 2.5)
        assert.is_equal("http://localhost:5144/api/books/" .. BOOK_ID .. "/chapters?offset=500&limit=500&volume=2.5", requests[3].url)
        -- No volume: the request is what it always was
        api:list_chapters(BOOK_ID, 0, 500)
        assert.is_equal("http://localhost:5144/api/books/" .. BOOK_ID .. "/chapters?offset=0&limit=500", requests[4].url)

        local volumes = ChaptersBook.fetch_volumes(api, BOOK_ID)
        assert.are.same({ { volume = 1, chapters = 2 }, { volume = 2.5, chapters = 3 } }, volumes.items)
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
