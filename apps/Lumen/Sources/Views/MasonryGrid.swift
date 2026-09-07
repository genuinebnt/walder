import SwiftUI

/// A masonry grid that stays lazy.
///
/// `MasonryLayout` was a `Layout`, and a `Layout` is not lazy: SwiftUI builds
/// and measures *every* subview before it can place any of them, twice per pass
/// — once in `sizeThatFits` and again in `placeSubviews`. At a few hundred
/// wallpapers that is slow; at two thousand it hangs on the first scroll.
///
/// This distributes items into columns arithmetically, from aspect ratios that
/// are already known, and renders each column as a `LazyVStack`. Nothing is
/// measured, and only visible rows are built.
struct MasonryGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    /// Width over height. Known up front — from the API for Wallhaven results,
    /// from the file header for local ones — so no measuring is needed.
    let aspect: (Item) -> Double
    let columnWidth: CGFloat
    let spacing: CGFloat
    @ViewBuilder let content: (Item) -> Content

    @State private var available: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                LazyVStack(spacing: spacing) {
                    ForEach(column) { item in
                        content(item)
                            // The tile's height follows from its shape, so the
                            // column can lay out without asking the image.
                            .aspectRatio(max(aspect(item), 0.05), contentMode: .fit)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background {
            // One read of the container width, rather than a measurement pass
            // over every tile.
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    available = width
                }
            }
        }
    }

    /// Column distribution for a given width, so the gate can check the
    /// balancing without standing up a view hierarchy.
    func columnsForVerification(width: CGFloat) -> [[Item]] {
        distribute(into: columnCount(for: width))
    }

    private func columnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int((width + spacing) / (columnWidth + spacing)))
    }

    private var columnCount: Int {
        guard available > 0 else { return 1 }
        return max(1, Int((available + spacing) / (columnWidth + spacing)))
    }

    /// Items dealt into columns, each going to whichever column is shortest.
    ///
    /// Heights are relative — 1/aspect per item — because only their ordering
    /// matters for balancing, not their pixel values.
    private var columns: [[Item]] { distribute(into: columnCount) }

    private func distribute(into count: Int) -> [[Item]] {
        guard count > 1 else { return [items] }

        var buckets = [[Item]](repeating: [], count: count)
        var heights = [Double](repeating: 0, count: count)
        for item in items {
            var shortest = 0
            for index in 1..<count where heights[index] < heights[shortest] {
                shortest = index
            }
            buckets[shortest].append(item)
            heights[shortest] += 1 / max(aspect(item), 0.05)
        }
        return buckets
    }
}
