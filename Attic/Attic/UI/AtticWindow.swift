import SwiftUI
import AppKit

struct AtticWindow: View {

    @State private var model = ScanModel()
    @State private var isShowingSplash = true

    /// Shared with the About window through preferences rather than passed down,
    /// so changing the theme in one updates the other without either knowing the
    /// other exists.
    @AppStorage(AtticTheme.storageKey) private var themeID = AtticTheme.fallback.rawValue

    private var theme: AtticTheme { AtticTheme.named(themeID) }

    var body: some View {
        ZStack {
            switch model.phase {
            case .firstRun:
                // No sidebar before a scan. Every row in it would be empty, and
                // an empty sidebar is a promise the app cannot keep yet.
                FirstRunView(model: model, theme: theme)
            case .scanning, .review:
                // The sidebar does not collapse. It is how you move around the
                // app, it is five rows long, and the width it would give back is
                // not worth a control that can wedge the window.
                NavigationSplitView(columnVisibility: .constant(.all)) {
                    Sidebar(model: model, theme: theme)
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    ReviewView(model: model)
                }
            }

            if isShowingSplash {
                SplashView(theme: theme)
                    .transition(.opacity)
                    // Clicking through it is faster than waiting, and nobody
                    // should have to watch a logo they have already seen.
                    .onTapGesture { dismissSplash() }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .atticTheme(theme)
        .animation(.easeInOut(duration: 0.3), value: model.phase)
        .animation(.easeInOut(duration: 0.25), value: themeID)
        .task {
            try? await Task.sleep(for: .milliseconds(1500))
            dismissSplash()
        }
        // Asked again whenever Attic comes back to the front, which is when
        // somebody returns from System Settings. For this process the answer
        // cannot have changed — rights are fixed at launch — so the point is not
        // to notice a grant. It is that if the permission was revoked while the
        // app sat in the background, the app stops claiming figures it can no
        // longer stand behind.
        .task {
            let activations = NotificationCenter.default
                .notifications(named: NSApplication.didBecomeActiveNotification)
            for await _ in activations {
                model.refreshDiskAccess()
            }
        }
    }

    private func dismissSplash() {
        guard isShowingSplash else { return }
        withAnimation(.easeOut(duration: 0.45)) { isShowingSplash = false }
    }
}

// MARK: - Splash

/// The first second and a half.
///
/// It says the name and then gets out of the way. No progress bar, because
/// nothing is loading — claiming to work while doing nothing is the oldest lie
/// in software, and this app is built on not telling that kind of story.
private struct SplashView: View {

    let theme: AtticTheme

    @State private var hasAppeared = false
    @State private var hasRevealed = false

    var body: some View {
        ZStack {
            // An attic at dusk: warm at the apex, cool below.
            LinearGradient(
                colors: [theme.deepTop, theme.deepBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            // The light coming in through the skylight, off centre so it reads
            // as a window rather than a spotlight.
            RadialGradient(
                colors: [theme.glow.opacity(0.24), .clear],
                center: UnitPoint(x: 0.62, y: 0.16),
                startRadius: 0,
                endRadius: 420
            )

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.06))
                    Circle()
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    // The cleared row arrives a beat after the chip, so the
                    // splash shows the app's whole idea in one gesture.
                    AtticMark(treatment: .onDark, revealsReclaimed: hasRevealed)
                        .frame(width: 76, height: 76)
                }
                .frame(width: 124, height: 124)
                .shadow(color: theme.glow.opacity(0.35), radius: 26, y: 10)
                .scaleEffect(hasAppeared ? 1 : 0.9)
                .opacity(hasAppeared ? 1 : 0)

                VStack(spacing: 4) {
                    Text("Attic")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .kerning(-0.4)
                    Text("Find the space you forgot you had")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 8)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { hasAppeared = true }
            withAnimation(.easeOut(duration: 0.4).delay(0.45)) { hasRevealed = true }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let model: ScanModel
    /// Passed in rather than read from preferences again.
    ///
    /// Reading it here as well as at the root gave the sidebar a second source
    /// of truth for the same setting, and the two could disagree — which is
    /// exactly what a preview showed: an amber selection capsule inside an
    /// indigo window.
    let theme: AtticTheme

    var body: some View {
        List(selection: Binding(
                get: { model.destination },
                set: { model.destination = $0 ?? .everything }
            )) {
                // The name, at the top of the sidebar, where it stays for the
                // whole session rather than only greeting you once.
                HStack(spacing: 9) {
                    AtticMark()
                        .frame(width: 20, height: 20)
                    Text("Attic")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .kerning(-0.2)
                    Spacer()
                }
                .padding(.bottom, 2)
                .listRowSeparator(.hidden)
                .selectionDisabled()

                // Storage: the space this Mac is using, by kind.
                Section("Storage") {
                    row(.everything, symbol: "chart.pie.fill", title: "Everything",
                        bytes: model.totalFound)

                    // The uninstaller has its own section below, so its category
                    // never appears in the storage list too.
                    let storage = model.categoriesPresent.filter {
                        !$0.isDeveloper && $0 != .removedApps
                    }
                    ForEach(storage) {
                        row(.category($0), symbol: $0.symbol, title: $0.title,
                            bytes: model.total(in: $0))
                    }

                    // The developer group does not render at all when no
                    // developer rule produced anything, so a Mac without Xcode
                    // never learns it exists.
                    ForEach(model.categoriesPresent.filter(\.isDeveloper)) {
                        row(.category($0), symbol: $0.symbol, title: $0.title,
                            bytes: model.total(in: $0))
                    }
                }

                // A separate concern, and a separate menu. What an app left
                // behind is not "storage by kind" — it is a list of software
                // that is gone, and burying it among caches hid it completely.
                Section("Uninstaller") {
                    // The uninstaller proper: pick an app, see its whole
                    // footprint, remove the lot.
                    row(.installedApps, symbol: "trash.fill",
                        title: "Uninstall an app", bytes: 0)

                    if model.categoriesPresent.contains(.removedApps) {
                        row(.category(.removedApps), symbol: Category.removedApps.symbol,
                            title: "Already removed", bytes: model.total(in: .removedApps))
                    }
                }

                // Its own destination: the largest figure on most Macs,
                // belonging to no category, and none of it on offer.
                if let system = model.systemSpace, system.isWorthShowing {
                    Section("Managed by macOS") {
                        row(.managedByMacOS, symbol: "clock.badge.checkmark.fill",
                            title: "Snapshots", bytes: system.purgeable)
                    }
                }
            }
        .safeAreaInset(edge: .bottom) { footer }
        // The List stops painting its own background so the wash below shows
        // through. The window's own material stays behind it, so the sidebar is
        // still translucent — this tints that translucency rather than replacing
        // it with a flat colour.
        .scrollContentBackground(.hidden)
        .background {
            LinearGradient(
                colors: [theme.accent.opacity(0.16), theme.accent.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 252, max: 340)
    }

    private func row(
        _ destination: ScanModel.Destination,
        symbol: String,
        title: String,
        bytes: Int64
    ) -> some View {
        let isSelected = model.destination == destination

        return HStack(spacing: 9) {
            // Every glyph gets the same square, centred. Symbols vary a lot in
            // width, and letting each one set its own left the titles ragged.
            //
            // White on the selected row, accent on the rest: the selected row is
            // a filled capsule in the accent, and an accent glyph on it was
            // drawing colour on colour and vanishing.
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 22, height: 22)

            Text(title)
                .lineLimit(1)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer(minLength: 8)
            // Zero means "this row is a place, not a measurement" — the
            // uninstaller has no total until an app is chosen.
            if bytes > 0 {
                Text(ByteFormat.string(bytes))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .font(.callout)
            }
        }
        .accessibilityLabel("\(title), \(ByteFormat.string(bytes))")
        // Drawn here rather than left to the system. A sidebar's own selection is
        // a pale grey wash that ignores the app's tint, which left the theme
        // stopping at the edge of the sidebar and the white glyph invisible on
        // top of it.
        .listRowBackground(selectionBackground(isSelected))
        .tag(destination)
    }

    /// Tinted Liquid Glass on macOS 26 and later; the same accent as a plain
    /// gradient before that.
    @ViewBuilder
    private func selectionBackground(_ isSelected: Bool) -> some View {
        if isSelected {
            if #available(macOS 26.0, *) {
                Capsule()
                    .fill(theme.accent.opacity(0.9))
                    .glassEffect(.regular.tint(theme.accent).interactive(), in: .capsule)
                    .padding(.vertical, 1)
                    .padding(.trailing, 8)
            } else {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.accent, theme.accent.opacity(0.84)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    }
                    .padding(.vertical, 1)
                    .padding(.trailing, 8)
            }
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
                Divider()

                if model.lifetimeReclaimed > 0 { lifetimeTotal }

                if let space = model.spaceAtStart {
                    Text("Free: \(ByteFormat.string(space.available)) of \(ByteFormat.string(space.total))")
                    if space.purgeable > 0 {
                        Text("plus \(ByteFormat.string(space.purgeable)) macOS can reclaim on demand")
                            .foregroundStyle(.tertiary)
                    }
                }
                // The line that was already here, now load-bearing when the
                // links exist: the source and the place to support the work,
                // where somebody actually looks — rather than only in a panel
                // nobody opens twice.
                HStack(spacing: 6) {
                    if let source = AtticLinks.source {
                        Link("Free and open source", destination: source)
                            .foregroundStyle(.tint)
                    } else {
                        Text("Free and open source")
                            .foregroundStyle(.tint)
                    }

                    if let support = AtticLinks.support {
                        Text("·").foregroundStyle(.tertiary)
                        // Never "Donate". The app is free and says so; this is
                        // an invitation, and a nag would undercut every other
                        // honest thing in here.
                        Link("Support", destination: support)
                            .foregroundStyle(.tint)
                    }
                }
            }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What Attic has moved to the Trash since the counter was last cleared.
    ///
    /// Phrased as "moved to the Trash", never "freed": the Trash is still on the
    /// disk until the user empties it, and this app does not take credit for
    /// space that has not actually come back.
    private var lifetimeTotal: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(ByteFormat.string(model.lifetimeReclaimed)) moved to the Trash")
                    .foregroundStyle(.primary)
                    .fontWeight(.medium)
                Text(lifetimeDetail)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 2)
            Menu {
                Button("Reset counter", systemImage: "arrow.counterclockwise") {
                    model.resetLifetimeTotal()
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reset the lifetime counter")
        }
        .padding(.bottom, 4)
    }

    private var lifetimeDetail: String {
        let items = model.lifetimeItems
        let noun = items == 1 ? "item" : "items"
        guard let since = model.lifetimeSince else { return "\(items) \(noun) in total" }
        return "\(items) \(noun) since \(since.formatted(date: .abbreviated, time: .omitted))"
    }

    private var freeSpaceDescription: String {
        guard let space = model.spaceAtStart else { return "" }
        return "\(ByteFormat.string(space.available)) free of \(ByteFormat.string(space.total))"
    }
}

// MARK: - First run

private struct FirstRunView: View {
    let model: ScanModel
    let theme: AtticTheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // The app's own mark, lit the way the icon is: the roof, and the
            // space under it, with the light falling into it.
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accent.opacity(0.22), theme.accent.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Circle()
                    .strokeBorder(theme.accent.opacity(0.22), lineWidth: 1)
                AtticMark()
                    .frame(width: 68, height: 68)
            }
            .frame(width: 112, height: 112)
            .shadow(color: theme.accent.opacity(0.18), radius: 18, y: 8)
            .padding(.bottom, 18)

            // The name, at the size a name deserves. Eleven points of title bar
            // is not an introduction — this is the one screen where the app has
            // a chance to say who it is before it asks to look through a disk.
            Text("Attic")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [theme.accent, theme.accent.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .kerning(-0.5)

            Text("Find the space you forgot you had")
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text("Every Mac keeps a room in the roof: caches, build leftovers and files from apps you removed months ago. Attic shows you what is up there, tells you what each thing is, and lets you decide.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 440)
                .padding(.top, 14)

            // Three promises, each one a thing the app actually does rather than
            // a claim. They are the reason to trust the button underneath.
            VStack(alignment: .leading, spacing: 14) {
                promise("eye.fill", "A scan only reads", "Nothing on this Mac changes while Attic looks.")
                promise("hand.point.up.left.fill", "Nothing is ticked for you", "Every removal is a choice you make, item by item.")
                // Recoverability, not destination. Almost everything goes to the
                // Trash, but the preview simulators are deleted by a command and
                // an iCloud file is only evicted — so a card promising the Trash
                // for all of it would be the app's first words being untrue.
                promise("arrow.uturn.backward", "Nothing is gone for good",
                        "Almost everything moves to the Trash. Where it works differently, the row says so.")
            }
            .padding(20)
            .frame(maxWidth: 440)
            // Tinted Liquid Glass on macOS 26 and later, so the card carries the
            // theme; a plain material before that.
            .themedGlass(theme, in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 1)
            }
            .padding(.top, 24)

            scanButton
                .padding(.top, 24)

            HStack(spacing: 6) {
                Text("Free and open source · nothing leaves this Mac")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                // Reachable before the first scan, not only from the menu bar.
                // This is the screen where somebody decides whether to trust the
                // app at all, so "who made this" belongs on it.
                Button("About") { openWindow(id: "about") }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.top, 14)

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        // A wash of the accent behind the whole screen, brightest where the mark
        // sits. Enough to feel deliberate, not enough to compete with the text.
        .background {
            RadialGradient(
                colors: [theme.accent.opacity(0.07), .clear],
                center: UnitPoint(x: 0.5, y: 0.28),
                startRadius: 10,
                endRadius: 520
            )
            .ignoresSafeArea()
        }
    }

    private func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            // A fixed square well rather than a bare glyph. Symbols have wildly
            // different widths — an eye is wide, an arrow is narrow — so laying
            // them out by their own size leaves the text column ragged.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.tint.opacity(0.14))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                // Lines the well up with the cap height of the title beside it
                // rather than the top of its line box.
                .offset(y: -1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var scanButton: some View {
        if #available(macOS 26.0, *) {
            Button("Scan this Mac") { model.startScan() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        } else {
            Button("Scan this Mac") { model.startScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

// MARK: - Review

private struct ReviewView: View {
    let model: ScanModel
    @Environment(\.openWindow) private var openWindow
    @State private var expanded: Set<String> = []
    @State private var isConfirming = false
    @State private var areNoticesExpanded = false
    @State private var didCopyVerification = false

    var body: some View {
        Group {
            switch model.destination {
            case .managedByMacOS:
                List { if let system = model.systemSpace { systemSpaceSection(system) } }
            case .installedApps:
                UninstallerView(model: model)
            default:
                List { content }
            }
        }
        .listStyle(.inset)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarItems }
        .safeAreaInset(edge: .bottom) { footer }
        .confirmationDialog(
            prompt.title,
            isPresented: $isConfirming
        ) {
            Button(prompt.confirmLabel, role: .destructive) { model.removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(prompt.message)
        }
    }

    private var title: String {
        switch model.destination {
        case .everything: "Everything"
        case .installedApps: "Uninstall an app"
        // Titled after the menu it was reached from, so the uninstaller reads
        // as its own place rather than another slice of storage.
        case .category(.removedApps): "Already removed"
        case .category(let category): category.title
        case .managedByMacOS: "Managed by macOS"
        }
    }

    @ViewBuilder
    private var content: some View {
        if let space = model.spaceAtStart { capacityHeader(space) }

        // One line, closed, rather than four stacked banners. Anything the scan
        // needs to admit stays one click away instead of pushing the findings —
        // the reason someone opened the app — below the fold.
        if notices.isEmpty == false { noticesSection }

        if let receipt = model.receipt { receiptSection(receipt) }

        if hidden.count > 0 { hiddenBelowFloorRow }

        ForEach(model.findings(in: model.selectedCategory)) { finding in
            FindingRow(
                finding: finding,
                isSelected: model.isSelected(finding),
                isExpanded: expanded.contains(finding.id),
                select: { model.toggle(finding) },
                toggle: {
                    if expanded.contains(finding.id) { expanded.remove(finding.id) }
                    else { expanded.insert(finding.id) }
                }
            )
        }
    }

    private var hasSelectedAllSafe: Bool {
        model.hasSelectedAllSafe(in: model.selectedCategory)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            if model.phase == .scanning {
                Button {
                    model.cancelScan()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .labelStyle(.titleAndIcon)
                .help("Stop the scan")
            } else {
                Menu {
                    Picker("Sort by", selection: Binding(
                        get: { model.sortOrder }, set: { model.sortOrder = $0 }
                    )) {
                        ForEach(ScanModel.SortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.inline)

                    Picker("Show", selection: Binding(
                        get: { model.sizeFloor }, set: { model.sizeFloor = $0 }
                    )) {
                        ForEach(ScanModel.SizeFloor.allCases) { floor in
                            Text(floor.title).tag(floor)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "line.3.horizontal.decrease")
                }
                .labelStyle(.titleAndIcon)
                .help("Change the order and the size floor")

                // A switch, not a filter: it decides what the app is willing to
                // offer at all. On by default, and it says which state it is in
                // rather than making you open a menu to find out.
                Toggle(isOn: Binding(
                    get: { model.protectsAuthoredWork },
                    set: { model.setProtectsAuthoredWork($0) }
                )) {
                    Label(
                        model.protectsAuthoredWork ? "Work protected" : "Protection off",
                        systemImage: model.protectsAuthoredWork ? "lock.shield.fill" : "lock.open"
                    )
                }
                .toggleStyle(.button)
                .labelStyle(.titleAndIcon)
                .help("Hold back chat transcripts, edit history and anything built here that exists nowhere else")

                // Glyph and a short word each. Icon-only was too terse to read
                // at a glance; the original full sentences made the toolbar the
                // loudest thing on screen, when the list is what matters.
                // The same button both ways round. Ticking sixteen rows and then
                // having to untick them one at a time was the kind of small
                // cruelty that makes people stop using the bulk action at all.
                Button {
                    model.toggleSafeSelection(in: model.selectedCategory)
                } label: {
                    Label(
                        hasSelectedAllSafe ? "Deselect safe" : "Select safe",
                        systemImage: hasSelectedAllSafe ? "checklist.unchecked" : "checklist.checked"
                    )
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.safeFindings(in: model.selectedCategory).isEmpty)
                .help(hasSelectedAllSafe
                      ? "Untick the safe items this ticked"
                      : "Tick everything graded safe")

                Button {
                    model.startScan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .labelStyle(.titleAndIcon)
                .help("Scan this Mac again")

                // Icon-only, and last: it is the one button here that changes
                // nothing. The About panel is also where the definitions live,
                // which is not something to go hunting in a menu bar for.
                Button {
                    openWindow(id: "about")
                } label: {
                    Label("About", systemImage: "info.circle")
                }
                .help("About Attic, and the definitions it uses")
            }
        }
    }

    /// Where the disk stands, before a single row is read.
    ///
    /// One bar rather than three numbers: used, what this scan found, and what
    /// macOS is holding, in proportion. The found segment is drawn on top of
    /// used because that is what it is — a slice of the used space, not an
    /// addition to it — and it is tinted so the eye lands on the part that is
    /// actionable.
    private func capacityHeader(_ space: VolumeSpace.Reading) -> some View {
        let total = max(space.total, 1)
        let used = max(space.total - space.available, 0)
        let found = min(model.total(in: model.selectedCategory), used)

        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(ByteFormat.string(found))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(model.phase == .scanning ? "found so far" : "found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.phase == .scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        // Beside the figure it checks, rather than in the
                        // toolbar. It is the answer to "why should I believe
                        // this number", which is a question about this number —
                        // and it was taking a permanent toolbar slot for
                        // something most people will never press.
                        Button(action: copyVerification) {
                            Label(
                                didCopyVerification ? "Copied" : "Check with du",
                                systemImage: didCopyVerification ? "checkmark" : "terminal"
                            )
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(model.findings.isEmpty)
                        .help("Copy a du command that checks these figures against the system")
                    }
                }

                GeometryReader { geometry in
                    let width = geometry.size.width
                    HStack(spacing: 2) {
                        Capsule()
                            .fill(.tint)
                            .frame(width: max(width * Double(found) / Double(total), found > 0 ? 3 : 0))
                        Capsule()
                            .fill(.quaternary)
                            .frame(width: max(width * Double(used - found) / Double(total), 0))
                        Capsule()
                            .fill(.quinary)
                    }
                }
                .frame(height: 8)

                HStack(spacing: 14) {
                    legend(.tint, "Found by this scan")
                    legend(.quaternary, "Used by everything else")
                    legend(.quinary, "Free")
                    Spacer()
                    Text("\(ByteFormat.string(space.available)) free of \(ByteFormat.string(space.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func legend(_ shade: some ShapeStyle, _ text: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(shade).frame(width: 14, height: 6)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Everything the scan has to admit to, in the order it matters.
    ///
    /// All of it used to be four stacked banners, which on a real Mac pushed the
    /// first finding off the bottom of the window. None of it can be dropped —
    /// each line is something the app would otherwise be hiding — so it is
    /// folded into one row that opens.
    private struct Notice: Identifiable {
        let id = UUID()
        let symbol: String
        let tint: Color
        let text: String
    }

    /// Read once. The hardware is not going to change mid-session, and asking
    /// sysctl per row redraw would be silly.
    private var systemSupport: SystemSupport { SystemSupport() }

    private var notices: [Notice] {
        var notices: [Notice] = []

        for rejection in model.rejections {
            notices.append(Notice(
                symbol: "exclamationmark.octagon.fill",
                tint: .red,
                text: "\(model.ruleName(rejection.ruleID)) produced a path that \(rejection.reason.message) — refused"
            ))
        }
        // Placed above the "found nothing" lines it explains. Without it, a rule
        // that came up empty because Apple moved a folder in a release nobody
        // checked reads as "there is nothing here".
        if let warning = systemSupport.warning {
            notices.append(Notice(
                symbol: "desktopcomputer.trianglebadge.exclamationmark",
                tint: .orange,
                text: warning
            ))
        }
        // Two different statements, and conflating them was the old bug. The
        // first is a permission Attic knows it does not have, said before a scan
        // demonstrates it. The second is what a scan actually ran into, which can
        // happen for reasons Full Disk Access would not fix.
        if model.diskAccess == .denied {
            notices.append(Notice(
                symbol: "lock.fill",
                tint: .orange,
                text: "Attic does not have Full Disk Access, so every size here is a floor "
                    + "and some rules will find nothing that is really there."
            ))
        } else if model.someSizesAreUnderstated {
            notices.append(Notice(
                symbol: "lock.fill",
                tint: .orange,
                text: "Some folders could not be read, so the sizes here are lower than what is really there."
            ))
        }
        for entry in model.withheld {
            notices.append(Notice(
                symbol: "hand.raised.fill",
                tint: .secondary,
                text: "\(entry.count) left alone (\(ByteFormat.string(entry.bytes))) because \(entry.reason.message)"
            ))
        }
        for group in model.unavailableSummary {
            notices.append(Notice(
                symbol: "magnifyingglass",
                tint: .secondary,
                text: "\(group.ruleNames.count) \(group.ruleNames.count == 1 ? "rule" : "rules") found nothing — \(group.reason.message)"
            ))
        }
        return notices
    }

    /// Starts a fresh copy of Attic, then quits this one.
    ///
    /// The order matters. The new instance is launched first and this one only
    /// terminates once macOS reports it started, so a launch that fails leaves
    /// somebody with the app they already had rather than no app and no
    /// explanation.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private var noticesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $areNoticesExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(notices) { notice in
                        Label {
                            Text(notice.text)
                        } icon: {
                            Image(systemName: notice.symbol).foregroundStyle(notice.tint)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }

                    if model.someSizesAreUnderstated {
                        // The relaunch is not a detail. macOS fixes what a
                        // process may read when it launches, so granting the
                        // permission changes nothing for the copy already
                        // running — and somebody who is not told that grants it,
                        // sees the same floors, and decides the app is broken.
                        Text(FullDiskAccess.relaunchNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            Button("Open Full Disk Access") {
                                if let url = FullDiskAccess.settingsURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)

                            Button("Quit and Reopen Attic") { relaunch() }
                                .buttonStyle(.link)
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: worstNoticeSymbol)
                        .foregroundStyle(worstNoticeTint)
                    Text(noticeSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The most serious thing in the list decides the glyph, so a refused path
    /// never hides behind a tally of rules that found nothing.
    private var worstNoticeSymbol: String {
        if !model.rejections.isEmpty { return "exclamationmark.octagon.fill" }
        if model.someSizesAreUnderstated { return "lock.fill" }
        return "info.circle"
    }

    private var worstNoticeTint: Color {
        if !model.rejections.isEmpty { return .red }
        if model.someSizesAreUnderstated { return .orange }
        return .secondary
    }

    private var noticeSummary: String {
        if !model.rejections.isEmpty {
            return "\(model.rejections.count) refused \(model.rejections.count == 1 ? "path" : "paths") · \(notices.count) notes about this scan"
        }
        if model.someSizesAreUnderstated {
            return "Some sizes are lower than what is really there · \(notices.count) notes about this scan"
        }
        return "\(notices.count) \(notices.count == 1 ? "note" : "notes") about this scan"
    }


    /// Space macOS holds and will release on its own. Reported separately from the
    /// scan, and deliberately not added to its total: the system gives one figure
    /// for the lot, and snapshots share storage with the live disk and each other,
    /// so no individual one has a size that could be listed next to it.
    private func systemSpaceSection(_ system: SystemSpaceReport) -> some View {
        Section {
            SystemSpaceRow(
                report: system,
                isExpanded: expanded.contains(Self.systemSpaceID),
                toggle: {
                    if expanded.contains(Self.systemSpaceID) {
                        expanded.remove(Self.systemSpaceID)
                    } else {
                        expanded.insert(Self.systemSpaceID)
                    }
                }
            )

            if system.systemUpdateSnapshots.isEmpty == false {
                UpdateSnapshotRow(
                    report: system,
                    isExpanded: expanded.contains(Self.updateSnapshotID),
                    toggle: {
                        if expanded.contains(Self.updateSnapshotID) {
                            expanded.remove(Self.updateSnapshotID)
                        } else {
                            expanded.insert(Self.updateSnapshotID)
                        }
                    }
                )
            }
            // Apple silicon only, and measured on a background task, so it
            // appears a moment after the rest rather than holding up the list.
            if let assets = model.modelAssets, assets.isWorthShowing {
                ModelAssetRow(
                    assets: assets,
                    isExpanded: expanded.contains(Self.modelAssetsID),
                    toggle: {
                        if expanded.contains(Self.modelAssetsID) {
                            expanded.remove(Self.modelAssetsID)
                        } else {
                            expanded.insert(Self.modelAssetsID)
                        }
                    }
                )
            }
        } header: {
            Text("Managed by macOS")
        } footer: {
            Text("Counted separately — macOS reports this as one figure and will free it on its own when the disk fills up.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private static let systemSpaceID = "system.space"
    private static let updateSnapshotID = "system.update-snapshot"
    private static let modelAssetsID = "system.model-assets"

    private var hidden: (count: Int, bytes: Int64) {
        model.hiddenByFloor(in: model.selectedCategory)
    }

    /// The floor decides what is worth showing, never what was found — so what
    /// it hides is still counted, still in the total, and still said out loud.
    private var hiddenBelowFloorRow: some View {
        HStack(spacing: 6) {
            Text("\(hidden.count) smaller \(hidden.count == 1 ? "item" : "items") not shown · \(ByteFormat.string(hidden.bytes))")
            Button("Show everything") { model.sizeFloor = .everything }
                .buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var subtitle: String {
        let count = model.findings(in: model.selectedCategory).count
        let total = ByteFormat.string(model.total(in: model.selectedCategory))

        if model.destination == .installedApps {
            let apps = model.installedApps.count
            return apps == 0
                ? "reading your applications folder"
                : "\(apps) apps · pick one to see everything it would take with it"
        }
        if model.phase == .scanning {
            return "scanning · reading only · \(count) found so far"
        }
        // Counted in apps rather than items: one app that scattered files across
        // nine folders is one decision, and one thing to say.
        if model.destination == .category(.removedApps) {
            return count == 1
                ? "1 app left files behind · \(total)"
                : "\(count) apps left files behind · \(total)"
        }
        return "\(count) items · \(total) found"
    }

    /// What the dialog and the button that opens it will say, given what is
    /// ticked right now. Derived rather than written out, so neither can promise
    /// the Trash for something that is not going there.
    private var prompt: RemovalPrompt {
        RemovalPrompt(selecting: model.selectedFindings)
    }

    /// The one destructive control in the app.
    ///
    /// On Tahoe and later it is Liquid Glass, which is what the system uses for
    /// a prominent action and what makes it read as the live thing in the bar.
    /// Earlier releases get the prominent bordered button they have always had —
    /// a different design for a different system, not a degraded one.
    @ViewBuilder
    private var removeButton: some View {
        if #available(macOS 26.0, *) {
            Button(prompt.confirmLabel) { isConfirming = true }
                .buttonStyle(.glassProminent)
                .disabled(model.selectedFindings.isEmpty)
        } else {
            Button(prompt.confirmLabel) { isConfirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedFindings.isEmpty)
        }
    }

    /// Bytes that were found and reported but that Attic will not offer to
    /// remove — detect-only rules, keep-graded findings, anything needing an
    /// administrator. The headline figure counts them, so it has to say so.
    private var shownOnly: Int64 {
        model.total(in: model.selectedCategory)
            - model.selectableTotal(in: model.selectedCategory)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    // Nothing is ticked for the user. A selection is always their
                    // own act, and the button below stays disabled until it is.
                    Text(model.selectedFindings.isEmpty
                         ? "Nothing selected · tick what you want removed"
                         : "\(model.selectedFindings.count) selected · \(ByteFormat.string(model.selectedBytes))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if shownOnly > 0 {
                        Text("\(ByteFormat.string(shownOnly)) of this is reported for information only")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text(ByteFormat.string(model.total(in: model.selectedCategory)))
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                removeButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    /// What the removal actually did. Reported rather than assumed: the space the
    /// system gives back is not always the total that was selected.
    private func receiptSection(_ receipt: RemovalReceipt) -> some View {
        Section {
            if receipt.wasAbandoned {
                Label(
                    "Nothing was removed. A path failed its safety check between the scan and the removal, so the whole batch was abandoned.",
                    systemImage: "exclamationmark.octagon.fill"
                )
                .foregroundStyle(.red)
                .font(.callout)
            } else {
                Text("Moved \(receipt.trashedCount) \(receipt.trashedCount == 1 ? "item" : "items") to the Trash · \(ByteFormat.string(receipt.bytesTrashed))")
                    .font(.callout)
                if let before = model.spaceAtStart, let after = model.spaceAfterRemoval {
                    let freed = after.available - before.available
                    Text(freed > 0
                         ? "Free space went up by \(ByteFormat.string(freed)). Emptying the Trash is up to you."
                         : "Free space will go up once you empty the Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(receipt.problems) { problem in
                    Text(problem.loggedLine)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Button("Dismiss") { model.dismissReceipt() }
                .buttonStyle(.link)
        } header: {
            Text("Last removal")
        }
    }

    /// Copies a `du -sch` over every path in view, so the figures above can be
    /// checked against the system's own accounting rather than believed.
    private func copyVerification() {
        let command = model.verificationCommand(for: model.selectedCategory)
        guard !command.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        // Says it worked, then goes back to offering. A copy with no
        // acknowledgement leaves you pressing it twice to be sure.
        didCopyVerification = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyVerification = false
        }
    }
}

// MARK: - Uninstaller

/// The uninstaller macOS does not have.
///
/// There is no API for this: no registry, no receipts, nothing to ask. An app is
/// a bundle, and removing it means moving that bundle and the files it wrote
/// under its own identifier to the Trash. Every uninstaller on the Mac works
/// this way, and so does this one — through the same planner, the same three
/// gates and the same receipt as any other removal.
private struct UninstallerView: View {
    let model: ScanModel

    @State private var chosen: InstalledApp?
    @State private var isConfirming = false

    var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detail
                .frame(minWidth: 320)
        }
        .onAppear { model.loadInstalledApps() }
        .confirmationDialog(
            "Uninstall \(chosen?.name ?? "this app")?",
            isPresented: $isConfirming
        ) {
            Button("Move to Trash", role: .destructive) { model.uninstallChosenApp() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app and everything it saved go to the Trash, where you can put them back. Emptying the Trash is up to you.")
        }
    }

    private var appList: some View {
        List(selection: $chosen) {
            ForEach(model.installedApps) { app in
                HStack(spacing: 10) {
                    // The app's real icon: it is installed, so we can ask for it.
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                        .resizable()
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                        Text(app.identifier)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .tag(app)
            }
        }
        .overlay {
            if model.isLoadingApps && model.installedApps.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .onChange(of: chosen) { _, app in model.chooseApp(app) }
    }

    @ViewBuilder
    private var detail: some View {
        if let footprint = model.appFootprint, footprint.app == chosen {
            footprintDetail(footprint)
        } else if chosen != nil {
            ProgressView("Measuring…").controlSize(.small)
        } else {
            ContentUnavailableView(
                "Pick an app",
                systemImage: "app.dashed",
                description: Text("Attic will show you the app and every file it has saved elsewhere, then move the lot to the Trash.")
            )
        }
    }

    private func footprintDetail(_ footprint: AppFootprint) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: footprint.app.bundleURL.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(footprint.app.name)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                        if let version = footprint.app.version {
                            Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
                        }
                        Text(footprint.app.identifier)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(ByteFormat.string(footprint.totalBytes))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("in total").font(.caption).foregroundStyle(.secondary)
                    }
                }

                // The two halves, because they are two different things: the app
                // you installed, and everything it wrote while you used it.
                VStack(spacing: 0) {
                    part("The app itself", ByteFormat.string(footprint.bundleBytes),
                         footprint.app.bundleURL.path)
                    Divider()
                    part(
                        footprint.supportPaths.isEmpty
                            ? "No files saved elsewhere"
                            : "Saved elsewhere, in \(footprint.supportPaths.count) \(footprint.supportPaths.count == 1 ? "place" : "places")",
                        ByteFormat.string(footprint.supportBytes),
                        nil
                    )
                    ForEach(footprint.supportPaths.prefix(8), id: \.self) { path in
                        Divider()
                        HStack {
                            Text(path.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 12)
                    }
                    if footprint.supportPaths.count > 8 {
                        Divider()
                        Text("and \(footprint.supportPaths.count - 8) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 12)
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.quaternary.opacity(0.3))
                }

                if footprint.isRunning {
                    // Trashing a running app leaves a process with no files
                    // underneath it, so this is a wall rather than a warning.
                    HStack(spacing: 8) {
                        Label(
                            "\(footprint.app.name) is running. Quit it before removing it.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                        Spacer()
                        Button("Quit \(footprint.app.name)") { model.quitChosenApp() }
                    }
                }

                HStack {
                    Spacer()
                    uninstallButton(footprint)
                }
            }
            .padding(22)
        }
    }

    private func part(_ title: String, _ size: String, _ path: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                if let path {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Text(size).monospacedDigit().font(.callout)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func uninstallButton(_ footprint: AppFootprint) -> some View {
        if #available(macOS 26.0, *) {
            Button { isConfirming = true } label: {
                Label("Move \(ByteFormat.string(footprint.totalBytes)) to the Trash",
                      systemImage: "trash")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(footprint.isRunning)
        } else {
            Button { isConfirming = true } label: {
                Label("Move \(ByteFormat.string(footprint.totalBytes)) to the Trash",
                      systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(footprint.isRunning)
        }
    }
}

// MARK: - Row

private struct FindingRow: View {
    let finding: Finding
    let isSelected: Bool
    let isExpanded: Bool
    let select: () -> Void
    let toggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                selectionControl

                // A tinted glyph anchors the row and says what kind of thing it
                // is before the name is read. Same shape at every size, so the
                // list has a spine down its left edge.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(glyphColor.opacity(0.16))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: finding.category.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(glyphColor)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    // No file paths in the list. They live in the expansion.
                    Text(finding.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(finding.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                // A chip only where there is a decision to carry. "Safe" needs
                // no badge — most rows are safe, and badging all of them makes
                // the two that are not disappear into the pattern.
                // "Protected" rather than "Detect only" where that is the actual
                // reason, so the row explains itself instead of looking like an
                // unfinished feature.
                if finding.holdsAuthoredWork && !finding.isSelectable {
                    Chip(text: "Protected", symbol: "lock.shield.fill", tint: .blue)
                } else if finding.status == .detectOnly {
                    Chip(text: "Detect only", symbol: "eye.fill", tint: .secondary)
                }
                if finding.grade != .safe {
                    // The one saturated colour in the row, and it never follows
                    // the theme: a caution that changes colour with the
                    // appearance is a caution nobody learns to recognise.
                    Chip(
                        text: finding.grade.label,
                        symbol: finding.grade.symbol,
                        tint: finding.grade.warningColor
                    )
                }

                VStack(alignment: .trailing, spacing: 0) {
                    Text(ByteFormat.string(finding.allocatedSize))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    if finding.wasPartlyUnreadable {
                        // The figure beside this row is a floor, not a total.
                        Text("at least")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 96, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
            }

            if isExpanded { expansion }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background {
            // Selection is the theme's job, in every theme: it is the one state
            // here that means "you chose this".
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(.tint.opacity(0.12))
                      : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.04 : 0)))
        }
        .overlay {
            // A selected row is outlined as well as filled, so the choice reads
            // without relying on a colour difference alone.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.tint.opacity(isSelected ? 0.40 : 0), lineWidth: 1)
        }
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    /// Only offered where Attic can actually act. A row it cannot act on has no
    /// checkbox rather than a disabled one, so the list does not read as a set
    /// of things waiting to be ticked.
    @ViewBuilder
    private var selectionControl: some View {
        if finding.isSelectable {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in select() })) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel("Select \(finding.displayName)")
        } else {
            Image(systemName: "minus")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .frame(width: 14)
                .accessibilityLabel("\(finding.displayName) cannot be removed by Attic")
        }
    }

    private var expansion: some View {
        VStack(alignment: .leading, spacing: 7) {
            sentence("What this is.", finding.explanation.whatThisIs)
            sentence("What stops working.", finding.explanation.whatStopsWorking)
            sentence("Does it come back.", finding.explanation.doesItComeBack)

            Divider().padding(.vertical, 2)

            // A row Attic is not offering describes the action conditionally, so
            // it cannot read as though something is about to happen.
            Text(finding.isSelectable ? finding.action.displayForm : finding.action.conditionalForm)
                .font(.caption.monospaced())
            if finding.holdsAuthoredWork && !finding.isSelectable {
                Text("Held back because this is history, not a cache — nothing regenerates it. Turn off Work protected in the toolbar if you really want it offered.")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            } else if finding.status == .detectOnly {
                Text("Measured but not offered in this release, so nothing here is selectable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    /// What kind of thing this is, not how risky it is. A protected row is the
    /// exception: it is held back for a reason the glyph should carry, so it
    /// takes the same blue as its chip.
    private var glyphColor: Color {
        finding.holdsAuthoredWork && !finding.isSelectable
            ? .blue
            : finding.category.glyphColor
    }
}

// MARK: - Managed by macOS

private struct SystemSpaceRow: View {
    let report: SystemSpaceReport
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Time Machine snapshots")
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Chip(text: "macOS decides", symbol: "gearshape.fill", tint: .secondary)
                Text(ByteFormat.string(report.purgeable))
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

    private var subtitle: String {
        let count = report.timeMachineSnapshots.count
        guard count > 0 else { return "nothing held locally right now" }
        let noun = count == 1 ? "snapshot" : "snapshots"
        guard let oldest = report.oldestSnapshot else { return "\(count) \(noun)" }
        return "\(count) \(noun) · oldest \(oldest.formatted(date: .abbreviated, time: .shortened))"
    }

    private var expansion: some View {
        VStack(alignment: .leading, spacing: 7) {
            sentence("What this is.", report.explanation.whatThisIs)
            sentence("What stops working.", report.explanation.whatStopsWorking)
            sentence("Does it come back.", report.explanation.doesItComeBack)

            Divider().padding(.vertical, 2)

            Text("Attic will not do this for you. Reclaiming it needs an administrator, and macOS will do it by itself when the space is needed:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(report.reclaimCommand)
                .font(.caption.monospaced())
                .textSelection(.enabled)

            ForEach(report.timeMachineSnapshots.prefix(4)) { snapshot in
                Text(snapshot.name)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if report.timeMachineSnapshots.count > 4 {
                Text("and \(report.timeMachineSnapshots.count - 4) more")
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
}

/// The rollback point for a macOS update.
///
/// No size beside it, because it has none of its own — like every snapshot it
/// shares storage with the live disk. It is here because an old update can hold
/// gigabytes, and leaving it off screen means nothing explains where they went.
private struct UpdateSnapshotRow: View {
    let report: SystemSpaceReport
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Roll back a macOS update")
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Chip(text: "Needs an administrator", symbol: "lock.fill", tint: .secondary)
            }

            if isExpanded { expansion }
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
    }

    private var subtitle: String {
        let count = report.systemUpdateSnapshots.count
        return count == 1
            ? "1 update can still be undone"
            : "\(count) updates can still be undone"
    }

    private var expansion: some View {
        VStack(alignment: .leading, spacing: 7) {
            sentence("What this is.", report.updateSnapshotExplanation.whatThisIs)
            sentence("What stops working.", report.updateSnapshotExplanation.whatStopsWorking)
            sentence("Does it come back.", report.updateSnapshotExplanation.doesItComeBack)

            Divider().padding(.vertical, 2)

            Text("Attic will not do this for you. It needs an administrator, and it is the only way back if an update went wrong:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(report.discardUpdateSnapshotCommand)
                .font(.caption.monospaced())
                .textSelection(.enabled)

            ForEach(report.systemUpdateSnapshots) { snapshot in
                Text(snapshot.name)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
}

/// The on-device models. A row that exists to say "this is where six gigabytes
/// went, and no app can take it back" — including this one.
private struct ModelAssetRow: View {
    let assets: OnDeviceModelAssets
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence and Siri models")
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Chip(text: "Attic cannot remove this", symbol: "lock.fill", tint: .secondary)
                Text(ByteFormat.string(assets.bytes))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }

            if isExpanded { expansion }
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
    }

    /// The largest few families by name, because "6 GB of system assets" invites
    /// the question this line answers.
    private var subtitle: String {
        assets.largestFamilies
            .map { "\($0.readableName) \(ByteFormat.string($0.bytes))" }
            .joined(separator: " · ")
    }

    private var expansion: some View {
        VStack(alignment: .leading, spacing: 7) {
            sentence("What this is.", assets.explanation.whatThisIs)
            sentence("What stops working.", assets.explanation.whatStopsWorking)
            sentence("Does it come back.", assets.explanation.doesItComeBack)

            Divider().padding(.vertical, 2)

            Text("These files are on the read-only system volume, protected by System Integrity Protection. No cleaner can delete them — Attic included. Any app that says it can is not telling you the truth about where the space went.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = OnDeviceModelAssets.settingsURL {
                Button("Open Apple Intelligence & Siri settings") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            ForEach(assets.families.sorted { $0.bytes > $1.bytes }) { family in
                HStack(spacing: 6) {
                    Text(family.readableName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(ByteFormat.string(family.bytes))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
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
}

private struct Chip: View {
    let text: String
    var symbol: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                // Glyph as well as colour: the grade has to survive being read
                // by someone who cannot tell the green from the orange.
                Image(systemName: symbol).font(.caption2)
            }
            Text(text).font(.caption2.weight(.semibold))
        }
        // Solid colour rather than a material, so the chip stays readable at
        // both ends of the system transparency setting.
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: .capsule)
    }
}

// MARK: - Formatting

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        guard bytes != 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Preview

/// The sidebar and the list together, under the theme that exposed the problem
/// this preview exists to check: with an amber accent, grade-coloured row icons
/// turned the whole list one shade of orange and hid the warnings inside it.
#Preview("Sidebar and rows") {
    let model = ScanModel()
    model.adopt([
        .preview(.cachesAndLogs, "npm's download cache", "289 files", 254_000_000, .safe),
        .preview(.developerXcode, "Swiftpm", "left behind in 1 place", 522_500_000, .checkFirst),
        .preview(.installers, "Install macOS Tahoe", "last modified 3 months ago", 15_100_000_000, .safe),
        .preview(.removedApps, "Microsoft Edge", "last used 3 months ago", 879_400_000, .checkFirst),
        .preview(.cloudStorage, "Downloaded from iCloud", "1,204 files", 3_200_000_000, .safe),
        .preview(.backups, "Device backups", "2 devices", 44_000_000_000, .keep),
    ])

    // The split view rather than `AtticWindow`, which would spend the first
    // second and a half of every preview showing the splash.
    return NavigationSplitView(columnVisibility: .constant(.all)) {
        Sidebar(model: model, theme: .amber)
            .toolbar(removing: .sidebarToggle)
    } detail: {
        ReviewView(model: model)
    }
    .atticTheme(.amber)
    .frame(width: 980, height: 620)
}

/// The same list under Dusk, whose indigo sits closest to the backups and Xcode
/// glyphs. If any theme was going to swallow a category colour it would be this
/// one, so it gets its own preview rather than a hopeful assumption.
#Preview("Sidebar and rows — Dusk") {
    let model = ScanModel()
    model.adopt([
        .preview(.backups, "Device backups", "2 devices", 44_000_000_000, .keep),
        .preview(.developerXcode, "Build files for old projects", "12 projects", 8_400_000_000, .safe),
        .preview(.cloudStorage, "Downloaded from iCloud", "1,204 files", 3_200_000_000, .safe),
        .preview(.removedApps, "Microsoft Edge", "last used 3 months ago", 879_400_000, .checkFirst),
        .preview(.oldAndUnused, "Old device support", "iPhone 17,2 · 26.4", 6_100_000_000, .checkFirst),
        .preview(.cachesAndLogs, "npm's download cache", "289 files", 254_000_000, .safe),
    ])

    return NavigationSplitView(columnVisibility: .constant(.all)) {
        Sidebar(model: model, theme: .indigo)
            .toolbar(removing: .sidebarToggle)
    } detail: {
        ReviewView(model: model)
    }
    .atticTheme(.indigo)
    .frame(width: 980, height: 620)
}

extension Finding {

    /// Preview-only. Kept beside the preview rather than in the test harness
    /// because the app target cannot see the test target's fixtures.
    fileprivate static func preview(
        _ category: Attic.Category,
        _ name: String,
        _ subtitle: String,
        _ bytes: Int64,
        _ grade: SafetyGrade
    ) -> Finding {
        Finding(
            id: "preview.\(name)",
            ruleID: "preview.rule",
            category: category,
            displayName: name,
            subtitle: subtitle,
            paths: [URL(fileURLWithPath: "/tmp/preview")],
            fileCount: 1,
            allocatedSize: bytes,
            lastUsed: nil,
            grade: grade,
            action: .trash,
            privilege: .user,
            explanation: Explanation(
                whatThisIs: "Preview.", whatStopsWorking: "Nothing.", doesItComeBack: "Yes."
            ),
            status: .active
        )
    }
}
