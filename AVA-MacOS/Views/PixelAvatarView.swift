import SwiftUI

/// Agent avatar — pixel art style matching the iOS app.
/// Generates deterministic appearance from agent ID so it's consistent across sessions.
struct PixelAvatarView: View {
    let agentId: String
    let personality: String?
    var size: CGFloat = 44

    private var appearance: AgentAppearance {
        AgentAppearance.fromId(agentId)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(appearance.clothingColor.gradient)
                .frame(width: size, height: size)

            Canvas { ctx, canvasSize in
                let scale = size / 28
                let ox = (canvasSize.width - 22 * scale) / 2
                let oy = (canvasSize.height - 22 * scale) / 2 + 2 * scale

                func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                    ctx.fill(Path(CGRect(x: ox + x * scale, y: oy + y * scale, width: w * scale, height: h * scale)), with: .color(color))
                }

                let skin = appearance.skinColor
                let hair = appearance.hairColor
                let cloth = appearance.clothingColor
                let white = Color.white
                let black = Color(red: 0.1, green: 0.1, blue: 0.12)
                let dark = Color(red: 0.15, green: 0.15, blue: 0.18)
                let gold = Color.yellow
                let gray = Color(red: 0.35, green: 0.35, blue: 0.38)
                let lensGray = Color(red: 0.2, green: 0.2, blue: 0.22)

                // Hair
                switch appearance.hairStyle {
                case 0: // spiky
                    px(4, 2, 5, 5, hair); px(8, 0, 6, 7, hair); px(13, 2, 5, 5, hair)
                case 1: // flat
                    px(4, 3, 14, 4, hair)
                case 2: // mohawk
                    px(9, 0, 4, 4, hair); px(5, 3, 12, 3, hair)
                default: // parted
                    px(4, 2, 7, 5, hair); px(11, 3, 7, 4, hair)
                }

                // Head
                px(5, 6, 12, 10, skin)

                // Face based on personality
                switch personality {
                case "orchestrator":
                    px(7, -2, 2, 2, gold); px(10, -3, 2, 3, gold); px(13, -2, 2, 2, gold); px(7, 0, 8, 2, gold)
                    px(7, 9, 3, 3, white); px(8, 10, 2, 2, black)
                    px(12, 9, 3, 3, white); px(13, 10, 2, 2, black)

                case "programmer":
                    let mask = Color(red: 0.92, green: 0.90, blue: 0.86)
                    let maskDark = Color(red: 0.25, green: 0.22, blue: 0.20)
                    px(5, 6, 12, 10, mask)
                    px(6, 7, 1, 1, maskDark); px(7, 8, 1, 1, maskDark); px(8, 8, 1, 1, maskDark)
                    px(15, 7, 1, 1, maskDark); px(14, 8, 1, 1, maskDark); px(13, 8, 1, 1, maskDark)
                    px(7, 9, 3, 2, black); px(12, 9, 3, 2, black)
                    px(8, 12, 2, 1, maskDark); px(12, 12, 2, 1, maskDark)
                    px(10, 13, 2, 1, maskDark); px(10, 14, 2, 1, maskDark); px(11, 15, 1, 1, maskDark)
                    px(7, 13, 1, 1, maskDark); px(14, 13, 1, 1, maskDark)
                    px(6, 11, 2, 2, Color.pink.opacity(0.3)); px(14, 11, 2, 2, Color.pink.opacity(0.3))

                case "assistant":
                    px(7, 9, 3, 3, white); px(8, 10, 2, 2, black)
                    px(12, 9, 3, 3, white); px(13, 10, 2, 2, black)
                    px(3, 9, 2, 4, dark); px(4, 8, 1, 1, dark); px(3, 13, 2, 1, gray); px(2, 10, 1, 2, gray)

                case "researcher":
                    px(7, 9, 3, 3, white); px(8, 10, 2, 2, black)
                    px(11, 8, 5, 5, gold); px(12, 9, 3, 3, white); px(13, 10, 2, 2, black); px(16, 13, 1, 3, gold)

                case "marketer":
                    px(7, 9, 3, 3, white); px(8, 10, 2, 2, black)
                    px(12, 9, 3, 3, white); px(13, 10, 2, 2, black)
                    let megaRed = Color(red: 0.85, green: 0.15, blue: 0.15)
                    let megaWhite = Color(red: 0.92, green: 0.92, blue: 0.92)
                    px(17, 11, 2, 2, megaRed); px(19, 10, 2, 4, megaWhite); px(21, 9, 1, 6, megaWhite); px(22, 8, 1, 8, gray)

                case "accountant":
                    px(6, 8, 4, 4, gold); px(7, 9, 2, 2, Color.green.opacity(0.7))
                    px(12, 8, 4, 4, gold); px(13, 9, 2, 2, Color.green.opacity(0.7))
                    px(10, 9, 2, 1, gold)

                case "cofounder":
                    px(6, 8, 4, 4, black); px(7, 9, 2, 2, lensGray)
                    px(12, 8, 4, 4, black); px(13, 9, 2, 2, lensGray)
                    px(10, 9, 2, 1, black); px(5, 9, 1, 1, black); px(16, 9, 1, 1, black)

                case "partner":
                    px(7, 9, 3, 3, white); px(8, 10, 2, 2, black)
                    px(12, 9, 3, 3, white); px(13, 10, 2, 2, black)
                    let kiss = Color(red: 0.85, green: 0.15, blue: 0.25)
                    px(14, 12, 2, 1, kiss); px(15, 11, 1, 1, kiss); px(15, 13, 1, 1, kiss)

                default:
                    px(7, 9, 3, 3, white); px(8, 10, 2, 2, black)
                    px(12, 9, 3, 3, white); px(13, 10, 2, 2, black)
                }

                // Body
                px(4, 16, 14, 6, cloth)
            }
            .frame(width: size, height: size)
        }
        .clipShape(Circle())
    }
}

// MARK: - Deterministic Appearance from Agent ID

struct AgentAppearance {
    let skinTone: Int    // 0-3
    let hairStyle: Int   // 0-3
    let hairColorIndex: Int
    let clothingColorIndex: Int

    static func fromId(_ id: String) -> AgentAppearance {
        let hash = abs(id.hashValue)
        return AgentAppearance(
            skinTone: hash % 4,
            hairStyle: (hash / 4) % 4,
            hairColorIndex: (hash / 16) % Self.hairColors.count,
            clothingColorIndex: (hash / 128) % Self.clothingColors.count
        )
    }

    var skinColor: Color {
        [
            Color(red: 0.96, green: 0.85, blue: 0.74),
            Color(red: 0.92, green: 0.75, blue: 0.60),
            Color(red: 0.76, green: 0.58, blue: 0.42),
            Color(red: 0.55, green: 0.38, blue: 0.26),
        ][skinTone % 4]
    }

    var hairColor: Color { Self.hairColors[hairColorIndex % Self.hairColors.count] }
    var clothingColor: Color { Self.clothingColors[clothingColorIndex % Self.clothingColors.count] }

    static let hairColors: [Color] = [
        Color(red: 0.12, green: 0.10, blue: 0.10),
        Color(red: 0.45, green: 0.30, blue: 0.18),
        Color(red: 0.90, green: 0.78, blue: 0.50),
        Color(red: 0.72, green: 0.22, blue: 0.18),
        Color(red: 0.30, green: 0.50, blue: 0.90),
        Color(red: 0.60, green: 0.30, blue: 0.80),
        Color(red: 0.25, green: 0.70, blue: 0.35),
        Color(red: 0.90, green: 0.45, blue: 0.65),
    ]

    static let clothingColors: [Color] = [
        Color(red: 0.35, green: 0.55, blue: 0.95),
        Color(red: 0.60, green: 0.40, blue: 0.90),
        Color(red: 0.95, green: 0.55, blue: 0.25),
        Color(red: 0.30, green: 0.78, blue: 0.55),
        Color(red: 0.90, green: 0.40, blue: 0.55),
        Color(red: 0.25, green: 0.75, blue: 0.82),
        Color(red: 0.85, green: 0.35, blue: 0.35),
        Color(red: 0.90, green: 0.78, blue: 0.30),
        Color(red: 0.45, green: 0.40, blue: 0.85),
        Color(red: 0.40, green: 0.85, blue: 0.72),
    ]
}
