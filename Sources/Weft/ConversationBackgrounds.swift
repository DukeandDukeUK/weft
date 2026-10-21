import AppKit
import Foundation

// MARK: - Conversation backgrounds

/// Photo backgrounds set in Messages (by either side of the conversation).
/// Messages keeps one "channel" per conversation under Attachments/
/// BackgroundChannels; its info file names the conversation, and a photo
/// background is stored as an ordinary image file inside it. Apple's
/// built-in styles (gradients, colours, sky) are drawn live by Messages and
/// aren't saved as pictures, so those conversations keep Weft's own colour.
enum ConversationBackgrounds {
    static var channelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Messages/Attachments/BackgroundChannels/Contents/Data/Channels")
    }

    /// Messages' identifier for a conversation (the phone number, email or
    /// group id), the last part of its guid ("iMessage;-;+15551234567").
    static func identifier(fromGUID guid: String) -> String {
        guid.split(separator: ";").last.map(String.init) ?? ""
    }

    /// The photo background for a conversation, or nil.
    static func imageURL(forChat identifier: String, in directory: URL = channelsDirectory) -> URL? {
        guard let channel = channel(forChat: identifier, in: directory),
              let poster = newestNumbered(in: channel.appending(path: "channelPosterVersions")) else { return nil }
        return newestImage(under: poster)
    }

    /// Whether Messages shows this conversation dark (true) or light (false)
    /// to suit its background; nil when it just follows the Mac's setting.
    /// Read from Messages' saved preview of the background.
    static func isDark(forChat identifier: String, in directory: URL = channelsDirectory) -> Bool? {
        guard let channel = channel(forChat: identifier, in: directory),
              let walker = FileManager.default.enumerator(at: channel.appending(path: "snapshotCache"),
                                                          includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        var newest: (date: Date, style: Int)?
        for case let url as URL in walker where url.lastPathComponent == "Info.plist" {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let style = plist["PUIPosterSnapshotBundleInfoKeyUserInterfaceStyle"] as? Int else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if newest == nil || date > newest!.date { newest = (date, style) }
        }
        switch newest?.style {
        case 2: return true    // dark
        case 1: return false   // light
        default: return nil
        }
    }

    /// The channel folder whose info file names this conversation.
    private static func channel(forChat identifier: String, in directory: URL) -> URL? {
        guard !identifier.isEmpty,
              let channels = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        return channels.first { channel in
            guard let version = newestNumbered(in: channel.appending(path: "channelVersions")),
                  let data = try? Data(contentsOf: version.appending(path: "channelInfo.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let objects = plist["$objects"] as? [Any] else { return false }
            return objects.contains { ($0 as? String) == identifier }
        }
    }

    /// The highest-numbered subfolder ("0", "1", …): the current version.
    private static func newestNumbered(in directory: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url in Int(url.lastPathComponent).map { ($0, url) } }.max { $0.0 < $1.0 }?.1
    }

    /// The most recently saved background image in a poster version (the
    /// background layer, not the cut-out foreground of a depth effect).
    private static func newestImage(under directory: URL) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return nil }
        var best: (url: URL, date: Date, isBackground: Bool)?
        for case let url as URL in walker {
            guard ["heic", "png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { continue }
            let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let isBackground = url.lastPathComponent.lowercased().contains("background")
            // Background layers first; among those, the newest.
            if let current = best {
                let better = isBackground != current.isBackground ? isBackground : date > current.date
                if better { best = (url, date, isBackground) }
            } else {
                best = (url, date, isBackground)
            }
        }
        return best?.url
    }
}
