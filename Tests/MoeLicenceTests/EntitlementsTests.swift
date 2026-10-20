import CryptoKit
import Foundation
import Testing
@testable import MoeLicence

/// Generated here, in memory, thrown away when the test ends. There is no
/// real keypair in this repo and there must never be one — docs/RELEASING.md
/// §1.5 describes where the real private key lives, and describing it is as
/// close as this project gets to it.
private let us = Curve25519.Signing.PrivateKey()
private var ourPublicKey: Data { us.publicKey.rawRepresentation }

private let dayZero = Date(timeIntervalSince1970: 1_780_000_000)        // 2026-05-29
private func days(_ n: Double) -> Date { dayZero.addingTimeInterval(n * 86_400) }

private func bought(tier: Tier = .pro, windowEnds: Date? = days(365)) -> Entitlements {
    Entitlements(licence: Licence(id: "0102030405060708", tier: tier, buyer: "ada@example.com",
                                  issued: dayZero, updateWindowEnds: windowEnds, macs: 2))
}

// MARK: - Nothing shipping today is gated

struct NothingIsGatedTests {

    /// The load-bearing test of this whole change. Moe sells nothing today:
    /// the mechanism is built, the switch is not thrown, and throwing it is a
    /// product decision the founder has not made. If this test fails, someone
    /// has started charging for something — which may well be right, but it
    /// has to be on purpose, and this is where it gets noticed.
    @Test func everyFeatureIsStillFree() {
        for feature in Feature.allCases {
            #expect(!feature.isSold, "\(feature.rawValue) is being sold")
        }
    }

    @Test func anUnlicensedInstallGetsEverythingItGotBefore() {
        let free = Entitlements.unlicensed
        #expect(!free.isLicensed)
        for feature in Feature.allCases {
            #expect(free.includes(feature), "\(feature.rawValue) was taken away from a free install")
        }
    }

    @Test func aLicensedInstallGetsEverythingToo() {
        for feature in Feature.allCases {
            #expect(bought().includes(feature))
        }
    }
}

// MARK: - The update window takes nothing away

struct UpdateWindowTests {

    @Test func anExpiredWindowLeavesTheInstallLicensedForWhatItBought() {
        let pro = bought(windowEnds: days(365))
        let longAfter = days(4_000)          // eight years past the window

        #expect(pro.updateWindow(asOf: longAfter) == .closed(since: days(365)))
        // Everything that matters is unchanged. This is the shape CLOUD.md
        // §14.5 sells — one payment, a bounded window of updates, perpetual
        // use of what you already have.
        #expect(pro.isLicensed)
        #expect(pro.tier == .pro)
        for feature in Feature.allCases {
            #expect(pro.includes(feature), "\(feature.rawValue) vanished when the window closed")
        }
    }

    @Test func theWindowOnlyDecidesWhichBuildsAreIncluded() {
        let pro = bought(windowEnds: days(365))
        #expect(pro.updatesCover(buildReleasedOn: days(1)))
        #expect(pro.updatesCover(buildReleasedOn: days(365)))
        #expect(!pro.updatesCover(buildReleasedOn: days(366)))
        // And a build from before the purchase is covered, which is the
        // version the customer is most likely to actually be running.
        #expect(pro.updatesCover(buildReleasedOn: days(-100)))
    }

    @Test func aLifetimeKeyCoversEveryBuildThereWillEverBe() {
        let forever = bought(tier: .lifetime, windowEnds: nil)
        #expect(forever.updateWindow(asOf: days(50_000)) == .neverEnds)
        #expect(forever.updatesCover(buildReleasedOn: days(50_000)))
    }

    @Test func anOpenWindowSaysWhenItCloses() {
        let pro = bought(windowEnds: days(365))
        #expect(pro.updateWindow(asOf: days(10)) == .open(until: days(365)))
        #expect(pro.updateWindow(asOf: days(365)) == .open(until: days(365)))
        #expect(pro.updateWindow(asOf: days(10))?.isOpen == true)
    }

    @Test func anUnlicensedInstallHasNoWindowRatherThanAClosedOne() {
        #expect(Entitlements.unlicensed.updateWindow(asOf: days(1)) == nil)
    }
}

// MARK: - Clocks

struct ClockTests {

    /// A Mac whose clock has rolled back — a dead PRAM battery, a bad NTP
    /// answer, someone testing something, a restore from an old image — must
    /// not lose anything. Note what is asserted first: `isLicensed` does not
    /// take a date at all, so no clock in any state can touch it.
    @Test func aClockSetBackwardsRevokesNobody() {
        let pro = bought(windowEnds: days(365))

        for now in [days(-1), days(-10_000), Date(timeIntervalSince1970: 0), Date.distantPast] {
            #expect(pro.isLicensed)
            #expect(pro.tier == .pro)
            for feature in Feature.allCases { #expect(pro.includes(feature)) }
            // The window reads as open, never as "not started yet" and never
            // as closed. A clock behind the issue date is a broken clock, and
            // the customer does not pay for that.
            #expect(pro.updateWindow(asOf: now)?.isOpen == true, "\(now)")
        }
    }

    @Test func aClockRunFarForwardStillLeavesEverythingWorking() {
        // The other direction: a clock in 2099 closes the window, and closing
        // the window is the *only* thing it is allowed to do.
        let pro = bought(windowEnds: days(365))
        let absurd = Date(timeIntervalSince1970: 4_100_000_000)

        #expect(pro.updateWindow(asOf: absurd)?.isOpen == false)
        #expect(pro.isLicensed)
        for feature in Feature.allCases { #expect(pro.includes(feature)) }
    }

    @Test func aKeyWithNoIssueDateAtAllStillReadsAsOpen() throws {
        // A payload minted without the issued field — an older or newer
        // minting tool, or a field we drop one day. The clock check has
        // nothing to compare against and must not invent a reason to say no.
        var signed = Data([1])
        signed.append(contentsOf: [2, 1, 1])                            // tier: pro
        signed.append(contentsOf: [5, 2, 0x00, 0x64])                   // window ends day 100

        var blob = signed
        blob.append(try us.signature(for: signed))
        let sum = CRC16.of(blob)
        blob.append(UInt8(sum >> 8))
        blob.append(UInt8(sum & 0xFF))

        let licence = try LicenceKey.read("MOE01-" + Base32.encode(blob), publicKey: ourPublicKey).get()
        #expect(licence.issued == .distantPast)
        #expect(Entitlements(licence: licence).updateWindow(asOf: LicenceKey.epoch)?.isOpen == true)
    }
}

// MARK: - The file on disk

struct LicenceFileTests {

    private func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-licence-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aKeyThatWasSavedIsReadBackOnTheNextLaunch() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("licence.txt")

        let key = LicenceKey.mint(Licence(id: "aabbccddeeff0011", tier: .lifetime, buyer: "ada@example.com",
                                          issued: dayZero, updateWindowEnds: nil, macs: 2),
                                  signedBy: us)
        try LicenceFile.write(key, to: file)

        let entitlements = LicenceFile.read(at: file, publicKey: ourPublicKey)
        #expect(entitlements.isLicensed)
        #expect(entitlements.tier == .lifetime)

        // It names the customer, so it is theirs to read and nobody else's.
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    @Test func noLicenceFileAtAllLeavesTheAppFullyWorking() {
        let missing = scratch().appendingPathComponent("nothing-here.txt")
        let entitlements = LicenceFile.read(at: missing, publicKey: ourPublicKey)

        #expect(entitlements == .unlicensed)
        for feature in Feature.allCases { #expect(entitlements.includes(feature)) }
    }

    @Test func anUnreadableOrCorruptLicenceFileLeavesTheAppFullyWorking() throws {
        let dir = scratch()
        defer { try? FileManager.default.chmod(dir, 0o700); try? FileManager.default.removeItem(at: dir) }

        // Six ways for the file to be wrong, including the two that would
        // throw if anything here threw: no read permission, and a directory
        // sitting where the file should be.
        let empty = dir.appendingPathComponent("empty.txt")
        try Data().write(to: empty)

        let rubbish = dir.appendingPathComponent("rubbish.txt")
        try Data([0xFF, 0xFE, 0x00, 0x01, 0x80, 0x90]).write(to: rubbish)   // not even UTF-8

        let prose = dir.appendingPathComponent("prose.txt")
        try Data("I lost my licence key, sorry".utf8).write(to: prose)

        let truncated = dir.appendingPathComponent("truncated.txt")
        let key = LicenceKey.mint(Licence(id: "01", tier: .pro, buyer: "a@b.c", issued: dayZero,
                                          updateWindowEnds: days(10), macs: 1), signedBy: us)
        try Data(key.dropLast(20).utf8).write(to: truncated)

        let unreadable = dir.appendingPathComponent("unreadable.txt")
        try Data(key.utf8).write(to: unreadable)
        try FileManager.default.chmod(unreadable, 0o000)

        let aDirectory = dir.appendingPathComponent("licence.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: aDirectory, withIntermediateDirectories: true)

        for url in [empty, rubbish, prose, truncated, unreadable, aDirectory] {
            let entitlements = LicenceFile.read(at: url, publicKey: ourPublicKey)
            #expect(entitlements == .unlicensed, "\(url.lastPathComponent)")
            for feature in Feature.allCases {
                #expect(entitlements.includes(feature), "\(url.lastPathComponent): \(feature.rawValue)")
            }
        }

        try? FileManager.default.chmod(unreadable, 0o600)
    }

    @Test func aBuildWithNoPublicKeyStillOpensAndStillWorks() throws {
        // build.sh omits the public key from a plain checkout, exactly as it
        // omits Sparkle's. Nothing can verify, and nothing may break.
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("licence.txt")
        try LicenceFile.write(LicenceKey.mint(Licence(id: "01", tier: .pro, buyer: "a@b.c",
                                                      issued: dayZero, updateWindowEnds: days(10), macs: 1),
                                              signedBy: us), to: file)

        let entitlements = LicenceFile.read(at: file, publicKey: Data())
        #expect(entitlements == .unlicensed)
        for feature in Feature.allCases { #expect(entitlements.includes(feature)) }
    }

    @Test func removingAKeyThatIsNotThereIsNotAProblem() {
        LicenceFile.remove(at: scratch().appendingPathComponent("nothing-here.txt"))
    }
}

private extension FileManager {
    func chmod(_ url: URL, _ mode: Int) throws {
        try setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
