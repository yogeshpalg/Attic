import SwiftUI
import UniformTypeIdentifiers

/// Where the app says who made it, what it is, and what it knows about this Mac.
///
/// The standard About panel would give the name, the icon and a version string.
/// This one also gives the two facts that decide what Attic will find here — the
/// macOS release and how many rules apply to it — because "how does it know
/// where to look on my system" is a fair question and the answer should not be
/// buried in a repository.
struct AboutView: View {

    /// Filled in once these exist. Rendered only when set, so a build never
    /// ships a button that opens a dead page.
    private enum Link {
        static let source = ""
        static let issues = ""
        static let support = ""
    }

    private let store = DefinitionStore()
    private let definitions = RemoteDefinitionSource()
    private let customDefinitions = CustomDefinitionStore()
    private let support = SystemSupport()

    @AppStorage(AtticTheme.storageKey) private var themeID = AtticTheme.fallback.rawValue

    @State private var updateState: UpdateState = .idle
    @State private var customRuleCount = 0
    @State private var customMessage: String?
    @State private var isImporting = false
    @State private var isExporting = false

    private enum UpdateState: Equatable {
        case idle
        case checking
        case updated(version: Int)
        case failed(String)
    }

    private var theme: AtticTheme { AtticTheme.named(themeID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            details
        }
        .frame(width: 420)
        .background(.background)
        .atticTheme(theme)
        .animation(.easeInOut(duration: 0.25), value: themeID)
    }

    // MARK: - Header

    private var header: some View {
        headerContent
    }

    private var headerContent: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(.white.opacity(0.06))
                Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                AtticMark(treatment: .onDark)
                    .frame(width: 60, height: 60)
            }
            .frame(width: 100, height: 100)

            VStack(spacing: 3) {
                Text("Attic")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .kerning(-0.3)
                Text("Find the space you forgot you had")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Text(versionLine)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background {
            ZStack {
                LinearGradient(
                    colors: [theme.deepTop, theme.deepBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [theme.glow.opacity(0.18), .clear],
                    center: UnitPoint(x: 0.68, y: 0.12),
                    startRadius: 0,
                    endRadius: 260
                )
            }
        }
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            credit
            appearance
            catalogueSummary
            customSummary
            if hasAnyLink { links }
            Text("Attic moves what you choose to the Trash. Emptying it is your decision, not the app's.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
    }

    private var credit: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Built by Yogesh Gahlot")
                .font(.system(size: 13, weight: .semibold))
            Text(copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    /// The honest version of "it knows where to look": the release it is running
    /// on, and the number of rules that survived this Mac's version filter.
    private var catalogueSummary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.definitions().count) rules active on macOS \(store.osVersion)")
                    .font(.system(size: 12, weight: .medium))
                Text("Each rule names one place on this Mac, what lives there, and what happens if it goes. Rules that do not apply to this version of macOS are left out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Which catalogue is running. The difference between "the app
                // is wrong" and "the app is out of date" should not require
                // reading a log to establish.
                Text(definitionsLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)

                // The range the locations were actually checked against. A Mac
                // outside it still works; some rules may simply find nothing,
                // and that is worth stating where the rule count is stated.
                Text(verificationLine)
                    .font(.caption)
                    .foregroundStyle(support.isFullyVerified
                                     ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                    .fixedSize(horizontal: false, vertical: true)

                if DefinitionFeed.url != nil {
                    updateControl
                        .padding(.top, 6)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    /// Four themes, chosen by colour rather than by name.
    private var appearance: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "paintpalette")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 7) {
                Text("Appearance")
                    .font(.system(size: 12, weight: .medium))
                ThemePicker(selection: $themeID)
                if #unavailable(macOS 26.0) {
                    Text("Liquid Glass needs macOS 26 or later — the colour applies either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    /// The user's own rules: what they are, how to write them, how to remove
    /// them. The format is open so that whoever knows where their toolchain
    /// hides two gigabytes can say so without waiting for a release.
    private var customSummary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 6) {
                Text(customRuleCount == 0
                     ? "No definitions of your own"
                     : "\(customRuleCount) of your own \(customRuleCount == 1 ? "rule" : "rules")")
                    .font(.system(size: 12, weight: .medium))

                Text("Your rules layer over the built-in ones by id. They are found, measured and explained like any other — and, like fetched rules, they can only move your own files to the Trash. They cannot run commands or claim administrator rights.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("Import…") { isImporting = true }
                    Button("Export template…") { isExporting = true }
                    if customDefinitions.exists {
                        Button("Remove") {
                            customDefinitions.remove()
                            customRuleCount = 0
                            customMessage = "Your definitions were removed."
                        }
                    }
                }
                .controlSize(.small)

                if let customMessage {
                    Text(customMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .onAppear { customRuleCount = customDefinitions.ruleCount }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            adopt(result)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: templateDocument,
            contentType: .json,
            defaultFilename: "attic-definitions"
        ) { _ in }
    }

    private var templateDocument: DefinitionTemplateDocument? {
        try? DefinitionTemplateDocument(data: CustomDefinitionStore.template())
    }

    /// Validation failures are reported with the ids at fault rather than a
    /// generic "invalid file", because the person who wrote the file is the
    /// person reading this message.
    private func adopt(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            do {
                let count = try customDefinitions.replace(withContentsOf: url)
                customRuleCount = customDefinitions.ruleCount
                customMessage = "Imported \(count) \(count == 1 ? "rule" : "rules"). They apply to the next scan."
            } catch let error as CustomDefinitionError {
                customMessage = error.message
            } catch {
                customMessage = "That file could not be imported."
            }
        case .failure:
            customMessage = "That file could not be opened."
        }
    }

    /// Shown only when a feed exists. A "check for updates" button with nowhere
    /// to check is the same lie as a progress bar with nothing loading.
    @ViewBuilder private var updateControl: some View {
        HStack(spacing: 8) {
            Button("Check for new definitions") { Task { await check() } }
                .controlSize(.small)
                .disabled(updateState == .checking)

            switch updateState {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
            case .updated(let version):
                Text("Updated to catalogue \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                // Named rather than softened: a refused catalogue means Attic is
                // running its compiled rules, and the user should know which.
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func check() async {
        guard let feed = DefinitionFeed.url else { return }
        updateState = .checking
        do {
            let payload = try await DefinitionUpdater(feed: feed).update()
            updateState = .updated(version: payload.catalogueVersion)
        } catch let error as DefinitionTrustError {
            updateState = .failed(Self.describe(error))
        } catch {
            updateState = .failed("Could not reach the definitions feed")
        }
    }

    private static func describe(_ error: DefinitionTrustError) -> String {
        switch error {
        case .noTrustedKey: "This build has no signing key, so updates are refused"
        case .malformedDocument: "That catalogue could not be read"
        case .badSignature: "That catalogue was not signed by the expected key"
        case .unsupportedFormat: "That catalogue needs a newer version of Attic"
        case .downgrade: "That catalogue is older than the one already installed"
        }
    }

    private var links: some View {
        HStack(spacing: 14) {
            if let url = URL(string: Link.source), !Link.source.isEmpty {
                SwiftUI.Link("Source code", destination: url)
            }
            if let url = URL(string: Link.issues), !Link.issues.isEmpty {
                SwiftUI.Link("Report an issue", destination: url)
            }
            if let url = URL(string: Link.support), !Link.support.isEmpty {
                SwiftUI.Link("Support development", destination: url)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var hasAnyLink: Bool {
        !(Link.source.isEmpty && Link.issues.isEmpty && Link.support.isEmpty)
    }

    // MARK: - Bundle facts

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    private var definitionsLine: String {
        guard let provenance = definitions.provenance else {
            return "Definitions: built into this version"
        }
        let date = provenance.published.formatted(date: .abbreviated, time: .omitted)
        return "Definitions: catalogue \(provenance.catalogueVersion), \(date)"
    }

    private var verificationLine: String {
        guard support.isFullyVerified else {
            return "This Mac is outside that range — see the notices above your findings."
        }
        return "Locations verified on macOS \(SupportedSystems.testedFloor)–\(SupportedSystems.testedCeiling), Apple silicon."
    }

    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "© Yogesh Gahlot"
    }
}

/// The template, wrapped so the standard save panel can write it.
struct DefinitionTemplateDocument: FileDocument {

    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview("About") {
    AboutView()
}
