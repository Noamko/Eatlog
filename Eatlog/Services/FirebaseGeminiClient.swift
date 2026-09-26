import Foundation
import UIKit
import FirebaseCore
import FirebaseAILogic

/// Gemini through Firebase AI Logic — no user API key. The app authenticates via
/// the bundled Firebase project config (GoogleService-Info.plist); when that file
/// is absent this client reports itself unavailable and the app falls back to
/// direct Gemini API calls with a user-supplied key.
struct FirebaseGeminiClient: AnalysisClient {
    let model: String
    let useWebSearch: Bool

    /// True when a Firebase config was bundled and configured at launch.
    static var isAvailable: Bool {
        FirebaseApp.app() != nil
    }

    func analyzeMeal(
        imageJPEG: Data?,
        description: String?,
        onStatus: (@Sendable (AnalysisStatus) -> Void)? = nil
    ) async throws -> MealAnalysis {
        guard Self.isAvailable else {
            throw AnalysisError.responseError("Firebase isn't configured — add GoogleService-Info.plist to the app, or set a Gemini API key.")
        }
        // Gemini 3.5+ supports Google Search combined with a response schema, but
        // keep a schema-only retry in case a chosen model rejects the combination.
        let variants: [Bool] = useWebSearch ? [true, false] : [false]
        var lastError: Error?
        for (index, search) in variants.enumerated() {
            do {
                return try await request(
                    imageJPEG: imageJPEG,
                    description: description,
                    search: search,
                    onStatus: onStatus
                )
            } catch let error as URLError {
                throw AnalysisError.network(from: error)
            } catch let error as AnalysisError {
                throw error
            } catch where index < variants.count - 1 {
                lastError = error
                continue
            } catch {
                throw AnalysisError.responseError(Self.detailedMessage(for: error))
            }
        }
        if let lastError {
            throw AnalysisError.responseError(Self.detailedMessage(for: lastError))
        }
        throw AnalysisError.emptyResponse
    }

    /// The SDK's errors stringify uselessly ("GenerateContentError error 0"),
    /// so dig out the underlying cause for display.
    private static func detailedMessage(for error: Error) -> String {
        var current = error as NSError
        while let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
            current = underlying
        }
        let localized = current.localizedDescription
        if localized.contains("error 0") || localized.hasSuffix("couldn’t be completed.") {
            return String(describing: error).prefix(500).description
        }
        return localized
    }

    private func request(
        imageJPEG: Data?,
        description: String?,
        search: Bool,
        onStatus: (@Sendable (AnalysisStatus) -> Void)?
    ) async throws -> MealAnalysis {
        guard let instruction = AnalysisPrompt.instruction(hasImage: imageJPEG != nil, description: description)
        else { throw AnalysisError.emptyResponse }

        let itemSchema = Schema.object(properties: [
            "name": .string(),
            "portion": .string(),
            "calories": .double(),
            "protein_g": .double(),
            "carbs_g": .double(),
            "fat_g": .double(),
        ])
        let schema = Schema.object(properties: [
            "title": .string(),
            "description": .string(),
            "items": .array(items: itemSchema),
            "calories": .double(),
            "protein_g": .double(),
            "carbs_g": .double(),
            "fat_g": .double(),
            "notes": .string(),
        ])

        // Limited-use tokens: fresh App Check token per request (replay protection).
        // The console's AI Logic enforcement can require these; standard cached
        // tokens then come back as "App Check token is invalid".
        let generativeModel = FirebaseAI.firebaseAI(
            backend: .googleAI(),
            useLimitedUseAppCheckTokens: true
        ).generativeModel(
            modelName: model,
            generationConfig: GenerationConfig(
                responseMIMEType: "application/json",
                responseSchema: schema
            ),
            tools: search ? [.googleSearch()] : nil,
            systemInstruction: ModelContent(role: "system", parts: AnalysisPrompt.system)
        )

        if search {
            onStatus?(.searching)
        }
        let stream: AsyncThrowingStream<GenerateContentResponse, any Error>
        if let imageJPEG, let image = UIImage(data: imageJPEG) {
            stream = try generativeModel.generateContentStream(image, instruction)
        } else {
            stream = try generativeModel.generateContentStream(instruction)
        }

        var accumulated = ""
        for try await chunk in stream {
            if let text = chunk.text, !text.isEmpty {
                if accumulated.isEmpty { onStatus?(.writing) }
                accumulated += text
            }
        }
        guard !accumulated.isEmpty else { throw AnalysisError.emptyResponse }
        return try MealAnalysis.decode(fromModelOutput: accumulated)
    }

    func validateKey() async throws {
        guard Self.isAvailable else {
            throw AnalysisError.responseError("Firebase isn't configured — add GoogleService-Info.plist to the app.")
        }
    }

    /// Firebase AI Logic has no model-listing endpoint for client apps,
    /// so the picker keeps the curated current-model list.
    func listModels() async throws -> [String] {
        AIProvider.gemini.fallbackModels
    }
}
