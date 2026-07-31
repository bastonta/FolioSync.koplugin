local logger = require("logger")

local M = {}

-- Convert local KOReader bookmark/highlight item to Folio Annotation object
function M.koreader_to_folio_annotation(kr_item)
    if not kr_item then return nil end
    local pos0 = kr_item.pos0 or string.format("page_%s", tostring(kr_item.page or 1))
    local pos1 = kr_item.pos1 or ""

    return {
        locationStart = pos0,
        locationEnd = pos1,
        selectedText = kr_item.text or "",
        note = kr_item.notes or kr_item.note or "",
        color = kr_item.color or "yellow",
    }
end

-- Convert Folio Annotation response item to KOReader bookmark/highlight item
function M.folio_to_koreader_annotation(folio_item)
    if not folio_item then return nil end

    local text = folio_item.selectedText or folio_item.selected_text or ""
    local note = folio_item.note or ""
    local locationStart = folio_item.locationStart or ""
    local locationEnd = folio_item.locationEnd or ""

    local kr_item = {
        datetime = folio_item.updatedAt or folio_item.updated_at or folio_item.createdAt or "",
        text = text ~= "" and text or nil,
        notes = note ~= "" and note or nil,
        pos0 = locationStart,
        pos1 = locationEnd ~= "" and locationEnd or nil,
        color = folio_item.color or "yellow",
        type = (text ~= "" or note ~= "") and "highlight" or "bookmark",
        folio_id = folio_item.id,
    }

    return kr_item
end

-- Compare whether two annotations match by location / position
function M.is_same_annotation(item_a, item_b)
    if not item_a or not item_b then return false end
    if item_a.folio_id and item_b.folio_id and item_a.folio_id == item_b.folio_id then
        return true
    end
    local pos_a = item_a.pos0 or item_a.locationStart or ""
    local pos_b = item_b.pos0 or item_b.locationStart or ""

    if pos_a ~= "" and pos_a == pos_b then
        return true
    end

    local text_a = item_a.text or item_a.selectedText or item_a.selected_text or ""
    local text_b = item_b.text or item_b.selectedText or item_b.selected_text or ""

    if text_a ~= "" and text_a == text_b then
        return true
    end

    return false
end

return M
