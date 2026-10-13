import Foundation

/// Ambiente Python embutido: o app funciona num Mac virgem (só macOS 14+
/// arm64 + rede), sem o Python do sistema nem os venvs do dono.
///
/// Na primeira execução, `ensure` cria `~/Library/Application
/// Support/EdgeSpeak/venv` a partir da base embutida no bundle
/// (`Resources/pythonbase`) e instala SEM rede a partir dos wheels
/// embutidos (`Resources/wheels`). Depois disso, é 1 probe rápido.
/// Idempotente: com o venv pronto, nada é recriado nem reinstalado.
enum BundledEnv {
    /// Pasta base: a mesma do Piper (`~/Library/Application Support/EdgeSpeak`).
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeSpeak", isDirectory: true)
    }

    static var venvDir: URL { supportDir.appendingPathComponent("venv", isDirectory: true) }

    /// O interpretador do venv de suporte (nil quando ainda não existe).
    static var supportPython: String {
        venvDir.appendingPathComponent("bin/python").path
    }

    /// Escolha do interpretador: suporte quando válido, senão o legado.
    /// Pura para teste (a ordem do probe em um lugar só).
    static func pickPython(support: String?, supportValid: Bool, legacy: String) -> String {
        if supportValid, let support { return support }
        return legacy
    }

    private static let stateLock = NSLock()
    private static var readyCache = false
    private static let setupLock = NSLock()

    /// O venv de suporte, sem gerar processo: vale quando o `ensure` já
    /// passou nesta execução (o `ensure` verificou os imports). Nil senão.
    /// É o que mantém o caminho quente rápido (sem probe por acesso).
    static func readyPython() -> String? {
        stateLock.lock()
        let ready = readyCache
        stateLock.unlock()
        guard ready,
              FileManager.default.isExecutableFile(atPath: supportPython)
        else { return nil }
        return supportPython
    }

    private static func markReady() {
        stateLock.lock()
        readyCache = true
        stateLock.unlock()
    }

    /// Garante o venv de suporte com edge_tts+fitz+piper; devolve o caminho
    /// do interpretador. Rápido quando pronto (1 probe). Erros em pt-BR
    /// para a UI. Serializado: duas chamadas juntas preparam uma vez só.
    static func ensure(progress: @escaping (String) -> Void) throws -> String {
        if importsOK(supportPython) {
            markReady()
            return supportPython
        }
        setupLock.lock()
        defer { setupLock.unlock() }
        // Outra thread pode ter terminado enquanto esta esperava.
        if importsOK(supportPython) {
            markReady()
            return supportPython
        }
        let fm = FileManager.default
        guard let base = basePython() else {
            throw makeError(
                "Falta o Python embutido no app. Reinstale o EdgeSpeak.")
        }
        progress("Preparando o ambiente (só na primeira vez)…")
        if !fm.fileExists(atPath: venvDir.path) {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let (st, err) = runSync(base, ["-m", "venv", venvDir.path], timeout: 300)
            guard st == 0 else {
                throw makeError(
                    "Não foi possível criar o ambiente local (\(tail(err))).")
            }
        }
        let pip = venvDir.appendingPathComponent("bin/pip").path
        if !fm.isExecutableFile(atPath: pip) {
            // Base sem pip (standalone mínimo): completa dentro do venv,
            // sem tocar na base embutida.
            let (st, err) = runSync(supportPython, ["-m", "ensurepip"], timeout: 300)
            guard st == 0, fm.isExecutableFile(atPath: pip) else {
                throw makeError(
                    "Não foi possível completar o ambiente local (\(tail(err))).")
            }
        }
        guard let wheels = wheelsDir() else {
            throw makeError("Faltam os pacotes embutidos no app. Reinstale o EdgeSpeak.")
        }
        progress("Instalando os pacotes (sem rede, só na primeira vez)…")
        let (stIns, errIns) = runSync(
            pip,
            ["install", "--no-index", "--find-links", wheels.path,
             "edge-tts", "pymupdf", "piper-tts"],
            timeout: 900)
        guard stIns == 0 else {
            throw makeError(
                "Falha ao instalar os pacotes embutidos (\(tail(errIns))).")
        }
        progress("Aplicando o remendo do edge-tts…")
        guard let patch = patchScript(), let site = sitePackages() else {
            throw makeError("Faltam arquivos embutidos no app. Reinstale o EdgeSpeak.")
        }
        let (stPatch, errPatch) = runSync(
            supportPython, [patch, site.path], timeout: 120)
        guard stPatch == 0 else {
            throw makeError(
                "Falha no remendo do edge-tts (\(tail(errPatch))).")
        }
        guard importsOK(supportPython) else {
            throw makeError(
                "O ambiente local não passou na verificação. Tente de novo.")
        }
        markReady()
        return supportPython
    }

    /// Um probe só: o interpretador importa edge_tts+fitz+piper?
    static func importsOK(_ python: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: python)
        probe.arguments = ["-c", "import edge_tts, fitz, piper"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    // MARK: - Arquivos embutidos (bundle; reserva: repo em dev)

    /// Raiz do pacote em execução de dev (3 níveis acima deste arquivo).
    static var devRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Python 3 da base embutida (`Resources/pythonbase`), ou nil.
    static func basePython() -> String? {
        if let dir = embeddedDir("pythonbase") {
            for name in ["bin/python3", "bin/python"] {
                let p = dir.appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Pasta de wheels embutida, ou nil.
    static func wheelsDir() -> URL? { embeddedDir("wheels") }

    /// Script do remendo (bundle ou `Tools/` em dev), ou nil.
    static func patchScript() -> String? {
        if let url = Bundle.main.url(forResource: "patch_edge_tts", withExtension: "py") {
            return url.path
        }
        let p = devRoot.appendingPathComponent("Tools/patch_edge_tts.py").path
        return FileManager.default.isRegularFile(atPath: p) ? p : nil
    }

    private static func embeddedDir(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // Reserva de dev: Build/staging (do build-app.sh) ou Resources/.
        for base in ["Build/staging", "Resources"] {
            let url = devRoot.appendingPathComponent(base).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// O site-packages do venv de suporte (nil se ainda não existir).
    /// Puro no sistema de arquivos (testável com diretório fake).
    static func sitePackages(in dir: URL? = nil) -> URL? {
        let venv = dir ?? venvDir
        let lib = venv.appendingPathComponent("lib")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: lib, includingPropertiesForKeys: nil)
        else { return nil }
        for entry in entries where entry.lastPathComponent.hasPrefix("python") {
            let site = entry.appendingPathComponent("site-packages")
            if FileManager.default.fileExists(atPath: site.path) { return site }
        }
        return nil
    }

    // MARK: - Ajuda

    private static func runSync(_ path: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let fm = FileManager.default
        let errURL = fm.temporaryDirectory
            .appendingPathComponent("edgespeak-env-\(UUID().uuidString).log")
        fm.createFile(atPath: errURL.path, contents: nil)
        defer { try? fm.removeItem(at: errURL) }
        guard let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return (1, "(sem stderr)")
        }
        defer { try? errHandle.close() }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errHandle
        do {
            try proc.run()
        } catch {
            return (1, error.localizedDescription)
        }
        let fim = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < fim {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            proc.terminate()
            // Dá um instante para o SIGTERM; se o filho ignorar, força.
            let hard = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < hard {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
            proc.waitUntilExit()
            return (1, "tempo esgotado após \(Int(timeout))s")
        }
        proc.waitUntilExit()
        try? errHandle.close()
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return (proc.terminationStatus, err)
    }

    private static func tail(_ text: String, max: Int = 400) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "(sem detalhes)" }
        return t.count <= max ? t : "…" + String(t.suffix(max))
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "EdgeSpeak.BundledEnv", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension FileManager {
    func isRegularFile(atPath path: String) -> Bool {
        var dir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
    }
}
