import Testing
@testable import Cherry

@Test func settingsNavigationHistoryTraversesRecordedSelections() {
    var history = SettingsNavigationHistory(initialSelection: .page(.general))

    #expect(!history.canGoBack)
    #expect(!history.canGoForward)
    #expect(history.goBack() == nil)

    history.record(.page(.terminal))
    history.record(.project("/work/cherry"))

    #expect(history.canGoBack)
    #expect(!history.canGoForward)
    #expect(history.goBack() == .page(.terminal))
    #expect(history.goBack() == .page(.general))
    #expect(history.goBack() == nil)
    #expect(history.canGoForward)
    #expect(history.goForward() == .page(.terminal))
    #expect(history.goForward() == .project("/work/cherry"))
    #expect(history.goForward() == nil)
}

@Test func settingsNavigationHistoryDropsForwardEntriesAfterBranching() {
    var history = SettingsNavigationHistory(initialSelection: .page(.general))
    history.record(.page(.terminal))
    history.record(.page(.projects))

    #expect(history.goBack() == .page(.terminal))

    history.record(.page(.agents))

    #expect(history.entries == [.page(.general), .page(.terminal), .page(.agents)])
    #expect(!history.canGoForward)
    #expect(history.goForward() == nil)
}

@Test func settingsNavigationHistoryIgnoresCurrentSelection() {
    var history = SettingsNavigationHistory(initialSelection: .page(.general))

    history.record(.page(.general))

    #expect(history.entries == [.page(.general)])
    #expect(!history.canGoBack)
    #expect(!history.canGoForward)
}
