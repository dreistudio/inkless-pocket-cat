// A print as the adapter sends it: the control packets around the raster, and the flow rules it must obey.
import Foundation

public struct PrintJob: Equatable {
    public let rows: [[UInt8]]
    public let darkness: Int
    public init(bitmap: Bitmap, darkness: Int) { rows = bitmap.packedRows; self.darkness = darkness }
    public init(rows: [[UInt8]], darkness: Int) { self.rows = rows; self.darkness = darkness }

    /// Sent on AE01 before the raster: density, then start. Wait for `.startAck(0)` before any row.
    public var preamble: [Data] { [MXW01.density(darkness: darkness), MXW01.startPrint(rows: rows.count)] }
    /// Sent on AE03 in order, pausing on `.pause` until `.resume`, ~30 ms apart.
    public var chunks: [Data] {
        let all = MXW01.raster(rows)
        return stride(from: 0, to: all.count, by: MXW01.chunkSize).map { all.subdata(in: $0..<min($0 + MXW01.chunkSize, all.count)) }
    }
    /// Sent on AE01 after the last chunk; then wait for `.done`, keep the link 2 s more.
    public var trailer: Data { MXW01.finalize }

    /// The control packets and the raster as one hex transcript — what the fixture pins.
    public var transcript: String {
        (preamble.map(\.hexString) + [MXW01.raster(rows).hexString, trailer.hexString]).joined(separator: "\n")
    }
}

/// What the adapter should do after one notification arrives mid-job. Pure, so it is testable.
public enum FlowRule {
    public enum Phase: Equatable { case waitingForStart, streaming, waitingForDone, finished, notReady(UInt8) }
    public static func next(_ phase: Phase, on n: MXW01.Notification, paused: inout Bool) -> Phase {
        switch (phase, n) {
        case (.waitingForStart, .startAck(let s)): return s == 0 ? .streaming : .notReady(s)
        case (_, .pause): paused = true; return phase
        case (_, .resume): paused = false; return phase
        case (.waitingForDone, .done): return .finished
        default: return phase
        }
    }
}
