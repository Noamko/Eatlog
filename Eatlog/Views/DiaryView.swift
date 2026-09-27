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
                .task { await openAddMealIfRequested() }
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

    /// Simulator/testing hook: `-open-add-meal` launch argument opens the add-meal sheet.
    private func openAddMealIfRequested() async {
        #if DEBUG
        guard LaunchHooks.consume("-open-add-meal") else { return }
        try? await Task.sleep(for: .milliseconds(900))
        showingAddMeal = true
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
                    goal: tileGoal,
                    onSelect: { selectedNutrient = $0 }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
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

    /// Daily-goal state for a tile, with tile-sized status text ("72 over", "met").
    private func tileGoal(_ nutrient: Nutrient) -> StatTile.GoalInfo? {
        guard let goal = settings.goals[nutrient], goal.period == .daily else { return nil }
        let value = dayTotal(nutrient)
        let status = goal.status(value: value, unit: nutrient.unit)
        let diff = Int(goal.amount.rounded() - value.rounded())
        let text: String
        switch goal.direction {
        case .atMost:
            text = diff >= 0 ? "\(diff) left" : "\(-diff) over"
        case .atLeast:
            text = diff > 0 ? "\(diff) to go" : "met"
        }
        return StatTile.GoalInfo(
            fraction: goal.progress(value: value),
            state: status.state,
            text: text,
            warning: status.state == .over && nutrient.warnsWhenExceeded
        )
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
    let goal: (Nutrient) -> StatTile.GoalInfo?
    let onSelect: (Nutrient) -> Void

    var body: some View {
        let anyGoal = Nutrient.allCases.contains { goal($0) != nil }
        HStack(spacing: 10) {
            ForEach(Nutrient.allCases) { nutrient in
                Button {
                    onSelect(nutrient)
                } label: {
                    StatTile(
                        value: total(nutrient),
                        unit: nutrient.unit,
                        label: nutrient.title,
                        color: nutrient.color,
                        goal: goal(nutrient),
                        reservesGoalSpace: anyGoal
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct StatTile: View {
    /// Daily-goal state rendered inside the tile: a slim bar plus "42 left"-style status.
    struct GoalInfo {
        let fraction: Double
        let state: NutrientGoal.State
        let text: String
        let warning: Bool
    }

    let value: Double
    let unit: String
    let label: String
    let color: Color
    var isSelected: Bool = false
    var goal: GoalInfo? = nil
    var reservesGoalSpace: Bool = false

    private var valueColor: Color {
        if goal?.warning == true { return .red }
        return isSelected ? color : .primary
    }

    private var goalTint: Color {
        switch goal?.state {
        case .over: return .red
        case .met: return .green
        default: return color
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(value.rounded()))")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let goal {
                VStack(spacing: 2) {
                    ProgressView(value: goal.fraction)
                        .tint(goalTint)
                        .scaleEffect(y: 0.8)
                    Text(goal.text)
                        .font(.caption2.weight(goal.warning ? .semibold : .regular))
                        .foregroundStyle(goal.state == .onTrack ? AnyShapeStyle(.secondary) : AnyShapeStyle(goalTint))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
            } else if reservesGoalSpace {
                Color.clear.frame(height: 22)
            }
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
