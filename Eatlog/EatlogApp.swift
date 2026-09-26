import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseAppCheck

#if !DEBUG
/// Release builds attest with Apple's App Attest — the provider the Firebase
/// console registration expects. Requires the App Attest entitlement, which the
/// Release configuration applies via Eatlog.entitlements at the project root.
private final class AppAttestFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}
#endif

@main
struct EatlogApp: App {
    @State private var settings = AppSettings()

    init() {
        // Firebase powers keyless Gemini access. The app works fine without the
        // config file — Gemini then needs a user-supplied API key instead.
        if Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil {
            #if DEBUG
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
            #else
            AppCheck.setAppCheckProviderFactory(AppAttestFactory())
            #endif
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
        }
        .modelContainer(for: Meal.self)
    }
}
