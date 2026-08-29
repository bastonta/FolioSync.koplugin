# Changelog

All notable changes to the FolioSync KOReader plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
