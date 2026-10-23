import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Small iOS/macOS seams for the views and services both app targets share.
// Each shim keeps the iOS behavior exactly as it was at its call sites.

extension EnvironmentValues {
    /// macOS: how far `readingWidth()` insets each List row on either side
    /// so its content sits in the centered reading column. Always 0 on iOS.
    @Entry var readingInset: CGFloat = 0
}

extension View {
    /// Inset a List row (or section header) to the reading column set up by
    /// `readingWidth()` (macOS). A no-op on iOS, where the inset is 0.
    func readingRow() -> some View {
        modifier(ReadingRowInset())
    }

    /// Compact navigation title: inline on iOS; macOS has no large titles.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// What a text field holds, which picks the iOS keyboard and capitalization.
enum TextEntryKind {
    case url, token, host, header
}

extension View {
    /// Keyboard, capitalization, and autocorrection for machine-readable
    /// input. macOS has no software keyboard, so only autocorrection applies.
    func textEntry(_ kind: TextEntryKind) -> some View {
        #if os(iOS)
        Group {
            switch kind {
            case .url:
                keyboardType(.URL).textInputAutocapitalization(.never)
            case .token:
                textInputAutocapitalization(.characters)
            case .host:
                keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never)
            case .header:
                textInputAutocapitalization(.never)
            }
        }
        .autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

extension PlatformImage {
    /// Avatars render at ≤88 pt, so cap photos at `maxDimension` px and
    /// re-encode as JPEG rather than storing multi-megabyte originals.
    static func downscaledJPEG(from data: Data, maxDimension: CGFloat) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)
        #else
        // Pixel dimensions, not NSImage's point size (which folds in DPI).
        guard let source = NSBitmapImageRep(data: data),
              let cgImage = source.cgImage else { return nil }
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        let scale = min(1, maxDimension / max(width, height))
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: targetWidth, height: targetHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let resized = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: resized)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

enum Pasteboard {
    /// Copy plain text. On iOS it is local-only and expiring: transcripts
    /// shouldn't hop devices via Universal Clipboard or linger in the
    /// pasteboard indefinitely.
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(10 * 60),
            ])
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

enum SystemSettings {
    /// Where the user turns microphone access back on.
    static var microphonePrivacyURL: URL {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)!
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        #endif
    }
}

enum DeviceNoun {
    /// The device in user-facing copy, e.g. "everything runs on this iPhone".
    #if os(iOS)
    static let current = "iPhone"
    #else
    static let current = "Mac"
    #endif
}

private struct ReadingRowInset: ViewModifier {
    @Environment(\.readingInset) private var inset

    func body(content: Content) -> some View {
        #if os(macOS)
        // macOS draws row separators from the content's leading edge to the
        // List's trailing edge, which reads as stray lines beside a centered
        // column; the reading-column rows go without them.
        content
            .padding(.horizontal, inset)
            .listRowSeparator(.hidden)
        #else
        content
        #endif
    }
}
