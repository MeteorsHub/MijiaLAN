import Foundation
import MijiaCore

/// Moves only matter.js's node store. Commissioning credentials and App preferences stay in place.
struct MatterPairingResetStore {
    struct Checkpoint {
        let archive: URL?
    }
    enum Failure: LocalizedError {
        case unsafeDirectory
        var errorDescription: String? {
            L10n.tr("Matter 存储或备份路径不是普通目录，请检查本机文件权限。", "Matter storage or its backup path is not a regular directory. Check local permissions.")
        }
    }

    let root: URL
    private var node: URL { root.appendingPathComponent("mijialan", isDirectory: true) }
    private var backups: URL { root.appendingPathComponent("PairingBackups", isDirectory: true) }
    private let files = FileManager.default

    func archive() throws -> Checkpoint {
        try validateIfPresent(root)
        guard try exists(node) else { return Checkpoint(archive: nil) }
        try validateIfPresent(node)
        let folder = try privateBackup()
        let destination = folder.appendingPathComponent("mijialan", isDirectory: true)
        try files.moveItem(at: node, to: destination)
        return Checkpoint(archive: destination)
    }

    /// Called only after all children exited. Keep a failed fresh node separate instead of deleting data.
    func restore(_ checkpoint: Checkpoint) throws {
        try validateIfPresent(root)
        if let archive = checkpoint.archive { try validateIfPresent(archive); guard try exists(archive) else { throw Failure.unsafeDirectory } }
        if try exists(node) {
            try validateIfPresent(node)
            let folder = try privateBackup()
            try files.moveItem(at: node, to: folder.appendingPathComponent("failed-new-node", isDirectory: true))
        }
        if let archive = checkpoint.archive { try files.moveItem(at: archive, to: node) }
    }

    private func exists(_ url: URL) throws -> Bool {
        do { _ = try files.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }
    private func validateIfPresent(_ url: URL) throws {
        guard try exists(url) else { return }
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unsafeDirectory }
    }
    private func privateBackup() throws -> URL {
        try validateIfPresent(backups)
        if try !exists(backups) {
            try files.createDirectory(at: backups, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backups.path)
        let folder = backups.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }
}
