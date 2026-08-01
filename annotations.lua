local logger = require("logger")
local utils = require("utils")

local M = {}

-- Sanitize KOReader bookmark/highlight item to exact minimal schema
function M.sanitize_koreader_annotation(kr_item, target_doc)
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
    if type(kr_item.pos0) == "string" and kr_item.pos0:sub(1, 1) == "/" then
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

    if not kr_item.color or kr_item.color == "" then
        kr_item.color = "yellow"
    end
    if not kr_item.drawer or kr_item.drawer == "" then
        kr_item.drawer = "lighten"
    end
    if not kr_item.datetime or kr_item.datetime == "" then
        kr_item.datetime = os.date("%Y-%m-%d %H:%M:%S")
    end
    if not kr_item.datetime_updated or kr_item.datetime_updated == "" then
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

    local pos0 = kr_item.pos0 or (type(kr_item.page) == "string" and kr_item.page)
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
        color = kr_item.color or "yellow",
        drawer = kr_item.drawer or "lighten",
    }
end

-- Convert Folio Annotation response item to KOReader bookmark/highlight item
function M.folio_to_koreader_annotation(folio_item, target_doc)
    if not folio_item then return nil end

    local text = type(folio_item.selectedText) == "string" and folio_item.selectedText
        or type(folio_item.selected_text) == "string" and folio_item.selected_text
        or type(folio_item.text) == "string" and folio_item.text
        or ""
    local note = type(folio_item.note) == "string" and folio_item.note
        or type(folio_item.notes) == "string" and folio_item.notes
        or ""
    local locationStart = folio_item.locationStart
        or folio_item.location_start
        or folio_item.location
        or folio_item.pos0
        or ""
    local locationEnd = folio_item.locationEnd
        or folio_item.location_end
        or folio_item.pos1
        or ""

    local kr_item = {
        color = folio_item.color or "yellow",
        datetime = folio_item.createdAt
            or folio_item.created_at
            or folio_item.datetime
            or os.date("%Y-%m-%d %H:%M:%S"),
        datetime_updated = folio_item.updatedAt
            or folio_item.updated_at
            or folio_item.datetime_updated
            or folio_item.createdAt
            or folio_item.created_at
            or os.date("%Y-%m-%d %H:%M:%S"),
        drawer = folio_item.drawer or "lighten",
        note = note ~= "" and note or nil,
        page = locationStart ~= "" and locationStart or "page_1",
        pos0 = locationStart ~= "" and locationStart or "page_1",
        pos1 = locationEnd ~= "" and locationEnd or "",
        text = text ~= "" and text or nil,
        folio_id = folio_item.id,
    }

    return M.sanitize_koreader_annotation(kr_item, target_doc)
end

-- Convert Folio Bookmark response item to KOReader bookmark item
function M.folio_to_koreader_bookmark(folio_bm, target_doc)
    if not folio_bm then return nil end
    local location = folio_bm.location or folio_bm.locationStart or folio_bm.pos0 or "page_1"
    local page = location:match("^page_(%d+)$") and tonumber(location:match("^page_(%d+)$")) or location

    return {
        datetime = folio_bm.createdAt or folio_bm.created_at or os.date("%Y-%m-%d %H:%M:%S"),
        page = page,
        pos0 = location,
        text = folio_bm.title or folio_bm.text or "",
        folio_id = folio_bm.id,
    }
end

-- Convert KOReader bookmark item to Folio Bookmark payload
function M.koreader_to_folio_bookmark(kr_bm)
    if not kr_bm then return nil end
    local location = kr_bm.pos0 or (type(kr_bm.page) == "string" and kr_bm.page) or (type(kr_bm.page) == "number" and string.format("page_%d", kr_bm.page)) or "page_1"
    return {
        location = location,
        title = type(kr_bm.text) == "string" and kr_bm.text ~= "" and kr_bm.text or "Bookmark",
    }
end

-- Compare whether two annotations match by location / position
function M.is_same_annotation(item_a, item_b)
    if not item_a or not item_b then return false end
    if item_a.folio_id and item_b.folio_id and item_a.folio_id == item_b.folio_id then
        return true
    end
    local pos_a = type(item_a.pos0) == "string" and item_a.pos0 or item_a.locationStart or (type(item_a.page) == "string" and item_a.page) or ""
    local pos_b = type(item_b.pos0) == "string" and item_b.pos0 or item_b.locationStart or (type(item_b.page) == "string" and item_b.page) or ""

    if pos_a ~= "" and pos_a == pos_b then
        return true
    end

    local text_a = type(item_a.text) == "string" and item_a.text or (type(item_a.selectedText) == "string" and item_a.selectedText) or ""
    local text_b = type(item_b.text) == "string" and item_b.text or (type(item_b.selectedText) == "string" and item_b.selectedText) or ""

    if text_a ~= "" and text_a == text_b then
        return true
    end

    return false
end

return M
