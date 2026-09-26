import Foundation

/// What the model returns for a meal: an editable description, a per-component
/// breakdown, and nutrition totals.
struct MealAnalysis: Codable {
    var title: String
    var description: String
    var items: [MealComponent]
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var notes: String

    enum CodingKeys: String, CodingKey {
        case title, description, items, calories, notes
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }

    // Totals derived from the breakdown when present, so the numbers shown
    // always match the sum of the components.
    var totalCalories: Double { items.isEmpty ? calories : items.totalCalories }
    var totalProtein: Double { items.isEmpty ? proteinG : items.totalProtein }
    var totalCarbs: Double { items.isEmpty ? carbsG : items.totalCarbs }
    var totalFat: Double { items.isEmpty ? fatG : items.totalFat }

    /// Decode model output leniently: some providers wrap JSON in markdown fences
    /// or add stray prose even when asked not to.
    static func decode(fromModelOutput text: String) throws -> MealAnalysis {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !cleaned.hasPrefix("{"),
           let first = cleaned.firstIndex(of: "{"),
           let last = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[first...last])
        }
        guard let data = cleaned.data(using: .utf8),
              let analysis = try? JSONDecoder().decode(MealAnalysis.self, from: data)
        else { throw AnalysisError.emptyResponse }
        return analysis
    }
}
