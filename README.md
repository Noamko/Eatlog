# Eatlog

> Formerly "MealSnap". Everything is renamed to Eatlog except two identifiers
> kept for compatibility: the bundle ID `com.noamko.MealSnap` (signing, Firebase,
> App Check) and the Keychain service string (saved API keys).

A personal iOS app for tracking what you eat. Photograph a meal (or describe it in
text), let an OpenAI vision model figure out what it is, edit the description if it
got something wrong, and save it to a daily diary with estimated calories, protein,
carbs, and fat.

## Requirements

- Xcode 16 or newer, iOS 18+ device or simulator
- An API key for at least one provider — OpenAI (platform.openai.com → API keys),
  Gemini (Google AI Studio, aistudio.google.com → Get API key), or Claude
  (console.anthropic.com → API Keys). Pick the provider in Settings; keys, model
  choices, and model lists are kept per provider

## Getting started

1. Open `Eatlog.xcodeproj` in Xcode and run the **Eatlog** scheme.
2. In the app, go to **Settings** and paste your OpenAI API key, then **Save Key**
   (and optionally **Test Key**). The key is stored in the iOS Keychain and only
   ever sent to `api.openai.com`.
3. In **Diary**, tap **+**, take or choose a photo of your meal — analysis starts
   automatically. Or skip the photo and type what you ate, then tap
   **Estimate from Description**.
4. Edit the description text if the AI misread anything, tap **Re-estimate**, adjust
   any number by hand if you like, and **Save**. A **Breakdown** section shows what
   each component of the meal contributed; tap the photo and it pops out into a
   large uncropped view over the blurred app, with pinch/double-tap zoom —
   tap outside, swipe down, or hit ✕ to close.
5. In the Diary, tap any totals tile (Calories, Protein, Carbs, Fat) to see where
   that day's number comes from: every meal's contribution largest-first with its
   share of the total, each broken into components, linking through to the meal.
6. The chart button next to the date arrows opens the **weekly/monthly overview**:
   daily-average tiles (tap one to pick the nutrient), a per-day bar chart with
   the period average and tap-to-read values, and top contributors grouped by
   meal name with drill-through to individual reports.

To install on your iPhone: select the project in Xcode → *Signing & Capabilities* →
choose your team, then pick your phone as the run destination.

## Keyless Gemini via Firebase (optional)

The app embeds Firebase AI Logic, Google's official way for mobile apps to call
Gemini **without any API key in the app or in Settings**. It activates
automatically when a Firebase config file is present; without it the app behaves
exactly as before (Gemini needs a pasted key). To set it up:

1. Go to console.firebase.google.com → **Add project** (no billing needed — the
   Gemini Developer API path has a free tier on the Spark plan).
2. In the project: **Add app → iOS**, bundle ID `com.noamko.MealSnap`, and
   download **GoogleService-Info.plist**.
3. In the console's **Firebase AI Logic** section, click through the setup for
   the **Gemini Developer API** backend.
4. Drop `GoogleService-Info.plist` into the `Eatlog/` source folder (next to
   `EatlogApp.swift`) — the folder-synced project picks it up automatically —
   and rebuild.

Settings will then show Gemini as "via Firebase, no key needed", and anyone you
install the app for can use Gemini with zero setup. A pasted Gemini key always
takes precedence (direct API calls) if you ever want it.

Notes: Firebase requires **App Check enforcement from Nov 2, 2026** — the app
already registers the debug provider in DEBUG builds; enable enforcement plus the
DeviceCheck provider in the console when you get there. Google's Grounding-with-
Search terms ask apps to display search suggestions/sources for grounded answers;
the analysis notes name sources, but review those terms if you keep web lookup on
via Firebase.

## How analysis works

Analysis goes through a small `AnalysisClient` protocol with three implementations:
`Services/OpenAIClient.swift` (OpenAI Responses API + hosted web_search),
`Services/GeminiClient.swift` (Gemini `streamGenerateContent` + Google Search
grounding; since Gemini sometimes rejects search combined with a strict response
schema, it tries search+schema, then search+prompt-enforced JSON, then schema-only),
and `Services/ClaudeClient.swift` (Anthropic Messages API with structured outputs
via `output_config.format` and the `web_search` server tool — newest tool variant
first, basic variant for older models like Haiku, then no tool). All send the
(downscaled) photo and/or description with a strict JSON schema, so the model
always returns:
`title`, `description` (one "Component — portion" per line), an `items` array with
each component's own calories/protein/carbs/fat, meal totals, and `notes` naming its
sources and assumptions. The app computes the displayed totals by summing the items,
so the breakdown always adds up. When both a photo and an edited description are
present, the prompt tells the model to trust the description.

The analysis follows a built-in "skill" prompt: identify components (preparation-
specific), estimate portions from visual cues, **look up nutrition values via the
hosted web-search tool** (USDA FoodData Central, brand/restaurant pages) and scale
them to the portion, never omit cooking fat/dressings/sauces, and sanity-check
against macro math (4/4/9 kcal per gram). Web lookup can be toggled off in Settings;
models without the web-search tool fall back to knowledge-only automatically.

Responses are **streamed**, so a long analysis (web search can take a minute or
more) never trips an idle network timeout, and the analyze button shows live
progress — "Searching the web…", "Writing it up…". Network failures get distinct
messages (offline, connection dropped, timed out) so slow analyses and bad
connections are easy to tell apart.

The model is chosen from a picker in Settings (default `gpt-4o-mini`). Once an API
key is saved, the list is fetched from `/v1/models` and filtered to chat-capable
models (dated snapshots hidden); with no key yet, a curated fallback list is shown.
For tricky photos a bigger vision model like `gpt-4o` or `gpt-5` does better.

## Ideas for later

- Daily calorie/protein goals and progress rings
- History charts (weekly/monthly trends)
- Favorites / repeat a previous meal
- HealthKit export
- Barcode scanning for packaged food
