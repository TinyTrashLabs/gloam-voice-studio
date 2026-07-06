import os

/// App-level loggers. `log stream --predicate 'subsystem == "fm.gloam.studio"'`
/// (or Console.app) shows these; the app previously had no os_log at all, which
/// made residency questions ("did something evict the model?") unanswerable.
enum AppLog {
    static let memory = Logger(subsystem: "fm.gloam.studio", category: "memory")
}
