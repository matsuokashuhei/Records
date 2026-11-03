//
//  RecordsTests.swift
//  RecordsTests
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import Foundation
import Testing

/// MediaURLParser(Shared/MediaEntry.swift)の純ロジックテスト。
/// MediaEntry.swift はこのターゲットに直接コンパイルされるため @testable 不要。
struct MediaURLParserTests {

    // MARK: - 素のID

    @Test func bareNumericIDIsAlbum() {
        let parsed = MediaURLParser.parse("1440842296")
        #expect(parsed?.kind == .album)
        #expect(parsed?.id == "1440842296")
        #expect(parsed?.country == "jp")
    }

    @Test func tinyNumberIsRejected() {
        // 100_000以下はカタログIDとして扱わない
        #expect(MediaURLParser.parse("42") == nil)
    }

    @Test func nonNumericTextIsRejected() {
        #expect(MediaURLParser.parse("hello") == nil)
        #expect(MediaURLParser.parse("") == nil)
    }

    // MARK: - アルバムURL

    @Test func albumURLWithSlug() {
        let parsed = MediaURLParser.parse("https://music.apple.com/jp/album/brown-sugar/1440842296")
        #expect(parsed?.kind == .album)
        #expect(parsed?.id == "1440842296")
        #expect(parsed?.country == "jp")
    }

    @Test func albumURLWithoutSlug() {
        let parsed = MediaURLParser.parse("https://music.apple.com/jp/album/1440842296")
        #expect(parsed?.kind == .album)
        #expect(parsed?.id == "1440842296")
    }

    @Test func albumURLCountryCode() {
        let parsed = MediaURLParser.parse("https://music.apple.com/us/album/thriller/269572838")
        #expect(parsed?.kind == .album)
        #expect(parsed?.id == "269572838")
        #expect(parsed?.country == "us")
    }

    @Test func albumURLWithoutCountry() {
        // 国コードなしパスはデフォルト jp
        let parsed = MediaURLParser.parse("https://music.apple.com/album/brown-sugar/1440842296")
        #expect(parsed?.kind == .album)
        #expect(parsed?.id == "1440842296")
        #expect(parsed?.country == "jp")
    }

    @Test func albumURLWithTrackParam() {
        // ?i= はクエリなのでパス解析の対象外。アルバムIDが取れる
        let parsed = MediaURLParser.parse("https://music.apple.com/jp/album/brown-sugar/1440842296?i=1440842467")
        #expect(parsed?.kind == .album)
        #expect(parsed?.id == "1440842296")
    }

    // MARK: - プレイリストURL

    @Test func playlistURL() {
        let parsed = MediaURLParser.parse("https://music.apple.com/jp/playlist/lo-fi-japan/pl.38eb70f47b834187a21cf4e8e5833f35")
        #expect(parsed?.kind == .playlist)
        #expect(parsed?.id == "pl.38eb70f47b834187a21cf4e8e5833f35")
        #expect(parsed?.country == "jp")
    }

    @Test func playlistURLWithoutSlug() {
        let parsed = MediaURLParser.parse("https://music.apple.com/us/playlist/pl.38eb70f47b834187a21cf4e8e5833f35")
        #expect(parsed?.kind == .playlist)
        #expect(parsed?.id == "pl.38eb70f47b834187a21cf4e8e5833f35")
        #expect(parsed?.country == "us")
    }

    // MARK: - music:// とスキーム省略

    @Test func musicSchemeDeepLink() {
        let parsed = MediaURLParser.parse("music://music.apple.com/jp/album/brown-sugar/1440842296")
        #expect(parsed?.kind == .album)
        #expect(parsed?.id == "1440842296")
    }

    @Test func schemelessAppleMusicURL() {
        let parsed = MediaURLParser.parse("music.apple.com/jp/album/brown-sugar/1440842296")
        #expect(parsed?.kind == .album)
        #expect(parsed?.id == "1440842296")
    }

    // MARK: - 拒否ケース

    @Test func nonAppleHostIsRejected() {
        #expect(MediaURLParser.parse("https://example.com/jp/album/x/1440842296") == nil)
    }

    @Test func unknownPathIsRejected() {
        #expect(MediaURLParser.parse("https://music.apple.com/jp/artist/dangelo/123456789") == nil)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let parsed = MediaURLParser.parse("  https://music.apple.com/jp/album/brown-sugar/1440842296\n")
        #expect(parsed?.kind == .album)
        #expect(parsed?.id == "1440842296")
    }
}

/// ShelfPlacement(Shared/MediaEntry.swift)の自由配置ロジックテスト。
/// スロットは0始まりの行優先index。各エントリのslotIndexは一意
private func placementEntry(_ id: String, slot: Int) -> MediaEntry {
    MediaEntry(
        kind: .album, id: id, title: id, artist: "", country: "jp",
        url: "", artworkURL: "", addedAt: .distantPast, slotIndex: slot
    )
}

private func slotsByID(_ entries: [MediaEntry]) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.slotIndex) })
}

struct ShelfPlacementTests {

    // MARK: - 正規化(読み込み時マイグレーション)

    @Test func normalizeAssignsFirstFreeSlotsInFileOrder() {
        // 旧フォーマット(全員-1): ファイル順のまま先頭から0,1,2
        let entries = [placementEntry("a", slot: -1),
                       placementEntry("b", slot: -1),
                       placementEntry("c", slot: -1)]
        let result = ShelfPlacement.normalized(entries)
        #expect(result.changed)
        #expect(result.entries.map(\.slotIndex) == [0, 1, 2])
        #expect(result.entries.map(\.id) == ["a", "b", "c"])
    }

    @Test func normalizeResolvesCollisionKeepingFileOrder() {
        // bとcが同じスロット: 先に現れたbが2を保持、cは空きの0へ。
        // 結果はslotIndex昇順に並ぶ
        let entries = [placementEntry("a", slot: 1),
                       placementEntry("b", slot: 2),
                       placementEntry("c", slot: 2)]
        let result = ShelfPlacement.normalized(entries)
        #expect(result.changed)
        #expect(slotsByID(result.entries) == ["a": 1, "b": 2, "c": 0])
        #expect(result.entries.map(\.id) == ["c", "a", "b"])
    }

    @Test func normalizeUnchangedWhenAlreadyValid() {
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 3)]
        let result = ShelfPlacement.normalized(entries)
        #expect(!result.changed)
        #expect(result.entries == entries)
    }

    // MARK: - paddedSlots

    @Test func paddedSlotsHonorsSlotIndexWithGaps() {
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 3)]
        let slots = ShelfPlacement.paddedSlots(entries, capacity: 5)
        #expect(slots.map(\.?.id) == ["a", nil, nil, "b", nil])
    }

    @Test func paddedSlotsHidesOutOfRangeEntries() {
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("hidden", slot: 9)]
        let slots = ShelfPlacement.paddedSlots(entries, capacity: 4)
        #expect(slots.compactMap(\.?.id) == ["a"])
    }

    // MARK: - 密配置の並び替え(旧moveと同じ結果)

    @Test func denseReorderBeforeMatchesOldMove() {
        // cをaの直前へ → 順序[c,a,b]、スロットは0,1,2のまま
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 1),
                       placementEntry("c", slot: 2)]
        let result = ShelfPlacement.reorder(
            entries: entries, draggedID: "c", targetSlotIndex: 0, after: false
        )
        #expect(result?.map(\.id) == ["c", "a", "b"])
        #expect(result?.map(\.slotIndex) == [0, 1, 2])
    }

    @Test func denseReorderAfterMatchesOldMove() {
        // aをcの直後へ → 順序[b,c,a]
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 1),
                       placementEntry("c", slot: 2)]
        let result = ShelfPlacement.reorder(
            entries: entries, draggedID: "a", targetSlotIndex: 2, after: true
        )
        #expect(result?.map(\.id) == ["b", "c", "a"])
        #expect(result?.map(\.slotIndex) == [0, 1, 2])
    }

    // MARK: - ギャップありのスライド

    @Test func gapReorderSlidesOnlyBetweenRecords() {
        // a@0, b@3, c@5。cの直前へaをドロップ → 占有位置[0,3,5]は不変で
        // 順序が[b,a,c]に: b@0, a@3, c@5(間のレコードだけ1スロットずつスライド)
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 3),
                       placementEntry("c", slot: 5)]
        let result = ShelfPlacement.reorder(
            entries: entries, draggedID: "a", targetSlotIndex: 5, after: false
        )
        #expect(slotsByID(result ?? []) == ["a": 3, "b": 0, "c": 5])
    }

    @Test func gapReorderKeepsRecordsBeyondGap() {
        // a@0, b@3, c@5, d@8。bをaの直前へ → [b,a,c,d] →
        // b@0, a@3, c@5, d@8(c,dは動かない)
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 3),
                       placementEntry("c", slot: 5),
                       placementEntry("d", slot: 8)]
        let result = ShelfPlacement.reorder(
            entries: entries, draggedID: "b", targetSlotIndex: 0, after: false
        )
        #expect(slotsByID(result ?? []) == ["a": 3, "b": 0, "c": 5, "d": 8])
    }

    @Test func hiddenOutOfRangeEntryStaysPutDuringReorder() {
        // capacity外の非表示エントリは最大側=順序末尾なので動かない
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 1),
                       placementEntry("h", slot: 9)]
        let result = ShelfPlacement.reorder(
            entries: entries, draggedID: "a", targetSlotIndex: 1, after: true
        )
        #expect(slotsByID(result ?? []) == ["a": 1, "b": 0, "h": 9])
    }

    // MARK: - 空きスロットへの配置(他は動かない)

    @Test func placeToEmptySlotMovesOnlyDragged() {
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 3)]
        let result = ShelfPlacement.place(
            entries: entries, draggedID: "a", atSlot: 7, capacity: 10
        )
        #expect(slotsByID(result ?? []) == ["a": 7, "b": 3])
    }

    @Test func placeToSameSlotIsNoOp() {
        let entries = [placementEntry("a", slot: 0)]
        #expect(ShelfPlacement.place(entries: entries, draggedID: "a", atSlot: 0, capacity: 10) == nil)
    }

    @Test func placeToOccupiedSlotIsRejected() {
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 3)]
        #expect(ShelfPlacement.place(entries: entries, draggedID: "a", atSlot: 3, capacity: 10) == nil)
    }

    // MARK: - no-op(自分自身・隣接の同順位置)

    @Test func dropOnSelfIsNoOp() {
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 1)]
        #expect(ShelfPlacement.reorder(
            entries: entries, draggedID: "a", targetSlotIndex: 0, after: false
        ) == nil)
        #expect(ShelfPlacement.reorder(
            entries: entries, draggedID: "a", targetSlotIndex: 0, after: true
        ) == nil)
    }

    @Test func dropOnAdjacentSameOrderIsNoOp() {
        // a@0をb@1の直前へ = 元と同じ順序
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 1)]
        #expect(ShelfPlacement.reorder(
            entries: entries, draggedID: "a", targetSlotIndex: 1, after: false
        ) == nil)
        // b@1をa@0の直後へ = 元と同じ順序
        #expect(ShelfPlacement.reorder(
            entries: entries, draggedID: "b", targetSlotIndex: 0, after: true
        ) == nil)
    }

    // MARK: - 挿入シフト

    @Test func insertAtEmptySlotPlacesExactly() {
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 2)]
        let result = ShelfPlacement.insertionShift(
            entries: entries, inserting: placementEntry("x", slot: -1), at: 1, capacity: 10
        )
        #expect(slotsByID(result ?? []) == ["a": 0, "b": 2, "x": 1])
    }

    @Test func insertShiftRightPushesOccupiedRun() {
        // a@0,b@1,c@2。s=1へ挿入 → ラン[0,2]の右に空きがあるので
        // b,cが+1へ、xは1へ
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 1),
                       placementEntry("c", slot: 2)]
        let result = ShelfPlacement.insertionShift(
            entries: entries, inserting: placementEntry("x", slot: -1), at: 1, capacity: 10
        )
        #expect(slotsByID(result ?? []) == ["a": 0, "b": 2, "c": 3, "x": 1])
    }

    @Test func insertShiftLeftFallbackWhenRightBlocked() {
        // capacity4でa@1,b@2,c@3(ランの右が詰まり、左の0が空き)。
        // s=2へ挿入 → 占有[1..2]が-1へ、xは2へ、右のcは動かない
        let entries = [placementEntry("a", slot: 1),
                       placementEntry("b", slot: 2),
                       placementEntry("c", slot: 3)]
        let result = ShelfPlacement.insertionShift(
            entries: entries, inserting: placementEntry("x", slot: -1), at: 2, capacity: 4
        )
        #expect(slotsByID(result ?? []) == ["a": 0, "b": 1, "c": 3, "x": 2])
    }

    @Test func insertShiftKeepsHiddenEntries() {
        // 非表示(slotIndex>=capacity)のエントリはシフト対象外
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("h", slot: 9)]
        let result = ShelfPlacement.insertionShift(
            entries: entries, inserting: placementEntry("x", slot: -1), at: 0, capacity: 4
        )
        #expect(slotsByID(result ?? []) == ["a": 1, "h": 9, "x": 0])
    }

    @Test func insertShiftReturnsNilWhenFull() {
        // capacity2で両方占有 → 左右どちらにもずらせない
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 1)]
        #expect(ShelfPlacement.insertionShift(
            entries: entries, inserting: placementEntry("x", slot: -1), at: 0, capacity: 2
        ) == nil)
    }

    // MARK: - 最近傍空きスロット

    @Test func nearestEmptySlotResolvesByDistance() {
        // 2列グリッド(cell=10, gap=0): 0,1が上段、2,3が下段。
        // a@0のみ占有。スロット0の中心へのドロップ → 最近傍の空きは1
        let entries = [placementEntry("a", slot: 0)]
        let found = ShelfPlacement.nearestEmptySlot(
            entries: entries, capacity: 4, columns: 2,
            cell: 10, columnSpacing: 0, rowSpacing: 0,
            at: CGPoint(x: 5, y: 5)
        )
        #expect(found == 1)
        // スロット3の中心(15,15)付近 → 3
        let far = ShelfPlacement.nearestEmptySlot(
            entries: entries, capacity: 4, columns: 2,
            cell: 10, columnSpacing: 0, rowSpacing: 0,
            at: CGPoint(x: 14, y: 16)
        )
        #expect(far == 3)
    }

    @Test func nearestEmptySlotReturnsNilWhenFull() {
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 1)]
        #expect(ShelfPlacement.nearestEmptySlot(
            entries: entries, capacity: 2, columns: 2,
            cell: 10, columnSpacing: 0, rowSpacing: 0,
            at: CGPoint(x: 5, y: 5)
        ) == nil)
    }

    // MARK: - firstEmptySlot(満杯判定)

    @Test func firstEmptySlotFindsHeadGap() {
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("b", slot: 3)]
        #expect(ShelfPlacement.firstEmptySlot(entries: entries, capacity: 4) == 1)
    }

    @Test func firstEmptySlotIgnoresHiddenEntries() {
        // slotIndex >= capacity の非表示エントリは占有として数えない:
        // count >= capacity でも空きがあれば満杯ではない
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("h", slot: 9)]
        #expect(ShelfPlacement.firstEmptySlot(entries: entries, capacity: 4) == 1)
    }

    @Test func firstEmptySlotBoundaryCapacities() {
        let full = [placementEntry("a", slot: 0),
                    placementEntry("b", slot: 1)]
        #expect(ShelfPlacement.firstEmptySlot(entries: full, capacity: 2) == nil)
        // capacity=0 は常に空きなし、capacity=1 の空シェルフはスロット0
        #expect(ShelfPlacement.firstEmptySlot(entries: [], capacity: 0) == nil)
        #expect(ShelfPlacement.firstEmptySlot(entries: [], capacity: 1) == 0)
        #expect(ShelfPlacement.firstEmptySlot(entries: [placementEntry("a", slot: 0)], capacity: 1) == nil)
    }

    // MARK: - capacity=0/1 の境界

    @Test func capacityZeroRejectsEverything() {
        let entries = [placementEntry("a", slot: 0)]
        #expect(ShelfPlacement.paddedSlots(entries, capacity: 0).isEmpty)
        #expect(ShelfPlacement.firstEmptySlot(entries: [], capacity: 0) == nil)
        #expect(ShelfPlacement.nearestEmptySlot(
            entries: [], capacity: 0, columns: 1,
            cell: 10, columnSpacing: 0, rowSpacing: 0, at: CGPoint(x: 0, y: 0)) == nil)
        #expect(ShelfPlacement.insertionShift(
            entries: [], inserting: placementEntry("x", slot: -1), at: 0, capacity: 0) == nil)
        #expect(ShelfPlacement.place(
            entries: entries, draggedID: "a", atSlot: 0, capacity: 0) == nil)
    }

    @Test func capacityOneInsertShift() {
        // capacity=1: 空なら置ける、占有ならどちらにもずらせない
        #expect(ShelfPlacement.insertionShift(
            entries: [], inserting: placementEntry("x", slot: -1), at: 0, capacity: 1
        )?.map(\.slotIndex) == [0])
        let occupied = [placementEntry("a", slot: 0)]
        #expect(ShelfPlacement.insertionShift(
            entries: occupied, inserting: placementEntry("x", slot: -1), at: 0, capacity: 1
        ) == nil)
    }

    // MARK: - normalized の混在ケース

    @Test func normalizeMixedUnsetAndValidSlots() {
        // -1と有効slotIndexの混在: 有効なbは2を保持、aは空きの先頭0へ
        let entries = [placementEntry("a", slot: -1),
                       placementEntry("b", slot: 2)]
        let result = ShelfPlacement.normalized(entries)
        #expect(result.changed)
        #expect(slotsByID(result.entries) == ["a": 0, "b": 2])
    }

    @Test func normalizePreservesOutOfCapacitySlots() {
        // slotIndex >= capacity(グリッド縮小で非表示になったエントリ)は
        // 正規化で再配置しない。値が有効かつ一意ならそのまま保持する
        let entries = [placementEntry("a", slot: 0),
                       placementEntry("h", slot: 9)]
        let result = ShelfPlacement.normalized(entries)
        #expect(!result.changed)
        #expect(slotsByID(result.entries) == ["a": 0, "h": 9])
    }

    // MARK: - slotIndex=-1混入(防御)

    @Test func reorderWithUnplacedEntryKeepsItsSlot() {
        // 未配置(-1)が混ざっていても占有位置集合は[-1,0,1]のまま動く:
        // a@0をb@1の直後へ → 順序[x,b,a] → x@-1,b@0,a@1
        let entries = [placementEntry("x", slot: -1),
                       placementEntry("a", slot: 0),
                       placementEntry("b", slot: 1)]
        let result = ShelfPlacement.reorder(
            entries: entries, draggedID: "a", targetSlotIndex: 1, after: true
        )
        #expect(slotsByID(result ?? []) == ["x": -1, "a": 1, "b": 0])
    }

    @Test func placeWithUnplacedEntry() {
        let entries = [placementEntry("x", slot: -1)]
        let result = ShelfPlacement.place(
            entries: entries, draggedID: "x", atSlot: 2, capacity: 5
        )
        #expect(slotsByID(result ?? []) == ["x": 2])
    }
}
