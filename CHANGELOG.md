# Changelog

All notable changes to the FolioSync KOReader plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-11-13

### Added
- **Reading books that have no EPUB file yet** (Folio `Chapters` kind): the library browser lists them (`📝`) and downloads them chapter by chapter, assembling a local EPUB with illustrations, cover and a table of contents (`chapters_book.lua`, `chapters_epub.lua`). Downloading a book that is already on the device updates it: only new and changed chapters are fetched, the rest is copied from the previous build. Progress is shown while downloading and the download can be cancelled.
- **📥 Update Book Chapters from Folio** in the document menu updates the open book and reopens it.
- After an update adds, removes or reorders chapters of a downloaded `Chapters` book, its reading percentage (`percent_finished`) is recomputed for the chapter being read (finishing chapter 100 of 100 becomes 50 % once 100 more arrive), a finished book with new chapters after the position goes back to "reading", and the corrected percentage is sent to the server right away, dated just after the server's row so a newer position from another device still wins. FolioReader computes the same.
- Reading progress of such books is exchanged with the server as a chapter reference (`ch:<chapterId>`, the form the Folio web reader uses): pushing sends the current chapter, pulling opens the chapter read elsewhere and keeps the precise local position when it is the same chapter. When chapters are inserted or reordered on the server, the stored position, annotations and bookmarks follow their chapters.
- **Downloading by volume**: a `Chapters` book with several volumes can be downloaded as the whole book or one volume at a time. The browser lists the volumes with their chapter counts and marks the copies already on the device; every volume is a file of its own (`<Title> - <Author> - Vol 03.epub`, titled `<Title> — Volume 3`, with the book as its series) that is updated independently, also through **📥 Update Book Chapters from Folio**.
- A volume copy syncs as a part of the book: the reading position is still the chapter (`ch:<chapterId>`), percentages and reading statistics are sent in whole-book scale, bookmarks and annotations are translated to and from whole-book positions (those of other volumes are left alone), and finishing a volume does not mark the book as read unless it is the last one.
- Assembled books are linked to their server book without hashing (`<book>.sdr/folio_chapters.json`, with the manifest inside the EPUB as a fallback).
- `FolioAPI.is_chapters_book` helper and API methods `list_chapters` (optionally of one volume), `list_volumes`, `get_chapter`, `get_book_image`, `get_book_cover`.
- Clear error message when `/books/{id}/download` answers `409 Conflict` for a `Chapters` book.
- Unit tests for the EPUB builder, incremental updates, position translation, book kind detection and catalog query parameters.

### Changed
- `list_books` (title fallback for matching local files) requests `kind=File`; `browse` lists books of every kind.
- Annotations and bookmarks are matched to their server items by id as well as by position.
- Requires a Folio server that lets API keys read chapters (`GET /books/{id}/chapters`); older servers answer `403` and the plugin says so.
- Downloading by volume needs a Folio server with `GET /books/{id}/volumes`; with an older server only the whole book is offered.

- **Reading position: the latest change wins.** The position is sent with the time it was read at and the server keeps a newer one; opening a book jumps to the server position only when it is the newer one. A device that comes online with an old position no longer overwrites what was read elsewhere, and going back in a book is synced like any other position (it used to be refused as "behind", while every opening threw the reader forward again). Device and server clocks are reconciled through the `Date` header of the server's answers. **Push All** / **Fetch All** force their direction. Needs a Folio server that orders progress by `updatedAt`; an older server is asked for its position before anything is sent.
- The read flag follows the same rule in both directions: a book marked unread elsewhere becomes unread on the device.
- Bookmarks and highlights are merged against a snapshot that only records what the server confirmed; the whole list is requested on every sync instead of "changes since" a time taken from the device clock. Highlights and bookmarks get their id on the device, so a request that is repeated creates nothing twice.
- Background sync is skipped while the network is off and pauses after the server failed to answer (30 s, growing to 10 min); request timeouts are 5 s / 15 s instead of 10 s / 30 s. Actions started by the user are always attempted.
- The title fallback for matching a local file accepts a search result only when title (and author, where known) are the same and it is the only such book. Books linked to a wrong server book by an earlier version stay linked: remove `folio_book_id` from the book's settings (or delete the `.sdr` folder) to match them again.
- Downloaded book files are written to `<name>.part` and put in place when complete. A second book with the same title and author is saved as `<Title> - <Author> (<id>).epub` instead of replacing the first.
- A long chapter download that loses its connection asks whether to try again and continues where it was, instead of starting over.

### Fixed
- `list_books` now paginates with `offset`/`limit` as the server expects instead of an ignored `page` parameter.
- Downloading a book file over a copy assembled from chapters relinks the file to the downloaded book.
- Page bookmarks were turned into highlights by the first sync (a `drawer` and a `color` were written into KOReader's own items): the bookmark corner disappeared and tapping it again added a duplicate. KOReader's items are no longer modified, and bookmarks damaged by earlier versions are repaired on the next sync.
- Progress in the first percent of a book was multiplied by 100 twice (page 4 of 600 was sent as 66.7%).
- Session and item ids are taken from the system's random source: the fallback generator repeated the same ids after every start of KOReader, and the server dropped those reading sessions as duplicates.
- A highlight or bookmark the server did not get was recorded as synced and never sent again; a deletion that failed was never repeated.
- Deletions and edits made in the web reader or another app never reached the device once a book had been synced.
- Two highlights of the same words were treated as one: the second was not sent and its colour and note overwrote the first.
- Highlights made in the first session with a book could disappear when anything was pulled from the server (the saved list was read instead of the reader's own, which was then replaced).
- A JSON `null` from the server (`color`, `note`, `title`) could end up in the book's settings as a value KOReader cannot save.
- Every event was handled twice (the plugin added itself to the reader's event chain, where KOReader had already put it).
- A book the server does not know was read and hashed in full on every sync — every 5 seconds while turning pages. The hash is cached, and such a book is left alone for 10 minutes.
- Resetting the sync snapshot also deleted reading sessions recorded offline.
- A reading session started when the device went to sleep, so reading in the morning was counted for the evening before; a session now starts on wake-up and ends with the last page turn.
- A failed or incomplete download (full disk, lost connection) could replace a good copy of a book and report success.
- A volume copy keeps its place in the book up to date (`GET /books/{id}/volumes`): the last volume downloaded no longer calls the book finished after another volume was added, and bookmarks and annotations are not shifted by a stale chapter count.
- An illustration the server does not have no longer turns every update of a `Chapters` book into a rebuild of the whole file; the number of missing illustrations is shown.
- A series named `..` could place a downloaded file outside the download folder.
- **✓ Mark as Read** in the library browser created empty `.sdr` folders for books that were not downloaded.
- An EPUB whose archive could not be finished (full disk) is not put in place of the previous build.
- XPointers that name a text node by number (`text()[2].15`) fall back to their paragraph when opening a server position.
- The update check ordered `beta.10` before `beta.2`.

## [0.4.0] - 2026-08-30

### Added
- Track and synchronize active reading sessions with Folio server, including duration, start/end progress, start/end time, and local pending session persistence across document close, suspend, and background auto-sync.
- New API methods `push_reading_sessions` and `get_book_statistics` in `folio_api`.
- Active reading timer with idle detection threshold (3 minutes) to pause tracking during inactivity.
- Log XPointer navigation errors to `xpointer_errors.txt` in the parent directory above the book/download folder for easy troubleshooting of remote position mismatches.
- Helper `utils.get_parent_dir` for resolving parent directories across platforms.
- Extended unit test suite for reading session tracking, dwell time calculations, API push, and XPointer error logging.

### Fixed
- Include elapsed dwell time on current page when finalizing reading sessions so reading without page turns or final page reading time is accurately counted.
- Initialize session start progress percentage correctly upon opening document in `onReaderReady`.
- Guard manager synchronization handlers across reader lifecycle events.

## [0.3.4] - 2026-08-30

### Fixed
- Remove `is_in_jump_stack` check in `onPageUpdate`, `onCloseDocument`, and `onSuspend` to allow automatic background reading progress sync after Table of Contents, bookmark, and link navigation (relying safely on Smart Jump Dwell Guard).

## [0.3.3] - 2026-08-28

### Added
- Protect reading progress during footnote, bookmark, and internal link jumps using navigation location stack detection (`ui.link.location_stack` and `ui.readerback.location_stack`).
- Smart Jump Dwell Guard: require a 45-second dwell time or 3 consecutive page turns on position jumps > 5% before syncing the new progress to server.
- Session self-correction in `Manager:sync_progress` allowing progress rollbacks if forward progress was pushed by the current reading session.
- Comprehensive unit tests covering jump suppression, dwell period, and self-correction in `spec/unit/folio_sync_spec.lua`.

### Fixed
- Prevent pushing transient jump positions on document close and device suspend events.

## [0.3.2] - 2026-08-28

### Added
- Support incremental annotations and bookmarks sync using `since` timestamp parameter.
- Instant push for notes and bookmarks on creation and modification.
- Centralized HTTP logging for outgoing request payloads and incoming server responses in `folio_api`.

### Fixed
- Prevent position snapback to remote reading position when navigating to bookmarks or earlier pages.
- Optimize sync flow on reader resume and document open.
- Fixed reading progress sync on book open and cleaned up luacheck warnings.

## [0.3.1] - 2026-08-28

### Fixed
- Correct GitHub API repository endpoint to `bastonta/FolioSync.koplugin`.
- Only display development version notice when `is_dev` is actually true.
- Unified version retrieval in settings menu via `UpdateChecker.getCurrentVersion()`.
- Added unit test coverage for non-dev version comparison.

## [0.3.0] - 2026-08-26

### Added
- Built-in update checker engine with GitHub Releases API integration.
- Non-blocking background update downloads and SemVer version comparisons.
- Release notes Markdown viewer with interactive link navigation in KOReader UI.
- Atomic plugin self-updating with backup creation, verification, and automatic rollback on failure.
- Manual update check button and 24h background auto-check toggle in Settings menu.
- Russian and English localization for all update dialogs and messages.
- Unit test suite for version parsing, comparison, and backup paths.

## [0.2.5] - 2026-08-26

### Added
- Automatic background sync on device sleep (`onSuspend`) for reading progress, annotations, and bookmarks.
- Automatic sync on device wake-up (`onResume`) with 1-second delay for Wi-Fi reconnection.
- Safe `ReaderUI` resolution across all lifecycle hooks.
- Unit tests for `onSuspend` and `onResume` lifecycle handlers in `spec/unit/folio_sync_spec.lua`.

## [0.2.4] - 2026-08-23

### Added
- MIT license.

### Changed
- Comprehensive README update with hierarchical series navigation, search targets, sorting, platform paths, dispatcher actions, and setup instructions.

## [0.2.3] - 2026-08-23

### Fixed
- Validate XPointer (`doc:isXPointerInDocument`) before jumping via `ui.link:onGotoLink` to avoid KOReader "Invalid or external link" error popup.
- Normalized candidate variant matching for XPointers (e.g. stripping trailing `/text().0` or `.0`).
- Seamless fallback to page-based and percentage-based navigation when XPointer cannot be resolved in DOM.
- Prevent jumping to book cover on invalid remote positions.

## [0.2.2] - 2026-08-23

### Added
- Automatic nested series and subseries folder hierarchy creation on book download (`create_series_folders` setting).
- Breadcrumb folder context matching when downloading inside series folders.
- Recursive directory creation helper `utils.ensure_dir` and path sanitization `utils.build_book_target_dir`.
- Registered `foliosync_toggle_series_folders` gesture dispatcher action.
- Settings checkbox and Library menu toggle for series folders.
- Updated POT template and Russian translations.

## [0.2.1] - 2026-08-14

### Added
- Support for toggling and syncing read/unread status with Folio server and KOReader metadata.
- Context menu options, API methods, and unit tests for read status.

## [0.2.0] - 2026-08-13

### Added
- Search functionality in Folio library browser.
- Pagination controls and modular navigation in FolioBrowser.

### Fixed
- UI race conditions and menu management improvements.
- CSpell dictionary additions and API call formatting.

## [0.1.1] - 2026-08-12

### Added
- Dynamic versioning support displaying plugin version in settings menu.
- Makefile release target for building clean plugin zip archives.

### Changed
- Updated default server URL and API endpoint handling.

## [0.1.0] - 2026-08-12

### Added
- Initial public release of FolioSync KOReader plugin.
- Two-way synchronization of reading progress, highlights, annotations, and bookmarks with Folio server.
- Hash-based book matching and remote library browsing.
- API Key authentication and secure HTTPS communication.
- Gesture dispatcher action integration aligned with KOSync patterns.
- Full localization support with Russian and English translations.
