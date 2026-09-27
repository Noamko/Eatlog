import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct AddMealView: View {
    let day: Date

    init(day: Date) {
        self.day = day
        let initial: Date
        if Calendar.current.isDateInToday(day) {
            initial = .now
        } else {
            initial = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        }
        _mealTime = State(initialValue: min(initial, .now))
    }

    @State private var mealTime: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings

    @State private var photo: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var popoutRequest: PopoutRequest?
    @State private var photoFrame: CGRect = .zero

    @State private var title = ""
    @State private var details = ""
    @State private var calories: Double = 0
    @State private var protein: Double = 0
    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var components: [MealComponent] = []
    @State private var analysisNotes = ""

    @State private var isAnalyzing = false
    @State private var analysisStage: String?
    @State private var hasAnalyzed = false
    @State private var errorMessage: String?

    private var canAnalyze: Bool {
        photo != nil || !details.trimmed.isEmpty
    }

    private var canSave: Bool {
        photo != nil || !title.trimmed.isEmpty || !details.trimmed.isEmpty || calories > 0
    }

    private var analyzeButtonTitle: String {
        if hasAnalyzed { return "Re-estimate" }
        return photo != nil ? "Analyze Photo" : "Estimate from Description"
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                descriptionSection
                analyzeSection
                Section("Nutrition") {
                    NutritionFields(calories: $calories, protein: $protein, carbs: $carbs, fat: $fat)
                }
                if !components.isEmpty {
                    Section {
                        ComponentBreakdownRows(components: components)
                    } header: {
                        Text("Breakdown")
                    } footer: {
                        Text(analysisNotes.isEmpty
                            ? "What each part of the meal contributes, from the last analysis. Edit the description and re-estimate to refresh it."
                            : analysisNotes)
                    }
                }
            }
            .navigationTitle("Add Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave || isAnalyzing)
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { image in
                    setPhoto(image)
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                loadPickedPhoto(item)
            }
        }
        .overlay {
            if let popoutRequest {
                PhotoPopoutOverlay(request: popoutRequest) {
                    self.popoutRequest = nil
                }
            }
        }
    }

    private var photoSection: some View {
        Section {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()
                    .listRowInsets(EdgeInsets())
                    .overlay(alignment: .bottomLeading) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                            .padding(8)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isAnalyzing {
                            ProgressView()
                                .padding(8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .padding(8)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        popoutRequest = PopoutRequest(image: photo, sourceFrame: photoFrame, sourceCornerRadius: 24)
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { newFrame in
                        photoFrame = newFrame
                    }
                    .opacity(popoutRequest == nil ? 1 : 0)
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showingCamera = true
                } label: {
                    Label(photo == nil ? "Take Photo" : "Retake Photo", systemImage: "camera")
                }
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(photo == nil ? "Choose from Library" : "Choose Different Photo",
                      systemImage: "photo.on.rectangle")
            }
        } footer: {
            if photo == nil {
                Text("Snap your meal — or skip the photo and just describe it below.")
            }
        }
    }

    private var descriptionSection: some View {
        Section("Description") {
            DatePicker(
                "When",
                selection: $mealTime,
                in: ...Date.now,
                displayedComponents: [.date, .hourAndMinute]
            )
            TextField("Title (e.g. Chicken salad)", text: $title)
            ZStack(alignment: .topLeading) {
                if details.isEmpty {
                    Text("e.g. 2 scrambled eggs, toast with butter, orange juice")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $details)
                    .frame(minHeight: 90)
            }
        }
    }

    private var analyzeSection: some View {
        Section {
            Button {
                Task { await analyze() }
            } label: {
                HStack {
                    Spacer()
                    if isAnalyzing {
                        ProgressView()
                            .controlSize(.small)
                        Text(analysisStage ?? "Analyzing…")
                            .contentTransition(.opacity)
                    } else {
                        Image(systemName: "sparkles")
                        Text(analyzeButtonTitle)
                    }
                    Spacer()
                }
                .fontWeight(.semibold)
            }
            .disabled(isAnalyzing || !canAnalyze)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } footer: {
            if !settings.canAnalyze {
                Text("Add an API key in Settings to enable analysis.")
            } else {
                Text("AI reads the photo and description, then estimates nutrition. Edit the text and re-estimate any time.")
            }
        }
    }

    private func setPhoto(_ image: UIImage) {
        photo = image
        showingCamera = false
        if settings.canAnalyze {
            Task { await analyze() }
        }
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { @MainActor in
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                setPhoto(image)
            }
            photoItem = nil
        }
    }

    @MainActor
    private func analyze() async {
        guard !isAnalyzing else { return }
        errorMessage = nil
        guard settings.canAnalyze else {
            errorMessage = AnalysisError.missingAPIKey.localizedDescription
            return
        }
        isAnalyzing = true
        analysisStage = nil
        defer {
            isAnalyzing = false
            analysisStage = nil
        }
        do {
            let analysis = try await settings.client().analyzeMeal(
                imageJPEG: photo?.resizedJPEG(maxDimension: 1024, quality: 0.7),
                description: details.trimmed.isEmpty ? nil : details.trimmed,
                onStatus: { status in
                    Task { @MainActor in analysisStage = status.label }
                }
            )
            title = analysis.title
            details = analysis.description
            components = analysis.items
            calories = analysis.totalCalories
            protein = analysis.totalProtein
            carbs = analysis.totalCarbs
            fat = analysis.totalFat
            analysisNotes = analysis.notes
            hasAnalyzed = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        let meal = Meal(
            createdAt: mealTime,
            title: title.trimmed.isEmpty ? "Meal" : title.trimmed,
            details: details.trimmed,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            components: components,
            notes: analysisNotes,
            photoData: photo?.resizedJPEG(maxDimension: 1600, quality: 0.8)
        )
        modelContext.insert(meal)
        dismiss()
    }
}

struct NutritionFields: View {
    @Binding var calories: Double
    @Binding var protein: Double
    @Binding var carbs: Double
    @Binding var fat: Double

    private enum Field: Hashable {
        case calories, protein, carbs, fat
    }

    @FocusState private var focusedField: Field?

    var body: some View {
        row("Calories", value: $calories, unit: "kcal", field: .calories)
        row("Protein", value: $protein, unit: "g", field: .protein)
        row("Carbs", value: $carbs, unit: "g", field: .carbs)
        row("Fat", value: $fat, unit: "g", field: .fat)
            .toolbar {
                // Attached to a single row on purpose: a Group would replicate
                // the toolbar onto all four rows, showing four Done buttons.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
    }

    private func row(_ label: String, value: Binding<Double>, unit: String, field: Field) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .focused($focusedField, equals: field)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }
}
