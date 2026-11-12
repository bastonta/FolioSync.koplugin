local json = require("json")
local logger = require("logger")
local utils = require("utils")

local FolioAPI = {}

-- Folio stores complete e-book files (kind = "File") and books assembled from
-- chapters (kind = "Chapters"). The latter have no downloadable file: the plugin
-- builds a local EPUB from their chapters (see chapters_book.lua).
FolioAPI.BOOK_KIND_FILE = "File"
FolioAPI.BOOK_KIND_CHAPTERS = "Chapters"

-- Returns true when the book item (browse / list / detail response) has no
-- downloadable file. Items from older servers carry no `kind` and are files.
function FolioAPI.is_chapters_book(book)
    return type(book) == "table" and book.kind == FolioAPI.BOOK_KIND_CHAPTERS
end

local function urlencode(str)
    if not str then return "" end
    str = string.gsub(str, "\r?\n", "\r\n")
    str = string.gsub(str, "([^%w%-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

-- ================= NETWORK STATE =================
-- Requests are synchronous and run on the UI thread, so a server that does not answer
-- must cost as little as possible: short timeouts, no second request right after one
-- that failed, and a growing pause before background sync tries again.

-- Seconds to wait for a connection / between two chunks, and for a whole response
local API_BLOCK_TIMEOUT, API_TOTAL_TIMEOUT = 5, 15
-- Chapters, illustrations and book files: long-running downloads the user asked for
local BULK_BLOCK_TIMEOUT, BULK_TOTAL_TIMEOUT = 15, 120
-- After a network error every further request fails at once for this long: it covers
-- the rest of the sync that was running (each step would wait for its own timeout)
local FAIL_FAST_SECONDS = 3
-- Pause before background sync is tried again: doubles with every failure in a row
local BACKOFF_FIRST, BACKOFF_MAX = 30, 600

local net_state = {
    failures = 0,
    fail_fast_until = 0,
    retry_at = 0,
    -- Server clock minus device clock, in seconds; nil until a response told us
    clock_offset = nil,
}

local function note_network_failure()
    local now = os.time()
    net_state.failures = net_state.failures + 1
    local pause = BACKOFF_FIRST * 2 ^ math.min(net_state.failures - 1, 10)
    net_state.fail_fast_until = now + FAIL_FAST_SECONDS
    net_state.retry_at = now + math.min(pause, BACKOFF_MAX)
end

local function note_response(resp_headers)
    net_state.failures = 0
    net_state.fail_fast_until = 0
    net_state.retry_at = 0
    local date = type(resp_headers) == "table" and (resp_headers.date or resp_headers.Date) or nil
    local server_now = utils.parse_http_date(date)
    if server_now then
        net_state.clock_offset = server_now - os.time()
    elseif net_state.clock_offset == nil then
        -- No Date header to learn from: trust the device clock
        net_state.clock_offset = 0
    end
end

-- Decodes a JSON document. JSON `null` comes out of KOReader's decoder as a placeholder
-- value (not nil); it is dropped here so that it can never reach a book's settings file.
local function scrub_nulls(value)
    for key, item in pairs(value) do
        local kind = type(item)
        if kind == "table" then
            scrub_nulls(item)
        elseif kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
            value[key] = nil
        end
    end
    return value
end

local function decode_json(body)
    local ok, data = pcall(json.decode, body)
    if not ok then
        return false, data
    end
    if type(data) == "table" then
        scrub_nulls(data)
    elseif type(data) ~= "string" and type(data) ~= "number" and type(data) ~= "boolean" then
        data = nil
    end
    return true, data
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

    -- opts.quiet: bulk / binary request, keep it out of the info log
    -- opts.bulk: part of a long download (own retries, long timeouts, never fails fast)
    -- opts.sink: ltn12 sink that receives the response body instead of a string
    local function do_request(url, method, body, headers, opts)
        local quiet = opts and opts.quiet
        local bulk = opts and opts.bulk
        if not bulk and os.time() < net_state.fail_fast_until then
            return nil, "network unavailable"
        end

        local response_body = {}
        local sink = opts and opts.sink
        local request_params = {
            url    = url,
            method = method,
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
                if bulk then
                    socketutil:set_timeout(BULK_BLOCK_TIMEOUT, BULK_TOTAL_TIMEOUT)
                else
                    socketutil:set_timeout(API_BLOCK_TIMEOUT, API_TOTAL_TIMEOUT)
                end
            end
        end
        if not sink then
            -- socketutil's sink also enforces the total timeout
            if ok_su and socketutil and socketutil.table_sink then
                sink = socketutil.table_sink(response_body)
            else
                sink = ltn12.sink.table(response_body)
            end
        end
        request_params.sink = sink

        local http_driver = sockethttp
        if url and url:sub(1, 6):lower() == "https:" and ok_https and sslhttps then
            http_driver = sslhttps
        end

        if quiet then
            logger.dbg("FolioSync API: [HTTP " .. tostring(method or "GET") .. "]", url)
        else
            logger.info(string.format("FolioSync API: [HTTP %s] %s%s",
                method or "GET", url or "nil", body and (" payload=" .. tostring(body)) or ""))
        end

        local res, code, resp_headers
        if http_driver then
            local ok_call
            ok_call, res, code, resp_headers = pcall(http_driver.request, request_params)
            if not ok_call then
                res, code, resp_headers = nil, res, nil
            end
        end

        if ok_su and socketutil then
            if socketutil.reset_timeout then
                socketutil:reset_timeout()
            end
        end

        if res == nil then
            if not bulk then
                note_network_failure()
            end
            logger.warn(string.format("FolioSync API: [HTTP %s] %s -> NETWORK ERROR: %s",
                method or "GET", url or "nil", tostring(code)))
            return nil, tostring(code) -- code contains the error message on failure
        end
        note_response(resp_headers)

        local resp_str = table.concat(response_body)
        local status_num = tonumber(code) or 0
        if status_num >= 200 and status_num < 300 then
            if not quiet then
                logger.info(string.format("FolioSync API: [HTTP %s] %s -> HTTP %s (%d bytes)%s",
                    method or "GET", url or "nil", tostring(code), #resp_str,
                    #resp_str > 0 and (" response=" .. resp_str:sub(1, 500)) or ""))
            end
        elseif quiet then
            logger.warn(string.format("FolioSync API: [HTTP %s] %s -> HTTP %s",
                method or "GET", url or "nil", tostring(code)))
        else
            logger.warn(string.format("FolioSync API: [HTTP %s] %s -> HTTP %s: %s",
                method or "GET", url or "nil", tostring(code), resp_str:sub(1, 500)))
        end

        return {
            code = status_num,
            status = status_num,
            body = resp_str,
            content = resp_str,
            headers = resp_headers,
        }
    end

    function client.get(url, headers, opts)
        return do_request(url, "GET", nil, headers, opts)
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

-- Whether background sync should stay quiet for now: the last requests did not reach the
-- server, and the pause before the next attempt is not over.
function FolioAPI:in_backoff()
    return os.time() < net_state.retry_at
end

-- Forgets earlier network failures: the user asked for something, try right away.
function FolioAPI:reset_backoff()
    net_state.failures = 0
    net_state.fail_fast_until = 0
    net_state.retry_at = 0
end

-- Server clock minus device clock in seconds, learned from the `Date` header of the last
-- response; nil before the first response. Reading positions are compared by time, and
-- the clock of an e-reader is often wrong.
function FolioAPI:clock_offset()
    return net_state.clock_offset
end

-- Whether the server compares `updatedAt` of a pushed reading position with what it has
-- (it then answers with `applied`). nil until a position has been pushed.
function FolioAPI:conditional_progress()
    return net_state.conditional_progress
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
        local ok, data = decode_json(body)
        if ok and data then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if code == 404 then
        if callback then callback(false, "not_found", code) end
        return false, "not_found", code
    end

    local msg = "Failed to find book by hash (HTTP " .. tostring(code) .. ")"
    if callback then callback(false, msg, code) end
    return false, msg, code
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
        local ok, data = decode_json(body)
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

    -- The server paginates with offset/limit; `page` is 1-based here.
    -- Only File books: this list is used to match a local file by its title.
    local offset = math.max(0, (page - 1) * limit)
    local query = string.format("offset=%d&limit=%d&kind=%s", offset, limit, FolioAPI.BOOK_KIND_FILE)
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
        local ok, data = decode_json(body)
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
        local ok, data = decode_json(body)
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
        local ok, data = decode_json(body)
        if ok and type(data) == "table" then
            if callback then callback(true, data) end
            return true, data
        end
    end

    local msg = "Failed to get series list (HTTP " .. tostring(code) .. ")"
    if callback then callback(false, msg) end
    return false, msg
end

-- Puts `tmp_path` in place of `target_path`. Some filesystems refuse to rename over an
-- existing file: the old copy is then moved aside and put back if the new one still
-- cannot take its place.
local function replace_file(tmp_path, target_path)
    local ok, err = os.rename(tmp_path, target_path)
    if not ok and utils.file_exists(target_path) then
        local backup = target_path .. ".old"
        os.remove(backup)
        if os.rename(target_path, backup) then
            ok, err = os.rename(tmp_path, target_path)
            if ok then
                os.remove(backup)
            else
                os.rename(backup, target_path)
            end
        end
    end
    return ok and true or false, err
end

-- Downloads the file of a book to `save_path`. The body is streamed to a temporary file
-- next to the target, which takes the target's place only once it is complete: a failed
-- download (network, full disk) leaves the copy that was there untouched.
function FolioAPI:download_book(book_id, save_path, callback)
    local function done(ok, res)
        if callback then callback(ok, res) end
        return ok, res
    end

    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/download"

    local http = get_http_client()
    if not http then
        return done(false, "HTTP client unavailable")
    end

    local tmp_path = tostring(save_path) .. ".part"
    local handle = io.open(tmp_path, "wb")
    if not handle then
        return done(false, "Cannot write file to " .. tostring(save_path))
    end

    local written, write_err = 0, nil
    local function sink(chunk)
        if chunk and chunk ~= "" then
            local ok_write, err = handle:write(chunk)
            if not ok_write then
                write_err = tostring(err or "write failed")
                return nil, write_err
            end
            written = written + #chunk
        end
        return 1
    end

    local headers = self:get_headers()
    headers["Content-Type"] = nil
    headers["Accept"] = "*/*"
    local response, err = http.get(url, headers, { quiet = true, bulk = true, sink = sink })
    local closed, close_err = handle:close()
    if not closed and not write_err then
        -- Buffered data that did not fit on the disk is reported here
        write_err = tostring(close_err or "write failed")
    end

    if not response then
        os.remove(tmp_path)
        if write_err then
            return done(false, "Cannot write file to " .. tostring(save_path) .. ": " .. write_err)
        end
        return done(false, "Download failed: " .. tostring(err))
    end

    local code = response.code or response.status or 0
    if code == 409 then
        os.remove(tmp_path)
        -- Book assembled from chapters: the server has no file for it
        return done(false, "This book is assembled from chapters on the server and has no EPUB file")
    elseif code < 200 or code >= 300 then
        os.remove(tmp_path)
        return done(false, "Download failed (HTTP " .. tostring(code) .. ")")
    end

    local expected = type(response.headers) == "table"
        and tonumber(response.headers["content-length"] or response.headers["Content-Length"]) or nil
    if write_err then
        os.remove(tmp_path)
        return done(false, "Cannot write file to " .. tostring(save_path) .. ": " .. write_err)
    elseif written == 0 or (expected and expected ~= written) or utils.file_stat(tmp_path) ~= written then
        os.remove(tmp_path)
        return done(false, "Download failed: the file is incomplete")
    end

    local renamed, rename_err = replace_file(tmp_path, save_path)
    if not renamed then
        os.remove(tmp_path)
        return done(false, "Cannot write file to " .. tostring(save_path) .. ": " .. tostring(rename_err))
    end
    return done(true, save_path)
end

-- GET `path` (relative to the server URL) without touching the info log.
-- Returns true, body | false, message, http_code (code is nil on a network error).
-- `background`: asked by background sync, not by a download the user is waiting for —
-- short timeouts, and no attempt at all right after the network failed.
function FolioAPI:get_raw(path, accept, background)
    local http = get_http_client()
    if not http then
        return false, "HTTP client unavailable"
    end

    local headers = self:get_headers()
    headers["Content-Type"] = nil
    headers["Accept"] = accept or "*/*"

    local response, err = http.get(self:get_server_url() .. path, headers, { quiet = true, bulk = not background })
    if not response then
        return false, tostring(err)
    end

    local code = tonumber(response.code or response.status) or 0
    if code >= 200 and code < 300 then
        return true, response.body or response.content or ""
    end
    return false, "HTTP " .. tostring(code), code
end

-- Like get_raw, but decodes a JSON object / array response.
function FolioAPI:get_json(path, background)
    local ok, body, code = self:get_raw(path, "application/json", background)
    if not ok then
        return false, body, code
    end
    local ok_json, data = decode_json(body)
    if ok_json and type(data) == "table" then
        return true, data
    end
    return false, "Unexpected server response"
end

-- One page of the chapter list of a Chapters book (summaries without content),
-- in reading order: { items = {...}, more = bool, total = n }.
-- `volume` (optional) restricts the list to one volume; servers older than the volumes
-- feature ignore it, so callers filter the items again.
function FolioAPI:list_chapters(book_id, offset, limit, volume)
    local path = string.format("/books/%s/chapters?offset=%d&limit=%d",
        tostring(book_id), offset or 0, limit or 100)
    if tonumber(volume) then
        path = path .. "&volume=" .. string.format("%.7g", tonumber(volume))
    end
    return self:get_json(path)
end

-- Volumes of a Chapters book, in reading order:
-- { items = { { volume = n, chaptersCount = n, ... } }, chaptersTotal = n }.
-- Servers older than the volumes feature answer 403 (API key allow-list) or 404.
function FolioAPI:list_volumes(book_id, background)
    return self:get_json(string.format("/books/%s/volumes", tostring(book_id)), background)
end

-- A chapter with its content paragraphs.
function FolioAPI:get_chapter(book_id, chapter_id)
    return self:get_json(string.format("/books/%s/chapters/%s", tostring(book_id), tostring(chapter_id)))
end

-- Bytes of a chapter illustration (file names come from the chapter content).
function FolioAPI:get_book_image(book_id, filename)
    return self:get_raw(string.format("/books/%s/images/%s", tostring(book_id), urlencode(filename)))
end

-- Bytes of the book cover.
function FolioAPI:get_book_cover(book_id)
    return self:get_raw(string.format("/books/%s/cover", tostring(book_id)))
end

-- callback(true, data) | callback(false, message, http_code); the code is nil on a
-- network error and 404 when the server has no progress for the book.
function FolioAPI:get_progress(book_id, callback)
    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/progress?format=xpointer"

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
        local ok, data = decode_json(body)
        if ok and data then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
end

-- `opts.updated_at` (RFC 3339): when the position actually changed. A server that knows
-- the field keeps a newer position of its own and says so with `applied = false`; an
-- older server ignores the field and always writes.
-- callback(true, data) — data is the progress row as it is on the server now (nil when
-- the response carried none) — or callback(false, message, http_code).
function FolioAPI:update_progress(book_id, location, progress_percent, is_read, callback, opts)
    if type(is_read) == "function" and (callback == nil or type(callback) == "table") then
        opts = callback
        callback = is_read
        is_read = nil
    end

    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/progress?format=xpointer"

    local body_tab = {}
    -- An empty location means "no position": it is never sent
    if type(location) == "string" and location ~= "" then
        body_tab.location = location
    end
    if progress_percent ~= nil then
        body_tab.progressPercent = progress_percent
    end
    if is_read ~= nil then
        body_tab.isRead = is_read
    end
    if type(opts) == "table" and type(opts.updated_at) == "string" and opts.updated_at ~= "" then
        body_tab.updatedAt = opts.updated_at
    end

    local payload = json.encode(body_tab)

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
        local ok, data = decode_json(response.body or response.content or "")
        if not ok or type(data) ~= "table" then data = nil end
        if data and body_tab.updatedAt then
            net_state.conditional_progress = data.applied ~= nil
        end
        if callback then callback(true, data) end
        return true, data
    end

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
end

function FolioAPI:set_read_status(book_id, is_read, callback)
    return self:update_progress(book_id, nil, nil, is_read, callback)
end

function FolioAPI:push_reading_sessions(sessions, callback)
    if not sessions or #sessions == 0 then
        if callback then callback(true, { inserted = 0 }) end
        return true, { inserted = 0 }
    end

    local base_url = self:get_server_url()
    local url = base_url .. "/statistics/sessions"
    local payload = json.encode({ sessions = sessions })

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
    local body = response.body or ""
    if code >= 200 and code < 300 then
        local ok, data = decode_json(body)
        if ok and data then
            if callback then callback(true, data) end
            return true, data
        end
        if callback then callback(true) end
        return true
    end

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
end

function FolioAPI:get_book_statistics(book_id, callback)
    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/statistics"

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
    local body = response.body or ""
    if code >= 200 and code < 300 then
        local ok, data = decode_json(body)
        if ok and data then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
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
        local ok, data = decode_json(body)
        if ok and type(data) == "table" then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
end

function FolioAPI:create_annotation(book_id, annotation, callback)
    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/annotations?format=xpointer"

    local payload = json.encode({
        -- Generated on the device: a request that is sent twice creates one annotation
        id = utils.is_uuid(annotation.id) and annotation.id or nil,
        locationStart = annotation.locationStart or "",
        locationEnd = annotation.locationEnd or "",
        selectedText = annotation.selected_text or annotation.selectedText or "",
        note = (type(annotation.note) == "string" and annotation.note ~= "") and annotation.note or nil,
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
        local ok, data = decode_json(body)
        if ok and data then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
end

function FolioAPI:update_annotation(book_id, annotation_id, annotation, callback)
    local base_url = self:get_server_url()
    local url = base_url ..
        "/books/" .. tostring(book_id) .. "/annotations/" .. tostring(annotation_id) .. "?format=xpointer"

    local payload = json.encode({
        locationStart = annotation.locationStart or "",
        locationEnd = annotation.locationEnd or "",
        selectedText = annotation.selected_text or annotation.selectedText or "",
        -- An empty string clears the note on the server; a missing field leaves it alone
        note = type(annotation.note) == "string" and annotation.note or "",
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
        -- The annotation as it is on the server now (nil when the response carried none)
        local ok, data = decode_json(response.body or response.content or "")
        if not ok or type(data) ~= "table" then data = nil end
        if callback then callback(true, data) end
        return true, data
    end

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
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

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
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
        local ok, data = decode_json(body)
        if ok and type(data) == "table" then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
end

function FolioAPI:create_bookmark(book_id, bookmark, callback)
    local base_url = self:get_server_url()
    local url = base_url .. "/books/" .. tostring(book_id) .. "/bookmarks?format=xpointer"

    local payload = json.encode({
        -- Generated on the device: a request that is sent twice creates one bookmark
        id = utils.is_uuid(bookmark.id) and bookmark.id or nil,
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
        local ok, data = decode_json(body)
        if ok and data then
            if callback then callback(true, data) end
            return true, data
        end
    end

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
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

    if callback then callback(false, "HTTP " .. tostring(code), code) end
    return false, "HTTP " .. tostring(code), code
end

return FolioAPI
