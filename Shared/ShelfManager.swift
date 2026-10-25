import Foundation
import os

/// シェルフ(=ウィンドウ)の集合を管理する。
/// シェルフごとにShelfStoreを1つ持ち、登録データ/表示設定は
/// Application Support/Records/Shelves/<shelfID>/ 下に保存する。
/// shelves.json にシェルフIDの一覧を保存し、次回起動時に
/// 全シェルフのウィンドウを開き直す(ウィンドウを閉じてもシェルフは残る)。
@MainActor
final class ShelfManager: ObservableObject {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Shelf")

    static let shared = ShelfManager()

    /// 登録済みシェルフのID(作成順)。shelves.json に永続化される
    @Published private(set) var shelfIDs: [String]
    /// 最後にキーになったシェルフウィンドウのストア。
    /// 設定画面はこれを編集する(「設定はフォーカスしているウィンドウで有効」)
    @Published private(set) var focusedStore: ShelfStore?
    /// シェルフウィンドウを開くアクション。ShelfViewが環境の
    /// openWindow(id:value:)を保持する(⇧⌘Nコマンドなど環境が
    /// 取れない場所から開くための退避。引数はシェルフID)
    var openShelfWindow: ((String) -> Void)?

    private var stores: [String: ShelfStore] = [:]
    /// 現在開いているシェルフウィンドウのID。
    /// 復元時の二重オープン防止と、値を持たないウィンドウが
    /// 重複かどうかの判定に使う
    private(set) var openShelfIDs: Set<String> = []
    /// openWindowを発行済みだがビューのアタッチ(noteWindowOpened)が
    /// まだのID。復元の遅延オープンが重複発行するのを防ぐ
    private var pendingOpenIDs: Set<String> = []

    private init() {
        Self.migrateLegacyFiles()
        shelfIDs = Self.loadShelfIDs()
        saveShelfIDs()
    }

    /// 起動時に開く値を持たないウィンドウが使うシェルフ
    var primaryShelfID: String { shelfIDs[0] }

    /// シェルフID→ストア。同じIDには常に同じインスタンスを返す
    func store(for shelfID: String) -> ShelfStore {
        if let store = stores[shelfID] { return store }
        let store = ShelfStore(shelfID: shelfID)
        stores[shelfID] = store
        return store
    }

    /// シェルフウィンドウがキーになった通知。設定画面の編集対象を切り替える
    func shelfWindowBecameKey(_ store: ShelfStore) {
        if focusedStore !== store {
            Self.logger.notice("focused shelf changed: \(store.shelfID, privacy: .public)")
            focusedStore = store
        }
    }

    /// 新しいシェルフを作ってそのIDを返す(⇧⌘N / コンテキストメニュー)。
    /// ウィンドウを開くのは呼び出し側の役目(ShelfViewは自身のopenWindow
    /// 環境で、RecordsAppのコマンドはopenShelfWindow経由で開く)
    func createShelf() -> String {
        let id = "shelf-" + UUID().uuidString.prefix(8).lowercased()
        shelfIDs.append(id)
        Self.logger.notice("shelf created: \(id, privacy: .public) total=\(self.shelfIDs.count, privacy: .public)")
        saveShelfIDs()
        return id
    }

    /// シェルフウィンドウの開閉を記録する
    func noteWindowOpened(_ shelfID: String) {
        openShelfIDs.insert(shelfID)
        pendingOpenIDs.remove(shelfID)
    }

    func noteWindowClosed(_ shelfID: String) {
        openShelfIDs.remove(shelfID)
    }

    /// まだウィンドウが開かれていないシェルフを開く。
    /// 値を持たないウィンドウ(起動時やドックアイコンでシステムが
    /// 作るもの)から呼ぶ。他のウィンドウがアタッチしてID登録を
    /// 済ませる時間を取るため少し遅延させる
    func openMissingShelfWindows(using openWindow: @escaping (String) -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            for id in self.shelfIDs
            where !self.openShelfIDs.contains(id) && !self.pendingOpenIDs.contains(id) {
                Self.logger.notice("opening missing shelf window: \(id, privacy: .public)")
                self.pendingOpenIDs.insert(id)
                openWindow(id)
            }
        }
    }

    /// シェルフを削除する。登録データと設定ファイルも消す。
    /// 最後の1枚は削除しない(シェルフ0枚の状態は作らない)
    func deleteShelf(_ shelfID: String) {
        guard shelfIDs.count > 1, let i = shelfIDs.firstIndex(of: shelfID) else {
            Self.logger.notice("deleteShelf refused: shelfID=\(shelfID, privacy: .public) count=\(self.shelfIDs.count, privacy: .public)")
            return
        }
        Self.logger.notice("shelf deleted: \(shelfID, privacy: .public)")
        shelfIDs.remove(at: i)
        stores.removeValue(forKey: shelfID)
        if focusedStore?.shelfID == shelfID { focusedStore = nil }
        do {
            try FileManager.default.removeItem(at: ShelfStore.shelfDirectory(shelfID))
        } catch {
            Self.logger.error("deleteShelf: dir removal failed: \(error.localizedDescription, privacy: .public)")
        }
        saveShelfIDs()
    }

    /// 他のシェルフ(閉じているもののファイルを含む)がそのエントリを
    /// 使っているか。アートワークファイルを消してよいかの判定に使う。
    /// (アートワークは全シェルフで共有するため)
    func isEntryUsedElsewhere(_ entryID: String, excluding shelfID: String) -> Bool {
        for id in shelfIDs where id != shelfID {
            let entries = stores[id]?.entries ?? ShelfStore.readFromDisk(shelfID: id)
            if entries.contains(where: { $0.id == entryID }) { return true }
        }
        return false
    }

    /// 現在開いているシェルフの表示中エントリIDの和集合
    /// (閉じたシェルフは含めない)。
    /// PlaybackMonitorの「アクティブエントリが非表示になったら止める」判定用
    var allVisibleEntryIDs: Set<String> {
        Set(
            openShelfIDs
                .compactMap { stores[$0] }
                .flatMap { $0.paddedSlots().compactMap(\.?.id) }
        )
    }

    // MARK: - 永続化・マイグレーション

    private static var registryFile: URL {
        ShelfStore.baseDirectory.appendingPathComponent("shelves.json")
    }

    /// 単一シェルフ時代のレイアウト(ルートのalbums.json/settings.json)が
    /// 残っていれば Shelves/main/ へ移動する。
    /// ルートのalbums.jsonが無ければ何もしない
    private static func migrateLegacyFiles() {
        let fm = FileManager.default
        let legacyAlbums = ShelfStore.baseDirectory.appendingPathComponent("albums.json")
        guard fm.fileExists(atPath: legacyAlbums.path) else { return }
        let dir = ShelfStore.shelfDirectory("main")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("migration: Shelves/main dir creation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        for name in ["albums.json", "settings.json"] {
            let src = ShelfStore.baseDirectory.appendingPathComponent(name)
            let dst = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: src)
                } else {
                    try fm.moveItem(at: src, to: dst)
                }
            } catch {
                logger.error("migration of \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.notice("migrated legacy albums.json/settings.json into Shelves/main/")
    }

    private static func loadShelfIDs() -> [String] {
        do {
            let data = try Data(contentsOf: registryFile)
            let ids = try JSONDecoder().decode([String].self, from: data)
            if !ids.isEmpty { return ids }
            logger.error("shelves.json is empty; recreating with primary shelf")
        } catch {
            logger.notice("shelves.json not readable, creating registry: \(error.localizedDescription, privacy: .public)")
        }
        return ["main"]
    }

    private func saveShelfIDs() {
        do {
            let data = try JSONEncoder().encode(shelfIDs)
            try data.write(to: Self.registryFile, options: .atomic)
        } catch {
            Self.logger.error("shelves.json save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
