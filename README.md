# FolioSync for KOReader

**FolioSync** (`FolioSync.koplugin`) is a KOReader plugin that seamlessly integrates your e-reader device with a self-hosted **[Folio](https://github.com/bastonta/folio)** ebook server. It provides bidirectional synchronization for reading progress, annotations, highlights, and bookmarks, along with a built-in library browser to search, sort, and download books directly to your device.

---

## 🌟 Key Features

- **📚 Remote Library Browser & Downloader**
  - **Hierarchical Series Navigation**: Browse standalone books and series folders with intuitive breadcrumb navigation.
  - **Advanced Search**: Search across your library with scoped targets (**All fields**, **Book Titles**, **Authors**, or **Series Names**).
  - **Sorting**: Sort library items by **Name**, **Recently Added**, or **Series Order** (`sortOrder`).
  - **Automatic Series Folders**: Automatically organize downloaded books into nested series directories (`<download_dir>/<Series>/<Subseries>/<Title> - <Author>.epub`).
  - **Flexible Download Paths**: Download directly to your configured default folder or pick a custom folder per book.
  - **Instant Reading & Refresh**: Prompt to open downloaded books immediately upon completion, with automatic File Manager refresh.
  - **Read / Unread Management**: Mark books as read or unread directly from the browser (with `✅` and `📖` status indicators).

- **🔄 Reading Progress & Status Sync**
  - **Automatic Progress Sync**: Automatically syncs reading position and progress percentage in the background on page turns (throttled) and on document close.
  - **On-Demand Sync**: Push or pull reading position on demand via the document menu or dispatcher gestures.
  - **Read Status Synchronization**: Synchronize finished / read status between your device and Folio server.
  - **Precise Location Mapping**: Accurate conversion between KOReader locations (XPointers, EpubCFI, page numbers) and server formats.

- **🖊️ Highlights & Annotation Sync**
  - **Bidirectional Merge**: Syncs text highlights, notes, and color metadata bidirectionally between KOReader and Folio.
  - **Snapshot State Tracking**: Tracks sync state snapshot in `<book>.sdr/folio_sync_state.json` to reliably handle remote and local deletions without data loss.
  - **Robust Book Matching**: Identifies books primarily via SHA-256 file hash matching with metadata fallback (title/author).

- **🔖 Bookmark Synchronization**
  - Keeps document bookmarks in sync between KOReader and Folio.

- **⚡ KOReader Dispatcher & Gesture Integration**
  - Full integration with KOReader's Dispatcher and Gesture Manager to bind actions to hardware buttons, taps, multi-swipes, or quick menus.

- **🌐 Multi-Language Support (i18n)**
  - Localized UI with Gettext support (includes English and Russian translations).

---

## 📦 Installation

### Option 1: Pre-built Release (Recommended)

1. Download the latest `FolioSync-v*.zip` from GitHub Releases.
2. Extract the archive into KOReader's `plugins/` directory on your device.
3. Restart KOReader.

### Option 2: From Source / Git Clone

1. Clone or copy the repository into KOReader's `plugins/` folder:
   ```bash
   cd /path/to/koreader/plugins
   git clone https://github.com/bastonta/FolioSync.koplugin.git
   ```
2. Compile translations:
   ```bash
   cd FolioSync.koplugin
   make mo
   # or: python3 po2mo.py
   ```
3. Restart KOReader.

### Platform-Specific Plugin Directories

| Platform                       | Path                                                   |
| ------------------------------ | ------------------------------------------------------ |
| **Android**                    | `/sdcard/koreader/plugins/FolioSync.koplugin`          |
| **Kindle**                     | `/mnt/us/koreader/plugins/FolioSync.koplugin`          |
| **Kobo**                       | `/.kobo/koreader/plugins/FolioSync.koplugin`           |
| **PocketBook**                 | `/mnt/ext1/system/koreader/plugins/FolioSync.koplugin` |
| **reMarkable / Linux Desktop** | `~/.config/koreader/plugins/FolioSync.koplugin`        |

---

## ⚙️ Configuration

1. Open KOReader's main menu and navigate to **Tools** (`🛠️`) -> **Folio Sync & Library** -> **⚙️ Settings & Account**.
2. Configure the following settings:

| Setting                                 | Description                                                                                                                                                                                         | Default                     |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| **Server URL**                          | Base URL of your Folio API endpoint (e.g. `http://192.168.1.100:5144/api` or `https://folio.example.com/api`). _Note: Include `/api` prefix if your Folio backend routes are mounted under `/api`._ | `http://192.168.1.100:8080` |
| **API Key**                             | User API key generated from your Folio user profile (`X-API-Key` authentication).                                                                                                                   | _Empty_                     |
| **Download Folder**                     | Default device path where downloaded books will be saved.                                                                                                                                           | `/sdcard/books/FolioSync`   |
| **Automatically Create Series Folders** | Create nested subfolders for series when downloading books.                                                                                                                                         | `Enabled`                   |
| **Auto-sync Reading Progress**          | Automatically sync reading progress in background on page turns and document close.                                                                                                                 | `Disabled`                  |
| **Version**                             | Shows installed version of the plugin.                                                                                                                                                              | `dev` / release tag         |

---

## 🚀 Usage

### 📚 Library Browser & Downloading Books

- Navigate to **Tools** (`🛠️`) -> **Folio Sync & Library** -> **📚 Browse & Download Books from Folio** (or trigger via gesture/dispatcher).
- **Navigation**: Tap a series folder (`📁 [Series] ...`) to enter its hierarchy. Tap `📁 .. (Back)` to navigate up.
- **Search & Sort**: Tap the top-left menu icon (`☰`):
  - **Search Library**: Enter a search query.
  - **Search Target**: Filter search by _All fields_, _Book Titles_, _Authors_, or _Series Names_.
  - **Sort**: Sort by _Name_, _Recently Added_, or _Series Order_.
  - **Series Folders**: Toggle automatic series folder creation on the fly.
- **Book Actions**: Tap on any book to:
  - Download to the default download folder.
  - Download to a custom selected folder.
  - Mark book as Read or Unread on Folio.
- **Open Immediately**: After download finishes, confirm to open the book directly in KOReader.

### 🔄 Document Synchronization

While reading an open document, access **Folio Sync & Library** from the document menu:

- **📤 Push All Data of Active Document**: Upload local progress, highlights, and bookmarks to Folio.
- **📥 Fetch All Data of Active Document**: Download server progress, highlights, and bookmarks from Folio.
- **🔄 Sync Active Document Annotations**: Perform a bidirectional merge of annotations and bookmarks.
- **✓ Toggle Read Status on Folio**: Toggle read/unread status on Folio and update local reading status.

### ⚡ Gesture & Dispatcher Actions

You can assign FolioSync commands to hardware buttons, taps, or gestures via KOReader's **Gesture Manager** / **Dispatcher**:

| Action Name                                 | Event / Action ID                 | Context | Description                                |
| ------------------------------------------- | --------------------------------- | ------- | ------------------------------------------ |
| `FolioSync: Browse library`                 | `foliosync_browse`                | General | Open remote Folio library browser          |
| `FolioSync: Sync active document`           | `foliosync_sync_doc`              | Reader  | Bidirectional sync of active document      |
| `FolioSync: Push document data to server`   | `foliosync_push_doc`              | Reader  | Push progress & annotations to Folio       |
| `FolioSync: Pull document data from server` | `foliosync_pull_doc`              | Reader  | Pull progress & annotations from Folio     |
| `FolioSync: Toggle read / finished status`  | `foliosync_toggle_read`           | Reader  | Toggle read status on server & device      |
| `FolioSync: Toggle auto progress sync`      | `foliosync_toggle_autosync`       | General | Toggle background auto-sync on/off         |
| `FolioSync: Set auto progress sync`         | `foliosync_set_autosync`          | General | Explicitly enable or disable auto-sync     |
| `FolioSync: Toggle create series folders`   | `foliosync_toggle_series_folders` | General | Toggle automatic series subfolder creation |

---

## 🛠️ Development & Localization

### Translation Workflow

Translations are stored in the `l10n/` directory.

```bash
# Compile .po translation files into .mo binary files
make mo

# Re-generate the translation template (.pot) from Lua source code
make pot

# Alternatively, compile using Python without gettext CLI tools
python3 po2mo.py
```

### Building Release Package

To create a clean release archive (`build/FolioSync.koplugin.zip`):

```bash
make release VERSION="v1.0.0"
```

### Running Unit Tests

Unit tests are written using Busted:

```bash
busted spec/unit/
```

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
