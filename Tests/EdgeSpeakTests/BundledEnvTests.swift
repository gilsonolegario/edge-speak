import Foundation
import Testing

@testable import EdgeSpeak

/// Cobertura do ambiente embutido: o que é puro (ordem de probe, nomes de
/// voz, site-packages fake) e a idempotência do remendo via diretório fake.
struct BundledEnvTests {
    // MARK: - Ordem de probe

    @Test func suporteValidoVence() {
        #expect(BundledEnv.pickPython(
            support: "/suporte/venv/bin/python", supportValid: true,
            legacy: "/usr/bin/python3") == "/suporte/venv/bin/python")
    }

    @Test func suporteInvalidoCaiParaLegado() {
        #expect(BundledEnv.pickPython(
            support: "/suporte/venv/bin/python", supportValid: false,
            legacy: "/usr/bin/python3") == "/usr/bin/python3")
    }

    @Test func semSuporteCaiParaLegado() {
        #expect(BundledEnv.pickPython(
            support: nil, supportValid: false,
            legacy: "/usr/bin/python3") == "/usr/bin/python3")
    }

    // MARK: - Nomes de voz

    @Test func nomesDeVoz() {
        #expect(PiperTTS.voiceFileBase(for: PiperTTS.faberPtBR) == "pt_BR-faber-medium")
        #expect(PiperTTS.voiceFileBase(for: PiperTTS.lessacEnUS) == "en_US-lessac-medium")
        #expect(PiperTTS.voiceFileBase(for: PiperTTS.edressonPtBR) == "pt_BR-edresson-low")
        #expect(PiperTTS.voiceFileBase(for: PiperTTS.caduPtBR) == "pt_BR-cadu-medium")
        #expect(PiperTTS.voiceFileBase(for: PiperTTS.jeffPtBR) == "pt_BR-jeff-medium")
        #expect(PiperTTS.voiceFileBase(for: "voz-inexistente") == nil)
        #expect(PiperTTS.onnxPath(for: "voz-inexistente") == nil)
    }

    @Test func ordemDaVoz() {
        let suporte = URL(fileURLWithPath: "/suporte/pt_BR-faber-medium.onnx")
        let pacote = URL(fileURLWithPath: "/pacote/pt_BR-faber-medium.onnx")
        // Suporte existente vence o bundle.
        #expect(PiperTTS.pickOnnx(
            support: suporte, supportExists: true,
            bundle: pacote, bundleExists: true) == suporte)
        // Sem suporte, o bundle vale.
        #expect(PiperTTS.pickOnnx(
            support: suporte, supportExists: false,
            bundle: pacote, bundleExists: true) == pacote)
        // Sem nenhum, devolve o suporte (alvo do download).
        #expect(PiperTTS.pickOnnx(
            support: suporte, supportExists: false,
            bundle: nil, bundleExists: false) == suporte)
    }

    // MARK: - site-packages fake

    @Test func sitePackagesEmVenvFake() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgespeak-teste-\(UUID().uuidString)")
        let site = base.appendingPathComponent("lib/python3.13/site-packages")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // Compara com symlinks resolvidos (/var → /private/var no macOS).
        #expect(BundledEnv.sitePackages(in: base)?.resolvingSymlinksInPath().path
            == site.resolvingSymlinksInPath().path)
        #expect(BundledEnv.sitePackages(
            in: base.appendingPathComponent("sem-venv")) == nil)
    }

    // MARK: - Remendo idempotente (diretório fake, sem rede)

    private func pacoteFake(estiloAntigo: Bool) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgespeak-remendo-\(UUID().uuidString)")
        let pacote = base.appendingPathComponent("edge_tts")
        try FileManager.default.createDirectory(at: pacote, withIntermediateDirectories: true)
        if estiloAntigo {
            let constants = "\"\"\"Constants.\"\"\"\n"
                + "BASE_URL = \"speech.platform.bing.com/consumer/speech/synthesize/readaloud\"\n"
                + "TRUSTED_CLIENT_TOKEN = \"6A5AA1D4EAFF4E9FB37E23D68491D6F4\"\n"
                + "WSS_URL = (\n"
                + "    f\"wss://{BASE_URL}/antigo\"\n"
                + ")\n"
            try constants.write(
                to: pacote.appendingPathComponent("constants.py"),
                atomically: true, encoding: .utf8)
            let drm = "\"\"\"DRM.\"\"\"\n"
                + "import hashlib\n"
                + "from datetime import datetime as dt\n"
                + "from datetime import timezone as tz\n"
                + "from typing import Dict, Optional\n"
                + "\n"
                + "\n"
                + "class DRM:\n"
                + "    @staticmethod\n"
                + "    def parse_rfc2616_date(date):\n"
                + "        try:\n"
                + "            parsed = dt.strptime(date, \"%a, %d %b %Y %H:%M:%S GMT\")\n"
                + "        except (TypeError, ValueError):\n"
                + "            return None\n"
                + "        return parsed.timestamp()\n"
                + "\n"
                + "    @staticmethod\n"
                + "    def outra():\n"
                + "        return 1\n"
            try drm.write(
                to: pacote.appendingPathComponent("drm.py"),
                atomically: true, encoding: .utf8)
        }
        return base
    }

    private func rodaRemendo(sitePackages: URL) throws -> Int32 {
        guard let script = BundledEnv.patchScript() else {
            Issue.record("Script do remendo não encontrado (Tools/patch_edge_tts.py).")
            return 99
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script, sitePackages.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    @Test func remendoIdempotente() throws {
        let base = try pacoteFake(estiloAntigo: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try rodaRemendo(sitePackages: base) == 0)
        let const1 = try Data(contentsOf: base.appendingPathComponent("edge_tts/constants.py"))
        let drm1 = try Data(contentsOf: base.appendingPathComponent("edge_tts/drm.py"))
        // O endpoint v2 entrou e o parse imune a idioma também.
        #expect(String(data: const1, encoding: .utf8)?
            .contains("api.msedgeservices.com/tts/cognitiveservices/websocket/v1") == true)
        #expect(String(data: drm1, encoding: .utf8)?
            .contains("parsedate_to_datetime(date)") == true)
        // O resto do drm sobreviveu (não comeu o método vizinho).
        #expect(String(data: drm1, encoding: .utf8)?.contains("def outra()") == true)
        // Segunda passada: sai 0 e não muda um byte.
        #expect(try rodaRemendo(sitePackages: base) == 0)
        #expect(try Data(contentsOf: base.appendingPathComponent("edge_tts/constants.py")) == const1)
        #expect(try Data(contentsOf: base.appendingPathComponent("edge_tts/drm.py")) == drm1)
    }

    @Test func remendoSemPacoteFalhaLegivel() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgespeak-vazio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try rodaRemendo(sitePackages: base) == 1)
    }
}
