--[[--
Builds a local EPUB 3 file from the chapters of a Folio `Chapters` book.

Such books have no file on the server (`/download` answers 409), so the plugin assembles
one on the device. The layout mirrors the Folio server compiler and the FolioReader
builder: paragraphs are lightweight markdown where only images (`![alt](url)` and
`<img src>`) are interpreted, everything else is emitted as escaped text with line breaks.

What matters for an updatable local copy:
- chapter documents are named after the chapter id (`ch-<id>.xhtml`), so an update can
  copy unchanged chapters from the previous file instead of downloading them again;
- `META-INF/folio-chapters.json` records which chapters and illustrations the file holds;
- the spine holds nothing but the chapters, so `DocFragment[N]` of a KOReader XPointer is
  the N-th chapter and can be converted to and from a chapter id.

A file may hold the whole book or a single volume of it (`meta.volume`). A volume copy is
titled `<title> — Volume N`, names the book as its series and records in the manifest
where it sits in the book (`volume`, `chaptersBefore`, `bookChapters`).
]]

local M = {}

-- Archive entry describing the chapters stored in a locally built EPUB.
M.MANIFEST_PATH = "META-INF/folio-chapters.json"
-- Bumped whenever the rendering changes in a way that makes old chapter documents unusable.
M.MANIFEST_VERSION = 1

local CONTENT_DIR = "OEBPS"

-- ================= TEXT HELPERS =================

-- Byte length of the whitespace character starting at `i` (Unicode White_Space), or nil.
local function space_len(s, i)
    local b = s:byte(i)
    if not b then return nil end
    if b == 32 or (b >= 9 and b <= 13) then return 1 end
    if b == 0xC2 then
        local c = s:byte(i + 1)
        if c == 0xA0 or c == 0x85 then return 2 end
    elseif b == 0xE1 then
        if s:sub(i, i + 2) == "\225\154\128" then return 3 end
    elseif b == 0xE2 then
        local c, d = s:byte(i + 1, i + 2)
        if c == 0x80 and d and ((d >= 0x80 and d <= 0x8A) or d == 0xA8 or d == 0xA9 or d == 0xAF) then
            return 3
        end
        if c == 0x81 and d == 0x9F then return 3 end
    elseif b == 0xE3 then
        if s:sub(i, i + 2) == "\227\128\128" then return 3 end
    end
    return nil
end

-- Trims whitespace on both sides, including non-breaking and ideographic spaces.
local function trim(s)
    local i, j = 1, #s
    while i <= j do
        local n = space_len(s, i)
        if not n then break end
        i = i + n
    end
    while j >= i do
        local n
        if space_len(s, j) == 1 then
            n = 1
        elseif j - 1 >= i and space_len(s, j - 1) == 2 then
            n = 2
        elseif j - 2 >= i and space_len(s, j - 2) == 3 then
            n = 3
        end
        if not n then break end
        j = j - n
    end
    return s:sub(i, j)
end
M.trim = trim

local function escape_text(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function escape_attr(s)
    return (escape_text(s):gsub('"', "&quot;"))
end

local function format_number(n)
    n = tonumber(n) or 0
    if n == math.floor(n) then
        return string.format("%d", n)
    end
    return (string.format("%.7g", n))
end

M.format_number = format_number

local function as_string(v)
    return type(v) == "string" and v or nil
end

-- Language tag used in the package and chapter documents (`en` when the server has none).
function M.normalize_language(language)
    local lang = type(language) == "string" and trim(language) or ""
    if lang ~= "" and #lang <= 35 and not lang:find("[^A-Za-z0-9%-]") then
        return lang
    end
    return "en"
end

local function is_russian(lang)
    local lower = tostring(lang or ""):lower()
    return lower == "ru" or lower:sub(1, 3) == "ru-"
end

local function chapter_word(lang)
    return is_russian(lang) and "Глава" or "Chapter"
end

local function volume_word(lang)
    return is_russian(lang) and "Том" or "Volume"
end

-- Title of a copy that holds a single volume of the book: `<title> — Volume N`.
function M.volume_title(lang, title, volume)
    return string.format("%s — %s %s", title, volume_word(lang), format_number(volume))
end

-- Table of contents label of a chapter.
local function chapter_label(lang, chapter, name)
    name = trim(tostring(name or ""))
    local number = format_number(chapter)
    if name == "" then
        return chapter_word(lang) .. " " .. number
    elseif name:sub(1, #number) == number then
        return name
    end
    return number .. ". " .. name
end
M.chapter_label = chapter_label

-- Keeps only characters that are safe in an archive entry name and an XML id.
local function sanitize_id(id)
    return (tostring(id or ""):gsub("[^A-Za-z0-9%-_]", "_"))
end

-- File name (relative to `OEBPS/`) of a chapter document.
function M.chapter_file_name(chapter_id)
    return "ch-" .. sanitize_id(chapter_id) .. ".xhtml"
end

-- Archive entry name of a chapter document.
function M.chapter_entry_name(chapter_id)
    return CONTENT_DIR .. "/" .. M.chapter_file_name(chapter_id)
end

-- Archive entry name of an illustration.
function M.image_entry_name(filename)
    return CONTENT_DIR .. "/images/" .. filename
end

-- Archive entry name of a file stored directly under `OEBPS/` (the cover).
function M.content_entry_name(filename)
    return CONTENT_DIR .. "/" .. filename
end

-- Illustration file names are embedded as archive entries and `src` attributes, so only
-- plain names are accepted (no separators, no parent references, nothing that needs
-- URL escaping).
local function is_safe_image_name(name)
    return type(name) == "string"
        and name ~= ""
        and #name <= 200
        and name:sub(1, 1) ~= "."
        and not name:find("..", 1, true)
        and not name:find("[^A-Za-z0-9%.%-_]")
end
M.is_safe_image_name = is_safe_image_name

-- Extracts the illustration file name from an image URL that points into the book's own
-- image store (`/api/books/{id}/images/{file}`, optionally with a scheme and host).
local function local_image_name(url, image_url_prefix)
    local rest
    if url:sub(1, #image_url_prefix) == image_url_prefix then
        rest = url:sub(#image_url_prefix + 1)
    elseif url:sub(1, 7) == "http://" or url:sub(1, 8) == "https://" then
        local _, pos_end = url:find(image_url_prefix, 1, true)
        if not pos_end then return nil end
        rest = url:sub(pos_end + 1)
    else
        return nil
    end
    local file = rest:match("^[^?#]*")
    if is_safe_image_name(file) then
        return file
    end
    return nil
end
M.local_image_name = local_image_name

-- Detects a raster image format by its magic bytes; returns extension, media type.
function M.sniff_image(bytes)
    if type(bytes) ~= "string" then return nil end
    if bytes:sub(1, 3) == "\255\216\255" then
        return "jpg", "image/jpeg"
    elseif bytes:sub(1, 4) == "\137PNG" then
        return "png", "image/png"
    elseif bytes:sub(1, 4) == "GIF8" then
        return "gif", "image/gif"
    elseif #bytes >= 12 and bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
        return "webp", "image/webp"
    end
    return nil
end

local MEDIA_TYPES = {
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    png = "image/png",
    gif = "image/gif",
    webp = "image/webp",
    svg = "image/svg+xml",
    avif = "image/avif",
    bmp = "image/bmp",
}

-- Media type of an image, by extension first and by magic bytes as a fallback.
function M.image_media_type(filename, bytes)
    local ext = tostring(filename or ""):match("%.([^.]+)$")
    local by_ext = ext and MEDIA_TYPES[ext:lower()]
    if by_ext then return by_ext end
    local _, mime = M.sniff_image(bytes)
    return mime or "image/jpeg"
end

-- ================= CHAPTER RENDERING =================

-- Parses `![alt](url "title")` at the start of `s`; returns alt, url, consumed bytes.
local function parse_markdown_image(s)
    local close_alt = s:find("](", 1, true)
    if not close_alt then return nil end
    local alt = s:sub(3, close_alt - 1)
    local after = s:sub(close_alt + 2)
    local close = after:find(")", 1, true)
    if not close then return nil end
    local url = trim(after:sub(1, close - 1)):match("^(%S+)")
    if not url or url == "" then return nil end
    return alt, url, close_alt + 1 + close
end

local function extract_attr(tag, name)
    local lower = tag:lower()
    local search = 1
    while true do
        local idx = lower:find(name, search, true)
        if not idx then return nil end
        local pos = idx + #name
        while lower:sub(pos, pos):find("^%s$") do pos = pos + 1 end
        if lower:sub(pos, pos) == "=" then
            pos = pos + 1
            while tag:sub(pos, pos):find("^%s$") do pos = pos + 1 end
            local quote = tag:sub(pos, pos)
            if quote == "" then return nil end
            if quote == '"' or quote == "'" then
                local close = tag:find(quote, pos + 1, true)
                if not close then return nil end
                return tag:sub(pos + 1, close - 1)
            end
            return tag:match("^[^%s>]*", pos)
        end
        search = idx + #name
    end
end

-- Parses `<img ... src="url" ...>` at the start of `s`; returns alt, url, consumed bytes.
local function parse_html_image(s)
    local tag_end = s:find(">", 1, true)
    if not tag_end then return nil end
    local tag = s:sub(1, tag_end - 1)
    local url = extract_attr(tag, "src")
    if not url then return nil end
    return extract_attr(tag, "alt") or "", url, tag_end
end

-- Converts one markdown-ish paragraph to XHTML, collecting referenced local image names.
local function paragraph_to_xhtml(paragraph, image_url_prefix, used_images, used_set)
    local out = {}
    local text = {}

    local function flush_text()
        local trimmed = trim(table.concat(text))
        text = {}
        if trimmed == "" then return end
        local lines = {}
        for line in (trimmed .. "\n"):gmatch("(.-)\r?\n") do
            lines[#lines + 1] = escape_text(line)
        end
        out[#out + 1] = "<p>" .. table.concat(lines, "<br/>") .. "</p>\n"
    end

    local rest = tostring(paragraph or "")
    while rest ~= "" do
        local md = rest:find("![", 1, true)
        local html = rest:find("<img", 1, true)
        local pos = md and html and math.min(md, html) or md or html
        if not pos then
            text[#text + 1] = rest
            break
        end

        text[#text + 1] = rest:sub(1, pos - 1)
        local tail = rest:sub(pos)
        local is_markdown = tail:sub(1, 2) == "!["

        local alt, url, consumed
        if is_markdown then
            alt, url, consumed = parse_markdown_image(tail)
        else
            alt, url, consumed = parse_html_image(tail)
        end

        if url then
            flush_text()
            local file = local_image_name(url, image_url_prefix)
            if file then
                if not used_set[file] then
                    used_set[file] = true
                    used_images[#used_images + 1] = file
                end
                out[#out + 1] = string.format('<figure><img src="images/%s" alt="%s"/></figure>\n',
                    escape_attr(file), escape_attr(alt))
            elseif trim(alt) ~= "" then
                -- External image: keep only its caption
                out[#out + 1] = "<p><em>" .. escape_text(trim(alt)) .. "</em></p>\n"
            end
            rest = tail:sub(consumed + 1)
        else
            -- Not an image after all: emit the marker literally
            local marker_len = is_markdown and 2 or 4
            text[#text + 1] = tail:sub(1, marker_len)
            rest = tail:sub(marker_len + 1)
        end
    end

    flush_text()
    return table.concat(out)
end

-- Renders a chapter to an XHTML document.
-- Returns the document and the list of illustration file names it references.
function M.render_chapter(lang, chapter, name, paragraphs, image_url_prefix)
    local used_images, used_set = {}, {}
    local body = {}
    if type(paragraphs) == "table" then
        for _, paragraph in ipairs(paragraphs) do
            if type(paragraph) == "string" then
                body[#body + 1] = paragraph_to_xhtml(paragraph, image_url_prefix, used_images, used_set)
            end
        end
    end
    local body_str = table.concat(body)
    if body_str == "" then
        body_str = "<p></p>\n"
    end

    name = tostring(name or "")
    local title = trim(name)
    if title == "" then
        title = chapter_label(lang, chapter, name)
    end
    local heading = escape_text(title)

    local doc = table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        "<!DOCTYPE html>\n",
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="',
        lang, '" lang="', lang, '">\n',
        "<head>\n",
        '  <meta charset="UTF-8"/>\n',
        "  <title>", heading, "</title>\n",
        '  <link rel="stylesheet" type="text/css" href="style.css"/>\n',
        "</head>\n",
        '<body epub:type="bodymatter">\n',
        '  <section epub:type="chapter">\n',
        "    <h2>", heading, "</h2>\n",
        body_str,
        "  </section>\n",
        "</body>\n",
        "</html>\n",
    })
    return doc, used_images
end

local STYLESHEET = [[
body { font-family: serif; line-height: 1.5; margin: 1em; }
h2 { text-align: center; margin: 1.5em 0 1em; }
p { margin: 0 0 0.9em; text-indent: 1.2em; }
figure { margin: 1em 0; text-align: center; }
figure img { max-width: 100%; height: auto; }
]]

local CONTAINER_XML = [[
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]]

-- ================= PACKAGE DOCUMENTS =================

local function build_nav(lang, title, chapters)
    -- Group by volume when there is more than one
    local volumes, order = {}, {}
    for _, chapter in ipairs(chapters) do
        local key = math.floor((tonumber(chapter.volume) or 0) * 1000)
        if not volumes[key] then
            volumes[key] = {}
            order[#order + 1] = key
        end
        table.insert(volumes[key], chapter)
    end
    table.sort(order)

    local items = {}
    local function chapter_item(indent, chapter)
        items[#items + 1] = string.format('%s<li><a href="%s">%s</a></li>\n', indent,
            M.chapter_file_name(chapter.id), escape_text(chapter_label(lang, chapter.chapter, chapter.name)))
    end

    if #order > 1 then
        for _, key in ipairs(order) do
            local entries = volumes[key]
            local first = entries[1]
            items[#items + 1] = string.format('      <li><a href="%s">%s %s</a>\n        <ol>\n',
                M.chapter_file_name(first.id), volume_word(lang), format_number(first.volume))
            for _, chapter in ipairs(entries) do
                chapter_item("          ", chapter)
            end
            items[#items + 1] = "        </ol>\n      </li>\n"
        end
    else
        for _, chapter in ipairs(chapters) do
            chapter_item("      ", chapter)
        end
    end

    local escaped_title = escape_text(title)
    return table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        "<!DOCTYPE html>\n",
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="',
        lang, '" lang="', lang, '">\n',
        "<head>\n",
        '  <meta charset="UTF-8"/>\n',
        "  <title>", escaped_title, "</title>\n",
        "</head>\n",
        "<body>\n",
        '  <nav epub:type="toc" id="toc">\n',
        "    <h1>", escaped_title, "</h1>\n",
        "    <ol>\n",
        table.concat(items),
        "    </ol>\n",
        "  </nav>\n",
        "</body>\n",
        "</html>\n",
    })
end
M.build_nav = build_nav

local function build_opf(meta, title, chapters, images, cover)
    local lang = meta.language
    local manifest = {
        '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\n',
        '    <item id="css" href="style.css" media-type="text/css"/>\n',
    }
    if cover then
        manifest[#manifest + 1] = string.format(
            '    <item id="cover-image" href="%s" media-type="%s" properties="cover-image"/>\n',
            escape_attr(cover.name), escape_attr(cover.mime))
    end
    local spine = {}
    for _, chapter in ipairs(chapters) do
        local item_id = "ch-" .. sanitize_id(chapter.id)
        manifest[#manifest + 1] = string.format(
            '    <item id="%s" href="%s" media-type="application/xhtml+xml"/>\n',
            item_id, M.chapter_file_name(chapter.id))
        -- Nothing but chapters in the spine: DocFragment[N] is the N-th chapter.
        spine[#spine + 1] = string.format('    <itemref idref="%s"/>\n', item_id)
    end
    for i, image in ipairs(images) do
        manifest[#manifest + 1] = string.format(
            '    <item id="img%d" href="images/%s" media-type="%s"/>\n',
            i, escape_attr(image.name), escape_attr(image.mime))
    end

    local description = type(meta.description) == "string" and trim(meta.description) or ""
    local description_xml = description ~= ""
        and ("    <dc:description>" .. escape_text(description) .. "</dc:description>\n") or ""
    local cover_meta = cover and '    <meta name="cover" content="cover-image"/>\n' or ""

    -- A volume copy is one book of a series named after the whole book
    local identifier = "urn:uuid:" .. tostring(meta.book_id)
    local series_meta = ""
    local volume = tonumber(meta.volume)
    if volume then
        local number = format_number(volume)
        local series = trim(tostring(meta.title or ""))
        if series == "" then series = "Untitled" end
        identifier = "urn:folio:" .. tostring(meta.book_id) .. ":volume:" .. number
        series_meta = table.concat({
            '    <meta name="calibre:series" content="', escape_attr(series), '"/>\n',
            '    <meta name="calibre:series_index" content="', number, '"/>\n',
            '    <meta property="belongs-to-collection" id="series">', escape_text(series), "</meta>\n",
            '    <meta refines="#series" property="collection-type">series</meta>\n',
            '    <meta refines="#series" property="group-position">', number, "</meta>\n",
        })
    end

    return table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="',
        lang, '">\n',
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n',
        '    <dc:identifier id="pub-id">', escape_text(identifier), "</dc:identifier>\n",
        "    <dc:title>", escape_text(title), "</dc:title>\n",
        '    <dc:creator id="creator">', escape_text(trim(tostring(meta.author or ""))), "</dc:creator>\n",
        "    <dc:language>", lang, "</dc:language>\n",
        description_xml,
        '    <meta property="dcterms:modified">', os.date("!%Y-%m-%dT%H:%M:%SZ"), "</meta>\n",
        cover_meta,
        series_meta,
        "  </metadata>\n",
        "  <manifest>\n",
        table.concat(manifest),
        "  </manifest>\n",
        "  <spine>\n",
        table.concat(spine),
        "  </spine>\n",
        "</package>\n",
    })
end
M.build_opf = build_opf

-- ================= EPUB WRITER =================

-- Opens a zip archive for writing with whatever KOReader provides.
-- Returns a sink `{ add(self, name, content, store), close(self) }` or nil, error.
function M.open_sink(path)
    local ok_arc, Archiver = pcall(require, "ffi/archiver")
    if ok_arc and type(Archiver) == "table" and Archiver.Writer then
        local writer = Archiver.Writer:new {}
        if not writer:open(path, "epub") then
            return nil, "Cannot create file " .. tostring(path)
        end
        local mtime = os.time()
        return {
            add = function(_, name, content, store)
                if not writer:setZipCompression(store and "store" or "deflate") then
                    return false
                end
                return writer:addFileFromMemory(name, content, mtime) and true or false
            end,
            close = function()
                -- false only when the archive library says the file is not complete
                return writer:close() ~= false
            end,
        }
    end

    -- KOReader before 2025.04
    local ok_zip, ZipWriter = pcall(require, "ffi/zipwriter")
    if ok_zip and type(ZipWriter) == "table" then
        local writer = ZipWriter:new {}
        if not writer:open(path) then
            return nil, "Cannot create file " .. tostring(path)
        end
        return {
            add = function(_, name, content, store)
                writer:add(name, content, store and true or nil)
                return true
            end,
            close = function()
                return writer:close() ~= false
            end,
        }
    end

    return nil, "This KOReader version cannot create EPUB files"
end

--[[--
Incremental EPUB writer: chapter documents and illustrations are appended as they arrive
(downloaded or copied from the previous file); the navigation document, the package
document and the chapter manifest are written by `finish`.
]]
local EpubWriter = {}
EpubWriter.__index = EpubWriter

function M.new_writer(sink)
    local writer = setmetatable({
        sink = sink,
        chapters = {},
        images = {}, -- { name, mime } in the order they were added
        image_set = {},
        cover = nil, -- { name, mime }
    }, EpubWriter)
    -- The `mimetype` entry must come first and must not be compressed.
    if not writer:_add("mimetype", "application/epub+zip", true)
        or not writer:_add("META-INF/container.xml", CONTAINER_XML, false) then
        sink:close()
        return nil, "Failed to write EPUB"
    end
    return writer
end

function EpubWriter:_add(name, content, store)
    local ok, res = pcall(self.sink.add, self.sink, name, content, store)
    return ok and res and true or false
end

function EpubWriter:has_chapter(chapter_id)
    return self.chapters[chapter_id] == true
end

-- Adds a chapter document (freshly rendered or taken from the previous build).
function EpubWriter:add_chapter(chapter_id, xhtml)
    if self.chapters[chapter_id] then return true end
    if not self:_add(M.chapter_entry_name(chapter_id), xhtml, false) then
        return false, "Failed to write EPUB"
    end
    self.chapters[chapter_id] = true
    return true
end

function EpubWriter:has_image(filename)
    return self.image_set[filename] == true
end

-- Adds an illustration.
function EpubWriter:add_image(filename, bytes)
    if self.image_set[filename] then return true end
    if not is_safe_image_name(filename) then
        return false, "Unsupported illustration file name '" .. tostring(filename) .. "'"
    end
    if not self:_add(M.image_entry_name(filename), bytes, true) then
        return false, "Failed to write EPUB"
    end
    self.image_set[filename] = true
    self.images[#self.images + 1] = { name = filename, mime = M.image_media_type(filename, bytes) }
    return true
end

-- Stores the cover image; the extension and the media type are detected from the bytes.
function EpubWriter:set_cover(bytes)
    if self.cover then return true end
    local extension, mime = M.sniff_image(bytes)
    if not extension then
        extension, mime = "jpg", "image/jpeg"
    end
    local filename = "cover." .. extension
    if not self:_add(M.content_entry_name(filename), bytes, true) then
        return false, "Failed to write EPUB"
    end
    self.cover = { name = filename, mime = mime }
    return true
end

-- Closes the archive without finishing the book (the file is not a valid EPUB).
function EpubWriter:abort()
    pcall(self.sink.close, self.sink)
end

-- Writes the navigation document, the package document and the chapter manifest, then
-- closes the archive. `chapters` defines the reading order; every chapter must have been
-- added with `add_chapter`. Returns the manifest, or nil and an error.
function EpubWriter:finish(meta, chapters)
    local function fail(err)
        self:abort()
        return nil, err
    end

    if type(chapters) ~= "table" or #chapters == 0 then
        return fail("Book has no chapters")
    end
    for _, chapter in ipairs(chapters) do
        if not self.chapters[chapter.id] then
            return fail("Chapter " .. tostring(chapter.id) .. " was not written to the EPUB")
        end
    end

    local lang = meta.language
    local title = trim(tostring(meta.title or ""))
    if title == "" then title = "Untitled" end
    local volume = tonumber(meta.volume)
    if volume then
        title = M.volume_title(lang, title, volume)
    end

    local manifest = {
        version = M.MANIFEST_VERSION,
        bookId = meta.book_id,
        language = lang,
        cover = self.cover and self.cover.name or nil,
        -- Only in a copy that holds a single volume: where it sits in the book
        volume = volume,
        chaptersBefore = volume and (tonumber(meta.chapters_before) or 0) or nil,
        bookChapters = volume and (tonumber(meta.book_chapters) or #chapters) or nil,
        chapters = {},
    }
    for i, chapter in ipairs(chapters) do
        manifest.chapters[i] = {
            id = chapter.id,
            updated = as_string(chapter.updated),
            volume = tonumber(chapter.volume) or 0,
            chapter = tonumber(chapter.chapter) or 0,
            name = tostring(chapter.name or ""),
            -- An empty list is left out: JSON encoders disagree on `{}` vs `[]`
            images = (type(chapter.images) == "table" and #chapter.images > 0) and chapter.images or nil,
        }
    end
    local ok_json, manifest_json = pcall(require("json").encode, manifest)
    if not ok_json or type(manifest_json) ~= "string" then
        return fail("Failed to write EPUB")
    end

    if not self:_add(M.content_entry_name("nav.xhtml"), build_nav(lang, title, chapters), false)
        or not self:_add(M.content_entry_name("style.css"), STYLESHEET, false)
        or not self:_add(M.content_entry_name("content.opf"),
            build_opf(meta, title, chapters, self.images, self.cover), false)
        or not self:_add(M.MANIFEST_PATH, manifest_json, false) then
        return fail("Failed to write EPUB")
    end

    -- The end of the archive (its directory) is written here: a failure leaves a file
    -- that cannot be opened, and it must not take the place of the previous build
    local ok_close, closed = pcall(self.sink.close, self.sink)
    if not ok_close or closed == false then
        return nil, "Failed to write EPUB"
    end
    return manifest
end

-- ================= READING A PREVIOUS BUILD =================

-- Brings a decoded manifest to the shape used by this module; nil when it is not one.
local function normalize_manifest(data)
    if type(data) ~= "table" then return nil end
    local book_id = as_string(data.bookId) or as_string(data.book_id)
    if not book_id or type(data.chapters) ~= "table" then return nil end

    local manifest = {
        version = tonumber(data.version) or 0,
        book_id = book_id,
        language = as_string(data.language) or "",
        cover = as_string(data.cover),
        chapters = {},
    }
    -- A copy of a single volume (absent in a whole-book copy)
    local volume = tonumber(data.volume)
    if volume then
        manifest.volume = volume
        manifest.chapters_before = math.max(0, math.floor(tonumber(data.chaptersBefore) or 0))
        manifest.book_chapters = math.max(0, math.floor(tonumber(data.bookChapters) or 0))
    end
    for _, chapter in ipairs(data.chapters) do
        if type(chapter) == "table" and as_string(chapter.id) then
            local images = {}
            if type(chapter.images) == "table" then
                for _, name in ipairs(chapter.images) do
                    if type(name) == "string" then images[#images + 1] = name end
                end
            end
            manifest.chapters[#manifest.chapters + 1] = {
                id = chapter.id,
                updated = as_string(chapter.updated),
                volume = tonumber(chapter.volume) or 0,
                chapter = tonumber(chapter.chapter) or 0,
                name = as_string(chapter.name) or "",
                images = images,
            }
        end
    end
    return manifest
end
M.normalize_manifest = normalize_manifest

--[[--
What a previously built EPUB can contribute to an update.

`reader` is `{ entries = set of entry names, extract(self, name) -> content|nil, close(self) }`.
]]
local ExistingEpub = {}
ExistingEpub.__index = ExistingEpub

function M.new_existing(manifest, reader)
    local by_id = {}
    for _, chapter in ipairs(manifest.chapters) do
        by_id[chapter.id] = chapter
    end
    return setmetatable({ manifest = manifest, reader = reader, by_id = by_id }, ExistingEpub)
end

-- The stored document of a chapter can be reused when nothing it was rendered from has
-- changed on the server.
function ExistingEpub:reusable_chapter(language, summary)
    if self.manifest.version ~= M.MANIFEST_VERSION or self.manifest.language ~= language then
        return nil
    end
    local stored = self.by_id[summary.id]
    if not stored then return nil end
    local same = stored.updated == as_string(summary.updated)
        and stored.volume == (tonumber(summary.volume) or 0)
        and stored.chapter == (tonumber(summary.chapter) or 0)
        and stored.name == (as_string(summary.name) or "")
    if same and self.reader.entries[M.chapter_entry_name(summary.id)] then
        return stored
    end
    return nil
end

function ExistingEpub:has_image(filename)
    return self.reader.entries[M.image_entry_name(filename)] == true
end

-- Cover file name, when the previous build embedded one.
function ExistingEpub:cover()
    local cover = self.manifest.cover
    if cover and cover:match("^cover%.[A-Za-z0-9]+$") and self.reader.entries[M.content_entry_name(cover)] then
        return cover
    end
    return nil
end

function ExistingEpub:read_chapter(chapter_id)
    return self.reader:extract(M.chapter_entry_name(chapter_id))
end

function ExistingEpub:read_image(filename)
    return self.reader:extract(M.image_entry_name(filename))
end

function ExistingEpub:read_cover()
    local cover = self:cover()
    return cover and self.reader:extract(M.content_entry_name(cover)) or nil
end

function ExistingEpub:close()
    pcall(self.reader.close, self.reader)
end

-- Opens an archive for reading; nil when KOReader has no archive reader (before 2025.04)
-- or the file cannot be read.
local function open_reader(path)
    local ok_arc, Archiver = pcall(require, "ffi/archiver")
    if not ok_arc or type(Archiver) ~= "table" or not Archiver.Reader then
        return nil
    end
    local ok, reader = pcall(function()
        local arc = Archiver.Reader:new()
        if not arc:open(path) then return nil end
        local entries = {}
        for entry in arc:iterate() do
            if entry.mode == "file" then
                entries[entry.path] = true
            end
        end
        return {
            entries = entries,
            extract = function(_, name)
                if not entries[name] then return nil end
                local ok_x, content = pcall(arc.extractToMemory, arc, name)
                return ok_x and content or nil
            end,
            close = function()
                arc:close()
            end,
        }
    end)
    return ok and reader or nil
end

-- Whether this KOReader can read archives back (2025.04 and later): only then can a
-- previous build be reused and a new one be checked.
function M.can_read_archives()
    local ok_arc, Archiver = pcall(require, "ffi/archiver")
    return ok_arc and type(Archiver) == "table" and Archiver.Reader ~= nil
end

-- Reads an EPUB built by this module (or by FolioReader).
-- Returns nil for any other EPUB, an unreadable file, or when it cannot be checked.
-- The caller must `close()` the returned object.
function M.read_existing(path, opener)
    local ok_open, reader = pcall(opener or open_reader, path)
    if not ok_open or type(reader) ~= "table" then return nil end
    local manifest
    if reader.entries[M.MANIFEST_PATH] then
        local raw = reader:extract(M.MANIFEST_PATH)
        if type(raw) == "string" then
            local ok, data = pcall(require("json").decode, raw)
            manifest = ok and normalize_manifest(data) or nil
        end
    end
    if not manifest then
        pcall(reader.close, reader)
        return nil
    end
    return M.new_existing(manifest, reader)
end

-- ================= XPOINTER HELPERS =================

-- Spine index (0-based) addressed by a KOReader XPointer: `/body/DocFragment[N]/...`.
function M.xpointer_spine_index(xpointer)
    if type(xpointer) ~= "string" then return nil end
    local n = xpointer:match("^/body/DocFragment%[(%d+)%]")
    if n then
        n = tonumber(n)
        return n >= 1 and (n - 1) or nil
    end
    -- crengine leaves the index out when the book has a single fragment
    if xpointer == "/body/DocFragment" or xpointer:match("^/body/DocFragment[/%.]") then
        return 0
    end
    return nil
end

-- XPointer of the beginning of the spine item at `position` (0-based).
function M.chapter_start_xpointer(position)
    return string.format("/body/DocFragment[%d]/body", position + 1)
end

-- Rewrites the fragment of an XPointer when its chapter moved to another position
-- (`moved` maps old spine indexes to new ones). Returns nil when nothing changes.
function M.remap_xpointer_spine(xpointer, moved)
    local old = M.xpointer_spine_index(xpointer)
    if not old then return nil end
    local new = moved[old]
    if not new or new == old then return nil end
    local rest = xpointer:match("^/body/DocFragment%[%d+%](.*)$") or xpointer:match("^/body/DocFragment(.*)$")
    return string.format("/body/DocFragment[%d]%s", new + 1, rest or "")
end

-- The same position `delta` spine items further (or earlier, when negative). Returns nil
-- when the XPointer names no spine item or the result would fall before the first one.
function M.shift_xpointer_spine(xpointer, delta)
    local old = M.xpointer_spine_index(xpointer)
    if not old then return nil end
    local new = old + delta
    if new < 0 then return nil end
    if delta == 0 then return xpointer end
    local rest = xpointer:match("^/body/DocFragment%[%d+%](.*)$") or xpointer:match("^/body/DocFragment(.*)$")
    return string.format("/body/DocFragment[%d]%s", new + 1, rest or "")
end

return M
