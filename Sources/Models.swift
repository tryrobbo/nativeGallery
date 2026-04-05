import Foundation
import Combine
import AppKit
import AVFoundation
import CoreServices

enum MediaType {
    case photo
    case video
}

struct FolderNode: Identifiable, Hashable {
    let id: String
    let name: String
    var children: [FolderNode]?
}

struct MetadataEntry: Codable {
    var albums: [String]
}

struct FolderMetadata: Codable {
    var files: [String: MetadataEntry]
}

struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let type: MediaType
    let date: Date
    let name: String

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "avi"].contains(ext) {
            self.type = .video
        } else {
            self.type = .photo
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attrs[.modificationDate] as? Date {
            self.date = modDate
        } else {
            self.date = Date()
        }
    }
}

class GalleryModel: ObservableObject {
    @Published var rootURL: URL? = nil
    @Published var mediaItems: [MediaItem] = []
    @Published var isScanning = false

    // Filters
    enum FilterType: String, CaseIterable, Identifiable {
        case all = "All"
        case photo = "Photos"
        case video = "Videos"
        var id: String { self.rawValue }
    }

    @Published var currentFilter: FilterType = .all
    @Published var searchQuery: String = ""
    @Published var selectedFolderID: String? = nil
    @Published var folders: [FolderNode] = []
    @Published var selectedItem: MediaItem? = nil
    
    @Published var albums: [String: [MediaItem]] = [:]
    @Published var selectedAlbum: String? = nil
    @Published var isPlayingSlideshow = false

    @Published var activePlayer: AVPlayer? = nil
    @Published var expandedFolders: [String: Bool] = [:]
    @Published private(set) var filteredItems: [MediaItem] = []

    // Import State
    @Published var isImportMode = false
    @Published var importSourceURL: URL? = nil
    @Published var importItems: [MediaItem] = []
    @Published var selectedImportURIs = Set<URL>()
    @Published var importDescription = ""
    @Published var isImporting = false
    @Published var importProgress: Double = 0
    @Published var deleteSourceAfterImport = false
    @Published var importDestinationURL: URL? = nil
    @Published var recentFolders: [URL] = []

    private var eventStream: FSEventStreamRef?
    private var scanGeneration = 0
    private let fsEventQueue = DispatchQueue(label: "com.nativegallery.fsevents", qos: .utility)
    private var cancellables = Set<AnyCancellable>()

    init() {
        Publishers.CombineLatest(
            Publishers.CombineLatest4($mediaItems, $currentFilter, $searchQuery, $selectedFolderID),
            $selectedAlbum
        )
            .map { core, albumName -> [MediaItem] in
                let (items, filter, query, folderID) = core
                var result = items
                
                if let album = albumName {
                    let albumURLs = Set((self.albums[album] ?? []).map { $0.url })
                    result = result.filter { albumURLs.contains($0.url) }
                }
                if filter == .photo {
                    result = result.filter { $0.type == .photo }
                } else if filter == .video {
                    result = result.filter { $0.type == .video }
                }
                if let sf = folderID {
                    result = result.filter { $0.url.deletingLastPathComponent().path == sf }
                }
                if !query.isEmpty {
                    result = result.filter { $0.name.localizedCaseInsensitiveContains(query) }
                }
                return result.sorted { $0.date > $1.date }
            }
            .assign(to: &$filteredItems)

        // Load stored root folder if it exists.
        if let lastPath = UserDefaults.standard.string(forKey: "lastRootPath") {
            let url = URL(fileURLWithPath: lastPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                self.rootURL = url
                startWatching(url: url)
                scan(url: url, initialLoad: true)
            }
        }
    }

    deinit {
        stopWatching()
    }

    func selectRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Media Folder"
        if panel.runModal() == .OK, let url = panel.url {
            self.rootURL = url
            self.selectedAlbum = nil
            UserDefaults.standard.set(url.path, forKey: "lastRootPath")
            startWatching(url: url)
            scan(url: url, initialLoad: true)
        }
    }

    // MARK: - File system watching

    private func startWatching(url: URL) {
        stopWatching()

        let pathsToWatch = [url.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let model = Unmanaged<GalleryModel>.fromOpaque(info!).takeUnretainedValue()
            DispatchQueue.main.async {
                guard let root = model.rootURL else { return }
                model.scan(url: root, initialLoad: false)
            }
        }

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        eventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,   // 300 ms coalescing latency
            flags
        )

        if let stream = eventStream {
            FSEventStreamSetDispatchQueue(stream, fsEventQueue)
            FSEventStreamStart(stream)
        }
    }

    private func stopWatching() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    // MARK: - Scanning

    private func scan(url: URL, initialLoad: Bool) {
        if initialLoad {
            self.isScanning = true
            self.mediaItems = []
        }

        // Increment generation so any in-flight scan knows it's been superseded.
        scanGeneration += 1
        let generation = scanGeneration

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            var newItems = [MediaItem]()
            var tempAlbums = [String: [URL]]()
            
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                
                // Process media files
                if ["jpg", "jpeg", "png", "heic", "gif", "mp4", "mov", "m4v"].contains(ext) {
                    newItems.append(MediaItem(url: fileURL))
                }
                
                // Process metadata files
                if fileURL.lastPathComponent == ".ng_metadata.json" {
                    if let data = try? Data(contentsOf: fileURL),
                       let meta = try? JSONDecoder().decode(FolderMetadata.self, from: data) {
                        let parent = fileURL.deletingLastPathComponent()
                        for (filename, entry) in meta.files {
                            let itemURL = parent.appendingPathComponent(filename)
                            for albumName in entry.albums {
                                tempAlbums[albumName, default: []].append(itemURL)
                            }
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                // Discard results if a newer scan has already started.
                guard self.scanGeneration == generation else { return }

                // Dismiss lightbox if the open item was deleted.
                if let current = self.selectedItem,
                   !newItems.contains(where: { $0.url == current.url }) {
                    self.selectedItem = nil
                }

                self.mediaItems = newItems
                
                // Aggregate albums
                var finalAlbums = [String: [MediaItem]]()
                for (name, urls) in tempAlbums {
                    finalAlbums[name] = newItems.filter { urls.contains($0.url) }
                }
                self.albums = finalAlbums

                let allDirs = Set(newItems.map { $0.url.deletingLastPathComponent() })
                let newFolders = self.buildFolderTree(from: allDirs, root: url)
                self.folders = newFolders

                if initialLoad {
                    // Expand everything on first load.
                    self.expandedFolders = Dictionary(
                        uniqueKeysWithValues: self.allFolderIDs(from: newFolders).map { ($0, true) }
                    )
                    self.isScanning = false
                } else {
                    // Preserve current expansion state; default new folders to expanded.
                    let updated = Dictionary(
                        uniqueKeysWithValues: self.allFolderIDs(from: newFolders).map { id in
                            (id, self.expandedFolders[id] ?? true)
                        }
                    )
                    self.expandedFolders = updated
                }
            }
        }
    }

    private func buildFolderTree(from urls: Set<URL>, root: URL) -> [FolderNode] {
        class Node {
            let name: String
            let path: String
            var children: [String: Node] = [:]
            init(name: String, path: String) { self.name = name; self.path = path }

            func toFolderNode() -> FolderNode {
                let sortedChildren = children.values
                    .map { $0.toFolderNode() }
                    .sorted { $0.name > $1.name }
                return FolderNode(id: path, name: name, children: sortedChildren.isEmpty ? nil : sortedChildren)
            }
        }

        let rootNode = Node(name: "Root", path: root.path)

        for dirUrl in urls {
            guard dirUrl.path.hasPrefix(root.path), dirUrl.path != root.path else { continue }

            let relativePath = String(dirUrl.path.dropFirst(root.path.count))
            let rawComponents = relativePath.split(separator: "/")

            var current = rootNode
            var currentPath = root.path
            for comp in rawComponents {
                let name = String(comp)
                currentPath = (currentPath as NSString).appendingPathComponent(name)
                if current.children[name] == nil {
                    current.children[name] = Node(name: name, path: currentPath)
                }
                current = current.children[name]!
            }
        }

        return rootNode.children.values
            .map { $0.toFolderNode() }
            .sorted { $0.name > $1.name }
    }

    private func allFolderIDs(from nodes: [FolderNode]) -> [String] {
        var ids: [String] = []
        for node in nodes {
            ids.append(node.id)
            if let children = node.children {
                ids.append(contentsOf: allFolderIDs(from: children))
            }
        }
        return ids
    }

    func togglePlayPause() {
        guard let p = activePlayer else { return }
        if p.timeControlStatus == .playing {
            p.pause()
        } else {
            p.play()
        }
    }

    func navigate(offset: Int) {
        let items = filteredItems
        guard let current = selectedItem, let currentIndex = items.firstIndex(of: current) else { return }

        var newIndex = currentIndex + offset
        if newIndex < 0 {
            newIndex = items.count - 1
        } else if newIndex >= items.count {
            newIndex = 0
        }

        selectedItem = items[newIndex]
    }

    // MARK: - Albums & Slideshow

    func addToAlbum(item: MediaItem, albumName: String) {
        let parentDir = item.url.deletingLastPathComponent()
        let metaURL = parentDir.appendingPathComponent(".ng_metadata.json")
        
        var meta = (try? JSONDecoder().decode(FolderMetadata.self, from: Data(contentsOf: metaURL))) ?? FolderMetadata(files: [:])
        
        var entry = meta.files[item.url.lastPathComponent, default: MetadataEntry(albums: [])]
        if !entry.albums.contains(albumName) {
            entry.albums.append(albumName)
            meta.files[item.url.lastPathComponent] = entry
            
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: metaURL)
                // Refresh local state for reactive UI
                var currentItems = self.albums[albumName, default: []]
                currentItems.append(item)
                self.albums[albumName] = currentItems
            }
        }
    }

    func removeFromAlbum(item: MediaItem, albumName: String) {
        let parentDir = item.url.deletingLastPathComponent()
        let metaURL = parentDir.appendingPathComponent(".ng_metadata.json")
        
        guard var meta = try? JSONDecoder().decode(FolderMetadata.self, from: Data(contentsOf: metaURL)),
              var entry = meta.files[item.url.lastPathComponent] else { return }
              
        entry.albums.removeAll { $0 == albumName }
        if entry.albums.isEmpty {
            meta.files.removeValue(forKey: item.url.lastPathComponent)
        } else {
            meta.files[item.url.lastPathComponent] = entry
        }
        
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL)
            self.albums[albumName]?.removeAll { $0.url == item.url }
        }
    }

    private var slideshowTimer: AnyCancellable?

    func toggleSlideshow() {
        if isPlayingSlideshow {
            stopSlideshow()
        } else {
            startSlideshow()
        }
    }

    func startSlideshow() {
        guard !isPlayingSlideshow else { return }
        isPlayingSlideshow = true
        slideshowTimer = Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.navigate(offset: 1)
            }
    }

    func stopSlideshow() {
        isPlayingSlideshow = false
        slideshowTimer?.cancel()
        slideshowTimer = nil
    }

    // MARK: - Import Mode

    func startImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Source Folder"
        if panel.runModal() == .OK, let url = panel.url {
            self.importSourceURL = url
            self.isImportMode = true
            self.selectedImportURIs = []
            self.importDescription = ""
            self.importDestinationURL = nil // Reset selection
            updateRecentFolders()
            scanImportSource(url: url)
        }
    }

    private func updateRecentFolders() {
        guard let root = rootURL else { return }
        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let dirs = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            // Sort alphabetically descending (latest yyyy-mm first)
            self.recentFolders = dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch {
            print("Error listing directories: \(error)")
        }
    }

    private func scanImportSource(url: URL) {
        self.isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                DispatchQueue.main.async { self.isScanning = false }
                return
            }

            var items = [MediaItem]()
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "heic", "gif", "mp4", "mov", "m4v"].contains(ext) {
                    items.append(MediaItem(url: fileURL))
                }
            }

            DispatchQueue.main.async {
                self.importItems = items.sorted { $0.date > $1.date }
                self.isScanning = false
                // Default to no selection for safety.
                self.selectedImportURIs = []
            }
        }
    }

    func performImport() {
        guard let destRoot = rootURL, !selectedImportURIs.isEmpty else { return }
        let selectedItems = importItems.filter { selectedImportURIs.contains($0.url) }
        
        let targetDir: URL
        if let explicitDest = importDestinationURL {
            targetDir = explicitDest
        } else {
            // Calculate date prefix from earliest selected item
            guard let earliestDate = selectedItems.map({ $0.date }).min() else { return }
            
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM"
            let datePrefix = df.string(from: earliestDate)
            
            let folderName = importDescription.isEmpty ? datePrefix : "\(datePrefix) \(importDescription)"
            targetDir = destRoot.appendingPathComponent(folderName)
        }
        
        self.isImporting = true
        self.importProgress = 0
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var completed = 0
            let total = selectedItems.count
            
            for item in selectedItems {
                let srcURL = item.url
                var destURL = targetDir.appendingPathComponent(item.name)
                var wasSuccessful = false
                
                do {
                    // Check for existence
                    if fm.fileExists(atPath: destURL.path) {
                        // Compare SHA256
                        let srcHash = ImportUtilities.sha256(at: srcURL)
                        let destHash = ImportUtilities.sha256(at: destURL)
                        
                        if srcHash == destHash {
                            // Truly identical, skip
                            print("Skipping identical file: \(item.name)")
                            wasSuccessful = true
                        } else {
                            // Same name, different content -> rename with suffix
                            let base = destURL.deletingPathExtension().lastPathComponent
                            let ext = destURL.pathExtension
                            var counter = 1
                            while fm.fileExists(atPath: destURL.path) {
                                let newName = "\(base)_\(counter).\(ext)"
                                destURL = targetDir.appendingPathComponent(newName)
                                counter += 1
                            }
                            try ImportUtilities.copyItem(at: srcURL, to: destURL)
                            wasSuccessful = true
                        }
                    } else {
                        try ImportUtilities.copyItem(at: srcURL, to: destURL)
                        wasSuccessful = true
                    }
                    
                    if wasSuccessful && self.deleteSourceAfterImport {
                        try fm.removeItem(at: srcURL)
                    }
                } catch {
                    print("Error importing \(item.name): \(error)")
                }
                
                completed += 1
                DispatchQueue.main.async {
                    self.importProgress = Double(completed) / Double(total)
                }
            }
            
            DispatchQueue.main.async {
                self.isImporting = false
                self.isImportMode = false
                self.importItems = []
                self.selectedImportURIs = []
                // Rescan library to show new items
                self.scan(url: destRoot, initialLoad: false)
                // Switch to newly created directory
                self.selectedFolderID = targetDir.path
            }
        }
    }

    func cancelImport() {
        self.isImportMode = false
        self.importItems = []
        self.selectedImportURIs = []
    }
}
