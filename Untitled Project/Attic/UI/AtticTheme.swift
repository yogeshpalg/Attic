import SwiftUI

/// The four appearances.
///
/// Each theme is one accent colour plus the two darks behind it, because the
/// splash and the first-run wash are part of the app's identity and a tint that
/// only reached the buttons would leave them looking borrowed from another app.
///
/// On macOS 26 and later the same colour tints Liquid Glass, so the material
/// picks up the theme rather than sitting grey on top of it. Earlier releases
/// get the tint without the glass, which is a difference in material, not in
/// which controls work.
enum AtticTheme: String, CaseIterable, Identifiable, Sendable {

    /// The default, and the colour of the app's own mark.
    case teal
    /// The warm end of the icon: the cleared row, at full strength.
    case amber
    /// For people who would rather the app did not have an opinion.
    case graphite
    case indigo

    static let storageKey = "attic.theme"

    static let fallback = AtticTheme.teal

    static func named(_ raw: String) -> AtticTheme {
        AtticTheme(rawValue: raw) ?? fallback
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teal: "Attic"
        case .amber: "Skylight"
        case .graphite: "Graphite"
        case .indigo: "Dusk"
        }
    }

    /// Drives every control, glyph and selection in the app.
    var accent: Color {
        switch self {
        case .teal: Color(red: 0.09, green: 0.40, blue: 0.54)
        case .amber: Color(red: 0.78, green: 0.50, blue: 0.09)
        case .graphite: Color(red: 0.36, green: 0.40, blue: 0.45)
        case .indigo: Color(red: 0.35, green: 0.33, blue: 0.72)
        }
    }

    /// The light falling through the skylight on the splash, and the wash behind
    /// the first-run screen.
    var glow: Color {
        switch self {
        case .teal: Color(red: 1.0, green: 0.72, blue: 0.29)
        case .amber: Color(red: 1.0, green: 0.78, blue: 0.36)
        case .graphite: Color(red: 0.78, green: 0.83, blue: 0.90)
        case .indigo: Color(red: 0.74, green: 0.66, blue: 1.0)
        }
    }

    /// Top and bottom of the dark ground the mark sits on.
    var deepTop: Color {
        switch self {
        case .teal: Color(red: 0.07, green: 0.13, blue: 0.20)
        case .amber: Color(red: 0.15, green: 0.10, blue: 0.04)
        case .graphite: Color(red: 0.12, green: 0.13, blue: 0.15)
        case .indigo: Color(red: 0.11, green: 0.10, blue: 0.21)
        }
    }

    var deepBottom: Color {
        switch self {
        case .teal: Color(red: 0.04, green: 0.07, blue: 0.12)
        case .amber: Color(red: 0.08, green: 0.05, blue: 0.02)
        case .graphite: Color(red: 0.07, green: 0.07, blue: 0.08)
        case .indigo: Color(red: 0.06, green: 0.05, blue: 0.12)
        }
    }

    /// How strongly the accent is allowed into the glass. Held well below full
    /// strength: Liquid Glass is meant to carry what is behind it, and a
    /// saturated pane stops being a window and starts being a wall.
    var glassTint: Color { accent.opacity(0.28) }
}

// MARK: - Category colours

extension Untitled_Project.Category {

    /// The colour of a category's glyph in the list.
    ///
    /// Deliberately *not* the theme accent, and deliberately not the safety
    /// grade either.
    ///
    /// It used to be the grade — green for safe, orange for check-first — which
    /// said the same thing as the chip beside it twice, and under the amber
    /// theme turned the whole list into one shade of orange with the warnings
    /// hidden inside it. So the glyph now says *what kind of thing this is*, the
    /// chip says *how careful to be*, and the accent is reserved for things you
    /// can click.
    ///
    /// Every hue here is held at low saturation for two reasons: a muted field
    /// lets the accent read as "interactive" against it whichever theme is on,
    /// and it leaves the saturated warning orange of a "Check first" chip as the
    /// loudest thing in the row, which is where the loudness belongs.
    var glyphColor: Color {
        switch self {
        case .installers: Color(red: 0.31, green: 0.47, blue: 0.62)
        case .removedApps: Color(red: 0.55, green: 0.42, blue: 0.58)
        case .oldAndUnused: Color(red: 0.45, green: 0.50, blue: 0.36)
        case .cachesAndLogs: Color(red: 0.34, green: 0.53, blue: 0.47)
        case .backups: Color(red: 0.40, green: 0.45, blue: 0.64)
        case .cloudStorage: Color(red: 0.36, green: 0.57, blue: 0.70)
        case .developerXcode: Color(red: 0.50, green: 0.38, blue: 0.52)
        case .developerToolchains: Color(red: 0.42, green: 0.48, blue: 0.56)
        }
    }
}

extension SafetyGrade {

    /// Warning colour, fixed across themes.
    ///
    /// A caution that changed colour with the appearance would be a caution
    /// nobody learns to recognise, so this ignores the theme entirely — and the
    /// glyph in the chip carries the same meaning for anyone who cannot separate
    /// the orange from the red.
    var warningColor: Color {
        switch self {
        case .safe: .secondary
        case .checkFirst: .orange
        case .keep: .red
        }
    }
}

// MARK: - Applying a theme

extension View {

    /// Tints the whole hierarchy, and the glass with it where the system has any.
    ///
    /// `tint` rather than an asset-catalog accent colour, because the theme is a
    /// runtime choice: an accent colour in the catalogue is fixed at build time
    /// and macOS only honours it when the user has Multicolor selected.
    func atticTheme(_ theme: AtticTheme) -> some View {
        tint(theme.accent)
    }

    /// Adds tinted Liquid Glass where it exists, and a plain material where it
    /// does not. The shape is passed in so a card and a capsule can share this.
    @ViewBuilder
    func themedGlass(_ theme: AtticTheme, in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(theme.glassTint), in: shape)
        } else {
            background(.quaternary.opacity(0.3), in: shape)
        }
    }
}

/// Four swatches, and the name of the one that is on.
///
/// Swatches rather than a pop-up menu: the thing being chosen is a colour, and a
/// menu of the words "Attic, Skylight, Graphite, Dusk" tells you nothing about
/// what you are picking.
struct ThemePicker: View {

    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AtticTheme.allCases) { theme in
                Button {
                    selection = theme.rawValue
                } label: {
                    swatch(theme)
                }
                .buttonStyle(.plain)
                .help(theme.title)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(
                    theme.rawValue == selection ? [.isSelected, .isButton] : .isButton
                )
            }

            Text(AtticTheme.named(selection).title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }

    fileprivate func swatch(_ theme: AtticTheme) -> some View {
        let isOn = theme.rawValue == selection

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [theme.accent, theme.deepTop],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // A dot of the glow, so a swatch shows both halves of the theme
            // rather than only the accent.
            Circle()
                .fill(theme.glow)
                .frame(width: 6, height: 6)
                .offset(x: 4, y: -4)

            // The ring is outside the swatch rather than drawn on it, so the
            // selected colour is not altered by the thing marking it.
            if isOn {
                Circle()
                    .strokeBorder(theme.accent, lineWidth: 2)
                    .frame(width: 28, height: 28)
            }
        }
        .frame(width: 20, height: 20)
        .padding(4)
    }
}

// MARK: - Preview

/// All four themes at once, each showing the parts that actually change: the
/// dark ground, the mark, a glass card and a prominent button.
#Preview("Themes") {
    VStack(spacing: 14) {
        ForEach(AtticTheme.allCases) { theme in
            HStack(spacing: 14) {
                ZStack {
                    LinearGradient(
                        colors: [theme.deepTop, theme.deepBottom],
                        startPoint: .top, endPoint: .bottom
                    )
                    RadialGradient(
                        colors: [theme.glow.opacity(0.28), .clear],
                        center: UnitPoint(x: 0.7, y: 0.2), startRadius: 0, endRadius: 90
                    )
                    AtticMark(treatment: .onDark).frame(width: 34, height: 34)
                }
                .frame(width: 92, height: 68)
                .clipShape(.rect(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 6) {
                    Text(theme.title).font(.headline)
                    HStack(spacing: 8) {
                        AtticMark().frame(width: 18, height: 18)
                        Button("Scan") {}
                            .controlSize(.small)
                        Text("4.8 GB found")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                .padding(10)
                .themedGlass(theme, in: .rect(cornerRadius: 12))

                Spacer()
            }
            .atticTheme(theme)
        }

        Divider()
        ThemePicker(selection: .constant(AtticTheme.amber.rawValue))
    }
    .padding(20)
    .frame(width: 460)
}
