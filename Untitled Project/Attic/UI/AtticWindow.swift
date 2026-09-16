import SwiftUI
import AppKit

struct AtticWindow: View {

    @State private var model = ScanModel()

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
        } detail: {
            switch model.phase {
            case .firstRun: FirstRunView(model: model)
            case .scanning, .review: ReviewView(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let model: ScanModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedCategory },
            set: { model.selectedCategory = $0 }
        )) {
            Section {
                row(nil, title: "Everything", bytes: model.totalFound)
            }

            let general = model.categoriesPresent.filter { !$0.isDeveloper }
            if !general.isEmpty {
                Section("On this Mac") {
                    ForEach(general) { row($0, title: $0.title, bytes: model.total(in: $0)) }
                }
            }

            // The developer group does not render at all when no developer rule
            // produced anything, so a Mac without Xcode never learns it exists.
            let developer = model.categoriesPresent.filter(\.isDeveloper)
            if !developer.isEmpty {
                Section("Detected") {
                    ForEach(developer) { row($0, title: $0.title, bytes: model.total(in: $0)) }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func row(_ category: Category?, title: String, bytes: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(ByteFormat.string(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .tag(category)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            if let space = model.spaceAtStart {
                Text("Free: \(ByteFormat.string(space.available)) of \(ByteFormat.string(space.total))")
                if space.purgeable > 0 {
                    Text("plus \(ByteFormat.string(space.purgeable)) macOS can reclaim on demand")
                        .foregroundStyle(.tertiary)
                }
            }
            Text("Free and open source")
                .foregroundStyle(.tint)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - First run

private struct FirstRunView: View {
    let model: ScanModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .padding(.bottom, 6)

            Text("See what's taking up your disk")
                .font(.title2.weight(.semibold))

            Text("Attic looks through caches, logs and leftover build files, then tells you what each one is before anything is removed.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            GroupBox {
                Text("This build can only read. No removal code is compiled into it, so a scan cannot change anything on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380, alignment: .leading)
            }
            .padding(.vertical, 8)

            Button("Scan this Mac") { model.startScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
    }
}

// MARK: - Review

private struct ReviewView: View {
    let model: ScanModel
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            if !model.rejections.isEmpty { rejectionBanner }
            if !model.withheld.isEmpty { withheldBanner }
            if !model.unavailable.isEmpty { unavailableBanner }

            ForEach(model.findings(in: model.selectedCategory)) { finding in
                FindingRow(
                    finding: finding,
                    isExpanded: expanded.contains(finding.id),
                    toggle: {
                        if expanded.contains(finding.id) { expanded.remove(finding.id) }
                        else { expanded.insert(finding.id) }
                    }
                )
            }
        }
        .listStyle(.inset)
        .navigationTitle(model.selectedCategory?.title ?? "Everything")
        .navigationSubtitle(subtitle)
        .toolbar {
            if model.phase == .scanning {
                Button("Cancel") { model.cancelScan() }
            } else {
                Button("Copy du command") { copyVerification() }
                Button("Scan again") { model.startScan() }
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    /// A rule that withholds matches says so. Silence here would make a broken
    /// retention rule indistinguishable from an empty folder.
    private var withheldBanner: some View {
        Section {
            ForEach(model.withheld) { entry in
                Text("\(entry.count) left alone (\(ByteFormat.string(entry.bytes))) because \(entry.reason.message)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Deliberately kept")
        }
    }

    private var subtitle: String {
        let count = model.findings(in: model.selectedCategory).count
        let total = ByteFormat.string(
            model.selectedCategory.map { model.total(in: $0) } ?? model.totalFound
        )
        return model.phase == .scanning
            ? "scanning · reading only · \(count) found so far"
            : "\(count) items · \(total) found"
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                // Nothing is pre-selected, and this build offers no selection at
                // all — removal arrives with the test harness, not before it.
                Text("Read-only build · nothing here can be removed yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(
                    model.selectedCategory.map { model.total(in: $0) } ?? model.totalFound
                ))
                .font(.title3.weight(.medium))
                .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var rejectionBanner: some View {
        Section {
            ForEach(Array(model.rejections.enumerated()), id: \.offset) { _, rejection in
                Label(
                    "\(rejection.ruleID) produced a path that \(rejection.reason.message) — refused",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .foregroundStyle(.red)
                .font(.callout)
            }
        } header: {
            Text("Refused paths")
        }
    }

    private var unavailableBanner: some View {
        Section {
            ForEach(Array(model.unavailable.enumerated()), id: \.offset) { _, entry in
                Text("\(entry.ruleID) was skipped — \(entry.reason.message)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Not scanned")
        }
    }

    private func copyVerification() {
        let command = model.verificationCommand(for: model.selectedCategory)
        guard !command.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

// MARK: - Row

private struct FindingRow: View {
    let finding: Finding
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    // No file paths in the list. They live in the expansion.
                    Text(finding.displayName)
                        .fontWeight(.medium)
                    Text(finding.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if finding.status == .detectOnly {
                    Chip(text: "Detect only", tint: .secondary)
                }
                Chip(text: finding.grade.label, tint: tint)
                Text(ByteFormat.string(finding.allocatedSize))
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .frame(width: 84, alignment: .trailing)
            }

            if isExpanded { expansion }
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
    }

    private var expansion: some View {
        VStack(alignment: .leading, spacing: 7) {
            sentence("What this is.", finding.explanation.whatThisIs)
            sentence("What stops working.", finding.explanation.whatStopsWorking)
            sentence("Does it come back.", finding.explanation.doesItComeBack)

            Divider().padding(.vertical, 2)

            Text(finding.action.displayForm)
                .font(.caption.monospaced())
            if finding.privilege == .administrator {
                Text("Needs an administrator — Attic will offer Reveal in Finder instead of removing it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(finding.paths.prefix(4), id: \.self) { path in
                Text(path.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if finding.paths.count > 4 {
                Text("and \(finding.paths.count - 4) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 7))
    }

    private func sentence(_ lead: String, _ body: String) -> some View {
        Text("**\(lead)** \(body)")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var tint: Color {
        switch finding.grade {
        case .safe: .green
        case .checkFirst: .orange
        case .keep: .red
        }
    }
}

private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            // Solid colour rather than a material, so the chip stays readable at
            // both ends of the system transparency setting.
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: .rect(cornerRadius: 4))
    }
}

// MARK: - Formatting

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        guard bytes != 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
