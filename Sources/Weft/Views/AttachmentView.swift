import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - AttachmentView

/// A photo/video thumbnail (made by macOS, so HEIC and video work), or a
/// file chip. Click opens it in its usual app.
struct AttachmentView: View {
    let attachment: Attachment
    @State private var thumbnail: NSImage?
    @State private var previewFailed = false
    @State private var retry = 0

    var body: some View {
        Group {
            if attachment.isMissing {
                chip(symbol: "icloud.and.arrow.down", text: "\(attachment.name) — not downloaded to this Mac yet")
            } else if (attachment.isImage || attachment.isVideo) && previewFailed {
                HStack(spacing: 8) {
                    chip(symbol: attachment.isVideo ? "film" : "photo", text: attachment.name)
                    Button("Open") { NSWorkspace.shared.open(attachment.url) }
                    Button("Retry Preview") { previewFailed = false; retry += 1 }
                }
                .controlSize(.small)
            } else if attachment.isImage || attachment.isVideo {
                ZStack {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15))
                            .frame(width: 160, height: 120)
                            .overlay(ProgressView().controlSize(.small))
                    }
                    if attachment.isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                }
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { NSWorkspace.shared.open(attachment.url) }
                .accessibilityLabel(attachment.isVideo ? "Video: \(attachment.name)" : "Photo: \(attachment.name)")
                .accessibilityAddTraits(.isButton)
                .task(id: "\(attachment.id)-\(retry)") { await loadThumbnail() }
            } else {
                chip(symbol: "doc", text: attachment.name)
                    .onTapGesture { NSWorkspace.shared.open(attachment.url) }
                    .accessibilityAddTraits(.isButton)
            }
        }
        .contextMenu {
            if !attachment.isMissing {
                Button("Open") { NSWorkspace.shared.open(attachment.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([attachment.url]) }
            }
        }
        .help(attachment.name)
    }

    private func chip(symbol: String, text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func loadThumbnail() async {
        let request = QLThumbnailGenerator.Request(
            fileAt: attachment.url,
            size: CGSize(width: 480, height: 480),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = rep.nsImage
        } else {
            previewFailed = true
        }
    }
}

// MARK: - LinkPreviewCard

/// A shared link, shown like Messages does: image, title and website.
/// Click to open it in your browser.
struct LinkPreviewCard: View {
    let link: LinkPreview
    @State private var image: NSImage?

    var body: some View {
        Button { NSWorkspace.shared.open(link.url) } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 300, height: min(170, 300 * image.size.height / max(image.size.width, 1)))
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title.isEmpty ? link.url.absoluteString : link.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(link.site)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 300)
            .foregroundStyle(WeftStyle.theirText)
            .background(WeftStyle.theirBubble)
            .clipShape(RoundedRectangle(cornerRadius: WeftStyle.bubbleRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: WeftStyle.bubbleRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(link.url.absoluteString)
        .contextMenu {
            Button("Open Link") { NSWorkspace.shared.open(link.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            }
        }
        .accessibilityLabel("Link: \(link.title.isEmpty ? link.site : link.title), \(link.site)")
        .accessibilityAddTraits(.isLink)
        .task(id: link.imagePath) {
            guard let path = link.imagePath else { return }
            image = await Task.detached { NSImage(contentsOfFile: path) }.value
        }
    }
}
