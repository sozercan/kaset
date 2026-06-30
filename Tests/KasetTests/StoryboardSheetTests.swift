import Foundation
import Testing
@testable import Kaset

// MARK: - StoryboardSheetTests

/// Tests for `StoryboardSheet`, the pure parser that turns a YouTube storyboard
/// spec string into fetchable sprite-sheet URLs and per-cell crop rects, plus
/// the `AmbientBackdropStyle` value type.
@Suite(.tags(.parser))
struct StoryboardSheetTests {
    /// A well-formed Level-0 spec (10×10 grid, 100 frames, single `default`
    /// sheet) shaped exactly like a real captured spec. The `sigh` token here is
    /// a harmless placeholder — never a real credential.
    private static let validSpec =
        "https://i.ytimg.com/sb/VIDEOID/storyboard3_L$L/$N.jpg?sqp=TOKEN" +
        "|48#27#100#10#10#0#default#PLACEHOLDERSIGH" +
        "|80#45#100#10#10#5000#M$M#PLACEHOLDERSIGH2"

    // MARK: - Valid parsing

    @Test("Parses a valid spec into an https ytimg sheet URL")
    func parsesValidSpec() throws {
        let sheet = try #require(StoryboardSheet(spec: Self.validSpec))
        #expect(sheet.sheetURLs.count == 1) // 100 frames / (10*10) = 1 sheet
        let url = try #require(sheet.sheetURLs.first)
        #expect(url.scheme == "https")
        #expect(url.host == "i.ytimg.com")
        // Level 0, $N -> default, sigh appended, $M -> 0.
        #expect(url.absoluteString.contains("storyboard3_L0/default.jpg"))
        #expect(url.absoluteString.contains("sigh=PLACEHOLDERSIGH"))
        #expect(!url.absoluteString.contains("$"))
    }

    @Test("sheetCount rounds up when frameCount is not a grid multiple")
    func sheetCountRoundsUp() throws {
        // 5×5 = 25 per sheet, 60 frames -> ceil(60/25) = 3 sheets.
        let spec = "https://i.ytimg.com/sb/V/storyboard3_L$L/$N.jpg?sqp=T" +
            "|48#27#60#5#5#0#default#SIGH"
        let sheet = try #require(StoryboardSheet(spec: spec))
        #expect(sheet.sheetURLs.count == 3)
    }

    // MARK: - cellRects capping

    @Test("cellRects caps the last sheet to the remaining real frames")
    func cellRectsCapsLastSheet() throws {
        // 5×5 grid, 60 frames -> sheet 2 (index 2) holds the final 10 frames.
        let spec = "https://i.ytimg.com/sb/V/storyboard3_L$L/$N.jpg?sqp=T" +
            "|48#27#60#5#5#0#default#SIGH"
        let sheet = try #require(StoryboardSheet(spec: spec))
        // A 250×250 sheet -> 50×50 cells.
        let firstSheet = sheet.cellRects(forSheetAt: 0, pixelWidth: 250, height: 250)
        #expect(firstSheet.count == 25) // full grid
        let lastSheet = sheet.cellRects(forSheetAt: 2, pixelWidth: 250, height: 250)
        #expect(lastSheet.count == 10) // 60 - 2*25 = 10 real frames, not 25 padding cells
    }

    @Test("cellRects returns nothing for a sheet index past the frame count")
    func cellRectsEmptyPastEnd() throws {
        let sheet = try #require(StoryboardSheet(spec: Self.validSpec))
        #expect(sheet.cellRects(forSheetAt: 99, pixelWidth: 100, height: 100).isEmpty)
    }

    @Test("cellRects returns nothing when the sheet is too small to subdivide")
    func cellRectsEmptyForTinySheet() throws {
        let sheet = try #require(StoryboardSheet(spec: Self.validSpec))
        // 10×10 grid but only a 4×4 sheet -> integer cell size 0.
        #expect(sheet.cellRects(forSheetAt: 0, pixelWidth: 4, height: 4).isEmpty)
    }

    // MARK: - Security: host / scheme allowlist (tested via init? building URLs)

    @Test(
        "Rejects specs whose base resolves to a non-ytimg or non-https host",
        arguments: [
            "http://127.0.0.1/sb/V/storyboard3_L$L/$N.jpg?sqp=T|48#27#100#10#10#0#default#SIGH",
            "https://evil.example.com/sb/V/$N.jpg?sqp=T|48#27#100#10#10#0#default#SIGH",
            "http://i.ytimg.com/sb/V/$N.jpg?sqp=T|48#27#100#10#10#0#default#SIGH",
            "https://notytimg.com/sb/V/$N.jpg?sqp=T|48#27#100#10#10#0#default#SIGH",
        ]
    )
    func rejectsDisallowedHosts(spec: String) {
        // No allowed URL can be built, so init? fails closed.
        #expect(StoryboardSheet(spec: spec) == nil)
    }

    @Test("Accepts subdomains of ytimg.com over https")
    func acceptsYtimgSubdomain() throws {
        let spec = "https://i9.ytimg.com/sb/V/storyboard3_L$L/$N.jpg?sqp=T" +
            "|48#27#100#10#10#0#default#SIGH"
        let sheet = try #require(StoryboardSheet(spec: spec))
        #expect(sheet.sheetURLs.first?.host == "i9.ytimg.com")
    }

    // MARK: - Security: bounds / malformed input

    @Test("Rejects an empty or single-field spec")
    func rejectsMalformedSpec() {
        #expect(StoryboardSheet(spec: "") == nil)
        #expect(StoryboardSheet(spec: "https://i.ytimg.com/sb/V/$N.jpg") == nil)
    }

    @Test("Rejects a level whose field list is too short")
    func rejectsShortFieldList() {
        let spec = "https://i.ytimg.com/sb/V/$N.jpg?sqp=T|48#27#100#10#10"
        #expect(StoryboardSheet(spec: spec) == nil)
    }

    @Test(
        "Rejects non-positive or non-numeric grid/frame values",
        arguments: [
            "https://i.ytimg.com/sb/V/$N.jpg?sqp=T|48#27#100#0#10#0#default#S", // cols 0
            "https://i.ytimg.com/sb/V/$N.jpg?sqp=T|48#27#100#10#0#0#default#S", // rows 0
            "https://i.ytimg.com/sb/V/$N.jpg?sqp=T|48#27#0#10#10#0#default#S", // frames 0
            "https://i.ytimg.com/sb/V/$N.jpg?sqp=T|48#27#abc#10#10#0#default#S", // frames NaN
        ]
    )
    func rejectsInvalidDimensions(spec: String) {
        #expect(StoryboardSheet(spec: spec) == nil)
    }

    @Test(
        "Rejects oversized grid/frame values that exceed the security caps",
        arguments: [
            "https://i.ytimg.com/sb/V/$N.jpg?sqp=T|48#27#100#9999#10#0#default#S", // cols > cap
            "https://i.ytimg.com/sb/V/$N.jpg?sqp=T|48#27#100#10#9999#0#default#S", // rows > cap
            "https://i.ytimg.com/sb/V/$N.jpg?sqp=T|48#27#999999999#10#10#0#default#S", // frames > cap
        ]
    )
    func rejectsOversizedDimensions(spec: String) {
        #expect(StoryboardSheet(spec: spec) == nil)
    }
}

// MARK: - AmbientBackdropStyleTests

@Suite(.tags(.model))
struct AmbientBackdropStyleTests {
    @Test("userSelectableCases excludes off and lists the three visible styles")
    func userSelectableExcludesOff() {
        let cases = AmbientBackdropStyle.userSelectableCases
        #expect(!cases.contains(.off))
        #expect(cases == [.soft, .glow, .live])
    }

    @Test("rawValues round-trip for every case")
    func rawValuesRoundTrip() {
        for style in AmbientBackdropStyle.allCases {
            #expect(AmbientBackdropStyle(rawValue: style.rawValue) == style)
        }
    }

    @Test("Identifiers are unique")
    func identifiersUnique() {
        let ids = AmbientBackdropStyle.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Display and debug names are non-empty for every case")
    func namesNonEmpty() {
        for style in AmbientBackdropStyle.allCases {
            #expect(!style.displayName.isEmpty)
            #expect(!style.debugLabel.isEmpty)
        }
    }
}
