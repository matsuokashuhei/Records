//
//  RecordsTests.swift
//  RecordsTests
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

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
