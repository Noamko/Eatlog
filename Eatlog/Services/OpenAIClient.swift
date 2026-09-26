import Foundation

struct OpenAIClient: AnalysisClient {
    let apiKey: String
    let model: String
    let useWebSearch: Bool

    /// Analyze a meal from a photo, a text description, or both.
    /// When both are given, the description wins (the user may have corrected it).
    /// The hosted search tool has gone by two names, and not every model supports it,
    /// so try "web_search", then "web_search_preview", then knowledge-only.
    func analyzeMeal(
        imageJPEG: Data?,
        description: String?,
        onStatus: (@Sendable (AnalysisStatus) -> Void)? = nil
    ) async throws -> MealAnalysis {
        guard !apiKey.isEmpty else { throw AnalysisError.missingAPIKey }
        let attempts: [String?] = useWebSearch ? ["web_search", "web_search_preview", nil] : [nil]
        for (index, searchTool) in attempts.enumerated() {
            do {
                return try await requestAnalysis(
                    imageJPEG: imageJPEG,
                    description: description,
                    searchTool: searchTool,
                    onStatus: onStatus
                )
            } catch AnalysisError.badStatus(400, let message)
                where index < attempts.count - 1 && message.localizedCaseInsensitiveContains("web_search") {
                continue
            }
        }
        throw AnalysisError.emptyResponse
    }

    private func requestAnalysis(
        imageJPEG: Data?,
        description: String?,
        searchTool: String?,
        onStatus: (@Sendable (AnalysisStatus) -> Void)?
    ) async throws -> MealAnalysis {
        guard let instruction = AnalysisPrompt.instruction(hasImage: imageJPEG != nil, description: description)
        else { throw AnalysisError.emptyResponse }

        var content: [[String: Any]] = [
            ["type": "input_text", "text": instruction]
        ]
        if let imageJPEG {
            content.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())",
            ])
        }

        let itemSchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["name", "portion", "calories", "protein_g", "carbs_g", "fat_g"],
            "properties": [
                "name": ["type": "string", "description": "The component, specific about preparation, e.g. 'Grilled chicken breast'"],
                "portion": ["type": "string", "description": "Estimated portion, e.g. '150 g', '1 cup', '2 slices'"],
                "calories": ["type": "number", "description": "kcal for this portion"],
                "protein_g": ["type": "number"],
                "carbs_g": ["type": "number"],
                "fat_g": ["type": "number"],
            ],
        ]
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "description", "items", "calories", "protein_g", "carbs_g", "fat_g", "notes"],
            "properties": [
                "title": ["type": "string", "description": "Short meal name, at most 4 words"],
                "description": ["type": "string", "description": "One 'Name — portion' line per component"],
                "items": ["type": "array", "items": itemSchema],
                "calories": ["type": "number", "description": "Total kcal, equal to the sum over items"],
                "protein_g": ["type": "number"],
                "carbs_g": ["type": "number"],
                "fat_g": ["type": "number"],
                "notes": ["type": "string", "description": "Sources used and assumptions worth flagging; empty if none"],
            ],
        ]

        var body: [String: Any] = [
            "model": model,
            "instructions": AnalysisPrompt.system,
            "input": [["role": "user", "content": content]],
            "stream": true,
            "text": ["format": [
                "type": "json_schema",
                "name": "meal_analysis",
                "strict": true,
                "schema": schema,
            ]],
        ]
        if let searchTool {
            body["tools"] = [["type": searchTool]]
        }

        // Streamed so the connection is never idle while the model works —
        // a blocking call would trip URLSession's idle timeout on long analyses.
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AnalysisError.emptyResponse }
            guard (200..<300).contains(http.statusCode) else {
                var errorData = Data()
                for try await byte in bytes { errorData.append(byte) }
                throw AnalysisError.badStatus(http.statusCode, Self.errorMessage(from: errorData))
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, payload != "[DONE]",
                      let eventData = payload.data(using: .utf8),
                      let event = try? JSONDecoder().decode(StreamEnvelope.self, from: eventData)
                else { continue }

                switch event.type {
                case "response.web_search_call.in_progress", "response.web_search_call.searching":
                    onStatus?(.searching)
                case "response.output_text.delta":
                    onStatus?(.writing)
                case "response.completed":
                    guard let text = event.response?.outputText else { throw AnalysisError.emptyResponse }
                    return try MealAnalysis.decode(fromModelOutput: text)
                case "response.failed", "response.incomplete":
                    throw AnalysisError.responseError(
                        event.response?.error?.message ?? "The analysis did not complete."
                    )
                case "error":
                    throw AnalysisError.responseError(event.message ?? "Unknown streaming error.")
                default:
                    break
                }
            }
            throw AnalysisError.emptyResponse
        } catch let error as URLError {
            throw AnalysisError.network(from: error)
        }
    }

    private struct ResponsesReply: Decodable {
        struct Item: Decodable {
            struct Part: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let content: [Part]?
        }
        struct APIError: Decodable { let message: String? }
        let output: [Item]?
        let error: APIError?

        var outputText: String? {
            output?
                .last(where: { $0.type == "message" })?
                .content?
                .first(where: { $0.type == "output_text" })?
                .text
        }
    }

    private struct StreamEnvelope: Decodable {
        let type: String
        let response: ResponsesReply?
        let message: String?
    }

    /// Cheap request to check that the key works at all.
    func validateKey() async throws {
        _ = try await send(path: "models?limit=1", method: "GET", body: nil)
    }

    /// Chat-capable models available to this key, for the Settings picker.
    /// The API exposes no capability metadata, so filtering is by naming convention;
    /// dated snapshots (e.g. gpt-4o-2024-08-06) are dropped to keep the list short.
    func listModels() async throws -> [String] {
        let data = try await send(path: "models", method: "GET", body: nil)
        struct ModelsResponse: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let ids = try JSONDecoder().decode(ModelsResponse.self, from: data).data.map(\.id)
        let excludedFragments = [
            "embedding", "whisper", "tts", "audio", "realtime", "transcribe",
            "moderation", "dall-e", "image", "davinci", "babbage", "instruct",
            "search", "computer-use", "codex", "deep-research",
        ]
        let chatPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt-"]
        let models = ids.filter { id in
            chatPrefixes.contains(where: id.hasPrefix)
                && !excludedFragments.contains(where: id.contains)
                && id.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil
        }
        return Array(Set(models)).sorted()
    }

    private func send(path: String, method: String, body: Data?) async throws -> Data {
        guard !apiKey.isEmpty else { throw AnalysisError.missingAPIKey }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

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
