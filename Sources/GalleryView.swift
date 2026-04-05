import SwiftUI
import QuickLookThumbnailing
import AVKit
import ImageIO

struct MediaGroup: Identifiable {
    let id: Date
    let items: [MediaItem]
}

struct GalleryView: View {
    @ObservedObject var model: GalleryModel
    @AppStorage("nativeThumbSize") private var thumbSize: Double = 200
    @State private var sizeAtGestureStart: Double? = nil

    private var groupedItems: [MediaGroup] {
        let items = model.isImportMode ? model.importItems : model.filteredItems
        let grouped = Dictionary(grouping: items) { item in
            Calendar.current.startOfDay(for: item.date)
        }
        return grouped.map { MediaGroup(id: $0.key, items: $0.value) }
            .sorted { $0.id > $1.id }
    }

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let gap: CGFloat = 16
            let colSize = CGFloat(thumbSize)
            
            // Calculate how many fixed-size columns + gaps fit
            let numCols = max(1, Int((availableWidth - gap) / (colSize + gap)))
            let gridWidth = CGFloat(numCols) * colSize + CGFloat(numCols - 1) * gap
            let sidePadding = (availableWidth - gridWidth) / 2
            
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(colSize), spacing: gap), count: numCols),
                    spacing: gap,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(groupedItems) { group in
                        Section(header: DayHeader(model: model, date: group.id, items: group.items)) {
                            ForEach(group.items) { item in
                                MediaCell(item: item, size: thumbSize, model: model)
                                    .onTapGesture {
                                        withAnimation {
                                            model.selectedItem = item
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(.leading, sidePadding)
                .padding(.trailing, sidePadding)
                .padding(.bottom, model.isImportMode ? 80 : 20)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isImportMode {
                ImportBar(model: model)
            }
        }
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    let base = sizeAtGestureStart ?? thumbSize
                    if sizeAtGestureStart == nil { sizeAtGestureStart = thumbSize }
                    thumbSize = min(max(base * value, 100), 500)
                }
                .onEnded { _ in
                    sizeAtGestureStart = nil
                }
        )
    }
}

struct MediaCell: View {
    let item: MediaItem
    let size: Double
    @ObservedObject var model: GalleryModel
    @State private var thumbnail: NSImage?
    @State private var isFailed = false
    @State private var isHovering = false
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipped()
                        .cornerRadius(8)
                } else if isFailed {
                    Rectangle()
                        .fill(Color(NSColor.windowBackgroundColor))
                        .frame(width: size, height: size)
                        .cornerRadius(8)
                        .overlay(Image(systemName: "exclamationmark.triangle").foregroundColor(.secondary))
                } else {
                    Rectangle()
                        .fill(Color(NSColor.windowBackgroundColor))
                        .frame(width: size, height: size)
                        .cornerRadius(8)
                        .overlay(ProgressView())
                }
                
                if item.type == .video && isHovering {
                    NativeHoverVideoPlayer(url: item.url)
                        .frame(width: size, height: size)
                        .cornerRadius(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.isImportMode {
                    Toggle("", isOn: Binding(
                        get: { model.selectedImportURIs.contains(item.url) },
                        set: { isSelected in
                            if isSelected {
                                model.selectedImportURIs.insert(item.url)
                            } else {
                                model.selectedImportURIs.remove(item.url)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .padding(4)
                }
            }
        }
        .onHover { hovering in
            self.isHovering = hovering
        }
        .task(id: "\(item.url)-\(Int(size / 50))", priority: .userInitiated) {
            // Scroll debouncing: don't start until we stay for 0.1s
            try? await Task.sleep(nanoseconds: 100_000_000)
            await generateThumbnail()
        }
    }
    
    func generateThumbnail() async {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let reqSize = CGSize(width: size, height: size)
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: reqSize, scale: scale, representationTypes: .thumbnail)
        do {
            let result = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            await MainActor.run {
                self.thumbnail = result.nsImage
            }
        } catch {
            await MainActor.run {
                self.isFailed = true
            }
        }
    }
}

struct DayHeader: View {
    @ObservedObject var model: GalleryModel
    let date: Date
    let items: [MediaItem]

    private var isAllSelected: Bool {
        items.allSatisfy { model.selectedImportURIs.contains($0.url) }
    }

    var body: some View {
        HStack {
            Text(date, style: .date)
                .font(.headline)
                .foregroundColor(.primary)
            
            Text("\(items.count) items")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
            
            if model.isImportMode {
                Button(isAllSelected ? "Deselect Day" : "Select Day") {
                    if isAllSelected {
                        items.forEach { model.selectedImportURIs.remove($0.url) }
                    } else {
                        items.forEach { model.selectedImportURIs.insert($0.url) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
        .background(.ultraThinMaterial)
    }
}

struct ImportBar: View {
    @ObservedObject var model: GalleryModel
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Importing \(model.selectedImportURIs.count) of \(model.importItems.count) items")
                        .font(.headline)
                    Text(model.importSourceURL?.path ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if !model.recentFolders.isEmpty {
                    Picker("To:", selection: $model.importDestinationURL) {
                        Text("New Folder (Auto)").tag(Optional<URL>.none)
                        Divider()
                        ForEach(model.recentFolders, id: \.self) { url in
                            Text(url.lastPathComponent).tag(Optional<URL>.some(url))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 250)
                    .disabled(model.isImporting)
                }

                if model.importDestinationURL == nil {
                    TextField("Folder Description", text: $model.importDescription)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .disabled(model.isImporting)
                }
                
                Toggle("Delete from Source", isOn: $model.deleteSourceAfterImport)
                    .toggleStyle(.checkbox)
                    .foregroundColor(.red)
                    .disabled(model.isImporting)
                
                Button("Cancel") {
                    model.cancelImport()
                }
                .buttonStyle(.bordered)
                .disabled(model.isImporting)
                
                Button(action: { model.performImport() }) {
                    if model.isImporting {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 4)
                    } else {
                        Text("Import Selected")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedImportURIs.isEmpty || model.isImporting)
            }
            .padding()
            .background(.ultraThinMaterial)
            
            if model.isImporting {
                ProgressView(value: model.importProgress)
                    .progressViewStyle(.linear)
            }
        }
    }
}

class HoverVideoView: NSView {
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        let p = AVPlayer(url: url)
        p.isMuted = true
        p.play()
        player = p
        let pl = AVPlayerLayer(player: p)
        pl.videoGravity = .resizeAspectFill
        layer?.addSublayer(pl)
        playerLayer = pl
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

    func stop() {
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        player = nil
        playerLayer = nil
    }

    // Don't consume scroll events — let the ScrollView handle them.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct NativeHoverVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> HoverVideoView {
        HoverVideoView(url: url)
    }

    func updateNSView(_ nsView: HoverVideoView, context: Context) {}

    static func dismantleNSView(_ nsView: HoverVideoView, coordinator: ()) {
        nsView.stop()
    }
}

struct LightBoxView: View {
    let item: MediaItem
    @ObservedObject var model: GalleryModel
    @State private var player: AVPlayer?
    @State private var lightboxImage: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Semi-transparent overlay backing
            Color.black.opacity(0.85).ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        model.selectedItem = nil
                    }
                }

            // Media Content
            if item.type == .photo {
                if let nsImage = lightboxImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            } else if item.type == .video {
                if let p = player {
                    NativeVideoPlayer(player: p)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            
            // Controls Layer
            VStack {
                HStack {
                    Button(action: { toggleMacFullscreen() }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.title2)
                            .padding(8)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Button(action: {
                        withAnimation {
                            model.selectedItem = nil
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .padding(8)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                Spacer()
            }
            
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onChange(of: item) { _, newValue in
            player?.pause()
            if newValue.type == .video {
                let p = AVPlayer(url: newValue.url)
                p.play()
                self.player = p
            } else {
                self.player = nil
            }
        }
        .task(id: item) {
            guard item.type == .photo else { return }
            lightboxImage = nil
            let url = item.url
            
            // Use CGImageSource for high-quality, memory-efficient loading
            let result = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCache: true,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096 // High-res target
                ]
                
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return NSImage(contentsOf: url) // Fallback
                }
                
                return NSImage(cgImage: cgImage, size: .zero)
            }.value

            await MainActor.run {
                self.lightboxImage = result
            }
        }
        .onAppear {
            if item.type == .video {
                let p = AVPlayer(url: item.url)
                p.play()
                self.player = p
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
    
    func toggleMacFullscreen() {
        if let window = NSApp.mainWindow {
            window.toggleFullScreen(nil)
        }
    }
}

struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect // Ensure perfect aspect ratio rendering
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        nsView.videoGravity = .resizeAspect
    }
}
