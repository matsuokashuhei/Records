import Foundation
import os

/// シェルフの表示設定(登録枚数とアートワークサイズ)。
/// ShelfStore.baseDirectory 下の settings.json に JSON で保存する。
/// 読み書きはすべて nonisolated。
struct ShelfSettings: Codable, Equatable {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Settings")

    /// 登録スロット数の選択肢。グリッドの列×行と対応する。
    enum Capacity: Int, Codable, CaseIterable, Identifiable {
        case six = 6
        case twelve = 12
        case twenty = 20

        var id: Int { rawValue }

        var columns: Int {
            switch self {
            case .six: return 3
            case .twelve: return 4
            case .twenty: return 5
            }
        }

        var rows: Int {
            switch self {
            case .six: return 2
            case .twelve: return 3
            case .twenty: return 4
            }
        }

        var label: String { "\(rawValue)枚 (\(columns)×\(rows))" }
    }

    /// アートワーク(セル)1辺のサイズ。S=現在のセル相当、M=Sの1.5倍、L=Mの1.5倍。
    enum ArtworkSize: String, Codable, CaseIterable, Identifiable {
        case s
        case m
        case l

        var id: String { rawValue }

        var points: CGFloat {
            switch self {
            case .s: return 96
            case .m: return 144
            case .l: return 216
            }
        }

        var label: String { rawValue.uppercased() }
    }

    var capacity: Capacity
    var artworkSize: ArtworkSize

    /// 設定ファイルが無い/読めない場合の既定値(20枚・Sサイズ)。
    static let `default` = ShelfSettings(capacity: .twenty, artworkSize: .s)

    static var fileURL: URL {
        ShelfStore.baseDirectory.appendingPathComponent("settings.json")
    }

    static func loadFromDisk() -> ShelfSettings {
        do {
            let data = try Data(contentsOf: fileURL)
            let settings = try JSONDecoder().decode(ShelfSettings.self, from: data)
            logger.notice("settings.json loaded: capacity=\(settings.capacity.rawValue, privacy: .public) artworkSize=\(settings.artworkSize.rawValue, privacy: .public)")
            return settings
        } catch {
            // 初回起動やファイル破損時は既定値。読めなくても既定値で動作継続する。
            logger.notice("settings.json not readable, using defaults: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    static func saveToDisk(_ settings: ShelfSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: fileURL, options: .atomic)
            logger.notice("settings.json saved: capacity=\(settings.capacity.rawValue, privacy: .public) artworkSize=\(settings.artworkSize.rawValue, privacy: .public)")
        } catch {
            logger.error("settings.json save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
