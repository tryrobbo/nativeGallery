# NativeGallery

A native macOS media gallery app built with SwiftUI.

## Features

- Browse photos and videos from any local folder
- Thumbnail grid with adjustable size
- Lightbox viewer with full-window overlay
- Keyboard navigation (← → to browse, Esc to close, Space to play/pause)
- Video hover preview in the grid
- Folder tree sidebar with recursive navigation
- Filter by photos, videos, or search by filename

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
  Models.swift       — Data models, scanning, filtering
  ContentView.swift  — Sidebar, folder tree, layout
  GalleryView.swift  — Grid, lightbox, video playback
```
