local json = require("json")
local logger = require("logger")
local utils = require("utils")

local FolioAPI = {}

local function urlencode(str)
    if not str then return "" end
    str = string.gsub(str, "\r?\n", "\r\n")
    str = string.gsub(str, "([^%w%-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

local function get_http_client()
    local ok_http, sockethttp = pcall(require, "socket.http")
    local ok_https, sslhttps = pcall(require, "ssl.https")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not (ok_http and sockethttp) and not (ok_https and sslhttps) then
        return nil
    end
    if not ok_ltn12 or not ltn12 then
        return nil
    end

    -- Optionally use socketutil for timeout management
    local ok_su, socketutil = pcall(require, "socketutil")

    local client = {}

    local function do_request(url, method, body, headers)
        local response_body = {}
        local request_params = {
            url    = url,
            method = method,
            sink   = ltn12.sink.table(response_body),
        }

        if headers then
            -- Make a copy so we don't mutate the caller's table
            local h = {}
            for k, v in pairs(headers) do h[k] = v end
            if body then
                h["Content-Length"] = tostring(#body)
            end
            request_params.headers = h
        end

        if body then
            request_params.source = ltn12.source.string(body)
        end

        if ok_su and socketutil then
            if socketutil.set_timeout then
                socketutil:set_timeout(10, 30)
            end
        end

        local http_driver = sockethttp
        if url and url:sub(1, 6):lower() == "https:" and ok_https and sslhttps then
            http_driver = sslhttps
        end

        local res, code, resp_headers
        if http_driver then
            res, code, resp_headers = http_driver.request(request_params)
        end

        if ok_su and socketutil then
            if socketutil.reset_timeout then
                socketutil:reset_timeout()
            end
        end

        if res == nil then
            return nil, tostring(code) -- code contains the error message on failure
        end

        return {
            code = code,
            status = code,
            body = table.concat(response_body),
            content = table.concat(response_body),
            headers = resp_headers,
        }
    end

    function client.get(url, headers)
        return do_request(url, "GET", nil, headers)
    end

    function client.post(url, body, headers)
        return do_request(url, "POST", body, headers)
    end

    function client.put(url, body, headers)
        return do_request(url, "PUT", body, headers)
    end

    function client.delete(url, headers)
        return do_request(url, "DELETE", nil, headers)
    end

    return client
end

local function make_headers(api_key)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    }
    if api_key and api_key ~= "" then
        headers["X-API-Key"] = api_key
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

function FolioAPI:get_api_key()
    return self.settings.api_key or ""
end

function FolioAPI:has_auth()
    return self.settings.api_key and self.settings.api_key ~= ""
end

function FolioAPI:get_headers()
    return make_headers(self:get_api_key())
end

function FolioAPI:find_book_by_hash(file_hash, callback)
    local base_url = self:get_server_url()
    local url = base_url .. "/books/by-hash/" .. tostring(file_hash)

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false, "HTTP client unavailable"
    end

    local response, err = http.get(url, self:get_headers())
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

    if code == 404 then
        if callback then callback(false, "not_found") end
        return false, "not_found"
    end

    local msg = "Failed to find book by hash (HTTP " .. tostring(code) .. ")"
    if callback then callback(false, msg) end
    return false, msg
end

function FolioAPI:browse(series_id, sort_by, offset, limit, search, search_by, callback)
    local base_url = self:get_server_url()
    offset = offset or 0
    limit = limit or 20

    local query = string.format("offset=%d&limit=%d", offset, limit)
    if series_id and series_id ~= "" then
        query = query .. "&seriesId=" .. tostring(series_id)
    end
    if sort_by and sort_by ~= "" then
        query = query .. "&sortBy=" .. tostring(sort_by)
    end
    if search and search ~= "" then
        query = query .. "&search=" .. urlencode(search)
    end
    if search_by and search_by ~= "" then
        query = query .. "&searchBy=" .. urlencode(search_by)
    end

    local url = base_url .. "/browse?" .. query
    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false, "HTTP client unavailable"
    end

    local response, err = http.get(url, self:get_headers())
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

    local msg = "Failed to browse library (HTTP " .. tostring(code) .. ")"
    if callback then callback(false, msg) end
    return false, msg
end

function FolioAPI:list_books(page, limit, search, callback)
    local base_url = self:get_server_url()
    page = page or 1
    limit = limit or 20

    local query = string.format("page=%d&limit=%d", page, limit)
    if search and search ~= "" then
        query = query .. "&search=" .. urlencode(search)
    end

    local url = base_url .. "/books?" .. query
    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false, "HTTP client unavailable"
    end

    local response, err = http.get(url, self:get_headers())
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

function FolioAPI:get_book(book_id, callback)
    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id)

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false, "HTTP client unavailable"
    end

    local response, err = http.get(url, self:get_headers())
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

    local msg = "Failed to get book details (HTTP " .. tostring(code) .. ")"
    if callback then callback(false, msg) end
    return false, msg
end

function FolioAPI:get_series(search, callback)
    local base_url = self:get_server_url()
    local query = ""
    if search and search ~= "" then
        query = "?search=" .. urlencode(search)
    end
    local url = base_url .. "/series" .. query

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false, "HTTP client unavailable"
    end

    local response, err = http.get(url, self:get_headers())
    if not response then
        if callback then callback(false, tostring(err)) end
        return false, tostring(err)
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

    local msg = "Failed to get series list (HTTP " .. tostring(code) .. ")"
    if callback then callback(false, msg) end
    return false, msg
end

function FolioAPI:download_book(book_id, save_path, callback)
    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/download"

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false, "HTTP client unavailable"
    end

    logger.info("FolioSync API: downloading book " .. tostring(book_id) .. " to " .. tostring(save_path))
    local response, err = http.get(url, self:get_headers())
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
    local url = base_url .. "/books/" .. tostring(book_id) .. "/progress?format=xpointer"

    logger.info("FolioSync API: GET progress -> " .. url)

    local http = get_http_client()
    if not http then
        logger.warn("FolioSync API: GET progress failed - HTTP client unavailable")
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.get(url, self:get_headers())
    if not response then
        logger.warn("FolioSync API: GET progress network error: " .. tostring(err))
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    local body = response.body or response.content or ""

    if code >= 200 and code < 300 then
        local ok, data = pcall(json.decode, body)
        if ok and data then
            logger.info(string.format("FolioSync API: received progress for book %s (HTTP %s): %s",
                tostring(book_id), tostring(code), tostring(body)))
            if callback then callback(true, data) end
            return true, data
        end
    end

    logger.warn(string.format("FolioSync API: GET progress failed for book %s (HTTP %s): %s",
        tostring(book_id), tostring(code), tostring(body)))
    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

function FolioAPI:update_progress(book_id, location, progress_percent, is_read, callback)
    if type(is_read) == "function" and callback == nil then
        callback = is_read
        is_read = nil
    end

    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/progress?format=xpointer"

    local body_tab = {}
    if location ~= nil then
        body_tab.location = location
    end
    if progress_percent ~= nil then
        body_tab.progressPercent = progress_percent
    end
    if is_read ~= nil then
        body_tab.isRead = is_read
    end

    local payload = json.encode(body_tab)
    logger.info(string.format("FolioSync API: PUT progress -> %s, payload: %s", url, payload))

    local http = get_http_client()
    if not http then
        logger.warn("FolioSync API: PUT progress failed - HTTP client unavailable")
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.put(url, payload, self:get_headers())
    if not response then
        logger.warn("FolioSync API: PUT progress network error: " .. tostring(err))
        if callback then callback(false, tostring(err)) end
        return false
    end

    local code = response.code or response.status or 0
    local body = response.body or response.content or ""
    if code >= 200 and code < 300 then
        logger.info(string.format("FolioSync API: progress updated successfully for book %s (HTTP %s)",
            tostring(book_id), tostring(code)))
        if callback then callback(true) end
        return true
    end

    logger.warn(string.format("FolioSync API: PUT progress failed for book %s (HTTP %s): %s",
        tostring(book_id), tostring(code), tostring(body)))
    if callback then callback(false, "HTTP " .. tostring(code)) end
    return false
end

function FolioAPI:set_read_status(book_id, is_read, callback)
    return self:update_progress(book_id, nil, nil, is_read, callback)
end

function FolioAPI:list_annotations(book_id, since_or_cb, maybe_callback)
    local since
    local callback
    if type(since_or_cb) == "function" then
        callback = since_or_cb
    else
        since = since_or_cb
        callback = maybe_callback
    end

    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/annotations?format=xpointer"
    if since and since ~= "" then
        url = url .. "&since=" .. utils.url_encode(since)
    end

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.get(url, self:get_headers())
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
    local url = base_url .. "/books/" .. tostring(book_id) .. "/annotations?format=xpointer"

    local payload = json.encode({
        locationStart = annotation.locationStart or "",
        locationEnd = annotation.locationEnd or "",
        selectedText = annotation.selected_text or annotation.selectedText or "",
        note = annotation.note,
        color = annotation.color,
    })

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.post(url, payload, self:get_headers())
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
    local url = base_url ..
        "/books/" .. tostring(book_id) .. "/annotations/" .. tostring(annotation_id) .. "?format=xpointer"

    local payload = json.encode({
        locationStart = annotation.locationStart or "",
        locationEnd = annotation.locationEnd or "",
        selectedText = annotation.selected_text or annotation.selectedText or "",
        note = annotation.note,
        color = annotation.color,
    })

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.put(url, payload, self:get_headers())
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
    local url = base_url .. "/books/" .. tostring(book_id) .. "/annotations/" .. tostring(annotation_id)

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.delete(url, self:get_headers())
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

function FolioAPI:list_bookmarks(book_id, since_or_cb, maybe_callback)
    local since
    local callback
    if type(since_or_cb) == "function" then
        callback = since_or_cb
    else
        since = since_or_cb
        callback = maybe_callback
    end

    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/bookmarks?format=xpointer"
    if since and since ~= "" then
        url = url .. "&since=" .. utils.url_encode(since)
    end

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.get(url, self:get_headers())
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
    local url = base_url .. "/books/" .. tostring(book_id) .. "/bookmarks?format=xpointer"

    local payload = json.encode({
        location = bookmark.location or "",
        title = bookmark.title or "Bookmark",
    })

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.post(url, payload, self:get_headers())
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
    local url = base_url .. "/books/" .. tostring(book_id) .. "/bookmarks/" .. tostring(bookmark_id)

    local http = get_http_client()
    if not http then
        if callback then callback(false, "HTTP client unavailable") end
        return false
    end

    local response, err = http.delete(url, self:get_headers())
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
