import Foundation
import Testing

@testable import EdgeSpeak

/// Plano item 41 — exportação com os tempos (SRT/VTT/JSON).
///
/// O áudio exportado ia sozinho: fora do Mac não havia acompanhamento nem
/// pulo por frase. A lista de `Segment` que o app já mantém para o destaque
/// passou a sair serializada ao lado do arquivo. A serialização é PURA,
/// então aqui ela é fixada byte a byte — a gravação em disco é coberta
/// pelos dois últimos testes.
struct LaneExportTests {
    /// Duas frases com tempos globais; a primeira traz `words` (EdgeTTS),
    /// a segunda não (Piper).
    private func twoSegments() -> [EdgeTTS.Segment] {
        [
            EdgeTTS.Segment(
                start: 0, duration: 3.12, text: "Primeira frase.",
                words: [
                    .init(start: 0, duration: 0.5, text: "Primeira"),
                    .init(start: 0.5, duration: 0.62, text: "frase."),
                ],
                index: 0, page: 3),
            EdgeTTS.Segment(
                start: 3.12, duration: 1.2, text: "Segunda frase.",
                index: 1),
        ]
    }

    @Test func srtFormatIsExact() {
        let expected = """
        1
        00:00:00,000 --> 00:00:03,120
        Primeira frase.

        2
        00:00:03,120 --> 00:00:04,320
        Segunda frase.

        """
        #expect(SubtitleExporter.srt(twoSegments()) == expected)
    }

    @Test func vttFormatHasHeaderAndDots() {
        let expected = """
        WEBVTT

        00:00:00.000 --> 00:00:03.120
        Primeira frase.

        00:00:03.120 --> 00:00:04.320
        Segunda frase.

        """
        #expect(SubtitleExporter.vtt(twoSegments()) == expected)
    }

    @Test func vttOfAnEmptyListIsJustTheHeader() {
        #expect(SubtitleExporter.vtt([]) == "WEBVTT\n")
        #expect(SubtitleExporter.srt([]) == "")
    }

    @Test func timecodeIsWholeMilliseconds() {
        #expect(SubtitleExporter.timecode(0, decimalComma: true) == "00:00:00,000")
        #expect(SubtitleExporter.timecode(3.12, decimalComma: true) == "00:00:03,120")
        #expect(SubtitleExporter.timecode(3.12, decimalComma: false) == "00:00:03.120")
        #expect(SubtitleExporter.timecode(3661.4994, decimalComma: true) == "01:01:01,499")
        // O arredondamento atravessa o segundo: nada de "00:59:60,000".
        #expect(SubtitleExporter.timecode(3599.9995, decimalComma: true) == "01:00:00,000")
        #expect(SubtitleExporter.timecode(-1, decimalComma: true) == "00:00:00,000")
    }

    @Test func cuePayloadKeepsToOneLine() {
        let segments = [EdgeTTS.Segment(start: 0, duration: 1, text: "Uma\nfrase.", index: 0)]
        #expect(SubtitleExporter.srt(segments) == "1\n00:00:00,000 --> 00:00:01,000\nUma frase.\n")
    }

    @Test func cuesComeOutSortedWithIndexAsTiebreak() {
        let segments = [
            EdgeTTS.Segment(start: 5, duration: 1, text: "Terceira.", index: 2),
            EdgeTTS.Segment(start: 1, duration: 1, text: "Primeira.", index: 0),
            EdgeTTS.Segment(start: 1, duration: 1, text: "Empate depois.", index: 1),
        ]
        let srt = SubtitleExporter.srt(segments)
        #expect(srt.hasPrefix("1\n00:00:01,000 --> 00:00:02,000\nPrimeira."))
        #expect(srt.contains("2\n00:00:01,000 --> 00:00:02,000\nEmpate depois."))
        #expect(srt.hasSuffix("3\n00:00:05,000 --> 00:00:06,000\nTerceira.\n"))
        // Sem tempos (todas em zero) o índice é a única ordem que significa algo.
        let untimed = [
            EdgeTTS.Segment(start: 0, duration: 0, text: "Segunda.", index: 1),
            EdgeTTS.Segment(start: 0, duration: 0, text: "Primeira.", index: 0),
        ]
        #expect(SubtitleExporter.srt(untimed).hasPrefix("1\n00:00:00,000 --> 00:00:00,000\nPrimeira."))
    }

    @Test func jsonIsStableSortedAndCarriesWordsWhenTheyExist() throws {
        let once = SubtitleExporter.json(twoSegments())
        let twice = SubtitleExporter.json(twoSegments())
        #expect(once == twice, "a mesma entrada tem de dar os mesmos bytes")

        let cues = try #require(
            JSONSerialization.jsonObject(with: Data(once.utf8)) as? [[String: Any]])
        #expect(cues.count == 2)
        #expect(cues[0]["text"] as? String == "Primeira frase.")
        #expect(cues[0]["start"] as? Double == 0)
        #expect(cues[0]["duration"] as? Double == 3.12)
        #expect(cues[0]["index"] as? Int == 0)
        #expect(cues[0]["page"] as? Int == 3)
        let words = try #require(cues[0]["words"] as? [[String: Any]])
        #expect(words.count == 2)
        #expect(words[1]["text"] as? String == "frase.")
        #expect(words[1]["start"] as? Double == 0.5)
        // Segunda frase sem tempos de palavra: `words` AUSENTE, não vazio.
        #expect(cues[1]["words"] == nil)
        #expect(cues[1]["page"] == nil)

        // Chaves ordenadas (JSONEncoder.sortedKeys): duration < index < page < start < text < words.
        let duration = try #require(once.range(of: "\"duration\""))
        let start = try #require(once.range(of: "\"start\""))
        let text = try #require(once.range(of: "\"text\""))
        let wordKey = try #require(once.range(of: "\"words\""))
        #expect(duration.lowerBound < start.lowerBound)
        #expect(start.lowerBound < text.lowerBound)
        #expect(text.lowerBound < wordKey.lowerBound)
    }

    @Test func jsonOmitsTheIndexWhenItIsUnknown() throws {
        let segments = [EdgeTTS.Segment(start: 0, duration: 1, text: "Sem índice.")]
        let cues = try #require(
            JSONSerialization.jsonObject(with: Data(SubtitleExporter.json(segments).utf8))
                as? [[String: Any]])
        #expect(cues[0]["index"] == nil)
        #expect(cues[0]["text"] as? String == "Sem índice.")
    }

    @Test func jsonOfAnEmptyListIsAnEmptyArray() {
        #expect(SubtitleExporter.json([]) == "[]\n")
    }

    @Test func sidecarNamesDeriveFromTheExportedAudio() {
        let audio = URL(fileURLWithPath: "/tmp/leitura.mp3")
        #expect(SubtitleExporter.sidecarURL(for: audio, format: .srt).path == "/tmp/leitura.srt")
        #expect(SubtitleExporter.sidecarURL(for: audio, format: .vtt).path == "/tmp/leitura.vtt")
        #expect(SubtitleExporter.sidecarURL(for: audio, format: .json).path == "/tmp/leitura.json")
        // WAV offline e um nome sem extensão caem no mesmo lugar.
        #expect(
            SubtitleExporter.sidecarURL(for: URL(fileURLWithPath: "/tmp/a/b.wav"), format: .srt).path
                == "/tmp/a/b.srt")
        #expect(
            SubtitleExporter.sidecarURL(for: URL(fileURLWithPath: "/tmp/sem"), format: .json).path
                == "/tmp/sem.json")
    }

    @Test func writeBesidePutsTheThreeFilesNextToTheAudio() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaneExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("leitura.mp3")
        try Data("audio".utf8).write(to: audio)

        let wrote = try SubtitleExporter.writeBeside(twoSegments(), audio: audio)
        #expect(wrote)
        let srt = dir.appendingPathComponent("leitura.srt")
        let vtt = dir.appendingPathComponent("leitura.vtt")
        let json = dir.appendingPathComponent("leitura.json")
        #expect(FileManager.default.fileExists(atPath: srt.path))
        #expect(FileManager.default.fileExists(atPath: vtt.path))
        #expect(FileManager.default.fileExists(atPath: json.path))
        #expect(try String(contentsOf: srt, encoding: .utf8) == SubtitleExporter.srt(twoSegments()))
        #expect(try String(contentsOf: vtt, encoding: .utf8) == SubtitleExporter.vtt(twoSegments()))
        #expect(try String(contentsOf: json, encoding: .utf8) == SubtitleExporter.json(twoSegments()))
        // O áudio exportado não é tocado pela serialização.
        #expect(try String(contentsOf: audio, encoding: .utf8) == "audio")
    }

    @Test func writeBesideWritesNothingWithoutTimes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaneExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("leitura.wav")
        try Data("audio".utf8).write(to: audio)

        let wrote = try SubtitleExporter.writeBeside([], audio: audio)
        #expect(!wrote)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(entries == ["leitura.wav"], "sem tempos, nenhum arquivo lateral")
    }

    /// A serialização serve à exportação E ao catálogo: as chaves de status
    /// novas existem nos dois idiomas com os marcadores no lugar (a
    /// completude do catálogo tem suíte própria; aqui se garante que a
    /// exportação não cai no fallback).
    @Test func exportStatusKeysExistInBothLanguages() {
        for key in ["status.audioWithTimes", "status.audioTimesFailed"] {
            #expect(L.get(key, locale: .pt, args: "leitura.mp3", "sem espaço")
                != key, "sem PT: \(key)")
            #expect(L.get(key, locale: .en, args: "leitura.mp3", "sem espaço")
                != key, "sem EN: \(key)")
        }
        #expect(L.get("status.audioWithTimes", locale: .pt, args: "leitura.mp3")
            .contains("leitura.mp3"))
        #expect(L.get("status.audioTimesFailed", locale: .pt, args: "leitura.mp3", "disco cheio")
            .contains("disco cheio"))
    }
}
