import SwiftUI

/// Rows of images at their own proportions, each row filling the width.
///
/// The other layouts put every wallpaper in a box of the same shape, so a
/// portrait is either letterboxed inside a landscape tile or cropped to fit
/// one. Neither shows the picture as it is.
///
/// This is the layout Photos uses: take images in order, keep adding them to a
/// row until the row is about as tall as wanted, then scale that row to fill
/// the width exactly. Every image keeps its own aspect — portraits come out
/// tall and narrow, panoramas short and wide — and nothing is cropped.
///
/// Like [MasonryGrid] it works from aspect ratios that are already known, so
/// nothing has to be measured and the rows can be built without laying out a
/// single subview.
struct JustifiedGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    /// Width over height.
    let aspect: (Item) -> Double
    /// The height rows aim for before being scaled to fit the width. Rows end
    /// up near this, not exactly on it.
    let targetRowHeight: CGFloat
    let spacing: CGFloat
    @ViewBuilder let content: (Item) -> Content

    @State private var available: CGFloat = 0
    /// Row building is O(items); redoing it every render is felt as scroll
    /// jank at a few thousand wallpapers.
    @State private var cached: (key: String, rows: [Row])?

    struct Row: Identifiable {
        let id: Int
        let items: [Item]
        /// The height every item in this row is drawn at.
        let height: CGFloat
    }

    var body: some View {
        LazyVStack(spacing: spacing) {
            ForEach(rows) { row in
                HStack(spacing: spacing) {
                    ForEach(row.items) { item in
                        content(item)
                            .frame(width: max(row.height * aspect(item), 1),
                                   height: row.height)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    available = width
                }
            }
        }
    }

    /// Rows for a given width, so the gate can check the arithmetic without
    /// standing up a view hierarchy.
    func rowsForVerification(width: CGFloat) -> [Row] {
        build(in: width)
    }

    private var rows: [Row] {
        let key = "\(items.count)|\(Int(available))|\(Int(targetRowHeight))"
            + "|\(items.first.map { String(describing: $0.id) } ?? "")"
        if let cached, cached.key == key { return cached.rows }
        let built = build(in: available)
        // Assigning during body would loop; filled on the next pass.
        Task { @MainActor in self.cached = (key, built) }
        return built
    }

    /// Fills rows to the width, scaling each to fit exactly.
    ///
    /// The rule is the standard one: keep adding while the row's natural height
    /// at full width is still taller than wanted. Adding a wallpaper makes a row
    /// wider, so scaling it back to the container makes it shorter — the row
    /// closes on the first item that would take it below the target.
    private func build(in width: CGFloat) -> [Row] {
        guard width > 1, !items.isEmpty else {
            return items.isEmpty ? [] : [Row(id: 0, items: items, height: targetRowHeight)]
        }

        var rows: [Row] = []
        var current: [Item] = []
        var aspectSum: Double = 0

        func height(for count: Int, sum: Double) -> CGFloat {
            guard sum > 0 else { return targetRowHeight }
            // Width available to the pictures once the gaps are taken out.
            let gaps = spacing * CGFloat(max(count - 1, 0))
            return max((width - gaps) / CGFloat(sum), 1)
        }

        for item in items {
            current.append(item)
            aspectSum += max(aspect(item), 0.05)

            if height(for: current.count, sum: aspectSum) <= targetRowHeight {
                rows.append(Row(id: rows.count, items: current,
                                height: height(for: current.count, sum: aspectSum)))
                current = []
                aspectSum = 0
            }
        }

        // The last row is short of the width, so scaling it to fit would blow
        // its pictures up out of proportion to the rest. It keeps the target
        // height instead, which is what Photos does too.
        if !current.isEmpty {
            let natural = height(for: current.count, sum: aspectSum)
            rows.append(Row(id: rows.count, items: current,
                            height: min(natural, targetRowHeight)))
        }
        return rows
    }
}
