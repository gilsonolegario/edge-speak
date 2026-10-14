import Foundation

/// Monta um relatório de diagnóstico copiável (Ajustes → Avançado), pensado
/// para o suporte por GitHub: reúne versões, ambiente de execução, presença do
/// venv e das ferramentas e o último status/erro mostrado — sem dados do
/// documento lido (privacidade).
///
/// Nada aqui inventa estado: cada linha é lida do ambiente no momento da
/// chamada; o que não existe aparece como "ausente".
enum Diagnostics {
    /// Texto em várias linhas, pronto para colar num relatório.
    static func texto() -> String {
        var linhas: [String] = []
        let info = Bundle.main.infoDictionary
        let versao = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        linhas.append("EdgeSpeak \(versao) (\(build))")
        linhas.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if arch(arm64)
        linhas.append("arch: arm64")
        #elseif arch(x86_64)
        linhas.append("arch: x86_64")
        #else
        linhas.append("arch: desconhecida")
        #endif

        // Ambiente de suporte (venv Python com edge_tts/fitz/piper).
        linhas.append("suporte: \(BundledEnv.supportDir.path)")
        let venvPresente = FileManager.default.fileExists(atPath: BundledEnv.venvDir.path)
        linhas.append("venv: \(venvPresente ? "presente" : "ausente")")
        if let pronto = BundledEnv.readyPython() {
            linhas.append("python (pronto nesta execução): \(pronto)")
        } else if let base = BundledEnv.basePython() {
            linhas.append("python (base do sistema): \(base)")
        } else {
            linhas.append("python: não encontrado")
        }
        linhas.append("ffmpeg: \(EdgeTTS.ffmpegPath ?? "ausente")")

        // Cache em disco.
        let bytes = CacheDisco.totalBytes()
        linhas.append("cache: \(bytes / 1_048_576) MB (\(bytes) bytes)")

        // Idioma escolhido e último status/erro (não é dado do documento).
        let idioma = UserDefaults.standard.string(forKey: AppSetting.languageKey) ?? "pt"
        linhas.append("idioma da interface: \(idioma)")
        let ultimo = DiagStatus.ultimoStatus
        linhas.append("último status: \(ultimo.isEmpty ? "(nenhum)" : ultimo)")

        return linhas.joined(separator: "\n")
    }
}

/// Snapshot thread-safe do último status/erro mostrado. Fica fora de
/// `SpeechController` (que é `@MainActor`) de propósito: o texto do
/// diagnóstico é montado em segundo plano, e o controller pode escrever
/// da main. Um lock curto cobre os dois lados.
enum DiagStatus {
    private static let lock = NSLock()
    private static var texto = ""

    static var ultimoStatus: String {
        lock.lock(); defer { lock.unlock() }
        return texto
    }

    static func registra(_ s: String) {
        lock.lock(); texto = s; lock.unlock()
    }
}
