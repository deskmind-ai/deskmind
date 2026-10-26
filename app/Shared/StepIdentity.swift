// How a step is named and, from a harness before M0, how it ended: one mapping for the session's state
// (SessionReducer) and the run's record (RunDir), so both show the same rows (#131 review). Its own file, Foundation
// only, because the helper builds RunDir without the reducer (#131 Codex review: the helper did not build).

import Foundation

enum StepIdentity {
    /// A step's id: its own, else (a harness before M0: no step_id) its place, step-<n>.
    static func of(_ stepId: String?, stepsSoFar: Int) -> String { stepId ?? "step-\(stepsSoFar + 1)" }

    /// The results a step can have on the wire (StepState.Status's).
    static let results: Set<String> = ["ok", "unverified", "refused", "stale", "error"]

    /// A step result's status from the wire: one of the results a step can have, else `fallback`.
    static func result(_ raw: String, else fallback: String) -> String { results.contains(raw) ? raw : fallback }

    /// A harness before M0 said a step's result on the step itself (no step_id, no step_result): that status, else ok.
    static func legacyResult(stepId: String?, status: String?) -> String? {
        guard stepId == nil, let old = status else { return nil }
        return result(old, else: "ok")
    }
}
