import Testing
@testable import Cherry

@Test func nativeExecLaunchClearsInheritedNoColorForColorCapableChildren() {
    func launch(environment: [String: String] = [:]) -> (command: String, environment: [String: String]) {
        ShellProcessController.nativeExecLaunch(
            for: .init(
                shellPath: "/bin/sh",
                workingDirectory: "/tmp",
                environment: environment,
                term: "xterm-ghostty",
                initialSize: TerminalViewportSize(columns: 80, rows: 24)
            )
        )
    }

    let inherited = launch()
    #expect(inherited.command == "/usr/bin/env -u NO_COLOR /bin/sh -l")
    #expect(inherited.environment["COLORTERM"] == "truecolor")
    #expect(inherited.environment["TERM"] == "xterm-ghostty")

    let explicit = launch(environment: ["NO_COLOR": "1"])
    #expect(explicit.command == "/bin/sh -l")
    #expect(explicit.environment["NO_COLOR"] == "1")
}
