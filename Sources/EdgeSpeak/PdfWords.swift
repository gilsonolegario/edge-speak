import Foundation

/// PDF lines via PyMuPDF (words with boxes), with a PDFKit fallback.
///
/// Why it exists: the text layer of some PDFs has no spaces between
/// words — `PDFPage.string` glues everything ("disputesconducted...") and the
/// narrator swallows pauses. PyMuPDF segments into words with boxes, so
/// spaces exist again. Personal use: with no distribution, the AGPL
/// license imposes nothing; the app keeps working without it (PDFKit fallback).
enum PdfWords {
    struct PageLines: Decodable {
        let index: Int
        /// Top of the note rule in PDFKit coords (nil with no rule or old
        /// JSON — the absence does not break decoding).
        let footnoteRuleY: CGFloat?
        let lines: [Line]

        enum CodingKeys: String, CodingKey {
            case index, lines
            case footnoteRuleY = "footnote_rule_y"
        }

        struct Line: Decodable {
            let text: String
            let box: [CGFloat]
            let words: [Word]?
            struct Word: Decodable {
                let text: String
                let box: [CGFloat]
                /// Superscript (span flag or small+elevated, see
                /// Tools/pdf_extract.py). Missing in old JSON: becomes false.
                let sup: Bool

                enum CodingKeys: String, CodingKey {
                    case text, box, sup
                }

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    text = try c.decode(String.self, forKey: .text)
                    box = try c.decode([CGFloat].self, forKey: .box)
                    sup = try c.decodeIfPresent(Bool.self, forKey: .sup) ?? false
                }
            }
        }
    }
    struct Output: Decodable {
        let pages: [PageLines]
    }

    /// Script in the bundle (packaged app) or in the repo (dev) — same pattern as the
    /// voice engine.
    static var scriptPath: String {
        if let bundled = Bundle.main.url(forResource: "pdf_extract", withExtension: "py") {
            return bundled.path
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/pdf_extract.py").path
    }

    /// Lines per page: `[(text, box in PDFKit coords, words)]`,
    /// or nil if PyMuPDF is not available (the caller uses PDFKit).
    /// The variant with `sup` (`linesWithSup`) is the full path of the geometric
    /// signal; this one drops the `sup` so as not to break the current
    /// caller (the extractor adopts `sup` in its own step).
    static func lines(pdfURL: URL, pageCount: Int) -> [[(text: String, box: CGRect, words: [(text: String, box: CGRect)])]]? {
        linesWithSup(pdfURL: pdfURL, pageCount: pageCount)?.map { page in
            page.map { (text: $0.text, box: $0.box, words: $0.words.map { (text: $0.text, box: $0.box) }) }
        }
    }

    /// Same as `lines`, but each word carries its `sup` (superscript) from the
    /// JSON — this is how the geometric signal enters the app.
    static func linesWithSup(pdfURL: URL, pageCount: Int) -> [[(text: String, box: CGRect, words: [(text: String, box: CGRect, sup: Bool)])]]? {
        guard let pages = decodedPages(pdfURL: pdfURL, pageCount: pageCount) else { return nil }
        return pages.map { page in page.lines.compactMap(lineTuples) }
    }

    /// Same extraction with the per-page note rule (nil with no rule or in
    /// old JSON). This is how the "note zone" signal enters the app.
    static func linesRules(pdfURL: URL, pageCount: Int) -> [(lines: [(text: String, box: CGRect, words: [(text: String, box: CGRect, sup: Bool)])], ruleY: CGFloat?)]? {
        guard let pages = decodedPages(pdfURL: pdfURL, pageCount: pageCount) else { return nil }
        typealias LineTuple = (text: String, box: CGRect, words: [(text: String, box: CGRect, sup: Bool)])
        return pages.map { page -> (lines: [LineTuple], ruleY: CGFloat?) in
            var ls: [LineTuple] = []
            ls.reserveCapacity(page.lines.count)
            for line in page.lines {
                if let t = lineTuples(line) { ls.append(t) }
            }
            return (lines: ls, ruleY: page.footnoteRuleY)
        }
    }

    /// Runs the script and decodes the pages in order. Nil without Python/on error.
    private static func decodedPages(pdfURL: URL, pageCount: Int) -> [PageLines]? {
        guard let python = pythonWithFitz() else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeSpeak-words-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [scriptPath, "--pdf", pdfURL.path, "--out", out.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch { return nil }
        let limit = Date().addingTimeInterval(TimeInterval(min(180, 15 + pageCount * 3)))
        while proc.isRunning, Date() < limit {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if proc.isRunning { proc.terminate(); return nil }
        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: out),
              let parsed = try? JSONDecoder().decode(Output.self, from: data)
        else { return nil }
        return parsed.pages.sorted { $0.index < $1.index }
    }

    /// Decoded line as tuple, or nil without valid geometry.
    private static func lineTuples(_ line: PageLines.Line) -> (text: String, box: CGRect, words: [(text: String, box: CGRect, sup: Bool)])? {
        guard line.box.count == 4 else { return nil }
        let rect = CGRect(
            x: line.box[0], y: line.box[1],
            width: max(0, line.box[2] - line.box[0]),
            height: max(0, line.box[3] - line.box[1]))
        guard rect.width > 0, rect.height > 0 else { return nil }
        let words: [(text: String, box: CGRect, sup: Bool)] = (line.words ?? []).compactMap { word in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, word.box.count == 4 else { return nil }
            let rect = CGRect(
                x: word.box[0], y: word.box[1],
                width: max(0, word.box[2] - word.box[0]),
                height: max(0, word.box[3] - word.box[1]))
            guard rect.width > 0, rect.height > 0 else { return nil }
            return (text, rect, word.sup)
        }
        return (line.text, rect, words)
    }

    /// First interpreter that imports `fitz` (installs nothing by itself).
    /// Prefers the support venv (bundled), with the result cached.
    private static var fitzCache: String?
    private static let fitzLock = NSLock()

    private static func pythonWithFitz() -> String? {
        fitzLock.lock()
        if let cached = fitzCache {
            fitzLock.unlock()
            return cached == "" ? nil : cached
        }
        fitzLock.unlock()
        let found = searchPythonWithFitz()
        fitzLock.lock()
        fitzCache = found ?? ""
        fitzLock.unlock()
        return found
    }

    private static func searchPythonWithFitz() -> String? {
        var seen: [String] = []
        func add(_ path: String) {
            if !seen.contains(path) { seen.append(path) }
        }
        // The support venv already ships fitz verified by `ensure`: it goes
        // first and avoids repeated probes on machines with the bundle.
        if let pronto = BundledEnv.readyPython() { add(pronto) }
        add(EdgeTTS.pythonPath)
        add(PiperTTS.venvPython.path)
        add("/opt/homebrew/bin/python3")
        add("/usr/bin/python3")
        for candidate in seen where FileManager.default.isExecutableFile(atPath: candidate) {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: candidate)
            probe.arguments = ["-c", "import fitz"]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            try? probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus == 0 { return candidate }
        }
        return nil
    }
}
