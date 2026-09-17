import SwiftUI

enum MoaTheme {
    static let teal = Color(red: 0.05, green: 0.48, blue: 0.43)
    static let mint = Color(red: 0.48, green: 0.84, blue: 0.73)
    static let coral = Color(red: 0.96, green: 0.39, blue: 0.31)
    static let ink = Color(red: 0.08, green: 0.16, blue: 0.17)
    static let canvas = Color(red: 0.95, green: 0.98, blue: 0.97)
    static let hero = LinearGradient(
        colors: [Color(red: 0.02, green: 0.35, blue: 0.34), Color(red: 0.08, green: 0.59, blue: 0.48)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct MoaPage<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) { content }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 32)
        }
        .background(MoaTheme.canvas.ignoresSafeArea())
    }
}

struct MoaCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            }
            .shadow(color: MoaTheme.ink.opacity(0.06), radius: 14, y: 7)
    }
}

struct MoaSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title3.bold()).foregroundStyle(MoaTheme.ink)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MoaStatusPill: View {
    let text: String
    let systemImage: String
    var color: Color = MoaTheme.teal
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct MoaMetric: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = MoaTheme.teal
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: Circle())
            Text(value).font(.headline).minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MoaSettingsLink<Destination: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let destination: Destination

    init(title: String, subtitle: String, systemImage: String, tint: Color,
         @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.bold())
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MoaPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) }
                else { Text(title) }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(disabled ? Color.gray : MoaTheme.teal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .disabled(disabled)
    }
}

extension View {
    func moaField() -> some View {
        self.padding(13)
            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
