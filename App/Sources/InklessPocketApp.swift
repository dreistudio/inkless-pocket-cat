import SwiftUI

@main
struct InklessPocketApp: App {
    @StateObject private var link = PrinterLink()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(link) }
    }
}
