import Combine
import Foundation

@MainActor
final class ProjectWorkspaceContext {
    let repository: RepositoryWorkspace
    let noteStore: ProjectNoteStore
    let todoStore: ProjectTodoStore
    let activity: ProjectAggregateStatus

    private let settings: AgentSettings
    private(set) var didStart = false
    var selection = ProjectSelectionState.terminal

    init(
        projectRoot: String,
        settings: AgentSettings = .shared,
        createInitialSession: Bool = true
    ) {
        let repository = RepositoryWorkspace(
            projectRoot: projectRoot,
            createInitialSession: createInitialSession
        )
        self.repository = repository
        self.settings = settings
        noteStore = ProjectNoteStore(projectRoot: repository.repositoryRoot, loadsInBackground: true)
        todoStore = ProjectTodoStore(projectRoot: repository.repositoryRoot)
        activity = ProjectAggregateStatus(repository: repository)
    }

    var projectRoot: String {
        repository.repositoryRoot
    }

    var workspace: TerminalWorkspace {
        repository.activeWorkspace
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true

        if let projectRoot = workspace.projectRoot {
            for command in settings.launchableProjectCommands(for: projectRoot)
            where command.autoStart {
                workspace.addCommandSession(command: command, projectRoot: projectRoot, select: false)
            }
        }

        Task { [weak repository] in
            await repository?.refresh()
        }
    }

    func closeAllSessions() {
        repository.closeAllSessions()
    }

    func scheduleHiddenAgentSummaries() {
        repository.allLoadedWorkspaces().forEach { workspace in
            workspace.scheduleHiddenAgentSummaries()
        }
    }

    func runningProcessCount() -> Int {
        repository.runningProcessCount()
    }
}

@MainActor
final class ProjectWindowModel: ObservableObject {
    @Published private(set) var activeProjectRoot: String?
    @Published private(set) var contexts: [String: ProjectWorkspaceContext] = [:]
    @Published private var expandedProjectRootsBySection: [ProjectSidebarSection: Set<String>] = [:]
    @Published private(set) var commandAddRequestRevision = 0

    let chromeState = ProjectWindowChromeState()

    private let settings: AgentSettings
    private let startsContextsOnActivation: Bool
    private let notifiesRegistry: Bool
    private var pendingCommandAddProjectRoots: Set<String> = []

    init(
        initialProjectRoot: String?,
        settings: AgentSettings = .shared,
        startsContextsOnActivation: Bool = true,
        notifiesRegistry: Bool = true
    ) {
        self.settings = settings
        self.startsContextsOnActivation = startsContextsOnActivation
        self.notifiesRegistry = notifiesRegistry
        if let initialProjectRoot {
            _ = activate(projectRoot: initialProjectRoot)
        }
    }

    var activeContext: ProjectWorkspaceContext? {
        guard let activeProjectRoot else { return nil }
        return contexts[activeProjectRoot]
    }

    var activeWorkspace: TerminalWorkspace? {
        activeContext?.workspace
    }

    var activeNoteStore: ProjectNoteStore? {
        activeContext?.noteStore
    }

    var activeTodoStore: ProjectTodoStore? {
        activeContext?.todoStore
    }

    var loadedProjectRoots: [String] {
        Array(contexts.keys)
    }

    func context(for requestedRoot: String) -> ProjectWorkspaceContext? {
        let root = Self.standardizedRoot(requestedRoot)
        if let direct = contexts[root] {
            return direct
        }
        return contexts.values.first { context in
            context.repository.contains(worktreeRoot: root)
        }
    }

    @discardableResult
    func activate(
        projectRoot requestedRoot: String,
        activateWorktree: Bool = true
    ) -> ProjectWorkspaceContext? {
        let requestedRoot = Self.standardizedRoot(requestedRoot)
        let existingContext = context(for: requestedRoot)
        if existingContext == nil,
           notifiesRegistry,
           ProjectWindowRegistry.shared.focusExistingProject(
               projectRoot: requestedRoot,
               excluding: self,
               activateWorktree: activateWorktree
           ) {
            return nil
        }
        let nextContext = existingContext ?? loadContext(projectRoot: requestedRoot)
        guard let nextContext else { return nil }
        let previousContext = activeContext

        if let previousContext, previousContext !== nextContext {
            previousContext.selection = ProjectSelectionState(chromeState: chromeState)
        }

        activeProjectRoot = nextContext.projectRoot
        if existingContext == nil {
            expandProject(nextContext.projectRoot)
        }

        // A project switch hides every surface in the previous context without
        // changing that workspace's selected session. Trigger the same refresh
        // and summary path used when switching sessions or hiding the window.
        if previousContext !== nextContext {
            previousContext?.scheduleHiddenAgentSummaries()
        }

        if previousContext !== nextContext {
            nextContext.selection.apply(to: chromeState)
        }
        if activateWorktree,
           nextContext.repository.contains(worktreeRoot: requestedRoot) {
            _ = nextContext.repository.activate(
                worktreeRoot: requestedRoot,
                chromeState: chromeState
            )
        }

        if startsContextsOnActivation {
            nextContext.startIfNeeded()
        }
        settings.markProjectOpened(nextContext.workspace.projectRoot)
        if notifiesRegistry {
            ProjectWindowRegistry.shared.projectManagerDidActivate(self)
        }
        return nextContext
    }

    @discardableResult
    func openProject(_ project: CherryProject) -> ProjectWorkspaceContext? {
        activate(projectRoot: project.root, activateWorktree: false)
    }

    @discardableResult
    func loadProject(_ project: CherryProject) -> ProjectWorkspaceContext? {
        let existingContext = context(for: project.root)
        if existingContext == nil,
           notifiesRegistry,
           ProjectWindowRegistry.shared.focusExistingProject(
               projectRoot: project.root,
               excluding: self,
               activateWorktree: false
           ) {
            return nil
        }
        let context = existingContext ?? loadContext(projectRoot: project.root)
        if startsContextsOnActivation {
            context?.startIfNeeded()
        }
        return context
    }

    @discardableResult
    func requestNewCommand(in project: CherryProject) -> ProjectWorkspaceContext? {
        guard let context = loadProject(project) else { return nil }
        _ = openProject(project)
        setProjectExpanded(true, projectRoot: project.root, in: .commands)
        pendingCommandAddProjectRoots.insert(context.projectRoot)
        commandAddRequestRevision &+= 1
        return context
    }

    func consumeNewCommandRequest(projectRoot: String) -> Bool {
        pendingCommandAddProjectRoots.remove(canonicalRoot(projectRoot)) != nil
    }

    func closeAllSessions() {
        contexts.values.forEach { $0.closeAllSessions() }
    }

    func runningProcessCount() -> Int {
        contexts.values.reduce(0) { $0 + $1.runningProcessCount() }
    }

    func projectRoot(containing sessionID: UUID) -> String? {
        for context in contexts.values {
            if let root = context.repository.root(containing: sessionID) {
                return root
            }
        }
        return nil
    }

    func isProjectExpanded(_ projectRoot: String, in section: ProjectSidebarSection) -> Bool {
        expandedProjectRootsBySection[section]?.contains(canonicalRoot(projectRoot)) == true
    }

    func setProjectExpanded(
        _ isExpanded: Bool,
        projectRoot: String,
        in section: ProjectSidebarSection
    ) {
        let projectRoot = canonicalRoot(projectRoot)
        if isExpanded {
            expandedProjectRootsBySection[section, default: []].insert(projectRoot)
        } else {
            expandedProjectRootsBySection[section, default: []].remove(projectRoot)
        }
    }

    func toggleProjectExpanded(_ projectRoot: String, in section: ProjectSidebarSection) {
        setProjectExpanded(
            !isProjectExpanded(projectRoot, in: section),
            projectRoot: projectRoot,
            in: section
        )
    }

    func expandProject(_ projectRoot: String) {
        let projectRoot = canonicalRoot(projectRoot)
        for section in ProjectSidebarSection.allCases {
            expandedProjectRootsBySection[section, default: []].insert(projectRoot)
        }
    }

    func removeProject(_ project: CherryProject) {
        let projectRoot = canonicalRoot(project.root)
        let wasActive = activeProjectRoot == projectRoot

        if notifiesRegistry {
            ProjectWindowRegistry.shared.projectManager(self, didRemoveProjectRoot: projectRoot)
        }
        contexts.removeValue(forKey: projectRoot)?.closeAllSessions()
        pendingCommandAddProjectRoots.remove(projectRoot)
        for section in ProjectSidebarSection.allCases {
            expandedProjectRootsBySection[section]?.remove(projectRoot)
        }
        settings.removeProject(CherryProject(root: projectRoot))

        guard wasActive else { return }
        activeProjectRoot = nil

        for remainingProject in settings.projects {
            guard loadProject(remainingProject) != nil else { continue }
            _ = openProject(remainingProject)
            return
        }
    }

    private func loadContext(
        projectRoot: String,
        createInitialSession: Bool = true
    ) -> ProjectWorkspaceContext? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectRoot, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        let context = ProjectWorkspaceContext(
            projectRoot: projectRoot,
            settings: settings,
            createInitialSession: createInitialSession
        )
        contexts[context.projectRoot] = context
        return context
    }

    private static func standardizedRoot(_ root: String) -> String {
        URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
    }

    private func canonicalRoot(_ root: String) -> String {
        context(for: root)?.projectRoot ?? Self.standardizedRoot(root)
    }
}

enum ProjectSidebarSection: String, CaseIterable, Codable {
    case agents
    case terminals
    case commands

    var title: String {
        rawValue.capitalized
    }

    var showsProjectActivityIndicator: Bool {
        self == .agents
    }
}

@MainActor
struct ProjectSelectionState {
    var selectedNoteID: UUID?
    var selectedTodoID: UUID?
    var isTodoPanePresented: Bool
    var selectedTodoTagFilterIDs: Set<String>
    var collapsedAgentGroupIDs: Set<UUID>
    var focusedIdleCommandName: String?

    static let terminal = ProjectSelectionState(
        selectedNoteID: nil,
        selectedTodoID: nil,
        isTodoPanePresented: false,
        selectedTodoTagFilterIDs: [],
        collapsedAgentGroupIDs: [],
        focusedIdleCommandName: nil
    )

    init(chromeState: ProjectWindowChromeState) {
        selectedNoteID = chromeState.selectedNoteID
        selectedTodoID = chromeState.selectedTodoID
        isTodoPanePresented = chromeState.isTodoPanePresented
        selectedTodoTagFilterIDs = chromeState.selectedTodoTagFilterIDs
        collapsedAgentGroupIDs = chromeState.collapsedAgentGroupIDs
        focusedIdleCommandName = chromeState.focusedIdleCommandName
    }

    init(
        selectedNoteID: UUID?,
        selectedTodoID: UUID?,
        isTodoPanePresented: Bool,
        selectedTodoTagFilterIDs: Set<String>,
        collapsedAgentGroupIDs: Set<UUID>,
        focusedIdleCommandName: String?
    ) {
        self.selectedNoteID = selectedNoteID
        self.selectedTodoID = selectedTodoID
        self.isTodoPanePresented = isTodoPanePresented
        self.selectedTodoTagFilterIDs = selectedTodoTagFilterIDs
        self.collapsedAgentGroupIDs = collapsedAgentGroupIDs
        self.focusedIdleCommandName = focusedIdleCommandName
    }

    func apply(to chromeState: ProjectWindowChromeState) {
        chromeState.selectedNoteID = selectedNoteID
        chromeState.selectedTodoID = selectedTodoID
        chromeState.isTodoPanePresented = isTodoPanePresented
        chromeState.selectedTodoTagFilterIDs = selectedTodoTagFilterIDs
        chromeState.collapsedAgentGroupIDs = collapsedAgentGroupIDs
        chromeState.focusedIdleCommandName = focusedIdleCommandName
    }
}

@MainActor
final class ProjectAggregateStatus: ObservableObject {
    @Published private(set) var needsAttention = false
    @Published private(set) var hasUnread = false
    @Published private(set) var isWorking = false

    private weak var repository: RepositoryWorkspace?
    private var repositoryCancellables: Set<AnyCancellable> = []
    private var workspaceCancellables: Set<AnyCancellable> = []
    private var sessionCancellables: Set<AnyCancellable> = []

    init(repository: RepositoryWorkspace) {
        self.repository = repository
        repository.$loadedWorktreeRoots
            .sink { [weak self] _ in
                // @Published emits from willSet. Rebind on the next actor turn
                // so repository.allLoadedWorkspaces() sees the committed set.
                Task { @MainActor [weak self] in self?.bindWorkspaces() }
            }
            .store(in: &repositoryCancellables)
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshHiddenAgentSurfaces() }
            .store(in: &repositoryCancellables)
        bindWorkspaces()
    }

    /// A project switch removes the old project's terminal views. Ghostty keeps
    /// their PTYs alive, but a detached native surface is not guaranteed to send
    /// render callbacks. Pull hidden running agents periodically so their live
    /// Working/prompt markers continue to drive project-level status.
    private func refreshHiddenAgentSurfaces() {
        let sessions = repository?.allLoadedWorkspaces().flatMap(\.agentSessions) ?? []
        for session in sessions
        where session.isRunning && !ProjectWindowRegistry.shared.isSessionVisible(session) {
            _ = session.lineCount
        }
        refresh()
    }

    private func bindWorkspaces() {
        workspaceCancellables.removeAll()
        guard let repository else { return }
        for workspace in repository.allLoadedWorkspaces() {
            workspace.$sessions
                .sink { [weak self] _ in
                    // The emitted sessions value arrives before workspace.sessions
                    // changes. A synchronous rescan would bind the old array and
                    // permanently miss the newly added agent.
                    Task { @MainActor [weak self] in self?.bindSessions() }
                }
                .store(in: &workspaceCancellables)
        }
        bindSessions()
    }

    private func bindSessions() {
        sessionCancellables.removeAll()
        let sessions = repository?.allLoadedWorkspaces().flatMap(\.sessions) ?? []
        for session in sessions {
            session.$agentActivityState
                .sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &sessionCancellables)
            session.$hasUnreadNotification
                .sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &sessionCancellables)
            session.$hasUnacknowledgedAttention
                .sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &sessionCancellables)
        }
        refresh()
    }

    private func scheduleRefresh() {
        // Session @Published properties also emit in willSet. Waiting for the
        // next MainActor turn makes the aggregate read the new value rather
        // than becoming permanently stuck on the preceding state.
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private func refresh() {
        let sessions = repository?.allLoadedWorkspaces().flatMap(\.sessions) ?? []
        needsAttention = sessions.contains {
            $0.hasUnacknowledgedAttention
                || $0.agentActivityState == .permission
                || $0.agentActivityState == .error
        }
        hasUnread = sessions.contains { $0.hasUnreadNotification }
        isWorking = sessions.contains { $0.agentActivityState.showsWorkingIndicator }
    }
}
