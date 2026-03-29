# NativeGallery

A native macOS media gallery app built with SwiftUI.

## Features

- Browse photos and videos from any local folder
- Thumbnail grid with adjustable size slider in the sidebar
- Live file system watching — media appears and disappears automatically as files change on disk
- Lightbox viewer rendered in a borderless overlay window, covering the full app including the toolbar
- Keyboard navigation (← → to browse, Esc to close, Space to play/pause)
- Video hover preview in the grid (scroll events pass through to the gallery)
- Recursive folder tree sidebar, expanded by default
- Filter by photos, videos, or search by filename
- Item count shown in the sidebar

## Requirements

- macOS 13+
- Xcode command-line tools (`xcode-select --install`)

## Build & Run

```bash
bash build.sh
open build/NativeGallery.app
```

## Project Structure

```
Sources/
  App.swift          — App entry point
  Models.swift       — Data models, scanning, filtering, FSEvent watching
  ContentView.swift  — Sidebar, folder tree, lightbox panel management
  GalleryView.swift  — Grid, thumbnail cells, lightbox, video playback
```
