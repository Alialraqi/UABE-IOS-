import SwiftUI

struct TextureEditorView: View {
    let title: String
    let onApply: (Data) -> Void

    @StateObject private var doc: CanvasDocument
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false
    @State private var confirmClear = false
    @State private var confirmReset = false
    @State private var exportItem: ExportItem?

    private let swatches: [Color] = [
        .black, .white, .red, .orange, .yellow, .green, .mint, .cyan, .blue, .purple, .pink, .brown,
    ]

    init(title: String, image: UIImage, onApply: @escaping (Data) -> Void) {
        self.title = title
        self.onApply = onApply
        _doc = StateObject(wrappedValue: CanvasDocument(image: image))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CanvasRepresentable(doc: doc)
                    .background(Color(.systemGray6))
                    .clipped()
                controls
            }
            .navigationTitle(title.isEmpty ? "Texture" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if doc.isDirty { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { doc.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!doc.canUndo)
                    Button { doc.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!doc.canRedo)
                    actionsMenu
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .fontWeight(.semibold)
                        .disabled(!doc.isDirty)
                }
            }
        }
        .sheet(item: $exportItem) { export in
            DocumentExporter(url: export.url) { exportItem = nil }
        }
        .confirmationDialog("Discard your drawing?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .confirmationDialog("Clear the whole texture?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { doc.clearAll() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Go back to the original texture?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { doc.resetToOriginal() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button { doc.fitHandler?() } label: { Label("Fit to screen", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
            Divider()
            Button { doc.flipHorizontal() } label: { Label("Flip horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
            Button { doc.flipVertical() } label: { Label("Flip vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
            Button { doc.invertColors() } label: { Label("Invert colors", systemImage: "circle.lefthalf.filled") }
            Divider()
            Button { exportPNG() } label: { Label("Export PNG…", systemImage: "square.and.arrow.up") }
            Divider()
            Button(role: .destructive) { confirmClear = true } label: { Label("Clear all", systemImage: "trash") }
            Button(role: .destructive) { confirmReset = true } label: { Label("Reset to original", systemImage: "arrow.counterclockwise") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PaintTool.allCases) { tool in
                        toolButton(tool)
                    }
                }
                .padding(.horizontal)
            }

            HStack(spacing: 10) {
                ColorPicker("Color", selection: $doc.color, supportsOpacity: false)
                    .labelsHidden()
                    .scaleEffect(1.15)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                            Circle()
                                .fill(swatch)
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                                .onTapGesture {
                                    doc.color = swatch
                                    Haptics.tap()
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal)

            VStack(spacing: 6) {
                sliderRow("Size", value: $doc.size, range: 1...doc.maxSize, label: "\(Int(doc.size)) px")
                sliderRow("Opacity", value: $doc.opacity, range: 0.05...1, label: "\(Int(doc.opacity * 100))%")
                if doc.tool == .rectangle || doc.tool == .ellipse {
                    Toggle("Filled shape", isOn: $doc.filled)
                        .font(.subheadline)
                }
                if doc.tool == .fill {
                    sliderRow("Tolerance", value: $doc.tolerance, range: 0...128, label: "\(Int(doc.tolerance))")
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func toolButton(_ tool: PaintTool) -> some View {
        let selected = doc.tool == tool
        return Button {
            doc.tool = tool
            Haptics.tap()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 38)
                    .background(selected ? Theme.accent : Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .foregroundColor(selected ? .white : .primary)
                Text(tool.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(selected ? Theme.accent : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.subheadline)
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func apply() {
        guard let data = doc.pngData() else { return }
        Haptics.success()
        onApply(data)
        dismiss()
    }

    private func exportPNG() {
        guard let data = doc.pngData() else { return }
        let name = title.isEmpty ? "texture" : title
        let url = makeTempDir("UABEPaint").appendingPathComponent("\(name).png")
        if (try? data.write(to: url)) != nil {
            exportItem = ExportItem(url: url)
        }
    }
}
