import Foundation

/// What the New Bot quick path sends, derived from what the user typed the
/// way hermes desktop's hermes-bots plugin does (`labels.ts`
/// `slugifyProfileName` / `botProfileIdentity` / `displayName`, `soul.ts`
/// `composeSoul`, `canonical-chat.ts` kickoff; hermes-agent `16fe260aab`),
/// so a bot is named, described and introduced the same from either client.
public enum BotCreation {
    /// The prompt a newly created bot's Bot Chat opens with: the bot
    /// introduces itself. Sent once, on creation only.
    public static let kickoff = "Hey, tell me about yourself!"

    /// The profile id for a typed name. The backend accepts only
    /// `^[a-z0-9][a-z0-9_-]{0,63}$` (`hermes_constants.PROFILE_ID_RE`), so
    /// accented Latin folds to its base letters (`Résumé` → `resume`) and any
    /// other letter or digit becomes a `u<hex>` token per NFC code point
    /// (`小助手` → `u5c0f-u52a9-u624b`). Past 64 characters it is cut at the
    /// last token boundary. Empty when nothing usable was typed (`🤖`).
    public static func profileSlug(for name: String) -> String {
        var folded = ""
        for scalar in name.precomposedStringWithCanonicalMapping.unicodeScalars {
            guard isLetterOrNumber(scalar) else {
                folded.unicodeScalars.append(scalar)
                continue
            }
            let base = String(scalar).decomposedStringWithCompatibilityMapping.unicodeScalars
                .filter { !isMark($0) }
            if !base.isEmpty, base.allSatisfy({ $0.isASCII && isAlphanumericASCII($0) }) {
                folded.unicodeScalars.append(contentsOf: base)
            } else {
                folded += "-u\(String(scalar.value, radix: 16))-"
            }
        }
        let slug = slugify(
            folded.replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression))
        guard slug.count > 64 else { return slug }
        let characters = Array(slug)
        let cut = String(characters[..<64])
        let boundary: Int
        if characters[64] == "-" {
            boundary = 64
        } else if let last = cut.lastIndex(of: "-") {
            boundary = cut.distance(from: cut.startIndex, to: last)
        } else {
            boundary = 0
        }
        let kept = boundary > 0 ? String(characters[..<boundary]) : cut
        return String(kept.reversed().drop(while: { $0 == "-" }).reversed())
    }

    /// Whether `id` satisfies `hermes_constants.PROFILE_ID_RE`.
    public static func isValidProfileID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// The profile id and title for what was typed in Name and Title. A
    /// non-ASCII name can't be the id, so it survives as the title when
    /// Title was left empty.
    public static func identity(name: String, title: String) -> (slug: String, title: String) {
        let enteredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonASCII = enteredName.unicodeScalars.contains { !(0x20...0x7E).contains($0.value) }
        return (profileSlug(for: enteredName), enteredTitle.isEmpty && nonASCII ? enteredName : enteredTitle)
    }

    /// The bot's display name: its title, else the id with `-`/`_` as spaces
    /// and each word capitalised (`inbox-triage` → `Inbox Triage`).
    public static func displayName(slug: String, title: String) -> String {
        let raw = (title.isEmpty ? slug : title)
            .replacingOccurrences(of: #"[-_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var result = ""
        var atWordStart = true
        for character in raw {
            let isWord = character.isASCII && (character.isLetter || character.isNumber || character == "_")
            result.append(atWordStart && isWord ? Character(character.uppercased()) : character)
            atWordStart = !isWord
        }
        return result
    }

    /// The SOUL.md a new bot is born with: its identity. The desktop appends
    /// the agent-to-agent messaging protocol only when the backend doesn't
    /// inject it; every backend Chat supports (contract ≥ 7, well after
    /// `bot_mode_protocol`) injects it, so it is left out here.
    public static func soul(slug: String, title: String, description: String) -> String {
        let name = displayName(slug: slug, title: title)
        var lines = ["# \(name)", ""]
        if !title.isEmpty { lines.append("**Role:** \(title)") }
        if !description.isEmpty { lines.append("**Mission:** \(description)") }
        lines += [
            "",
            "You are \(name), a persistent named agent (profile `\(slug)`) on this machine.",
            "You keep your own memory, skills, and conversation history across sessions.",
        ]
        return lines.joined(separator: "\n")
    }

    /// The profile's description: title and description joined as the
    /// desktop does ("Researcher — Finds things out"); nil when both are empty.
    public static func profileDescription(title: String, description: String) -> String? {
        let parts = [title, description].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    // MARK: Helpers

    /// `value.toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '')`.
    private static func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "-", options: .regularExpression)
        return lowered.replacingOccurrences(of: #"^-+|-+$"#, with: "", options: .regularExpression)
    }

    /// `\p{L}` or `\p{N}`.
    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// `\p{M}`.
    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isAlphanumericASCII(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }
}
