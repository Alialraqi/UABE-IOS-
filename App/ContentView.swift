import SwiftUI
import UniformTypeIdentifiers

private enum ImporterKind {
    case bundle
    case object(ObjectItem)
}

struct ContentView: View {
    @EnvironmentObject var vm: BundleViewModel

    @State private var showSettings = false
    @State private var showSync = false
    @State private var showHistory = false
    @State private var showRecents = false
    @State private var showFilter = false
    @State private var showDiagnostics = false
    @State private var showKeyAlert = false
    @State private var showCloseConfirm = false
    @State private var keyText = ""
    @State private var editItem: ObjectItem?
    @State private var exportItem: ExportItem?

    var body: some View {
        NavigationStack {
            Group {
                if vm.displayName == nil {
                    HomeView(onBrowse: { present(.bundle) })
                } else {
                    objectList
                }
            }
            .navigationTitle(vm.displayName ?? "UABE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if vm.displayName != nil {
                        Button { showRecents = true } label: { Image(systemName: "folder") }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) { mainMenu }
            }
        }
        .overlay { if vm.isLoading { LoadingCard(text: vm.statusText ?? "Working…") } }
        .overlay(alignment: .bottom) { toastView }
        .animation(.default, value: vm.toast)
        .animation(.default, value: vm.isLoading)
        .task { await vm.autoReopenLast() }
        .sheet(isPresented: $showRecents) {
            RecentsSheet(onBrowse: {
                showRecents = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { present(.bundle) }
            })
            .environmentObject(vm)
        }
        .sheet(isPresented: $showFilter) { FilterSheet().environmentObject(vm) }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
        .sheet(item: $editItem) { EditObjectView(item: $0).environmentObject(vm) }
        .sheet(item: $exportItem) { export in
            DocumentExporter(url: export.url) { exportItem = nil }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(vm) }
        .sheet(isPresented: $showSync) { SyncView().environmentObject(vm) }
        .sheet(isPresented: $showHistory) { UndoHistoryView().environmentObject(vm) }
        .alert("Error", isPresented: Binding(get: { vm.errorMessage != nil },
                                             set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("Heads up", isPresented: Binding(get: { vm.warningMessage != nil },
                                                set: { if !$0 { vm.warningMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.warningMessage ?? "")
        }
        .alert("Decryption Key", isPresented: $showKeyAlert) {
            TextField("Key", text: $keyText)
            Button("Save") { Task { await vm.setDecryptionKey(keyText) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Used for AssetBundles encrypted by the Chinese Unity build. Reload the bundle after changing it.")
        }
        .alert("Close viewer?", isPresented: $showCloseConfirm) {
            Button("Close", role: .destructive) { vm.closeBundle() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will close the current bundle view.\n\nThe file stays in Recents so you can reopen it later.")
        }
    }

    private var objectList: some View {
        List {
            Section {
                summaryCard
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            Section {
                typeChips
                controlsRow
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))

            Section {
                ForEach(vm.visibleItems) { item in
                    Button {
                        editItem = item
                    } label: {
                        ObjectRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { editItem = item } label: { Label("Open", systemImage: "pencil") }
                            .tint(Theme.accent)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task { if let url = await vm.exportObject(item) { exportItem = ExportItem(url: url) } }
                        } label: { Label("Export", systemImage: "square.and.arrow.up") }
                            .tint(.green)
                    }
                    .contextMenu { contextActions(for: item) }
                }
                if vm.visibleItems.isEmpty && !vm.items.isEmpty {
                    Text("No objects match your filters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $vm.filter.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search name, type, id")
        .refreshable { await vm.reload() }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: [Theme.accent, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.displayName ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(vm.items.count) objects · \(vm.typeCounts.count) types")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if vm.editedCount > 0 {
                    Text("\(vm.editedCount) edited")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundColor(.orange)
                }
            }
            if let status = vm.statusText, !vm.isLoading {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .card()
    }

    private var typeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", count: vm.items.count, selected: vm.filter.types.isEmpty, type: nil) {
                    vm.filter.types = []
                }
                ForEach(vm.typeCounts) { entry in
                    chip(title: entry.type, count: entry.count, selected: vm.filter.types == [entry.type],
                         type: entry.type) {
                        vm.filter.types = vm.filter.types == [entry.type] ? [] : [entry.type]
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(title: String, count: Int, selected: Bool, type: String?, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 6) {
                if let type {
                    Image(systemName: TypeStyle.of(type).symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .opacity(0.7)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Theme.accent : Color(.secondarySystemGroupedBackground), in: Capsule())
            .foregroundColor(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Button { showFilter = true } label: {
                Label(vm.filter.activeCount > 0 ? "Filter (\(vm.filter.activeCount))" : "Filter",
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.bordered)
            Menu {
                Picker("Sort", selection: $vm.sortMode) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } label: {
                Label("Sort: \(vm.sortMode.rawValue)", systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(.bordered)
            Spacer()
            Text("\(vm.visibleItems.count) shown")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var mainMenu: some View {
        Menu {
            Button { present(.bundle) } label: { Label("Open from Files…", systemImage: "folder.badge.plus") }
            Divider()
            Button {
                Task { await vm.reload() }
            } label: { Label("Reload", systemImage: "arrow.clockwise") }
            .disabled(!vm.hasOpenBundle)
            Button {
                Task { if let url = await vm.exportBundleCopy() { exportItem = ExportItem(url: url) } }
            } label: { Label("Export (Save As…)", systemImage: "square.and.arrow.up") }
            .disabled(!vm.hasOpenBundle)
            Button {
                keyText = vm.storedKey
                showKeyAlert = true
            } label: { Label("Decryption Key", systemImage: "key") }
            Divider()
            Button { showSync = true } label: { Label("Sync bundles…", systemImage: "arrow.left.arrow.right.square") }
            if vm.editedCount > 0 {
                Button { showHistory = true } label: {
                    Label("Edit history · \(vm.editedCount)", systemImage: "clock.arrow.circlepath")
                }
            }
            Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            Button { showDiagnostics = true } label: { Label("Diagnostics", systemImage: "stethoscope") }
            if vm.displayName != nil {
                Button(role: .destructive) {
                    showCloseConfirm = true
                } label: { Label("Close", systemImage: "xmark.circle") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private func contextActions(for item: ObjectItem) -> some View {
        Button { editItem = item } label: { Label("Edit / Preview", systemImage: "pencil") }
        Button {
            Task { if let url = await vm.exportObject(item) { exportItem = ExportItem(url: url) } }
        } label: { Label("Export…", systemImage: "square.and.arrow.up") }
        if item.type != "Mesh" {
            Button { present(.object(item)) } label: { Label("Import…", systemImage: "square.and.arrow.down") }
        }
        if item.isModified {
            Button(role: .destructive) {
                Task { await vm.restoreObject(item) }
            } label: { Label("Restore original", systemImage: "arrow.uturn.backward") }
        }
        Menu {
            RawDumpActions(item: item, exportItem: $exportItem)
        } label: {
            Label("Raw / Dump", systemImage: "square.stack.3d.down.right")
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = vm.toast {
            ToastView(text: toast)
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func present(_ kind: ImporterKind) {
        switch kind {
        case .bundle:
            FilePicker.pick(types: [.item]) { url in
                guard let url else { return }
                Task { await vm.openExternal(url) }
            }
        case .object(let item):
            ImportPicker.pick(for: item) { url in
                guard let url else { return }
                Task { await vm.importObject(item, from: url) }
            }
        }
    }
}
