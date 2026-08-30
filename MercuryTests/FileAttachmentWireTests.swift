import Foundation
import Testing

@Suite("FileAttachmentWire")
struct FileAttachmentWireTests {
    @Test func knownExtensionsMapToMIME() {
        #expect(FileAttachmentWire.mimeType(forFilename: "a.txt") == "text/plain")
        #expect(FileAttachmentWire.mimeType(forFilename: "b.pdf") == "application/pdf")
        #expect(FileAttachmentWire.mimeType(forFilename: "c.csv") == "text/csv")
    }

    @Test func unknownExtensionFallsBackToOctetStream() {
        #expect(FileAttachmentWire.mimeType(forFilename: "weird.zzqq") == "application/octet-stream")
        #expect(FileAttachmentWire.mimeType(forFilename: "noext") == "application/octet-stream")
    }

    @Test func dataURLCarriesMIMEAndBase64() {
        let url = FileAttachmentWire.dataURL(Data("hi".utf8), filename: "a.txt")
        #expect(url == "data:text/plain;base64,aGk=")
    }
}
