# FolioSync for KOReader — Project Rules & Guidelines

Welcome to **FolioSync** (`FolioSync.koplugin`), an e-reader plugin for [KOReader](https://github.com/koreader/koreader) providing seamless integration with a self-hosted **[Folio](https://github.com/bastonta/folio)** digital library server. FolioSync enables bidirectional reading progress synchronization, highlight and annotation syncing, bookmark synchronization, and an interactive remote library browser to search, sort, and download books directly to e-ink devices.

This document serves as the single source of truth for architecture, conventions, and operational rules for human developers and AI assistants working in this repository.

---

## 1. Project Architecture & Directory Layout

FolioSync is designed as a standalone KOReader plugin written in **Lua 5.1 / LuaJIT**:

```text
FolioSync.koplugin/
├── _meta.lua                 # KOReader plugin metadata (name, fullname, version hook)
├── _version.lua              # Auto-generated release version file (overridden during packaging)
├── main.lua                  # Plugin entrypoint: settings, event dispatching, menu integration
├── manager.lua               # Document lifecycle coordinator: onDocumentOpen, onDocumentClose, sync triggers
├── folio_api.lua             # HTTP REST API client: X-API-Key auth, books, progress, annotations, stats
├── browser.lua               # Remote library browser UI: series tree, search, sorting, downloader
├── annotations.lua           # Converter between KOReader bookmark/highlight models & Folio REST format
├── menus.lua                 # KOReader Tools menu builder (⚙️ Settings, 📚 Browse, 🔄 Sync)
├── update_checker.lua        # In-app GitHub release updater & zip extractor
├── utils.lua                 # Common helpers: string sanitization, path joining, menu positioning
├── l10n/                     # Internationalization catalog (PO & compiled MO files)
│   ├── folio_sync.pot        # Extracted gettext template
│   ├── ru/                   # Russian translations (folio_sync.po, folio_sync.mo)
│   └── ...                   # Other language directories
├── spec/                     # Unit test suites executed with Busted
│   └── unit/
│       ├── folio_sync_spec.lua      # Extensive mocks & conversion/API/manager tests
│       └── update_checker_spec.lua  # Release parser & version comparison tests
├── Makefile                  # Build tasks: compile gettext translations & generate release zips
├── po2mo.py                  # Python script for compiling PO to MO without external gettext tools
├── .luacheckrc               # Luacheck linter configuration with KOReader global definitions
└── CHANGELOG.md              # Semantic release notes
```

---

## 2. Core Architectural & Synchronization Concepts

### A. Communication with Folio Server

- **Authentication**: Uses API keys via the `X-API-Key` HTTP request header, generated in the user's Folio profile.
- **HTTP Transport**: Uses LuaSocket (`socket.http` / `ssl.https`) with `ltn12` sinks and configurable timeouts via `socketutil`.
- **Location Conversion**:
  - KOReader natively identifies reading locations via **XPointers** (e.g. `/body/DocFragment[4]/body/div[1]/p[2]/text().15`).
  - Folio REST API accepts and converts locations via Canonical Folio Location (`cfl`) using the query parameter `?format=xpointer`.

### B. Reliable Book Matching & Snapshot State

- **SHA-256 Primary Hash**: Books are identified on the server by the SHA-256 checksum of the e-book file (`/api/library/books/by-hash/{sha256}`).
- **Title/Author Fallback**: If hash matching fails (e.g. file modified locally), fallback searching by title and primary author is used.
- **Snapshot State Tracking (`folio_sync_state.json`)**:
  - Stored inside the book's sidecar directory (`<book>.sdr/folio_sync_state.json`).
  - Records the last synced hash and snapshot of annotations/bookmarks to prevent redundant network requests and safely detect local vs. remote deletions without data loss.

### C. E-Ink Device Constraints & Defensive Programming

- **Never Block the Main UI Thread**: Long-running or network-bound tasks must yield or use non-blocking feedback (`InfoMessage` or `ConfirmBox`).
- **Pcall Wrapping**: Wrap all network calls, JSON decoding, and filesystem writes with `pcall` to ensure an API error or network drop never crashes KOReader.
- **Resource Conservation**: Avoid large temporary table allocations during page turns. Reading progress is throttled to avoid flooding the server on fast scanning.

---

## 3. Essential CLI Commands

Run commands from the repository root:

### Testing & Verification

```bash
# Run unit tests via Busted
busted spec/unit

# Run a specific test suite
busted spec/unit/folio_sync_spec.lua
```

### Localization & Build

```bash
# Compile Gettext PO files to MO
make mo
# or alternatively via python:
python3 po2mo.py

# Extract new strings from Lua files into l10n/folio_sync.pot
make pot

# Package release zip (creates build/FolioSync.koplugin.zip)
make release VERSION=v0.4.0
```

---

## 4. Coding Conventions & KOReader Environment

- **Lua 5.1 / LuaJIT Syntax**:
  - Do not use Lua 5.2+ features (e.g. `goto` without compat, `//` integer division, `~=` bitwise operators).
  - Use 4 spaces for indentation.
- **KOReader Globals**:
  - KOReader environment provides globals such as `UIManager`, `Dispatcher`, `DataStorage`, `gettext`, `G_reader_settings`, and `logger`.
  - When writing unit tests in `spec/`, mock these dependencies explicitly as shown in `spec/unit/folio_sync_spec.lua`.
- **Localization**:
  - All user-visible strings must be wrapped in `_("Your text here")` for Gettext translation.
  - Always re-run `make mo` after changing translation strings.

---

## 5. AI Assistant Operating Guidelines

When developing or modifying code in this repository:

1. **Verify with Busted**: Always run `busted spec/unit` after modifying any Lua file. Ensure all unit tests pass.
2. **Defensive Error Handling**: Always verify that unexpected HTTP status codes, nil values, or malformed JSON are handled gracefully without runtime exceptions.
3. **Translation Preservation**: Whenever adding new user-facing messages or dialogs, use `_("...")` and update `l10n/folio_sync.pot`.
4. **Preserve Comments & Docstrings**: Maintain existing function documentation and inline comments.
5. **Git Commit Style**: Use Conventional Commits with clear scopes:
   - `feat(browser): ...`, `fix(sync): ...`, `feat(manager): ...`, `fix(api): ...`, `chore(release): ...`.
6. **Releases & Versioning**: Update `CHANGELOG.md` following Keep a Changelog and use the `.agents/skills/release` skill when preparing releases and tagging (`vX.Y.Z`).
   - Follow **Variant 1 (Clean Release without `-dev` in Git)**: commit `CHANGELOG.md`, tag the release commit, and package release archives using `make release VERSION=vX.Y.Z`.
   - In source checkouts, `_version.lua` returns `"dev"` and UI indicates `Version: dev (Debug)`. Release packages have the clean version baked in by the Makefile without mutating git history.
