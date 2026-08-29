import Foundation

/// An attachment carried by a user message. `Kind` is the extension point
/// for later types (PDF pages, arbitrary files) — v1 only produces `.image`.
public struct MessageAttachment: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case image
    }

    public var id: String
    public var kind: Kind
    public var filename: String
    /// Encoded image bytes for live-session thumbnails. Nil on rows rebuilt
    /// from hydration — the backend doesn't round-trip attachment bytes, so
    /// those render as a chip instead.
    public var previewData: Data?

    public init(id: String, kind: Kind, filename: String, previewData: Data? = nil) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.previewData = previewData
    }
}

/// An attachment staged in the composer, ready to upload: bytes are already
/// downscaled/transcoded to what the wire should carry.
public struct PendingAttachment: Sendable, Equatable, Identifiable {
    public var id: String
    public var filename: String
    public var data: Data
    public var kind: MessageAttachment.Kind
    /// Small preview (≤512 px JPEG) for tray/echo thumbnails, so the
    /// transcript never holds the full wire bytes. Nil falls back to `data`.
    public var thumbnail: Data?

    public init(
        id: String = UUID().uuidString, filename: String, data: Data,
        kind: MessageAttachment.Kind = .image, thumbnail: Data? = nil
    ) {
        self.id = id
        self.filename = filename
        self.data = data
        self.kind = kind
        self.thumbnail = thumbnail
    }
}
