import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(red: 0.36, green: 0.42, blue: 1.0)
    static let corner: CGFloat = 16
}

extension View {
    func card(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

struct TypeStyle {
    let symbol: String
    let colors: [Color]

    static func of(_ type: String) -> TypeStyle {
        switch type {
        case "Texture2D", "Sprite":
            return TypeStyle(symbol: "photo", colors: [.blue, .cyan])
        case "Mesh":
            return TypeStyle(symbol: "cube", colors: [.purple, .pink])
        case "TextAsset":
            return TypeStyle(symbol: "doc.text", colors: [.green, .mint])
        case "AudioClip":
            return TypeStyle(symbol: "waveform", colors: [.pink, .orange])
        case "GameObject", "Transform":
            return TypeStyle(symbol: "square.stack.3d.up", colors: [.teal, .blue])
        case "MonoBehaviour", "MonoScript":
            return TypeStyle(symbol: "curlybraces", colors: [.orange, .yellow])
        case "Material", "Shader":
            return TypeStyle(symbol: "paintpalette", colors: [.indigo, .purple])
        case "AssetBundle":
            return TypeStyle(symbol: "shippingbox", colors: [.brown, .orange])
        default:
            return TypeStyle(symbol: "questionmark.square.dashed", colors: [.gray, .gray.opacity(0.7)])
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct LoadingCard: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text(text).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}
