import AppKit
import SwiftUI

struct SettingsView: View {
    @StateObject private var terminalSettings = TerminalSettings.shared
    @StateObject private var agentSettings = AgentSettings.shared
    @State private var selection: SettingsSelection = .page(.general)
    @State private var searchText = ""

    var body: some View {
        SettingsNavigationSplitView(
            selection: $selection,
            searchText: $searchText,
            terminalSettings: terminalSettings,
            agentSettings: agentSettings,
            pages: SettingsPage.filtered(by: searchText),
            projects: CherryProject.filtered(agentSettings.projects, by: searchText)
        )
        .onChange(of: searchText) { _, _ in
            keepSelectionVisible()
        }
        .onChange(of: agentSettings.projects) { _, _ in
            keepSelectionVisible()
        }
    }

    private func keepSelectionVisible() {
        let visible = visibleSelections()
        guard !visible.isEmpty else { return }
        guard !visible.contains(selection) else { return }
        selection = visible.first ?? .page(.general)
    }

    private func visibleSelections() -> [SettingsSelection] {
        let visible = SettingsPage.filtered(by: searchText).map(SettingsSelection.page)
            + CherryProject.filtered(agentSettings.projects, by: searchText).map { .project($0.root) }
        return visible.isEmpty ? [.emptySearch] : visible
    }
}

enum SettingsSelection: Hashable {
    case page(SettingsPage)
    case project(String)
    case emptySearch
}

struct SettingsNavigationHistory {
    private(set) var entries: [SettingsSelection]
    private(set) var index: Int

    init(initialSelection: SettingsSelection) {
        entries = [initialSelection]
        index = entries.startIndex
    }

    var canGoBack: Bool {
        index > entries.startIndex
    }

    var canGoForward: Bool {
        index < entries.index(before: entries.endIndex)
    }

    mutating func record(_ selection: SettingsSelection) {
        guard entries[index] != selection else { return }

        entries.removeSubrange(entries.index(after: index)..<entries.endIndex)
        entries.append(selection)
        index = entries.index(before: entries.endIndex)
    }

    mutating func goBack() -> SettingsSelection? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func goForward() -> SettingsSelection? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}

private struct SettingsNavigationSplitView: View {
    @Binding var selection: SettingsSelection
    @Binding var searchText: String
    @ObservedObject var terminalSettings: TerminalSettings
    @ObservedObject var agentSettings: AgentSettings
    let pages: [SettingsPage]
    let projects: [CherryProject]

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var navigationHistory = SettingsNavigationHistory(
        initialSelection: .page(.general)
    )
    @FocusState private var isSidebarFocused: Bool

    private var canGoBack: Bool {
        navigationHistory.canGoBack
    }

    private var canGoForward: Bool {
        navigationHistory.canGoForward
    }

    private var sidebarSelection: Binding<SettingsSelection?> {
        Binding(
            get: { selection },
            set: { newSelection in
                if let newSelection {
                    selection = newSelection
                    isSidebarFocused = true
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                if pages.isEmpty, projects.isEmpty {
                    Label("No Results", systemImage: "magnifyingglass")
                        .tag(SettingsSelection.emptySearch)
                } else {
                    if !pages.isEmpty {
                        Section("Settings") {
                            ForEach(pages) { page in
                                Label(page.title, systemImage: page.systemImage)
                                    .tag(SettingsSelection.page(page))
                            }
                        }
                    }

                    if !projects.isEmpty {
                        Section("Projects") {
                            ForEach(projects) { project in
                                Label(project.name, systemImage: "folder")
                                    .tag(SettingsSelection.project(project.root))
                            }
                        }
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            .searchable(
                text: $searchText,
                placement: .sidebar,
                prompt: "Search settings"
            )
            .navigationSplitViewColumnWidth(209)
            .focused($isSidebarFocused)
            .onAppear {
                isSidebarFocused = true
            }
        } detail: {
            selectedPane
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button(action: goBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(!canGoBack)
                    .help("Back")

                    Button(action: goForward) {
                        Label("Forward", systemImage: "chevron.right")
                    }
                    .disabled(!canGoForward)
                    .help("Forward")
                }
                .labelStyle(.iconOnly)
                .controlGroupStyle(.navigation)
            }
        }
        .background(SettingsNativeWindowConfigurator())
        .frame(width: 980, height: 680)
        .onChange(of: selection) { _, newSelection in
            recordNavigation(to: newSelection)
        }
        .task(id: columnVisibility) {
            guard columnVisibility != .detailOnly else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            isSidebarFocused = true
        }
    }

    private func goBack() {
        guard let previousSelection = navigationHistory.goBack() else { return }
        selection = previousSelection
    }

    private func goForward() {
        guard let nextSelection = navigationHistory.goForward() else { return }
        selection = nextSelection
    }

    private func recordNavigation(to newSelection: SettingsSelection) {
        navigationHistory.record(newSelection)
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch selection {
        case .page(.general):
            GeneralSettingsPane(settings: terminalSettings)
        case .page(.terminal):
            TerminalSettingsPane(settings: terminalSettings)
        case .page(.projects):
            ProjectSettingsPane(settings: agentSettings)
        case .page(.agents):
            AgentSettingsPane(settings: agentSettings)
        case .page(.mcp):
            MCPSettingsPane()
        case .project(let root):
            if let project = agentSettings.projects.first(where: { $0.root == root }) {
                ProjectDetailSettingsPane(project: project, settings: agentSettings)
            }
        case .emptySearch:
            SettingsEmptySearchPane(query: searchText)
        }
    }
}

private struct SettingsEmptySearchPane: View {
    let query: String

    var body: some View {
        SettingsPaneScroll(
            title: "No Results",
            subtitle: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No settings are available."
                : "No settings match \"\(query)\".",
            systemImage: "magnifyingglass"
        ) {
            SettingsCard {
                SettingsEmptyState(
                    title: "No settings found",
                    message: "Try searching for a section, project name, or folder path.",
                    systemImage: "magnifyingglass"
                )
            }
        }
    }
}

private struct SettingsNativeWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsNativeWindowChromeView {
        let view = SettingsNativeWindowChromeView()
        DispatchQueue.main.async {
            view.configureWindowChrome()
        }
        return view
    }

    func updateNSView(_ nsView: SettingsNativeWindowChromeView, context: Context) {
        DispatchQueue.main.async {
            nsView.configureWindowChrome()
        }
    }
}

private final class SettingsNativeWindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowChrome()
    }

    func configureWindowChrome() {
        guard let window else { return }
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
    }
}

private extension CherryProject {
    var settingsSearchTokens: String {
        "\(name) \(root) project projects workspace folder commands features appearance color"
    }

    static func filtered(_ projects: [CherryProject], by query: String) -> [CherryProject] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmedQuery.isEmpty
            ? projects
            : projects.filter {
                $0.settingsSearchTokens.localizedCaseInsensitiveContains(trimmedQuery)
            }
        return SettingsProjectOrdering.byName(filtered)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case terminal
    case projects
    case agents
    case mcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .projects: "Projects"
        case .agents: "Agents"
        case .mcp: "MCP"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "App chrome, sidebar, worktrees, and theme behavior"
        case .terminal: "Terminal themes, text, cursor, and contrast"
        case .projects: "Workspaces, local features, and identity colors"
        case .agents: "Agent tools and automatic summaries"
        case .mcp: "Install commands and connection status"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .terminal: "terminal.fill"
        case .projects: "folder.fill"
        case .agents: "sparkles"
        case .mcp: "point.3.connected.trianglepath.dotted"
        }
    }

    var searchTokens: String {
        "\(title) \(subtitle) \(rawValue)"
    }

    static func filtered(by query: String) -> [SettingsPage] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return allCases }
        return allCases.filter {
            $0.searchTokens.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }
}
