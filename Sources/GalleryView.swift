import SwiftUI
import QuickLookThumbnailing
import AVKit

struct GalleryView: View {
    @ObservedObject var model: GalleryModel
    @AppStorage("nativeThumbSize") private var thumbSize: Double = 200

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize))], spacing: 16) {
                ForEach(model.filteredItems) { item in
                    MediaCell(item: item, size: thumbSize)
                        .onTapGesture {
                            withAnimation {
                                model.selectedItem = item
                            }
                        }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}

struct MediaCell: View {
    let item: MediaItem
    let size: Double
    @State private var thumbnail: NSImage?
    @State private var isFailed = false
    @State private var isHovering = false
    
    var body: some View {
        VStack {
            ZStack {
                if item.type == .video && isHovering {
                    NativeHoverVideoPlayer(url: item.url)
                        .frame(width: size, height: size)
                        .cornerRadius(8)
                } else if let thumb = thumbnail {
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
                
                if item.type == .video && !isHovering {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: size * 0.2))
                        .foregroundColor(.white.opacity(0.8))
                        .shadow(radius: 2)
                }
            }
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size)
        }
        .onHover { hovering in
            self.isHovering = hovering
        }
        .task(id: item.url) {
            await generateThumbnail()
        }
    }
    
    func generateThumbnail() async {
        let reqSize = CGSize(width: size * 2, height: size * 2) 
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: reqSize, scale: 2.0, representationTypes: .thumbnail)
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
}

struct LightBoxView: View {
    let item: MediaItem
    @ObservedObject var model: GalleryModel
    @State private var player: AVPlayer?
    
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
                if let nsImage = NSImage(contentsOf: item.url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Failed to load image.")
                        .foregroundColor(.white)
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
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
