// The planner's routing threshold: below it the fast model's answer goes to the strong one. Foundation only, so the
// unit tests (tests/DecisionTests.swift) run it.
//
// A model pair can need its own: G18b's 0.8B learned to say 0.95 whether right or wrong (its rule teacher's labels
// were all 0.95), so at the server's default 0.94 its wrong answers were never escalated; at 0.96 it escalates about
// as often as G17 did and passes the gate that 0.94 failed (10-01).

import Foundation

enum RoutingThreshold {
    static let fallback = 0.94

    /// The development override's "threshold" (models.local.json, a string: "0.96"), else the fast model's own
    /// (its deskmind.json "router_threshold", which ships with the weights), else the release manifest's, else the
    /// server's default. A value outside (0, 1) is ignored.
    static func pick(override: String?, model: Double? = nil, manifest: Double?) -> Double {
        if let o = override.flatMap(Double.init), o > 0, o < 1 { return o }
        if let m = model, m > 0, m < 1 { return m }
        if let m = manifest, m > 0, m < 1 { return m }
        return fallback
    }

    /// "router_threshold" from a model's deskmind.json, if it has one. The fast model carries the threshold its pair
    /// was gated at from G18b on (brain 6e39065 serves with it by default), so the weights and their threshold
    /// travel together.
    static func fromModelConfig(_ data: Data) -> Double? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["router_threshold"] as? NSNumber)?.doubleValue
    }
}
