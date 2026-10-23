import SwiftUI
import PhotosUI

/// Circular profile picture, falling back to an initials monogram.
/// Purely aesthetic — photos are never used by transcription or sync.
struct AvatarView: View {
    let fileName: String?
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(.tint.opacity(0.15))
                    .overlay {
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tint)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var loadedImage: PlatformImage? {
        guard let fileName else { return nil }
        return PlatformImage(contentsOfFile: Store.photoURL(fileName: fileName).path)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// Avatar wrapped in a photo picker: tap to choose a picture, long-press to
/// remove it. Hands back downscaled JPEG data ready for `Store`.
struct AvatarPicker: View {
    let fileName: String?
    let name: String
    var size: CGFloat = 56
    let onChange: (Data?) -> Void

    @State private var selection: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $selection, matching: .images) {
            AvatarView(fileName: fileName, name: name, size: size)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: size * 0.2))
                        .foregroundStyle(.white)
                        .padding(size * 0.08)
                        .background(.tint, in: Circle())
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if fileName != nil {
                Button(role: .destructive) {
                    onChange(nil)
                } label: {
                    Label("Remove Photo", systemImage: "trash")
                }
            }
        }
        .onChange(of: selection) {
            guard let item = selection else { return }
            selection = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let jpeg = PlatformImage.downscaledJPEG(from: data, maxDimension: 512)
                else { return }
                onChange(jpeg)
            }
        }
    }
}
