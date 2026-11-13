//
//  UpdateController.swift
//  Sleeves
//
//  Sparkle 2 の更新確認を束ねる薄いラッパー。
//  UIはSparkle標準(SPUStandardUpdaterControllerのデフォルト
//  UserDriver)に任せ、ここではログ用のデリゲートだけ差し込む。
//  自動チェックは startingUpdater:true と Info.plistの
//  SUEnableAutomaticChecks が担う(アプリ側にスケジュールコードは無い)。
//

import Sparkle
import os

final class UpdateController {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Sleeves", category: "Update")

    /// メニュー項目などから `updater.checkForUpdates()` を呼ぶための入口
    var updater: SPUUpdater { controller.updater }

    private let controller: SPUStandardUpdaterController
    private let loggingDelegate = UpdaterLoggingDelegate()

    init() {
        Self.logger.notice("starting Sparkle updater (automatic checks enabled)")
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: loggingDelegate,
            userDriverDelegate: nil
        )
    }
}

/// Sparkleイベントのロギング専用デリゲート。
/// エージェントはUIを目視できないため、チェック結果は必ずログに残す。
private final class UpdaterLoggingDelegate: NSObject, SPUUpdaterDelegate {

    private let logger = Logger(subsystem: "com.cacheandbuffer.Sleeves", category: "Update")

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        logger.notice("update found: version=\(item.displayVersionString, privacy: .public) build=\(item.versionString, privacy: .public) url=\(item.fileURL?.absoluteString ?? "none", privacy: .public)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        logger.notice("no update found (up to date)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        logger.error("updater aborted: \(error.localizedDescription, privacy: .public)")
    }
}
