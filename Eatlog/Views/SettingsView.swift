import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct JSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var keyDraft = ""
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportDocument: JSONDocument?
    @State private var exportCount = 0
    @State private var dataMessage: String?
    @State private var dataFailed = false
    @State private var testState: TestState = .idle
    @State private var isRefreshingModels = false
    @State private var modelsError: String?

    private enum TestState: Equatable {
        case idle, testing, success, failure(String)
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    ForEach(AIProvider.allCases) { provider in
                        Button {
                            settings.provider = provider
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.displayName)
                                    Text(providerSubtitle(provider))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if settings.provider == provider {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("AI Provider")
                } footer: {
                    Text("Meals are analyzed with the checked provider, using the model shown. The sections below configure it.")
                }

                Section {
                    SecureField(keyPlaceholder, text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Key") {
                        settings.apiKey = keyDraft.trimmed
                        testState = .idle
                        Task { await refreshModels(showErrors: false) }
                    }
                    .disabled(keyDraft.trimmed.isEmpty || keyDraft.trimmed == settings.apiKey)
                    if settings.hasAPIKey {
                        Label("Key saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                        Button {
                            Task { await testKey() }
                        } label: {
                            if testState == .testing {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Testing…")
                                }
                            } else {
                                Text("Test Key")
                            }
                        }
                        .disabled(testState == .testing)
                        Button("Remove Key", role: .destructive) {
                            settings.apiKey = ""
                            keyDraft = ""
                            testState = .idle
                        }
                    }
                    switch testState {
                    case .success:
                        Label("Key works", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    case .failure(let message):
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    case .idle, .testing:
                        EmptyView()
                    }
                } header: {
                    Text("\(settings.provider.displayName) API Key")
                } footer: {
                    Text(keyFooter)
                }

                Section {
                    Picker("Model", selection: $settings.model) {
                        ForEach(modelChoices, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Button {
                        Task { await refreshModels(showErrors: true) }
                    } label: {
                        if isRefreshingModels {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Refreshing…")
                            }
                        } else {
                            Text("Refresh Model List")
                        }
                    }
                    .disabled(!settings.canAnalyze || isRefreshingModels)
                    if let modelsError {
                        Text(modelsError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Model")
                } footer: {
                    if settings.hasAPIKey {
                        Text(modelFooter)
                    } else {
                        Text("Showing common models. Save an API key to load the models your account can actually use.")
                    }
                }

                Section {
                    Toggle("Look up nutrition data online", isOn: $settings.useWebSearch)
                } header: {
                    Text("Analysis")
                } footer: {
                    Text("The model searches the web (USDA, brand and restaurant nutrition pages) and scales real values to your portions instead of relying on memory — using the provider's built-in search tool. More accurate, a little slower, may be billed by the provider. Models without search support fall back automatically.")
                }

                Section {
                    Button {
                        prepareExport()
                    } label: {
                        Label("Export Data", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        dataMessage = nil
                        showingImporter = true
                    } label: {
                        Label("Import Data", systemImage: "square.and.arrow.down")
                    }
                    if let dataMessage {
                        Text(dataMessage)
                            .font(.footnote)
                            .foregroundStyle(dataFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Everything you've logged — meals, breakdowns, notes, and photos — as a single JSON file. Importing merges: meals already present are skipped. API keys are not included.")
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0")
                    Text("Nutrition values are AI estimates. Treat them as approximations, not medical advice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear { keyDraft = settings.apiKey }
            .task { await refreshModels(showErrors: false) }
            .onChange(of: settings.provider) { _, _ in
                keyDraft = settings.apiKey
                testState = .idle
                modelsError = nil
                Task { await refreshModels(showErrors: false) }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "Eatlog-Export-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
            ) { result in
                switch result {
                case .success:
                    dataFailed = false
                    dataMessage = "Exported \(exportCount) meal\(exportCount == 1 ? "" : "s")."
                case .failure(let error):
                    dataFailed = true
                    dataMessage = error.localizedDescription
                }
                exportDocument = nil
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.json]
            ) { result in
                switch result {
                case .success(let url):
                    runImport(from: url)
                case .failure(let error):
                    dataFailed = true
                    dataMessage = error.localizedDescription
                }
            }
        }
    }

    private func prepareExport() {
        dataMessage = nil
        do {
            let (data, count) = try MealExport.exportData(context: modelContext)
            exportDocument = JSONDocument(data: data)
            exportCount = count
            showingExporter = true
        } catch {
            dataFailed = true
            dataMessage = error.localizedDescription
        }
    }

    private func runImport(from url: URL) {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let result = try MealExport.importData(data, context: modelContext)
            dataFailed = false
            if result.imported == 0 && result.skipped > 0 {
                dataMessage = "Nothing new to import — all \(result.skipped) meals are already here."
            } else if result.skipped > 0 {
                dataMessage = "Imported \(result.imported) meal\(result.imported == 1 ? "" : "s"), skipped \(result.skipped) already present."
            } else {
                dataMessage = "Imported \(result.imported) meal\(result.imported == 1 ? "" : "s")."
            }
        } catch {
            dataFailed = true
            dataMessage = error.localizedDescription
        }
    }

    private func providerSubtitle(_ provider: AIProvider) -> String {
        let keyState: String
        if settings.hasAPIKey(for: provider) {
            keyState = "key saved"
        } else if provider == .gemini && FirebaseGeminiClient.isAvailable {
            keyState = "via Firebase, no key needed"
        } else {
            keyState = "no key"
        }
        return "\(settings.model(for: provider)) · \(keyState)"
    }

    private var keyPlaceholder: String {
        switch settings.provider {
        case .openAI: return "sk-…"
        case .gemini: return "AIza…"
        case .claude: return "sk-ant-…"
        }
    }

    private var keyFooter: String {
        switch settings.provider {
        case .openAI:
            return "Stored in the iOS Keychain and sent only to api.openai.com. Create a key at platform.openai.com under API keys."
        case .gemini:
            if FirebaseGeminiClient.isAvailable {
                return "Firebase is configured, so Gemini needs no API key. Paste one only if you want to call the Gemini API directly instead."
            }
            return "Stored in the iOS Keychain and sent only to Google's Gemini API. Create a free key in Google AI Studio (aistudio.google.com) under Get API key — or skip keys entirely by adding a Firebase config (see the README)."
        case .claude:
            return "Stored in the iOS Keychain and sent only to api.anthropic.com. Create a key at console.anthropic.com under API Keys."
        }
    }

    private var modelFooter: String {
        switch settings.provider {
        case .openAI:
            return "Models come from your OpenAI account. For photo analysis pick a vision-capable one — gpt-4o, gpt-4.1, or gpt-5 families (mini variants are cheaper)."
        case .gemini:
            return "Models come from your Google account. Flash models (3.5 and up) are fast and cheap; Pro models are the most accurate."
        case .claude:
            return "Models come from your Anthropic account. claude-opus-5 is the most capable; claude-sonnet-5 balances cost and quality; claude-haiku-4-5 is the cheapest."
        }
    }

    /// The fetched (or fallback) models, always including the current selection
    /// so the picker never shows an empty value.
    private var modelChoices: [String] {
        var models = settings.availableModels
        if !settings.model.isEmpty && !models.contains(settings.model) {
            models.append(settings.model)
            models.sort()
        }
        return models
    }

    @MainActor
    private func refreshModels(showErrors: Bool) async {
        guard settings.canAnalyze, !isRefreshingModels else { return }
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            try await settings.refreshAvailableModels()
            modelsError = nil
        } catch {
            if showErrors {
                modelsError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func testKey() async {
        testState = .testing
        do {
            try await settings.client().validateKey()
            testState = .success
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }
}
