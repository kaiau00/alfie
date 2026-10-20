import Foundation
import Testing
@testable import Moe

/// **Memory › Open folder is one folder with every file in it** (owner,
/// 2026-09-22): "it doesn't show me my MEMORY or USER.md anymore. They should
/// all sit in one folder." The files cannot move — Hermes, claimstore,
/// profile.py and the ledger's document sync address them by path — so the
/// folder is a view of links.
///
/// Falsifiers: drop the Hermes pair from `entries`, link the sidecars, stop
/// removing a dangling link, or let `ensure` delete a real file, and a test
/// here goes red.
@Suite("Memory › one folder")
struct MemoryFolderTests {

    func scratch() -> (memory: URL, hermes: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-folder-\(UUID().uuidString)", isDirectory: true)
        let memory = root.appendingPathComponent("home with space/memory", isDirectory: true)
        let hermes = root.appendingPathComponent("hermes/memories", isDirectory: true)
        let profile = memory.appendingPathComponent("profile", isDirectory: true)
        let fm = FileManager.default
        try! fm.createDirectory(at: profile.appendingPathComponent("digests"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: profile.appendingPathComponent("stamps"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: hermes, withIntermediateDirectories: true)
        for f in ["identity.md", "people.md", "threads.md", "summary.md", "questions.md",
                  "archive.md", ".meta.json", ".keys.json", "consent.json"] {
            try! "x\n".write(to: profile.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        for f in ["USER.md", "MEMORY.md", "USER.md.lock"] {
            try! "x\n".write(to: hermes.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        return (memory, hermes)
    }

    func listing(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    @Test("Hermes's USER.md and MEMORY.md sit beside the profile; no internals")
    func contents() {
        let (memory, hermes) = scratch()
        let view = MemoryFolder.ensure(memoryDir: memory, hermesDir: hermes)
        #expect(view.lastPathComponent == "What Moe knows")
        #expect(listing(view) == ["MEMORY.md", "USER.md", "identity.md", "people.md",
                                  "questions.md", "summary.md", "threads.md"])
        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: view.appendingPathComponent("USER.md").path)
        #expect(dest == hermes.appendingPathComponent("USER.md").path)
    }

    @Test("writing through a link writes the real file, and survives a rename-over")
    func linksReachTheRealFile() throws {
        let (memory, hermes) = scratch()
        let view = MemoryFolder.ensure(memoryDir: memory, hermesDir: hermes)
        let real = memory.appendingPathComponent("profile/people.md")
        // profile.py writes by temp file and rename — a new inode each time.
        try "- **Dana** — co-founder\n".write(to: real, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: view.appendingPathComponent("people.md"), encoding: .utf8)
                == "- **Dana** — co-founder\n")
        let handle = try FileHandle(forWritingTo: view.appendingPathComponent("USER.md"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("Call me Alex\n".utf8))
        try handle.close()
        #expect(try String(contentsOf: hermes.appendingPathComponent("USER.md"), encoding: .utf8) == "Call me Alex\n")
    }

    @Test("idempotent; a file that appears later is linked; a vanished one is unlinked")
    func refresh() throws {
        let (memory, hermes) = scratch()
        MemoryFolder.ensure(memoryDir: memory, hermesDir: hermes)
        let first = listing(memory.appendingPathComponent(MemoryFolder.name))
        MemoryFolder.ensure(memoryDir: memory, hermesDir: hermes)
        #expect(listing(memory.appendingPathComponent(MemoryFolder.name)) == first)

        try FileManager.default.removeItem(at: memory.appendingPathComponent("profile/questions.md"))
        try "x".write(to: memory.appendingPathComponent("profile/voice.md"), atomically: true, encoding: .utf8)
        let view = MemoryFolder.ensure(memoryDir: memory, hermesDir: hermes)
        #expect(!listing(view).contains("questions.md"))
        #expect(listing(view).contains("voice.md"))
    }

    @Test("a wipe of the folder is rebuilt; a real file in it is the person's and stays")
    func wipeAndRealFile() throws {
        let (memory, hermes) = scratch()
        var view = MemoryFolder.ensure(memoryDir: memory, hermesDir: hermes)
        try FileManager.default.removeItem(at: view)
        view = MemoryFolder.ensure(memoryDir: memory, hermesDir: hermes)
        #expect(listing(view).contains("USER.md"))

        // An editor that saved over the link left a real file with the
        // person's words in it. Never ours to delete.
        let link = view.appendingPathComponent("summary.md")
        try FileManager.default.removeItem(at: link)
        try "mine\n".write(to: link, atomically: true, encoding: .utf8)
        MemoryFolder.ensure(memoryDir: memory, hermesDir: hermes)
        #expect(try String(contentsOf: link, encoding: .utf8) == "mine\n")
    }

    @Test("Open folder opens the view, and the cloud line only when there is a copy")
    func openFolderAndCloud() {
        let (memory, hermes) = scratch()
        #expect(MemoryReader.folderToOpen(memoryDir: memory, hermesDir: hermes).lastPathComponent == MemoryFolder.name)
        #expect(MemoryReader.whereItLives(awayCopy: false) == nil)
        #expect(MemoryReader.whereItLives(awayCopy: true)?.contains("sealed copy") == true)
    }
}

/// **The Memory page's reader**: which lines go in which of the four places.
///
/// Falsifiers: drop the `active` filter, build To check from confidence
/// instead of `profile.py check`, show a To-check line twice, or sort people
/// by file order — each turns a
/// test here red.
@Suite("Memory › the page's sections")
struct MemoryReaderTests {

    /// A claim as `profile.py list --json` writes it, fields optional.
    static func row(_ id: String, _ file: String, _ text: String, date: String = "2026-09-01",
                    conf: String = "high", extra: [String: Any] = [:]) -> [String: Any] {
        var r: [String: Any] = ["id": id, "file": file, "text": text, "source": "gmail",
                                "date": date, "confidence": conf, "key": NSNull()]
        for (k, v) in extra { r[k] = v }
        return r
    }

    static func parse(_ rows: [[String: Any]]) -> [MemoryLine] {
        let data = try! JSONSerialization.data(withJSONObject: rows)
        return MemoryReader.parseClaims(String(decoding: data, as: UTF8.self))
    }
    func row(_ id: String, _ file: String, _ text: String, date: String = "2026-09-01",
             conf: String = "high", extra: [String: Any] = [:]) -> [String: Any] {
        Self.row(id, file, text, date: date, conf: conf, extra: extra)
    }
    func parse(_ rows: [[String: Any]]) -> [MemoryLine] { Self.parse(rows) }

    @Test("today's JSON, without the new fields: active, threads are events, support 0")
    func oldJSONDefaults() {
        let lines = parse([row("a", "people", "**Eli** — friend"), row("b", "threads", "Moved house")])
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.active && $0.support == 0 })
        #expect(lines[0].kind == .stable)
        #expect(lines[1].kind == .event)
        #expect(lines[0].origin == .claim(id: "a"))
        #expect(lines[0].source.hasPrefix("Gmail · "))
    }

    @Test("the new fields are read: kind, active, support, occurred_end")
    func newJSONFields() {
        let lines = parse([row("a", "identity", "Ran Kaporos", extra: [
            "kind": "event", "active": false, "support": 4, "occurred_end": "2025-10-01"])])
        #expect(lines[0].kind == .event)
        #expect(!lines[0].active)
        #expect(lines[0].support == 4)
        #expect(lines[0].date == "2025-10-01")
    }

    @Test("junk before the JSON, or none at all, never crashes")
    func noisyOutput() {
        #expect(MemoryReader.parseClaims("warning: something\n[]").isEmpty)
        #expect(MemoryReader.parseClaims("usage: profile.py").isEmpty)
    }

    @Test("where it came from: the source's name and the day, 'Your words' for the person's own")
    func sourceWords() {
        #expect(MemoryReader.sourceWords("whatsapp", "2026-09-22").hasPrefix("WhatsApp · "))
        #expect(MemoryReader.sourceWords("whatsapp", "2026-09-22").contains("22"))
        #expect(MemoryReader.sourceWords("github", "") == "GitHub")
        #expect(MemoryReader.sourceWords("user", "") == "Your words")
        #expect(MemoryReader.sourceWords("", "") == "Something you let Moe read")
    }

    @Test("people: active, stable people only, most support then most recent")
    func peopleOrder() {
        let lines = parse([
            row("1", "people", "**Old** — a", date: "2026-01-01", extra: ["support": 1]),
            row("2", "people", "**Busy** — b", date: "2026-02-01", extra: ["support": 9]),
            row("3", "people", "**Recent** — c", date: "2026-09-20", extra: ["support": 1]),
            row("4", "people", "**Gone** — d", extra: ["support": 50, "active": false]),
            row("5", "people", "**Once** — met at a wedding", extra: ["support": 50, "kind": "event"]),
            row("6", "identity", "Not a person", extra: ["support": 99]),
        ])
        #expect(MemoryReader.people(lines).map(\.text) == ["**Busy** — b", "**Recent** — c", "**Old** — a"])
        #expect(MemoryReader.plain("**Busy** — b") == "Busy — b")
        #expect(MemoryReader.boldName("**Busy** — b") == "Busy")
        #expect(MemoryReader.boldName("Busy — b") == nil)
    }

    @Test("to check is profile.py's list: a question, then the lines it is about; unsure and new are the line")
    func checks() {
        let lines = parse([
            row("a", "identity", "Hebrew is fluent"),
            row("b", "identity", "Hebrew is basic"),
            row("u", "people", "Unsure one", conf: "low"),
            row("n", "threads", "Started a cloud machine"),
            row("p", "people", "Past one", extra: ["active": false]),
        ])
        let list = MemoryReader.parseChecks("""
        [{"kind":"contradicts","text":"Is \\"Hebrew is fluent\\" or \\"Hebrew is basic\\" true?","ids":["a","b"]},
         {"kind":"question","text":"Still at the studio?","ids":[]},
         {"kind":"unsure","text":"Unsure one","ids":["u"]},
         {"kind":"new","text":"Started a cloud machine","ids":["n"]},
         {"kind":"unsure","text":"Past one","ids":["p"]}]
        """)
        #expect(list?.count == 5)
        let got = MemoryReader.checks(list ?? [], lines: lines)
        #expect(got.map(\.role) == [.question, .check, .check, .question, .check, .check])
        #expect(got.map(\.id) == [got[0].id, "claim:a", "claim:b", "q:Still at the studio?", "claim:u", "claim:n"])
        #expect(MemoryReader.parseChecks("usage: profile.py") == nil)
        #expect(MemoryReader.checks([], lines: lines).isEmpty)
    }

    @Test("the sections: You, People, Right now, To check, From your chats — every active line once")
    func page() {
        var lines = parse([
            row("i", "identity", "Builds sites"),
            row("v", "voice", "Short messages"),
            row("p", "people", "**Eli** — friend"),
            row("q", "people", "**Mo** — maybe a client", conf: "low", extra: ["flag": "unsure"]),
            row("t", "threads", "Launching in October", date: "2026-09-20"),
            row("t2", "threads", "Dentist on Friday", date: "2026-09-21"),
            row("ts", "threads", "Always busy in October", date: "2026-09-01", extra: ["kind": "stable"]),
            row("x", "threads", "Moved in March", extra: ["active": false]),
        ])
        lines.insert(MemoryLine(id: "hermes:you:0", section: .you, text: "Goes by Alex",
                                origin: .hermes(group: "you"), source: "", sureness: nil), at: 0)
        lines.append(MemoryLine(id: "hermes:memory:0", section: .things, text: "Invoices on the 1st",
                                origin: .hermes(group: "memory"), source: "", sureness: nil))
        let page = MemoryReader.sections(lines: lines, checks: [
            MemoryCheck(kind: .question, text: "Still at the studio?", ids: []),
            MemoryCheck(kind: .unsure, text: "Mo — maybe a client", ids: ["q"])])
        #expect(page.map(\.id) == ["you", "people", "now", "check", "chats"])
        #expect(page.map(\.title) == ["You", "People", "Right now", "To check", "From your chats"])
        #expect(page[0].items.map(\.text) == ["Goes by Alex", "Builds sites", "Short messages"])
        #expect(page[1].items.map(\.text) == ["Eli — friend"])
        // A stable threads line is still something going on, not "You".
        #expect(page[2].items.map(\.text) == ["Dentist on Friday", "Launching in October", "Always busy in October"])
        #expect(page[3].items.map(\.id) == ["q:Still at the studio?", "claim:q"])
        // Moe's own notes are From your chats, not You.
        #expect(page[4].items.map(\.text) == ["Invoices on the 1st"])
        let ids = page.flatMap(\.items).map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(Set(ids) == Set(lines.filter(\.active).map(\.id) + ["q:Still at the studio?"]))
        #expect(!ids.contains("claim:x"))
        #expect(MemoryReader.past(lines).map(\.text) == ["Moved in March"])
        // Nothing at all: every section is there, empty — the list still has its rows.
        #expect(MemoryReader.sections(lines: [], checks: []).map(\.items.count) == [0, 0, 0, 0, 0])
    }
}

/// **Design B: a list of sections, one shown at a time** (owner,
/// 2026-09-22). The section chosen is remembered for the session; each has
/// its own heading, line and empty state; and three of them take "+ Add".
///
/// Falsifiers: stop remembering the section, open a section the list does
/// not show, let "+ Add" write to the wrong file or to To check, or drop the
/// bold from an added person — each turns a test here red.
@Suite("Memory › sections and adding")
@MainActor
struct MemorySectionTests {

    @Test("switching sections is remembered; a section that has gone opens You")
    func opening() {
        let all: [MemoryTab] = [.you, .people, .now, .check, .chats]
        #expect(MemoryReader.opening(.people, shown: all) == .people)
        #expect(MemoryReader.opening(.check, shown: all) == .check)
        #expect(MemoryReader.opening(.past, shown: all) == .past)
        // From your chats emptied since it was chosen: the list no longer
        // shows it, so the page opens on You.
        #expect(MemoryReader.opening(.chats, shown: [.you, .people, .now, .check]) == .you)
        let before = MemoryPane.remembered
        defer { MemoryPane.remembered = before }
        MemoryPane.remembered = .now
        #expect(MemoryPane.remembered == .now)
    }

    @Test("each section has its own heading, line and empty state")
    func words() {
        #expect(MemoryTab.you.subtitle == "What Moe believes about you. Click a line to change it.")
        #expect(Set(MemoryTab.allCases.map(\.title)).count == MemoryTab.allCases.count)
        #expect(Set(MemoryTab.allCases.map(\.empty)).count == MemoryTab.allCases.count)
        #expect(MemoryTab.allCases.allSatisfy { !$0.subtitle.isEmpty })
    }

    @Test("+ Add: You → identity, People → people in bold, Right now → threads; nothing elsewhere")
    func add() {
        #expect(MemoryReader.planAdd(.you, draft: "  Lives in Monroe, NJ \n") == .add(file: "identity", text: "Lives in Monroe, NJ"))
        #expect(MemoryReader.planAdd(.now, draft: "Dentist on Friday") == .add(file: "threads", text: "Dentist on Friday"))
        #expect(MemoryReader.planAdd(.people, draft: "Dana - co-founder") == .add(file: "people", text: "**Dana** — co-founder"))
        #expect(MemoryReader.planAdd(.people, draft: "Dana — co-founder") == .add(file: "people", text: "**Dana** — co-founder"))
        #expect(MemoryReader.planAdd(.people, draft: "Dana") == .add(file: "people", text: "**Dana**"))
        #expect(MemoryReader.planAdd(.people, draft: "**Dana** — friend") == .add(file: "people", text: "**Dana** — friend"))
        #expect(MemoryReader.planAdd(.you, draft: "   ") == .nothing)
        for t in [MemoryTab.check, .chats, .past] {
            #expect(MemoryReader.planAdd(t, draft: "Something") == .nothing)
        }
        #expect(MemoryReader.command(.add(file: "identity", text: "Lives in Monroe"), script: "/p.py")
                == ["/p.py", "add", "identity", "Lives in Monroe", "--json"])
        #expect(MemoryReader.memoryCommand(.add(file: "identity", text: "x"), cli: "/cli.py") == nil)
    }
}

/// **Every line is edited in place, and the write is immediate** (owner,
/// 2026-09-22, and "the buttons write immediately", 2026-09-07). What a save
/// does is decided by `plan`; what runs is `command`.
///
/// Falsifiers: make an empty draft do nothing (or correct to ""), send a crawl
/// line to Moe, let "Right" skip profile.py, restore by delete, or drop the
/// bold name from a corrected people line — each turns a test here red. The
/// last test runs the real profile.py, so a change there that breaks the
/// page's calls is red here too.
@Suite("Memory › editing a line")
struct MemoryEditTests {

    let claim = MemoryItem.of(MemoryReaderTests.parse([MemoryReaderTests.row("abc", "identity", "Runs a studio")])[0])
    let person = MemoryItem.of(MemoryReaderTests.parse([MemoryReaderTests.row("p1", "people", "**Dana** — co-founder")])[0])
    let hermes = MemoryItem.of(MemoryLine(id: "hermes:you:0", section: .you, text: "Call me Alex",
                                          origin: .hermes(group: "you"), source: "", sureness: nil))

    @Test("edit → profile.py correct with the new words")
    func editWrites() {
        let edit = MemoryReader.plan(claim, draft: "  Runs a three-person studio \n")
        #expect(edit == .correct(id: "abc", text: "Runs a three-person studio"))
        #expect(MemoryReader.command(edit, script: "/p.py") == ["/p.py", "correct", "abc", "Runs a three-person studio", "--json"])
    }

    @Test("unchanged → nothing is written")
    func unchanged() {
        #expect(MemoryReader.plan(claim, draft: "Runs a studio") == .nothing)
        #expect(MemoryReader.plan(person, draft: "Dana — co-founder") == .nothing)
    }

    @Test("empty → forget, through profile.py delete")
    func emptyForgets() {
        let edit = MemoryReader.plan(claim, draft: "   ")
        #expect(edit == .forget(id: "abc"))
        #expect(MemoryReader.command(edit, script: "/p.py") == ["/p.py", "delete", "abc", "--json"])
    }

    @Test("a people line keeps its bold name, renamed or not")
    func rebold() {
        #expect(MemoryReader.plan(person, draft: "Dana — co-founder and friend")
                == .correct(id: "p1", text: "**Dana** — co-founder and friend"))
        #expect(MemoryReader.plan(person, draft: "Dana Reyes — co-founder")
                == .correct(id: "p1", text: "**Dana Reyes** — co-founder"))
        #expect(MemoryReader.rebold(original: "Runs a studio", edited: "Runs two") == "Runs two")
    }

    @Test("a line of Hermes's memory with a ledger id is written at once through claimstore's cli.py")
    func hermesWritesThroughTheLedger() {
        let rows = MemoryReader.parseHermes("""
        [{"id":"aae63ecb306e","target":"user","text":"Name: Alex Doe","source":"hermes:assistant_tool","key":null},
         {"id":"23894d82d4d2","target":"memory","text":"Answers short","source":"user:memory-page","key":null}]
        """) ?? []
        #expect(rows.map(\.origin) == [.hermes(group: "you"), .hermes(group: "memory")])
        #expect(rows[1].source == "Your words")
        let line = MemoryItem.of(rows[0])
        let edit = MemoryReader.plan(line, draft: "Name: Alex Q. Doe")
        #expect(edit == .correctMemory(id: "aae63ecb306e", text: "Name: Alex Q. Doe"))
        #expect(MemoryReader.memoryCommand(edit, cli: "/cli.py")
                == ["/cli.py", "correct", "aae63ecb306e", "Name: Alex Q. Doe", "--json"])
        #expect(MemoryReader.plan(line, draft: "") == .forgetMemory(id: "aae63ecb306e"))
        #expect(MemoryReader.memoryCommand(.forgetMemory(id: "aae63ecb306e"), cli: "/cli.py")
                == ["/cli.py", "delete", "aae63ecb306e", "--json"])
        #expect(MemoryReader.command(edit, script: "/p.py") == nil)
    }

    @Test("a USER.md line that speaks as Moe ('Prefers I take action') is not shown under You")
    func speaksAsMoe() {
        #expect(MemoryReader.speaksAsMoe("Prefers I take action over explaining"))
        #expect(MemoryReader.speaksAsMoe("Expects me to context-switch"))
        #expect(!MemoryReader.speaksAsMoe("Prefers Moe take action; UI redo in progress"))
        #expect(!MemoryReader.speaksAsMoe("Said \"I quit\" once"))
        let lines = [
            MemoryLine(id: "hermes:a", section: .you, text: "Prefers I take action", origin: .hermes(group: "you"),
                       source: "", sureness: nil, ledgerID: "a"),
            MemoryLine(id: "hermes:b", section: .you, text: "Name: Alex Doe", origin: .hermes(group: "you"),
                       source: "", sureness: nil, ledgerID: "b"),
        ]
        let page = MemoryReader.sections(lines: lines, checks: []).filter { !$0.items.isEmpty }
        #expect(page.map(\.title) == ["You", "From your chats"])
        #expect(page[0].items.map(\.id) == ["hermes:b"])
        #expect(page[1].items.map(\.id) == ["hermes:a"])
    }

    @Test("no ledger id (cli.py cannot run): the change is handed to Moe")
    func hermesAsksMoe() {
        guard case .askMoe(let fix) = MemoryReader.plan(hermes, draft: "Call me Al") else {
            Issue.record("expected askMoe"); return
        }
        #expect(fix.contains("Call me Alex") && fix.contains("Call me Al"))
        guard case .askMoe(let forget) = MemoryReader.plan(hermes, draft: "") else {
            Issue.record("expected askMoe"); return
        }
        #expect(forget.contains("forget"))
        #expect(MemoryReader.command(.askMoe(fix), script: "/p.py") == nil)
    }

    @Test("Right → profile.py confirm; Restore → profile.py restore")
    func rightAndRestore() {
        let line = claim.line!
        #expect(MemoryReader.confirmCommand(line, script: "/p.py") == ["/p.py", "confirm", "abc", "--json"])
        #expect(MemoryReader.restoreCommand(line, script: "/p.py") == ["/p.py", "restore", "abc", "--json"])
        #expect(MemoryReader.confirmCommand(hermes.line!, script: "/p.py") == nil)
    }

    @Test("a question's answer is kept; an empty answer does nothing; the question closes")
    func answers() {
        let q = MemoryItem.question("Still at the studio?")
        #expect(MemoryReader.plan(q, draft: "") == .nothing)
        let edit = MemoryReader.plan(q, draft: "Yes, until March")
        #expect(edit == .answer(question: "Still at the studio?", text: "Yes, until March"))
        #expect(MemoryReader.command(edit, script: "/p.py")
                == ["/p.py", "answer", "Still at the studio?", "Yes, until March", "--file", "identity", "--json"])
        #expect(MemoryReader.command(.dismiss(question: "Still at the studio?"), script: "/p.py")
                == ["/p.py", "dismiss", "Still at the studio?", "--json"])
    }

    /// The real profile.py, in a scratch profile: every call the page makes,
    /// and what the file says afterwards — including that an edit is the
    /// person's own (`user`), which is what keeps the nightly pass off it.
    @Test("against the real profile.py: edit, Right, forget, restore, answer")
    func realProfile() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("moe-home/learn/profile.py").path
        guard FileManager.default.fileExists(atPath: script) else { Issue.record("no profile.py at \(script)"); return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memory-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        # Identity

        - Runs a studio [gmail, 2026-09-01, high]
        - Speaks Spanish [gmail, 2026-09-01, low]
        - Old fact [gmail, 2026-09-01, high]
        """.write(to: dir.appendingPathComponent("identity.md"), atomically: true, encoding: .utf8)
        try """
        # Archive

        ## Threads
        - Moved in March [gmail, 2026-03-10, high]
        """.write(to: dir.appendingPathComponent("archive.md"), atomically: true, encoding: .utf8)
        let env = ["MOE_PROFILE_DIR": dir.path, "MOE_TODAY": "2026-09-22"]
        func list() -> [MemoryLine] {
            let r = ScriptRunner.run("/usr/bin/python3", [script, "list", "--json"], extraEnv: env, timeout: 20)
            return MemoryReader.parseClaims(r.output)
        }
        func item(_ text: String) -> MemoryItem? { list().first { $0.text == text }.map { MemoryItem.of($0) } }
        func identity() throws -> String { try String(contentsOf: dir.appendingPathComponent("identity.md"), encoding: .utf8) }

        // Edit.
        let edit = MemoryReader.plan(try #require(item("Runs a studio")), draft: "Runs a two-person studio")
        #expect(MemoryReader.run(MemoryReader.command(edit, script: script)!, extraEnv: env) == nil)
        #expect(try identity().contains("- Runs a two-person studio [user, 2026-09-22, high]"))
        #expect(try !identity().contains("- Runs a studio ["))

        // Right: the unsure line becomes the person's, and leaves To check.
        func checked() -> [MemoryItem] {
            let r = ScriptRunner.run("/usr/bin/python3", [script, "check", "--json"], extraEnv: env, timeout: 20)
            return MemoryReader.checks(MemoryReader.parseChecks(r.output) ?? [], lines: list())
        }
        #expect(checked().map(\.text) == ["Speaks Spanish"])
        let unsure = try #require(item("Speaks Spanish"))
        #expect(MemoryReader.run(MemoryReader.confirmCommand(unsure.line!, script: script)!, extraEnv: env) == nil)
        #expect(checked().isEmpty)
        #expect(try identity().contains("- Speaks Spanish [user, 2026-09-22, high]"))

        // Forget.
        let forget = MemoryReader.plan(try #require(item("Old fact")), draft: "")
        #expect(MemoryReader.run(MemoryReader.command(forget, script: script)!, extraEnv: env) == nil)
        #expect(!list().contains { $0.text == "Old fact" })

        // Restore.
        let past = try #require(item("Moved in March"))
        #expect(!past.line!.active)
        #expect(MemoryReader.run(MemoryReader.restoreCommand(past.line!, script: script)!, extraEnv: env) == nil)
        #expect(list().first { $0.text == "Moved in March" }?.active == true)

        // Answer — the question closes, and says "you" on the way.
        try "# Questions for you\n\n- Is the user still at the studio?\n- Other?\n"
            .write(to: dir.appendingPathComponent("questions.md"), atomically: true, encoding: .utf8)
        let asked = try #require(checked().first { $0.role == .question })
        #expect(asked.text == "Are you still at the studio?")
        let answer = MemoryReader.plan(asked, draft: "Yes, until March")
        #expect(MemoryReader.run(MemoryReader.command(answer, script: script)!, extraEnv: env) == nil)
        #expect(try identity().contains("- Yes, until March [user, 2026-09-22, high]"))
        #expect(checked().map(\.text) == ["Other?"])
        // Dismiss.
        #expect(MemoryReader.run(MemoryReader.command(.dismiss(question: "Other?"), script: script)!, extraEnv: env) == nil)
        #expect(checked().isEmpty)

        // Add: the person's own line, in the section it was added under.
        for (tab, typed) in [(MemoryTab.you, "Lives in Monroe, NJ"), (.people, "Dana - co-founder"),
                             (.now, "Dentist on Friday")] {
            let add = MemoryReader.planAdd(tab, draft: typed)
            #expect(MemoryReader.run(MemoryReader.command(add, script: script)!, extraEnv: env) == nil)
        }
        #expect(try identity().contains("- Lives in Monroe, NJ [user, 2026-09-22, high]"))
        let sections = MemoryReader.sections(lines: list(), checks: [])
        #expect(sections[0].items.map(\.text).contains("Lives in Monroe, NJ"))
        #expect(sections[1].items.map(\.text) == ["Dana — co-founder"])
        #expect(sections[1].items.first?.line?.source.hasPrefix("Your words") == true)
        #expect(sections[2].items.map(\.text).contains("Dentist on Friday"))
    }
}
