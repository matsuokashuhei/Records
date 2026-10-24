import Foundation

/// シェルフに並ぶ1項目(アルバム or プレイリスト)。
struct MediaEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case album
        case playlist
    }

    let kind: Kind
    /// アルバム: 数字列のカタログID / プレイリスト: "pl.xxx"
    let id: String
    var title: String
    /// アルバム: アーティスト名 / プレイリスト: キュレーター名
    var artist: String
    var country: String
    /// Apple MusicのURL
    var url: String
    var artworkURL: String
    var addedAt: Date
}

/// Apple MusicのURL/ID文字列を解析する。
/// 受け付ける形式:
///   1440842296
///   https://music.apple.com/jp/album/brown-sugar/1440842296  (?i=, music://も可)
///   https://music.apple.com/jp/playlist/lo-fi-japan/pl.38eb70f47b834187a21cf4e8e5833f35
enum MediaURLParser {

    struct Parsed {
        let kind: MediaEntry.Kind
        let country: String
        let id: String
    }

    static func parse(_ raw: String) -> Parsed? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 素の数字ID → アルバム扱い
        if let id = Int(text), id > 100_000 {
            return Parsed(kind: .album, country: "jp", id: String(id))
        }

        if text.contains("music.apple.com") {
            if text.hasPrefix("music://") {
                text = text.replacingOccurrences(of: "music://", with: "https://")
            } else if !text.hasPrefix("http") {
                text = "https://" + text
            }
        }

        guard let url = URL(string: text),
              let host = url.host?.lowercased(),
              host.hasSuffix("music.apple.com") else { return nil }

        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }

        var country = "jp"
        var index = 0
        if parts[0].count == 2 {
            country = parts[0].lowercased()
            index = 1
        }
        guard index < parts.count else { return nil }

        switch parts[index] {
        case "album":
            // {slug}/{数字ID} または {数字ID}
            let rest = Array(parts[(index + 1)...])
            guard let number = rest.reversed().first(where: { Int($0).map { $0 > 100_000 } == true }) else {
                return nil
            }
            return Parsed(kind: .album, country: country, id: number)
        case "playlist":
            let rest = Array(parts[(index + 1)...])
            guard let plID = rest.first(where: { $0.hasPrefix("pl.") && $0.count > 3 }) else {
                return nil
            }
            return Parsed(kind: .playlist, country: country, id: plID)
        default:
            return nil
        }
    }
}
