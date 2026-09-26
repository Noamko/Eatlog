import Foundation

/// One part of a meal with its own nutrition estimate, e.g. "Grilled chicken breast — 150 g".
struct MealComponent: Codable, Hashable {
    var name: String
    var portion: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double

    enum CodingKeys: String, CodingKey {
        case name, portion, calories
        case protein = "protein_g"
        case carbs = "carbs_g"
        case fat = "fat_g"
    }
}

extension [MealComponent] {
    var totalCalories: Double { reduce(0) { $0 + $1.calories } }
    var totalProtein: Double { reduce(0) { $0 + $1.protein } }
    var totalCarbs: Double { reduce(0) { $0 + $1.carbs } }
    var totalFat: Double { reduce(0) { $0 + $1.fat } }
}
