import Foundation
import CryptoKit

enum ImportUtilities {
    /// Calculates the SHA256 hash of a file at the given URL.
    /// Uses memory mapping for performance with large files.
    static func sha256(at url: URL) -> String? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 8192), !data.isEmpty {
                hasher.update(data: data)
            }
            
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }
    
    /// Copies a file while preserving its creation and modification dates.
    static func copyItem(at src: URL, to dest: URL) throws {
        let fm = FileManager.default
        
        // Ensure destination directory exists
        let destDir = dest.deletingLastPathComponent()
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        
        // Get original attributes
        let attrs = try fm.attributesOfItem(atPath: src.path)
        let creationDate = attrs[.creationDate] as? Date
        let modDate = attrs[.modificationDate] as? Date
        
        // Perform copy
        try fm.copyItem(at: src, to: dest)
        
        // Restore attributes on the copy
        var newAttrs: [FileAttributeKey: Any] = [:]
        if let cd = creationDate { newAttrs[.creationDate] = cd }
        if let md = modDate { newAttrs[.modificationDate] = md }
        
        if !newAttrs.isEmpty {
            try fm.setAttributes(newAttrs, ofItemAtPath: dest.path)
        }
    }
}
