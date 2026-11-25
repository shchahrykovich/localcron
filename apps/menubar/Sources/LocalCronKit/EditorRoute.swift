/// Where the window goes when the job editor opens, and where it goes back
/// to when the editor closes. The editor lives on one page (Jobs); an edit
/// can start on any page (Runs, Logs, Chat, ...).
public struct EditorRoute<Page: Equatable>: Equatable {
    /// The page to show now.
    public let show: Page
    /// The page to go back to when the editor closes, or nil to stay.
    public let back: Page?

    /// - Parameters:
    ///   - editorPage: the page that shows the editor.
    ///   - current: the page the window shows now.
    ///   - from: the page the edit started on, when the caller knows it.
    public init(editorPage: Page, current: Page, from: Page? = nil) {
        let origin = from ?? current
        show = editorPage
        back = origin == editorPage ? nil : origin
    }
}
