import SwiftUI

/// Rows showing what each part of the meal contributed, for use inside a Form section.
struct ComponentBreakdownRows: View {
    let components: [MealComponent]

    var body: some View {
        ForEach(Array(components.enumerated()), id: \.offset) { _, item in
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(item.calories.rounded())) kcal")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                HStack(alignment: .firstTextBaseline) {
                    if !item.portion.isEmpty {
                        Text(item.portion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("P \(Int(item.protein.rounded()))g · C \(Int(item.carbs.rounded()))g · F \(Int(item.fat.rounded()))g")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 2)
        }
    }
}
