import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: BundleViewModel
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage("keepTextureSize") private var keepTextureSize = true
    @AppStorage("bundleCompression") private var bundleCompression = "original"
    @State private var confirmClearRecents = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    HStack(spacing: 10) {
                        ForEach(AppearanceMode.allCases) { mode in
                            tile(mode)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Toggle("Keep original texture size", isOn: $keepTextureSize)
                } header: {
                    Text("Textures")
                } footer: {
                    Text("When you replace a texture with an image of another size, the image is resized to the width and height of the original so the bundle keeps the same layout.")
                }

                Section {
                    Picker("Compression", selection: $bundleCompression) {
                        Text("Keep original").tag("original")
                        Text("None").tag("none")
                        Text("LZ4").tag("lz4")
                        Text("LZ4 HC").tag("lz4hc")
                        Text("LZMA").tag("lzma")
                    }
                    Text("Saved files show their CRC32 checksum in the status line. This reports a checksum; it does not rewrite format-specific CRC metadata, which differs between Unity bundle formats.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Saving")
                } footer: {
                    Text("Compression is applied on the next save. Some legacy bundle formats do not support every compression choice.")
                }

                Section("Storage") {
                    Button {
                        vm.clearTemporaryFiles()
                    } label: {
                        Label("Clear temporary files", systemImage: "trash")
                    }
                    Button(role: .destructive) {
                        confirmClearRecents = true
                    } label: {
                        Label("Clear recent files", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section("Developer") {
                    Link(destination: URL(string: "https://www.tiktok.com/@frezcode")!) {
                        HStack(spacing: 12) {
                            TikTokBadge()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TikTok").foregroundColor(.primary)
                                Text("@frezcode").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(version).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Remove all recent files?", isPresented: $confirmClearRecents, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { vm.clearRecents() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The working copies stored in the app are deleted too. Your original files are not touched.")
            }
        }
    }

    private func tile(_ mode: AppearanceMode) -> some View {
        let selected = appearance == mode.rawValue
        return Button {
            appearance = mode.rawValue
            Haptics.tap()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 22))
                Text(mode.title)
                    .font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(selected ? Theme.accent.opacity(0.15) : Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2)
            )
            .foregroundColor(selected ? Theme.accent : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct TikTokBadge: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black)
            Image(systemName: "music.note")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Color(red: 0.15, green: 0.95, blue: 0.93))
                .offset(x: -1.2, y: -1)
            Image(systemName: "music.note")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Color(red: 1.0, green: 0.16, blue: 0.33))
                .offset(x: 1.2, y: 1)
            Image(systemName: "music.note")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 36, height: 36)
    }
}
