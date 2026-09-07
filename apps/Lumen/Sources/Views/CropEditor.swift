import SwiftUI
import AppKit

/// Chooses which part of a wallpaper survives on a display.
///
/// macOS centre-crops, which is wrong often enough to matter: a 21:9 photo with
/// its subject on the left loses the subject on a 16:10 screen. The crop is
/// stored per wallpaper *and* per display, because the right answer differs
/// between a laptop and an ultrawide.
///
/// When the menu bar would be unreadable over the chosen crop, the editor
/// offers the vertical offset that fixes it — the legibility check already
/// knows the answer, this is what makes it actionable.
struct CropEditor: View {
    @Environment(Store.self) private var store

    let title: String
    let source: URL
    /// Native pixels of the display being cropped for.
    let displaySize: CGSize
    /// Normalised rect (0...1) in the image's own space.
    var onSave: (CGRect) -> Void
    var onCancel: () -> Void

    @State private var image: NSImage?
    @State private var imageAspect: Double = 16.0 / 9
    /// 1 shows the largest crop that fits; higher zooms in.
    @State private var zoom: Double = 1
    /// Centre of the crop, normalised.
    @State private var centre = CGPoint(x: 0.5, y: 0.5)
    @State private var dragStart: CGPoint?
    @State private var menuBar: MenuBarLegibility.Verdict?
    @State private var suggestion: CGFloat?

    init(title: String, source: URL, displaySize: CGSize, existing: CGRect? = nil,
         onSave: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.source = source
        self.displaySize = displaySize
        self.onSave = onSave
        self.onCancel = onCancel
        if let existing, existing.width > 0, existing.height > 0 {
            _centre = State(initialValue: CGPoint(x: existing.midX, y: existing.midY))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvas
            Divider()
            controls
        }
        .frame(minWidth: 720, idealWidth: 1000, minHeight: 520, idealHeight: 700)
        .background(.background)
        .task(id: source) { await load() }
        .onChange(of: crop) { _, _ in assess() }
    }

    // MARK: Geometry

    private var displayAspect: Double { displaySize.width / max(displaySize.height, 1) }

    /// The largest crop of the display's shape that fits inside the image.
    private var baseSize: CGSize {
        if imageAspect > displayAspect {
            CGSize(width: displayAspect / imageAspect, height: 1)
        } else {
            CGSize(width: 1, height: imageAspect / displayAspect)
        }
    }

    /// The crop as it stands, clamped inside the image.
    private var crop: CGRect {
        let width = min(1, baseSize.width / zoom)
        let height = min(1, baseSize.height / zoom)
        let x = min(max(centre.x - width / 2, 0), 1 - width)
        let y = min(max(centre.y - height / 2, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            let frame = fitted(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .overlay {
                            // Everything outside the crop is dimmed, so what
                            // survives is obvious at a glance.
                            cropOverlay(in: frame, container: proxy.size)
                        }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStart == nil { dragStart = centre }
                        guard let start = dragStart, frame.width > 0, frame.height > 0 else { return }
                        centre = CGPoint(x: start.x - value.translation.width / frame.width,
                                         y: start.y - value.translation.height / frame.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The image drawn to fit the canvas, preserving its shape.
    private func fitted(in container: CGSize) -> CGSize {
        guard container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageAspect, container.height)
        return CGSize(width: scale * imageAspect, height: scale)
    }

    private func cropOverlay(in frame: CGSize, container: CGSize) -> some View {
        let rect = crop
        let origin = CGPoint(x: (container.width - frame.width) / 2 + rect.minX * frame.width,
                             y: (container.height - frame.height) / 2 + rect.minY * frame.height)
        let size = CGSize(width: rect.width * frame.width, height: rect.height * frame.height)

        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.55)
                .reverseMask {
                    Rectangle()
                        .frame(width: size.width, height: size.height)
                        .offset(x: origin.x, y: origin.y)
                }
            Rectangle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: size.width, height: size.height)
                .offset(x: origin.x, y: origin.y)
            // Where the menu bar will sit, which is what the warning is about.
            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(width: size.width,
                       height: size.height * (26 / max(displaySize.height, 1)) * 4)
                .offset(x: origin.x, y: origin.y)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: Tokens.s3) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Crop for \(Int(displaySize.width)) × \(Int(displaySize.height))")
                    .font(.system(size: 14, weight: .semibold))
                Text(title).font(.caption2Mono).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Reset") {
                withAnimation(Tokens.quick) {
                    zoom = 1
                    centre = CGPoint(x: 0.5, y: 0.5)
                }
            }
            .controlSize(.small)
        }
        .padding(Tokens.s3)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            if let menuBar {
                HStack(spacing: Tokens.s2) {
                    Image(systemName: menuBar.isRisky
                          ? "menubar.rectangle" : "checkmark.circle")
                        .foregroundStyle(menuBar.isRisky ? Tokens.warning : Tokens.success)
                    Text(menuBar.summary).font(.system(size: 12))
                    if let suggestion {
                        Button("Move crop to fix it") {
                            withAnimation(Tokens.normal) {
                                centre = CGPoint(x: centre.x, y: suggestion + crop.height / 2)
                            }
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                }
            }

            HStack(spacing: Tokens.s3) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...4)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Use This Crop") { onSave(crop) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.s3)
    }

    // MARK: Loading

    private func load() async {
        image = await ImageCache.shared.image(for: source, maxPixels: ImageDetail.preview)
        if let image, image.size.height > 0 {
            imageAspect = image.size.width / image.size.height
        }
        assess()
    }

    private func assess() {
        guard let image else { return }
        menuBar = MenuBarLegibility.assess(image, displaySize: displaySize, crop: crop)
        suggestion = MenuBarLegibility.suggestedOffset(for: image, crop: crop,
                                                       displaySize: displaySize)
    }
}

private extension View {
    /// Punches a hole in a fill, for the dimmed area outside the crop.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            ZStack {
                Rectangle()
                mask().blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}
