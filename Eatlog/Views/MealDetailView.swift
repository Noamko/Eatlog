import SwiftUI
import SwiftData
import UIKit

struct MealDetailView: View {
    @Bindable var meal: Meal

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isAnalyzing = false
    @State private var analysisStage: String?
    @State private var errorMessage: String?
    @Environment(PhotoPopoutController.self) private var photoPopout
    @State private var photoFrame: CGRect = .zero

    var body: some View {
        ScrollViewReader { proxy in
            form
                .task { await scrollToBottomIfRequested(proxy) }
                .task { await openPhotoViewerIfRequested() }
        }
    }

    private var form: some View {
        Form {
            if let data = meal.photoData, let image = UIImage(data: data) {
                Section {
                    Image(uiImage: image)
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
                        .contentShape(Rectangle())
                        .onTapGesture { openPhotoViewer() }
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .global)
                        } action: { newFrame in
                            photoFrame = newFrame
                        }
                        .opacity(photoPopout.request == nil ? 1 : 0)
                }
            }
            Section("Description") {
                DatePicker(
                    "When",
                    selection: $meal.createdAt,
                    in: ...Date.now,
                    displayedComponents: [.date, .hourAndMinute]
                )
                TextField("Title", text: $meal.title)
                TextEditor(text: $meal.details)
                    .frame(minHeight: 90)
            }
            Section {
                Button {
                    Task { await reanalyze() }
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
                            Text("Re-estimate Nutrition")
                        }
                        Spacer()
                    }
                    .fontWeight(.semibold)
                }
                .disabled(isAnalyzing || (meal.details.trimmed.isEmpty && meal.photoData == nil))
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Edit the description above, then re-estimate to update the numbers.")
            }
            Section("Nutrition") {
                NutritionFields(
                    calories: $meal.calories,
                    protein: $meal.protein,
                    carbs: $meal.carbs,
                    fat: $meal.fat
                )
            }
            if !meal.components.isEmpty {
                Section {
                    ComponentBreakdownRows(components: meal.components)
                } header: {
                    Text("Breakdown")
                } footer: {
                    Text(meal.notes.isEmpty
                        ? "What each part of the meal contributes, from the last analysis."
                        : meal.notes)
                }
            }
            Section {
                Button("Delete Meal", role: .destructive) {
                    modelContext.delete(meal)
                    dismiss()
                }
                .id("form-bottom")
            }
        }
        .navigationTitle(meal.title.isEmpty ? "Meal" : meal.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openPhotoViewer() {
        guard let data = meal.photoData, let image = UIImage(data: data) else { return }
        photoPopout.request = PopoutRequest(image: image, sourceFrame: photoFrame, sourceCornerRadius: 24)
    }

    /// Simulator/testing hook: `-open-photo-viewer` launch argument opens the photo popout.
    private func openPhotoViewerIfRequested() async {
        #if DEBUG
        guard LaunchHooks.consume("-open-photo-viewer"),
              meal.photoData != nil else { return }
        try? await Task.sleep(for: .milliseconds(1300))
        openPhotoViewer()
        #endif
    }

    /// Simulator/testing hook: `-scroll-bottom` launch argument opens the form scrolled to the end.
    private func scrollToBottomIfRequested(_ proxy: ScrollViewProxy) async {
        #if DEBUG
        guard LaunchHooks.consume("-scroll-bottom") else { return }
        try? await Task.sleep(for: .milliseconds(900))
        withAnimation { proxy.scrollTo("form-bottom", anchor: .bottom) }
        #endif
    }

    @MainActor
    private func reanalyze() async {
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
                imageJPEG: meal.photoData,
                description: meal.details.trimmed.isEmpty ? nil : meal.details.trimmed,
                onStatus: { status in
                    Task { @MainActor in analysisStage = status.label }
                }
            )
            meal.title = analysis.title
            meal.details = analysis.description
            meal.components = analysis.items
            meal.calories = analysis.totalCalories
            meal.protein = analysis.totalProtein
            meal.carbs = analysis.totalCarbs
            meal.fat = analysis.totalFat
            meal.notes = analysis.notes
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
