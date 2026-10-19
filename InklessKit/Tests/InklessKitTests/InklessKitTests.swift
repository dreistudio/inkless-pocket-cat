import XCTest
@testable import InklessKit

final class ProtocolTests: XCTestCase {
    func testCRC8() { XCTAssertEqual(MXW01.crc8([0x62]), 0x29); XCTAssertEqual(MXW01.crc8([]), 0) }
    func testDensityPacket() { XCTAssertEqual(MXW01.density(darkness: 5).hexString, "2221a20001006229ff"); XCTAssertEqual(MXW01.density(darkness: 9), MXW01.density(darkness: 5)) }
    func testStartPrintHasLiteralTail() { XCTAssertEqual(MXW01.startPrint(rows: 56).hexString, "2221a9000400380030000000"); XCTAssertEqual(MXW01.startPrint(rows: 300).hexString, "2221a90004002c0130000000") }
    func testFixedPackets() {
        XCTAssertEqual(MXW01.connectInit.hexString, "2221b10001000000ff")
        XCTAssertEqual(MXW01.finalize.hexString, "2221ad000100000000")
    }
    func testPackRowIsLSBFirst() {
        var px = [Bool](repeating: false, count: 384); px[0] = true; px[9] = true; px[383] = true
        let row = MXW01.packRow(px)
        XCTAssertEqual(row.count, 48); XCTAssertEqual(row[0], 0x01); XCTAssertEqual(row[1], 0x02); XCTAssertEqual(row[47], 0x80)
    }
    func testParseNotifications() {
        XCTAssertEqual(MXW01.parse(Data(hex: "2221b1000a00312e392e303931372e3200")), .firmware("1.9.0917.2"))
        XCTAssertEqual(MXW01.parse(Data(hex: "2221a7000600ffffffffffff00")), .serial("ffffffffffff"))
        XCTAssertEqual(MXW01.parse(Data(hex: "2221a90001000000")), .startAck(status: 0))
        XCTAssertEqual(MXW01.parse(Data(hex: "2221a90001000100")), .startAck(status: 1))
        XCTAssertEqual(MXW01.parse(Data(hex: "2221aa00030000585800")), .done)
        XCTAssertEqual(MXW01.parse(Data(hex: "2221AE0101001070FF")), .pause)
        XCTAssertEqual(MXW01.parse(Data(hex: "AA00")), .resume)
        XCTAssertEqual(MXW01.parse(Data(hex: "2221a1000800010052201f000000ff")), .status(state: 1, battery: 0x20, temperature: 0x1f, errorGroup: 0, errorCode: 0))
        XCTAssertEqual(MXW01.parse(Data(hex: "2221b2000000")), .wantsStatusPoll)
        XCTAssertEqual(MXW01.parse(Data(hex: "0102")), .other(Data(hex: "0102")))
    }
}

final class FlowTests: XCTestCase {
    func testAckGatesTheStream() {
        var paused = false
        XCTAssertEqual(FlowRule.next(.waitingForStart, on: .firmware("x"), paused: &paused), .waitingForStart)
        XCTAssertEqual(FlowRule.next(.waitingForStart, on: .startAck(status: 0), paused: &paused), .streaming)
        XCTAssertEqual(FlowRule.next(.waitingForStart, on: .startAck(status: 2), paused: &paused), .notReady(2))
    }
    func testPauseAndResumeMidStream() {
        var paused = false
        XCTAssertEqual(FlowRule.next(.streaming, on: .pause, paused: &paused), .streaming); XCTAssertTrue(paused)
        XCTAssertEqual(FlowRule.next(.streaming, on: .status(state: 1, battery: 1, temperature: 1, errorGroup: 0, errorCode: 0), paused: &paused), .streaming); XCTAssertTrue(paused)
        XCTAssertEqual(FlowRule.next(.streaming, on: .resume, paused: &paused), .streaming); XCTAssertFalse(paused)
    }
    func testDoneOnlyWhenWaitingForIt() {
        var paused = false
        XCTAssertEqual(FlowRule.next(.streaming, on: .done, paused: &paused), .streaming)
        XCTAssertEqual(FlowRule.next(.waitingForDone, on: .done, paused: &paused), .finished)
    }
    func testChunking() {
        let job = PrintJob(rows: Array(repeating: [UInt8](repeating: 0xAB, count: 48), count: 10), darkness: 3)
        XCTAssertEqual(job.chunks.count, 3); XCTAssertEqual(job.chunks[0].count, 180); XCTAssertEqual(job.chunks[2].count, 120)
        XCTAssertEqual(job.preamble[0].hexString, "2221a20001005d94ff")
    }
}

final class FixtureTests: XCTestCase {
    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
    /// The Kit encodes the reference bitmap to exactly the bytes the Python tool sent to the printer.
    func testTranscriptMatchesThePythonReference() throws {
        let bitmap = try XCTUnwrap(Bitmap(pbm: try fixture("hello.pbm")))
        let expected = try fixture("hello.transcript.hex").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(PrintJob(bitmap: bitmap, darkness: 5).transcript, expected)
    }
    /// Rendering is pinned loosely (CoreText vs Pillow hinting): same width, rows within 2, ink within 5 %, umlauts present.
    func testRendererMatchesTheReferenceShape() throws {
        let reference = try XCTUnwrap(Bitmap(pbm: try fixture("hello.pbm")))
        let text = try fixture("hello.txt")
        let ours = Renderer.render(text)
        XCTAssertEqual(ours.width, 384)
        XCTAssertLessThanOrEqual(abs(ours.height - reference.height), 2)
        XCTAssertLessThanOrEqual(abs(ours.inkCoverage - reference.inkCoverage), 0.05, "ink \(ours.inkCoverage) vs \(reference.inkCoverage)")
        XCTAssertGreaterThan(Renderer.render("ä").inkCoverage, Renderer.render(" ").inkCoverage)
        XCTAssertGreaterThan(Renderer.render("ä").inkCoverage, Renderer.render("a").inkCoverage, "the umlaut dots must survive")
    }
    func testWrapByPixelWidth() {
        let lines = Renderer.wrap("Milch Brot Äpfel Bananen Joghurt Butter Käse Eier")
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(Renderer.wrap("a\n\nb"), ["a", "", "b"])
        XCTAssertEqual(Renderer.wrap("Donaudampfschifffahrtsgesellschaftskapitän").count, 2)
        XCTAssertTrue(Renderer.render("").pixels.allSatisfy { !$0 })
    }
    /// A period sits on the baseline, so its ink must be in the lower half of a one-line bitmap — not flipped.
    func testOrientationIsPaperOrder() {
        let b = Renderer.render(".")
        let inkRows = (0..<b.height).filter { y in b.pixels[y * b.width..<(y + 1) * b.width].contains(true) }
        XCTAssertFalse(inkRows.isEmpty)
        XCTAssertGreaterThan(Double(inkRows.reduce(0, +)) / Double(inkRows.count), Double(b.height) / 2, "ink rows \(inkRows) in \(b.height)")
    }
    func testMarkup() {
        XCTAssertEqual(Renderer.blocks("# Big\n---\nsmall"), [.line("Big", title: true), .rule, .line("small", title: false)])
        XCTAssertGreaterThan(Renderer.render("# Big").height, Renderer.render("Big").height)
        XCTAssertGreaterThan(Renderer.render("# Big").inkCoverage, Renderer.render("Big").inkCoverage)
        let rule = Renderer.render("---")
        let inkRows = (0..<rule.height).filter { y in rule.pixels[y * rule.width..<(y + 1) * rule.width].contains(true) }
        XCTAssertEqual(inkRows.count, 3, "a rule is three rows")
        XCTAssertEqual(Renderer.blocks("#hashtag"), [.line("#hashtag", title: false)], "only '# ' with a space is a title")
    }
    func testPreviewRoundTrip() {
        let b = Renderer.render("hi")
        XCTAssertEqual(Bitmap(pbm: b.pbm), b)
        XCTAssertNotNil(b.cgImage())
    }
}

/// Invariant 1: nothing leaves the phone except the bytes to the printer. No network API, no packages.
final class InvariantTests: XCTestCase {
    var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func testNoNetworkAndNoPackagesInTheApp() throws {
        let sources = try FileManager.default.contentsOfDirectory(at: repoRoot.appendingPathComponent("App/Sources"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(sources.isEmpty)
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in ["URLSession", "import Network", "NWConnection", "WKWebView", "CloudKit"] {
                XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent) contains \(banned)")
            }
        }
        let project = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertFalse(project.contains("url:"), "project.yml pulls a remote package")
        XCTAssertTrue(project.contains("InklessKit"))
        XCTAssertTrue(project.contains("UIBackgroundModes: [bluetooth-central]"))
    }
}
