import Foundation
import Testing
@testable import MoeMeeting

// Phase B, first half: names from the calendar invite onto the voices
// diarization found. Every branch of the rule is here, and none of it
// touches EventKit — the attendee list is a plain struct, so "Calendar
// access was refused" is tested as exactly what it is: an empty list.

struct AttendeeNameTests {

    @Test func theDisplayNameIsUsedWhenThereIsOne() {
        let a = MeetingAttendee(name: "Dan Levy", email: "dl@acme.com")
        #expect(a.displayName == "Dan Levy")
    }

    @Test func aNameOnlyInTheAddressIsReadOutOfIt() {
        #expect(MeetingAttendee(email: "dan.levy@acme.com").displayName == "Dan Levy")
        #expect(MeetingAttendee(email: "dan@acme.com").displayName == "Dan")
        #expect(MeetingAttendee(email: "dan_levy@acme.com").displayName == "Dan Levy")
        #expect(MeetingAttendee(email: "dan-levy@acme.com").displayName == "Dan Levy")
        #expect(MeetingAttendee(email: "mailto:dan.levy@acme.com").displayName == "Dan Levy")
        #expect(MeetingAttendee(email: "dan.levy+cal@acme.com").displayName == "Dan Levy")
        #expect(MeetingAttendee(email: "dan2@acme.com").displayName == "Dan")
    }

    @Test func aNameFieldHoldingAnAddressGoesThroughTheAddressRules() {
        // Calendars routinely put the address in the name field.
        #expect(MeetingAttendee(name: "dan.levy@acme.com").displayName == "Dan Levy")
        #expect(MeetingAttendee(name: "noreply@acme.com", email: "noreply@acme.com").displayName == nil)
    }

    @Test func capitalsAlreadyInTheAddressAreKept() {
        #expect(MeetingAttendee(email: "McDonald@acme.com").displayName == "McDonald")
    }

    @Test func initialsAreDroppedRatherThanSpelledOut() {
        #expect(MeetingAttendee(email: "j.smith@acme.com").displayName == "Smith")
        #expect(MeetingAttendee(email: "a.b@acme.com").displayName == nil)
    }

    @Test func addressesThatAreNotPeopleNameNobody() {
        for local in ["info", "no-reply", "noreply-calendar", "meetings", "room4", "support", "zoom"] {
            #expect(MeetingAttendee(email: "\(local)@acme.com").displayName == nil,
                    "\(local) must not become a name")
        }
        #expect(MeetingAttendee(email: "3f9a2c1e4b7d8006a1f2c3d4e5f60718@resource.calendar.google.com").displayName == nil)
        #expect(MeetingAttendee(email: "a.b.c.d.e@acme.com").displayName == nil)
        #expect(MeetingAttendee(email: "").displayName == nil)
        #expect(MeetingAttendee().displayName == nil)
    }
}

struct SpeakerMatchingTests {

    func attendee(_ name: String, self isSelf: Bool = false) -> MeetingAttendee {
        MeetingAttendee(name: name, email: nil, isSelf: isSelf)
    }

    // MARK: The one case a name is emitted

    @Test func oneAttendeeAndOneVoiceIsTheOneConfidentMatch() {
        let book = SpeakerNaming.match(clusters: [1], attendees: [attendee("Dan")])
        #expect(book.name(for: 1) == "Dan")
        #expect(book.entry(for: 1)?.confidence == .likely)
        #expect(book.entry(for: 1)?.source == .calendar)
        #expect(book.hasNames)
    }

    @Test func theUserOnTheInviteIsNotAVoiceToName() {
        // The organiser is usually the user; with them removed this is the
        // one-to-one above and Dan is named.
        let book = SpeakerNaming.match(clusters: [1],
                                       attendees: [MeetingAttendee(name: "Jordy", isSelf: true, isOrganiser: true),
                                                   attendee("Dan")])
        #expect(book.name(for: 1) == "Dan")
    }

    @Test func theUserIsAlsoRecognisedByTheNameMoeKnowsThemBy() {
        let book = SpeakerNaming.match(clusters: [1], attendees: [attendee("Jordy"), attendee("Dan")],
                                       youName: "jordy")
        #expect(book.name(for: 1) == "Dan")
    }

    @Test func aSharedFirstNameDoesNotDeleteSomebodyElse() {
        // "Dan Roth" must not be mistaken for the user called Dan: doing so
        // would leave one attendee and name the voice confidently — with
        // the wrong person's name.
        let book = SpeakerNaming.match(clusters: [1], attendees: [attendee("Dan Roth"), attendee("Sam")],
                                       youName: "Dan")
        #expect(book.name(for: 1) == nil)
        #expect(book.entry(for: 1)?.candidates == ["Dan Roth", "Sam"])
    }

    // MARK: Everything else declines

    @Test func noAttendeesNamesNobodyAndLeavesARowToRename() {
        let book = SpeakerNaming.match(clusters: [1, 2], attendees: [])
        #expect(!book.hasNames)
        #expect(book.names.map(\.speaker) == [1, 2])
        #expect(book.names.allSatisfy { $0.candidates.isEmpty && $0.confidence == .unsure })
    }

    @Test func deniedCalendarAccessIsTheSamePathAsNoInvite() {
        // The EventKit edge hands back nothing when access is not granted,
        // so this is the whole of "denied": today's transcript, unchanged.
        let denied = SpeakerNaming.match(clusters: [1], attendees: [])
        #expect(!denied.hasNames)
        #expect(denied.label(for: .them(1)) == "them (speaker 1)")
        #expect(denied.label(for: .you) == "you")
    }

    @Test func everyAttendeeBeingTheUserNamesNobody() {
        let book = SpeakerNaming.match(clusters: [1], attendees: [attendee("Jordy", self: true)])
        #expect(!book.hasNames)
        #expect(book.entry(for: 1)?.candidates.isEmpty == true)
    }

    @Test func twoAttendeesAndTwoVoicesIsNotDerivable() {
        let book = SpeakerNaming.match(clusters: [1, 2], attendees: [attendee("Dan"), attendee("Sam")])
        #expect(!book.hasNames)
        for entry in book.names {
            #expect(entry.candidates == ["Dan", "Sam"])
            #expect(entry.confidence == .unsure)
        }
    }

    @Test func moreVoicesThanAttendeesNamesNobody() {
        // Somebody who was not invited turned up, or diarization split one
        // person in two. Either way the single invited name cannot be put
        // on either voice.
        let book = SpeakerNaming.match(clusters: [1, 2, 3], attendees: [attendee("Dan")])
        #expect(!book.hasNames)
        #expect(book.names.count == 3)
        #expect(book.names.allSatisfy { $0.candidates == ["Dan"] })
    }

    @Test func moreAttendeesThanVoicesNamesNobodyEither() {
        // Three were invited, one spoke. Which one is not knowable.
        let book = SpeakerNaming.match(clusters: [1],
                                       attendees: [attendee("Dan"), attendee("Sam"), attendee("Ada")])
        #expect(book.name(for: 1) == nil)
        #expect(book.entry(for: 1)?.candidates == ["Dan", "Sam", "Ada"])
    }

    @Test func aNameKnownOnlyFromAnAddressIsUsedLikeAnyOther() {
        let book = SpeakerNaming.match(clusters: [1], attendees: [MeetingAttendee(email: "dan.levy@acme.com")])
        #expect(book.name(for: 1) == "Dan Levy")
        #expect(book.entry(for: 1)?.confidence == .likely)
    }

    @Test func anAttendeeWithNoUsableNameIsNotACandidate() {
        // A meeting room and a person: the room is not somebody who spoke,
        // so this is still the one-to-one case.
        let book = SpeakerNaming.match(clusters: [1],
                                       attendees: [MeetingAttendee(email: "room4@acme.com"),
                                                   MeetingAttendee(email: "dan@acme.com")])
        #expect(book.name(for: 1) == "Dan")
    }

    @Test func theSamePersonTwiceCountsOnce() {
        let book = SpeakerNaming.match(clusters: [1], attendees: [attendee("Dan"), attendee("dan")])
        #expect(book.name(for: 1) == "Dan")
    }

    @Test func noVoicesAtAllGivesAnEmptyBook() {
        #expect(SpeakerNaming.match(clusters: [], attendees: [attendee("Dan")]).isEmpty)
    }

    @Test func candidatesKeepTheInvitesOrder() {
        #expect(SpeakerNaming.nameable(attendees: [attendee("Sam"), attendee("Ada"), attendee("Dan")])
                == ["Sam", "Ada", "Dan"])
    }
}

struct WhichCalendarEventTests {

    let now = Date(timeIntervalSince1970: 1_756_555_200)   // a fixed instant

    func event(_ title: String, from: Double, to: Double, allDay: Bool = false,
               attendees: [MeetingAttendee] = [MeetingAttendee(name: "Dan")]) -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: now.addingTimeInterval(from * 60),
                          end: now.addingTimeInterval(to * 60), isAllDay: allDay, attendees: attendees)
    }

    @Test func theEventCoveringNowIsTheMeeting() {
        let picked = MeetingCalendar.pick(from: [event("Standup", from: -10, to: 20)], at: now)
        #expect(picked?.title == "Standup")
    }

    @Test func anEmptyCalendarIsNoEvent() {
        #expect(MeetingCalendar.pick(from: [], at: now) == nil)
        #expect(MeetingCalendar.pick(from: [event("Later", from: 120, to: 180)], at: now) == nil)
        #expect(MeetingCalendar.pick(from: [event("Over", from: -120, to: -60)], at: now) == nil)
    }

    @Test func anAllDayEventIsNeverTheMeeting() {
        // "Vacation" covers every call of the day and names nobody.
        #expect(MeetingCalendar.pick(from: [event("Vacation", from: -600, to: 800, allDay: true)], at: now) == nil)
    }

    @Test func theMostSpecificOfOverlappingEventsWins() {
        let picked = MeetingCalendar.pick(from: [event("Focus time", from: -60, to: 120, attendees: []),
                                                 event("Dan 1:1", from: -5, to: 25),
                                                 event("Vacation", from: -600, to: 800, allDay: true)],
                                          at: now)
        #expect(picked?.title == "Dan 1:1")
    }

    @Test func anEventWithPeopleBeatsOneWithout() {
        let picked = MeetingCalendar.pick(from: [event("Lunch", from: -1, to: 10, attendees: []),
                                                 event("Sync", from: -30, to: 30)], at: now)
        #expect(picked?.title == "Sync")
    }

    @Test func startingAFewMinutesEarlyStillFindsTheEvent() {
        let picked = MeetingCalendar.pick(from: [event("Sync", from: 3, to: 33)], at: now)
        #expect(picked?.title == "Sync")
        // But not a meeting half an hour away.
        #expect(MeetingCalendar.pick(from: [event("Sync", from: 30, to: 60)], at: now) == nil)
    }

    @Test func anEventAlreadyRunningBeatsOneAboutToStart() {
        let picked = MeetingCalendar.pick(from: [event("Next", from: 2, to: 32),
                                                 event("Now", from: -10, to: 20)], at: now)
        #expect(picked?.title == "Now")
    }

    @Test func theAnswerDoesNotDependOnTheOrderTheCalendarReturned() {
        let a = event("A sync", from: -5, to: 25)
        let b = event("B sync", from: -5, to: 25)
        #expect(MeetingCalendar.pick(from: [a, b], at: now)?.title
                == MeetingCalendar.pick(from: [b, a], at: now)?.title)
    }
}

struct SpeakerNameBookTests {

    @Test func aNamedVoiceReadsAsThePersonAndAnUnnamedOneAsBefore() {
        let book = SpeakerNaming.match(clusters: [1], attendees: [MeetingAttendee(name: "Dan")])
        let segments = [Segment(start: 0, end: 4, speaker: .them(1), text: "ship on Tuesday"),
                        Segment(start: 5, end: 8, speaker: .you, text: "sounds good"),
                        Segment(start: 9, end: 10, speaker: .them(2), text: "bye")]
        #expect(Timeline.format(segments, names: book) == """
            [00:00] Dan: ship on Tuesday
            [00:05] you: sounds good
            [00:09] them (speaker 2): bye
            """)
    }

    @Test func anEmptyBookFormatsExactlyAsItDidBeforePhaseB() {
        let segments = [Segment(start: 0, end: 4, speaker: .them(1), text: "hello")]
        #expect(Timeline.format(segments, names: SpeakerNameBook()) == Timeline.format(segments))
    }

    @Test func aNamedTranscriptReadsBackIntoTheSameVoices() {
        var book = SpeakerNameBook()
        book.assign("Dan", to: 2)
        let text = "[00:00] Dan: hello\n[00:05] you: hi\n[00:09] them (speaker 3): morning"
        let parsed = Timeline.parse(text, names: book)
        #expect(parsed.map(\.speaker) == [.them(2), .you, .them(3)])
        #expect(parsed.map(\.text) == ["hello", "hi", "morning"])
    }

    @Test func aNameTheBookDoesNotKnowIsNotInvented() {
        #expect(Timeline.parse("[00:00] Dan: hello").isEmpty)
    }

    @Test func theUsersOwnAnswerIsFinalAndReversible() {
        var book = SpeakerNaming.match(clusters: [1, 2], attendees: [MeetingAttendee(name: "Dan"),
                                                                     MeetingAttendee(name: "Sam")])
        #expect(!book.hasNames)
        book.assign("Sam", to: 2)
        #expect(book.name(for: 2) == "Sam")
        #expect(book.entry(for: 2)?.confidence == .confirmed)
        #expect(book.entry(for: 2)?.source == .user)
        #expect(book.name(for: 1) == nil)
        book.assign(nil, to: 2)
        #expect(book.name(for: 2) == nil)
        #expect(book.entry(for: 2)?.confidence == .unsure)
    }

    // MARK: One gate for every name, whatever it came from

    @Test func aNameThatWouldBreakATranscriptLineIsRefused() {
        // `[mm:ss] who: text` — a colon inside the name moves where a reader
        // splits `who` from the words, so the name is refused outright.
        #expect(SpeakerNameBook.clean("Dan: the second") == nil)
        #expect(SpeakerNameBook.clean("Sam:") == nil)
        #expect(SpeakerNameBook.clean(String(repeating: "D", count: 61)) == nil)
        #expect(SpeakerNameBook.clean(String(repeating: "D", count: 60))?.count == 60)
        #expect(SpeakerNameBook.clean("") == nil)
        #expect(SpeakerNameBook.clean("   ") == nil)
        #expect(SpeakerNameBook.clean(nil) == nil)
    }

    @Test func newlinesAndControlCharactersAreFoldedNotWritten() {
        // A newline in a name would split one transcript line into two,
        // neither of them a transcript line.
        #expect(SpeakerNameBook.clean("Dan\nRoth") == "Dan Roth")
        #expect(SpeakerNameBook.clean("Dan\r\nRoth") == "Dan Roth")
        #expect(SpeakerNameBook.clean("Dan\tRoth") == "Dan Roth")
        #expect(SpeakerNameBook.clean("Dan\u{202E}Roth") == "Dan Roth")
        #expect(SpeakerNameBook.clean("\n\n") == nil)
    }

    @Test func spacesAroundAndInsideANameAreTidied() {
        #expect(SpeakerNameBook.clean("  Dan Roth  ") == "Dan Roth")
        #expect(SpeakerNameBook.clean("Dan    Roth") == "Dan Roth")
    }

    @Test func theGateIsTheSameForACalendarNameAndATypedOne() {
        // From the invite…
        #expect(MeetingAttendee(name: "Dan: the second").displayName == nil)
        #expect(MeetingAttendee(name: " Dan\nRoth ").displayName == "Dan Roth")
        #expect(SpeakerNaming.match(clusters: [1], attendees: [MeetingAttendee(name: "Dan: the second")]).hasNames == false)
        // …and from the pane's text field.
        var book = SpeakerNameBook()
        book.assign("Dan: the second", to: 1)
        #expect(book.name(for: 1) == nil)
        book.assign(" Dan\tRoth ", to: 1)
        #expect(book.name(for: 1) == "Dan Roth")
    }

    @Test func theTranscriptsOwnWordsAreNotAcceptedAsANameAndNorIsBlank() {
        var book = SpeakerNameBook()
        book.assign("you", to: 1)
        book.assign("  ", to: 2)
        #expect(book.name(for: 1) == nil)
        #expect(book.name(for: 2) == nil)
        #expect(SpeakerNaming.match(clusters: [1], attendees: [MeetingAttendee(name: "them")]).hasNames == false)
    }

    @Test func aVoiceWithNoNameIsCalledSpeakerTwoAndNeverACluster() {
        let entry = SpeakerName(speaker: 2)
        #expect(entry.label == "Speaker 2")
        #expect(SpeakerName(speaker: 2, name: "Dan").label == "Dan")
    }

    @Test func theRecordCarriesTheNamesThroughJSON() throws {
        var record = MeetingRecord(startedAt: Date(timeIntervalSince1970: 1_756_555_200), durationSeconds: 60,
                                   folder: "/tmp/x", speakers: [1])
        record.attendees = [MeetingAttendee(name: "Dan", email: "dan@acme.com")]
        record.speakerNames = SpeakerNaming.match(clusters: [1], attendees: record.attendees).names
        let back = try MeetingRecord.decoder().decode(MeetingRecord.self, from: try record.json())
        #expect(back.speakerNames.first?.name == "Dan")
        #expect(back.speakerNames.first?.confidence == .likely)
        #expect(back.attendees.first?.email == "dan@acme.com")
        #expect(back.nameBook.name(for: 1) == "Dan")
    }

    @Test func aHandEditedRecordCannotPutABrokenNameIntoATranscript() throws {
        // meeting.json is a plain file the user owns; a name edited into it
        // by hand goes through the same gate as one from the calendar.
        let json = #"""
        {"startedAt":"2026-08-30T14:15:00Z","durationSeconds":60,"folder":"/tmp/x",
         "speakerNames":[{"speaker":1,"name":"Dan: the second","candidates":[],
                          "confidence":"confirmed","source":"user"}]}
        """#
        let record = try MeetingRecord.decoder().decode(MeetingRecord.self, from: Data(json.utf8))
        #expect(record.nameBook.name(for: 1) == nil)
        let line = Segment(start: 0, end: 1, speaker: .them(1), text: "hello").line(names: record.nameBook)
        #expect(line == "[00:00] them (speaker 1): hello")
        #expect(Timeline.parse(line, names: record.nameBook).count == 1)
    }

    @Test func aRecordWrittenBeforePhaseBStillLoads() throws {
        let json = #"{"startedAt":"2026-08-30T14:15:00Z","durationSeconds":60,"folder":"/tmp/x"}"#
        let record = try MeetingRecord.decoder().decode(MeetingRecord.self, from: Data(json.utf8))
        #expect(record.speakerNames.isEmpty)
        #expect(record.attendees.isEmpty)
        #expect(!record.nameBook.hasNames)
    }
}

struct SpeakerRenameTests {

    var record: MeetingRecord {
        var r = MeetingRecord(startedAt: Date(timeIntervalSince1970: 1_756_555_200), durationSeconds: 60,
                              folder: "/tmp/x", speakers: [1, 2])
        r.attendees = [MeetingAttendee(name: "Dan"), MeetingAttendee(name: "Sam")]
        r.speakerNames = SpeakerNaming.match(clusters: [1, 2], attendees: r.attendees).names
        r.notes = MeetingNotes(title: "Ship date", summary: "Speaker 2 will send the notes.",
                               decisions: ["Ship on Tuesday"],
                               actionItems: [MeetingNotes.ActionItem(who: "speaker 2", what: "send the notes", when: "Tuesday")],
                               openQuestions: ["Who tells speaker 2?"])
        return r
    }

    let transcript = """
        [00:00] them (speaker 1): We ship on Tuesday.
        [00:05] them (speaker 2): I will send the notes.
        [00:09] you: Thanks.

        """

    @Test func namingAVoiceRewritesTheWholeTranscript() {
        let out = SpeakerRename.apply(record: record, transcript: transcript, summary: nil, speaker: 2, to: "Sam")
        #expect(out.transcript == """
            [00:00] them (speaker 1): We ship on Tuesday.
            [00:05] Sam: I will send the notes.
            [00:09] you: Thanks.

            """)
        #expect(out.record.nameBook.name(for: 2) == "Sam")
        #expect(out.record.speakerNames.first(where: { $0.speaker == 2 })?.confidence == .confirmed)
    }

    @Test func theNotesAndTheSummaryFollow() {
        let md = "# Ship date\n\nSpeaker 2 will send the notes.\n\n- **speaker 2**: send the notes\n"
        let out = SpeakerRename.apply(record: record, transcript: transcript, summary: md, speaker: 2, to: "Sam")
        let notes = out.record.notes
        #expect(notes?.summary == "Sam will send the notes.")
        #expect(notes?.actionItems.first?.who == "Sam")
        #expect(notes?.openQuestions == ["Who tells Sam?"])
        #expect(out.summary == "# Ship date\n\nSam will send the notes.\n\n- **Sam**: send the notes\n")
    }

    @Test func correctingANameMovesTheOwnerButNotThePeoplesNamesInProse() {
        var named = record
        named.speakerNames = [SpeakerName(speaker: 2, name: "Dan", confidence: .likely)]
        named.notes = MeetingNotes(title: "Ship date", summary: "Dan agreed with the other Dan.",
                                   actionItems: [MeetingNotes.ActionItem(who: "Dan", what: "send the notes", when: "")])
        let out = SpeakerRename.apply(record: named,
                                      transcript: "[00:05] Dan: I will send the notes.\n",
                                      summary: nil, speaker: 2, to: "Sam")
        #expect(out.transcript == "[00:05] Sam: I will send the notes.\n")
        #expect(out.record.notes?.actionItems.first?.who == "Sam")
        // A name in a sentence may be a different person; only labels move.
        #expect(out.record.notes?.summary == "Dan agreed with the other Dan.")
    }

    @Test func takingANameBackRestoresTheNumberedLabel() {
        let named = SpeakerRename.apply(record: record, transcript: transcript, summary: nil, speaker: 2, to: "Sam")
        let back = SpeakerRename.apply(record: named.record, transcript: named.transcript, summary: nil,
                                       speaker: 2, to: nil)
        #expect(back.transcript == transcript)
        #expect(back.record.nameBook.name(for: 2) == nil)
    }

    @Test func renamingOneVoiceLeavesTheOthersAlone() {
        let out = SpeakerRename.apply(record: record, transcript: transcript, summary: nil, speaker: 2, to: "Sam")
        #expect(out.transcript.contains("them (speaker 1)"))
        #expect(out.record.nameBook.name(for: 1) == nil)
    }

    // MARK: The transcript survives a rename whatever is in it

    @Test func aLineTheRewriteCannotReadIsKeptExactlyAsItWas() {
        // The whole file used to go through parse → format, and parse drops
        // what it cannot read: one odd line among fifty was deleted from the
        // user's meeting record by an operation as routine as a rename.
        let messy = """
            [00:00] them (speaker 1): We ship on Tuesday.
            -- I paused here to take a call --
            [00:05] them (speaker 2): I will send the notes.
            [bad] them (speaker 2): from an older writer
            [00:09] you: Thanks.

            """
        let out = SpeakerRename.apply(record: record, transcript: messy, summary: nil, speaker: 2, to: "Sam")
        #expect(out.transcript == """
            [00:00] them (speaker 1): We ship on Tuesday.
            -- I paused here to take a call --
            [00:05] Sam: I will send the notes.
            [bad] them (speaker 2): from an older writer
            [00:09] you: Thanks.

            """)
        // Every line that went in is still there, in order.
        #expect(out.transcript.components(separatedBy: "\n").count
                == messy.components(separatedBy: "\n").count)
    }

    @Test func blankLinesSpacingAndTheTrailingNewlineAreUntouched() {
        let odd = "\n[00:00]  them (speaker 2):   spaced out\n\n\nno newline at the end"
        let out = SpeakerRename.apply(record: record, transcript: odd, summary: nil, speaker: 2, to: "Sam")
        #expect(out.transcript == "\n[00:00]  Sam:   spaced out\n\n\nno newline at the end")
    }

    @Test func renamingAVoiceThatSaidNothingChangesNoLine() {
        let out = SpeakerRename.apply(record: record, transcript: transcript, summary: nil, speaker: 7, to: "Ada")
        #expect(out.transcript == transcript)
        #expect(out.record.nameBook.name(for: 7) == "Ada")
    }

    @Test func anAwkwardNameLeavesTheTranscriptReadable() {
        // A name that would have broken the line's grammar is refused, so
        // the voice keeps its number and every line still parses.
        for awkward in ["Dan: the second", "   ", String(repeating: "D", count: 61)] {
            let out = SpeakerRename.apply(record: record, transcript: transcript, summary: nil,
                                          speaker: 2, to: awkward)
            #expect(out.record.nameBook.name(for: 2) == nil, "\(awkward) must be refused")
            #expect(out.transcript == transcript)
            #expect(Timeline.parse(out.transcript).count == 3)
        }
        // One that is merely untidy — a stray newline, doubled spaces — is
        // folded into a usable name rather than refused, and the line it
        // writes is still one line that reads back.
        for untidy in ["  Sam   Roth \t", "Sam\nRoth", "Sam\u{202E}Roth"] {
            let tidy = SpeakerRename.apply(record: record, transcript: transcript, summary: nil,
                                           speaker: 2, to: untidy)
            #expect(tidy.record.nameBook.name(for: 2) == "Sam Roth")
            #expect(tidy.transcript.contains("[00:05] Sam Roth: I will send the notes."))
            #expect(Timeline.parse(tidy.transcript, names: tidy.record.nameBook).count == 3)
        }
    }

    @Test func aRenamedTranscriptCanBeRenamedAgain() {
        let first = SpeakerRename.apply(record: record, transcript: transcript, summary: nil, speaker: 2, to: "Sam")
        let second = SpeakerRename.apply(record: first.record, transcript: first.transcript, summary: nil,
                                         speaker: 2, to: "Sam Roth")
        #expect(second.transcript.contains("[00:05] Sam Roth: I will send the notes."))
        #expect(!second.transcript.contains("[00:05] Sam:"))
    }

    // MARK: Two digits

    @Test func renamingSpeakerOneDoesNotCorruptSpeakerTwelve() {
        var many = MeetingRecord(startedAt: Date(), durationSeconds: 60, folder: "/tmp/x", speakers: [1, 12])
        many.speakerNames = [SpeakerName(speaker: 1), SpeakerName(speaker: 12)]
        many.notes = MeetingNotes(title: "Standup",
                                  summary: "speaker 1 and speaker 12 disagreed; speaker 1's point won.",
                                  actionItems: [MeetingNotes.ActionItem(who: "speaker 12", what: "write it up", when: "")])
        let text = "[00:00] them (speaker 1): first\n[00:04] them (speaker 12): twelfth\n"
        let out = SpeakerRename.apply(record: many, transcript: text, summary: nil, speaker: 1, to: "Dan")
        #expect(out.transcript == "[00:00] Dan: first\n[00:04] them (speaker 12): twelfth\n")
        #expect(out.record.notes?.summary == "Dan and speaker 12 disagreed; Dan's point won.")
        #expect(out.record.notes?.actionItems.first?.who == "speaker 12")
    }

    @Test func renamingAMeetingThatHasNoRecognisedVoicesIsHarmless() {
        var empty = MeetingRecord(startedAt: Date(), durationSeconds: 0, folder: "/tmp/x")
        empty.speakerNames = []
        let out = SpeakerRename.apply(record: empty, transcript: "", summary: nil, speaker: 2, to: "Sam")
        #expect(out.transcript.isEmpty)
        #expect(out.record.nameBook.name(for: 2) == "Sam")
    }
}

/// The whole of the first half, end to end through the summary writer: the
/// invite goes in, the transcript on disk and the record come out named.
struct MeetingNamesEndToEndTests {

    struct Brain: MeetingBrain {
        func complete(system: String, user: String) async throws -> String {
            #expect(user.contains("[00:00] Dan: ship on Tuesday"))
            return #"{"title": "Ship date", "summary": "Dan will ship.", "action_items": [{"who": "Dan", "what": "ship", "when": "Tuesday"}]}"#
        }
    }

    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moe-names-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    let segments = [Segment(start: 0, end: 5, speaker: .them(1), text: "ship on Tuesday"),
                    Segment(start: 6, end: 8, speaker: .you, text: "sounds good")]

    @Test func theInviteNamesTheVoiceInTheTranscriptOnDiskAndInTheRecord() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await MeetingSummary.write(
            folder: dir, segments: segments, startedAt: Date(), duration: 8,
            drift: DriftReport(systemSeconds: 8, micSeconds: 8, wallSeconds: 8),
            attendees: [MeetingAttendee(name: "Jordy", isSelf: true), MeetingAttendee(email: "dan@acme.com")],
            youName: "Jordy", brain: Brain(), summarise: true)
        #expect(out.record.speakerNames.first?.name == "Dan")
        #expect(out.record.attendees.count == 2)
        let text = try String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8)
        #expect(text.contains("[00:00] Dan: ship on Tuesday"))
        #expect(!text.contains("speaker 1"))
        let record = try MeetingRecord.load(out.recordURL)
        #expect(record.nameBook.name(for: 1) == "Dan")
        #expect(record.notes?.actionItems.first?.who == "Dan")
    }

    @Test func noInviteLeavesTheTranscriptExactlyAsItWas() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = "[00:00] them (speaker 1): ship on Tuesday\n[00:06] you: sounds good\n"
        try before.write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let out = await MeetingSummary.write(
            folder: dir, segments: segments, startedAt: Date(), duration: 8,
            drift: DriftReport(systemSeconds: 8, micSeconds: 8, wallSeconds: 8),
            brain: nil, summarise: false)
        #expect(out.record.speakerNames.count == 1)
        #expect(out.record.speakerNames.first?.name == nil)
        let text = try String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8)
        #expect(text == before)
    }
}
