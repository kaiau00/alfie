import Foundation
import Testing
import MoeBrain
@testable import Moe

/// `PermissionGuide.forCode` has an answer for every code Hermes can send,
/// and every grant's guide is the owner and pane Hermes names.
///
/// "Every code Hermes can send" is `FixCode.allCases`, which
/// MoeBrainTests/ToolFixVocabularyTests holds equal to the pinned fork's
/// `CODES` (and `FixCode.grant` to its `GRANTS`), reading the fork itself.
/// This half launches no process, per the MoeAppTests rule.
struct PermissionGuideFixCodeTests {

    @Test func everyGrantIsAGuideOfTheSameOwnerAndPane() throws {
        for fix in FixCode.allCases {
            guard let grant = fix.grant else { continue }
            let (owner, pane) = (grant.owner, grant.pane)
            guard case .grant(let guide) = PermissionGuide.forCode(fix) else {
                Issue.record("\(fix.rawValue) is a grant, and the app has no guide for it"); continue
            }
            #expect(guide.owner == owner, "\(fix.rawValue): Hermes says \(owner), the guide \(guide.owner)")
            #expect(guide.settings.hasSuffix("?" + pane), "\(fix.rawValue): Hermes opens \(pane), the guide \(guide.settings)")
            #expect(guide.codes.contains(fix))
            guard case .grant(let named) = PermissionGuide.forCode(fix, pane: pane) else {
                Issue.record("\(fix.rawValue) with its own pane"); continue
            }
            #expect(named.id == guide.id)
        }
    }

    /// Everything that is not a grant has an explicit answer that is not one.
    @Test func everyOtherCodeHasItsOwnRemedy() {
        for fix in FixCode.allCases where fix.grant == nil {
            if case .grant = PermissionGuide.forCode(fix) { Issue.record("\(fix.rawValue) is not a grant") }
        }
        guard case .noCard = PermissionGuide.forCode(.windowOtherSpace) else {
            Issue.record("another Space gets no card"); return
        }
        // A step only the person can take, met by a job nobody was at: the
        // job's report says so, and no card has anything to press.
        guard case .noCard = PermissionGuide.forCode(.personNeeded) else {
            Issue.record("person_needed gets no card"); return
        }
    }

    /// `tcc_files` names the narrowest switch: Files & Folders on the
    /// Desktop, Full Disk Access in iCloud Drive (fix_reasons_macos
    /// PROTECTED_FOLDERS). A pane on another owner's row never crosses over.
    @Test func thePaneTheToolNamedPicksTheGuide() {
        guard case .grant(let desktop) = PermissionGuide.forCode(.tccFiles, pane: "Privacy_FilesAndFolders"),
              case .grant(let icloud) = PermissionGuide.forCode(.tccFiles, pane: "Privacy_AllFiles"),
              case .grant(let crossed) = PermissionGuide.forCode(.tccDriverAccessibility, pane: "Privacy_Microphone")
        else { Issue.record("tcc_* codes are grants"); return }
        #expect(desktop.id == PermissionGuide.filesAndFolders.id)
        #expect(icloud.id == PermissionGuide.fullDiskAccess.id)
        #expect(crossed.id == PermissionGuide.driverAccessibility.id)
    }

    /// Slice 4 polls these. Every catalogue entry a code points at has one.
    @Test func everyGuideACodePointsAtHasAProbe() {
        for guide in PermissionGuide.catalogue where !guide.codes.isEmpty {
            #expect(guide.probe != .none, "\(guide.id) has no probe")
        }
        #expect(PermissionGuide.driverAccessibility.probe == .driverPermission("accessibility"))
        #expect(PermissionGuide.driverScreenRecording.probe == .driverPermission("screen_recording"))
    }
}
