// The pocket printer's protocol (JK01, MXW01-class), byte-for-byte what tools/mxwprint.py sends.
// Verified on the device 2026-10-15. Pure data: no Bluetooth here, the App's adapter does the writes.
import Foundation

public enum MXW01 {
    public static let serviceUUID = "AE30"
    public static let controlUUID = "AE01"   // write-without-response: commands
    public static let notifyUUID = "AE02"    // replies and status
    public static let dataUUID = "AE03"      // write-without-response: raster rows
    public static let notify2UUID = "AE04"   // second notify channel, subscribe too

    public static let width = 384
    public static let bytesPerRow = 48
    public static let chunkSize = 180        // MTU 185 on this printer

    public static let connectInit = Data(hex: "2221B10001000000FF")
    public static let getSerial = Data(hex: "2221A70000000000")
    public static let finalize = Data(hex: "2221AD000100000000")
    public static let statusPoll = Data(hex: "2221A300020000000000")   // only as an answer to B2; A3 moves paper
    /// darkness 1...5
    public static let densityTable: [UInt8] = [0x58, 0x5A, 0x5D, 0x5F, 0x62]

    // Flow control as the MXW01 family signals it, from TiMini-Print's captures (Apache-2.0,
    // github.com/Dejniel/TiMini-Print); not yet seen on JK01 at our pace.
    static let pauseMarkers: Set<Data> = Set(["AA01", "2221AE0101001070FF", "2221AE0001000000"].map { Data(hex: $0) })
    static let resumeMarkers: Set<Data> = Set(["AA00", "2221AE0101000000FF", "2221AE0001001000"].map { Data(hex: $0) })

    /// CRC-8, poly 0x07, init 0, no reflection — over the payload only.
    public static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for b in bytes {
            c ^= b
            for _ in 0..<8 { c = (c & 0x80) != 0 ? (c << 1) ^ 0x07 : c << 1 }
        }
        return c
    }

    /// `22 21 op 00 len16 payload crc FF`
    public static func packet(op: UInt8, payload: [UInt8]) -> Data {
        var d = Data([0x22, 0x21, op, 0x00, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)])
        d.append(contentsOf: payload)
        d.append(crc8(payload)); d.append(0xFF)
        return d
    }

    public static func density(darkness: Int) -> Data {
        packet(op: 0xA2, payload: [densityTable[max(1, min(5, darkness)) - 1]])
    }

    /// A9 start-print: row count, 0x30, dot mode — and a literal `00 00` tail instead of crc+FF.
    public static func startPrint(rows: Int) -> Data {
        Data([0x22, 0x21, 0xA9, 0x00, 0x04, 0x00, UInt8(rows & 0xFF), UInt8(rows >> 8), 0x30, 0x00, 0x00, 0x00])
    }

    /// One row of 384 pixels (true = black) → 48 bytes, LSB first: pixel x lands in bit x % 8 of byte x / 8.
    public static func packRow(_ pixels: [Bool]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytesPerRow)
        for (x, black) in pixels.prefix(width).enumerated() where black { out[x / 8] |= 1 << (x % 8) }
        return out
    }

    /// The raster stream for AE03: rows concatenated, split into chunks by the adapter.
    public static func raster(_ rows: [[UInt8]]) -> Data { Data(rows.joined()) }

    public enum Notification: Equatable {
        case firmware(String)
        case serial(String)
        case startAck(status: UInt8)          // 0 = go; anything else = not ready (paper, lid)
        case done                              // AA — the job printed
        case pause, resume                     // flow control for the raster stream
        case status(state: UInt8, battery: UInt8, temperature: UInt8, errorGroup: UInt8, errorCode: UInt8)
        case wantsStatusPoll                   // B2 — answer with statusPoll after ~0.7 s
        case other(Data)
    }

    public static func parse(_ d: Data) -> Notification {
        if pauseMarkers.contains(d) { return .pause }
        if resumeMarkers.contains(d) { return .resume }
        let b = [UInt8](d)
        guard b.count >= 6, b[0] == 0x22, b[1] == 0x21 else { return .other(d) }
        let len = Int(b[4]) | Int(b[5]) << 8
        let body = Array(b[6..<min(b.count, 6 + len)])
        switch b[2] {
        case 0xB1: return .firmware(String(decoding: body.prefix { $0 != 0 }, as: UTF8.self))
        case 0xA7: return .serial(body.map { String(format: "%02x", $0) }.joined())
        case 0xA9: return .startAck(status: body.first ?? 0xFF)
        case 0xAA: return .done
        case 0xA1 where body.count >= 8: return .status(state: body[0], battery: body[3], temperature: body[4], errorGroup: body[6], errorCode: body[7])
        case 0xB2: return .wantsStatusPoll
        default: return .other(d)
        }
    }
}

public extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []; var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[i..<j], radix: 16) ?? 0); i = j
        }
        self.init(bytes)
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
