import Foundation
import UniformTypeIdentifiers

/// Filename → wire encoding for `file.attach` uploads. Pure and
/// SwiftUI-free so MercuryTests compiles it directly.
enum FileAttachmentWire {
    static func mimeType(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty,
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType
        else { return "application/octet-stream" }
        return mime
    }

    static func dataURL(_ data: Data, filename: String) -> String {
        "data:\(mimeType(forFilename: filename));base64,\(data.base64EncodedString())"
    }
}
