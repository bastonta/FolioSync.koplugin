--[[--
Downloads a Folio `Chapters` book — a book without a file, stored on the server as
separate chapters — and assembles it into a local EPUB, so it can be read (offline
included) like any other book.

Building again for a book that is already on the device updates it: only new and changed
chapters are downloaded, everything else is copied from the previous build.

The server keeps the reading position of such books as `ch:<chapterId>`; this module also
translates between that form and the XPointers of the local EPUB.

A book can also be downloaded volume by volume: every volume is a file of its own
(`<name> - Vol 03.epub`) that is updated independently. Such a copy knows where it sits in
the book (`chapters_before`, `book_chapters`), which is what percentages, bookmarks and
annotations are translated with: the server counts all of them in the whole book.
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
-- Illustrations missing from a copy that are asked for one by one before an update is
-- declared unnecessary; with more than that the copy is rebuilt.
local MAX_ABSENT_PROBES = 50
-- Pauses between attempts of one request, in seconds (network errors, 5xx and 429 are
-- retried). The patient schedule is for the chapters and illustrations of a download that
-- is already under way: a long book must survive a Wi-Fi hiccup.
local QUICK_DELAYS = { 0.3, 0.6 }
local PATIENT_DELAYS = { 1, 2, 4, 8 }

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

local function sleep(seconds)
    pcall(function()
        require("ffi/util").usleep(math.floor(seconds * 1000000))
    end)
end

--[[--
Runs `request` (returning ok, result, http_code) until it succeeds or fails for good.

`on_stalled(message)` (optional) is asked once the attempts are used up while the server
still cannot be reached; returning true starts another round. A long download then waits
for the user (the network went away, the device slept) instead of being thrown away.
]]
local function with_retry(request, on_stalled)
    local delays = on_stalled and PATIENT_DELAYS or QUICK_DELAYS
    while true do
        local ok, res, code
        for attempt = 1, #delays + 1 do
            ok, res, code = request()
            if ok then
                return true, res
            end
            local retryable = code == nil or code >= 500 or code == 429
            if not retryable then
                return false, res, code
            end
            if attempt <= #delays then
                sleep(delays[attempt])
            end
        end
        if not (on_stalled and on_stalled(res)) then
            return false, res, code
        end
    end
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

-- Where a copy of a single volume sits in the book; nil for a whole-book copy.
-- `source` is anything carrying `volume`, `chapters_before` and `book_chapters`.
local function volume_scope(source, chapters_in_copy)
    local volume = type(source) == "table" and tonumber(source.volume) or nil
    if not volume then return nil end
    local before = math.max(0, math.floor(tonumber(source.chapters_before) or 0))
    local total = math.max(math.floor(tonumber(source.book_chapters) or 0), before + chapters_in_copy)
    return { volume = volume, chapters_before = before, book_chapters = total }
end

-- `scope` (optional): `volume`, `chapters_before`, `book_chapters` of a volume copy.
local function make_layout(book_id, chapter_ids, scope)
    local positions = {}
    for index, id in ipairs(chapter_ids) do
        positions[id] = index - 1
    end
    local layout = { book_id = book_id, chapter_ids = chapter_ids, positions = positions }
    scope = volume_scope(scope, #chapter_ids)
    if scope then
        layout.volume = scope.volume
        layout.chapters_before = scope.chapters_before
        layout.book_chapters = scope.book_chapters
    end
    return layout
end
M.make_layout = make_layout

function M.save_layout(file_path, book_id, chapter_ids, scope)
    local path = M.layout_path(file_path)
    if not path then return false end
    scope = volume_scope(scope, #chapter_ids)
    local ok, encoded = pcall(require("json").encode, {
        book_id = book_id,
        chapter_ids = chapter_ids,
        size = file_size(file_path),
        volume = scope and scope.volume or nil,
        chapters_before = scope and scope.chapters_before or nil,
        book_chapters = scope and scope.book_chapters or nil,
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
            return make_layout(data.book_id, ids, data)
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
    local manifest = existing.manifest
    existing:close()
    M.save_layout(file_path, manifest.book_id, ids, manifest)
    return make_layout(manifest.book_id, ids, manifest)
end

-- ================= VOLUME COPIES =================

-- Whether two volume numbers name the same copy (nil is the whole book).
local function same_volume(a, b)
    a, b = tonumber(a), tonumber(b)
    if a == nil or b == nil then
        return a == b
    end
    return math.abs(a - b) < 0.0005
end
M.same_volume = same_volume

-- File name part of a volume copy: `Vol 03`, `Vol 03.5`.
function M.volume_file_suffix(volume)
    local text = ChaptersEpub.format_number(volume)
    local int, frac = text:match("^(%d+)(%.?%d*)$")
    if not int then
        return "Vol " .. text
    end
    return string.format("Vol %02d%s", tonumber(int), frac)
end

-- Whether the copy holds a single volume of the book.
function M.is_volume_copy(layout)
    return type(layout) == "table" and layout.volume ~= nil
end

-- Whether the end of the copy is the end of the book (always true for a whole-book copy).
function M.ends_book(layout)
    if not M.is_volume_copy(layout) then return true end
    return layout.chapters_before + #layout.chapter_ids >= layout.book_chapters
end

-- The server counts percentages in the whole book: a percentage of a volume copy
-- (0..100) in book scale.
function M.to_book_percent(layout, percent)
    percent = tonumber(percent)
    if not percent or not M.is_volume_copy(layout) or layout.book_chapters <= 0 then
        return percent
    end
    local fraction = math.max(0, math.min(1, percent / 100))
    return (layout.chapters_before + fraction * #layout.chapter_ids) / layout.book_chapters * 100
end

-- A book-scale percentage (0..100) as a percentage of this copy, clamped to its ends.
function M.from_book_percent(layout, percent)
    percent = tonumber(percent)
    local count = type(layout) == "table" and #layout.chapter_ids or 0
    if not percent or not M.is_volume_copy(layout) or count == 0 then
        return percent
    end
    local chapters = percent / 100 * layout.book_chapters - layout.chapters_before
    return math.max(0, math.min(1, chapters / count)) * 100
end

-- Bookmarks and annotations live on the server by spine index of the whole book.
-- A local XPointer as the server knows it (unchanged when it names no spine item).
function M.to_server_xpointer(layout, xpointer)
    if not M.is_volume_copy(layout) then return xpointer end
    return ChaptersEpub.shift_xpointer_spine(xpointer, layout.chapters_before) or xpointer
end

--[[--
A server XPointer for this copy. Returns the local XPointer, or nil when it points into a
part of the book this copy does not hold. Positions that name no spine item cannot be
placed and are passed through untouched.
]]
function M.to_local_xpointer(layout, xpointer)
    if not M.is_volume_copy(layout) then return xpointer end
    local index = ChaptersEpub.xpointer_spine_index(xpointer)
    if not index then return xpointer end
    local position = index - layout.chapters_before
    if position < 0 or position >= #layout.chapter_ids then
        return nil
    end
    return ChaptersEpub.shift_xpointer_spine(xpointer, -layout.chapters_before)
end

local LOCATION_FIELDS = { "locationStart", "locationEnd", "location_start", "location_end", "location" }

local function item_start(item)
    return as_string(item.locationStart) or as_string(item.location_start) or as_string(item.location)
end

-- Server bookmarks / annotations as this copy sees them: positions are translated and
-- items that belong to other volumes are left out (they are not this copy's to sync).
-- A whole-book copy gets the list as it is.
function M.localize_items(layout, items)
    if not M.is_volume_copy(layout) or type(items) ~= "table" then
        return items
    end
    local result = {}
    for _, item in ipairs(items) do
        if type(item) ~= "table" then
            result[#result + 1] = item
        else
            local start = item_start(item)
            if start == nil or M.to_local_xpointer(layout, start) ~= nil then
                local copy = {}
                for key, value in pairs(item) do copy[key] = value end
                for _, field in ipairs(LOCATION_FIELDS) do
                    if type(copy[field]) == "string" and copy[field] ~= "" then
                        -- An end that leaves the copy keeps its place in the last chapter's terms
                        copy[field] = M.to_local_xpointer(layout, copy[field])
                            or ChaptersEpub.shift_xpointer_spine(copy[field], -layout.chapters_before)
                            or copy[field]
                    end
                end
                result[#result + 1] = copy
            end
        end
    end
    return result
end

-- A bookmark / annotation payload with its positions as the server knows them.
function M.globalize_item(layout, payload)
    if not M.is_volume_copy(layout) or type(payload) ~= "table" then
        return payload
    end
    local copy = {}
    for key, value in pairs(payload) do copy[key] = value end
    for _, field in ipairs(LOCATION_FIELDS) do
        if type(copy[field]) == "string" and copy[field] ~= "" then
            copy[field] = M.to_server_xpointer(layout, copy[field])
        end
    end
    return copy
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

--[[--
Reading percentage (0..100) of a copy after its chapter list changed, for a reader whose
position stays in the same chapter: it was the `old_index`-th (0-based) of `old_total`
chapters and is the `new_index`-th of `new_total` now. The place inside that chapter comes
from the old percentage, so a reader who finished the last of 100 chapters is at 50 % once
100 more arrive. FolioReader computes the same (`chapters_epub::rescale_percent`).
]]
function M.rescale_percent(percent, old_index, old_total, new_index, new_total)
    percent = tonumber(percent)
    if not percent or percent ~= percent or old_total <= 0 or new_total <= 0 then
        return percent
    end
    local fraction = math.max(0, math.min(1, percent / 100))
    local in_chapter = math.max(0, math.min(1, fraction * old_total - old_index))
    return math.max(0, math.min(100, (new_index + in_chapter) / new_total * 100))
end

--[[--
The percentage of a copy follows its chapter list: after an update added, removed or
reordered chapters, `percent_finished` of a DocSettings object is recomputed for the chapter
of `last_xpointer` (already remapped to the new spine index), and a finished book with more
chapters after the reading position than before is marked as being read again.

Returns nil when nothing changed, otherwise { percent = 0..100, unfinished = true|nil }.
]]
function M.rescale_docsettings(docsettings, previous_ids, chapter_ids)
    if not (docsettings and docsettings.readSetting and docsettings.saveSetting) then
        return nil
    end
    if type(previous_ids) ~= "table" or #previous_ids == 0 or type(chapter_ids) ~= "table" then
        return nil
    end
    local new_index = ChaptersEpub.xpointer_spine_index(docsettings:readSetting("last_xpointer"))
    local chapter_id = new_index and chapter_ids[new_index + 1]
    if not chapter_id then return nil end
    local old_index
    for index, id in ipairs(previous_ids) do
        if id == chapter_id then
            old_index = index - 1
            break
        end
    end
    if not old_index then return nil end

    local old_total, new_total = #previous_ids, #chapter_ids
    local fraction = tonumber(docsettings:readSetting("percent_finished"))
    local result = {}
    if fraction then
        local percent = M.rescale_percent(fraction * 100, old_index, old_total, new_index, new_total)
        if math.abs(percent - fraction * 100) >= 0.0001 then
            docsettings:saveSetting("percent_finished", percent / 100)
            result.percent = percent
        end
    end

    local summary = docsettings:readSetting("summary")
    if type(summary) == "table" and summary.status == "complete"
        and new_total - new_index > old_total - old_index then
        summary.status = "reading"
        docsettings:saveSetting("summary", summary)
        result.unfinished = true
    end

    if result.percent == nil and not result.unfinished then return nil end
    if result.percent == nil then
        result.percent = fraction and fraction * 100 or nil
    end
    return result
end

-- ================= DOWNLOAD =================

-- The chapter list of a book (of one volume when `volume` is given), in reading order.
-- Returns the list, or nil, message, http_code.
function M.fetch_chapter_list(api, book_id, volume)
    local list, seen = {}, {}
    local offset = 0
    while true do
        local ok, page, code = with_retry(function()
            return api:list_chapters(book_id, offset, CHAPTERS_PAGE_SIZE, volume)
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
            -- A server older than the volumes feature ignores the filter: apply it here
            -- too, so a volume copy can never be given chapters of other volumes.
            local wanted = type(item) == "table" and as_string(item.id) and not seen[item.id]
                and (volume == nil or same_volume(tonumber(item.volume) or 0, volume))
            if wanted then
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
The volumes of a book, in reading order.

Returns { items = { { volume = n, chapters = n }, ... }, total = n } — or nil, message,
http_code. A server older than the volumes feature answers 403 or 404: callers then offer
the whole book only.
]]
function M.fetch_volumes(api, book_id, background)
    if type(api.list_volumes) ~= "function" then
        return nil, "Volumes are not supported"
    end
    local ok, data, code
    if background then
        -- Background sync runs on the UI thread: one short attempt
        ok, data, code = api:list_volumes(book_id, true)
    else
        ok, data, code = with_retry(function()
            return api:list_volumes(book_id)
        end)
    end
    if not ok then
        return nil, data, code
    end
    local raw = type(data) == "table" and (type(data.items) == "table" and data.items or data) or {}
    local items, sum = {}, 0
    for _, item in ipairs(raw) do
        local volume = type(item) == "table" and tonumber(item.volume)
        local count = volume and math.max(0, math.floor(tonumber(item.chaptersCount) or 0))
        if volume and count > 0 then
            items[#items + 1] = { volume = volume, chapters = count }
            sum = sum + count
        end
    end
    table.sort(items, function(a, b) return a.volume < b.volume end)
    return { items = items, total = math.max(sum, math.floor(tonumber(data.chaptersTotal) or 0)) }
end

-- Chapters of the book in the volumes before `volume`.
local function chapters_before(volumes, volume)
    local before = 0
    for _, item in ipairs(volumes.items) do
        if item.volume < volume and not same_volume(item.volume, volume) then
            before = before + item.chapters
        end
    end
    return before
end

--[[--
Where the copy of `layout` sits in the book as the server has it now. Volumes are added
and chapters move between them after a copy was downloaded; a copy that goes by what it
knew then would call a book finished that has gone on, and shift its bookmarks and
annotations by the wrong number of chapters.

Returns a scope ({ volume, chapters_before, book_chapters }) and whether it differs from
what the layout holds — or nil, message, http_code. A whole-book copy has no scope: nil.
]]
function M.current_scope(api, layout)
    if not M.is_volume_copy(layout) then return nil end
    local volumes, err, code = M.fetch_volumes(api, layout.book_id, true)
    if not volumes then
        return nil, err, code
    end
    local scope = volume_scope({
        volume = layout.volume,
        chapters_before = chapters_before(volumes, layout.volume),
        book_chapters = volumes.total,
    }, #layout.chapter_ids)
    local changed = scope.chapters_before ~= layout.chapters_before
        or scope.book_chapters ~= layout.book_chapters
    return scope, changed
end

--[[--
Picks the file to write for a book in `dir`: `<stem>.epub`, or `<stem> (<id>).epub` when
another book already uses the plain name. A copy of a single volume (`volume`) goes to
`<stem> - Vol NN.epub`. A file that belongs to another book — or to another volume, or to
the whole book when a volume is asked for, and the other way round — is never overwritten.

Returns path, layout of the copy already there (nil for a new file) — or nil, ERR_NAME_TAKEN.
]]
function M.resolve_target(dir, stem, book_id, load_layout, volume)
    load_layout = load_layout or M.load_layout
    if volume ~= nil then
        stem = stem .. " - " .. M.volume_file_suffix(volume)
    end
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
            if layout and layout.book_id == book_id and same_volume(layout.volume, volume) then
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
- volume: build a copy of this volume only (nil: the whole book)
- title, author: what the catalog knows (book details from the server take precedence)
- previous_chapter_ids: chapter order of the copy being replaced, when known
- on_progress(phase, done, total): phase is "chapters", "images" or "building";
  returning false cancels the download
- on_stalled(message): the server cannot be reached in the middle of the download;
  returning true tries again (see with_retry)
- open_sink, read_existing: injectable for tests

Returns a result table, or nil and an error (one of the ERR_* constants or a message).
]]
function M.build(api, opts)
    local book_id = opts.book_id
    local target_path = opts.target_path
    local progress = opts.on_progress or function() return true end
    local on_stalled = opts.on_stalled
    local open_sink = opts.open_sink or ChaptersEpub.open_sink
    local read_existing = opts.read_existing or ChaptersEpub.read_existing

    -- The id ends up in request paths and in the EPUB itself.
    if type(book_id) ~= "string" or not book_id:match("^[%x%-]+$") then
        return nil, "'" .. tostring(book_id) .. "' is not a Folio book id"
    end
    if type(target_path) ~= "string" or target_path == "" then
        return nil, "No target file"
    end

    local volume = opts.volume
    if volume ~= nil and not tonumber(volume) then
        return nil, "'" .. tostring(volume) .. "' is not a volume number"
    end
    volume = tonumber(volume)

    local list, list_err, list_code = M.fetch_chapter_list(api, book_id, volume)
    if not list then
        if list_code == 403 then
            return nil, M.ERR_FORBIDDEN
        end
        return nil, "Failed to load the chapter list: " .. tostring(list_err)
    end
    if #list == 0 then
        return nil, M.ERR_NO_CHAPTERS
    end

    -- A volume copy needs to know where it sits in the book: the server counts
    -- percentages, bookmarks and annotations in the whole book.
    local scope
    if volume then
        local volumes, volumes_err = M.fetch_volumes(api, book_id)
        if not volumes then
            return nil, "Failed to load the volume list: " .. tostring(volumes_err)
        end
        scope = volume_scope({
            volume = volume,
            chapters_before = chapters_before(volumes, volume),
            book_chapters = volumes.total,
        }, #list)
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
        volume = scope and scope.volume or nil,
        chapters_before = scope and scope.chapters_before or nil,
        book_chapters = scope and scope.book_chapters or nil,
    }

    -- What the copy is called in messages: a volume copy carries its volume in the title
    local display_title = volume and ChaptersEpub.volume_title(meta.language, meta.title, volume) or meta.title

    local updated = file_exists(target_path)
    local existing = updated and read_existing(target_path) or nil
    if existing and (existing.manifest.book_id ~= book_id or not same_volume(existing.manifest.volume, volume)) then
        -- Another book, another volume, or the whole book where a volume is asked for
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
    -- Illustrations fetched while checking for changes: name -> bytes
    local fetched_images = {}
    if existing then
        local stored_chapters = existing.manifest.chapters
        local unchanged = #stored_chapters == #list
        -- Illustrations the previous build could not get from the server
        local absent, absent_set = {}, {}
        for index, summary in ipairs(list) do
            if not unchanged then break end
            local stored = stored_chapters[index].id == summary.id
                and existing:reusable_chapter(meta.language, summary)
            if not stored then
                unchanged = false
            else
                for _, name in ipairs(stored.images) do
                    if not existing:has_image(name) and not absent_set[name] then
                        absent_set[name] = true
                        absent[#absent + 1] = name
                    end
                end
            end
        end
        -- An illustration the server does not have must not turn every update into a
        -- rebuild of the whole file: ask for the absent ones first, and rebuild only when
        -- one of them has turned up (or cannot be asked about)
        if unchanged and #absent > MAX_ABSENT_PROBES then
            unchanged = false
        end
        if unchanged then
            for _, name in ipairs(absent) do
                local ok, bytes, code = with_retry(function()
                    return api:get_book_image(book_id, name)
                end)
                if ok and bytes ~= "" then
                    fetched_images[name] = bytes
                    unchanged = false
                elseif not ok and (code == nil or code >= 500 or code == 429) then
                    existing:close()
                    return nil, "Failed to download illustration " .. name .. ": " .. tostring(bytes)
                end
            end
        end
        if unchanged then
            existing:close()
            return {
                book_id = book_id,
                title = display_title,
                target_path = target_path,
                chapter_ids = previous_ids,
                scope = scope,
                moved = {},
                has_moved = false,
                updated = true,
                unchanged = true,
                chapters_total = #list,
                chapters_fetched = 0,
                images_fetched = 0,
                images_missing = #absent,
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
            end, on_stalled)
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
        local ok, bytes, code = true, fetched_images[name], nil
        if not bytes then
            ok, bytes, code = with_retry(function()
                return api:get_book_image(book_id, name)
            end, on_stalled)
        end
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
    -- A file that was cut short (full disk) must not replace the copy that is there.
    -- Reading it back is only possible where archives can be read at all.
    local written = opts.open_sink == nil and file_size(tmp_path) or nil
    if opts.open_sink == nil and (not written or written == 0) then
        os.remove(tmp_path)
        return nil, "Failed to write the book file"
    end
    if opts.open_sink == nil and opts.read_existing == nil and ChaptersEpub.can_read_archives() then
        local check = read_existing(tmp_path)
        local complete = check ~= nil and #check.manifest.chapters == #chapters
        if check then check:close() end
        if not complete then
            os.remove(tmp_path)
            return nil, "Failed to write the book file"
        end
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
        title = display_title,
        target_path = target_path,
        tmp_path = tmp_path,
        chapter_ids = chapter_ids,
        -- volume, chapters_before, book_chapters of a volume copy; nil for the whole book
        scope = scope,
        -- Old spine index -> new spine index of the chapters that changed their place
        moved = moved,
        has_moved = has_moved,
        -- Chapter order of the previous build (nil for a new copy)
        previous_chapter_ids = previous_ids,
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
        -- The place of a volume in the book may have changed even though its chapters did not
        M.save_layout(result.target_path, result.book_id, result.chapter_ids, result.scope)
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
    M.save_layout(result.target_path, result.book_id, result.chapter_ids, result.scope)
    return true
end

-- Drops a built EPUB that will not be used.
function M.discard(result)
    if result and result.tmp_path then
        os.remove(result.tmp_path)
    end
end

return M
