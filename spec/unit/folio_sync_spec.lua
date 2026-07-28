-- Unit tests for FolioSync plugin logic and data conversions

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
        assert.is_equal("/6/4[chapter1]!/4/2/1:0-/6/4[chapter1]!/4/2/1:50", folio_item.cfiRange)
        assert.is_equal("Highlighted text quote", folio_item.selectedText)
        assert.is_equal("My user note", folio_item.note)
        assert.is_equal("yellow", folio_item.color)
    end)

    it("converts Folio REST annotation response item to KOReader bookmark format", function()
        local folio_item = {
            id = "12345678-1234-1234-1234-123456789abc",
            cfiRange = "epubcfi(/6/4!/4/2/1:0)",
            selectedText = "Sample quote from ebook",
            note = "Important reflection",
            color = "blue",
            updatedAt = "2026-07-28T12:00:00Z",
        }

        local kr_item = annotations.folio_to_koreader_annotation(folio_item)

        assert.is_not_nil(kr_item)
        assert.is_equal("Sample quote from ebook", kr_item.text)
        assert.is_equal("Important reflection", kr_item.notes)
        assert.is_equal("epubcfi(/6/4!/4/2/1:0)", kr_item.pos0)
        assert.is_equal("blue", kr_item.color)
        assert.is_equal("12345678-1234-1234-1234-123456789abc", kr_item.folio_id)
    end)

    it("sanitizes filenames correctly for downloading books", function()
        local clean1 = utils.sanitize_filename("Great Book: Edition 1 / Volume 2")
        assert.is_equal("Great Book_ Edition 1 _ Volume 2", clean1)

        local clean2 = utils.sanitize_filename("War & Peace")
        assert.is_equal("War & Peace", clean2)
    end)

    it("trims slashes from URLs properly", function()
        assert.is_equal("http://localhost:8080", utils.trim_slash("http://localhost:8080/"))
        assert.is_equal("http://localhost:8080", utils.trim_slash("http://localhost:8080///"))
    end)
end)
