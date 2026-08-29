import AppKit
import Testing
@testable import Cherry

@MainActor
@Test func ghosttySurfaceCloseRequestReplacesLastExitedTerminal() throws {
    let workspace = TerminalWorkspace(createInitialSession: false, launchBackend: .hostManaged)
    defer { workspace.closeAllSessions() }
    let session = workspace.addSession(title: "Exited")
    let sessionID = session.id
    let container = GhosttyTerminalContainerView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 400)
    )
    defer { container.detachActiveSession(releasesBridge: false) }
    container.configure(
        with: session,
        colorScheme: .dark,
        allowsAutoFocus: false,
        onClose: { [weak workspace] in
            guard let workspace,
                  let session = workspace.session(withID: sessionID)
            else { return }
            workspace.close(session)
        }
    )
    let bridge = session.ghosttyBridge

    bridge.terminalDidClose(processAlive: false)

    let replacement = try #require(workspace.terminalSessions.first)
    #expect(workspace.sessions.count == 1)
    #expect(replacement.id != sessionID)
    #expect(workspace.selectedSessionID == replacement.id)
}
