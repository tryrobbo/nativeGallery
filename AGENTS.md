# AGENTS.md — NativeGallery

Reference guide for AI agents working in this repository.

---

## Project Overview

**NativeGallery** is a native macOS desktop media gallery built with SwiftUI. It lets users browse, filter, and view photos and videos from their local file system. No web stack, no external dependencies — pure Apple frameworks.

- **Language:** Swift
- **UI Framework:** SwiftUI (with AppKit bridges via `NSViewRepresentable`)
- **Target:** macOS 12.0+
- **Architecture:** MVVM

---

## Directory Structure

```
nativeGallery/
├── Sources/
│   ├── App.swift           # App entry point (@main, WindowGroup)
│   ├── ContentView.swift   # Root layout: NavigationSplitView, sidebar, lightbox overlay
│   ├── GalleryView.swift   # Grid display, thumbnail cells, lightbox, video players
│   └── Models.swift        # GalleryModel (ObservableObject), MediaItem, FolderNode
├── build/
│   └── NativeGallery.app/  # Compiled app bundle (do not edit)
├── Info.plist              # App metadata (bundle ID: com.thomas.NativeGallery)
├── build.sh                # Build script (swiftc, links AVKit + AVFoundation)
└── AGENTS.md               # This file
```

---

## Key Files

### [Sources/Models.swift](Sources/Models.swift)
The single source of truth for all state and business logic.

- **`GalleryModel`** — `@ObservableObject`. Owns `rootURL`, `mediaItems`, `isScanning`, filters, and folder tree.
  - `selectRootFolder()` — opens `NSOpenPanel`
  - `scan(url:)` — async recursive file enumeration on a background thread
  - `buildFolderTree()` — constructs nested `FolderNode` hierarchy from flat URL list
  - `filteredItems` — computed; applies type filter + search query + folder selection, sorts newest-first
  - `navigate(offset:)` — circular item navigation for lightbox
- **`MediaItem`** — struct with `url`, `type` (photo/video), `date`, `name`
- **`FolderNode`** — `Identifiable` + `Hashable` tree node for sidebar folder list
- **`FilterType`** — enum: `.all`, `.photos`, `.videos`

Supported file extensions scanned: `jpg jpeg png heic gif` (photo), `mp4 mov m4v avi` (video).

### [Sources/ContentView.swift](Sources/ContentView.swift)
Root view and sidebar.

- **`ContentView`** — `NavigationSplitView` with sidebar + detail. Shows welcome / scanning / gallery states. Hosts lightbox overlay with keyboard shortcuts (ESC, ←/→, Space).
- **`SidebarView`** — type filter picker, search field, recursive folder tree, "Change Folder" button.

### [Sources/GalleryView.swift](Sources/GalleryView.swift)
All visual components for the gallery.

- **`GalleryView`** — `LazyVGrid` with adaptive columns. Reads thumbnail size from `@AppStorage("nativeThumbSize")` (100–500 px).
- **`MediaCell`** — async thumbnail via `QLThumbnailGenerator`; video hover preview via `NativeHoverVideoPlayer`.
- **`NativeHoverVideoPlayer`** — `NSViewRepresentable` wrapping `AVPlayerView`; muted auto-play on hover.
- **`LightBoxView`** — full-screen overlay; full-resolution image or video, fullscreen toggle, close button.
- **`NativeVideoPlayer`** — `NSViewRepresentable` wrapping `AVPlayerView` with floating controls.

### [Sources/App.swift](Sources/App.swift)
10-line entry point. Nothing to modify here unless changing the window title or adding scenes.

---

## Build

```bash
./build.sh
```

Compiles all `.swift` files in `Sources/` with `-O -whole-module-optimization`, links `AVKit` and `AVFoundation`, and produces `build/NativeGallery.app`.

There is no Package.swift, Xcode project, CocoaPods, or npm. The build script is the only build artifact.

---

## Frameworks Used

| Framework | Used For |
|-----------|----------|
| SwiftUI | All UI (views, state, layout) |
| Foundation | FileManager, URL, file attributes |
| Combine | `@Published`, `ObservableObject` reactive updates |
| AppKit | `NSViewRepresentable`, `NSOpenPanel`, `NSApp`, `NSColor` |
| AVKit | `AVPlayerView` (video playback UI) |
| AVFoundation | `AVPlayer`, `AVPlayerItem` |
| QuickLookThumbnailing | `QLThumbnailGenerator` (async thumbnails) |

No external packages or third-party dependencies.

---

## Architecture Notes

**MVVM pattern:**
- `GalleryModel` is both the Model and ViewModel — it holds data, drives file I/O, and exposes derived state (`filteredItems`, `folders`).
- Views are stateless consumers of `GalleryModel` via `@StateObject` / `@ObservedObject`.
- `@AppStorage("nativeThumbSize")` persists thumbnail size across sessions.

**Threading:**
- File scanning runs on a background `DispatchQueue`; results are published back on the main thread via `@Published`.
- Thumbnail generation uses `QLThumbnailGenerator`'s async completion handler.

**UI hierarchy:**
```
NativeGalleryApp
└── ContentView (NavigationSplitView)
    ├── SidebarView
    └── GalleryView
        ├── MediaCell (× N)
        │   └── NativeHoverVideoPlayer (video only)
        └── LightBoxView (modal overlay)
            └── NativeVideoPlayer (video only)
```

---

## Common Tasks for Agents

**Add a new supported file extension:**
Edit `Models.swift` — `scan(url:)` method. Add the extension to the photo or video array used to classify `MediaItem.type`.

**Add a new filter type:**
1. Add a case to `FilterType` in `Models.swift`
2. Update `filteredItems` computed property
3. Add the option to `SidebarView`'s segmented picker in `ContentView.swift`

**Change thumbnail behavior:**
Edit `MediaCell` in `GalleryView.swift`. Thumbnail generation is in the `.task` modifier on the cell.

**Modify keyboard shortcuts:**
Edit the `.onKeyPress` / `NSEvent` handlers in `ContentView.swift`'s `LightBoxView` presentation block.

**Change app metadata (version, bundle ID):**
Edit `Info.plist`.

---

## Constraints & Gotchas

- This is macOS-only. Do not introduce iOS/iPadOS APIs.
- `NSViewRepresentable` wrappers (`NativeHoverVideoPlayer`, `NativeVideoPlayer`) are required because SwiftUI's `VideoPlayer` lacks the control granularity needed (muted hover, floating controls).
- No sandbox entitlements are configured — the app reads arbitrary file system paths via user-selected folder. If sandbox entitlements are added later, `NSOpenPanel` security-scoped bookmarks will be required.
- `build.sh` does not do incremental compilation; it always recompiles all files.
