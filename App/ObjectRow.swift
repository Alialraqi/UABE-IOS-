import SwiftUI

struct ObjectRow: View {
    let item: ObjectItem

    var body: some View {
        HStack(spacing: 12) {
            TypeBadge(type: item.type)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if item.isModified {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                    }
                }
                HStack(spacing: 6) {
                    Text(item.type)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    Text("#\(item.index)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let c = item.container, !c.isEmpty {
                        Text(c)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if let bytes = item.bytes {
                Text(formatBytes(bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct TypeBadge: View {
    let type: String
    var size: CGFloat = 40

    var body: some View {
        let style = TypeStyle.of(type)
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(style.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}
