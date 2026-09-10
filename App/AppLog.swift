import os

/// App-level loggers. `log stream --predicate 'subsystem == "fm.gloam.studio"'`
/// (or Console.app) shows these; the app previously had no os_log at all, which
/// made residency questions ("did something evict the model?") unanswerable.
enum AppLog {
    static let memory = Logger(subsystem: "fm.gloam.studio", category: "memory")
    static let storage = Logger(subsystem: "fm.gloam.studio", category: "storage")
    static let history = Logger(subsystem: "fm.gloam.studio", category: "history")
    static let chat = Logger(subsystem: "fm.gloam.studio", category: "chat")
}
