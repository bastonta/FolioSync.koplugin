--[[--
Conversion between KOReader's annotation items and the Folio REST model, and the rules
that tell which local item is which server item.

KOReader keeps page bookmarks and highlights in one list (`ReaderAnnotation.annotations`):
- a page bookmark has `page` (XPointer, or a page number in paged documents) and no
  `drawer`, `pos0` or `pos1`. KOReader tells the two apart by `drawer` alone;
- a highlight has `drawer`, `pos0` and `pos1`.

Nothing here changes an item of that list, except `repair_bookmark`, which undoes what
earlier versions of this plugin wrote into page bookmarks.
]]

local utils = require("utils")

local M = {}

local function as_string(value)
    return type(value) == "string" and value or nil
end

local function non_empty(value)
    return type(value) == "string" and value ~= "" and value or nil
end

-- KOReader stores `datetime` as local time, the server answers with RFC 3339.
local function koreader_datetime(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "string" and value ~= "" then
            local epoch = utils.parse_iso8601(value)
            if epoch then
                return os.date("%Y-%m-%d %H:%M:%S", math.floor(epoch))
            end
            if value:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") then
                return value
            end
        end
    end
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- Brings a newly built item (never an item of KOReader's live list) to the shape of a
-- KOReader highlight.
function M.sanitize_koreader_annotation(kr_item)
    if not kr_item or type(kr_item) ~= "table" then return nil end

    -- 1. Ensure pos0 is valid
    local pos0 = kr_item.pos0
    if not pos0 or pos0 == "" then
        if type(kr_item.page) == "string" and kr_item.page ~= "" then
            pos0 = kr_item.page
        elseif type(kr_item.page) == "number" then
            pos0 = string.format("page_%d", kr_item.page)
        elseif type(kr_item.pageno) == "number" then
            pos0 = string.format("page_%d", kr_item.pageno)
        else
            pos0 = "page_1"
        end
    end
    kr_item.pos0 = pos0

    -- 2. Set page field: for XPointer annotations, KOReader sets page = pos0 (XPointer string)
    if type(kr_item.pos0) == "string" and (kr_item.pos0:sub(1, 1) == "/" or kr_item.pos0:find("DocFragment") or kr_item.pos0:find("text%(%)")) then
        kr_item.page = kr_item.pos0
    elseif not kr_item.page or kr_item.page == "" then
        local p_from_pos = type(kr_item.pos0) == "string" and kr_item.pos0:match("^page_(%d+)$")
        if p_from_pos then
            kr_item.page = tonumber(p_from_pos)
        elseif type(kr_item.pageno) == "number" then
            kr_item.page = kr_item.pageno
        else
            kr_item.page = 1
        end
    end

    if not kr_item.pos1 then
        kr_item.pos1 = ""
    end

    if type(kr_item.color) ~= "string" or kr_item.color == "" then
        kr_item.color = "yellow"
    end
    if type(kr_item.drawer) ~= "string" or kr_item.drawer == "" then
        kr_item.drawer = "lighten"
    end
    if type(kr_item.datetime) ~= "string" or kr_item.datetime == "" then
        kr_item.datetime = os.date("%Y-%m-%d %H:%M:%S")
    end
    if type(kr_item.datetime_updated) ~= "string" or kr_item.datetime_updated == "" then
        kr_item.datetime_updated = kr_item.datetime
    end

    -- Clean up note/notes field safely (strictly string values only)
    local note_val = nil
    if type(kr_item.note) == "string" and kr_item.note ~= "" then
        note_val = kr_item.note
    elseif type(kr_item.notes) == "string" and kr_item.notes ~= "" then
        note_val = kr_item.notes
    end
    kr_item.note = note_val
    kr_item.notes = nil

    -- Clean up text field safely (strictly string values only)
    if type(kr_item.text) ~= "string" or kr_item.text == "" then
        kr_item.text = nil
    end

    -- Strip extra fields not in minimal schema
    kr_item.chapter = nil
    kr_item.pageno = nil

    return kr_item
end

-- Convert local KOReader bookmark/highlight item to Folio Annotation object
function M.koreader_to_folio_annotation(kr_item)
    if not kr_item then return nil end

    ---@type string|table|nil
    local pos0 = kr_item.pos0
    if not pos0 and type(kr_item.page) == "string" then
        pos0 = kr_item.page
    end

    local page_num = type(kr_item.page) == "number" and kr_item.page or nil

    if type(pos0) == "table" then
        page_num = page_num or pos0.page
        pos0 = string.format("page_%s", tostring(page_num or 1))
    elseif not pos0 or pos0 == "" then
        if page_num then
            pos0 = string.format("page_%s", tostring(page_num))
        else
            pos0 = "page_1"
        end
    end

    local pos1 = kr_item.pos1
    if type(pos1) == "table" then
        pos1 = string.format("page_%s", tostring(pos1.page or page_num or 1))
    elseif not pos1 then
        pos1 = ""
    end

    local note_str = ""
    if type(kr_item.note) == "string" then
        note_str = kr_item.note
    elseif type(kr_item.notes) == "string" then
        note_str = kr_item.notes
    end

    return {
        locationStart = tostring(pos0),
        locationEnd = tostring(pos1),
        selectedText = type(kr_item.text) == "string" and kr_item.text or "",
        note = note_str,
        color = non_empty(kr_item.color) or "yellow",
        drawer = non_empty(kr_item.drawer) or "lighten",
    }
end

-- Convert Folio Annotation response item to KOReader bookmark/highlight item.
-- Only strings are taken from the response: a JSON `null` (or anything else a decoder
-- may put in its place) must never end up in the book's settings.
function M.folio_to_koreader_annotation(folio_item)
    if type(folio_item) ~= "table" then return nil end

    local text = as_string(folio_item.selectedText)
        or as_string(folio_item.selected_text)
        or as_string(folio_item.text)
        or ""
    local note = as_string(folio_item.note)
        or as_string(folio_item.notes)
        or ""
    local locationStart = as_string(folio_item.locationStart)
        or as_string(folio_item.location_start)
        or as_string(folio_item.location)
        or as_string(folio_item.pos0)
        or ""
    local locationEnd = as_string(folio_item.locationEnd)
        or as_string(folio_item.location_end)
        or as_string(folio_item.pos1)
        or ""

    local created = koreader_datetime(folio_item.createdAt, folio_item.created_at, folio_item.datetime)
    local kr_item = {
        color = non_empty(folio_item.color) or "yellow",
        datetime = created,
        datetime_updated = koreader_datetime(folio_item.updatedAt, folio_item.updated_at,
            folio_item.datetime_updated, created),
        drawer = non_empty(folio_item.drawer) or "lighten",
        note = note ~= "" and note or nil,
        page = locationStart ~= "" and locationStart or "page_1",
        pos0 = locationStart ~= "" and locationStart or "page_1",
        pos1 = locationEnd ~= "" and locationEnd or (text ~= "" and (locationStart ~= "" and locationStart or "page_1") or ""),
        text = text ~= "" and text or nil,
        folio_id = as_string(folio_item.id),
    }

    return M.sanitize_koreader_annotation(kr_item)
end

-- Title the plugin sends for a bookmark that has no text of its own
local DEFAULT_BOOKMARK_TITLE = "Bookmark"

-- Convert Folio Bookmark response item to a KOReader page bookmark: `page` and nothing
-- that would make KOReader take it for a highlight (no `drawer`, `pos0`, `pos1`).
function M.folio_to_koreader_bookmark(folio_bm)
    if type(folio_bm) ~= "table" then return nil end
    local location = non_empty(folio_bm.location) or non_empty(folio_bm.locationStart)
        or non_empty(folio_bm.pos0) or "page_1"
    local page_number = location:match("^page_(%d+)$")
    local title = non_empty(folio_bm.title) or non_empty(folio_bm.text)
    if title == DEFAULT_BOOKMARK_TITLE then title = nil end

    return {
        datetime = koreader_datetime(folio_bm.createdAt, folio_bm.created_at),
        page = page_number and tonumber(page_number) or location,
        text = title,
        folio_id = as_string(folio_bm.id),
    }
end

-- Convert KOReader bookmark item to Folio Bookmark payload
function M.koreader_to_folio_bookmark(kr_bm)
    if not kr_bm then return nil end
    local location = (type(kr_bm.page) == "string" and kr_bm.page ~= "" and kr_bm.page)
        or (type(kr_bm.page) == "number" and string.format("page_%d", kr_bm.page))
        or non_empty(kr_bm.pos0)
        or "page_1"
    return {
        location = location,
        title = non_empty(kr_bm.text) or DEFAULT_BOOKMARK_TITLE,
    }
end

-- ================= KINDS =================

local function has_position(value)
    return (type(value) == "string" and value ~= "") or type(value) == "table"
end

-- Check if item is a highlight/text annotation (has non-empty pos0 and pos1)
function M.is_annotation(item)
    return type(item) == "table" and has_position(item.pos0) and has_position(item.pos1)
end

-- Check if item is a page bookmark (has pos0/page, but empty pos1)
function M.is_bookmark(item)
    return type(item) == "table" and (item.pos0 ~= nil or item.page ~= nil) and not M.is_annotation(item)
end

--[[--
Earlier versions of this plugin "normalised" KOReader's own items in place and gave page
bookmarks a `drawer`, a `color`, a `pos0` and an empty `pos1`. KOReader takes anything
with a `drawer` for a highlight, so the dog-ear disappeared and tapping the corner again
added a second bookmark. Takes those fields off again; returns true when the item changed.
]]
function M.repair_bookmark(item)
    if type(item) ~= "table" or M.is_annotation(item) then return false end
    if item.page == nil or item.page == "" then return false end
    local changed = false
    if item.pos1 == "" then
        item.pos1 = nil
        changed = true
    end
    if item.drawer ~= nil and item.pos1 == nil then
        item.drawer = nil
        item.color = nil
        changed = true
    end
    if changed and type(item.pos0) == "string" then
        -- Was copied from `page` (or made up as `page_N` for a page number)
        item.pos0 = nil
    end
    return changed
end

-- ================= IDENTITY =================

-- The server id of an item: local items and snapshots carry it as `folio_id`, server
-- items as `id`.
function M.item_id(item)
    if type(item) ~= "table" then return nil end
    return as_string(item.folio_id) or as_string(item.id)
end

-- XPointers written by KOReader and by the server differ in how they spell the first
-- element of its kind (`div` / `div[1]`, `text()` / `text()[1]`) and the start of an
-- element (`p/text().0` comes back from the server as `p.0`): one spelling for all.
function M.position_key(position)
    if type(position) ~= "string" or position == "" then return nil end
    local key = position:gsub("%[1%]", ""):gsub("/text%(%)%.0$", ".0")
    return key
end

-- Where an item starts, as a comparable key; nil when it cannot be compared (a highlight
-- of a paged document is placed by coordinates the server does not have).
function M.start_key(item)
    if type(item) ~= "table" then return nil end
    local position = non_empty(item.pos0) or non_empty(item.locationStart) or non_empty(item.location_start)
        or non_empty(item.location)
    if not position and item.pos0 == nil then
        if type(item.page) == "string" and item.page ~= "" then
            position = item.page
        elseif type(item.page) == "number" then
            position = string.format("page_%d", item.page)
        end
    end
    return M.position_key(position)
end

-- Where a highlight ends; nil when unknown.
function M.end_key(item)
    if type(item) ~= "table" then return nil end
    return M.position_key(non_empty(item.pos1) or non_empty(item.locationEnd) or non_empty(item.location_end))
end

local function item_text(item)
    return non_empty(item.text) or non_empty(item.selectedText) or non_empty(item.selected_text)
end

-- Same place in the book: the start, and the end where both items have one.
local function same_position(item_a, item_b, with_end)
    local start_a = M.start_key(item_a)
    if not start_a or start_a ~= M.start_key(item_b) then
        return false
    end
    if with_end then
        local end_a, end_b = M.end_key(item_a), M.end_key(item_b)
        if end_a and end_b and end_a ~= end_b then
            return false
        end
    end
    return true
end

-- Compare whether two highlights are the same one: by server id, else by position.
-- The highlighted text is not an identity: the same words can be marked twice.
function M.is_same_annotation(item_a, item_b)
    if not item_a or not item_b then return false end
    local id_a, id_b = M.item_id(item_a), M.item_id(item_b)
    if id_a and id_b and id_a == id_b then
        return true
    end
    return same_position(item_a, item_b, true)
end

-- Compare whether two bookmarks match by location / position or folio_id
function M.is_same_bookmark(item_a, item_b)
    if not item_a or not item_b then return false end
    local id_a, id_b = M.item_id(item_a), M.item_id(item_b)
    if id_a and id_b and id_a == id_b then
        return true
    end
    return same_position(item_a, item_b, false)
end

--[[--
Pairs the items of two lists one to one: by server id, then by position, and — for
highlights, when `by_text` is set — by text where exactly one item on each side is left
with that text (positions written by two readers do not always agree to the character).

Returns two maps: index in `left` -> index in `right`, and the reverse.
]]
function M.pair_items(left, right, opts)
    local with_end = opts and opts.with_end
    local to_right, to_left = {}, {}

    local function pair(i, j)
        to_right[i] = j
        to_left[j] = i
    end

    -- 1. Server id
    local right_by_id = {}
    for j, item in ipairs(right) do
        local id = M.item_id(item)
        if id and right_by_id[id] == nil then right_by_id[id] = j end
    end
    for i, item in ipairs(left) do
        local id = M.item_id(item)
        local j = id and right_by_id[id]
        if j and not to_left[j] then pair(i, j) end
    end

    -- 2. Position
    local right_by_start = {}
    for j, item in ipairs(right) do
        local key = not to_left[j] and M.start_key(item)
        if key then
            right_by_start[key] = right_by_start[key] or {}
            table.insert(right_by_start[key], j)
        end
    end
    for i, item in ipairs(left) do
        local key = not to_right[i] and M.start_key(item)
        local candidates = key and right_by_start[key]
        if candidates then
            for _, j in ipairs(candidates) do
                if not to_left[j] and same_position(item, right[j], with_end) then
                    pair(i, j)
                    break
                end
            end
        end
    end

    -- 3. Text that is unique among what is left on both sides
    if opts and opts.by_text then
        local function unpaired_by_text(items, paired)
            local by_text = {}
            for index, item in ipairs(items) do
                local text = not paired[index] and type(item) == "table" and item_text(item)
                if text then
                    by_text[text] = by_text[text] == nil and index or false
                end
            end
            return by_text
        end
        local left_texts = unpaired_by_text(left, to_right)
        local right_texts = unpaired_by_text(right, to_left)
        for text, i in pairs(left_texts) do
            local j = right_texts[text]
            if i and j then pair(i, j) end
        end
    end

    return to_right, to_left
end

-- Sort items in-place by pos0 position (required by KOReader for highlight rendering)
function M.sort_by_position(items)
    if not items or #items < 2 then return items end
    local function position(item)
        return type(item.pos0) == "string" and item.pos0 or (type(item.page) == "string" and item.page) or ""
    end
    table.sort(items, function(a, b)
        local pos_a, pos_b = position(a), position(b)
        if pos_a == pos_b then
            local dt_a = type(a.datetime) == "string" and a.datetime or ""
            local dt_b = type(b.datetime) == "string" and b.datetime or ""
            return dt_a < dt_b
        end
        return pos_a < pos_b
    end)
    return items
end

return M
