import SwiftUI
import UniformTypeIdentifiers

struct SyncMatch: Identifiable, Decodable {
    let type: String
    let name: String
    let srcIndex: Int
    let dstIndex: Int
    let srcBytes: Int64?
    let dstBytes: Int64?
    let note: String?
    var id: Int { dstIndex }
}

struct SyncScan: Decodable {
    let matches: [SyncMatch]
    let unmatchedSource: [String]
    let unmatchedTarget: Int
    let sourceUnity: String?
    let targetUnity: String?
}

struct SyncItem: Identifiable, Decodable {
    let type: String
    let name: String
    let dstIndex: Int
    let status: String
    let reason: String?
    var id: Int { dstIndex }
}

struct SyncReport: Decodable {
    let replaced: Int
    let skipped: Int
    let failed: Int
    let items: [SyncItem]
    let modifiedIndices: [Int]
}

struct SyncView: View {
    @EnvironmentObject var vm: BundleViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sourceURL: URL?
    @State private var meshes = true
    @State private var textures = true
    @State private var texts = false
    @State private var matchByPathID = false
    @State private var scan: SyncScan?
    @State private var excluded = Set<Int>()
    @State private var report: SyncReport?
    @State private var busy = false
    @State private var busyText = ""
    @State private var errorText: String?

    private var selectedTypes: [String] {
        var list: [String] = []
        if meshes { list.append("Mesh") }
        if textures { list.append("Texture2D") }
        if texts { list.append("TextAsset") }
        return list
    }

    private var selectedCount: Int {
        guard let scan else { return 0 }
        return scan.matches.filter { !excluded.contains($0.dstIndex) }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                targetSection
                optionsSection
                scanSection
                if let scan { resultSection(scan) }
                if let report { reportSection(report) }
            }
            .navigationTitle("Sync bundles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay { if busy { LoadingCard(text: busyText) } }
            .alert("Error", isPresented: Binding(get: { errorText != nil },
                                                 set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .onDisappear {
            Task { let _: Empty? = try? await Backend.shared.call("sync_close") }
        }
    }

    private var sourceSection: some View {
        Section {
            HStack {
                Image(systemName: "square.and.arrow.down.on.square")
                    .foregroundColor(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceURL?.lastPathComponent ?? "No file chosen")
                        .lineLimit(1)
                    Text("Objects are copied from this file")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(sourceURL == nil ? "Choose…" : "Change…") {
                    FilePicker.pick(types: [.item]) { url in
                        guard let url else { return }
                        sourceURL = url
                        scan = nil
                        report = nil
                        excluded = []
                    }
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("Source bundle")
        }
    }

    private var targetSection: some View {
        Section {
            HStack {
                Image(systemName: "square.and.arrow.up.on.square")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.displayName ?? "No bundle open")
                        .lineLimit(1)
                    Text("Objects here are replaced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(vm.displayName == nil ? "Choose…" : "Change…") {
                    FilePicker.pick(types: [.item]) { url in
                        guard let url else { return }
                        scan = nil
                        report = nil
                        excluded = []
                        Task { await vm.openExternal(url) }
                    }
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("Target bundle")
        } footer: {
            Text("To copy the other way round (for example iOS to Android), open the other file as the target and choose this one as the source.")
        }
    }

    private var optionsSection: some View {
        Section("What to copy") {
            Toggle("Meshes (raw copy)", isOn: $meshes)
            Toggle("Textures (image copy)", isOn: $textures)
            Toggle("Text assets (raw copy)", isOn: $texts)
            Picker("Match objects by", selection: $matchByPathID) {
                Text("Name").tag(false)
                Text("Path ID").tag(true)
            }
            .pickerStyle(.segmented)
        }
    }

    private var scanSection: some View {
        Section {
            Button {
                Task { await runScan() }
            } label: {
                Label("Find matching objects", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .disabled(sourceURL == nil || vm.sessionId == nil || selectedTypes.isEmpty || busy)
        }
    }

    private func resultSection(_ scan: SyncScan) -> some View {
        Group {
            Section {
                if let a = scan.sourceUnity, let b = scan.targetUnity, a != b {
                    Label("Unity versions differ (\(a) and \(b)). Texture and text assets are converted; Mesh raw copies are skipped.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
                Text("\(scan.matches.count) matching objects, \(scan.unmatchedSource.count) only in the source, \(scan.unmatchedTarget) only in the target.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Result")
            }

            Section {
                ForEach(scan.matches) { match in
                    Toggle(isOn: Binding(
                        get: { !excluded.contains(match.dstIndex) },
                        set: { on in
                            if on { excluded.remove(match.dstIndex) } else { excluded.insert(match.dstIndex) }
                        })) {
                        HStack(spacing: 10) {
                            TypeBadge(type: match.type, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.name).lineLimit(1)
                                if let note = match.note, !note.isEmpty {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Matches")
            }

            Section {
                Button {
                    Task { await runApply() }
                } label: {
                    Label("Copy \(selectedCount) objects", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0 || busy)
            }
        }
    }

    private func reportSection(_ report: SyncReport) -> some View {
        Section {
            HStack(spacing: 16) {
                Label("\(report.replaced)", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                Label("\(report.skipped)", systemImage: "arrow.uturn.right.circle.fill").foregroundColor(.orange)
                Label("\(report.failed)", systemImage: "xmark.circle.fill").foregroundColor(.red)
            }
            ForEach(report.items.filter { $0.status != "replaced" }) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.type) · \(item.name)").font(.subheadline)
                    Text(item.reason ?? item.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Done")
        } footer: {
            Text("The bundle is saved and checked automatically. Use Export (Save As…) from the main menu to get the file out of the app.")
        }
    }

    private func runScan() async {
        guard let sid = vm.sessionId, let source = sourceURL else { return }
        busy = true
        busyText = "Comparing bundles…"
        report = nil
        defer { busy = false }
        do {
            let result: SyncScan = try await Backend.shared.call(
                "sync_scan",
                ["sessionId": sid, "sourcePath": source.path, "types": selectedTypes,
                 "match": matchByPathID ? "pathid" : "name"])
            scan = result
            excluded = []
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func runApply() async {
        guard let sid = vm.sessionId, let source = sourceURL else { return }
        busy = true
        busyText = "Copying objects…"
        defer { busy = false }
        do {
            let result: SyncReport = try await Backend.shared.call(
                "sync_apply",
                ["sessionId": sid, "sourcePath": source.path, "types": selectedTypes,
                 "match": matchByPathID ? "pathid" : "name", "exclude": Array(excluded)])
            report = result
            scan = nil
            for index in result.modifiedIndices { vm.markModified(index) }
            Haptics.success()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
