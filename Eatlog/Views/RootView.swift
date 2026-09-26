import SwiftUI
import SwiftData
import UIKit

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings

    private enum Tab { case diary, settings }
    @State private var selectedTab = Self.initialTab()
    @State private var photoPopout = PhotoPopoutController()

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                DiaryView()
                    .tabItem { Label("Diary", systemImage: "fork.knife") }
                    .tag(Tab.diary)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(Tab.settings)
            }
            if let request = photoPopout.request {
                PhotoPopoutOverlay(request: request) {
                    photoPopout.request = nil
                }
            }
        }
        .environment(photoPopout)
        .task {
            seedSampleMealIfRequested()
            runTestAnalysisIfRequested()
            runExportImportTestsIfRequested()
        }
    }

    /// Simulator/testing hooks: `-test-export` writes the full export to
    /// Documents/export-test.json; `-test-import` imports Documents/import-input.json
    /// and writes the outcome to Documents/import-test.txt.
    private func runExportImportTestsIfRequested() {
        #if DEBUG
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if LaunchHooks.consume("-test-export"), let documents {
            do {
                let (data, count) = try MealExport.exportData(context: modelContext)
                try data.write(to: documents.appendingPathComponent("export-test.json"))
                try "OK exported \(count) meals, \(data.count) bytes"
                    .write(to: documents.appendingPathComponent("export-test.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? "FAIL \(error.localizedDescription)"
                    .write(to: documents.appendingPathComponent("export-test.txt"), atomically: true, encoding: .utf8)
            }
        }
        if LaunchHooks.consume("-test-import"), let documents {
            let outcome: String
            do {
                let data = try Data(contentsOf: documents.appendingPathComponent("import-input.json"))
                let result = try MealExport.importData(data, context: modelContext)
                outcome = "OK imported \(result.imported) skipped \(result.skipped)"
            } catch {
                outcome = "FAIL \(error.localizedDescription)"
            }
            try? outcome.write(
                to: documents.appendingPathComponent("import-test.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        #endif
    }

    /// Simulator/testing hooks: `-test-analysis <description>` runs a real
    /// text-only analysis with the active provider; `-test-analysis-photo` runs
    /// one with the sample photo. Outcomes land in Documents/test-analysis*.txt.
    private func runTestAnalysisIfRequested() {
        #if DEBUG
        if let text = LaunchHooks.consumeValue(after: "-test-analysis") {
            runTestAnalysis(imageJPEG: nil, description: text, resultFile: "test-analysis.txt")
        }
        if LaunchHooks.consume("-test-analysis-photo") {
            runTestAnalysis(
                imageJPEG: Self.samplePhoto(),
                description: nil,
                resultFile: "test-analysis-photo.txt"
            )
        }
        #endif
    }

    #if DEBUG
    private func runTestAnalysis(imageJPEG: Data?, description: String?, resultFile: String) {
        Task {
            let outcome: String
            do {
                let analysis = try await settings.client().analyzeMeal(
                    imageJPEG: imageJPEG,
                    description: description,
                    onStatus: nil
                )
                outcome = "OK \(analysis.title) | \(Int(analysis.totalCalories)) kcal P\(Int(analysis.totalProtein)) C\(Int(analysis.totalCarbs)) F\(Int(analysis.totalFat)) | items: \(analysis.items.count) | notes: \(analysis.notes)"
            } catch {
                outcome = "FAIL \(error.localizedDescription)"
            }
            if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? outcome.write(
                    to: documents.appendingPathComponent(resultFile),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }
    #endif

    /// Simulator/testing hook: `-open-settings` launch argument starts on the Settings tab.
    private static func initialTab() -> Tab {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-open-settings") { return .settings }
        #endif
        return .diary
    }

    /// Simulator/testing hook: `-seed-sample-meal` launch argument inserts a few
    /// days of example meals (including a repeated one, for grouped breakdowns).
    private func seedSampleMealIfRequested() {
        #if DEBUG
        guard LaunchHooks.consume("-seed-sample-meal") else { return }
        let calendar = Calendar.current

        func insert(
            _ title: String,
            daysAgo: Int,
            hour: Int,
            minute: Int,
            components: [MealComponent],
            photoData: Data? = nil
        ) {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
            let createdAt = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            modelContext.insert(Meal(
                createdAt: createdAt,
                title: title,
                details: components.map { "\($0.name) — \($0.portion)" }.joined(separator: "\n"),
                calories: components.totalCalories,
                protein: components.totalProtein,
                carbs: components.totalCarbs,
                fat: components.totalFat,
                components: components,
                photoData: photoData
            ))
        }

        insert("Chicken Salad", daysAgo: 0, hour: 13, minute: 0, components: [
            MealComponent(name: "Grilled chicken breast", portion: "150 g", calories: 248, protein: 46, carbs: 0, fat: 5),
            MealComponent(name: "Mixed greens", portion: "1 bowl", calories: 25, protein: 2, carbs: 5, fat: 0),
            MealComponent(name: "Olive oil dressing", portion: "1 tbsp", calories: 119, protein: 0, carbs: 0, fat: 14),
        ], photoData: Self.samplePhoto())
        insert("Coffee & Croissant", daysAgo: 0, hour: 8, minute: 30, components: [
            MealComponent(name: "Cappuccino", portion: "1 cup", calories: 120, protein: 6, carbs: 9, fat: 6),
            MealComponent(name: "Butter croissant", portion: "1", calories: 260, protein: 5, carbs: 26, fat: 15),
        ])
        insert("Pasta Bolognese", daysAgo: 1, hour: 19, minute: 40, components: [
            MealComponent(name: "Spaghetti", portion: "200 g cooked", calories: 310, protein: 11, carbs: 62, fat: 2),
            MealComponent(name: "Bolognese sauce", portion: "150 g", calories: 220, protein: 14, carbs: 10, fat: 14),
            MealComponent(name: "Parmesan", portion: "10 g", calories: 43, protein: 4, carbs: 0, fat: 3),
        ])
        insert("Oatmeal & Berries", daysAgo: 1, hour: 8, minute: 15, components: [
            MealComponent(name: "Rolled oats", portion: "40 g dry", calories: 150, protein: 5, carbs: 27, fat: 3),
            MealComponent(name: "Blueberries", portion: "100 g", calories: 57, protein: 1, carbs: 14, fat: 0),
            MealComponent(name: "Honey", portion: "1 tbsp", calories: 64, protein: 0, carbs: 17, fat: 0),
        ])
        insert("Coffee & Croissant", daysAgo: 2, hour: 9, minute: 5, components: [
            MealComponent(name: "Cappuccino", portion: "1 cup", calories: 120, protein: 6, carbs: 9, fat: 6),
            MealComponent(name: "Butter croissant", portion: "1", calories: 260, protein: 5, carbs: 26, fat: 15),
        ])
        insert("Grilled Salmon Bowl", daysAgo: 3, hour: 13, minute: 10, components: [
            MealComponent(name: "Grilled salmon", portion: "150 g", calories: 280, protein: 39, carbs: 0, fat: 13),
            MealComponent(name: "White rice", portion: "180 g cooked", calories: 234, protein: 5, carbs: 50, fat: 1),
            MealComponent(name: "Avocado", portion: "1/2", calories: 120, protein: 1, carbs: 6, fat: 11),
        ])
        #endif
    }

    #if DEBUG
    private static func samplePhoto() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600))
        let image = renderer.image { ctx in
            UIColor(red: 0.62, green: 0.45, blue: 0.28, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
            UIColor(white: 0.96, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 200, y: 60, width: 500, height: 480))
            UIColor(red: 0.85, green: 0.6, blue: 0.35, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 300, y: 160, width: 200, height: 140))
            UIColor(red: 0.35, green: 0.6, blue: 0.3, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 430, y: 300, width: 180, height: 130))
        }
        return image.jpegData(compressionQuality: 0.8)
    }
    #endif
}

#Preview {
    RootView()
        .environment(AppSettings())
        .modelContainer(for: Meal.self, inMemory: true)
}
