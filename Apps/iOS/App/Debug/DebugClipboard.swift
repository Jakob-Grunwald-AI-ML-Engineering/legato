#if DEBUG || LEGATO_INTERNAL
import Foundation
import UIKit
import LegatoDevHarness

/// Private, lossless clipboard fixtures for on-device paste exploration. Never logs clipboard contents.
@MainActor enum DebugClipboard {
    private static var file: URL {
        URL.cachesDirectory.appending(path: "clipboard-fixture-backup.plist")
    }
    private enum Failure: Error {
        case foregroundRequired, existingBackup, unreadableOrEmpty, unsupportedItems, changed, missingBackup, invalid
    }

    static func register(_ harness: DevHarness) {
        harness.register("clipboard-status") { command in
            guard command.args.isEmpty else { throw Failure.invalid }
            try foreground()
            let board = UIPasteboard.general
            return ["numberOfItems": board.numberOfItems, "hasStrings": board.hasStrings,
                    "hasURLs": board.hasURLs, "hasImages": board.hasImages, "hasColors": board.hasColors]
        }
        harness.register("clipboard-preserve") { command in
            guard command.args.isEmpty else { throw Failure.invalid }
            try foreground()
            guard !FileManager.default.fileExists(atPath: file.path) else { throw Failure.existingBackup }
            let board = UIPasteboard.general
            let count = board.changeCount
            let items = board.items
            // An empty result cannot distinguish an empty clipboard from denied access.
            // Refuse rather than overwrite clipboard data we could not preserve.
            guard !items.isEmpty, items.count == board.numberOfItems else { throw Failure.unreadableOrEmpty }
            let data = try archive(items)
            guard count == board.changeCount else { throw Failure.changed }
            try save(["items": data, "ownerCount": count])
            return ["preserved": true, "itemCount": items.count]
        }
        harness.register("clipboard-fixture") { command in
            guard command.args.count == 1 else { throw Failure.invalid }
            try foreground()
            var backup = try load()
            let board = UIPasteboard.general
            guard let owner = backup["ownerCount"] as? Int, owner == board.changeCount else { throw Failure.changed }
            let original = try items(backup)
            guard owner == board.changeCount else { throw Failure.changed }
            board.setItems([["public.utf8-plain-text": command.args[0]]], options: [.localOnly: true])
            backup["ownerCount"] = board.changeCount
            do { try save(backup) }
            catch {
                // There is no await between setting our fixture and rollback. Do not leave
                // a fixture installed if its ownership metadata cannot be recorded.
                board.setItems(original, options: [.localOnly: true])
                backup["ownerCount"] = board.changeCount
                try? save(backup)
                throw Failure.invalid
            }
            return ["fixtureInstalled": true]
        }
        harness.register("clipboard-restore") { command in
            guard command.args.isEmpty else { throw Failure.invalid }
            try foreground()
            let backup = try load()
            let board = UIPasteboard.general
            guard let owner = backup["ownerCount"] as? Int, owner == board.changeCount else { throw Failure.changed }
            let original = try items(backup)
            guard owner == board.changeCount else { throw Failure.changed }
            board.setItems(original, options: [.localOnly: true])
            guard NSArray(array: board.items).isEqual(to: original) else { throw Failure.unsupportedItems }
            try FileManager.default.removeItem(at: file)
            return ["restored": true, "itemCount": original.count]
        }
    }

    private static func foreground() throws {
        guard UIApplication.shared.applicationState == .active else { throw Failure.foregroundRequired }
    }
    private static func archive(_ items: [[String: Any]]) throws -> Data {
        // Property-list-only payloads are round-trippable without loading arbitrary object
        // classes. Unsupported representations fail before any clipboard mutation.
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
            guard let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]],
                  NSArray(array: items).isEqual(to: decoded) else { throw Failure.unsupportedItems }
            return data
        } catch { throw Failure.unsupportedItems }
    }
    private static func items(_ backup: [String: Any]) throws -> [[String: Any]] {
        guard let data = backup["items"] as? Data,
              let items = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]] else {
            throw Failure.unsupportedItems
        }
        return items
    }
    private static func load() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path),
              let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), options: [], format: nil) as? [String: Any] else {
            throw Failure.missingBackup
        }
        return value
    }
    private static func save(_ backup: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}
#endif
