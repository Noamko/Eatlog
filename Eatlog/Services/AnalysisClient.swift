import Foundation

/// A meal-analysis backend (OpenAI, Gemini, …).
protocol AnalysisClient: Sendable {
    func analyzeMeal(
        imageJPEG: Data?,
        description: String?,
        onStatus: (@Sendable (AnalysisStatus) -> Void)?
    ) async throws -> MealAnalysis
    func validateKey() async throws
    func listModels() async throws -> [String]
}

enum AnalysisError: LocalizedError {
    case missingAPIKey
    case badStatus(Int, String)
    case responseError(String)
    case network(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key set for the selected AI provider. Add one in Settings."
        case .badStatus(let code, let message):
            if code == 401 || code == 403 {
                return "The provider rejected the API key. Check it in Settings."
            }
            return "Provider error (\(code)): \(message)"
        case .responseError(let message):
            return "Provider error: \(message)"
        case .network(let message):
            return message
        case .emptyResponse:
            return "The model returned an empty or unreadable response."
        }
    }

    static func network(from error: URLError) -> AnalysisError {
        switch error.code {
        case .timedOut:
            return .network("The analysis timed out — with web lookup it can take a while. Try again, or turn off web lookup in Settings for faster results.")
        case .notConnectedToInternet, .dataNotAllowed:
            return .network("No internet connection. Check your network and try again.")
        case .networkConnectionLost:
            return .network("The connection dropped during the analysis. Try again.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .network("Couldn't reach the AI provider. Check your network and try again.")
        default:
            return .network(error.localizedDescription)
        }
    }
}

/// Live progress of an analysis, for showing in the UI while it runs.
enum AnalysisStatus: Sendable {
    case searching
    case writing

    var label: String {
        switch self {
        case .searching: return "Searching the web…"
        case .writing: return "Writing it up…"
        }
    }
}

/// The analysis "skill" shared by every provider: a methodology the model must
/// follow, designed to make estimates precise and grounded in real data.
enum AnalysisPrompt {
    static let system = """
    You are a professional nutrition analyst inside a meal tracking app. From a meal \
    photo and/or the user's description you produce accurate, well-grounded nutrition \
    estimates.

    Follow this method every time:
    1. Identify each distinct component of the meal (foods AND drinks), being specific \
    about preparation: grilled vs fried, with skin vs without, whole vs low-fat dairy, \
    white vs whole-grain bread. The user's description always outranks what the photo shows.
    2. Estimate each component's portion from visual cues: plate/bowl/glass size, \
    utensils, packaging, thickness, and how much of the dish it covers. Prefer grams or \
    milliliters; otherwise use standard household measures. When uncertain, use the \
    typical serving — realistic, not optimistic.
    3. Ground the numbers in real data instead of inventing them: use web search to look \
    up each component's nutrition values, preferring USDA FoodData Central, national food \
    composition databases, and official brand or restaurant nutrition pages. Search for \
    the specific preparation, then scale per-100 g or per-serving values to your portion \
    estimate. Only fall back to your own knowledge when search is unavailable or finds nothing.
    4. Never omit cooking fat (oil, butter), dressings, sauces, sugar in drinks — the \
    most commonly missed calories. Restaurant food gets restaurant-typical amounts of fat.
    5. Sanity-check every item and the totals against macro math: calories should be \
    close to 4×protein_g + 4×carbs_g + 9×fat_g (alcohol adds 7 kcal/g). If it is off by \
    more than about 15%, re-derive the numbers.
    6. The reported totals must equal the sums over the items. Round sensibly: whole \
    kcal, grams with at most one decimal.
    """

    /// The per-request instruction. Returns nil when there is nothing to analyze.
    static func instruction(hasImage: Bool, description: String?) -> String? {
        var instruction = """
        Analyze this meal and report it in JSON:
        - "title": short meal name, at most 4 words.
        - "items": one entry per component of the meal, each with "name", "portion" \
        (e.g. "150 g", "1 cup", "2 slices") and that component's own "calories" (kcal), \
        "protein_g", "carbs_g", "fat_g".
        - "description": the same components, one per line, formatted "Name — portion". No other prose.
        - "calories", "protein_g", "carbs_g", "fat_g": totals for the whole meal, equal to the sums over "items".
        - "notes": one short sentence naming the data sources used and any assumption \
        worth flagging (e.g. "USDA values; assumed 1 tbsp oil in the pan"). Empty string if none.

        """
        switch (hasImage, description) {
        case (true, .some(let text)):
            instruction += """
            A photo of the meal is attached. The user describes it as:
            \(text)
            If the description and the photo disagree, trust the description — the user corrected it.
            """
        case (true, .none):
            instruction += "A photo of the meal is attached. Identify its components from the photo."
        case (false, .some(let text)):
            instruction += "There is no photo. The meal is described as:\n\(text)"
        case (false, .none):
            return nil
        }
        return instruction
    }
}
