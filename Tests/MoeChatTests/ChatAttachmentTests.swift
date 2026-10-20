import Foundation
import Testing
@testable import MoeChat

/// Photos and files handed to Moe with a message.
struct ChatAttachmentTests {

    private let deck = ChatAttachment(id: "d", path: "/Users/sam/Desktop/Launch deck v4.key", byteCount: 18_400_000)
    private let photo = ChatAttachment(id: "p", path: "/Users/sam/Library/Application Support/Moe/attachments/1a2b3c4d/IMG_4128.HEIC",
                                       byteCount: 2_400_000)

    @Test func kindComesFromTheExtension() {
        #expect(photo.kind == .image)
        #expect(deck.kind == .file)
        #expect(ChatAttachment(path: "/tmp/Screenshot.png").kind == .image)
        #expect(ChatAttachment(path: "/tmp/notes").kind == .file)
        #expect(ChatAttachment(path: "/tmp/contract.PDF").typeLabel == "PDF")
    }

    @Test func noAttachmentsSaysNothing() {
        #expect(ChatAttachment.brainNote([]) == "")
    }

    /// Every file reaches the model by its full path — spaces and all — since
    /// the path is the only way it can open it.
    @Test func theNoteNamesEveryPath() {
        let note = ChatAttachment.brainNote([deck, photo])
        #expect(note.contains("/Users/sam/Desktop/Launch deck v4.key"))
        #expect(note.contains("/Users/sam/Library/Application Support/Moe/attachments/1a2b3c4d/IMG_4128.HEIC"))
        #expect(note.contains("2 files"))
        #expect(note.hasPrefix("<attachments>"))
        #expect(note.hasSuffix("</attachments>"))
    }

    /// Only what was actually sent as a picture is described as one. A photo
    /// that failed to decode must not be something the model thinks it can see.
    @Test func onlyWhatWasPicturedIsSaidToBeAPicture() {
        let unpictured = ChatAttachment.brainNote([photo], pictured: [])
        #expect(!unpictured.contains("picture"))

        let pictured = ChatAttachment.brainNote([deck, photo], pictured: ["p"])
        let lines = pictured.split(separator: "\n")
        #expect(lines.first { $0.contains("IMG_4128") }?.contains("picture") == true)
        #expect(lines.first { $0.contains("Launch deck") }?.contains("picture") == false)
    }

    /// A thread written before attachments existed still opens.
    @Test func aTurnWithoutAttachmentsStillDecodes() throws {
        let old = #"{"id":"t1","role":"you","text":"hello","at":"2026-09-01T10:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let turn = try decoder.decode(ConversationStore.StoredTurn.self, from: Data(old.utf8))
        #expect(turn.attachments == nil)
        #expect(turn.text == "hello")
    }

    /// A photo sent with no words is a turn worth keeping, and a conversation
    /// holding only that is not empty.
    @Test func aPhotoOnItsOwnIsAConversation() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-attach-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ConversationStore(directory: dir)
        let convo = ConversationStore.Conversation(turns: [
            .init(role: .you, text: "", attachments: [photo]),
        ])
        #expect(!convo.isEmpty)
        try store.save(convo)
        let loaded = try #require(store.load(id: convo.id))
        #expect(loaded.turns.first?.attachments == [photo])
    }
}
