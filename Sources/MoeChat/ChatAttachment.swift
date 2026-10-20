import Foundation
import UniformTypeIdentifiers

/// Something the person handed Moe with a message — a photo, a PDF, a file
/// off the Desktop.
///
/// Held by path, never by contents: Moe runs on the same Mac as the file, so
/// the brain opens it with its own file tools, and a 40 MB deck costs a
/// sentence rather than a request body. Pictures are the exception, and only
/// for the model's eyes — `brainNote` says which ones were also sent as images.
public struct ChatAttachment: Codable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Codable { case image, file }

    public var id: String
    public var path: String
    public var name: String
    public var kind: Kind
    public var byteCount: Int

    public init(id: String = UUID().uuidString, path: String, name: String? = nil,
                kind: Kind? = nil, byteCount: Int = 0) {
        self.id = id
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.kind = kind ?? Self.kind(forPath: path)
        self.byteCount = byteCount
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// "PDF", "HEIC" — what a person calls the file, from its extension.
    public var typeLabel: String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(5))
    }

    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    public static func kind(forPath path: String) -> Kind {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .file }
        return type.conforms(to: .image) ? .image : .file
    }

    /// At most this many pictures go to the model as images on one turn. The
    /// rest still reach it, by path. Each picture costs time to first token
    /// (about 2.5 s for one screenshot, measured in `Conductor.submit`), so a
    /// dozen photos inline would be a minute of silence.
    public static let pictureLimit = 4

    /// What the model reads about the attachments, ahead of the person's words.
    ///
    /// `pictured` is the ids actually sent as images — decided by whoever
    /// encoded them, not assumed here, because a file that would not decode
    /// must not be described to the model as something it can see.
    public static func brainNote(_ attachments: [ChatAttachment], pictured: Set<String> = []) -> String {
        guard !attachments.isEmpty else { return "" }
        let lines = attachments.map { a -> String in
            var line = "- \(a.path) (\(a.typeLabel), \(a.sizeLabel))"
            if pictured.contains(a.id) { line += " — also attached to this message as a picture" }
            return line
        }
        let lead = attachments.count == 1
            ? "The user attached a file to this message. It is on this Mac; open it from this path."
            : "The user attached \(attachments.count) files to this message. They are on this Mac; open them from these paths."
        return "<attachments>\n\(lead)\n\(lines.joined(separator: "\n"))\n</attachments>"
    }
}
