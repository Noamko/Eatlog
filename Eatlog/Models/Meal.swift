import Foundation
import SwiftData

@Model
final class Meal {
    // Stable identity for export/import dedup. Optional so migrated rows start
    // nil (a non-optional UUID default would give every old row the same id);
    // export assigns one lazily.
    var uid: UUID?
    var createdAt: Date = Date()
    var title: String = ""
    var details: String = ""
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var components: [MealComponent] = []
    var notes: String = ""
    @Attribute(.externalStorage) var photoData: Data?

    init(
        uid: UUID? = nil,
        createdAt: Date = .now,
        title: String,
        details: String,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        components: [MealComponent] = [],
        notes: String = "",
        photoData: Data? = nil
    ) {
        self.uid = uid
        self.createdAt = createdAt
        self.title = title
        self.details = details
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.components = components
        self.notes = notes
        self.photoData = photoData
    }
}
