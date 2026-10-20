import Foundation
import Testing
@testable import MoeBrain

/// `invoke_menu` can fire any menu item by exact path, but nothing enumerated
/// them — cua-driver's window snapshot is scoped to a window, and a menu bar
/// is not in any window. These cover the half that turns a capability with no
/// discoverable input into one the model can actually use.
struct MenuMapTests {

    // MARK: Shortcut rendering

    @Test func aPlainCommandShortcut() {
        // Modifier bits absent entirely: a bare ⌘ is the menu default.
        #expect(MenuMap.shortcut(key: "b", modifiers: 0) == "⌘B")
    }

    /// Ground truth, read off Finder's own menu bar with a raw AX dump. A
    /// first draft invented these constants and had every bit in the wrong
    /// position — "⇧⌘⌫" rendered as "⌫", losing both shift and command — and
    /// no unit test could catch it, because the tests used the same invented
    /// numbers. These are measured.
    ///
    ///     Settings…      ⌘,     mods=0  char=U+002C
    ///     Empty Trash…   ⇧⌘⌫    mods=1  char=U+0008
    ///     Hide Others    ⌥⌘H    mods=2  char=U+0048
    ///     Hide Finder    ⌘H     mods=0  char=U+0048
    ///     New Folder     ⇧⌘N    mods=1  char=U+004E
    @Test func theMeasuredFinderShortcutsRenderExactly() {
        #expect(MenuMap.shortcut(key: ",", modifiers: 0) == "⌘,")
        #expect(MenuMap.shortcut(key: "\u{08}", modifiers: 1) == "⇧⌘⌫")
        #expect(MenuMap.shortcut(key: "H", modifiers: 2) == "⌥⌘H")
        #expect(MenuMap.shortcut(key: "H", modifiers: 0) == "⌘H")
        #expect(MenuMap.shortcut(key: "N", modifiers: 1) == "⇧⌘N")
    }

    @Test func modsZeroMeansPlainCommandNotNoModifiers() {
        // A bare ⌘ is the default for a menu shortcut, so the mask records
        // the departure from it: the command bit is set when ⌘ is ABSENT.
        #expect(MenuMap.shortcut(key: "b", modifiers: 0) == "⌘B")
        #expect(MenuMap.shortcut(key: "b", modifiers: 8) == "B")
    }

    @Test func modifiersRenderInTheOrderTheMenuDrawsThem() {
        // control, option, shift, command — the order a person reads off the
        // menu, so a printed shortcut can be compared to a screenshot by eye.
        #expect(MenuMap.shortcut(key: "s", modifiers: 1) == "⇧⌘S")
        #expect(MenuMap.shortcut(key: "s", modifiers: 2) == "⌥⌘S")
        #expect(MenuMap.shortcut(key: "s", modifiers: 4) == "⌃⌘S")
        #expect(MenuMap.shortcut(key: "s", modifiers: 1 | 2 | 4) == "⌃⌥⇧⌘S")
        #expect(MenuMap.shortcut(key: "s", modifiers: 1 | 8) == "⇧S")
    }

    @Test func rawControlCharactersBecomeGlyphsNotInvisibleBrackets() {
        // AX hands back the raw character: ⌫ arrives as U+0008. Rendering it
        // straight produced "Empty Trash… []" on the first real menu bar this
        // was pointed at — brackets around an invisible control character.
        #expect(MenuMap.shortcut(key: "\u{08}", modifiers: 8) == "⌫")
        #expect(MenuMap.shortcut(key: "\u{7F}", modifiers: 8) == "⌦")
        #expect(MenuMap.shortcut(key: "\u{0D}", modifiers: 0) == "⌘↩")
        #expect(MenuMap.shortcut(key: "\u{1B}", modifiers: 8) == "⎋")
        #expect(MenuMap.shortcut(key: "\u{09}", modifiers: 8) == "⇥")
    }

    @Test func modifiersWithNoKeyAreNotAShortcut() {
        // Returning the modifiers alone printed "Empty Trash [⇧]", which
        // reads as a real shortcut and is not one.
        #expect(MenuMap.shortcut(key: nil, modifiers: 1) == nil)
        #expect(MenuMap.shortcut(key: "\u{10}", modifiers: 1) == nil)
    }

    @Test func cocoaFunctionKeyCharactersAreNotPrinted() {
        // NSUpArrowFunctionKey and friends are private-use scalars, never
        // printable; the virtual keycode is the readable source.
        #expect(MenuMap.shortcut(key: "\u{F700}", modifiers: 8) == nil)
        #expect(MenuMap.shortcut(key: "\u{F700}", modifiers: 8, virtualKey: 0x7E) == "↑")
    }

    @Test func theKeyIsUppercasedTheWayMenusPrintIt() {
        #expect(MenuMap.shortcut(key: "z", modifiers: 0) == "⌘Z")
        #expect(MenuMap.shortcut(key: "/", modifiers: 0) == "⌘/")
    }

    @Test func aFunctionOrArrowKeyComesFromTheVirtualKeycode() {
        // Those items carry no character at all.
        #expect(MenuMap.shortcut(key: nil, modifiers: 0, virtualKey: 0x7A) == "⌘F1")
        #expect(MenuMap.shortcut(key: nil, modifiers: 2, virtualKey: 0x7C) == "⌥⌘→")
        #expect(MenuMap.shortcut(key: nil, modifiers: 8, virtualKey: 0x33) == "⌫")
    }

    @Test func anUnknownVirtualKeyYieldsNoShortcutRatherThanAWrongOne() {
        // A shortcut printed wrong is acted on; one left out sends the agent
        // to the menu path, which works.
        #expect(MenuMap.shortcut(key: nil, modifiers: 0, virtualKey: 0xFFFF) == nil)
    }

    @Test func mostItemsHaveNoShortcutAtAll() {
        #expect(MenuMap.shortcut(key: nil, modifiers: nil) == nil)
        #expect(MenuMap.shortcut(key: "", modifiers: nil) == nil)
        // U+0010 is AX's placeholder for "no character".
        #expect(MenuMap.shortcut(key: "\u{10}", modifiers: 8) == nil)
    }

    // MARK: What is worth listing

    @Test func separatorsAndTheAppleMenuAreNoise() {
        #expect(MenuMap.isNoise(""))
        #expect(MenuMap.isNoise("   "))
        #expect(MenuMap.isNoise("Apple"))
        #expect(!(MenuMap.isNoise("File")))
    }

    // MARK: Rendering round-trips into invoke_menu

    @Test func aRenderedLineCarriesThePathInInvokeMenuOrder() {
        let items = [
            MenuMap.Item(path: ["File", "Export…"], shortcut: "⇧⌘E"),
            MenuMap.Item(path: ["Format", "Font", "Bold"], shortcut: "⌘B"),
        ]
        #expect(MenuMap.render(items) == """
        File > Export…  [⇧⌘E]
        Format > Font > Bold  [⌘B]
        """)
    }

    @Test func aDisabledItemIsMarkedNotDropped() {
        // "Bounce exists but is greyed out" is the answer to "why did nothing
        // happen", and a different answer from "there is no such item".
        let line = MenuMap.render([
            MenuMap.Item(path: ["File", "Bounce"], shortcut: "⌘B", enabled: false)])
        #expect(line == "File > Bounce  [⌘B]  (disabled)")
    }

    @Test func anItemWithNoShortcutRendersWithoutEmptyBrackets() {
        #expect(MenuMap.render([MenuMap.Item(path: ["View", "Zoom In"])])
                == "View > Zoom In")
    }

    // MARK: Ambiguous paths — the case invoke_menu refuses
    //
    // Ground truth, read off this Mac with `mac.sh menus <app>` and counted
    // under LC_ALL=C:
    //
    //     Go > Enclosing Folder                 [⌘↑]  and  [⌥⌘↑]
    //     Window > Move & Resize > Quarters     twice, neither with a shortcut
    //
    // The locale matters and is not pedantry: collating the same listing in a
    // UTF-8 locale reported a third pair, "Empty Trash…" against "Empty
    // Trash", which differ by an ellipsis and are two different items. A
    // measurement taken with the wrong tool is how three wrong facts shipped
    // through this file before.

    @Test func alternatesSharingAPathAreCounted() {
        let go = [
            MenuMap.Item(path: ["Go", "Enclosing Folder"], shortcut: "⌘↑"),
            MenuMap.Item(path: ["Go", "Enclosing Folder"], shortcut: "⌥⌘↑"),
            MenuMap.Item(path: ["Go", "Recents"], shortcut: "⇧⌘F"),
        ]
        #expect(MenuMap.ambiguousPaths(go) == ["Go > Enclosing Folder": 2])
    }

    @Test func anEllipsisMakesItADifferentItem() {
        // Finder's Empty Trash… (⇧⌘⌫) and Empty Trash (⌥⇧⌘⌫) are not a pair.
        let finder = [
            MenuMap.Item(path: ["Finder", "Empty Trash…"], shortcut: "⇧⌘⌫"),
            MenuMap.Item(path: ["Finder", "Empty Trash"], shortcut: "⌥⇧⌘⌫"),
        ]
        #expect(MenuMap.ambiguousPaths(finder).isEmpty)
    }

    @Test func anAmbiguousItemSaysSoAndNamesTheWayOut() {
        let line = MenuMap.render([
            MenuMap.Item(path: ["Go", "Enclosing Folder"], shortcut: "⌘↑"),
            MenuMap.Item(path: ["Go", "Enclosing Folder"], shortcut: "⌥⌘↑"),
        ])
        #expect(line == """
        Go > Enclosing Folder  [⌘↑]  (ambiguous: 2 items share this path — \
        invoke_menu refuses it; send the shortcut instead)
        Go > Enclosing Folder  [⌥⌘↑]  (ambiguous: 2 items share this path — \
        invoke_menu refuses it; send the shortcut instead)
        """)
    }

    @Test func anAmbiguousItemWithNoShortcutSaysThereIsNoWayIn() {
        // Window > Move & Resize > Quarters, twice, neither with a shortcut.
        // Pretending a shortcut would help here is worse than saying nothing.
        let line = MenuMap.render([
            MenuMap.Item(path: ["Window", "Quarters"]),
            MenuMap.Item(path: ["Window", "Quarters"]),
        ])
        #expect(line.contains("has no shortcut — it cannot be reached by path"))
        #expect(!line.contains("send the shortcut instead"))
    }

    @Test func anOrdinaryListingGainsNothing() {
        let items = [
            MenuMap.Item(path: ["File", "Export…"], shortcut: "⇧⌘E"),
            MenuMap.Item(path: ["Format", "Font", "Bold"], shortcut: "⌘B"),
        ]
        #expect(!MenuMap.render(items).contains("ambiguous"))
    }

    @Test func aSearchSubsetStillKnowsAboutTheTwinItFilteredOut() {
        // Two items share a path but only one carries ⌥. A shortcut search
        // returns one of them, and rendering that alone would call a path
        // unambiguous when invoke_menu is about to refuse it.
        let all = [
            MenuMap.Item(path: ["Go", "Enclosing Folder"], shortcut: "⌘↑"),
            MenuMap.Item(path: ["Go", "Enclosing Folder"], shortcut: "⌥⌘↑"),
        ]
        let hits = MenuMap.search(all, for: "⌥⌘↑")
        #expect(hits.count == 1)
        #expect(!MenuMap.render(hits).contains("ambiguous"))
        #expect(MenuMap.render(hits, ambiguityFrom: all).contains("ambiguous: 2"))
    }

    // MARK: Search — a big app's menu bar is hundreds of items

    private var daw: [MenuMap.Item] {
        [
            MenuMap.Item(path: ["File", "New"], shortcut: "⌘N"),
            MenuMap.Item(path: ["File", "Bounce", "Project or Section…"], shortcut: "⌘B"),
            MenuMap.Item(path: ["Mix", "Bounce Regions in Place…"], enabled: false),
            MenuMap.Item(path: ["Track", "New Audio Track"], shortcut: "⌥⌘A"),
        ]
    }

    @Test func searchFindsEverySegmentOfThePathNotJustTheLast() {
        let hits = MenuMap.search(daw, for: "bounce")
        #expect(hits.count == 2)
        #expect(hits[0].path == ["File", "Bounce", "Project or Section…"])
        #expect(hits[1].path == ["Mix", "Bounce Regions in Place…"])
    }

    @Test func searchIsCaseInsensitiveAndTrimmed() {
        #expect(MenuMap.search(daw, for: "  BOUNCE ").count == 2)
    }

    @Test func searchCanFindByShortcut() {
        // "what is ⌘B here" is a real question with a menu answer.
        let hits = MenuMap.search(daw, for: "⌘B")
        #expect(hits.count == 1)
        #expect(hits[0].path.last == "Project or Section…")
    }

    @Test func anEmptyQueryIsNotAFilter() {
        #expect(MenuMap.search(daw, for: "   ").count == daw.count)
    }

    @Test func aQueryThatMatchesNothingReturnsNothing() {
        #expect(MenuMap.search(daw, for: "sidechain").isEmpty)
    }

    // MARK: The Globe key, and unknown bits (found by dumping eight real apps)

    @Test func theGlobeKeyIsBitFourAndRendersAsItsGlyph() {
        // Measured: 113 of 679 shortcut-bearing items across eight apps carry
        // bit 4, and every one is a Globe shortcut. A first draft knew only
        // bits 0-3 and printed "Enter Full Screen" (🌐F) as "⌘F", and
        // "Window > Center" (🌐⌃C) as "⌃C" — different shortcuts that do
        // different things.
        #expect(MenuMap.shortcut(key: "F", modifiers: 24) == "🌐F")
        #expect(MenuMap.shortcut(key: "F", modifiers: 28) == "🌐⌃F")
        #expect(MenuMap.shortcut(key: "C", modifiers: 28) == "🌐⌃C")
        #expect(MenuMap.shortcut(key: nil, modifiers: 28, virtualKey: 0x7B) == "🌐⌃←")
        #expect(MenuMap.shortcut(key: nil, modifiers: 29, virtualKey: 0x7B) == "🌐⌃⇧←")
        #expect(MenuMap.shortcut(key: nil, modifiers: 31, virtualKey: 0x7B) == "🌐⌃⌥⇧←")
    }

    @Test func aModifierBitThisBuildDoesNotKnowYieldsNoShortcut() {
        // The same policy virtualKeyName follows, and the direct falsifier for
        // how the Globe key shipped as ⌘: say nothing rather than something
        // wrong, because a wrong shortcut is acted on.
        #expect(MenuMap.shortcut(key: "F", modifiers: 32) == nil)
        #expect(MenuMap.shortcut(key: "F", modifiers: 1 | 64) == nil)
    }

    // MARK: Control glyphs and keycodes seen in the wild

    @Test func everyControlGlyphInTheTableIsCovered() {
        // Deleting any of these used to pass the whole suite; Music's
        // Controls > Play uses 0x20, Preview's Go menu uses 0x74/0x79.
        let expected: [(UInt32, String)] = [
            (0x08, "⌫"), (0x7F, "⌦"), (0x0D, "↩"), (0x03, "⌤"), (0x09, "⇥"),
            (0x19, "⇤"), (0x1B, "⎋"), (0x20, "Space"),
            (0x1C, "←"), (0x1D, "→"), (0x1E, "↑"), (0x1F, "↓"),
        ]
        for (code, glyph) in expected {
            let key = String(Unicode.Scalar(code)!)
            #expect(MenuMap.shortcut(key: key, modifiers: 8) == glyph,
                    "U+\(String(code, radix: 16)) should render as \(glyph)")
        }
    }

    @Test func everyVirtualKeyInTheTableIsCovered() {
        let expected: [(Int, String)] = [
            (0x7A, "F1"), (0x78, "F2"), (0x63, "F3"), (0x76, "F4"), (0x60, "F5"),
            (0x61, "F6"), (0x62, "F7"), (0x64, "F8"), (0x65, "F9"), (0x6D, "F10"),
            (0x67, "F11"), (0x6F, "F12"),
            (0x7B, "←"), (0x7C, "→"), (0x7E, "↑"), (0x7D, "↓"),
            (0x24, "↩"), (0x4C, "⌤"), (0x30, "⇥"), (0x31, "Space"),
            (0x33, "⌫"), (0x75, "⌦"), (0x35, "⎋"),
            (0x73, "↖"), (0x77, "↘"), (0x74, "⇞"), (0x79, "⇟"),
        ]
        for (code, name) in expected {
            #expect(MenuMap.shortcut(key: nil, modifiers: 8, virtualKey: code) == name,
                    "keycode 0x\(String(code, radix: 16)) should render as \(name)")
        }
    }

    @Test func printabilityBoundaries() {
        #expect(!(MenuMap.isPrintable(Unicode.Scalar(0x1F)!)))   // control
        #expect(MenuMap.isPrintable(Unicode.Scalar(0x21)!))      // "!"
        #expect(!(MenuMap.isPrintable(Unicode.Scalar(0x7F)!)))   // delete
        #expect(!(MenuMap.isPrintable(Unicode.Scalar(0xF700)!))) // Cocoa fn keys
        #expect(!(MenuMap.isPrintable(Unicode.Scalar(0xF8FF)!)))
        #expect(MenuMap.isPrintable(Unicode.Scalar(0xF900)!))
    }
}
