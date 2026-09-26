import Foundation

#if DEBUG
/// Simulator/testing launch-argument hooks. Each argument is consumed at most
/// once per process, so views that are recreated (day switches, navigation)
/// don't re-trigger a hook that already ran.
@MainActor
enum LaunchHooks {
    private static var consumed = Set<String>()

    static func consume(_ argument: String) -> Bool {
        guard ProcessInfo.processInfo.arguments.contains(argument),
              !consumed.contains(argument)
        else { return false }
        consumed.insert(argument)
        return true
    }

    static func consumeValue(after argument: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: argument), index + 1 < args.count,
              !consumed.contains(argument)
        else { return nil }
        consumed.insert(argument)
        return args[index + 1]
    }
}
#endif
