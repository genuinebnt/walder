import SwiftUI

struct FiltersPopover: View {
    @Environment(Store.self) private var store
    var dismiss: () -> Void
    @State private var presetName = ""

    private var filters: Binding<SearchFilters> {
        Binding(get: { store.filters }, set: { store.filters = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s4) {
                group("Category") {
                    ForEach(Category.allCases) { category in
                        Toggle(category.label, isOn: binding(for: category))
                    }
                }
                group("Purity") {
                    ForEach(Purity.allCases, id: \.self) { purity in
                        Toggle(purity.rawValue.uppercased(), isOn: binding(for: purity))
                            .tint(purity == .nsfw ? Tokens.danger : purity == .sketchy ? Tokens.warning : Tokens.accent)
                            .disabled(purity != .sfw && store.apiKey.isEmpty)
                    }
                    if store.apiKey.isEmpty {
                        Text("Sketchy and NSFW need an API key.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                group("Sort") {
                    Picker("", selection: filters.sorting) {
                        ForEach(Sorting.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    Toggle("Ascending", isOn: filters.ascending)
                    if store.filters.sorting == .toplist {
                        Picker("Range", selection: filters.topRange) {
                            ForEach(SearchFilters.topRanges, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                group("Resolution") {
                    Picker("", selection: filters.mode) {
                        ForEach(ResolutionMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    // At Least takes one resolution; Exactly accepts several,
                    // which is what Wallhaven's own form does.
                    if store.filters.mode == .exactly {
                        ChipRow(options: SearchFilters.resolutionOptions,
                                isSelected: { store.filters.exactResolutions.contains($0) },
                                select: { resolution in
                                    withAnimation(Tokens.quick) {
                                        if store.filters.exactResolutions.contains(resolution) {
                                            store.filters.exactResolutions.remove(resolution)
                                        } else {
                                            store.filters.exactResolutions.insert(resolution)
                                        }
                                    }
                                })
                    } else {
                        ChipRow(options: SearchFilters.resolutionOptions,
                                isSelected: { $0 == store.filters.resolution },
                                select: { store.filters.resolution = $0 })
                    }
                }
                group("AI Art") {
                    Picker("", selection: Binding(
                        get: { store.filters.aiArt },
                        set: { store.filters.aiArt = $0 })) {
                        Text("Any").tag(Bool?.none)
                        Text("Hide").tag(Bool?.some(false))
                        Text("Only").tag(Bool?.some(true))
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                group("Ratios") {
                    ChipRow(options: SearchFilters.ratioOptions,
                            isSelected: { store.filters.ratios.contains($0) },
                            select: { ratio in
                                withAnimation(Tokens.quick) {
                                    if store.filters.ratios.contains(ratio) { store.filters.ratios.remove(ratio) }
                                    else { store.filters.ratios.insert(ratio) }
                                }
                            })
                }
                group("Color") { colorGrid }

                group("Saved Filters") { presets }

                HStack(spacing: Tokens.s2) {
                    Button("Search") {
                        dismiss()
                        Task { await store.search() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    Button("Clear") { withAnimation(Tokens.normal) { store.filters = SearchFilters() } }
                }
            }
            .padding(Tokens.s4)
        }
        .frame(width: 310)
        .frame(maxHeight: 520)
    }

    private func group<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            Text(label.uppercased()).font(.sectionLabel).foregroundStyle(.secondary)
            content()
        }
    }

    /// Named filter sets. Saving under an existing name overwrites it, so
    /// re-tuning a preset does not leave a near-duplicate behind.
    private var presets: some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            ForEach(store.presets) { preset in
                HStack(spacing: Tokens.s2) {
                    Button {
                        store.applyPreset(preset)
                    } label: {
                        HStack {
                            Text(preset.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text("\(preset.filters.activeCount)")
                                .font(.caption2Mono).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    Button {
                        store.deletePreset(preset)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete this preset")
                }
            }

            HStack(spacing: Tokens.s2) {
                TextField("Name these filters", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(savePreset)
                Button("Save", action: savePreset)
                    .controlSize(.small)
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func savePreset() {
        store.savePreset(named: presetName)
        presetName = ""
    }

    private var colorGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 10), spacing: 5) {
            ForEach(SearchFilters.colorOptions, id: \.self) { hex in
                let selected = store.filters.color == hex
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(hex: hex))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5) }
                    .overlay { if selected { RoundedRectangle(cornerRadius: 5).strokeBorder(Tokens.accent, lineWidth: 2) } }
                    .scaleEffect(selected ? 1.15 : 1)
                    .animation(Tokens.bouncy, value: selected)
                    .onTapGesture { store.filters.color = selected ? nil : hex }
            }
        }
    }

    private func binding(for category: Category) -> Binding<Bool> {
        Binding(get: { store.filters.categories.contains(category) },
                set: { on in
                    if on { store.filters.categories.insert(category) }
                    else if store.filters.categories.count > 1 { store.filters.categories.remove(category) }
                })
    }

    private func binding(for purity: Purity) -> Binding<Bool> {
        Binding(get: { store.filters.purity.contains(purity) },
                set: { on in
                    if on { store.filters.purity.insert(purity) }
                    else if store.filters.purity.count > 1 { store.filters.purity.remove(purity) }
                })
    }
}

struct ChipRow: View {
    let options: [String]
    let isSelected: (String) -> Bool
    let select: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let on = isSelected(option)
                Text(option)
                    .font(.captionMono)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .foregroundStyle(on ? Tokens.accent : .secondary)
                    .background(on ? Tokens.accent.opacity(0.18) : Color.secondary.opacity(0.12), in: .capsule)
                    .overlay { if on { Capsule().strokeBorder(Tokens.accent.opacity(0.5), lineWidth: 0.5) } }
                    .onTapGesture { select(option) }
            }
        }
    }
}

/// Wrapping row of chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
