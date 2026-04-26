import Foundation

enum FileUtilities {
    struct Snapshot {
        let url: URL
        let existed: Bool
        let data: Data?
        let permissions: NSNumber?
    }

    static func removeItemIfExists(_ url: URL, fileManager: FileManager = .default) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                return
            }
            throw error
        }
    }

    static func writeWithBackupRollback(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let backupURL = url.appendingPathExtension("ccbot.bak")
        let hadOriginal = fileManager.fileExists(atPath: url.path)

        if hadOriginal {
            try? removeItemIfExists(backupURL, fileManager: fileManager)
            try fileManager.copyItem(at: url, to: backupURL)
        }

        do {
            try data.write(to: url, options: .atomic)
            if hadOriginal {
                try? removeItemIfExists(backupURL, fileManager: fileManager)
            }
        } catch {
            if hadOriginal {
                try? removeItemIfExists(url, fileManager: fileManager)
                try? fileManager.moveItem(at: backupURL, to: url)
            } else {
                try? removeItemIfExists(url, fileManager: fileManager)
            }
            throw error
        }
    }

    static func writeOrRemoveItem(
        _ data: Data?,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        if let data {
            try writeWithBackupRollback(data, to: url, fileManager: fileManager)
        } else {
            try removeItemIfExists(url, fileManager: fileManager)
        }
    }

    static func removeDirectoryIfEmpty(_ url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let contents = try fileManager.contentsOfDirectory(atPath: url.path)
        guard contents.isEmpty else { return }
        try removeItemIfExists(url, fileManager: fileManager)
    }

    static func captureSnapshots(for urls: [URL], fileManager: FileManager = .default) throws -> [Snapshot] {
        try urls.map { url in
            guard fileManager.fileExists(atPath: url.path) else {
                return Snapshot(url: url, existed: false, data: nil, permissions: nil)
            }
            let data = try Data(contentsOf: url)
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            let permissions = attrs?[.posixPermissions] as? NSNumber
            return Snapshot(url: url, existed: true, data: data, permissions: permissions)
        }
    }

    static func restoreSnapshots(_ snapshots: [Snapshot], fileManager: FileManager = .default) throws {
        for snapshot in snapshots {
            if snapshot.existed {
                try fileManager.createDirectory(
                    at: snapshot.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if let data = snapshot.data {
                    try data.write(to: snapshot.url, options: .atomic)
                }
                if let permissions = snapshot.permissions {
                    try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: snapshot.url.path)
                }
            } else {
                try removeItemIfExists(snapshot.url, fileManager: fileManager)
            }
        }
    }
}
