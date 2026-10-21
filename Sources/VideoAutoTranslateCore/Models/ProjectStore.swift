import Foundation
import CryptoKit

/// A project references durable, content-addressed audio beside its document.
public enum ProjectStore {
    private static let lock = NSRecursiveLock()
    public static func write(documentData: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        let document = try JSONDecoder().decode(ProjectDocument.self, from: documentData)
        let folderName = url.lastPathComponent + ".assets"
        let folder = url.deletingLastPathComponent().appendingPathComponent(folderName)
        for item in document.subtitles {
            guard let source = item.dubbedAudioURL else { continue }
            let resolved = source.scheme == nil ? url.deletingLastPathComponent().appendingPathComponent(source.relativeString) : source
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                item.dubbedAudioURL = nil
                continue
            }
            let data = try Data(contentsOf: resolved)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let filename = hash + "." + (resolved.pathExtension.isEmpty ? "wav" : resolved.pathExtension)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
            item.dubbedAudioURL = URL(string: folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "/" + filename)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Task.checkCancellation()
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    public static func removeCheckpoint(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    public static func read(from url: URL) throws -> ProjectDocument {
        let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        for item in document.subtitles {
            if let audio = item.dubbedAudioURL {
                let resolved = audio.scheme == nil ? URL(string: audio.relativeString, relativeTo: url.deletingLastPathComponent().appendingPathComponent("", isDirectory: true))!.absoluteURL : audio
                item.dubbedAudioURL = FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
            }
        }
        return document
    }
}
