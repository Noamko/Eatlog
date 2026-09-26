import SwiftUI
import SwiftData
import Charts
import UIKit

/// Weekly / monthly overview: daily-average tiles per nutrient, a per-day chart
/// of the selected nutrient, and the period's top contributors grouped by meal.
struct PeriodOverviewView: View {
    private enum Period: String, CaseIterable, Identifiable {
        case week, month

        var id: String { rawValue }
        var title: String { self == .week ? "Week" : "Month" }
        var component: Calendar.Component { self == .week ? .weekOfYear : .month }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var showingGoalsEditor = false
    @State private var period: Period = .week
    @State private var anchor: Date = .now
    @State private var meals: [Meal] = []
    @State private var nutrient: Nutrient = .calories
    @State private var expandedGroups: Set<String> = []
    @State private var selectedChartDay: Date?
    @State private var photoPopout = PhotoPopoutController()

    private var calendar: Calendar { .current }

    private var interval: DateInterval {
        calendar.dateInterval(of: period.component, for: anchor)
            ?? DateInterval(start: calendar.startOfDay(for: anchor), duration: 86_400)
    }

    private var containsToday: Bool { interval.contains(.now) }

    private var loggedDays: Set<Date> {
        Set(meals.map { calendar.startOfDay(for: $0.createdAt) })
    }

    private var periodTotal: Double {
        meals.reduce(0) { $0 + nutrient.value(of: $1) }
    }

    private var dailyTotals: [(day: Date, value: Double)] {
        Dictionary(grouping: meals) { calendar.startOfDay(for: $0.createdAt) }
            .map { day, dayMeals in
                (day: day, value: dayMeals.reduce(0) { $0 + nutrient.value(of: $1) })
            }
            .sorted { $0.day < $1.day }
    }

    private struct MealGroup: Identifiable {
        let id: String
        let meals: [Meal]
        let value: Double
    }

    private var groups: [MealGroup] {
        Dictionary(grouping: meals) { $0.title.isEmpty ? "Meal" : $0.title }
            .map { title, groupMeals in
                MealGroup(
                    id: title,
                    meals: groupMeals.sorted { $0.createdAt > $1.createdAt },
                    value: groupMeals.reduce(0) { $0 + nutrient.value(of: $1) }
                )
            }
            .sorted { $0.value > $1.value }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                // Goals stay visible even for an empty period — that's exactly
                // when you set them.
                if meals.isEmpty {
                    goalsSection
                    ContentUnavailableView(
                        "Nothing logged",
                        systemImage: "chart.bar",
                        description: Text("No meals in this \(period.title.lowercased()).")
                    )
                } else {
                    averagesSection
                    goalsSection
                    chartSection
                    contributorsSection
                }
            }
            .navigationTitle(periodLabel)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Meal.self) { meal in
                MealDetailView(meal: meal)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(containsToday)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: reloadKey) {
                #if DEBUG
                if LaunchHooks.consume("-overview-month") { period = .month }
                if LaunchHooks.consume("-open-goals") { showingGoalsEditor = true }
                #endif
                reload()
            }
            .sheet(isPresented: $showingGoalsEditor) {
                GoalsEditorView()
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

    private var reloadKey: String {
        "\(period.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)"
    }

    private var periodLabel: String {
        if containsToday {
            return period == .week ? "This Week" : "This Month"
        }
        switch period {
        case .week:
            let lastDay = interval.end.addingTimeInterval(-1)
            let start = interval.start.formatted(.dateTime.month(.abbreviated).day())
            let end = lastDay.formatted(.dateTime.month(.abbreviated).day())
            return "\(start) – \(end)"
        case .month:
            return anchor.formatted(.dateTime.month(.wide).year())
        }
    }

    private func shift(_ delta: Int) {
        anchor = calendar.date(byAdding: period.component, value: delta, to: anchor) ?? anchor
    }

    private func reload() {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<Meal>(
            predicate: #Predicate { $0.createdAt >= start && $0.createdAt < end },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        meals = (try? modelContext.fetch(descriptor)) ?? []
        expandedGroups = []
        selectedChartDay = nil
    }

    private func dailyAverage(_ nutrient: Nutrient) -> Double {
        let days = loggedDays.count
        guard days > 0 else { return 0 }
        return meals.reduce(0) { $0 + nutrient.value(of: $1) } / Double(days)
    }

    private var averagesSection: some View {
        Section {
            HStack(spacing: 10) {
                ForEach(Nutrient.allCases) { candidate in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            nutrient = candidate
                        }
                    } label: {
                        StatTile(
                            value: dailyAverage(candidate),
                            unit: candidate.unit,
                            label: candidate.title,
                            color: candidate.color,
                            isSelected: nutrient == candidate
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Daily Averages")
        } footer: {
            Text("Averaged over \(loggedDays.count) logged day\(loggedDays.count == 1 ? "" : "s") · \(meals.count) meal\(meals.count == 1 ? "" : "s"). Tap a tile to switch the chart and breakdown.")
        }
    }

    private func total(of nutrient: Nutrient) -> Double {
        meals.reduce(0) { $0 + nutrient.value(of: $1) }
    }

    private var weeksLogged: Int {
        Set(loggedDays.compactMap { calendar.dateInterval(of: .weekOfYear, for: $0)?.start }).count
    }

    /// What a goal is measured against in the current period view, with a label.
    private func goalValue(_ goal: NutrientGoal, nutrient: Nutrient) -> (value: Double, context: String) {
        switch (goal.period, period) {
        case (.weekly, .week):
            return (total(of: nutrient), "this week")
        case (.weekly, .month):
            return (total(of: nutrient) / Double(max(1, weeksLogged)), "avg/week")
        case (.daily, _):
            return (dailyAverage(nutrient), "avg/day")
        }
    }

    private var goalsSection: some View {
        Section {
            if settings.goals.isEmpty {
                Button {
                    showingGoalsEditor = true
                } label: {
                    Label("Set Goals", systemImage: "target")
                }
            } else {
                ForEach(Nutrient.allCases.filter { settings.goals[$0] != nil }) { nutrient in
                    goalRow(nutrient, goal: settings.goals[nutrient] ?? .suggested(for: nutrient))
                }
            }
        } header: {
            HStack {
                Text("Goals")
                Spacer()
                if !settings.goals.isEmpty {
                    Button("Edit") { showingGoalsEditor = true }
                        .font(.footnote)
                        .textCase(nil)
                }
            }
        } footer: {
            if settings.goals.isEmpty {
                Text("e.g. at least 120 g protein daily, or at most 2,000 kcal.")
            }
        }
    }

    private func goalRow(_ nutrient: Nutrient, goal: NutrientGoal) -> some View {
        let measured = goalValue(goal, nutrient: nutrient)
        let status = goal.status(value: measured.value, unit: nutrient.unit)
        let warning = status.state == .over && nutrient.warnsWhenExceeded
        let tint: Color = switch status.state {
        case .over: .red
        case .met: .green
        case .onTrack: nutrient.color
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(nutrient.title)
                    .font(.subheadline.weight(.medium))
                Text(goal.summary(unit: nutrient.unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(status.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.state == .onTrack ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
                    .monospacedDigit()
            }
            ProgressView(value: goal.progress(value: measured.value))
                .tint(tint)
            Text("\(Int(measured.value.rounded())) of \(Int(goal.amount.rounded())) \(nutrient.unit) · \(measured.context)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .listRowBackground(warning ? Color.red.opacity(0.09) : nil)
    }

    private var chartSection: some View {
        Section {
            Chart {
                ForEach(dailyTotals, id: \.day) { entry in
                    BarMark(
                        x: .value("Day", entry.day, unit: .day),
                        y: .value(nutrient.title, entry.value)
                    )
                    .foregroundStyle(nutrient.color.gradient)
                    .cornerRadius(3)
                }
                if let selectedChartDay,
                   let selected = dailyTotals.first(where: { calendar.isDate($0.day, inSameDayAs: selectedChartDay) }) {
                    RuleMark(x: .value("Selected", selected.day, unit: .day))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(spacing: 1) {
                                Text(selected.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(Int(selected.value.rounded())) \(nutrient.unit)")
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                } else if loggedDays.count > 1 {
                    RuleMark(y: .value("Average", dailyAverage(nutrient)))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("avg \(Int(dailyAverage(nutrient).rounded())) \(nutrient.unit)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartXScale(domain: interval.start...interval.end)
            .chartXSelection(value: $selectedChartDay)
            .chartXAxis {
                if period == .week {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                } else {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day())
                    }
                }
            }
            .frame(height: 190)
            .padding(.vertical, 6)
        } header: {
            Text("\(nutrient.title) per Day")
        } footer: {
            Text("Tap or drag on the chart to read a day.")
        }
    }

    private var contributorsSection: some View {
        Section {
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: expansionBinding(group.id)) {
                    ForEach(group.meals) { meal in
                        NavigationLink(value: meal) {
                            HStack {
                                Text(meal.createdAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(nutrient.value(of: meal).rounded())) \(nutrient.unit)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.id)
                                .font(.headline)
                            Text("\(group.meals.count)× logged")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(group.value.rounded())) \(nutrient.unit)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            if periodTotal > 0 {
                                Text("\(Int((group.value / periodTotal * 100).rounded()))% of total")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Top Contributors")
        } footer: {
            Text("Grouped by meal name, largest \(nutrient.title.lowercased()) first. Expand a group to open individual meals.")
        }
    }

    private func expansionBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(key) },
            set: { expanded in
                if expanded {
                    expandedGroups.insert(key)
                } else {
                    expandedGroups.remove(key)
                }
            }
        )
    }
}
