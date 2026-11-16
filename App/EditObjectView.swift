import SwiftUI
import UniformTypeIdentifiers

struct EditObjectView: View {
    let item: ObjectItem
    @EnvironmentObject var vm: BundleViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var loadError: String?
    @State private var info: ObjectDataInfo?
    @State private var meshURL: URL?
    @State private var image: UIImage?
    @State private var text = ""
    @State private var readOnlyReason: String?
    @State private var saving = false
    @State private var localError: String?
    @State private var exportItem: ExportItem?
    @State private var audioURL: URL?
    @State private var pendingWAV: URL?
    @State private var showEditor = false
    @StateObject private var player = AudioPlayerBox()

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading…")
                } else if let loadError {
                    errorView(loadError)
                } else if let info {
                    ScrollView {
                        VStack(spacing: 14) {
                            header(info)
                            content(for: info)
                            if info.embeddedBundle == true {
                                Button {
                                    Task {
                                        await vm.openEmbeddedBundle(item)
                                        dismiss()
                                    }
                                } label: {
                                    Label("Open embedded AssetBundle", systemImage: "shippingbox")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(item.name.isEmpty ? "Edit Object" : item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if info != nil {
                        Button {
                            Task {
                                if let url = await vm.exportObject(item) { exportItem = ExportItem(url: url) }
                            }
                        } label: { Image(systemName: "square.and.arrow.up") }
                        Menu {
                            RawDumpActions(item: item, exportItem: $exportItem, onImported: {
                                Task { await load() }
                            })
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let info, isTextual(info), readOnlyReason == nil {
                        Button(saving ? "Saving…" : "Save") { Task { await save(info) } }
                            .fontWeight(.semibold)
                            .disabled(saving)
                    }
                }
            }
        }
        .task { await load() }
        .onDisappear { player.stop() }
        .sheet(item: $exportItem) { export in
            DocumentExporter(url: export.url) { exportItem = nil }
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let image {
                TextureEditorView(title: item.name, image: image) { data in
                    Task { await applyEdited(data) }
                }
            }
        }
        .alert("Error", isPresented: Binding(get: { localError != nil },
                                             set: { if !$0 { localError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(localError ?? "")
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("Failed to load data").font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func header(_ info: ObjectDataInfo) -> some View {
        HStack(spacing: 12) {
            TypeBadge(type: item.type, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name.isEmpty ? item.type : item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(item.type) · #\(item.index) · id \(item.pathId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(formatBytes(Int64(info.bytes)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .card()
    }

    @ViewBuilder
    private func content(for info: ObjectDataInfo) -> some View {
        switch info.kind {
        case "image":
            imageContent
        case "audio":
            audioContent(info)
        case "mesh":
            meshContent
        default:
            textContent
        }
    }

    private var imageContent: some View {
        VStack(spacing: 14) {
            if let image {
                VStack(spacing: 8) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 360)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .card()
            }
            Button {
                showEditor = true
            } label: {
                Label("Draw / Edit", systemImage: "paintbrush.pointed.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(image == nil)
            Button {
                ImportPicker.pick(for: item) { url in
                    guard let url else { return }
                    Task {
                        await vm.importObject(item, from: url)
                        await load()
                    }
                }
            } label: {
                Label("Replace image… (Photos / Files)", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
        }
    }

    private var meshContent: some View {
        VStack(spacing: 8) {
            if let meshURL {
                MeshPreview(url: meshURL)
                    .frame(height: 380)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text("Drag to rotate · pinch to zoom. Use the export button to save the OBJ, or Raw / Dump in the menu to move it to another bundle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .card()
    }

    @ViewBuilder
    private var textContent: some View {
        if let readOnlyReason {
            VStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(readOnlyReason)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .card()
        } else {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 340)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .card()
    }

    @ViewBuilder
    private func audioContent(_ info: ObjectDataInfo) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 40))
                    .foregroundStyle(TypeStyle.of("AudioClip").gradient)
                Text(audioSummary(info)).font(.subheadline)
                if let note = info.note, !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .card()

            section("Current audio") {
                if let audioURL {
                    playButton(audioURL, idle: "Play")
                    Button {
                        Task {
                            if let url = await vm.convertToM4A(audioURL) { exportItem = ExportItem(url: url) }
                        }
                    } label: {
                        Label("Export as M4A (AAC)", systemImage: "music.note")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("Preview is not available for this format.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let pendingWAV {
                section("New audio (not applied yet)") {
                    playButton(pendingWAV, idle: "Play new audio")
                    Button {
                        player.stop()
                        Task {
                            if await vm.applyAudio(item, wav: pendingWAV) {
                                self.pendingWAV = nil
                                await load()
                            }
                        }
                    } label: {
                        Label("Apply replacement", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) {
                        player.stop()
                        self.pendingWAV = nil
                    } label: {
                        Label("Discard", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    player.stop()
                    ImportPicker.pick(for: item) { url in
                        guard let url else { return }
                        Task {
                            if let wav = await vm.prepareAudio(from: url) { pendingWAV = wav }
                        }
                    }
                } label: {
                    Label("Replace with audio…", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Pick an audio file (MP3, M4A, WAV…) or a video (MP4/MOV). Listen to it first, then apply. The new audio is stored as uncompressed PCM, so the bundle grows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func playButton(_ url: URL, idle: String) -> some View {
        Button {
            player.toggle(url)
        } label: {
            Label(player.isPlaying(url) ? "Stop" : idle,
                  systemImage: player.isPlaying(url) ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func audioSummary(_ info: ObjectDataInfo) -> String {
        var parts: [String] = []
        if let f = info.format { parts.append(f) }
        if let c = info.channels, c > 0 { parts.append("\(c) ch") }
        if let hz = info.frequency, hz > 0 { parts.append("\(hz) Hz") }
        if let len = info.length, len > 0 { parts.append(String(format: "%.1f s", len)) }
        return parts.joined(separator: " · ")
    }

    private func isTextual(_ info: ObjectDataInfo) -> Bool {
        info.kind == "text" || info.kind == "json"
    }

    private func applyEdited(_ data: Data) async {
        let url = makeTempDir("UABEPaint").appendingPathComponent("edited.png")
        do {
            try data.write(to: url)
        } catch {
            localError = "Could not store the edited image."
            return
        }
        await vm.importObject(item, from: url)
        await load()
    }

    private func load() async {
        loading = true
        loadError = nil
        guard let sid = vm.sessionId else {
            loadError = "Session is empty"
            loading = false
            return
        }
        let dir = makeTempDir("UABEEdit")
        let out = dir.appendingPathComponent("data.bin")
        do {
            let previewFile = dir.appendingPathComponent("preview.wav")
            let result: ObjectDataInfo = try await Backend.shared.call(
                "get_object_data",
                ["sessionId": sid, "idx": item.index, "outPath": out.path, "previewPath": previewFile.path])
            info = result
            switch result.kind {
            case "image":
                image = UIImage(contentsOfFile: out.path)
                if image == nil { loadError = "The texture could not be decoded." }
            case "audio":
                let dest = dir.appendingPathComponent("audio.\(result.ext ?? "bin")")
                try FileManager.default.moveItem(at: out, to: dest)
                if result.preview == true, FileManager.default.fileExists(atPath: previewFile.path) {
                    audioURL = previewFile
                } else if result.playable == true {
                    audioURL = dest
                } else {
                    audioURL = nil
                }
            case "mesh":
                let obj = dir.appendingPathComponent("mesh.obj")
                try FileManager.default.moveItem(at: out, to: obj)
                meshURL = obj
            default:
                readOnlyReason = nil
                if result.bytes > 2_000_000 {
                    readOnlyReason = "This object is too large to edit here (\(formatBytes(Int64(result.bytes)))).\nUse Export / Import instead."
                } else if let s = String(data: try Data(contentsOf: out), encoding: .utf8) {
                    text = s
                } else {
                    readOnlyReason = "This object contains binary data.\nUse Export / Import instead."
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func save(_ info: ObjectDataInfo) async {
        guard let sid = vm.sessionId else { return }
        if info.kind == "json" {
            let parsed = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            guard parsed is [String: Any] else {
                localError = "Invalid JSON. Must be a JSON object (starts with { … })."
                return
            }
        }
        saving = true
        defer { saving = false }
        do {
            let file = makeTempDir("UABEEdit").appendingPathComponent("edit.txt")
            try Data(text.utf8).write(to: file)
            let _: Empty = try await Backend.shared.call(
                "import_object", ["sessionId": sid, "idx": item.index, "inPath": file.path])
            vm.markModified(item.index)
            vm.showToast("Saved")
            dismiss()
        } catch {
            localError = "Save failed:\n\(error.localizedDescription)"
        }
    }
}
