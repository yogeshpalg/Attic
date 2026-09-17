import SwiftUI

/// The app's mark: a flash storage chip with one row part cleared.
///
/// The same geometry as `Attic.icon`, drawn here as shapes rather than an image
/// so it scales, tints and animates. The app used to borrow `house.lodge.fill`,
/// which was a pun on the name rather than a picture of what the app does —
/// and a house has nothing to do with a disk.
///
/// A chip rather than a Mac on purpose: Apple's guidelines forbid replicating
/// their hardware in an icon, and storage is the honest subject anyway.
///
/// Coordinates are the icon's own 1024 grid, scaled to whatever size the view
/// is given, so the mark and the icon can never drift apart.
struct AtticMark: View {

    /// Drawn over a dark ground, the body goes light and the rows keep their
    /// colour. Over a light ground, the body takes the tint.
    enum Treatment {
        case onDark
        case tinted
    }

    var treatment: Treatment = .tinted
    /// Set to fade the cleared row in, for the splash.
    var revealsReclaimed: Bool = true

    var body: some View {
        ZStack {
            ChipBody()
                .fill(bodyStyle)
            Cells()
                .fill(cellStyle)
            Reclaimed()
                .fill(Color(red: 1.0, green: 0.706, blue: 0.227))
                .opacity(revealsReclaimed ? 1 : 0)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Attic")
    }

    private var bodyStyle: AnyShapeStyle {
        switch treatment {
        case .onDark: AnyShapeStyle(.white)
        case .tinted: AnyShapeStyle(.tint)
        }
    }

    private var cellStyle: AnyShapeStyle {
        switch treatment {
        // Punched out of the light body, which reads at any size and needs no
        // second colour to be legible.
        case .onDark: AnyShapeStyle(Color(red: 0.07, green: 0.13, blue: 0.20))
        case .tinted: AnyShapeStyle(Color.white.opacity(0.92))
        }
    }
}

// MARK: - Geometry

/// A shape authored on the icon's 1024 grid and fitted to whatever rect SwiftUI
/// hands it. Scaling inside the path, rather than with `scaleEffect`, keeps the
/// drawing and the layout box the same size — an earlier version scaled a
/// 1024pt box down inside a 20pt frame and drew the mark off-screen entirely.
private protocol IconGridShape: Shape {
    func addParts(to path: inout Path, compact: Bool)
}

extension IconGridShape {

    /// Below this, detail stops being detail and becomes noise: the four
    /// contacts and three separate rows smear into a grey block in a 20pt
    /// sidebar header. The compact form drops the contacts and draws thicker
    /// rows on a squarer body.
    fileprivate static var compactThreshold: CGFloat { 28 }

    /// The artwork's own bounds within the 1024 grid: chip body through the
    /// bottom of the contacts. The grid's remaining margin is the icon's safe
    /// area, which the in-app mark should not inherit — at 20pt in the sidebar
    /// it would leave half the frame empty and the rows too small to read.
    fileprivate static func artworkBounds(compact: Bool) -> CGRect {
        compact
            ? CGRect(x: 248, y: 248, width: 528, height: 528)
            : CGRect(x: 248, y: 248, width: 528, height: 544)
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let compact = side < Self.compactThreshold

        var path = Path()
        addParts(to: &path, compact: compact)

        let bounds = Self.artworkBounds(compact: compact)
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        return path.applying(
            CGAffineTransform(
                translationX: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2
            )
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.minX, y: -bounds.minY)
        )
    }
}

/// The chip outline and, at larger sizes, its four contacts.
private struct ChipBody: IconGridShape {
    func addParts(to path: inout Path, compact: Bool) {
        guard !compact else {
            path.addRoundedRect(
                in: CGRect(x: 248, y: 248, width: 528, height: 528),
                cornerSize: CGSize(width: 128, height: 128),
                style: .continuous
            )
            return
        }

        path.addRoundedRect(
            in: CGRect(x: 248, y: 248, width: 528, height: 480),
            cornerSize: CGSize(width: 116, height: 116),
            style: .continuous
        )
        for x in stride(from: 332.0, through: 644.0, by: 104.0) {
            path.addRoundedRect(
                in: CGRect(x: x, y: 728, width: 56, height: 64),
                cornerSize: CGSize(width: 28, height: 28),
                style: .continuous
            )
        }
    }
}

/// Two full rows of storage.
private struct Cells: IconGridShape {
    func addParts(to path: inout Path, compact: Bool) {
        let rows: [CGRect] = compact
            ? [CGRect(x: 344, y: 344, width: 336, height: 88),
               CGRect(x: 344, y: 464, width: 336, height: 88)]
            : [CGRect(x: 336, y: 344, width: 352, height: 64),
               CGRect(x: 336, y: 452, width: 352, height: 64)]

        for row in rows {
            path.addRoundedRect(
                in: row,
                cornerSize: CGSize(width: row.height / 2, height: row.height / 2),
                style: .continuous
            )
        }
    }
}

/// The third row, part cleared — the space that came back.
private struct Reclaimed: IconGridShape {
    func addParts(to path: inout Path, compact: Bool) {
        let row = compact
            ? CGRect(x: 344, y: 584, width: 184, height: 88)
            : CGRect(x: 336, y: 560, width: 168, height: 64)

        path.addRoundedRect(
            in: row,
            cornerSize: CGSize(width: row.height / 2, height: row.height / 2),
            style: .continuous
        )
    }
}

// MARK: - Preview

/// The three sizes the mark is actually drawn at, so a change that reads well
/// on the splash but turns to mud in the sidebar is visible here.
#Preview("Mark") {
    VStack(spacing: 24) {
        HStack(alignment: .bottom, spacing: 24) {
            AtticMark(treatment: .tinted).frame(width: 20, height: 20)
            AtticMark(treatment: .tinted).frame(width: 68, height: 68)
            AtticMark(treatment: .tinted).frame(width: 76, height: 76)
        }
        .tint(Color(red: 0.07, green: 0.31, blue: 0.43))

        HStack(alignment: .bottom, spacing: 24) {
            AtticMark(treatment: .onDark).frame(width: 20, height: 20)
            AtticMark(treatment: .onDark).frame(width: 68, height: 68)
            AtticMark(treatment: .onDark, revealsReclaimed: false)
                .frame(width: 76, height: 76)
        }
        .padding(24)
        .background(Color(red: 0.07, green: 0.20, blue: 0.29), in: .rect(cornerRadius: 16))
    }
    .padding(32)
}
