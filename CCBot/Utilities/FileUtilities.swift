import Foundation

enum FileUtilities {
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
}
