import XCTest
@testable import NashiCore

final class OfficeInputSanitizerTests: XCTestCase {
    private let secret = "nashi-secret"

    private func package(_ files: [String: String], named name: String = "input") throws -> (input: URL, base: URL) {
        let base = try OutputFiles.temporaryDirectory()
        let root = base.appendingPathComponent("Package", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, body) in files {
            let item = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: item, atomically: true, encoding: .utf8)
        }
        let input = base.appendingPathComponent(name + ".docx")
        try ArchiveCodec.create(from: root, at: input, format: "zip", token: .init())
        return (input, base)
    }

    private func sanitizedParts(_ input: URL, extensions: [String], base: URL) throws -> [String: String] {
        let output = base.appendingPathComponent(UUID().uuidString + ".docx")
        defer { try? FileManager.default.removeItem(at: output) }
        try OfficeInputSanitizer.sanitize(input, output: output, token: .init())
        let unpacked = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try ArchiveCodec.extract(output, into: unpacked, token: .init())
        var parts: [String: String] = [:]
        for ext in extensions {
            // enumerator(at:) hands back resolved paths ("/private/var/..." for a "/var/..."
            // temporary directory), so the keys come from the relative enumerator instead.
            guard let walk = FileManager.default.enumerator(atPath: unpacked.path) else { continue }
            for case let relative as String in walk where (relative as NSString).pathExtension.lowercased() == ext {
                parts[relative] = try DocumentText.read(unpacked.appendingPathComponent(relative))
            }
        }
        return parts
    }

    func testHostPathRelationshipsAreRemovedForEveryAcceptedSpelling() throws {
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rIdDouble" Type="image" Target="file:///tmp/\(secret).png" TargetMode="External"/>
        <Relationship Id="rIdSingle" Type="image" Target='file:///tmp/\(secret).png' TargetMode='External'/>
        <Relationship Id="rIdEntity" Type="image" Target="&#102;ile:///tmp/\(secret).png" TargetMode="External"/>
        <Relationship Id="rIdSpacing" Type="image" Target = "file:///tmp/\(secret).png" TargetMode = "External"/>
        <Relationship Id="rIdDotDot" Type="image" Target="../../tmp/\(secret).png" TargetMode="External"/>
        <Relationship Id="rIdDrive" Type="image" Target="c:\\tmp\\\(secret).png" TargetMode="External"/>
        <Relationship Id="rIdUnc" Type="image" Target="\\\\server\\share\\\(secret).png" TargetMode="External"/>
        <Relationship Id="rIdMedia" Type="image" Target="media/picture.png"/>
        <Relationship Id="rIdLink" Type="hyperlink" Target="https://example.com/" TargetMode="External"/>
        </Relationships>
        """
        let (input, base) = try package(["_rels/document.xml.rels": rels, "word/document.xml": "<a/>"])
        defer { try? FileManager.default.removeItem(at: base) }
        let parts = try sanitizedParts(input, extensions: ["rels"], base: base)
        let text = try XCTUnwrap(parts["_rels/document.xml.rels"], "The relationship part never reached the staged package")
        for removed in ["rIdDouble", "rIdSingle", "rIdEntity", "rIdSpacing", "rIdDotDot", "rIdDrive", "rIdUnc"] {
            XCTAssertFalse(text.contains(removed), "\(removed) still points at a host path")
        }
        XCTAssertTrue(text.contains("rIdMedia"))
        XCTAssertTrue(text.contains("rIdLink"), "An inert external hyperlink must survive conversion")
    }

    func testHostPathAttributesAreNeutralisedWithoutRewritingOtherParts() throws {
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:xlink="http://www.w3.org/1999/xlink">
        <w:body><img xlink:href="file:///tmp/\(secret).png"/><img xl:href='file:///tmp/\(secret).png'/>        <img x:href="&#47;etc/passwd"/><img xlink:href="c:\\tmp\\\(secret).png"/><span data-src="file:///tmp/\(secret)-kept.png"/></w:body></w:document>
        """
        let vector = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><image xlink:href=\"file:///tmp/\(secret).png\"/></svg>"
        let (input, base) = try package(["word/document.xml": document, "word/media/image1.svg": vector])
        defer { try? FileManager.default.removeItem(at: base) }
        let parts = try sanitizedParts(input, extensions: ["xml", "svg"], base: base)
        let text = try XCTUnwrap(parts["word/document.xml"], "The document part never reached the staged package")
        XCTAssertEqual(text.components(separatedBy: "about:blank").count - 1, 4)
        XCTAssertTrue(text.contains(#"xlink:href="about:blank""#))
        XCTAssertTrue(text.contains("xl:href='about:blank'"), "The original quote style has to be restored")
        XCTAssertTrue(text.contains(#"data-src="file:///tmp/\#(secret)-kept.png""#), "data-src is not a resource reference")
        XCTAssertFalse(text.contains(secret + ".png"))
        let embedded = try XCTUnwrap(parts["word/media/image1.svg"], "The SVG part never reached the staged package")
        XCTAssertTrue(embedded.contains("about:blank"), "An SVG part resolves its own xlink:href")
        XCTAssertFalse(embedded.contains(secret))
    }

    func testDashPrefixedEntryNamesAreStoredInsteadOfReachingZipOptions() throws {
        let (input, base) = try package([
            "mimetype": "application/vnd.oasis.opendocument.text",
            "-xword/document.xml": "ignored",
            "word/-TTdocument.xml": "kept",
            "content.xml": "<office/>"
        ], named: "dashed")
        defer { try? FileManager.default.removeItem(at: base) }
        let output = base.appendingPathComponent(UUID().uuidString + ".docx")
        defer { try? FileManager.default.removeItem(at: output) }
        try OfficeInputSanitizer.sanitize(input, output: output, token: .init())
        let unpacked = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try ArchiveCodec.extract(output, into: unpacked, token: .init())
        for name in ["mimetype", "content.xml", "-xword/document.xml", "word/-TTdocument.xml"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent(name).path), name + " was dropped from the repacked package")
        }
    }

    func testFlatMarkupSavedUnderAPackageExtensionIsStripped() throws {
        let base = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let flat = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:xlink="http://www.w3.org/1999/xlink">        <draw:image xlink:href="file:///tmp/\(secret).png"/><draw:image xlink:href='file:///tmp/\(secret).png'/>        </office:document-content>
        """
        let input = base.appendingPathComponent("flat.odt")
        try flat.write(to: input, atomically: true, encoding: .utf8)
        let output = base.appendingPathComponent(UUID().uuidString + ".odt")
        try OfficeInputSanitizer.sanitize(input, output: output, token: .init())
        let text = try DocumentText.read(output)
        XCTAssertTrue(text.hasPrefix("<?xml"))
        XCTAssertEqual(text.components(separatedBy: "about:blank").count - 1, 2)
        XCTAssertFalse(text.contains(secret))
    }

    func testRewrittenDeclarationStillDescribesTheStagedBytes() throws {
        let base = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let flat = """
        <?xml version="1.0" encoding='UTF-16' standalone='yes'?>
        <office:document-content xmlns:xlink="http://www.w3.org/1999/xlink"><draw:image xlink:href="file:///tmp/\(secret).png"/></office:document-content>
        """
        let input = base.appendingPathComponent("declared.odt")
        let payload = try XCTUnwrap(flat.data(using: .utf16LittleEndian))
        try (Data([0xff, 0xfe]) + payload).write(to: input)
        let output = base.appendingPathComponent(UUID().uuidString + ".odt")
        try OfficeInputSanitizer.sanitize(input, output: output, token: .init())
        // The input really is UTF-16, so the staged file must be re-declared UTF-8 bytes.
        let staged = try Data(contentsOf: output)
        XCTAssertFalse(staged.starts(with: [0xff, 0xfe]))
        XCTAssertNotNil(String(data: staged, encoding: .utf8))
        let text = try DocumentText.read(output)
        // The staged bytes are UTF-8, and only the encoding name may change.
        XCTAssertTrue(text.hasPrefix("<?xml version=\"1.0\" encoding='UTF-8' standalone='yes'?>"), String(text.prefix(120)))
        XCTAssertEqual(text.components(separatedBy: "about:blank").count - 1, 1)
        XCTAssertFalse(text.contains(secret))
    }

    /// The CI job runs swift test with an explicit --filter list of test names, so
    /// a new class never executes unless it is added there. This asserts the list
    /// stayed in sync instead of letting the suite rot silently.
    func testContinuousIntegrationFilterRunsThisClass() throws {
        let path = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/source.yml")
        let text = try DocumentText.read(path)
        let filters = text.split(separator: "\n").filter { $0.contains("swift test --filter") }
        XCTAssertFalse(filters.isEmpty)
        // Each job filters its own slice of the suite, so only the archive/core
        // job has to name this class.
        XCTAssertTrue(filters.contains { $0.contains("OfficeInputSanitizerTests") },
                      "no swift test --filter line in source.yml runs OfficeInputSanitizerTests")
    }

    func testNonMarkupInputIsCopiedByteForByte() throws {
        let base = try OutputFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = Data([0xD0, 0xCF, 0x11, 0xE0] + Array("Legacy compound document mislabelled as a package".utf8))
        let input = base.appendingPathComponent("legacy.odt")
        try legacy.write(to: input)
        let output = base.appendingPathComponent(UUID().uuidString + ".odt")
        try OfficeInputSanitizer.sanitize(input, output: output, token: .init())
        XCTAssertEqual(try Data(contentsOf: output), legacy, "A mislabelled legacy file must keep the converter's own detection")
    }
}
