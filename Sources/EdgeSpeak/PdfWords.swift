import Foundation

/// Linhas do PDF via PyMuPDF (palavras com caixas), com reserva para PDFKit.
///
/// Por que existe: a camada de texto de alguns PDFs não tem os espaços entre
/// palavras — o `PDFPage.string` cola tudo ("disputesconducted...") e o
/// narrador engole pausas. O PyMuPDF segmenta em palavras com caixas, então
/// os espaços voltam a existir. Uso pessoal: sem distribuir, a licença AGPL
/// não impõe nada; o app continua funcionando sem ele (reserva PDFKit).
enum PdfWords {
    struct PageLines: Decodable {
        let index: Int
        /// Topo da régua de notas em coords PDFKit (nil sem régua ou JSON
        /// antigo — a ausência não quebra a decodificação).
        let footnoteRuleY: CGFloat?
        let lines: [Line]
        struct Line: Decodable {
            let text: String
            let box: [CGFloat]
            let words: [Word]?
            struct Word: Decodable {
                let text: String
                let box: [CGFloat]
                /// Sobrescrito (bit do span ou pequeno+elevado, vide
                /// Tools/pdf_extract.py). Ausente em JSON antigo: vira false.
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

    /// Script no bundle (app empacotado) ou no repo (dev) — mesmo padrão do
    /// motor de voz.
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

    /// Linhas por página: `[(texto, caixa em coords do PDFKit, palavras)]`,
    /// ou nil se o PyMuPDF não estiver disponível (o chamador usa o PDFKit).
    /// A variante com `sup` (`linesWithSup`) é o caminho completo do sinal
    /// geométrico; esta aqui descarta o `sup` para não quebrar o chamador
    /// atual (o extrator adota o `sup` em passo próprio).
    static func lines(pdfURL: URL, pageCount: Int) -> [[(text: String, box: CGRect, words: [(text: String, box: CGRect)])]]? {
        linesWithSup(pdfURL: pdfURL, pageCount: pageCount)?.map { page in
            page.map { (text: $0.text, box: $0.box, words: $0.words.map { (text: $0.text, box: $0.box) }) }
        }
    }

    /// Mesmo que `lines`, mas cada palavra leva o `sup` (sobrescrito) do
    /// JSON — é por aqui que o sinal geométrico entra no app.
    static func linesWithSup(pdfURL: URL, pageCount: Int) -> [[(text: String, box: CGRect, words: [(text: String, box: CGRect, sup: Bool)])]]? {
        guard let pages = decodedPages(pdfURL: pdfURL, pageCount: pageCount) else { return nil }
        return pages.map { page in page.lines.compactMap(lineTuples) }
    }

    /// Mesma extração com a régua de notas por página (nil sem régua ou em
    /// JSON antigo). É por aqui que o sinal "zona de notas" entra no app.
    static func linesRules(pdfURL: URL, pageCount: Int) -> [(lines: [(text: String, box: CGRect, words: [(text: String, box: CGRect, sup: Bool)])], ruleY: CGFloat?)]? {
        guard let pages = decodedPages(pdfURL: pdfURL, pageCount: pageCount) else { return nil }
        typealias Linha = (text: String, box: CGRect, words: [(text: String, box: CGRect, sup: Bool)])
        return pages.map { page -> (lines: [Linha], ruleY: CGFloat?) in
            var ls: [Linha] = []
            ls.reserveCapacity(page.lines.count)
            for line in page.lines {
                if let t = lineTuples(line) { ls.append(t) }
            }
            return (lines: ls, ruleY: page.footnoteRuleY)
        }
    }

    /// Roda o script e decodifica as páginas em ordem. Nil sem Python/erro.
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

    /// Linha decodificada em tupla, ou nil sem geometria válida.
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

    /// Primeiro interpretador que importa `fitz` (não instala nada sozinho).
    /// Prefere o venv de suporte (embutido), com cache do resultado.
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
        // O venv de suporte já traz fitz verificado pelo `ensure`: entra
        // primeiro e evita probes repetidos nas máquinas com bundle.
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
