import AppKit
import Testing
@testable import Cherry

@MainActor
@Test func ghosttySurfaceCloseRequestRemovesExitedTerminalFromWorkspace() {
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
            workspace.close(session, allowEmptyWorkspace: true)
        }
    )
    let bridge = session.ghosttyBridge

    bridge.terminalDidClose(processAlive: false)

    #expect(workspace.sessions.isEmpty)
    #expect(workspace.selectedSessionID == nil)
}
