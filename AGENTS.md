# AGENTS.md — NativeGallery

Reference guide for AI agents working in this repository.

---

## Project Overview

**NativeGallery** is a native macOS desktop media gallery built with SwiftUI. It lets users browse, filter, and view photos and videos from their local file system. No web stack, no external dependencies — pure Apple frameworks.

- **Language:** Swift
- **UI Framework:** SwiftUI (with AppKit bridges via `NSViewRepresentable`)
- **Target:** macOS 13.0+
- **Architecture:** MVVM

---

## Directory Structure

```
nativeGallery/
├── Sources/
│   ├── App.swift           # App entry point (@main, WindowGroup)
│   ├── ContentView.swift   # Root layout: NavigationSplitView, sidebar, lightbox panel
│   ├── GalleryView.swift   # Grid display, thumbnail cells, lightbox, video players
│   └── Models.swift        # GalleryModel (ObservableObject), MediaItem, FolderNode
├── build/
│   └── NativeGallery.app/  # Compiled app bundle (do not edit)
├── Info.plist              # App metadata (bundle ID: com.thomas.NativeGallery)
├── build.sh                # Build script (swiftc, links AVKit + AVFoundation + CoreServices)
└── AGENTS.md               # This file
```

---

## Key Files

### [Sources/Models.swift](Sources/Models.swift)
The single source of truth for all state and business logic.

- **`GalleryModel`** — `@ObservableObject`. Owns `rootURL`, `mediaItems`, `isScanning`, filters, and folder tree.
  - `selectRootFolder()` — opens `NSOpenPanel`, starts FSEvent watcher, triggers initial scan
  - `scan(url:initialLoad:)` — async recursive file enumeration on a background thread. Uses a `scanGeneration` counter to discard results from superseded scans (prevents stale data overwriting a fresher result).
  - `startWatching(url:)` / `stopWatching()` — `FSEventStream` watcher via CoreServices. Fires a background rescan on any file system change with a 300ms coalescing window. Background rescans preserve current folder expansion state and auto-dismiss the lightbox if the open item is deleted.
  - `buildFolderTree()` — constructs nested `FolderNode` hierarchy from flat URL list
  - `filteredItems` — computed; applies type filter + search query + folder selection, sorts newest-first
  - `navigate(offset:)` — circular item navigation for lightbox
- **`MediaItem`** — struct with `url`, `type` (photo/video), `date`, `name`
- **`FolderNode`** — `Identifiable` + `Hashable` tree node for sidebar folder list
- **`FilterType`** — enum: `.all`, `.photos`, `.videos`

Supported file extensions scanned: `jpg jpeg png heic gif` (photo), `mp4 mov m4v avi` (video).

### [Sources/ContentView.swift](Sources/ContentView.swift)
Root view, sidebar, and lightbox panel management.

- **`ContentView`** — `NavigationSplitView` with sidebar + detail. Shows welcome / scanning / gallery states. Hosts keyboard shortcuts (ESC, ←/→, Space) that remain active while the lightbox is open because the main window stays key.
- **`LightboxPanelHost`** — `NSViewRepresentable` that manages a borderless `NSPanel` child window. The panel uses `.nonactivatingPanel` so the parent window stays key (preserving keyboard shortcuts) while the panel covers the full window including the macOS toolbar/titlebar. The coordinator updates the hosted `LightBoxView` on navigation and tears the panel down on dismiss.
- **`SidebarView`** — type filter picker, search field, recursive folder tree, item count, thumbnail size slider (pinned to bottom via `.safeAreaInset`), "Change Folder" button. Folder tree is expanded by default on initial load.
- **`RecursiveFolderView`** — renders nested `FolderNode` tree with `DisclosureGroup`, expansion state stored in `model.expandedFolders`.

### [Sources/GalleryView.swift](Sources/GalleryView.swift)
All visual components for the gallery.

- **`GalleryView`** — `LazyVGrid` with adaptive columns. Reads thumbnail size from `@AppStorage("nativeThumbSize")` (100–500 px). No header bar — count and slider live in the sidebar.
- **`MediaCell`** — async thumbnail via `QLThumbnailGenerator`; video hover preview via `NativeHoverVideoPlayer`.
- **`HoverVideoView`** — plain `NSView` using `AVPlayerLayer` directly (not `AVPlayerView`). Muted auto-play on hover. Overrides `scrollWheel` to forward events via `nextResponder` so gallery scrolling is unaffected. `AVPlayerView` was not used here because its internal subviews intercept scroll events even when subclassed.
- **`NativeHoverVideoPlayer`** — `NSViewRepresentable` wrapping `HoverVideoView`.
- **`LightBoxView`** — full-resolution image or `AVPlayer` video. Hosted inside the `LightboxPanelHost` NSPanel. Pauses video on dismiss (`onDisappear`) and on navigation to the next item (`onChange`). Close button and overlay tap both set `model.selectedItem = nil`, which the panel coordinator observes.
- **`NativeVideoPlayer`** — `NSViewRepresentable` wrapping `AVPlayerView` with floating controls for the lightbox.

### [Sources/App.swift](Sources/App.swift)
Minimal entry point. No title string passed to `WindowGroup` — title is hidden at runtime via `NSApp.mainWindow?.titleVisibility = .hidden`.

---

## Build

```bash
./build.sh
```

Compiles all `.swift` files in `Sources/` with `-O -whole-module-optimization`, links `AVKit`, `AVFoundation`, and `CoreServices`, and produces `build/NativeGallery.app`.

There is no Package.swift, Xcode project, CocoaPods, or npm. The build script is the only build artifact.

**Always recompile and relaunch after making changes:**
```bash
bash build.sh && open build/NativeGallery.app
```

---

## Frameworks Used

| Framework | Used For |
|-----------|----------|
| SwiftUI | All UI (views, state, layout) |
| Foundation | FileManager, URL, file attributes |
| Combine | `@Published`, `ObservableObject` reactive updates |
| AppKit | `NSViewRepresentable`, `NSOpenPanel`, `NSApp`, `NSPanel`, `NSWindow` |
| AVKit | `AVPlayerView` (lightbox video playback UI) |
| AVFoundation | `AVPlayer`, `AVPlayerLayer` (hover preview) |
| QuickLookThumbnailing | `QLThumbnailGenerator` (async thumbnails) |
| CoreServices | `FSEventStream` (live file system watching) |

No external packages or third-party dependencies.

---

## Architecture Notes

**MVVM pattern:**
- `GalleryModel` is both the Model and ViewModel — it holds data, drives file I/O, and exposes derived state (`filteredItems`, `folders`).
- Views are stateless consumers of `GalleryModel` via `@StateObject` / `@ObservedObject`.
- `@AppStorage("nativeThumbSize")` persists thumbnail size across sessions.

**Threading:**
- File scanning runs on a background `DispatchQueue`; results are published back on the main thread.
- A `scanGeneration` counter ensures only the most recent scan's results are applied.
- FSEvent callbacks are delivered on the main queue via `FSEventStreamSetDispatchQueue`.
- Thumbnail generation uses `QLThumbnailGenerator`'s async API.

**Lightbox panel architecture:**
- The lightbox is an `NSPanel` child window (`.borderless`, `.nonactivatingPanel`), not a SwiftUI overlay.
- This allows it to cover the macOS toolbar/titlebar, which SwiftUI `.overlay` cannot reach.
- The panel is managed by `LightboxPanelHost` (an `NSViewRepresentable` coordinator in `ContentView`).
- Because the panel is non-activating, the parent window stays key and keyboard shortcuts in `ContentView` continue to fire normally.

**UI hierarchy:**
```
NativeGalleryApp
└── ContentView (NavigationSplitView)
    ├── SidebarView
    │   └── RecursiveFolderView (× folders)
    └── GalleryView
        └── MediaCell (× N)
            └── NativeHoverVideoPlayer → HoverVideoView (video only)

LightboxPanelHost (NSPanel child window, managed from ContentView.background)
└── LightBoxView
    └── NativeVideoPlayer (video only)
```

---

## Common Tasks for Agents

**Add a new supported file extension:**
Edit `Models.swift` — `scan(url:initialLoad:)` method. Add the extension to the photo or video array.

**Add a new filter type:**
1. Add a case to `FilterType` in `Models.swift`
2. Update `filteredItems` computed property
3. Add the option to `SidebarView`'s segmented picker in `ContentView.swift`

**Change thumbnail behaviour:**
Edit `MediaCell` in `GalleryView.swift`. Thumbnail generation is in the `.task` modifier.

**Modify keyboard shortcuts:**
Edit the hidden `Button` shortcuts in `ContentView`'s `.background` block. Keep them there — do not add duplicate shortcuts inside `LightBoxView`.

**Change app metadata (version, bundle ID):**
Edit `Info.plist`.

---

## Constraints & Gotchas

- macOS-only. Do not introduce iOS/iPadOS APIs.
- The lightbox uses `NSPanel`, not a SwiftUI overlay — changes to lightbox layout go in `LightBoxView` in `GalleryView.swift`, but panel lifecycle is in `LightboxPanelHost` in `ContentView.swift`.
- Do not use `AVPlayerView` for the hover thumbnail — its internal subviews intercept scroll events. Use `AVPlayerLayer` in a plain `NSView` (`HoverVideoView`) instead.
- Keyboard shortcuts live in `ContentView.background`, not in `LightBoxView`. The lightbox panel is non-activating so the parent window (and its shortcuts) stays active.
- No sandbox entitlements are configured — the app reads arbitrary file system paths via user-selected folder. If sandbox entitlements are added later, `NSOpenPanel` security-scoped bookmarks will be required.
- `build.sh` does not do incremental compilation; it always recompiles all files.
