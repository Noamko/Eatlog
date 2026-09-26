import SwiftUI
import UIKit
import Observation

/// A photo popout request: which image, and where on screen it lifts off from.
struct PopoutRequest: Identifiable {
    let id = UUID()
    let image: UIImage
    let sourceFrame: CGRect
    let sourceCornerRadius: CGFloat
}

/// Lets deep views (like the meal detail page) present the popout from the root,
/// above the navigation and tab bars, so the whole app blurs behind it.
@Observable
final class PhotoPopoutController {
    var request: PopoutRequest?
}

/// Hero-style photo popout: the tapped image itself lifts off its thumbnail,
/// grows to fit the screen while the app behind it blurs in, and shrinks back
/// into place on close. The presenting view hides the real thumbnail while the
/// popout is active, so it reads as one continuous image.
/// Pinch or double-tap to zoom, drag to pan while zoomed, drag down / tap outside / X to close.
struct PhotoPopoutOverlay: View {
    let request: PopoutRequest
    let onDismissed: () -> Void

    @State private var expanded = false
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private static let spring = Animation.spring(response: 0.4, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let source = request.sourceFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let dest = Self.fitRect(imageSize: request.image.size, in: geo.size, padding: 16)
            let rect = expanded ? dest : source

            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(expanded ? 1 : 0)
                    .ignoresSafeArea()
                Color.black.opacity(expanded ? 0.15 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                Image(uiImage: request.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? 22 : request.sourceCornerRadius))
                    .shadow(color: .black.opacity(expanded ? 0.3 : 0), radius: 24, y: 10)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(magnification)
                    .simultaneousGesture(drag)
                    .onTapGesture(count: 2) { toggleZoom() }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                        .padding()
                }
                .accessibilityLabel("Close")
                .opacity(expanded ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(Self.spring) { expanded = true }
        }
    }

    /// Aspect-fit rect for the image, centered in the container. Because the
    /// popped-out frame has the image's own aspect ratio, the scaledToFill crop
    /// opens up smoothly from the thumbnail's crop to the full uncropped photo.
    private static func fitRect(imageSize: CGSize, in container: CGSize, padding: CGFloat) -> CGRect {
        let available = CGSize(width: container.width - padding * 2, height: container.height - padding * 2)
        guard imageSize.width > 0, imageSize.height > 0, available.width > 0, available.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func close() {
        withAnimation(Self.spring) {
            expanded = false
            zoom = 1
            lastZoom = 1
            offset = .zero
            lastOffset = .zero
        } completion: {
            onDismissed()
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard expanded else { return }
                zoom = min(max(lastZoom * value, 1), 6)
            }
            .onEnded { _ in
                lastZoom = zoom
                if zoom <= 1.02 {
                    withAnimation(.spring(duration: 0.3)) {
                        zoom = 1
                        lastZoom = 1
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard expanded else { return }
                if zoom > 1 {
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                } else {
                    // Follow the finger a little so drag-down-to-close feels alive.
                    offset = CGSize(
                        width: value.translation.width * 0.2,
                        height: value.translation.height
                    )
                }
            }
            .onEnded { value in
                guard expanded else { return }
                if zoom > 1 {
                    lastOffset = offset
                } else if value.translation.height > 110 {
                    close()
                } else {
                    withAnimation(.spring(duration: 0.3)) { offset = .zero }
                    lastOffset = .zero
                }
            }
    }

    private func toggleZoom() {
        guard expanded else { return }
        withAnimation(.spring(duration: 0.3)) {
            if zoom > 1 {
                zoom = 1
                lastZoom = 1
                offset = .zero
                lastOffset = .zero
            } else {
                zoom = 2.5
                lastZoom = 2.5
            }
        }
    }
}
