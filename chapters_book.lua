--[[--
Downloads a Folio `Chapters` book — a book without a file, stored on the server as
separate chapters — and assembles it into a local EPUB, so it can be read (offline
included) like any other book.

Building again for a book that is already on the device updates it: only new and changed
chapters are downloaded, everything else is copied from the previous build.

The server keeps the reading position of such books as `ch:<chapterId>`; this module also
translates between that form and the XPointers of the local EPUB.
]]

local ChaptersEpub = require("chapters_epub")
local logger = require("logger")

local M = {}

-- Errors callers match on (anything else is a plain message)
M.ERR_NO_CHAPTERS = "BOOK_HAS_NO_CHAPTERS"
M.ERR_CANCELLED = "CANCELLED"
-- The server does not let an API key read chapters (Folio older than this feature)
M.ERR_FORBIDDEN = "CHAPTERS_FORBIDDEN"
-- Another book already uses the file name
M.ERR_NAME_TAKEN = "FILE_NAME_TAKEN"

-- Page size of the chapter list (the server clamps it to 500).
local CHAPTERS_PAGE_SIZE = 500
-- Attempts per request (network errors, 5xx and 429 are retried).
local MAX_ATTEMPTS = 3

local function as_string(v)
    return type(v) == "string" and v or nil
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

-- Runs `request` (returning ok, result, http_code) until it succeeds or fails for good.
local function with_retry(request)
    local ok, res, code
    for attempt = 1, MAX_ATTEMPTS do
        ok, res, code = request()
        if ok then
            return true, res
        end
        local retryable = code == nil or code >= 500 or code == 429
        if not retryable or attempt == MAX_ATTEMPTS then
            break
        end
        pcall(function()
            require("ffi/util").usleep(300000 * attempt)
        end)
    end
    return false, res, code
end

-- ================= CHAPTER LAYOUT =================
-- Which chapter each spine item of a built EPUB holds. Kept next to the plugin's sync
-- state in `<book>.sdr/folio_chapters.json`; the EPUB itself carries the same list in its
-- manifest, which is used when the sidecar copy is gone. The sidecar copy remembers the
-- size of the file it describes: once another file takes that place it is void.

local function sidecar_dir(file_path)
    local base = type(file_path) == "string" and file_path:match("^(.*)%.%w+$")
    return base and (base .. ".sdr") or nil
end

function M.layout_path(file_path)
    local dir = sidecar_dir(file_path)
    return dir and (dir .. "/folio_chapters.json") or nil
end

local function make_layout(book_id, chapter_ids)
    local positions = {}
    for index, id in ipairs(chapter_ids) do
        positions[id] = index - 1
    end
    return { book_id = book_id, chapter_ids = chapter_ids, positions = positions }
end
M.make_layout = make_layout

function M.save_layout(file_path, book_id, chapter_ids)
    local path = M.layout_path(file_path)
    if not path then return false end
    local ok, encoded = pcall(require("json").encode, {
        book_id = book_id,
        chapter_ids = chapter_ids,
        size = file_size(file_path),
    })
    if not ok or type(encoded) ~= "string" then return false end

    pcall(function()
        local lfs_mod = package.loaded["lfs"] or package.loaded["libs/libkoreader-lfs"]
        if lfs_mod and lfs_mod.mkdir then lfs_mod.mkdir(sidecar_dir(file_path)) end
    end)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(encoded)
    f:close()
    return true
end

-- Chapter layout of a locally built Chapters book; nil for any other file.
-- `read_existing` is injectable for tests.
function M.load_layout(file_path, read_existing)
    local path = M.layout_path(file_path)
    if not path then return nil end

    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(require("json").decode, content or "")
        local valid = ok and type(data) == "table" and as_string(data.book_id) and type(data.chapter_ids) == "table"
        if valid and (data.size == nil or data.size == file_size(file_path)) then
            local ids = {}
            for _, id in ipairs(data.chapter_ids) do
                if type(id) == "string" then ids[#ids + 1] = id end
            end
            return make_layout(data.book_id, ids)
        end
        -- Describes a file that is no longer there (replaced or removed)
        os.remove(path)
    end

    -- No sidecar copy: ask the EPUB itself
    if not file_path:lower():match("%.epub$") or not file_exists(file_path) then
        return nil
    end
    local existing = (read_existing or ChaptersEpub.read_existing)(file_path)
    if not existing then return nil end
    local ids = {}
    for _, chapter in ipairs(existing.manifest.chapters) do
        ids[#ids + 1] = chapter.id
    end
    local book_id = existing.manifest.book_id
    existing:close()
    M.save_layout(file_path, book_id, ids)
    return make_layout(book_id, ids)
end

-- ================= READING POSITION =================

-- Location to send to the server for a local reading position (`ch:<chapterId>`).
-- nil when it cannot be expressed for the server: then only the percentage is pushed.
function M.outgoing_location(layout, xpointer)
    local position = ChaptersEpub.xpointer_spine_index(xpointer)
    local chapter_id = position and layout.chapter_ids[position + 1]
    return chapter_id and ("ch:" .. chapter_id) or nil
end

--[[--
Translates a server reading position for the local copy of the book. Returns:
- "at", xpointer — a position the local copy can open;
- "same" — the chapter the reader is already in: the local position is more precise;
- "unknown" — a chapter this copy does not have (yet);
- "other" — not a chapter reference (the server's placeholder for "no position yet", or a
  position of another edition): nothing to open.
]]
function M.incoming_location(layout, remote, local_xpointer)
    local chapter_id = type(remote) == "string" and remote:match("^ch:(.+)$")
    if not chapter_id then
        return "other"
    end
    local position = layout.positions[chapter_id]
    if not position then
        return "unknown"
    end
    if ChaptersEpub.xpointer_spine_index(local_xpointer) == position then
        return "same"
    end
    return "at", ChaptersEpub.chapter_start_xpointer(position)
end

--[[--
Whether the server position is further in the book than the local one. Percentages cannot
tell: every client counts them its own way (the web reader by chapters, KOReader by pages).

Returns nil when the positions cannot be compared by chapter (the caller then falls back
to percentages): the server position is not a chapter reference, the local position is
unknown, or the chapter is not in this copy — it may be a newer one, or one that was
deleted on the server, and the latter must not block pushes for good.
]]
function M.remote_is_ahead(layout, remote, local_xpointer)
    local chapter_id = type(remote) == "string" and remote:match("^ch:(.+)$")
    if not chapter_id then
        return nil
    end
    local local_position = ChaptersEpub.xpointer_spine_index(local_xpointer)
    if not local_position then
        return nil
    end
    local remote_position = layout.positions[chapter_id]
    if not remote_position then
        return nil
    end
    return remote_position > local_position
end

-- Old spine index -> new spine index for chapters that changed their place.
local function moved_chapters(previous_ids, chapter_ids)
    local moved, has_moved = {}, false
    if type(previous_ids) ~= "table" then
        return moved, has_moved
    end
    local new_positions = {}
    for index, id in ipairs(chapter_ids) do
        new_positions[id] = index - 1
    end
    for index, id in ipairs(previous_ids) do
        local new = new_positions[id]
        if new and new ~= index - 1 then
            moved[index - 1] = new
            has_moved = true
        end
    end
    return moved, has_moved
end
M.moved_chapters = moved_chapters

-- Chapters that changed their place take the stored positions with them: rewrites the
-- last position and the annotations of a DocSettings object. Returns true when changed.
function M.remap_docsettings(docsettings, moved)
    if not (docsettings and docsettings.readSetting and docsettings.saveSetting) then
        return false
    end
    local changed = false

    local last = docsettings:readSetting("last_xpointer")
    local new_last = ChaptersEpub.remap_xpointer_spine(last, moved)
    if new_last then
        docsettings:saveSetting("last_xpointer", new_last)
        changed = true
    end

    local annotations = docsettings:readSetting("annotations")
    if type(annotations) == "table" then
        local annotations_changed = false
        for _, item in ipairs(annotations) do
            if type(item) == "table" then
                for _, field in ipairs({ "page", "pos0", "pos1" }) do
                    local new = ChaptersEpub.remap_xpointer_spine(item[field], moved)
                    if new then
                        item[field] = new
                        annotations_changed = true
                    end
                end
            end
        end
        if annotations_changed then
            docsettings:saveSetting("annotations", annotations)
            changed = true
        end
    end
    return changed
end

-- Same for the plugin's sync snapshot (`folio_sync_state.json`). Returns true when changed.
function M.remap_sync_state(state, moved)
    if type(state) ~= "table" then return false end
    local changed = false
    for _, section in ipairs({ "annotations", "bookmarks" }) do
        local items = state[section]
        if type(items) == "table" then
            local remapped = {}
            for key, item in pairs(items) do
                local new_key = key
                if type(item) == "table" then
                    local old_pos0 = item.pos0
                    for _, field in ipairs({ "pos0", "pos1" }) do
                        local new = ChaptersEpub.remap_xpointer_spine(item[field], moved)
                        if new then
                            item[field] = new
                            changed = true
                        end
                    end
                    -- Items without a server id are keyed by their position
                    if key == old_pos0 then
                        new_key = item.pos0
                    end
                end
                remapped[new_key] = item
            end
            state[section] = remapped
        end
    end
    return changed
end

-- ================= DOWNLOAD =================

-- The whole chapter list of a book, in reading order.
-- Returns the list, or nil, message, http_code.
function M.fetch_chapter_list(api, book_id)
    local list, seen = {}, {}
    local offset = 0
    while true do
        local ok, page, code = with_retry(function()
            return api:list_chapters(book_id, offset, CHAPTERS_PAGE_SIZE)
        end)
        if not ok then
            return nil, page, code
        end
        local items = type(page.items) == "table" and page.items or {}
        if #items == 0 then
            break
        end
        offset = offset + #items
        for _, item in ipairs(items) do
            -- The list may shift between pages while chapters are being added.
            if type(item) == "table" and as_string(item.id) and not seen[item.id] then
                seen[item.id] = true
                list[#list + 1] = {
                    id = item.id,
                    volume = tonumber(item.volume) or 0,
                    chapter = tonumber(item.chapter) or 0,
                    name = as_string(item.name) or "",
                    updated = as_string(item.updated),
                }
            end
        end
        if page.more ~= true then
            break
        end
    end
    return list
end

--[[--
Picks the file to write for a book in `dir`: `<stem>.epub`, or `<stem> (<id>).epub` when
another book already uses the plain name. A file that belongs to another book is never
overwritten.

Returns path, layout of the copy already there (nil for a new file) — or nil, ERR_NAME_TAKEN.
]]
function M.resolve_target(dir, stem, book_id, load_layout)
    load_layout = load_layout or M.load_layout
    local candidates = {
        string.format("%s/%s.epub", dir, stem),
        string.format("%s/%s (%s).epub", dir, stem, tostring(book_id):sub(1, 8)),
    }
    -- A copy of this book that is already there, under either name
    local taken = {}
    for index, path in ipairs(candidates) do
        if file_exists(path) then
            taken[index] = true
            local layout = load_layout(path)
            if layout and layout.book_id == book_id then
                return path, layout
            end
        end
    end
    for index, path in ipairs(candidates) do
        if not taken[index] then
            return path, nil
        end
    end
    return nil, M.ERR_NAME_TAKEN
end

--[[--
Downloads everything the previous build cannot provide and writes the EPUB to a temporary
file next to `opts.target_path`; `commit` then puts it in place.

opts:
- book_id, target_path (required)
- title, author: what the catalog knows (book details from the server take precedence)
- previous_chapter_ids: chapter order of the copy being replaced, when known
- on_progress(phase, done, total): phase is "chapters", "images" or "building";
  returning false cancels the download
- open_sink, read_existing: injectable for tests

Returns a result table, or nil and an error (one of the ERR_* constants or a message).
]]
function M.build(api, opts)
    local book_id = opts.book_id
    local target_path = opts.target_path
    local progress = opts.on_progress or function() return true end
    local open_sink = opts.open_sink or ChaptersEpub.open_sink
    local read_existing = opts.read_existing or ChaptersEpub.read_existing

    -- The id ends up in request paths and in the EPUB itself.
    if type(book_id) ~= "string" or not book_id:match("^[%x%-]+$") then
        return nil, "'" .. tostring(book_id) .. "' is not a Folio book id"
    end
    if type(target_path) ~= "string" or target_path == "" then
        return nil, "No target file"
    end

    local list, list_err, list_code = M.fetch_chapter_list(api, book_id)
    if not list then
        if list_code == 403 then
            return nil, M.ERR_FORBIDDEN
        end
        return nil, "Failed to load the chapter list: " .. tostring(list_err)
    end
    if #list == 0 then
        return nil, M.ERR_NO_CHAPTERS
    end

    -- Title, author, language and description. Required: a build with guessed metadata
    -- (above all another language) could reuse nothing from the previous one.
    local ok_details, details = with_retry(function()
        return api:get_book(book_id)
    end)
    if not ok_details or type(details) ~= "table" then
        return nil, "Failed to load the book details: " .. tostring(details)
    end
    local function pick(...)
        for i = 1, select("#", ...) do
            local value = select(i, ...)
            if type(value) == "string" and ChaptersEpub.trim(value) ~= "" then
                return value
            end
        end
        return nil
    end
    local meta = {
        book_id = book_id,
        title = pick(details.title, details.name, opts.title) or "Untitled",
        author = pick(details.author, opts.author) or "Unknown Author",
        language = ChaptersEpub.normalize_language(details.language),
        description = as_string(details.description),
    }

    local updated = file_exists(target_path)
    local existing = updated and read_existing(target_path) or nil
    if existing and existing.manifest.book_id ~= book_id then
        existing:close()
        return nil, M.ERR_NAME_TAKEN
    end
    local previous_ids = opts.previous_chapter_ids
    if existing then
        previous_ids = {}
        for _, chapter in ipairs(existing.manifest.chapters) do
            previous_ids[#previous_ids + 1] = chapter.id
        end
    end

    -- Nothing changed on the server since the previous build: the file stays as it is
    -- (a rewritten file would be rendered from scratch by the reader).
    if existing then
        local stored_chapters = existing.manifest.chapters
        local unchanged = #stored_chapters == #list
        for index, summary in ipairs(list) do
            if not unchanged then break end
            local stored = stored_chapters[index].id == summary.id
                and existing:reusable_chapter(meta.language, summary)
            if not stored then
                unchanged = false
            else
                for _, name in ipairs(stored.images) do
                    if not existing:has_image(name) then
                        unchanged = false
                    end
                end
            end
        end
        if unchanged then
            existing:close()
            return {
                book_id = book_id,
                title = meta.title,
                target_path = target_path,
                chapter_ids = previous_ids,
                moved = {},
                has_moved = false,
                updated = true,
                unchanged = true,
                chapters_total = #list,
                chapters_fetched = 0,
                images_fetched = 0,
                images_missing = 0,
            }
        end
    end

    -- Written next to the target so that the final rename stays on one filesystem; the
    -- book may be open in the reader right now and must stay intact until then.
    local tmp_path = target_path .. ".tmp"
    local sink, sink_err = open_sink(tmp_path)
    if not sink then
        if existing then existing:close() end
        return nil, sink_err or "Cannot create the book file"
    end
    local writer, writer_err = ChaptersEpub.new_writer(sink)
    if not writer then
        if existing then existing:close() end
        os.remove(tmp_path)
        return nil, writer_err
    end

    local function fail(err)
        writer:abort()
        if existing then existing:close() end
        os.remove(tmp_path)
        return nil, err
    end

    local language = meta.language
    local image_url_prefix = "/api/books/" .. book_id .. "/images/"
    local total = #list

    -- ---- Chapters: reuse what did not change, download the rest ----
    local chapters = {}
    local chapters_fetched = 0
    if progress("chapters", 0, total) == false then
        return fail(M.ERR_CANCELLED)
    end
    for index, summary in ipairs(list) do
        local xhtml
        local stored = existing and existing:reusable_chapter(language, summary)
        if stored then
            xhtml = existing:read_chapter(summary.id)
        end
        if xhtml then
            chapters[index] = {
                id = summary.id,
                updated = stored.updated,
                volume = stored.volume,
                chapter = stored.chapter,
                name = stored.name,
                images = stored.images,
            }
        else
            local ok, chapter, code = with_retry(function()
                return api:get_chapter(book_id, summary.id)
            end)
            if not ok then
                if code == 403 then
                    return fail(M.ERR_FORBIDDEN)
                end
                return fail("Failed to download chapter " .. tostring(index) .. ": " .. tostring(chapter))
            end
            local number = tonumber(chapter.chapter) or summary.chapter
            local name = as_string(chapter.name) or summary.name
            local images
            xhtml, images = ChaptersEpub.render_chapter(language, number, name, chapter.content, image_url_prefix)
            chapters[index] = {
                id = summary.id,
                updated = as_string(chapter.updated),
                volume = tonumber(chapter.volume) or summary.volume,
                chapter = number,
                name = name,
                images = images,
            }
            chapters_fetched = chapters_fetched + 1
        end

        local ok_add, add_err = writer:add_chapter(summary.id, xhtml)
        if not ok_add then
            return fail(add_err)
        end
        if progress("chapters", index, total) == false then
            return fail(M.ERR_CANCELLED)
        end
    end

    -- ---- Illustrations: copy the ones already embedded, download the missing ones ----
    local seen, to_fetch = {}, {}
    for _, chapter in ipairs(chapters) do
        for _, name in ipairs(chapter.images or {}) do
            if not seen[name] then
                seen[name] = true
                local bytes = existing and existing:has_image(name) and existing:read_image(name)
                if bytes then
                    local ok_add, add_err = writer:add_image(name, bytes)
                    if not ok_add then
                        return fail(add_err)
                    end
                else
                    to_fetch[#to_fetch + 1] = name
                end
            end
        end
    end

    local images_fetched, images_missing = 0, 0
    if #to_fetch > 0 and progress("images", 0, #to_fetch) == false then
        return fail(M.ERR_CANCELLED)
    end
    for index, name in ipairs(to_fetch) do
        local ok, bytes, code = with_retry(function()
            return api:get_book_image(book_id, name)
        end)
        if ok and bytes ~= "" then
            local ok_add, add_err = writer:add_image(name, bytes)
            if not ok_add then
                return fail(add_err)
            end
            images_fetched = images_fetched + 1
        elseif not ok and code == nil then
            return fail("Failed to download illustration " .. name .. ": " .. tostring(bytes))
        else
            -- The server no longer has the file: the chapter keeps the alt text.
            images_missing = images_missing + 1
        end
        if progress("images", index, #to_fetch) == false then
            return fail(M.ERR_CANCELLED)
        end
    end

    -- ---- Cover ----
    -- Optional: a failed request must not fail the whole book.
    local ok_cover, cover = api:get_book_cover(book_id)
    if not (ok_cover and type(cover) == "string" and cover ~= "") then
        cover = existing and existing:read_cover() or nil
    end
    if cover then
        local ok_add, add_err = writer:set_cover(cover)
        if not ok_add then
            return fail(add_err)
        end
    end

    if progress("building", total, total) == false then
        return fail(M.ERR_CANCELLED)
    end
    local manifest, finish_err = writer:finish(meta, chapters)
    if existing then existing:close() end
    if not manifest then
        os.remove(tmp_path)
        return nil, finish_err
    end

    local chapter_ids = {}
    for index, chapter in ipairs(chapters) do
        chapter_ids[index] = chapter.id
    end
    local moved, has_moved = moved_chapters(previous_ids, chapter_ids)

    logger.info(string.format("FolioSync: built '%s' (%d chapters, %d downloaded, %d illustrations, %d missing)",
        target_path, total, chapters_fetched, images_fetched, images_missing))

    return {
        book_id = book_id,
        title = meta.title,
        target_path = target_path,
        tmp_path = tmp_path,
        chapter_ids = chapter_ids,
        -- Old spine index -> new spine index of the chapters that changed their place
        moved = moved,
        has_moved = has_moved,
        -- true when an existing local copy is being replaced
        updated = updated,
        -- true when the existing copy needs no change (nothing was written)
        unchanged = false,
        chapters_total = total,
        chapters_fetched = chapters_fetched,
        images_fetched = images_fetched,
        images_missing = images_missing,
    }
end

-- Puts a built EPUB in place of the target file and records its chapter layout.
function M.commit(result)
    if result.unchanged then
        M.save_layout(result.target_path, result.book_id, result.chapter_ids)
        return true
    end

    local ok, err = os.rename(result.tmp_path, result.target_path)
    if not ok and file_exists(result.target_path) then
        -- Some filesystems refuse to rename over an existing file: move the old copy
        -- aside, and put it back if the new one still cannot take its place
        local backup = result.target_path .. ".old"
        os.remove(backup)
        if os.rename(result.target_path, backup) then
            ok, err = os.rename(result.tmp_path, result.target_path)
            if ok then
                os.remove(backup)
            else
                os.rename(backup, result.target_path)
            end
        end
    end
    if not ok then
        os.remove(result.tmp_path)
        return false, "Failed to save the book file: " .. tostring(err)
    end
    M.save_layout(result.target_path, result.book_id, result.chapter_ids)
    return true
end

-- Drops a built EPUB that will not be used.
function M.discard(result)
    if result and result.tmp_path then
        os.remove(result.tmp_path)
    end
end

return M
