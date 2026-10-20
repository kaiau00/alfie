import Testing
@testable import MoeScreen

/// D9.14's second closure: a consent control acts only on an event a person
/// made — and, when it cannot tell, only after the person authenticates.
/// Every event row below is a MEASURED event (2026-09-11, M3, macOS 26.5.2,
/// read from NSApp.currentEvent inside a SwiftUI action in a standalone
/// harness) — not an invented constant.
@Suite("HumanEventRule")
struct HumanEventRuleTests {
    typealias F = HumanEventRule.Facts

    /// A live, unused, in-control person mouse-up — the shape of a real click.
    static func personClick(age: Double = 0.01) -> F {
        F(kind: .mouseUp, sourcePID: 0, age: age, liveAndUnused: true, insideControl: true, activatesControl: false)
    }
    static func personReturn(age: Double = 0.01) -> F {
        F(kind: .keyDown, sourcePID: 0, age: age, liveAndUnused: true, insideControl: false, activatesControl: true)
    }

    @Test func aPersonsClickInTheControlIsAPerson() {
        #expect(HumanEventRule.classify(Self.personClick()) == .person)
    }

    @Test func aPersonsReturnOnTheControlIsAPerson() {
        #expect(HumanEventRule.classify(Self.personReturn()) == .person)
    }

    // AXPress and cua-driver's element click: the action ran with no event.
    @Test func anAccessibilityPressHasNoEventAndIsRefused() {
        #expect(HumanEventRule.classify(nil) == .noEvent)
    }

    // Another process's postToPid(Return) that FIRED a default Button carried
    // the poster's pid. The case that made the guard necessary.
    @Test func aPostedReturnThatFiredTheButtonIsRefused() {
        var f = Self.personReturn(); f.sourcePID = 51715
        #expect(HumanEventRule.classify(f) == .posted(pid: 51715))
    }

    // cua-driver's pixel click: the daemon's pid, and a zero timestamp
    // (age = system uptime).
    @Test func cuaDriversPixelClickIsRefused() {
        let f = F(kind: .mouseUp, sourcePID: 95219, age: 317611.6,
                  liveAndUnused: true, insideControl: true, activatesControl: false)
        #expect(HumanEventRule.classify(f) == .posted(pid: 95219))
    }

    @Test func anyNonZeroSourceIsRefusedWhateverThePid() {
        for pid: Int64 in [1, 88, 501, Int64(Int32.max)] {
            var f = Self.personClick(); f.sourcePID = pid
            #expect(!HumanEventRule.classify(f).isPerson)
        }
    }

    // THE LINGERING-EVENT ATTACK. A person clicks elsewhere in the window
    // (pid 0, live, but NOT inside this control); the agent AXPresses this
    // control within 2 s, and NSApp.currentEvent is still that click. It is
    // refused because the click was not inside this control.
    @Test func aPersonsClickElsewhereRidingAnAXPressIsRefused() {
        var f = Self.personClick(); f.insideControl = false
        #expect(HumanEventRule.classify(f) == .outsideControl)
        #expect(!HumanEventRule.classify(f).isPerson)
    }

    // The same click cannot authorise twice: an AX press moments after a real
    // click sees the same event, now used.
    @Test func aReusedOrLingeringEventIsRefused() {
        var f = Self.personClick(); f.liveAndUnused = false
        #expect(HumanEventRule.classify(f) == .notLive)
    }

    // A key that does not activate this control (wrong key, or the window is
    // not key) is not a person pressing THIS control.
    @Test func aKeyThatDoesNotActivateTheControlIsRefused() {
        var f = Self.personReturn(); f.activatesControl = false
        #expect(HumanEventRule.classify(f) == .notActivating)
    }

    // A mouse-DOWN or key-UP is not what an action fires on.
    @Test func onlyMouseUpAndKeyDownAreInputForAnAction() {
        for kind: F.Kind in [.mouseDown, .keyUp, .other] {
            let f = F(kind: kind, sourcePID: 0, age: 0.01, liveAndUnused: true,
                      insideControl: true, activatesControl: true)
            #expect(HumanEventRule.classify(f) == .notInput(kind.rawValue))
        }
    }

    // Age, pinned at absolute values both sides of each boundary — so
    // widening maxAge (0.5 → anything larger) or the future floor (-0.05 →
    // -0.5) turns a test red.
    @Test func ageIsBoundedBothWays() {
        func personAt(_ age: Double) -> HumanEventRule.Verdict { HumanEventRule.classify(Self.personClick(age: age)) }
        #expect(personAt(0.0) == .person)
        #expect(personAt(0.49) == .person)
        #expect(personAt(HumanEventRule.maxAge) == .person)          // 0.5, inclusive
        #expect(personAt(0.51) == .stale(0.51))                      // kills maxAge → 100
        #expect(personAt(1.0) == .stale(1.0))
        #expect(personAt(100.0) == .stale(100.0))
        #expect(personAt(-0.04) == .person)
        #expect(personAt(HumanEventRule.ageFloor) == .person)        // -0.05, inclusive
        #expect(personAt(-0.06) == .stale(-0.06))
        #expect(personAt(-0.2) == .stale(-0.2))                      // kills floor → -0.5
    }

    @Test func everyRefusalHasAReason() {
        let vs: [HumanEventRule.Verdict] = [.noEvent, .notInput("x"), .posted(pid: 7), .stale(9),
                                            .notLive, .outsideControl, .notActivating]
        for v in vs { #expect(!v.reason.isEmpty && v.reason != "person") }
    }

    // MARK: the accessibility fallback

    @Test func aPersonPressNeedsNoAuthentication() async {
        // The authenticator must not even be consulted for a real press.
        struct Trap: PersonAuthenticator { func confirmPerson(reason: String) async -> Bool {
            Issue.record("authenticator consulted for a person's press"); return false } }
        #expect(await HumanGate.allow(.person, reason: "r", authenticator: Trap()))
    }

    @Test func aNonPersonRunsOnlyWhenThePersonAuthenticates() async {
        #expect(await HumanGate.allow(.noEvent, reason: "r", authenticator: AllowingAuthenticator()))
        #expect(!(await HumanGate.allow(.noEvent, reason: "r", authenticator: DenyingAuthenticator())))
        // an AX press by VoiceOver, then a real Touch ID:
        #expect(await HumanGate.allow(.outsideControl, reason: "r", authenticator: AllowingAuthenticator()))
    }
}
