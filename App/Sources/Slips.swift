// The last ten slips, newest first, in UserDefaults — nothing else stores anything.
import Foundation

struct Slip: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date: Date
}

enum Slips {
    static let key = "slips"
    static func load() -> [Slip] {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode([Slip].self, from: d) else { return [] }
        return s
    }
    static func remove(_ slip: Slip) -> [Slip] {
        let s = load().filter { $0.id != slip.id }
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: key)
        return s
    }
    static func remember(_ text: String) -> [Slip] {
        var s = load().filter { $0.text != text }
        s.insert(Slip(text: text, date: Date()), at: 0)
        s = Array(s.prefix(10))
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: key)
        return s
    }
}
