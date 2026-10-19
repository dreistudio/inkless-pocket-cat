// Text → the 384-px 1-bit bitmap that prints. The preview shows this very bitmap (invariant 3).
import Foundation
import CoreGraphics
import CoreText

public struct Style: Equatable {
    public var fontName: String
    public var size: CGFloat
    public var margin: Int
    public var lineGap: Int
    public init(fontName: String = "Helvetica-Bold", size: CGFloat = 30, margin: Int = 8, lineGap: Int = 4) {
        self.fontName = fontName; self.size = size; self.margin = margin; self.lineGap = lineGap
    }
    /// The Inkless house style for the pocket printer (sampler verdict may move it: one constant).
    public static let house = Style()
}

public struct Bitmap: Equatable {
    public let width: Int
    public let height: Int
    /// true = black, row-major, width * height entries
    public let pixels: [Bool]
    public init(width: Int, height: Int, pixels: [Bool]) { self.width = width; self.height = height; self.pixels = pixels }
    public var packedRows: [[UInt8]] { (0..<height).map { MXW01.packRow(Array(pixels[$0 * width..<($0 + 1) * width])) } }
    public var inkCoverage: Double { pixels.isEmpty ? 0 : Double(pixels.filter { $0 }.count) / Double(pixels.count) }
    public func cgImage() -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * height)
        for (i, p) in pixels.enumerated() where p { bytes[i] = 0 }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    /// A portable bitmap (P1) — the fixture format.
    public var pbm: String {
        var s = "P1\n\(width) \(height)\n"
        for y in 0..<height { s += pixels[y * width..<(y + 1) * width].map { $0 ? "1" : "0" }.joined() + "\n" }
        return s
    }
    public init?(pbm: String) {
        let lines = pbm.split(separator: "\n").filter { !$0.hasPrefix("#") }
        guard lines.count >= 2, lines[0] == "P1" else { return nil }
        let dims = lines[1].split(separator: " ").compactMap { Int($0) }
        guard dims.count == 2 else { return nil }
        let px = lines.dropFirst(2).joined().compactMap { c -> Bool? in c == "1" ? true : c == "0" ? false : nil }
        guard px.count == dims[0] * dims[1] else { return nil }
        self.init(width: dims[0], height: dims[1], pixels: px)
    }
}

public enum Renderer {
    /// What a slip is made of. Two marks are understood, the rest is text: a line starting with `# ` prints
    /// big (title size), a line that is only `---` prints a rule. Everything else is plain text, wrapped.
    public enum Block: Equatable { case line(String, title: Bool), rule }
    public static let titleScale: CGFloat = 1.35

    public static func blocks(_ text: String, style: Style = .house) -> [Block] {
        var out: [Block] = []
        for paragraph in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "___" { out.append(.rule); continue }
            if trimmed.hasPrefix("# ") {
                let big = Style(fontName: style.fontName, size: (style.size * titleScale).rounded(), margin: style.margin, lineGap: style.lineGap)
                for l in wrap(String(trimmed.dropFirst(2)), style: big) { out.append(.line(l, title: true)) }
                continue
            }
            for l in wrap(paragraph, style: style) { out.append(.line(l, title: false)) }
        }
        while out.count > 1, out.last == .line("", title: false) { out.removeLast() }
        return out
    }

    /// Word-wrap by measured pixel width; paragraphs on "\n"; a word longer than the line is broken by characters.
    public static func wrap(_ text: String, style: Style = .house) -> [String] {
        let font = CTFontCreateWithName(style.fontName as CFString, style.size, nil)
        let maxWidth = CGFloat(MXW01.width - 2 * style.margin)
        func width(_ s: String) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        var lines: [String] = []
        for paragraph in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            var current = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                let trial = current.isEmpty ? word : current + " " + word
                if width(trial) <= maxWidth { current = trial; continue }
                if !current.isEmpty { lines.append(current); current = "" }
                var piece = ""
                for ch in word {   // a single word wider than the paper
                    if width(piece + String(ch)) <= maxWidth { piece.append(ch) } else { lines.append(piece); piece = String(ch) }
                }
                current = piece
            }
            lines.append(current)
        }
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    public static func render(_ text: String, style: Style = .house) -> Bitmap {
        let items = blocks(text, style: style)
        let width = MXW01.width
        let titleSize = (style.size * titleScale).rounded()
        func blockHeight(_ b: Block) -> Int {
            switch b {
            case .line(_, let title): return Int(title ? titleSize : style.size) + style.lineGap
            case .rule: return style.lineGap * 2 + 3
            }
        }
        let height = max(8, style.margin * 2 + items.map(blockHeight).reduce(0, +))
        var bytes = [UInt8](repeating: 255, count: width * height)
        let font = CTFontCreateWithName(style.fontName as CFString, style.size, nil)
        let bigFont = CTFontCreateWithName(style.fontName as CFString, titleSize, nil)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(false)
            ctx.setFillColor(gray: 0, alpha: 1)
            var top = style.margin                                        // from the top, like the paper
            for b in items {
                switch b {
                case .line(let line, let title):
                    let f = title ? bigFont : font
                    if !line.isEmpty {
                        let attr = NSAttributedString(string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: f, kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1)])
                        ctx.textPosition = CGPoint(x: CGFloat(style.margin), y: CGFloat(height - top) - CTFontGetAscent(f))
                        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
                    }
                case .rule:
                    let y = height - top - style.lineGap - 3
                    ctx.fill(CGRect(x: style.margin, y: y, width: width - 2 * style.margin, height: 3))
                }
                top += blockHeight(b)
            }
        }
        return Bitmap(width: width, height: height, pixels: bytes.map { $0 < 128 })
    }
}
