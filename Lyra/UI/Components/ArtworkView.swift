import SwiftUI

/// Cover art with a consistent placeholder. Loading is synchronous because the
/// cache is a small local JPEG and `ArtworkCache` keeps recent images in memory —
/// async loading here caused more flicker than it saved.
struct ArtworkView: View {
    let hash: String?
    var size: CGFloat
    var cornerRadius: CGFloat = 6

    var body: some View {
        Group {
            if let image = ArtworkCache.shared.image(for: hash) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.36, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Full-bleed artwork for the Now Playing screen, where the placeholder should
/// feel deliberate rather than like a missing asset.
struct LargeArtworkView: View {
    let hash: String?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Group {
                if let image = ArtworkCache.shared.image(for: hash) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: side * 0.25, weight: .thin))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.25), radius: 22, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
