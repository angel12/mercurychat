import Foundation
import MercuryKit

/// Recovers attachment chips from persisted user rows. The backend doesn't
/// round-trip attachment bytes; what history stores is the caption followed
/// by TRAILING `@image:<path>` directive lines (server-side
/// `_build_persist_message_with_image_refs` — the model-facing
/// `[The user attached an image: …]` marker form is never persisted).
/// Native-vision rows persist a structured content array whose text part
/// carries the same trailing refs. Both become byte-less `MessageAttachment`s.
public enum AttachmentMarkers {
    /// One persisted directive line: `@image:` + a path, quoted with
    /// backticks / double / single quotes when it contains whitespace or
    /// bracket/quote characters (mirrors `format_reference_value` and the
    /// desktop's HERMES_DIRECTIVE_RE). Computed, not stored: `Regex` isn't
    /// `Sendable`, so it can't be a static constant under strict concurrency
    /// — bind it once per parse instead of per line.
    private static var imageRefLine:
        Regex<(Substring, bq: Substring?, dq: Substring?, sq: Substring?, bare: Substring?)>
    {
        /^@image:(?:`(?<bq>[^`]+)`|"(?<dq>[^"]+)"|'(?<sq>[^']+)'|(?<bare>\S+))$/
    }

    public static func parse(
        text: String, rawContent: JSONValue?
    ) -> (text: String, attachments: [MessageAttachment]) {
        // Structured content (native-vision persistence): the text part
        // carries the same trailing refs — parse it identically. Fall back
        // to counting image parts ONLY when no refs were found; doing both
        // would double-count the same images.
        if let parts = rawContent?.arrayValue, !parts.isEmpty,
            parts.contains(where: { $0["type"]?.stringValue == "image_url" })
        {
            let joinedText = parts
                .filter { $0["type"]?.stringValue == "text" }
                .compactMap { $0["text"]?.stringValue }
                .joined(separator: "\n")
            let parsed = stripTrailingRefs(from: joinedText)
            if !parsed.attachments.isEmpty { return parsed }
            let imageCount = parts.filter { $0["type"]?.stringValue == "image_url" }.count
            let fallback = (0..<imageCount).map {
                MessageAttachment(id: "hydrated-\($0)", kind: .image, filename: "Image")
            }
            return (parsed.text, fallback)
        }
        return stripTrailingRefs(from: text)
    }

    /// Persistence only ever APPENDS refs, so strip exactly the trailing
    /// run of ref lines — a ref-shaped line mid-message is the user's own
    /// text. Refs are restored to top-to-bottom attach order. Known,
    /// unfixable-client-side edge: if the user's own final caption line is
    /// itself ref-shaped AND images were attached, this trailing-run strip
    /// consumes the user's line too — the parser has no way to know where
    /// the server-appended run actually begins.
    private static func stripTrailingRefs(
        from text: String
    ) -> (text: String, attachments: [MessageAttachment]) {
        let refLine = imageRefLine
        var lines = text.components(separatedBy: "\n")[...]
        var paths: [String] = []
        while let last = lines.last, let match = last.wholeMatch(of: refLine) {
            let value = match.bq ?? match.dq ?? match.sq ?? match.bare ?? ""
            paths.append(String(value))
            lines = lines.dropLast()
        }
        guard !paths.isEmpty else { return (text, []) }
        let attachments = paths.reversed().enumerated().map { index, path in
            MessageAttachment(
                id: "hydrated-\(index)", kind: .image,
                filename: (path as NSString).lastPathComponent)
        }
        return (
            lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            attachments
        )
    }
}
