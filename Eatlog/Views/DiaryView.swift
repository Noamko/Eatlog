import SwiftUI
import SwiftData

struct DiaryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var showingAddMeal = false
    @State private var showingOverview = false
    @State private var path = NavigationPath()

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        NavigationStack(path: $path) {
            DayMealsView(day: day)
                .id(day)
                .navigationDestination(for: Meal.self) { meal in
                    MealDetailView(meal: meal)
                }
                .navigationTitle(isToday ? "Today" : day.formatted(date: .abbreviated, time: .omitted))
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button { day = shifted(-1) } label: {
                            Image(systemName: "chevron.left")
                        }
                        Button { day = shifted(1) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(isToday)
                        Button { showingOverview = true } label: {
                            Image(systemName: "chart.bar.xaxis")
                        }
                        .accessibilityLabel("Weekly & Monthly Overview")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingAddMeal = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .accessibilityLabel("Add Meal")
                    }
                }
                .sheet(isPresented: $showingAddMeal) {
                    AddMealView(day: day)
                }
                .sheet(isPresented: $showingOverview) {
                    PeriodOverviewView()
                }
                .task { await openDetailIfRequested() }
                .task { await openOverviewIfRequested() }
        }
    }

    private func shifted(_ delta: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: delta, to: day) ?? day
    }

    /// Simulator/testing hook: `-open-overview` launch argument opens the period overview.
    private func openOverviewIfRequested() async {
        #if DEBUG
        guard LaunchHooks.consume("-open-overview") else { return }
        try? await Task.sleep(for: .milliseconds(900))
        showingOverview = true
        #endif
    }

    /// Simulator/testing hook: `-open-meal-detail` launch argument navigates to the newest meal.
    private func openDetailIfRequested() async {
        #if DEBUG
        guard LaunchHooks.consume("-open-meal-detail"), path.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(700))
        var descriptor = FetchDescriptor<Meal>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        if let meal = try? modelContext.fetch(descriptor).first {
            path.append(meal)
        }
        #endif
    }
}

private struct DayMealsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings
    @Query private var meals: [Meal]
    private let day: Date
    @State private var selectedNutrient: Nutrient?

    init(day: Date) {
        self.day = day
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        _meals = Query(
            filter: #Predicate<Meal> { $0.createdAt >= start && $0.createdAt < end },
            sort: \Meal.createdAt
        )
    }

    var body: some View {
        List {
            Section {
                NutritionTotalsCard(
                    total: dayTotal,
                    onSelect: { selectedNutrient = $0 }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                ForEach(Nutrient.allCases.filter { settings.goals[$0]?.period == .daily }) { nutrient in
                    if let goal = settings.goals[nutrient] {
                        dailyGoalRow(nutrient, goal: goal)
                    }
                }
            }
            Section {
                if meals.isEmpty {
                    ContentUnavailableView(
                        "No meals yet",
                        systemImage: "fork.knife.circle",
                        description: Text("Tap + to snap or describe your first meal.")
                    )
                } else {
                    ForEach(meals) { meal in
                        NavigationLink(value: meal) {
                            MealRow(meal: meal)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            modelContext.delete(meals[index])
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedNutrient) { nutrient in
            NutrientBreakdownView(nutrient: nutrient, meals: meals, dayLabel: dayLabel)
        }
        .task { await openNutrientIfRequested() }
    }

    private var dayLabel: String {
        Calendar.current.isDateInToday(day) ? "Today" : day.formatted(date: .abbreviated, time: .omitted)
    }

    private func dayTotal(_ nutrient: Nutrient) -> Double {
        meals.reduce(0) { $0 + nutrient.value(of: $1) }
    }

    private func dailyGoalRow(_ nutrient: Nutrient, goal: NutrientGoal) -> some View {
        let value = dayTotal(nutrient)
        let status = goal.status(value: value, unit: nutrient.unit)
        let warning = status.state == .over && nutrient.warnsWhenExceeded
        let tint: Color = switch status.state {
        case .over: .red
        case .met: .green
        case .onTrack: nutrient.color
        }
        return HStack(spacing: 10) {
            Text(nutrient.title)
                .font(.caption)
                .foregroundStyle(warning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 58, alignment: .leading)
            ProgressView(value: goal.progress(value: value))
                .tint(tint)
            if warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Text(status.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(status.state == .onTrack ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .monospacedDigit()
        }
        .listRowBackground(warning ? Color.red.opacity(0.09) : nil)
    }

    /// Simulator/testing hook: `-open-nutrient <name>` opens that nutrient's breakdown.
    private func openNutrientIfRequested() async {
        #if DEBUG
        guard let value = LaunchHooks.consumeValue(after: "-open-nutrient"),
              let nutrient = Nutrient(rawValue: value)
        else { return }
        try? await Task.sleep(for: .milliseconds(900))
        selectedNutrient = nutrient
        #endif
    }
}

private struct NutritionTotalsCard: View {
    let total: (Nutrient) -> Double
    let onSelect: (Nutrient) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Nutrient.allCases) { nutrient in
                Button {
                    onSelect(nutrient)
                } label: {
                    StatTile(
                        value: total(nutrient),
                        unit: nutrient.unit,
                        label: nutrient.title,
                        color: nutrient.color
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct StatTile: View {
    let value: Double
    let unit: String
    let label: String
    let color: Color
    var isSelected: Bool = false

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(value.rounded()))")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? color : Color.primary)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(isSelected ? 0.3 : 0.14), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MealRow: View {
    let meal: Meal

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.title.isEmpty ? "Meal" : meal.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(meal.createdAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(meal.calories.rounded())) kcal")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("P \(Int(meal.protein.rounded())) · C \(Int(meal.carbs.rounded())) · F \(Int(meal.fat.rounded()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = meal.photoData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemGray5))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "fork.knife")
                        .foregroundStyle(.secondary)
                }
        }
    }
}
