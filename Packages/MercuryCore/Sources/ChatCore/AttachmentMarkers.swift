import Foundation
import MercuryKit

/// Recovers attachment chips from persisted user rows. The backend doesn't
/// round-trip attachment bytes; what history stores is the caption followed
/// by TRAILING directive lines — `@image:<path>` for images (server-side
/// `_build_persist_message_with_image_refs`; the model-facing
/// `[The user attached an image: …]` marker form is never persisted) and
/// `@file:<path>` for staged files. Native-vision rows persist a structured
/// content array whose text part carries the same trailing refs. Both become
/// byte-less `MessageAttachment`s.
///
/// ## The persisted file shape
///
/// A `file.attach` + `prompt.submit` send is stored as the caption, then one
/// `@file:` line per staged file, then whatever the server's
/// `preprocess_context_references` pass appended while expanding those refs:
///
/// ```
/// caption line
/// @file:/Users/h/.hermes/attachments/probe.txt
///
/// --- Context Warnings ---
/// - @file:/Users/h/.hermes/attachments/probe.txt: path is outside the allowed workspace
/// ```
///
/// The warnings block is the COMMON case, not an error path: `file.attach`
/// stages into `~/.hermes/attachments/`, which sits outside the session cwd
/// the expansion pass is given as its allowed root, so every staged ref is
/// refused with one `- @file:<abs path>: path is outside the allowed
/// workspace` bullet (probed against the live backend). Nothing is inlined —
/// the agent instead reads the absolute path with its own tools. The
/// `--- Attached Context ---` block (blank line, then `📄 @file:<ref> (<n>
/// tokens)` plus a fenced dump for text, or a `📎 … binary file, not inlined
/// as text. …` one-liner for binary) only appears when a ref resolves INSIDE
/// the workspace — reachable when the user hand-types one — so both markers
/// have to be stripped. Ref paths from `file.attach` are always absolute and
/// are backtick-quoted when the name holds a space, quote, or bracket; the
/// chip name is the last path component after unquoting.
///
/// A PDF send carries no `@file:` refs at all: `pdf.attach` renders pages to
/// `~/.hermes/images/pdf_p<N>_<ts>_<seq>.png` which drain into the next
/// submit as the ordinary images-v1 projection (`@image:` lines, then one
/// `[screenshot]` line per page).
///
/// There is no structured sidecar for these rows — `display_kind`,
/// `display_metadata`, and `api_content` are all null on persisted user rows,
/// so text parsing is the only hydration source.
///
/// ## Known residuals (unfixable client-side)
///
/// - A user whose own text contains a line exactly equal to one of the block
///   markers loses everything from that line down, but ONLY when refs are
///   also present: the strip is gated on finding at least one ref around the
///   truncation, so marker-shaped prose in a plain message survives intact.
/// - A PDF echo (one `.pdf` attachment) hydrates as K image page chips, since
///   that is genuinely all the row records. `.pdf` never appears on a
///   hydrated row.
public enum AttachmentMarkers {
    /// One persisted directive line: `@image:` / `@file:` + a path, quoted
    /// with backticks / double / single quotes when it contains whitespace or
    /// bracket/quote characters (mirrors `format_reference_value` and the
    /// desktop's HERMES_DIRECTIVE_RE). Computed, not stored: `Regex` isn't
    /// `Sendable`, so it can't be a static constant under strict concurrency
    /// — bind it once per parse instead of per line.
    private static var refLine:
        Regex<
            (
                Substring, kind: Substring, bq: Substring?, dq: Substring?,
                sq: Substring?, bare: Substring?
            )
        >
    {
        /^@(?<kind>image|file):(?:`(?<bq>[^`]+)`|"(?<dq>[^"]+)"|'(?<sq>[^']+)'|(?<bare>\S+))$/
    }

    /// Lines the server's ref-expansion pass emits to open a block it
    /// appended below the user's prompt. Matched whole-line and exactly.
    private static let expansionMarkers: Set<String> = [
        "--- Context Warnings ---",
        "--- Attached Context ---",
    ]

    /// One recovered directive line, before it becomes a chip.
    private struct Ref {
        var kind: MessageAttachment.Kind
        var path: String
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
            let parsed = hydrate(joinedText)
            if !parsed.attachments.isEmpty { return parsed }
            let imageCount = parts.filter { $0["type"]?.stringValue == "image_url" }.count
            let fallback = (0..<imageCount).map {
                MessageAttachment(id: "hydrated-\($0)", kind: .image, filename: "Image")
            }
            return (parsed.text, fallback)
        }
        return hydrate(text)
    }

    /// Three passes, because a persisted row can sandwich the server's
    /// expansion blocks BETWEEN two ref runs:
    ///
    /// ```
    /// caption            ← what we want to keep
    /// @file:…            ← pass C strips these (Mercury appended them)
    ///                      (blank separator)
    /// --- Context Warnings ---   ← pass B truncates here
    /// - …
    /// @image:…           ← pass A strips these (server appended them after
    /// [screenshot]         expanding the prompt)
    /// ```
    ///
    /// Pass B runs TENTATIVELY: the truncation is committed only if pass A or
    /// pass C actually found a ref, so a plain message that happens to
    /// contain a marker-shaped line keeps all of its text.
    private static func hydrate(
        _ text: String
    ) -> (text: String, attachments: [MessageAttachment]) {
        let passA = stripTrailingRefs(from: text)
        var body = passA.text
        var leadingRefs: [Ref] = []
        if let truncated = truncatedAtFirstExpansionMarker(passA.text) {
            let passC = stripTrailingRefs(from: truncated)
            if !passA.refs.isEmpty || !passC.refs.isEmpty {
                body = passC.text
                leadingRefs = passC.refs
            }
        }
        let refs = leadingRefs + passA.refs
        guard !refs.isEmpty else { return (body, []) }
        let attachments = refs.enumerated().map { index, ref in
            MessageAttachment(
                id: "hydrated-\(index)", kind: ref.kind,
                filename: (ref.path as NSString).lastPathComponent)
        }
        return (body, attachments)
    }

    /// The text above the FIRST expansion-block marker line, with the blank
    /// separator line above it dropped — or nil when the text holds no marker
    /// at all. Callers decide whether the truncation is warranted.
    private static func truncatedAtFirstExpansionMarker(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let marker = lines.firstIndex(where: { expansionMarkers.contains($0) })
        else { return nil }
        var head = lines[..<marker]
        if head.last?.isEmpty == true { head = head.dropLast() }
        return head.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Persistence only ever APPENDS refs, so strip exactly the trailing
    /// run of ref lines — a ref-shaped line mid-message is the user's own
    /// text. Refs are restored to top-to-bottom attach order. Known,
    /// unfixable-client-side edge: if the user's own final caption line is
    /// itself ref-shaped AND attachments were sent, this trailing-run strip
    /// consumes the user's line too — the parser has no way to know where
    /// the server-appended run actually begins.
    ///
    /// The trailing run also absorbs bare `[screenshot]` lines: the REST
    /// projection of a native-vision row FLATTENS the structured parts list
    /// into a single string (server-side `_content_display_text`), appending
    /// one literal `[screenshot]` placeholder per image part after the
    /// `@image:` refs. Those placeholders duplicate images the refs already
    /// account for, so they are consumed WITHOUT producing attachments —
    /// and a trailing `[screenshot]` line with no refs above it is the
    /// user's own text, left untouched by the `refs.isEmpty` guard below.
    private static func stripTrailingRefs(
        from text: String
    ) -> (text: String, refs: [Ref]) {
        let pattern = refLine
        var lines = text.components(separatedBy: "\n")[...]
        var refs: [Ref] = []
        scan: while let last = lines.last {
            if let match = last.wholeMatch(of: pattern) {
                let value = match.bq ?? match.dq ?? match.sq ?? match.bare ?? ""
                refs.append(
                    Ref(kind: match.kind == "file" ? .file : .image, path: String(value)))
            } else if last == "[screenshot]" {
                // Flattened image part — already counted by its `@image:` ref.
            } else {
                break scan
            }
            lines = lines.dropLast()
        }
        guard !refs.isEmpty else { return (text, []) }
        return (
            lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            refs.reversed()
        )
    }
}
