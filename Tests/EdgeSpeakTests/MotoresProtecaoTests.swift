import Foundation
import Testing

@testable import EdgeSpeak

/// Proteção cruzada entre motores (M4) e duração com chunk extra (B3).
struct MotoresProtecaoTests {
    private func u16(_ v: UInt16, em dados: inout Data) {
        dados.append(UInt8(v & 0xFF))
        dados.append(UInt8((v >> 8) & 0xFF))
    }

    private func u32(_ v: UInt32, em dados: inout Data) {
        dados.append(UInt8(v & 0xFF))
        dados.append(UInt8((v >> 8) & 0xFF))
        dados.append(UInt8((v >> 16) & 0xFF))
        dados.append(UInt8((v >> 24) & 0xFF))
    }

    /// WAV de 2 s (22050 Hz, mono, 16 bits) com um chunk LIST entre o `fmt`
    /// e o `data`: a duração medida precisa ignorar o chunk extra.
    private func wavComLista() -> Data {
        var dados = Data()
        dados.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        u32(0, em: &dados) // tamanho recalculado abaixo
        dados.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        dados.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        u32(16, em: &dados)
        u16(1, em: &dados) // PCM
        u16(1, em: &dados) // mono
        u32(22050, em: &dados)
        u32(44100, em: &dados) // byte rate
        u16(2, em: &dados) // block align
        u16(16, em: &dados) // bits
        dados.append(contentsOf: [0x4C, 0x49, 0x53, 0x54]) // "LIST"
        u32(100, em: &dados)
        dados.append(Data(repeating: 0, count: 100))
        dados.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        u32(88200, em: &dados) // 44100 amostras de 2 bytes = 2 s
        dados.append(Data(repeating: 0, count: 88200))
        let total = UInt32(dados.count - 8)
        dados[4] = UInt8(total & 0xFF)
        dados[5] = UInt8((total >> 8) & 0xFF)
        dados[6] = UInt8((total >> 16) & 0xFF)
        dados[7] = UInt8((total >> 24) & 0xFF)
        return dados
    }

    /// A purga do motor online preserva o diretório offline registrado: sem
    /// isso a leitura em curso perdia os WAVs em silêncio (M4).
    @Test func purgaPreservaLeituraOffline() {
        let fm = FileManager.default
        let sufixo = UUID().uuidString
        let online = fm.temporaryDirectory.appendingPathComponent("EdgeSpeak-teste-online-\(sufixo)")
        let offline = fm.temporaryDirectory.appendingPathComponent("EdgeSpeak-teste-offline-\(sufixo)")
        try? fm.createDirectory(at: online, withIntermediateDirectories: true)
        try? fm.createDirectory(at: offline, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: online)
            try? fm.removeItem(at: offline)
        }
        EdgeTTS.keepOfflineDirectory(offline)
        EdgeTTS.purgeStaleDirectories(keeping: online)
        #expect(fm.fileExists(atPath: online.path))
        #expect(fm.fileExists(atPath: offline.path))
    }

    /// Chunk extra (LIST) não contamina a duração: 2 s medidos, não ~2,002 s.
    @Test func duracaoAtravessaChunkExtra() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("frase-\(UUID().uuidString).wav")
        try wavComLista().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let duracao = PiperTTS.duration(of: url)
        #expect(abs((duracao ?? -1) - 2.0) < 0.001)
    }
}
