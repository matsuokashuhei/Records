//
//  SettingsView.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import SwiftUI
import os

/// 設定画面(シェルフ右上のツールバー→「Settings…」から開く)。
/// シェルフの表示設定のみ扱う。アルバム/プレイリストの追加は
/// シェルフへのドロップで行う。
/// 表示設定の編集対象は「最後にキーになったシェルフウィンドウ」
/// (ShelfManager.focusedStore)。言語だけはアプリ全体共通。
struct SettingsView: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    @ObservedObject private var manager = ShelfManager.shared
    /// 言語変更後の再起動促しアラート表示フラグ
    @State private var showRestartAlert = false

    /// 編集対象のシェルフ(最後にフォーカスしたウィンドウ)。
    /// まだ一度もシェルフがキーになっていなければnil
    private var store: ShelfStore? { manager.focusedStore }

    /// 言語選択肢のタグ値。"system"はOS設定に従う(AppleLanguages未設定)
    private static let languageCodes = ["en", "ja", "es", "zh-Hans", "ko", "fr", "de"]

    var body: some View {
        Form {
            Section("Display") {
                Picker("Language", selection: languageSelection) {
                    Text("System").tag("system")
                    ForEach(Self.languageCodes, id: \.self) { code in
                        Text(languageName(for: code)).tag(code)
                    }
                }
                // この3つのピッカーはフォーカス中のシェルフにだけ効く。
                // 監視するのはstore側(manager.focusedStoreの参照変更だけでは
                // settingsの更新で再描画されないため)、サブビューに切り出して
                // @ObservedObjectで購読する
                if let store {
                    ShelfPickers(store: store)
                    ShelfSpacingSliders(store: store)
                }
            }
            // エフェクトプラグインのセクション。登録が1つも無いときは
            // セクションごと出さない(基盤だけの状態で空セクションを
            // 見せない — P0-7)。編集対象はピッカーと同じくフォーカス中シェルフ
            if let store, !ShelfPluginRegistry.all.isEmpty {
                Section("Effects") {
                    ShelfEffectSettings(store: store)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(8)
        .onAppear {
            Self.logger.notice("settings window shown")
        }
        .alert(
            "Restart Required",
            isPresented: $showRestartAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The new language will take effect after you restart Records.")
        }
    }

    // MARK: - 表示設定

    /// 言語名をその言語自体で表示する(autonym。英語なら"English")
    private func languageName(for code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
    }

    /// AppleLanguagesに言語コードを書き込んでアプリの表示言語を切り替える。
    /// "system"選択時はキーごと消してOS設定に戻す。反映は次回起動から。
    private var languageSelection: Binding<String> {
        Binding(
            get: {
                // standard.stringArrayはNSGlobalDomainまでフォールバックして
                // OSの言語一覧を拾ってしまう(未設定なのにピッカーが空選択になる)。
                // アプリ固有ドメインだけ読む
                let domain = UserDefaults.standard.persistentDomain(
                    forName: Bundle.main.bundleIdentifier ?? "com.cacheandbuffer.Records"
                )
                return (domain?["AppleLanguages"] as? [String])?.first ?? "system"
            },
            set: { newValue in
                Self.logger.notice("settings: language picker changed to \(newValue, privacy: .public)")
                if newValue == "system" {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                }
                showRestartAlert = true
            }
        )
    }

}

/// 列数/行数/アートワークサイズのピッカー群。
/// @ObservedObjectでstoreを購読するためにSettingsViewから切り出した
/// (SettingsViewが見るのはmanager.focusedStoreの参照だけなので、
///  settingsが変わっても再描画されずピッカー表示が古いままになる)
private struct ShelfPickers: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    @ObservedObject var store: ShelfStore

    var body: some View {
        Picker("Columns", selection: columnsSelection) {
            ForEach(1...ShelfSettings.maxDimension, id: \.self) { n in
                Text("\(n) columns").tag(n)
            }
        }
        Picker("Rows", selection: rowsSelection) {
            ForEach(1...ShelfSettings.maxDimension, id: \.self) { n in
                Text("\(n) rows").tag(n)
            }
        }
        Picker("Artwork Size", selection: artworkSizeSelection) {
            ForEach(ShelfSettings.ArtworkSize.allCases) { size in
                Text(size.label).tag(size)
            }
        }
        .pickerStyle(.segmented)
    }

    private var columnsSelection: Binding<Int> {
        Binding(
            get: { store.settings.columns },
            set: { newValue in
                Self.logger.notice("settings: columns picker changed to \(newValue, privacy: .public) (shelf=\(self.store.shelfID, privacy: .public))")
                updateDisplaySettings { $0.columns = newValue }
            }
        )
    }

    private var rowsSelection: Binding<Int> {
        Binding(
            get: { store.settings.rows },
            set: { newValue in
                Self.logger.notice("settings: rows picker changed to \(newValue, privacy: .public) (shelf=\(self.store.shelfID, privacy: .public))")
                updateDisplaySettings { $0.rows = newValue }
            }
        )
    }

    private var artworkSizeSelection: Binding<ShelfSettings.ArtworkSize> {
        Binding(
            get: { store.settings.artworkSize },
            set: { newValue in
                Self.logger.notice("settings: artwork size picker changed to \(newValue.rawValue, privacy: .public) (shelf=\(self.store.shelfID, privacy: .public))")
                updateDisplaySettings { $0.artworkSize = newValue }
            }
        )
    }

    /// 列数/行数/サイズの変更をフォーカス中のシェルフの設定に反映する。
    /// 新規インスタンスを組み立てず現行settingsをコピーして変えるので、
    /// 後から増えたフィールド(間隔等)が黙って既定値に戻ることはない。
    /// 縮小で非表示になった再生中プレイリストは停止UIが消えるためここで止める。
    private func updateDisplaySettings(mutate: (inout ShelfSettings) -> Void) {
        var s = store.settings
        mutate(&s)
        store.updateSettings(s)
        PlaybackMonitor.shared.stopIfActiveEntryHidden()
    }
}

/// グリッドの間隔スライダー群。レコード間隔(横)・シェルフ段間隔(縦)を
/// 調整する。外周の余白は独立した設定ではなく間隔から導出される
/// (edgePadding=columnSpacing、topPadding=max(4,rowSpacing)、
///  bottomPadding=rowSpacing。ShelfSettings参照)のでスライダーは
/// この2つだけ。
/// 値の変更はupdateSettingsTransientでメモリ上だけ反映(グリッドと
/// windowResizability(.contentSize)経由でウィンドウへライブ反映)し、
/// settings.jsonへの永続化+変更ログはPluginSliderRowと同じデバウンスで
/// commitSettingsにまとめる
private struct ShelfSpacingSliders: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    /// これだけ値が変わらなければ編集完了とみなす無入力時間
    /// (PluginSliderRowと同じ)
    private static let commitDelay: Duration = .milliseconds(400)

    @ObservedObject var store: ShelfStore
    /// デバウンス中のコミットTask。連続変更のたびに張り替える
    @State private var commitTask: Task<Void, Never>?

    var body: some View {
        Group {
            Slider(value: rowSpacingBinding,
                   in: ShelfSettings.rowSpacingRange, step: 1) {
                Text("Shelf Spacing")
            }
            Slider(value: columnSpacingBinding,
                   in: ShelfSettings.columnSpacingRange, step: 1) {
                Text("Record Spacing")
            }
        }
        // 設定画面が閉じる時点でtransientな変更が残っていたら即確定する
        .onDisappear {
            commitTask?.cancel()
            store.commitSettings()
        }
    }

    private var rowSpacingBinding: Binding<Double> {
        Binding(
            get: { store.settings.rowSpacing },
            set: { newValue in setSpacing { $0.rowSpacing = newValue } }
        )
    }

    private var columnSpacingBinding: Binding<Double> {
        Binding(
            get: { store.settings.columnSpacing },
            set: { newValue in setSpacing { $0.columnSpacing = newValue } }
        )
    }

    /// 現行settingsをコピーして1フィールドだけ変え、メモリ上に反映する
    /// (新規インスタンスだと将来増えるフィールドが既定値に戻るため)
    private func setSpacing(mutate: (inout ShelfSettings) -> Void) {
        var s = store.settings
        mutate(&s)
        store.updateSettingsTransient(s)
        scheduleCommit()
    }

    /// 無入力commitDelay後にsettingsを永続化してコミットログを出す。
    /// 連続変更のたびに延期されるので、ドラッグ中は書き込まれない
    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: Self.commitDelay)
            guard !Task.isCancelled else { return }
            commitTask = nil
            store.commitSettings()
            Self.logger.notice("settings: spacing committed rowSpacing=\(self.store.settings.rowSpacing, privacy: .public) columnSpacing=\(self.store.settings.columnSpacing, privacy: .public) (shelf=\(self.store.shelfID, privacy: .public))")
        }
    }
}

/// エフェクトプラグインの設定セクション(レジストリ列挙)。
/// 各プラグイン = 有効トグル + 有効時はパラメータ調整UI(スライダー等)。
/// ShelfPickersと同じく、store.settingsの更新で再描画されるよう
/// @ObservedObjectでstoreを購読するサブビューに切り出してある。
/// 変更はstore.updateSettingsでフォーカス中シェルフへ即時反映・永続化。
private struct ShelfEffectSettings: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    @ObservedObject var store: ShelfStore

    var body: some View {
        // レジストリ順=適用順=表示順(決定論的)
        ForEach(ShelfPluginRegistry.all, id: \.id) { plugin in
            pluginRow(plugin)
        }
        // スライダーのtransient更新が確定前に残らないよう、
        // セクションが閉じる/畳まれる時点で必ず永続化する
        // (変更が無ければcommitSettingsはno-op)
        .onDisappear { store.commitSettings() }
    }

    @ViewBuilder
    private func pluginRow(_ plugin: any ShelfPlugin) -> some View {
        Toggle(isOn: enabledBinding(plugin)) {
            // displayName/labelはStringなのでText(String)=verbatim initに
            // 解決されてしまう。LocalizedStringKey経由にしてカタログを
            // 引かせる(キーが無ければそのまま表示される)
            Text(LocalizedStringKey(plugin.displayName))
        }
        // 有効時だけパラメータ調整UIを出す(無効なら行ごと畳む)
        if isEnabled(plugin) {
            ForEach(plugin.parameterSpecs, id: \.id) { spec in
                parameterControl(plugin, spec: spec)
            }
        }
    }

    @ViewBuilder
    private func parameterControl(_ plugin: any ShelfPlugin, spec: PluginParameterSpec) -> some View {
        switch spec {
        case .slider(let s):
            PluginSliderRow(store: store, plugin: plugin, spec: s)
        case .options(let o):
            PluginOptionsRow(store: store, plugin: plugin, spec: o)
        }
    }

    // MARK: - 状態アクセス

    private func isEnabled(_ plugin: any ShelfPlugin) -> Bool {
        // 未保存のプラグインはdefaultEnabled(StoreShelfPluginは既定ON、
        // 効果系は既定OFF)。レジストリのresolveと同じ規則にして
        // 表示と実態を一致させる
        store.settings.plugins[plugin.id]?.enabled ?? plugin.defaultEnabled
    }

    private func enabledBinding(_ plugin: any ShelfPlugin) -> Binding<Bool> {
        Binding(
            get: { isEnabled(plugin) },
            set: { on in
                Self.logger.notice("plugin toggled: \(plugin.id, privacy: .public) \(on ? "enabled" : "disabled", privacy: .public) (shelf=\(self.store.shelfID, privacy: .public))")
                updatePluginState(store: store, plugin: plugin) { $0.enabled = on }
            }
        )
    }
}

/// フォーカス中シェルフのプラグイン状態を1件書き換える。
/// persist=trueは即座にsettings.jsonへ保存(トグル等の単発変更)。
/// persist=falseはメモリ上のライブ反映のみ(スライダーの連続変更。
/// 呼び出し側がcommitSettingsで確定する)
@MainActor
private func updatePluginState(
    store: ShelfStore,
    plugin: any ShelfPlugin,
    persist: Bool = true,
    mutate: (inout PluginState) -> Void
) {
    var plugins = store.settings.plugins
    // 未保存のプラグインはdefaultEnabledで状態をシードする
    // (トグルの表示=実態の規則と同じ)
    var state = plugins[plugin.id] ?? PluginState(enabled: plugin.defaultEnabled)
    mutate(&state)
    // specに存在しないキー(廃止パラメータ等)を間引き、settings.jsonに
    // 残った古い値が次の保存で消えるようにする
    let specIDs = Set(plugin.parameterSpecs.map(\.id))
    state.values = state.values.filter { specIDs.contains($0.key) }
    plugins[plugin.id] = state
    // 現行settingsをコピーしてpluginsだけ差し替える。新規インスタンスを
    // 組み立てると後から増えたフィールド(間隔等)が既定値に戻る
    var newSettings = store.settings
    newSettings.plugins = plugins
    if persist {
        store.updateSettings(newSettings)
    } else {
        store.updateSettingsTransient(newSettings)
    }
}

/// プラグインパラメータのスライダー行。
/// 値の変更はupdateSettingsTransientでメモリ上だけ反映(セルへライブ反映)
/// し、settings.jsonへの永続化+変更ログは「入力が止まる」を編集完了と
/// みなすデバウンスでcommitSettingsにまとめる。
/// (macOS 26で onEditingChanged 付きSliderのinitは非推奨。
///  デバウンスならドラッグ/クリックジャンプ/キー操作を問わず
///  編集完了を網羅できる)
private struct PluginSliderRow: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    /// これだけ値が変わらなければ編集完了とみなす無入力時間
    private static let commitDelay: Duration = .milliseconds(400)

    @ObservedObject var store: ShelfStore
    let plugin: any ShelfPlugin
    let spec: PluginParameterSpec.Slider
    /// デバウンス中のコミットTask。連続変更のたびに張り替える
    @State private var commitTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let step = spec.step {
                Slider(value: sliderBinding, in: spec.range, step: step) {
                    Text(LocalizedStringKey(spec.label))
                }
            } else {
                Slider(value: sliderBinding, in: spec.range) {
                    Text(LocalizedStringKey(spec.label))
                }
            }
        }
        // 行が畳まれる(トグルoff)・設定画面が閉じる時点で
        // transientな変更が残っていたら即確定する
        .onDisappear {
            commitTask?.cancel()
            store.commitSettings()
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: {
                store.settings.plugins[plugin.id]?.values[spec.id]?.number ?? spec.defaultValue
            },
            set: { newValue in
                updatePluginState(store: store, plugin: plugin, persist: false) {
                    $0.values[spec.id] = .number(newValue)
                }
                scheduleCommit()
            }
        )
    }

    /// 無入力commitDelay後にsettingsを永続化してコミットログを出す。
    /// 連続変更のたびに延期されるので、ドラッグ中は書き込まれない
    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: Self.commitDelay)
            guard !Task.isCancelled else { return }
            commitTask = nil
            store.commitSettings()
            let value = store.settings.plugins[plugin.id]?.values[spec.id]?.number ?? spec.defaultValue
            Self.logger.notice("plugin param committed: \(plugin.id, privacy: .public)/\(spec.id, privacy: .public)=\(value, privacy: .public) (shelf=\(self.store.shelfID, privacy: .public))")
        }
    }
}

/// プラグインパラメータの選択型行。
/// spec.presentationで出し方を切り替える:
///  - .automatic: 選択肢が少なければセグメント、多ければメニューの標準ピッカー
///  - .grid(columns): 固定列数のグリッドピッカー(照明位置の3x3等)
/// 選択は1回のタップで確定する単発変更なので、即時永続化
/// (persist=true)し、コミットログもここで出す(デバウンス不要)。
private struct PluginOptionsRow: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    /// グリッドピッカーのセル1辺
    private static let gridCellSize: CGFloat = 24

    @ObservedObject var store: ShelfStore
    let plugin: any ShelfPlugin
    let spec: PluginParameterSpec.Options

    var body: some View {
        switch spec.presentation {
        case .automatic:
            automaticPicker
        case .grid(let columns):
            gridPicker(columns: columns)
        }
    }

    /// 現在値(未設定ならspecのデフォルト)
    private var selection: String {
        store.settings.plugins[plugin.id]?.values[spec.id]?.string ?? spec.defaultValue
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { selection },
            set: { commit($0) }
        )
    }

    /// 標準ピッカー。4択程度までなら一目で選べるセグメントにし、
    /// それより多い/ラベルが長い場合はメニューに逃がす
    /// (pickerStyleは型が違うので三項演算子ではなく分岐で返す)
    @ViewBuilder
    private var automaticPicker: some View {
        if spec.choices.count <= 4 {
            optionsPicker.pickerStyle(.segmented)
        } else {
            optionsPicker.pickerStyle(.menu)
        }
    }

    private var optionsPicker: some View {
        Picker(selection: selectionBinding) {
            ForEach(spec.choices, id: \.id) { choice in
                Text(LocalizedStringKey(choice.label)).tag(choice.id)
            }
        } label: {
            Text(LocalizedStringKey(spec.label))
        }
    }

    /// 固定列数のグリッドピッカー。各セルは照明(sun)アイコンで、
    /// 選択中のセルだけ点灯した表示にする(光の位置を視覚的に選ぶUI)
    @ViewBuilder
    private func gridPicker(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(spec.label))
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(Self.gridCellSize), spacing: 4),
                    count: columns
                ),
                spacing: 4
            ) {
                ForEach(spec.choices, id: \.id) { choice in
                    let selected = selection == choice.id
                    Button {
                        commit(choice.id)
                    } label: {
                        gridCell(selected: selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(LocalizedStringKey(choice.label)))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    /// グリッドの1セル。選択中はアクセントの背景+点灯した
    /// sunアイコン、未選択は薄いドット状のsunアイコン
    private func gridCell(selected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(selected
                      ? Color.accentColor.opacity(0.3)
                      : Color.primary.opacity(0.06))
            Image(systemName: "sun.max.fill")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.accentColor
                                          : Color.secondary.opacity(0.35))
        }
        .frame(width: Self.gridCellSize, height: Self.gridCellSize)
        .contentShape(Rectangle())
    }

    /// 選択を確定して即時永続化+コミットログ。
    /// ログ形式はPluginSliderRowの `plugin param committed:` と同じ
    private func commit(_ newValue: String) {
        guard newValue != selection else { return }
        updatePluginState(store: store, plugin: plugin, persist: true) {
            $0.values[spec.id] = .string(newValue)
        }
        Self.logger.notice("plugin param committed: \(plugin.id, privacy: .public)/\(spec.id, privacy: .public)=\(newValue, privacy: .public) (shelf=\(self.store.shelfID, privacy: .public))")
    }
}
