import Foundation

/// A target for one nutrient: "at least 120 g protein daily", "at most 2,000 kcal
/// weekly", etc. At most one goal per nutrient, stored in AppSettings.
struct NutrientGoal: Codable, Equatable {
    enum Direction: String, Codable, CaseIterable, Identifiable {
        case atLeast, atMost

        var id: String { rawValue }
        var label: String { self == .atLeast ? "At least" : "At most" }
    }

    enum Period: String, Codable, CaseIterable, Identifiable {
        case daily, weekly

        var id: String { rawValue }
        var label: String { self == .daily ? "Daily" : "Weekly" }
    }

    var direction: Direction
    var amount: Double
    var period: Period

    static func suggested(for nutrient: Nutrient) -> NutrientGoal {
        switch nutrient {
        case .calories: return NutrientGoal(direction: .atMost, amount: 2000, period: .daily)
        case .protein: return NutrientGoal(direction: .atLeast, amount: 120, period: .daily)
        case .carbs: return NutrientGoal(direction: .atMost, amount: 250, period: .daily)
        case .fat: return NutrientGoal(direction: .atMost, amount: 70, period: .daily)
        }
    }

    /// e.g. "at least 120 g daily"
    func summary(unit: String) -> String {
        "\(direction == .atLeast ? "at least" : "at most") \(Int(amount.rounded())) \(unit) \(period == .daily ? "daily" : "weekly")"
    }

    enum State { case onTrack, met, over }

    func progress(value: Double) -> Double {
        guard amount > 0 else { return 0 }
        return min(max(value / amount, 0), 1)
    }

    func status(value: Double, unit: String) -> (text: String, state: State) {
        // Rounded first so the visible arithmetic adds up ("38 of 120" + "82 to go").
        let remaining = amount.rounded() - value.rounded()
        switch direction {
        case .atMost:
            if remaining >= 0 { return ("\(Int(remaining.rounded())) \(unit) left", .onTrack) }
            return ("\(Int((-remaining).rounded())) \(unit) over", .over)
        case .atLeast:
            if remaining > 0 { return ("\(Int(remaining.rounded())) \(unit) to go", .onTrack) }
            return ("Goal met", .met)
        }
    }
}
