import SwiftUI

struct HomeView: View {
    @EnvironmentObject var vm: BundleViewModel
    let onBrowse: () -> Void

    var body: some View {
        List {
            Section {
                hero
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                Button(action: onBrowse) {
                    Label("Open from Files…", systemImage: "folder.badge.plus")
                        .font(.headline)
                }
            }

            Section("Recent") {
                if vm.recents.isEmpty {
                    Text("Bundles you open appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.recents) { recent in
                    Button {
                        Task { await vm.open(recent: recent) }
                    } label: {
                        recentRow(recent)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let items = vm.recents
                    for i in offsets { vm.removeRecent(items[i]) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 38, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 84, height: 84)
                .background(
                    LinearGradient(colors: [Theme.accent, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 6)
            Text("UABE")
                .font(.title.weight(.bold))
            Text("Browse, preview and edit Unity AssetBundles")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func recentRow(_ recent: RecentBundle) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 17))
                .foregroundColor(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(recent.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(recent.date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
