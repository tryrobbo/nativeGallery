import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var model = GalleryModel()
    @AppStorage("nativeThumbSize") private var thumbSize: Double = 200

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            if model.rootURL == nil {
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 80))
                        .foregroundColor(.secondary)
                    Text("Welcome to NativeGallery")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Button("Select Media Folder") {
                        model.selectRootFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else if model.isScanning {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Scanning Media...")
                        .foregroundColor(.secondary)
                }
            } else {
                GalleryView(model: model)
                    .id(model.isImportMode ? "import" : "library")
            }
        }
        .toolbar(.hidden, for: .windowToolbar)
        .onAppear {
            DispatchQueue.main.async {
                NSApp.mainWindow?.titleVisibility = .hidden
                NSApp.mainWindow?.title = ""
            }
        }
        .background {
            // Hosts the lightbox in a borderless NSPanel child window so it covers
            // the full window including the macOS toolbar/titlebar.
            LightboxPanelHost(selectedItem: model.selectedItem, model: model)

            Button(action: { thumbSize = min(thumbSize + 25, 500) }) { EmptyView() }
                .keyboardShortcut("=", modifiers: .command)
            Button(action: { thumbSize = max(thumbSize - 25, 100) }) { EmptyView() }
                .keyboardShortcut("-", modifiers: .command)

            if model.selectedItem != nil {
                Button(action: { model.selectedItem = nil }) { EmptyView() }.keyboardShortcut(.escape, modifiers: [])
                Button(action: { model.navigate(offset: -1) }) { EmptyView() }.keyboardShortcut(.leftArrow, modifiers: [])
                Button(action: { model.navigate(offset: 1) }) { EmptyView() }.keyboardShortcut(.rightArrow, modifiers: [])
                Button(action: { model.togglePlayPause() }) { EmptyView() }.keyboardShortcut(.space, modifiers: [])
            }
        }
    }
}

// Manages a transparent, borderless NSPanel child window that sits above all window
// chrome (toolbar, titlebar) — something a SwiftUI .overlay cannot reach.
private struct LightboxPanelHost: NSViewRepresentable {
    let selectedItem: MediaItem?
    @ObservedObject var model: GalleryModel

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Defer so the window hierarchy is fully settled before we access it.
        DispatchQueue.main.async {
            context.coordinator.update(selectedItem: self.selectedItem, parentWindow: NSApp.mainWindow ?? nsView.window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    class Coordinator: NSObject {
        let model: GalleryModel
        private var panel: NSPanel?
        private var hostingController: NSHostingController<LightBoxView>?

        init(model: GalleryModel) { self.model = model }

        func update(selectedItem: MediaItem?, parentWindow: NSWindow?) {
            if let item = selectedItem {
                if let panel = panel {
                    // Update content when navigating to a different item.
                    hostingController?.rootView = LightBoxView(item: item, model: model)
                    if let parent = panel.parent {
                        panel.setFrame(parent.frame, display: false)
                    }
                } else if let parent = parentWindow {
                    show(item: item, in: parent)
                }
            } else {
                hide()
            }
        }

        private func show(item: MediaItem, in parent: NSWindow) {
            let panel = NSPanel(
                contentRect: parent.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovable = false
            panel.acceptsMouseMovedEvents = true
            // Stay visible in fullscreen and all Spaces.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let hc = NSHostingController(rootView: LightBoxView(item: item, model: model))
            panel.contentViewController = hc
            parent.addChildWindow(panel, ordered: .above)
            // Explicitly match the parent frame after insertion — the init contentRect
            // may not reflect the fully-settled window size.
            panel.setFrame(parent.frame, display: true)

            self.panel = panel
            self.hostingController = hc
        }

        private func hide() {
            if let panel = panel {
                panel.parent?.removeChildWindow(panel)
                panel.close()
            }
            panel = nil
            hostingController = nil
        }
    }
}

struct RecursiveFolderView: View {
    let folders: [FolderNode]
    @ObservedObject var model: GalleryModel

    var body: some View {
        ForEach(folders) { folder in
            if let children = folder.children, !children.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { model.expandedFolders[folder.id] ?? false },
                        set: { model.expandedFolders[folder.id] = $0 }
                    )
                ) {
                    RecursiveFolderView(folders: children, model: model)
                } label: {
                    folderLabel(for: folder)
                }
            } else {
                folderLabel(for: folder)
            }
        }
    }

    @ViewBuilder
    private func folderLabel(for folder: FolderNode) -> some View {
        Button(action: { 
            model.selectedFolderID = folder.id
            model.selectedAlbum = nil
        }) {
            Label(folder.name, systemImage: "folder")
        }
        .buttonStyle(.plain)
        .foregroundColor(model.selectedFolderID == folder.id ? .accentColor : .primary)
        .padding(.vertical, 2)
    }
}

struct SidebarView: View {
    @ObservedObject var model: GalleryModel

    var body: some View {
        List {
            Section {
                Button(action: {
                    model.startImport()
                }) {
                    Label("Import from Camera/Folder...", systemImage: "arrow.down.doc.fill")
                }
                .buttonStyle(.plain)
                .controlSize(.large)
            }

            Section(header: Text("Filters").font(.caption).foregroundColor(.secondary)) {
                Picker("Type", selection: $model.currentFilter) {
                    ForEach(GalleryModel.FilterType.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 8)

                TextField("Search files...", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
            }

            if !model.albums.isEmpty {
                Section(header: Text("Albums").font(.caption).foregroundColor(.secondary)) {
                    ForEach(model.albums.keys.sorted(), id: \.self) { album in
                        Button(action: {
                            model.selectedAlbum = album
                            model.selectedFolderID = nil
                        }) {
                            Label(album, systemImage: "rectangle.stack")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(model.selectedAlbum == album ? .accentColor : .primary)
                        .padding(.vertical, 2)
                    }
                }
            }

            if !model.folders.isEmpty {
                Section(header: Text("Folders").font(.caption).foregroundColor(.secondary)) {
                    Button(action: { 
                        model.selectedFolderID = nil 
                        model.selectedAlbum = nil
                    }) {
                        Label("All Media", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(model.selectedFolderID == nil && model.selectedAlbum == nil ? .accentColor : .primary)
                    .padding(.vertical, 2)

                    RecursiveFolderView(folders: model.folders, model: model)
                }
            }

            Section {
                Button(action: {
                    model.selectRootFolder()
                }) {
                    Label("Change Root Folder...", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Divider()
                HStack {
                    Text("\(model.filteredItems.count) items")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}
