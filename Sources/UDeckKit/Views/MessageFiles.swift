import AppKit
import ImageIO
@preconcurrency import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// The files that went with a message, drawn above it in the feed
/// (`FeedEntry.files`): pictures as pictures — one alone larger — and any
/// other file as its icon and name. A click opens them in Quick Look, the
/// message's files one after another (the operator's «1», 11-27: «в сообщении
/// показывать что за фото, и чтобы я мог их открыть»).
struct MessageFiles: View {
    let paths: [String]
    let theme: DeckTheme
    /// The feed entry's id, for the files' accessibility identifiers.
    let entryID: String

    private var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    var body: some View {
        let all = urls
        let pictures = all.enumerated().filter { FileThumbnails.isPicture($0.element) }
        let others = all.enumerated().filter { !FileThumbnails.isPicture($0.element) }
        VStack(alignment: .trailing, spacing: 4) {
            if pictures.count == 1, let one = pictures.first {
                picture(one.element, index: one.offset, all: all, size: CGSize(width: 220, height: 150))
            } else if !pictures.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(pictures.prefix(4)), id: \.offset) { item in
                        picture(item.element, index: item.offset, all: all, size: CGSize(width: 64, height: 48))
                    }
                    if pictures.count > 4, let fifth = pictures.dropFirst(4).first {
                        Button { QuickLook.shared.show(all, at: fifth.offset) } label: {
                            Text("+\(pictures.count - 4)").font(theme.bodyFont.weight(.semibold))
                                .foregroundStyle(theme.muted)
                                .frame(width: 64, height: 48)
                                .background(RoundedRectangle(cornerRadius: 7).fill(theme.subtleFill))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("row.feed.\(entryID).files.more")
                    }
                }
            }
            ForEach(Array(others), id: \.offset) { item in
                Button { QuickLook.shared.show(all, at: item.offset) } label: {
                    HStack(spacing: 5) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.element.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(item.element.lastPathComponent).font(theme.smallFont).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.subtleFill))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.element.path)
                .accessibilityIdentifier("row.feed.\(entryID).file.\(item.offset)")
            }
        }
    }

    private func picture(_ url: URL, index: Int, all: [URL], size: CGSize) -> some View {
        Button { QuickLook.shared.show(all, at: index) } label: {
            FileThumbnail(url: url, size: size, theme: theme)
        }
        .buttonStyle(.plain)
        .help(url.lastPathComponent)
        .accessibilityIdentifier("row.feed.\(entryID).file.\(index)")
    }
}

/// A picture's thumbnail, read off the main thread and kept; a file that is
/// gone is drawn as one.
struct FileThumbnail: View {
    let url: URL
    let size: CGSize
    let theme: DeckTheme
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: FileManager.default.fileExists(atPath: url.path) ? "photo" : "photo.badge.exclamationmark")
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.subtleFill)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .task(id: url) { image = await FileThumbnails.shared.thumbnail(of: url, longest: max(size.width, size.height) * 2) }
    }
}

/// Thumbnails of pictures on disk, made once each by ImageIO.
actor FileThumbnails {
    static let shared = FileThumbnails()
    private var made: [String: NSImage] = [:]

    nonisolated static func isPicture(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) ?? false
    }

    func thumbnail(of url: URL, longest: CGFloat) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = url.path + "|" + String(Int(longest)) + "|" + String(modified?.timeIntervalSince1970 ?? 0)
        if let image = made[key] { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(longest),
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if made.count > 200 { made.removeAll() }
        made[key] = image
        return image
    }
}

/// macOS Quick Look over the panel: the files of one message — or of a
/// field — one after another, ←/→ between them, Escape closing it.
@MainActor
final class QuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = max(0, min(index, urls.count - 1))
        // Above the panel, which sits at the status bar's level.
        panel.level = AboveThePanel.level
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
