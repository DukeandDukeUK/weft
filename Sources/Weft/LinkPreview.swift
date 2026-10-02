import Foundation

// MARK: - LinkPreview

/// The preview card Messages shows for a link: title, website and image.
/// Read from what Messages already saved — Weft never contacts the website.
struct LinkPreview: Sendable, Hashable {
    let url: URL
    let title: String
    let site: String
    /// Saved preview image (or the site's icon), if Messages kept one.
    var imagePath: String?
}

/// Reads the preview Messages stores with a link message (`payload_data`).
/// It's a keyed archive of Messages' own types; each one we need is read by
/// a small stand-in class, with secure decoding on, so nothing else in the
/// archive is ever created.
enum LinkPreviewParser {
    struct Parsed: Equatable {
        let url: URL
        let title: String
        let site: String
        /// Which of the message's saved preview files holds the image
        /// (the picture if there is one, else the site icon).
        let imageIndex: Int?
    }

    static func parse(_ data: Data) -> Parsed? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(RichLinkStub.self, forClassName: "RichLink")
        unarchiver.setClass(MetadataStub.self, forClassName: "LPLinkMetadata")
        unarchiver.setClass(ImageStub.self, forClassName: "RichLinkImageAttachmentSubstitute")
        defer { unarchiver.finishDecoding() }
        guard let root = unarchiver.decodeObject(of: RichLinkStub.self, forKey: NSKeyedArchiveRootObjectKey),
              let meta = root.metadata,
              let url = meta.url ?? meta.originalURL else { return nil }
        return Parsed(url: url,
                      title: meta.title ?? "",
                      site: meta.site ?? url.host() ?? "",
                      imageIndex: meta.image?.index ?? meta.icon?.index)
    }
}

final class RichLinkStub: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let metadata: MetadataStub?
    init?(coder: NSCoder) {
        metadata = coder.decodeObject(of: MetadataStub.self, forKey: "richLinkMetadata")
    }
    func encode(with coder: NSCoder) {}
}

final class MetadataStub: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let url: URL?
    let originalURL: URL?
    let title: String?
    let site: String?
    let image: ImageStub?
    let icon: ImageStub?
    init?(coder: NSCoder) {
        url = coder.decodeObject(of: NSURL.self, forKey: "URL") as URL?
        originalURL = coder.decodeObject(of: NSURL.self, forKey: "originalURL") as URL?
        title = coder.decodeObject(of: NSString.self, forKey: "title") as String?
        site = coder.decodeObject(of: NSString.self, forKey: "siteName") as String?
        image = coder.decodeObject(of: ImageStub.self, forKey: "image")
        icon = coder.decodeObject(of: ImageStub.self, forKey: "icon")
    }
    func encode(with coder: NSCoder) {}
}

final class ImageStub: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let index: Int?
    init?(coder: NSCoder) {
        index = coder.containsValue(forKey: "richLinkImageAttachmentSubstituteIndex")
            ? coder.decodeInteger(forKey: "richLinkImageAttachmentSubstituteIndex") : nil
    }
    func encode(with coder: NSCoder) {}
}

// MARK: - Clickable links in message text

enum LinkText {
    /// The message text with web addresses turned into clickable links.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard text.contains("."),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url,
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }

    /// Text that is nothing but the link itself (the card says it all).
    static func isJustTheLink(_ text: String, _ url: URL) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func bare(_ s: String) -> String {
            var s = s.lowercased()
            for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return t.isEmpty || bare(t) == bare(url.absoluteString)
    }
}
