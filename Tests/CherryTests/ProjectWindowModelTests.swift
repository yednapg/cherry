import Foundation
import Testing
@testable import Cherry

@MainActor
@Suite("Project window model", .serialized)
struct ProjectWindowModelTests {
    @Test func newWindowWithoutRequestedProjectStartsEmpty() throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let settings = fixture.makeSettings()
        _ = settings.addProject(path: fixture.firstProject.path)
        _ = settings.addProject(path: fixture.secondProject.path)

        let model = fixture.makeModel(initialProjectRoot: nil, settings: settings)

        #expect(model.activeProjectRoot == nil)
        #expect(model.contexts.isEmpty)
    }

    @Test func projectActivityAppearsOnlyInAgentsSection() {
        #expect(ProjectSidebarSection.agents.showsProjectActivityIndicator)
        #expect(!ProjectSidebarSection.terminals.showsProjectActivityIndicator)
        #expect(!ProjectSidebarSection.commands.showsProjectActivityIndicator)
    }

    @Test func switchingProjectsRetainsLoadedWorkspaceContexts() throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(initialProjectRoot: fixture.firstProject.path)
        defer { model.closeAllSessions() }

        let firstContext = try #require(model.activeContext)
        let firstWorkspace = firstContext.workspace

        let secondContext = try #require(model.activate(projectRoot: fixture.secondProject.path))

        #expect(model.contexts.count == 2)
        #expect(model.activeContext === secondContext)
        #expect(firstContext.workspace === firstWorkspace)

        _ = model.activate(projectRoot: fixture.firstProject.path)

        #expect(model.activeContext === firstContext)
        #expect(model.activeWorkspace === firstWorkspace)
    }

    @Test func hiddenProjectAggregatesItsOwnWorkingAgent() async throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(initialProjectRoot: fixture.firstProject.path)
        defer { model.closeAllSessions() }
        let firstContext = try #require(model.activeContext)
        let hiddenContext = try #require(model.loadProject(
            CherryProject(root: fixture.secondProject.path)
        ))
        let hiddenAgent = hiddenContext.workspace.addAgentSession(
            agent: AgentToolDefinition(name: "Codex", command: "/bin/cat"),
            projectRoot: hiddenContext.projectRoot,
            select: false
        )
        #expect(!hiddenContext.activity.isWorking)

        hiddenAgent.ingestTestingData(Data("Working (2m13s • esc to interrupt)\n".utf8))

        #expect(model.activeContext === firstContext)
        #expect(await waitForProjectCondition(timeout: 2) {
            hiddenContext.activity.isWorking
        })
        #expect(!firstContext.activity.isWorking)
    }

    @Test func switchingProjectsSchedulesSummariesForTheContextThatBecameHidden() throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(initialProjectRoot: fixture.firstProject.path)
        defer { model.closeAllSessions() }
        let firstWorkspace = try #require(model.activeWorkspace)
        var schedulingCount = 0
        firstWorkspace.hiddenAgentSummarySchedulingObserverForTesting = {
            schedulingCount += 1
        }

        _ = model.activate(projectRoot: fixture.secondProject.path)

        #expect(schedulingCount == 1)
    }

    @Test func switchingProjectsRestoresProjectSpecificSelection() throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(initialProjectRoot: fixture.firstProject.path)
        defer { model.closeAllSessions() }
        let firstContext = try #require(model.activeContext)
        let firstNoteID = UUID()
        let firstCollapsedGroupID = UUID()
        model.chromeState.selectedNoteID = firstNoteID
        model.chromeState.collapsedAgentGroupIDs = [firstCollapsedGroupID]

        let secondContext = try #require(model.activate(projectRoot: fixture.secondProject.path))

        #expect(model.chromeState.selectedNoteID == nil)
        #expect(model.chromeState.collapsedAgentGroupIDs.isEmpty)
        let secondTodoID = UUID()
        model.chromeState.selectedTodoID = secondTodoID
        model.chromeState.isTodoPanePresented = true

        _ = model.activate(projectRoot: fixture.firstProject.path)

        #expect(model.activeContext === firstContext)
        #expect(model.chromeState.selectedNoteID == firstNoteID)
        #expect(model.chromeState.selectedTodoID == nil)
        #expect(model.chromeState.isTodoPanePresented == false)
        #expect(model.chromeState.collapsedAgentGroupIDs == [firstCollapsedGroupID])

        _ = model.activate(projectRoot: fixture.secondProject.path)

        #expect(model.activeContext === secondContext)
        #expect(model.chromeState.selectedNoteID == nil)
        #expect(model.chromeState.selectedTodoID == secondTodoID)
        #expect(model.chromeState.isTodoPanePresented)
    }

    @Test func activationRejectsFilesAndMissingDirectories() throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(initialProjectRoot: nil)
        let fileURL = fixture.root.appending(path: "not-a-project.txt")
        try Data().write(to: fileURL)

        #expect(model.activate(projectRoot: fileURL.path) == nil)
        #expect(model.activate(projectRoot: fixture.root.appending(path: "missing").path) == nil)
        #expect(model.contexts.isEmpty)
    }

    @Test func projectGroupDisclosureStateSurvivesProjectSwitches() throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(initialProjectRoot: fixture.firstProject.path)
        defer { model.closeAllSessions() }

        #expect(model.isProjectExpanded(fixture.firstProject.path, in: .agents))
        #expect(model.isProjectExpanded(fixture.firstProject.path, in: .terminals))
        #expect(model.isProjectExpanded(fixture.firstProject.path, in: .commands))

        model.setProjectExpanded(false, projectRoot: fixture.firstProject.path, in: .agents)
        _ = model.activate(projectRoot: fixture.secondProject.path)
        _ = model.activate(projectRoot: fixture.firstProject.path)

        #expect(!model.isProjectExpanded(fixture.firstProject.path, in: .agents))
        #expect(model.isProjectExpanded(fixture.firstProject.path, in: .terminals))
        #expect(model.isProjectExpanded(fixture.secondProject.path, in: .agents))
        #expect(model.isProjectExpanded(fixture.secondProject.path, in: .terminals))
        #expect(model.isProjectExpanded(fixture.secondProject.path, in: .commands))
    }

    @Test func expandingABackgroundProjectCreatesItsDefaultTerminalWithoutChangingSelection() throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(initialProjectRoot: fixture.firstProject.path)
        defer { model.closeAllSessions() }
        let firstContext = try #require(model.activeContext)

        let secondContext = try #require(model.loadProject(CherryProject(root: fixture.secondProject.path)))
        model.setProjectExpanded(true, projectRoot: fixture.secondProject.path, in: .terminals)

        #expect(model.activeContext === firstContext)
        #expect(model.context(for: fixture.secondProject.path) === secondContext)
        #expect(secondContext.workspace.terminalSessions.count == 1)
        #expect(secondContext.workspace.sessions.count == 1)
        #expect(model.isProjectExpanded(fixture.secondProject.path, in: .terminals))
        #expect(!model.isProjectExpanded(fixture.secondProject.path, in: .agents))
    }

    @Test func requestingACommandLoadsAProjectTerminalAndQueuesTheEditorOnce() throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel(initialProjectRoot: fixture.firstProject.path)
        defer { model.closeAllSessions() }
        let project = CherryProject(root: fixture.secondProject.path)

        let context = try #require(model.requestNewCommand(in: project))

        #expect(model.activeContext === context)
        #expect(context.workspace.terminalSessions.count == 1)
        #expect(context.workspace.sessions.count == 1)
        #expect(model.isProjectExpanded(project.root, in: .commands))
        #expect(model.commandAddRequestRevision == 1)
        #expect(model.consumeNewCommandRequest(projectRoot: project.root))
        #expect(!model.consumeNewCommandRequest(projectRoot: project.root))
    }

    @Test func projectVisibilityCanBeChangedPerSectionAndRestored() throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let project = CherryProject(root: fixture.firstProject.path)
        let settings = fixture.makeSettings()
        _ = settings.addProject(path: project.root)

        settings.hideProject(project, from: .agents)

        #expect(!settings.isProjectVisible(project, in: .agents))
        #expect(settings.isProjectVisible(project, in: .terminals))
        #expect(settings.isProjectVisible(project, in: .commands))
        #expect(settings.projectHasHiddenSidebarSections(project))

        let reloadedSettings = fixture.makeSettings()
        #expect(!reloadedSettings.isProjectVisible(project, in: .agents))

        _ = reloadedSettings.addProject(path: project.root)

        #expect(ProjectSidebarSection.allCases.allSatisfy {
            reloadedSettings.isProjectVisible(project, in: $0)
        })
    }

    @Test func removingActiveProjectSelectsRemainingProjectWithItsDefaultTerminal() throws {
        let fixture = try ProjectWindowFixture()
        defer { fixture.cleanUp() }
        let settings = fixture.makeSettings()
        let firstProject = try #require(settings.addProject(path: fixture.firstProject.path))
        let secondProject = try #require(settings.addProject(path: fixture.secondProject.path))
        let model = fixture.makeModel(initialProjectRoot: firstProject.root, settings: settings)
        defer { model.closeAllSessions() }

        model.removeProject(firstProject)

        #expect(settings.projects == [secondProject])
        #expect(model.context(for: firstProject.root) == nil)
        #expect(model.activeProjectRoot == secondProject.root)
        #expect(model.activeWorkspace?.terminalSessions.count == 1)
        #expect(model.activeWorkspace?.sessions.count == 1)
    }
}

@MainActor
private struct ProjectWindowFixture {
    let root: URL
    let firstProject: URL
    let secondProject: URL
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "cherry-project-window-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        firstProject = root.appending(path: "alpha", directoryHint: .isDirectory)
        secondProject = root.appending(path: "bravo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)
        suiteName = "CherryProjectWindowModelTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    func makeSettings() -> AgentSettings {
        AgentSettings(defaults: defaults)
    }

    func makeModel(
        initialProjectRoot: String?,
        settings: AgentSettings? = nil
    ) -> ProjectWindowModel {
        ProjectWindowModel(
            initialProjectRoot: initialProjectRoot,
            settings: settings ?? makeSettings(),
            startsContextsOnActivation: false,
            notifiesRegistry: false
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func waitForProjectCondition(
    timeout: TimeInterval = 1,
    interval: Duration = .milliseconds(10),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: interval)
    }
    return condition()
}
