import Foundation

struct ClaudeClient: AnalysisClient {
    let apiKey: String
    let model: String
    let useWebSearch: Bool

    private static let base = "https://api.anthropic.com/v1"
    private static let apiVersion = "2023-06-01"

    /// The web search server tool has a newer variant (`web_search_20260209`) that
    /// older models such as Haiku 4.5 reject, so try newest → basic → no tool.
    func analyzeMeal(
        imageJPEG: Data?,
        description: String?,
        onStatus: (@Sendable (AnalysisStatus) -> Void)? = nil
    ) async throws -> MealAnalysis {
        guard !apiKey.isEmpty else { throw AnalysisError.missingAPIKey }
        let attempts: [String?] = useWebSearch
            ? ["web_search_20260209", "web_search_20250305", nil]
            : [nil]
        for (index, searchToolType) in attempts.enumerated() {
            do {
                return try await requestAnalysis(
                    imageJPEG: imageJPEG,
                    description: description,
                    searchToolType: searchToolType,
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
        searchToolType: String?,
        onStatus: (@Sendable (AnalysisStatus) -> Void)?
    ) async throws -> MealAnalysis {
        guard let instruction = AnalysisPrompt.instruction(hasImage: imageJPEG != nil, description: description)
        else { throw AnalysisError.emptyResponse }

        var content: [[String: Any]] = []
        if let imageJPEG {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": imageJPEG.base64EncodedString(),
                ],
            ])
        }
        content.append(["type": "text", "text": instruction])

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
            "max_tokens": 16000,
            "stream": true,
            "system": AnalysisPrompt.system,
            "messages": [["role": "user", "content": content]],
            "output_config": ["format": [
                "type": "json_schema",
                "schema": schema,
            ]],
        ]
        if let searchToolType {
            body["tools"] = [[
                "type": searchToolType,
                "name": "web_search",
                "max_uses": 5,
            ]]
        }

        var request = URLRequest(url: URL(string: "\(Self.base)/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
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

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var accumulated = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty,
                      let eventData = payload.data(using: .utf8),
                      let event = try? decoder.decode(StreamEvent.self, from: eventData)
                else { continue }

                switch event.type {
                case "content_block_start":
                    if event.contentBlock?.type == "server_tool_use" {
                        onStatus?(.searching)
                    }
                case "content_block_delta":
                    if event.delta?.type == "text_delta", let text = event.delta?.text {
                        if accumulated.isEmpty { onStatus?(.writing) }
                        accumulated += text
                    }
                case "message_delta":
                    switch event.delta?.stopReason {
                    case "refusal":
                        throw AnalysisError.responseError("The model declined to analyze this request.")
                    case "max_tokens":
                        throw AnalysisError.responseError("The response was cut off before finishing. Try again.")
                    default:
                        break
                    }
                case "error":
                    throw AnalysisError.responseError(event.error?.message ?? "Unknown streaming error.")
                default:
                    break
                }
            }
            guard !accumulated.isEmpty else { throw AnalysisError.emptyResponse }
            return try MealAnalysis.decode(fromModelOutput: accumulated)
        } catch let error as URLError {
            throw AnalysisError.network(from: error)
        }
    }

    private struct StreamEvent: Decodable {
        struct ContentBlock: Decodable { let type: String }
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stopReason: String?
        }
        struct APIError: Decodable { let message: String? }
        let type: String
        let contentBlock: ContentBlock?
        let delta: Delta?
        let error: APIError?
    }

    func validateKey() async throws {
        _ = try await get(path: "models?limit=1")
    }

    /// Claude models for the Settings picker. The Models API lists only chat models,
    /// so no capability filtering is needed — every entry works for analysis.
    func listModels() async throws -> [String] {
        let data = try await get(path: "models?limit=100")
        struct ModelsResponse: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]?
        }
        let ids = (try JSONDecoder().decode(ModelsResponse.self, from: data).data ?? [])
            .map(\.id)
            .filter { $0.hasPrefix("claude") }
        return Array(Set(ids)).sorted()
    }

    private func get(path: String) async throws -> Data {
        guard !apiKey.isEmpty else { throw AnalysisError.missingAPIKey }
        var request = URLRequest(url: URL(string: "\(Self.base)/\(path)")!)
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

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
