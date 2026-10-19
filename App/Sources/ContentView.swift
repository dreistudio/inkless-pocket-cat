import SwiftUI
import UIKit
import InklessKit

struct ContentView: View {
    @EnvironmentObject var link: PrinterLink
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("darkness") private var darkness = 5
    @AppStorage("lastText") private var text = ""
    @AppStorage("printedChangeCount") private var printedChangeCount = -1
    @State private var pasteOffer = false
    @State private var busy = false
    @State private var bitmap = Renderer.render("")   // rendered once per text change, shown and printed as is
    @State private var slips = Slips.load()
    @FocusState private var editing: Bool

    private var canPrint: Bool { link.isConnected && !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        List {
            Group {
                header
                if pasteOffer { pasteChip }
                editor
                paper
                darknessPicker
                if !link.lastError.isEmpty { Text(link.lastError).font(.footnote).foregroundStyle(.red) }
            }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            if !slips.isEmpty { recent }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.paperRoom.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { printBar }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { becameActive() } }
        .onChange(of: text) { _, t in bitmap = Renderer.render(t) }
        .onChange(of: link.state) { _, s in
            if s == .printed { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            if case .notReady = s { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
        .onAppear { bitmap = Renderer.render(text); becameActive() }
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 12) {
            Image("CatPrinter").resizable().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 11))
            Text("Inkless Pocket").font(.system(.title2, design: .rounded, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            statusPill.layoutPriority(1)
        }.padding(.top, 8)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusShort).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .onTapGesture { if case .asleep = link.state { link.look() } }
    }

    private var pasteChip: some View {
        Button { pasteAndPrint() } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                Text("Paste & print what you just copied").fontWeight(.semibold)
                Spacer()
                Image(systemName: "arrow.right")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.logoYellow))
            .foregroundStyle(.black)
        }.buttonStyle(.plain).disabled(!link.isConnected || busy)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Type or paste a slip.\n# for a big line, --- for a rule")
                    .foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 14).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .focused($editing)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.card))
        .overlay(alignment: .topTrailing) {
            if !text.isEmpty {
                Button { text = ""; editing = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .padding(10).accessibilityLabel("Clear")
            }
        }
    }

    private var paper: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VStack(spacing: 0) {
                if let img = bitmap.cgImage() {
                    Image(decorative: img, scale: 1)
                        .resizable().interpolation(.none)
                        .aspectRatio(CGFloat(bitmap.width) / CGFloat(bitmap.height), contentMode: .fit)
                        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 18)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color.white)
            .clipShape(TornBottom())
            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
            .padding(.horizontal, 6)
            Text("\(bitmap.height) rows · \(Renderer.blocks(text).count) lines · \(String(format: "%.0f", Double(bitmap.height) / 8.0)) mm")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    private var darknessPicker: some View {
        HStack {
            Text("Darkness").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Picker("Darkness", selection: $darkness) { ForEach(1...5, id: \.self) { Text("\($0)").tag($0) } }
                .pickerStyle(.segmented).frame(maxWidth: 220)
        }
    }

    private var recent: some View {
        Section {
            ForEach(slips) { slip in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slip.text.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "# ", with: "") } ?? "")
                            .fontWeight(.semibold).lineLimit(1)
                        Text(slip.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { text = slip.text; Task { await printSlip() } } label: { Image(systemName: "printer").font(.body) }
                        .buttonStyle(.bordered).tint(.primary).disabled(!link.isConnected || busy)
                }
                .contentShape(Rectangle())
                .onTapGesture { text = slip.text; editing = false }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                .swipeActions { Button(role: .destructive) { slips = Slips.remove(slip) } label: { Label("Delete", systemImage: "trash") } }
            }
        } header: {
            Text("Recent").font(.headline).foregroundStyle(.primary).textCase(nil)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20))
        }
    }

    private var printBar: some View {
        Button { Task { await printSlip() } } label: {
            HStack(spacing: 12) {
                Image(systemName: busy ? "printer.fill" : "printer")
                VStack(alignment: .leading, spacing: 1) {
                    Text(printTitle).font(.headline)
                    Text(printSubtitle).font(.caption).opacity(0.75)
                }
                Spacer()
                if case .printing(let i, let n) = link.state, n > 0 {
                    ProgressView(value: Double(i), total: Double(n)).frame(width: 60).tint(.black)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18).fill(canPrint ? Color.logoYellow : Color.primary.opacity(0.08)))
            .foregroundStyle(canPrint ? .black : .secondary)
        }
        .buttonStyle(.plain).disabled(!canPrint)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
        .background(Color.paperRoom)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    // MARK: words and colours

    private var statusColor: Color {
        switch link.state {
        case .connected, .printed: return .green
        case .printing, .connecting, .looking: return .logoYellow
        case .asleep, .noAnswer, .unconfirmed: return .orange
        case .notReady: return .red
        case .bluetoothOff, .unavailable: return .gray
        }
    }
    private var statusShort: String {
        switch link.state {
        case .bluetoothOff: return "Bluetooth off"
        case .unavailable: return "no Bluetooth"
        case .looking: return "looking…"
        case .connecting: return "connecting…"
        case .connected, .printed: return link.battery.map { "connected · \($0) %" } ?? "connected"
        case .printing: return "printing"
        case .notReady: return "not ready"
        case .noAnswer: return "no answer"
        case .unconfirmed: return "unconfirmed"
        case .asleep: return "asleep · tap"
        }
    }
    private var printTitle: String {
        switch link.state {
        case .printing(let i, let n): return "Printing \(i)/\(n)"
        case .printed: return "Printed · print again"
        default: return "Print"
        }
    }
    private var printSubtitle: String {
        switch link.state {
        case .asleep, .looking: return "press the printer's button"
        case .connecting: return "connecting to the printer"
        case .connected: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "write or paste a slip first" : "\(bitmap.height) rows on JK01"
        case .notReady: return "printer not ready — paper? lid?"
        case .noAnswer: return "the printer did not answer — press its button"
        case .unconfirmed: return "sent, no confirmation — check the slip"
        case .printed: return "the slip is out"
        case .printing: return "keep the phone near the printer"
        case .bluetoothOff: return "turn Bluetooth on"
        case .unavailable: return "no Bluetooth on this device"
        }
    }

    // MARK: actions

    private func becameActive() {
        if case .asleep = link.state { link.look() }
        if let pending = UserDefaults.standard.string(forKey: "pendingIntentText"), !pending.isEmpty {
            UserDefaults.standard.removeObject(forKey: "pendingIntentText")
            text = pending
            Task { await printWhenConnected() }
            return
        }
        let pb = UIPasteboard.general
        pasteOffer = pb.hasStrings && pb.changeCount != printedChangeCount   // no read until tapped
    }

    private func pasteAndPrint() {
        guard let s = UIPasteboard.general.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { pasteOffer = false; return }
        text = s
        printedChangeCount = UIPasteboard.general.changeCount
        pasteOffer = false
        Task { await printSlip() }
    }

    /// For the intent: the printer may still be waking up when the app opens. Wait up to 20 s for a link.
    private func printWhenConnected() async {
        for _ in 0..<40 where !link.isConnected { try? await Task.sleep(for: .milliseconds(500)) }
        if link.isConnected { await printSlip() }
    }

    private func printSlip() async {
        busy = true; defer { busy = false }
        editing = false
        await link.print(bitmap, darkness: darkness)
        if link.state == .printed || link.state == .unconfirmed { slips = Slips.remember(text) }
    }
}

extension Color {
    /// The logo's background (sampled from AppIcon-1024.png: 253, 221, 137).
    static let logoYellow = Color(red: 253 / 255, green: 221 / 255, blue: 137 / 255)
    /// The room the paper lies in: warm off-white by day, warm charcoal at night.
    static let paperRoom = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1) : UIColor(red: 0.965, green: 0.945, blue: 0.905, alpha: 1) })
    static let card = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 1, alpha: 0.75) })
}

/// A slip torn off the roll: straight sides, a zigzag bottom edge.
struct TornBottom: Shape {
    var tooth: CGFloat = 7
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - tooth))
        var x = r.maxX; var up = false
        while x > r.minX {
            x = max(r.minX, x - tooth)
            p.addLine(to: CGPoint(x: x, y: up ? r.maxY - tooth : r.maxY)); up.toggle()
        }
        p.closeSubpath()
        return p
    }
}
