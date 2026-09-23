import MercuryKit
import SwiftUI

/// One Bots-roster row: avatar, display title, latest-message preview, and
/// activity timestamp. The row's click target is the bot's canonical Bot
/// Chat (resolved server-side into the roster row).
struct BotRow: View {
    @Environment(AppModel.self) private var model
    let bot: BotSummary

    var body: some View {
        NavigationLink(value: AppModel.Route.botChat(model.botChatTarget(for: bot))) {
            HStack(spacing: 10) {
                BotAvatarView(bot: bot, imageData: model.botAvatars[bot.name])
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if bot.pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(bot.title)
                            .lineLimit(1)
                        if bot.isDefault {
                            Text("default")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let preview = bot.preview, !preview.isEmpty {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let description = bot.metaDescription ?? bot.profileDescription,
                        !description.isEmpty
                    {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let activity = bot.lastActivity {
                    Text(activity, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: bot.name) { model.fetchBotAvatarIfNeeded(bot) }
    }
}

/// A bot's face: the fetched avatar image when the profile has one, else the
/// desktop's geometric shape+color vocabulary (with a name-hashed color when
/// the bot never picked one). Unknown legacy shapes (blobatar/sigils) fall
/// back to a circle rather than vanishing.
struct BotAvatarView: View {
    let bot: BotSummary
    let imageData: Data?

    var body: some View {
        if let imageData, let image = platformImage(imageData) {
            image
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            face
        }
    }

    private var face: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                faceShape
                    .fill(color)
                // The desktop faces have eyes; two dots keep the family
                // resemblance without porting the blink animation.
                HStack(spacing: size * 0.18) {
                    Circle().frame(width: size * 0.11, height: size * 0.11)
                    Circle().frame(width: size * 0.11, height: size * 0.11)
                }
                .foregroundStyle(.white.opacity(0.9))
                .offset(y: -size * 0.05)
            }
        }
    }

    private var faceShape: AnyShape {
        switch bot.shape {
        case "squircle": AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case "pill": AnyShape(Capsule())
        case "triangle": AnyShape(TriangleShape())
        case "hexagon": AnyShape(HexagonShape())
        case "cloud", "drop": AnyShape(Circle())  // no native analogue; keep the color
        default: AnyShape(Circle())
        }
    }

    private var color: Color {
        Color(hex: bot.colorHex) ?? Self.hashedColor(for: bot.name)
    }

    /// Deterministic per-name fallback color (FNV-1a → hue), mirroring the
    /// desktop's "every bot gets a stable face" behavior for profiles that
    /// never picked a color.
    static func hashedColor(for name: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
            NSImage(data: data).map(Image.init(nsImage:))
        #else
            UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        path.addLine(to: CGPoint(x: w, y: h * 0.25))
        path.addLine(to: CGPoint(x: w, y: h * 0.75))
        path.addLine(to: CGPoint(x: w * 0.5, y: h))
        path.addLine(to: CGPoint(x: 0, y: h * 0.75))
        path.addLine(to: CGPoint(x: 0, y: h * 0.25))
        path.closeSubpath()
        return path
    }
}

extension Color {
    /// `#rgb` / `#rrggbb` CSS hex, as the desktop stores bot colors.
    init?(hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else {
            return nil
        }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
