import SwiftUI

/// Set or clear a goal per nutrient: at least / at most an amount, daily or weekly.
struct GoalsEditorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Nutrient.allCases) { nutrient in
                    section(for: nutrient)
                }
            }
            .navigationTitle("Goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func section(for nutrient: Nutrient) -> some View {
        Section {
            Toggle(isOn: enabledBinding(nutrient)) {
                Label(nutrient.title, systemImage: "target")
                    .foregroundStyle(.primary)
            }
            .tint(nutrient.color)
            if settings.goals[nutrient] != nil {
                let goal = goalBinding(nutrient)
                Picker("Type", selection: goal.direction) {
                    ForEach(NutrientGoal.Direction.allCases) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Amount")
                    Spacer()
                    TextField("0", value: goal.amount, format: .number.precision(.fractionLength(0)))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text(nutrient.unit)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                }
                Picker("Period", selection: goal.period) {
                    ForEach(NutrientGoal.Period.allCases) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.segmented)
            }
        } footer: {
            if let goal = settings.goals[nutrient] {
                Text("\(nutrient.title) \(goal.summary(unit: nutrient.unit)).")
            }
        }
    }

    private func enabledBinding(_ nutrient: Nutrient) -> Binding<Bool> {
        Binding(
            get: { settings.goals[nutrient] != nil },
            set: { enabled in
                settings.goals[nutrient] = enabled
                    ? (settings.goals[nutrient] ?? .suggested(for: nutrient))
                    : nil
            }
        )
    }

    private func goalBinding(_ nutrient: Nutrient) -> Binding<NutrientGoal> {
        Binding(
            get: { settings.goals[nutrient] ?? .suggested(for: nutrient) },
            set: { settings.goals[nutrient] = $0 }
        )
    }
}
