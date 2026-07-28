local json = require("json")
local logger = require("logger")
local utils = require("utils")

local FolioAPI = {}

local function get_http_client()
    local ok, http = pcall(require, "httpclient")
    if ok and http then
        return http
    end
    return nil
end

local function make_headers(token)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    }
    if token and token ~= "" then
        headers["Authorization"] = "Bearer " .. token
    end
    return headers
end

function FolioAPI:new(settings)
    local o = {
        settings = settings or {},
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function FolioAPI:get_server_url()
    local url = self.settings.server_url or ""
    return utils.trim_slash(url)
end

function FolioAPI:get_token()
    return self.settings.token or ""
end

function FolioAPI:login(email, password, callback)
    local base_url = self:get_server_url()
    if base_url == "" then
        if callback then callback(false, "Server URL is not set") end
        return false, "Server URL is not set"
    end

    local login_url = base_url .. "/identity/login"
    local payload = json.encode({
        email = email,
        password = password,
    })

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false, "HTTP client unavailable"
    end

    logger.info("FolioSync API: logging in to " .. login_url)
    local response, err = http.post(login_url, payload, {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    })

    if not response then
        local msg = "Connection error: " .. tostring(err or "Unknown")
        logger.warn("FolioSync API: login failed - " .. msg)
        if callback then callback(false, msg) end
        return false, msg
    end

    local code = response.code or response.status or 0
    local body = response.body or response.content or ""

    if code >= 200 and code < 300 then
        local ok, data = pcall(json.decode, body)
        if ok and data and data.token then
            self.settings.token = data.token
            self.settings.user_id = data.userId
            self.settings.email = email
            logger.info("FolioSync API: login successful for " .. email)
            if callback then callback(true, data) end
            return true, data
        else
            local msg = "Invalid login response format"
            if callback then callback(false, msg) end
            return false, msg
        end
    else
        local msg = "Login failed (HTTP " .. tostring(code) .. ")"
        logger.warn("FolioSync API: " .. msg)
        if callback then callback(false, msg) end
        return false, msg
    end
end

function FolioAPI:list_books(page, limit, search, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    page = page or 1
    limit = limit or 20

    local query = string.format("page=%d&limit=%d", page, limit)
    if search and search ~= "" then
        query = query .. "&search=" .. string.gsub(search, " ", "%%20")
    end

    local url = base_url .. "/books?" .. query
    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false, "HTTP client unavailable"
    end

    local response, err = http.get(url, make_headers(token))
    if not response then
        if callback then callback(false, tostring(err)) end
        return false, tostring(err)
    end

    local code = response.code or response.status or 0
    local body = response.body or response.content or ""

    if code >= 200 and code < 300 then
        local ok, data = pcall(json.decode, body)
        if ok and data then
            if callback then callback(true, data) end
            return true, data
        end
    end

    local msg = "Failed to list books (HTTP " .. tostring(code) .. ")"
    if callback then callback(false, msg) end
    return false, msg
end

function FolioAPI:download_book(book_id, save_path, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/download"

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false, "HTTP client unavailable"
    end

    logger.info("FolioSync API: downloading book " .. tostring(book_id) .. " to " .. tostring(save_path))
    local response, err = http.get(url, make_headers(token))
    if not response then
        local msg = "Download failed: " .. tostring(err)
        if callback then callback(false, msg) end
        return false, msg
    end

    local code = response.code or response.status or 0
    local body = response.body or response.content or ""

    if code >= 200 and code < 300 and #body > 0 then
        local f = io.open(save_path, "wb")
        if not f then
            local msg = "Cannot write file to " .. tostring(save_path)
            if callback then callback(false, msg) end
            return false, msg
        end
        f:write(body)
        f:close()
        logger.info("FolioSync API: book downloaded successfully (" .. tostring(#body) .. " bytes)")
        if callback then callback(true, save_path) end
        return true, save_path
    else
        local msg = "Download failed (HTTP " .. tostring(code) .. ")"
        if callback then callback(false, msg) end
        return false, msg
    end
end

function FolioAPI:get_progress(book_id, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/progress"

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.get(url, make_headers(token))
    if not response then
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    local body = response.body or response.content or ""

    if code >= 200 and code < 300 then
        local ok, data = pcall(json.decode, body)
        if ok and data then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

function FolioAPI:update_progress(book_id, cfi, progress_percent, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/progress"

    local payload = json.encode({
        cfi = cfi or "",
        progressPercent = progress_percent or 0.0,
    })

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.put(url, payload, make_headers(token))
    if not response then
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    if code >= 200 and code < 300 then
        if callback then callback(true) end
        return true
    end

    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

function FolioAPI:list_annotations(book_id, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/annotations"

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.get(url, make_headers(token))
    if not response then
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    local body = response.body or response.content or ""

    if code >= 200 and code < 300 then
        local ok, data = pcall(json.decode, body)
        if ok and type(data) == "table" then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

function FolioAPI:create_annotation(book_id, annotation, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/annotations"

    local payload = json.encode({
        cfiRange = annotation.cfi_range or annotation.cfiRange or "",
        selectedText = annotation.selected_text or annotation.selectedText or "",
        note = annotation.note,
        color = annotation.color,
    })

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.post(url, payload, make_headers(token))
    if not response then
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    local body = response.body or response.content or ""

    if code >= 200 and code < 300 then
        local ok, data = pcall(json.decode, body)
        if ok and data then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

function FolioAPI:update_annotation(book_id, annotation_id, annotation, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/annotations/" .. tostring(annotation_id)

    local payload = json.encode({
        cfiRange = annotation.cfi_range or annotation.cfiRange or "",
        selectedText = annotation.selected_text or annotation.selectedText or "",
        note = annotation.note,
        color = annotation.color,
    })

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.put(url, payload, make_headers(token))
    if not response then
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    if code >= 200 and code < 300 then
        if callback then callback(true) end
        return true
    end

    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

function FolioAPI:delete_annotation(book_id, annotation_id, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/annotations/" .. tostring(annotation_id)

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.delete(url, make_headers(token))
    if not response then
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    if code >= 200 and code < 300 then
        if callback then callback(true) end
        return true
    end

    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

function FolioAPI:list_bookmarks(book_id, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/bookmarks"

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.get(url, make_headers(token))
    if not response then
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    local body = response.body or response.content or ""

    if code >= 200 and code < 300 then
        local ok, data = pcall(json.decode, body)
        if ok and type(data) == "table" then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

function FolioAPI:create_bookmark(book_id, bookmark, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/bookmarks"

    local payload = json.encode({
        cfi = bookmark.cfi or "",
        title = bookmark.title or "Bookmark",
    })

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.post(url, payload, make_headers(token))
    if not response then
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    local body = response.body or response.content or ""

    if code >= 200 and code < 300 then
        local ok, data = pcall(json.decode, body)
        if ok and data then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

function FolioAPI:delete_bookmark(book_id, bookmark_id, callback)
    local base_url = self:get_server_url()
    local token = self:get_token()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/bookmarks/" .. tostring(bookmark_id)

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.delete(url, make_headers(token))
    if not response then
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    if code >= 200 and code < 300 then
        if callback then callback(true) end
        return true
    end

    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

return FolioAPI
