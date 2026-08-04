# FolioSync for KOReader

**FolioSync** (`FolioSync.koplugin`) is a KOReader plugin that seamlessly integrates your e-reader device with a self-hosted **Folio** ebook server. It provides bidirectional synchronization for reading progress, annotations, highlights, and bookmarks, along with a built-in library browser to search and download books directly to your device.

---

## 🌟 Key Features

- **📚 Remote Library Browser & Downloader**
  - Search, filter (by series/author), and browse your remote Folio library.
  - Download books directly to your device's storage.

- **🔄 Automatic & Manual Progress Sync**
  - Automatically syncs your reading position and progress percentage on page turns or document closure.
  - Push or pull reading position on demand.

- **🖊️ Highlights & Annotation Sync**
  - Syncs highlights, notes, text annotations, and color metadata bidirectionally.
  - Accurate conversion between KOReader locations (XPointer / EpubCFI) and server formats.

- **🔖 Bookmark Synchronization**
  - Keep document bookmarks in sync between KOReader and Folio.

- **⚡ KOReader Dispatcher Support**
  - Map FolioSync commands to custom gestures, buttons, or hardware keys via KOReader's Dispatcher menu.

- **🌐 Multi-language Support (i18n)**
  - Localized UI with Gettext support (includes English and Russian translations).

---

## 📦 Installation

1. Copy or clone the `FolioSync.koplugin` directory into KOReader's `plugins/` folder on your device:
   - **Android**: `/sdcard/koreader/plugins/FolioSync.koplugin`
   - **Kindle / Kobo / PocketBook**: `koreader/plugins/FolioSync.koplugin`

2. Restart KOReader to load the plugin.

---

## ⚙️ Configuration

1. Open KOReader's main menu and navigate to **Tools** (`🛠️`) -> **Folio Sync & Library** -> **⚙️ Settings & Account**.
2. Configure the following fields:
   - **Server URL**: The base URL of your Folio server (e.g., `http://192.168.1.100:8080`).
   - **🔑 API Key**: Your user API key generated from your Folio user profile.
   - **Download Folder**: Path where downloaded books will be saved (default: `/sdcard/books/FolioSync`).
   - **Auto-sync Reading Progress**: Toggle background progress syncing.

---

## 🚀 Usage

### Browsing & Downloading Books

- Navigate to **Tools** -> **Folio Sync & Library** -> **📚 Browse & Download Books from Folio**.
- Search for titles or filter by series.
- Tap a book to download it directly to your designated download directory.

### Document Synchronization

While reading a document, access **Folio Sync & Library** from the document menu:

- **Push All Data of Active Document**: Upload local progress, highlights, and bookmarks to Folio.
- **Fetch All Data of Active Document**: Download server progress, highlights, and bookmarks.
- **Sync Active Document Annotations**: Perform a bidirectional merge of annotations.

### Gesture & Dispatcher Shortcuts

Bind shortcuts using KOReader's **Gesture Manager**:

- `FolioSync: Browse library`
- `FolioSync: Sync active document`
- `FolioSync: Push document data to server`
- `FolioSync: Pull document data from server`
- `FolioSync: Toggle auto progress sync`

---

## 🛠️ Translation & Development

### Building Localizations

Translation files are stored in the `l10n/` directory.

```bash
# Compile .po translation files into .mo binary files
make mo

# Re-generate the translation template (.pot)
make pot
```

Or use the python helper script:

```bash
python3 po2mo.py
```

---

## 📄 License

This project is licensed under the GNU General Public License v3.0 (GPL-3.0), matching KOReader's plugin licensing model.
