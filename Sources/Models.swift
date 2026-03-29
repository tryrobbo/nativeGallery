import Foundation
import Combine
import AppKit
import AVFoundation

enum MediaType {
    case photo
    case video
}

struct FolderNode: Identifiable, Hashable {
    let id: String
    let name: String
    var children: [FolderNode]?
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
    
    @Published var activePlayer: AVPlayer? = nil
    @Published var expandedFolders: [String: Bool] = [:]
    
    var filteredItems: [MediaItem] {
        var items = mediaItems
        if currentFilter == .photo {
            items = items.filter { $0.type == .photo }
        } else if currentFilter == .video {
            items = items.filter { $0.type == .video }
        }
        
        if let sf = selectedFolderID {
            items = items.filter { $0.url.deletingLastPathComponent().path == sf }
        }
        
        if !searchQuery.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
        
        return items.sorted(by: { $0.date > $1.date })
    }
    
    func selectRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Media Folder"
        if panel.runModal() == .OK, let url = panel.url {
            self.rootURL = url
            scan(url: url)
        }
    }
    
    private func scan(url: URL) {
        self.isScanning = true
        self.mediaItems = []
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                DispatchQueue.main.async { self.isScanning = false }
                return
            }
            
            var newItems = [MediaItem]()
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "heic", "gif", "mp4", "mov", "m4v"].contains(ext) {
                    newItems.append(MediaItem(url: fileURL))
                }
            }
            
            DispatchQueue.main.async {
                self.mediaItems = newItems

                let allDirs = Set(newItems.map { $0.url.deletingLastPathComponent() })
                self.folders = self.buildFolderTree(from: allDirs, root: url)
                self.expandedFolders = Dictionary(
                    uniqueKeysWithValues: self.allFolderIDs(from: self.folders).map { ($0, true) }
                )

                self.isScanning = false
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
}
