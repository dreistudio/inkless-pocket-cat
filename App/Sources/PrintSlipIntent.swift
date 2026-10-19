// "Print with Inkless Pocket" for Shortcuts, the Action Button and (through a Shortcut) the share sheet.
// The intent only hands the text to the app and opens it; the app prints once the printer is connected.
import AppIntents
import Foundation

struct PrintSlipIntent: AppIntent {
    static var title: LocalizedStringResource = "Print with Inkless Pocket"
    static var description = IntentDescription("Prints the text on the pocket printer.")
    static var openAppWhenRun = true

    @Parameter(title: "Text") var text: String

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(text, forKey: "pendingIntentText")
        return .result()
    }
}

struct InklessShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PrintSlipIntent(), phrases: ["Print with \(.applicationName)"], shortTitle: "Print slip", systemImageName: "printer")
    }
}
