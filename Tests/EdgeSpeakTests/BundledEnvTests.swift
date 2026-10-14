import Foundation
import Testing

@testable import EdgeSpeak

/// Coverage of the bundled environment: what is pure (probe order, voice
/// names, fake site-packages) and the idempotency of the patch via a fake directory.
struct BundledEnvTests {
    // MARK: - Ordem de probe

    @Test func validSupportWins() {
        #expect(BundledEnv.pickPython(
            support: "/suporte/venv/bin/python", supportValid: true,
            legacy: "/usr/bin/python3") == "/suporte/venv/bin/python")
    }

    @Test func invalidSupportFallsBackToLegacy() {
        #expect(BundledEnv.pickPython(
            support: "/suporte/venv/bin/python", supportValid: false,
            legacy: "/usr/bin/python3") == "/usr/bin/python3")
    }

    @Test func noSupportFallsBackToLegacy() {
        #expect(BundledEnv.pickPython(
            support: nil, supportValid: false,
            legacy: "/usr/bin/python3") == "/usr/bin/python3")
    }

    // MARK: - Nomes de voz

    @Test func voiceNames() {
        #expect(PiperTTS.voiceFileBase(for: PiperTTS.faberPtBR) == "pt_BR-faber-medium")
        #expect(PiperTTS.voiceFileBase(for: PiperTTS.lessacEnUS) == "en_US-lessac-medium")
        #expect(PiperTTS.voiceFileBase(for: PiperTTS.edressonPtBR) == "pt_BR-edresson-low")
        #expect(PiperTTS.voiceFileBase(for: PiperTTS.caduPtBR) == "pt_BR-cadu-medium")
        #expect(PiperTTS.voiceFileBase(for: PiperTTS.jeffPtBR) == "pt_BR-jeff-medium")
        #expect(PiperTTS.voiceFileBase(for: "voz-inexistente") == nil)
        #expect(PiperTTS.onnxPath(for: "voz-inexistente") == nil)
    }

    @Test func voiceOrder() {
        let support = URL(fileURLWithPath: "/suporte/pt_BR-faber-medium.onnx")
        let package = URL(fileURLWithPath: "/pacote/pt_BR-faber-medium.onnx")
        // Suporte existente vence o bundle.
        #expect(PiperTTS.pickOnnx(
            support: support, supportExists: true,
            bundle: package, bundleExists: true) == support)
        // Sem suporte, o bundle vale.
        #expect(PiperTTS.pickOnnx(
            support: support, supportExists: false,
            bundle: package, bundleExists: true) == package)
        // Sem nenhum, devolve o suporte (alvo do download).
        #expect(PiperTTS.pickOnnx(
            support: support, supportExists: false,
            bundle: nil, bundleExists: false) == support)
    }

    // MARK: - site-packages fake

    @Test func sitePackagesInFakeVenv() throws {
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

    // MARK: - Idempotent patch (fake directory, no network)

    private func fakePackage(estiloAntigo: Bool) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgespeak-remendo-\(UUID().uuidString)")
        let package = base.appendingPathComponent("edge_tts")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        if estiloAntigo {
            let constants = "\"\"\"Constants.\"\"\"\n"
                + "BASE_URL = \"speech.platform.bing.with/consumer/speech/synthesize/readaloud\"\n"
                + "TRUSTED_CLIENT_TOKEN = \"6A5AA1D4EAFF4E9FB37E23D68491D6F4\"\n"
                + "WSS_URL = (\n"
                + "    f\"wss://{BASE_URL}/antigo\"\n"
                + ")\n"
            try constants.write(
                to: package.appendingPathComponent("constants.py"),
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
                to: package.appendingPathComponent("drm.py"),
                atomically: true, encoding: .utf8)
        }
        return base
    }

    private func runPatch(sitePackages: URL) throws -> Int32 {
        guard let script = BundledEnv.patchScript() else {
            Issue.record("Patch script not found (Tools/patch_edge_tts.py).")
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

    @Test func patchIsIdempotent() throws {
        let base = try fakePackage(estiloAntigo: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try runPatch(sitePackages: base) == 0)
        let const1 = try Data(contentsOf: base.appendingPathComponent("edge_tts/constants.py"))
        let drm1 = try Data(contentsOf: base.appendingPathComponent("edge_tts/drm.py"))
        // The v2 endpoint came in, and with it the language-immune parse.
        #expect(String(data: const1, encoding: .utf8)?
            .contains("api.msedgeservices.com/tts/cognitiveservices/websocket/v1") == true)
        #expect(String(data: drm1, encoding: .utf8)?
            .contains("parsedate_to_datetime(date)") == true)
        // The rest of drm survived (it did not eat the neighboring method).
        #expect(String(data: drm1, encoding: .utf8)?.contains("def outra()") == true)
        // Second pass: returns 0 and does not change a byte.
        #expect(try runPatch(sitePackages: base) == 0)
        #expect(try Data(contentsOf: base.appendingPathComponent("edge_tts/constants.py")) == const1)
        #expect(try Data(contentsOf: base.appendingPathComponent("edge_tts/drm.py")) == drm1)
    }

    @Test func patchWithoutPackageFailsLegibly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgespeak-vazio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try runPatch(sitePackages: base) == 1)
    }
}
