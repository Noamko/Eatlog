import Foundation

struct GeminiClient: AnalysisClient {
    let apiKey: String
    let model: String
    let useWebSearch: Bool

    private static let base = "https://generativelanguage.googleapis.com/v1beta"

    /// Gemini rejects some combinations of Google Search grounding and a strict
    /// response schema (it varies by model generation), so try: search + schema,
    /// then search + prompt-enforced JSON, then schema without search.
    private struct Variant {
        let search: Bool
        let strictSchema: Bool
    }

    func analyzeMeal(
        imageJPEG: Data?,
        description: String?,
        onStatus: (@Sendable (AnalysisStatus) -> Void)? = nil
    ) async throws -> MealAnalysis {
        guard !apiKey.isEmpty else { throw AnalysisError.missingAPIKey }
        let variants: [Variant] = useWebSearch
            ? [
                Variant(search: true, strictSchema: true),
                Variant(search: true, strictSchema: false),
                Variant(search: false, strictSchema: true),
            ]
            : [Variant(search: false, strictSchema: true)]
        for (index, variant) in variants.enumerated() {
            do {
                return try await requestAnalysis(
                    imageJPEG: imageJPEG,
                    description: description,
                    variant: variant,
                    onStatus: onStatus
                )
            } catch AnalysisError.badStatus(400, _) where index < variants.count - 1 {
                continue
            }
        }
        throw AnalysisError.emptyResponse
    }

    private func requestAnalysis(
        imageJPEG: Data?,
        description: String?,
        variant: Variant,
        onStatus: (@Sendable (AnalysisStatus) -> Void)?
    ) async throws -> MealAnalysis {
        guard var instruction = AnalysisPrompt.instruction(hasImage: imageJPEG != nil, description: description)
        else { throw AnalysisError.emptyResponse }
        if !variant.strictSchema {
            instruction += "\n\nRespond with ONLY the single JSON object — no markdown fences, no commentary."
        }

        var parts: [[String: Any]] = [["text": instruction]]
        if let imageJPEG {
            parts.append([
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": imageJPEG.base64EncodedString(),
                ],
            ])
        }

        var generationConfig: [String: Any] = [:]
        if variant.strictSchema {
            let itemSchema: [String: Any] = [
                "type": "OBJECT",
                "required": ["name", "portion", "calories", "protein_g", "carbs_g", "fat_g"],
                "properties": [
                    "name": ["type": "STRING"],
                    "portion": ["type": "STRING"],
                    "calories": ["type": "NUMBER"],
                    "protein_g": ["type": "NUMBER"],
                    "carbs_g": ["type": "NUMBER"],
                    "fat_g": ["type": "NUMBER"],
                ],
                "propertyOrdering": ["name", "portion", "calories", "protein_g", "carbs_g", "fat_g"],
            ]
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = [
                "type": "OBJECT",
                "required": ["title", "description", "items", "calories", "protein_g", "carbs_g", "fat_g", "notes"],
                "properties": [
                    "title": ["type": "STRING"],
                    "description": ["type": "STRING"],
                    "items": ["type": "ARRAY", "items": itemSchema],
                    "calories": ["type": "NUMBER"],
                    "protein_g": ["type": "NUMBER"],
                    "carbs_g": ["type": "NUMBER"],
                    "fat_g": ["type": "NUMBER"],
                    "notes": ["type": "STRING"],
                ],
                "propertyOrdering": ["title", "description", "items", "calories", "protein_g", "carbs_g", "fat_g", "notes"],
            ] as [String: Any]
        }

        var body: [String: Any] = [
            "system_instruction": ["parts": [["text": AnalysisPrompt.system]]],
            "contents": [["role": "user", "parts": parts]],
        ]
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
        }
        if variant.search {
            body["tools"] = [["google_search": [String: String]()]]
        }

        let modelID = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        var request = URLRequest(
            url: URL(string: "\(Self.base)/models/\(modelID):streamGenerateContent?alt=sse")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AnalysisError.emptyResponse }
            guard (200..<300).contains(http.statusCode) else {
                var errorData = Data()
                for try await byte in bytes { errorData.append(byte) }
                throw AnalysisError.badStatus(http.statusCode, Self.errorMessage(from: errorData))
            }

            if variant.search {
                onStatus?(.searching)
            }
            var accumulated = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty,
                      let chunkData = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(StreamChunk.self, from: chunkData)
                else { continue }

                if let message = chunk.error?.message {
                    throw AnalysisError.responseError(message)
                }
                if let text = chunk.text, !text.isEmpty {
                    if accumulated.isEmpty { onStatus?(.writing) }
                    accumulated += text
                }
                if let reason = chunk.finishReason, reason != "STOP", accumulated.isEmpty {
                    throw AnalysisError.responseError("The analysis stopped early (\(reason)).")
                }
            }
            guard !accumulated.isEmpty else { throw AnalysisError.emptyResponse }
            return try MealAnalysis.decode(fromModelOutput: accumulated)
        } catch let error as URLError {
            throw AnalysisError.network(from: error)
        }
    }

    private struct StreamChunk: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            let content: Content?
            let finishReason: String?
        }
        struct APIError: Decodable { let message: String? }
        let candidates: [Candidate]?
        let error: APIError?

        var text: String? {
            candidates?.first?.content?.parts?.compactMap(\.text).joined()
        }
        var finishReason: String? {
            candidates?.first?.finishReason
        }
    }

    func validateKey() async throws {
        _ = try await get(path: "models?pageSize=1")
    }

    /// Flash models below 3.5 are outdated — the picker only offers current ones.
    /// Unversioned ids (e.g. a "latest" alias) pass, since they track current models.
    static func meetsVersionPolicy(_ id: String) -> Bool {
        guard id.contains("flash") else { return true }
        guard let range = id.range(of: #"^gemini-(\d+(?:\.\d+)?)-"#, options: .regularExpression) else {
            return true
        }
        let version = Double(id[range].dropFirst("gemini-".count).dropLast()) ?? 0
        return version >= 3.5
    }

    /// Vision-capable Gemini chat models, for the Settings picker. Experimental,
    /// preview, and numbered-snapshot variants are dropped to keep the list short.
    func listModels() async throws -> [String] {
        let data = try await get(path: "models?pageSize=1000")
        struct ModelsResponse: Decodable {
            struct Model: Decodable {
                let name: String
                let supportedGenerationMethods: [String]?
            }
            let models: [Model]?
        }
        let excludedFragments = [
            "embedding", "tts", "image", "audio", "live", "exp", "preview",
            "vision", "aqa", "gemma", "learnlm",
        ]
        let ids = (try JSONDecoder().decode(ModelsResponse.self, from: data).models ?? [])
            .filter { $0.supportedGenerationMethods?.contains("generateContent") ?? false }
            .map { $0.name.hasPrefix("models/") ? String($0.name.dropFirst("models/".count)) : $0.name }
            .filter { id in
                id.hasPrefix("gemini")
                    && !excludedFragments.contains(where: id.contains)
                    && id.range(of: #"-\d{3}$"#, options: .regularExpression) == nil
                    && Self.meetsVersionPolicy(id)
            }
        return Array(Set(ids)).sorted()
    }

    private func get(path: String) async throws -> Data {
        guard !apiKey.isEmpty else { throw AnalysisError.missingAPIKey }
        var request = URLRequest(url: URL(string: "\(Self.base)/\(path)")!)
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw AnalysisError.network(from: error)
        }
        guard let http = response as? HTTPURLResponse else { throw AnalysisError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AnalysisError.badStatus(http.statusCode, Self.errorMessage(from: data))
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String {
        struct ErrorResponse: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        return (try? JSONDecoder().decode(ErrorResponse.self, from: data))?
            .error?.message ?? "Unknown error"
    }
}
