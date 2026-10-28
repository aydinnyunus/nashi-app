import Foundation

/// LibreOffice resolves external resource references inside office documents
/// at its own file permission level. The conversion sandbox only denies IP
/// networking, so an untrusted document that carries host-path references
/// (OOXML relationship targets or ODF href attributes) pulls local files
/// into the export before conversion. Office inputs are therefore staged with
/// those references removed; the converter then renders its standard missing
/// image placeholder. Package entries are rewritten without touching their
/// internal paths, so a freshly prepared file still converts identically.
enum OfficeInputSanitizer {
    static let formats: Set<String> = ["docx", "xlsx", "pptx", "odt", "ods", "odp"]

    static func sanitize(_ input: URL, output: URL, token: CancellationToken) throws {
        switch input.pathExtension.lowercased() {
        case "docx", "xlsx", "pptx", "odt", "ods", "odp": try stagePackage(input, output: output, token: token)
        default: try FileManager.default.copyItem(at: input, to: output)
        }
    }

    private static func stagePackage(_ input: URL, output: URL, token: CancellationToken) throws {
        let fm = FileManager.default
        guard isZIP(input) else { try fm.copyItem(at: input, to: output); return }
        let work = try OutputFiles.temporaryDirectory()
        defer { try? fm.removeItem(at: work) }
        let unpacked = work.appendingPathComponent("Package", isDirectory: true)
        try ArchiveCodec.extract(input, into: unpacked, token: token)
        try token.check()
        for part in markupParts(in: unpacked) {
            try token.check()
            let text = try DocumentText.read(part)
            let clean = part.pathExtension.lowercased() == "rels" ? stripRelationships(text) : stripReferences(text)
            if clean != text { try clean.write(to: part, atomically: true, encoding: .utf8) }
        }
        try token.check()
        try? fm.removeItem(at: output)
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        var packed: [String] = []
        if fm.fileExists(atPath: unpacked.appendingPathComponent("mimetype").path) {
            // ODF keeps a stored first entry, mirroring EPUBCodec.
            try ProcessRunner.run(zip, ["-q", "-X", "-0", output.path, "mimetype"], directory: unpacked, token: token)
            packed = ["mimetype"]
        }
        let entries = (try fm.contentsOfDirectory(atPath: unpacked.path)).filter { !packed.contains($0) }.sorted()
        guard !entries.isEmpty else { throw NashiError.invalidInput("This document package is empty.") }
        try ProcessRunner.run(zip, ["-q", "-X", "-r", output.path] + entries, directory: unpacked, token: token)
    }

    private static func isZIP(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 4) else { return false }
        return head == Data([0x50, 0x4B, 0x03, 0x04])
    }

    private static func markupParts(in root: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { ["xml", "rels"].contains($0.pathExtension.lowercased()) }
    }

    /// Replaces a host-path resource reference with a document-internal anchor
    /// the converter cannot resolve. Matches file:, absolute, home-relative and
    /// parent-directory escapes in href, xlink:href and src attributes.
    private static let referencePattern = regex("(href|xlink:href|src)\\s*=\\s*\"(file:[^\"]*|/[^\"]*|~[^\"]*|\\.\\.[/\\\\][^\"]*)\"")

    private static func stripReferences(_ text: String) -> String {
        referencePattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1=\"about:blank\"")
    }

    /// Drops an OOXML relationship that points outside the package through a
    /// host path. Relative and hyperlinks stay: LibreOffice resolves them
    /// against the staged document only, and links are inert during import.
    private static let relationshipPattern = regex("<Relationship\\b[^>]*/>|<Relationship\\b[^>]*>.*?</Relationship>")
    private static let targetPattern = regex("Target=\"([^\"]*)\"")

    private static func stripRelationships(_ text: String) -> String {
        var result = text
        let full = NSRange(text.startIndex..., in: text)
        for match in relationshipPattern.matches(in: text, range: full).reversed() {
            guard let hit = substring(match.range, in: result), isHostTarget(hit) else { continue }
            if let range = Range(match.range, in: result) { result.removeSubrange(range) }
        }
        return result
    }

    private static func isHostTarget(_ element: String) -> Bool {
        guard element.lowercased().contains("targetmode=\"external\"") else { return false }
        let full = NSRange(element.startIndex..., in: element)
        guard let found = targetPattern.firstMatch(in: element, range: full), found.numberOfRanges > 1,
              let target = substring(found.range(at: 1), in: element) else { return false }
        let value = target.lowercased()
        return value.hasPrefix("file:") || value.hasPrefix("/") || value.hasPrefix("~") || value.contains("../") || value.contains("..\\")
    }

    private static func substring(_ range: NSRange, in text: String) -> String? {
        Range(range, in: text).map { String(text[$0]) }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        guard let value = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            preconditionFailure("invalid sanitizer pattern")
        }
        return value
    }
}
