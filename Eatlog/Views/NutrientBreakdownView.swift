import SwiftUI
import SwiftData
import UIKit

enum Nutrient: String, CaseIterable, Identifiable {
    case calories, protein, carbs, fat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calories: return "Calories"
        case .protein: return "Protein"
        case .carbs: return "Carbs"
        case .fat: return "Fat"
        }
    }

    var unit: String { self == .calories ? "kcal" : "g" }

    var color: Color {
        switch self {
        case .calories: return .orange
        case .protein: return .blue
        case .carbs: return .green
        case .fat: return .purple
        }
    }

    func value(of meal: Meal) -> Double {
        switch self {
        case .calories: return meal.calories
        case .protein: return meal.protein
        case .carbs: return meal.carbs
        case .fat: return meal.fat
        }
    }

    func value(of component: MealComponent) -> Double {
        switch self {
        case .calories: return component.calories
        case .protein: return component.protein
        case .carbs: return component.carbs
        case .fat: return component.fat
        }
    }
}

/// Where a day's total for one nutrient comes from: each meal's contribution
/// (largest first, with its share of the total), broken down into the meal's
/// components. Meals link through to their full report.
struct NutrientBreakdownView: View {
    let nutrient: Nutrient
    let meals: [Meal]
    let dayLabel: String

    @Environment(\.dismiss) private var dismiss
    @State private var photoPopout = PhotoPopoutController()

    private var total: Double {
        meals.reduce(0) { $0 + nutrient.value(of: $1) }
    }

    private var sortedMeals: [Meal] {
        meals.sorted { nutrient.value(of: $0) > nutrient.value(of: $1) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(dayLabel) total")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(total.rounded()))")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(nutrient.color)
                            .monospacedDigit()
                        Text(nutrient.unit)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if meals.isEmpty {
                    ContentUnavailableView(
                        "No meals yet",
                        systemImage: "fork.knife.circle",
                        description: Text("Add a meal and its \(nutrient.title.lowercased()) will show up here.")
                    )
                } else {
                    ForEach(sortedMeals) { meal in
                        mealSection(meal)
                    }
                }
            }
            .navigationTitle("\(nutrient.title) · \(dayLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Meal.self) { meal in
                MealDetailView(meal: meal)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Local popout mount so photos opened from a meal report inside this
        // sheet appear above the sheet, not behind it on the root.
        .overlay {
            if let request = photoPopout.request {
                PhotoPopoutOverlay(request: request) {
                    photoPopout.request = nil
                }
            }
        }
        .environment(photoPopout)
    }

    private func mealSection(_ meal: Meal) -> some View {
        Section {
            NavigationLink(value: meal) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meal.title.isEmpty ? "Meal" : meal.title)
                            .font(.headline)
                        Text(meal.createdAt, format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(nutrient.value(of: meal).rounded())) \(nutrient.unit)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        if total > 0 {
                            Text("\(Int((nutrient.value(of: meal) / total * 100).rounded()))% of total")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(Array(meal.components.enumerated()), id: \.offset) { _, component in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(component.name)
                            .font(.subheadline)
                        if !component.portion.isEmpty {
                            Text(component.portion)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(Int(nutrient.value(of: component).rounded())) \(nutrient.unit)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.leading, 8)
            }
        }
    }
}
