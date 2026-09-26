import Foundation
import SwiftData

enum ExportError: LocalizedError {
    case notAnExport
    case newerVersion

    var errorDescription: String? {
        switch self {
        case .notAnExport:
            return "That file isn't an Eatlog export."
        case .newerVersion:
            return "This export was made by a newer version of Eatlog — update the app and try again."
        }
    }
}

/// Whole-diary export/import as a single JSON file: meals with their component
/// breakdowns, notes, and photos (base64). Settings and API keys are excluded.
/// Each meal carries a stable UUID so importing the same file twice never
/// duplicates anything.
enum MealExport {
    static let format = "mealsnap-export"
    static let version = 1

    struct File: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var meals: [ExportedMeal]
    }

    struct ExportedMeal: Codable {
        var uid: UUID
        var createdAt: Date
        var title: String
        var details: String
        var calories: Double
        var protein: Double
        var carbs: Double
        var fat: Double
        var notes: String
        var components: [MealComponent]
        var photo: Data?
    }

    @MainActor
    static func exportData(context: ModelContext) throws -> (data: Data, mealCount: Int) {
        let meals = try context.fetch(
            FetchDescriptor<Meal>(sortBy: [SortDescriptor(\.createdAt)])
        )
        let exported = meals.map { meal in
            if meal.uid == nil { meal.uid = UUID() }
            return ExportedMeal(
                uid: meal.uid ?? UUID(),
                createdAt: meal.createdAt,
                title: meal.title,
                details: meal.details,
                calories: meal.calories,
                protein: meal.protein,
                carbs: meal.carbs,
                fat: meal.fat,
                notes: meal.notes,
                components: meal.components,
                photo: meal.photoData
            )
        }
        let file = File(format: format, version: version, exportedAt: .now, meals: exported)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try encoder.encode(file), exported.count)
    }

    @MainActor
    static func importData(_ data: Data, context: ModelContext) throws -> (imported: Int, skipped: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: File
        do {
            file = try decoder.decode(File.self, from: data)
        } catch {
            throw ExportError.notAnExport
        }
        guard file.format == format else { throw ExportError.notAnExport }
        guard file.version <= version else { throw ExportError.newerVersion }

        let existing = Set(try context.fetch(FetchDescriptor<Meal>()).compactMap(\.uid))
        var imported = 0
        var skipped = 0
        for meal in file.meals {
            if existing.contains(meal.uid) {
                skipped += 1
                continue
            }
            context.insert(Meal(
                uid: meal.uid,
                createdAt: meal.createdAt,
                title: meal.title,
                details: meal.details,
                calories: meal.calories,
                protein: meal.protein,
                carbs: meal.carbs,
                fat: meal.fat,
                components: meal.components,
                notes: meal.notes,
                photoData: meal.photo
            ))
            imported += 1
        }
        return (imported, skipped)
    }
}
