import SwiftUI

/// Menu bar popover — set a wallpaper without opening the window.
struct QuickSetView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.s3) {
            HStack {
                Text("Lumen").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(store.rotationEnabled ? "next in \(store.rotationMinutes)m" : "paused")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Group {
                if let current = store.current {
                    AsyncImage(url: current.thumb) { $0.resizable().scaledToFill() }
                        placeholder: { Rectangle().fill(.quaternary).shimmer() }
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Text("Nothing set").font(.captionMono).foregroundStyle(.secondary) }
                }
            }
            .aspectRatio(16.0/10, contentMode: .fill)
            .frame(height: 178)
            .clipShape(.rect(cornerRadius: 9))

            HStack(spacing: Tokens.s2) {
                Button {
                    store.shuffleNow()
                } label: {
                    Label("Shuffle now", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Toggle(isOn: Binding(get: { store.rotationEnabled }, set: { store.rotationEnabled = $0 })) {
                    Image(systemName: store.rotationEnabled ? "play.fill" : "pause.fill")
                }
                .toggleStyle(.button)
                .help("Pause or resume rotation")
            }

            if !store.recents.isEmpty {
                Text("RECENT").font(.sectionLabel).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(store.recents.prefix(3)) { wallpaper in
                        AsyncImage(url: wallpaper.thumb) { $0.resizable().scaledToFill() }
                            placeholder: { Rectangle().fill(.quaternary) }
                            .frame(height: 46)
                            .frame(maxWidth: .infinity)
                            .clipShape(.rect(cornerRadius: 6))
                            .onTapGesture { store.setWallpaper(wallpaper) }
                    }
                }
            }

            Divider()
            HStack {
                Button("Open Lumen") { NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.link)
                Button("Close") { dismissPopover() }
                    .buttonStyle(.link)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
            }
            .font(.system(size: 11.5))
        }
        .padding(Tokens.s3)
        .frame(width: 322)
    }

    /// MenuBarExtra(.window) has no dismiss environment value, so close the
    /// panel the popover is hosted in directly.
    private func dismissPopover() {
        NSApp.keyWindow?.close()
    }
}
