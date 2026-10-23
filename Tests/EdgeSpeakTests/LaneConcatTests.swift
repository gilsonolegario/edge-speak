import Foundation
import Testing

@testable import EdgeSpeak

/// Robustez dos motores — lane própria: itens 46 e 47 do plano.
///
/// Item 46 (`concatWavs` manual, sem ffmpeg): a medição de pico de RSS e a
/// prova de que a escrita em blocos produz bytes idênticos à versão antiga.
/// O host de desenvolvimento TEM ffmpeg (`/opt/homebrew/bin/ffmpeg`), então o
/// caminho manual nunca é alcançado por `concatWavs` aqui — daí o caminho
/// manual ser uma função interna e testada direto, e a versão antiga viver
/// neste arquivo como referência.
///
/// Item 47 (frase gigante offline): o fatiamento acima do cap, puro e medido
/// ao vivo (`LANE47_LIVE=1`).
///
/// Medições registradas (2026-10-18, Mac mini `issoeocios-Mac-mini.local`,
/// macOS 27.2, SwiftPM debug; parte das medições com load ~4-5 de outras lanes,
/// o que INFLA os tempos absolutos — a relação entre os números é o que vale):
///
/// * Item 46 — pico de RSS do processo (`getrusage(RUSAGE_SELF).ru_maxrss`,
///   delta medido em volta da chamada; `LANE46_MB` e `LANE46_IMPL` escolhem o
///   caso, ver `concatByHandPeakRSS`), 40 WAVs sintéticos:
///     20 MiB de PCM ⇒ antigo 44.613.632 B (2,13× o PCM) × novo 950.272 B;
///     200 MiB de PCM ⇒ antigo 430.145.536 B (2,05× o PCM) × novo 884.736 B.
///   O fator ~2× da hipótese do plano está confirmado, e o pico do antigo
///   cresce com o PCM (nas 5 h da auditoria, ~1,6 GB deixa de ser inferência);
///   o novo é constante (~0,9 MB) — o plano manda reescrever, e foi o que se
///   fez.
/// * Item 47 — tempo de UMA requisição ao Piper (`pt_BR-faber-medium`, voz já
///   carregada, texto sem pontuação): medido rodando `Tools/piper_synth.py
///   --onnx …/voices/pt_BR-faber-medium.onnx` e enviando um pedido JSON por
///   comprimento, cronometrando a resposta (o mesmo protocolo do app):
///     300 ⇒ 0,75 s · 900 ⇒ 1,97 s · 1800 ⇒ 4,73 / 4,75 / 5,07 / 5,18 / 5,21 /
///     5,32 s · 3600 ⇒ 20,17 s e 24,11 s · 5400 ⇒ 98,37 s · 7200 ⇒ 579,60 s.
///   O crescimento é superlinear (o áudio é linear; o TEMPO não), e o prazo de
///   300 s de `PiperSession.synth` é cruzado entre 5400 e 7200 caracteres — no
///   cruzamento a sessão é morta e a leitura inteira morre com
///   `offlineTimeout`, exatamente o sintoma do item 47. Os mesmos 7200 em 4
///   requisições de 1800 ⇒ 20,0 s, cada uma a ~5 s do prazo.
struct LaneConcatTests {

    // MARK: - Item 46: the manual writer as it was, kept as reference

    /// The manual join as it was BEFORE item 46: the whole PCM of every file
    /// assembled in a single `Data`, then copied again into `final`. Kept here
    /// (and not in the source) because it is the reference the byte-identity
    /// test compares against — the source no longer carries the memory bug.
    static func referenceByHand(_ ordered: [URL], into outURL: URL) throws -> URL {
        var pcm = Data()
        var headerSize: Data?
        var dataOffset = 0
        for url in ordered {
            let data = try Data(contentsOf: url)
            guard let layout = PiperTTS.wavLayout(data), data.count > layout.dataOffset else {
                throw TestFailure("invalid wav in the reference join")
            }
            if headerSize == nil {
                headerSize = data.prefix(layout.dataOffset)
                dataOffset = layout.dataOffset
            }
            pcm.append(data.suffix(from: layout.dataOffset))
        }
        guard var head = headerSize else { throw TestFailure("empty reference join") }
        func writeU32(_ v: UInt32, within o: Int) {
            head[o] = UInt8(v & 0xFF)
            head[o + 1] = UInt8((v >> 8) & 0xFF)
            head[o + 2] = UInt8((v >> 16) & 0xFF)
            head[o + 3] = UInt8((v >> 24) & 0xFF)
        }
        writeU32(UInt32(pcm.count + head.count - 8), within: 4)
        writeU32(UInt32(pcm.count), within: dataOffset - 4)
        try? FileManager.default.removeItem(at: outURL)
        var final = head
        final.append(pcm)
        try final.write(to: outURL, options: .atomic)
        return outURL
    }

    struct TestFailure: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: - Synthetic WAVs

    /// Canonical mono/22050 Hz/16-bit WAV written in blocks: the PCM of the
    /// INPUT never sits in memory whole (otherwise the measurement would blame
    /// the fixture instead of the joiner). `extraChunk` inserts a `LIST` chunk
    /// between `fmt ` and `data`, which pushes `dataOffset` past 44 — the case
    /// B3 fixed and the joiner must keep carrying.
    @discardableResult
    static func makeWav(
        at url: URL, pcmBytes: Int, fill: UInt8, extraChunk: Int = 0
    ) throws -> Int {
        var head = Data()
        head.append(contentsOf: Array("RIFF".utf8))
        var afterRIFF = UInt32(0)          // size field, patched at the end
        head.append(contentsOf: [0, 0, 0, 0])
        head.append(contentsOf: Array("WAVE".utf8))
        head.append(contentsOf: Array("fmt ".utf8))
        head.append(contentsOf: u32(16))
        head.append(contentsOf: u16(1))     // PCM
        head.append(contentsOf: u16(1))     // mono
        head.append(contentsOf: u32(22050))
        head.append(contentsOf: u32(44100)) // byte rate
        head.append(contentsOf: u16(2))     // block align
        head.append(contentsOf: u16(16))    // bits
        if extraChunk > 0 {
            head.append(contentsOf: Array("LIST".utf8))
            head.append(contentsOf: u32(UInt32(extraChunk)))
            head.append(Data(repeating: 0x20, count: extraChunk))
        }
        head.append(contentsOf: Array("data".utf8))
        head.append(contentsOf: u32(UInt32(pcmBytes)))
        afterRIFF = UInt32(head.count - 8 + pcmBytes)
        head[4] = UInt8(afterRIFF & 0xFF)
        head[5] = UInt8((afterRIFF >> 8) & 0xFF)
        head[6] = UInt8((afterRIFF >> 16) & 0xFF)
        head[7] = UInt8((afterRIFF >> 24) & 0xFF)

        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let out = try? FileHandle(forWritingTo: url)
        else { throw TestFailure("cannot create \(url.lastPathComponent)") }
        try out.write(contentsOf: head)
        let block = Data(repeating: fill, count: min(1 << 20, max(1, pcmBytes)))
        var remaining = pcmBytes
        while remaining > 0 {
            let n = min(block.count, remaining)
            try out.write(contentsOf: block.prefix(n))
            remaining -= n
        }
        try out.close()
        return head.count + pcmBytes
    }

    static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    static func scratchDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane46-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Item 46: byte identity

    @Test func concatByHandMatchesTheOldWriter() throws {
        let dir = try Self.scratchDir("identity")
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for (i, pcm) in [2000, 4002, 96, 1234].enumerated() {
            let url = dir.appendingPathComponent("in-\(i).wav")
            try Self.makeWav(at: url, pcmBytes: pcm, fill: UInt8(0x10 + i))
            urls.append(url)
        }
        let old = dir.appendingPathComponent("old.wav")
        let new = dir.appendingPathComponent("new.wav")
        _ = try Self.referenceByHand(urls, into: old)
        _ = try PiperTTS.concatWavsByHand(urls, into: new)
        let oldBytes = try Data(contentsOf: old)
        let newBytes = try Data(contentsOf: new)
        #expect(oldBytes == newBytes)
        // The header carries the recalculated sizes: total = old 44-byte header
        // + every file's PCM.
        #expect(newBytes.count == 44 + 2000 + 4002 + 96 + 1234)
        #expect(PiperTTS.wavLayout(newBytes)?.dataSize == 2000 + 4002 + 96 + 1234)
    }

    @Test func concatByHandKeepsTheExtraChunkOfTheFirstFile() throws {
        let dir = try Self.scratchDir("extra")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("in-0.wav")
        let second = dir.appendingPathComponent("in-1.wav")
        // 10 bytes of LIST push the first file's data to offset 58; the second
        // file's own header (canonical, 44) is dropped.
        try Self.makeWav(at: first, pcmBytes: 512, fill: 0xAB, extraChunk: 10)
        try Self.makeWav(at: second, pcmBytes: 256, fill: 0xCD)
        let old = dir.appendingPathComponent("old.wav")
        let new = dir.appendingPathComponent("new.wav")
        _ = try Self.referenceByHand([first, second], into: old)
        _ = try PiperTTS.concatWavsByHand([first, second], into: new)
        let oldBytes = try Data(contentsOf: old)
        #expect(oldBytes == (try Data(contentsOf: new)))
        let layout = try #require(PiperTTS.wavLayout(oldBytes))
        #expect(layout.dataOffset == 62)
        #expect(layout.dataSize == 512 + 256)
    }

    /// The block loop must not lose or duplicate a byte when the input crosses
    /// several 1 MiB blocks — the write side of the identity test.
    @Test func concatByHandCrossesBlockBoundariesWithoutLoss() throws {
        let dir = try Self.scratchDir("blocks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.wav")
        let b = dir.appendingPathComponent("b.wav")
        try Self.makeWav(at: a, pcmBytes: (1 << 20) + 3, fill: 0x5A)
        try Self.makeWav(at: b, pcmBytes: (1 << 20) + 511, fill: 0xA5)
        let out = dir.appendingPathComponent("joined.wav")
        _ = try PiperTTS.concatWavsByHand([a, b], into: out)
        let bytes = try Data(contentsOf: out)
        #expect(bytes.count == 44 + (1 << 20) + 3 + (1 << 20) + 511)
        // First block byte of each source survives at its exact offset.
        let dataStart = try #require(PiperTTS.wavLayout(bytes)?.dataOffset)
        #expect(bytes[dataStart] == 0x5A)
        #expect(bytes[dataStart + (1 << 20) + 3] == 0xA5)
    }

    @Test func concatByHandRefusesEmptyAndNonWav() throws {
        let dir = try Self.scratchDir("guards")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.wav")
        #expect(throws: (any Error).self) {
            _ = try PiperTTS.concatWavsByHand([], into: out)
        }
        let bogus = dir.appendingPathComponent("bogus.wav")
        try Data(repeating: 0x00, count: 4096).write(to: bogus)
        #expect(throws: (any Error).self) {
            _ = try PiperTTS.concatWavsByHand([bogus], into: out)
        }
        // A failed join never leaves a half-written output behind.
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - Item 46: the measurement

    static func peakRSSBytes() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss            // bytes on Darwin
    }

    /// Measurement harness, not an assertion: runs only when the environment
    /// asks for it, so the suite stays fast and the number is comparable
    /// between runs.
    ///
    ///     LANE46_MB=20  LANE46_IMPL=ref  swift test --filter concatByHandPeakRSS
    ///     LANE46_MB=20  LANE46_IMPL=new  swift test --filter concatByHandPeakRSS
    ///
    /// `LANE46_MB` is the total PCM across `LANE46_FILES` synthetic WAVs;
    /// `ru_maxrss` is the process peak, read AFTER the fixtures are on disk
    /// (so the fixture build is inside the baseline) and after the join.
    @Test func concatByHandPeakRSS() throws {
        let env = ProcessInfo.processInfo.environment
        guard let mbText = env["LANE46_MB"], let mb = Int(mbText), mb > 0 else { return }
        let impl = env["LANE46_IMPL"] ?? "new"
        let files = Int(env["LANE46_FILES"] ?? "") ?? 40
        let per = ((mb * 1024 * 1024) / files) & ~0x7   // even PCM, byte-aligned
        let dir = try Self.scratchDir("peak-\(impl)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        var inputBytes = 0
        for i in 0..<files {
            let url = dir.appendingPathComponent(String(format: "in-%03d.wav", i))
            inputBytes += try Self.makeWav(at: url, pcmBytes: per, fill: UInt8(i & 0xFF))
            urls.append(url)
        }
        let out = dir.appendingPathComponent("joined.wav")
        let baseline = Self.peakRSSBytes()
        if impl == "ref" {
            _ = try Self.referenceByHand(urls, into: out)
        } else {
            _ = try PiperTTS.concatWavsByHand(urls, into: out)
        }
        let peak = Self.peakRSSBytes()
        let outSize = (try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int ?? 0
        let pcm = inputBytes - 44 * files
        print("LANE46 impl=\(impl) files=\(files) pcmBytes=\(pcm) inputBytes=\(inputBytes) "
            + "baselineRSS=\(baseline) peakRSS=\(peak) delta=\(peak - baseline) "
            + "ratio=\(String(format: "%.2f", Double(peak - baseline) / Double(pcm))) outBytes=\(outSize)")
        #expect(outSize == pcm + 44)
    }

    // MARK: - Item 47: the slicing plan

    @Test func speechPiecesBelowTheCapKeepsTheTextWhole() {
        let text = "uma frase curta com acentuacao e espacos"
        #expect(PiperTTS.speechPieces(for: text, maxChars: 1800) == [text])
        // Exactly at the cap is NOT above it: the normal path has to stay one
        // request, byte for byte, or every reading would change.
        let exact = String(repeating: "a", count: 40)
        #expect(PiperTTS.speechPieces(for: exact, maxChars: 40) == [exact])
    }

    @Test func speechPiecesSplitsRightAboveTheCap() {
        let text = "aliqua tempor"                       // 13 chars
        let pieces = PiperTTS.speechPieces(for: text, maxChars: 10)
        #expect(pieces == ["aliqua", "tempor"])
        #expect(pieces.allSatisfy { $0.count <= 10 })
    }

    /// One word above the cap has no whitespace to cut at: it is cut anyway —
    /// the request that would run past the deadline is worse than a word split.
    @Test func speechPiecesCutsAnOversizedWord() {
        let pieces = PiperTTS.speechPieces(for: "abcdefghijkl", maxChars: 5)
        #expect(pieces == ["abcde", "fghij", "kl"])
        #expect(pieces.allSatisfy { $0.count <= 5 })
    }

    /// The plan the reading follows: every request at or under the cap, the
    /// words in the original order and none lost or duplicated — the sentence
    /// is read whole, only in more than one request.
    @Test func speechPiecesKeepEveryWordInOrderUnderTheCap() {
        let words = (0..<400).map { "palavra\($0 % 7)" }
        let text = words.joined(separator: " ")
        let pieces = PiperTTS.speechPieces(for: text, maxChars: 200)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 200 })
        #expect(pieces.joined(separator: " ") == text)
        #expect(pieces.flatMap { $0.split(separator: " ") } == words.map { Substring($0) })
    }

    /// Whitespace-only text has no word to pack: the split returns nothing, and
    /// an empty plan would leave the phrase without its WAV (the join of the
    /// reading would die on a missing file). Falls back to the whole text, which
    /// is exactly what this path did before item 47.
    @Test func speechPiecesFallsBackWhenThereIsNoWordToSplit() {
        let blanks = String(repeating: " ", count: 50)
        #expect(PiperTTS.speechPieces(for: blanks, maxChars: 10) == [blanks])
    }

    // MARK: - Item 47: live smoke (model + venv on this machine)

    /// Runs only with `LANE47_LIVE=1`: it synthesizes for real with the local
    /// Piper voice (`~/Library/Application Support/EdgeSpeak/voices`), so the
    /// suite stays network-free and fast by default.
    ///
    /// What it proves: (a) a sentence above the cap no longer kills the reading
    /// — the same `synthesizeStreaming` that used to die with `offlineTimeout`
    /// now delivers the sentence's WAV and its segment, sliced in sequence;
    /// (b) the manual join, on GENUINE Piper WAVs (not fixtures), reproduces the
    /// sum of the parts' durations.
    @Test func liveGiantSentenceIsSlicedAndJoined() async throws {
        guard ProcessInfo.processInfo.environment["LANE47_LIVE"] == "1" else { return }
        let fm = FileManager.default
        guard let voice = PiperTTS.offlineVoices.first(where: { file in
            voiceFileExists(file, in: fm)
        }) else { return }
        let shortA = TextImport.Phrase(index: 0, text: "primeira frase curta.", page: 1, rects: [])
        let shortB = TextImport.Phrase(index: 1, text: "segunda frase curta.", page: 1, rects: [])
        // No punctuation: the single runaway sentence of item 47, above the cap.
        let giantText = String(repeating: "texto corrido sem pontuacao alguma ", count: 140)
        let giant = TextImport.Phrase(index: 2, text: giantText, page: 2, rects: [])
        #expect(giantText.count > PiperTTS.maxPhraseChars)
        #expect(PiperTTS.speechPieces(for: giantText).count > 1)

        var chunks: [(Int, URL)] = []
        var final: EdgeTTS.Result?
        let stream = PiperTTS.synthesizeStreaming(
            phrases: [shortA, shortB, giant], voice: voice, locale: .pt
        ) { _ in }
        for try await event in stream {
            switch event {
            case .chunk(let index, let url, _): chunks.append((index, url))
            case .final(let result): final = result
            }
        }
        let result = try #require(final)
        defer {
            PiperTTS.stopActiveSession()
            try? fm.removeItem(at: result.audioURL.deletingLastPathComponent())
        }
        #expect(chunks.count == 3)
        #expect(result.segments.count == 3)
        let giantSegment = try #require(result.segments.last)
        let firstSegment = result.segments[0]
        // The giant sentence carries real audio: several times the short one.
        #expect(giantSegment.duration > firstSegment.duration * 3)
        // The offsets advance by the measured durations, in order.
        #expect(abs(giantSegment.start - (result.segments[0].duration + result.segments[1].duration)) < 0.5)

        // Manual join over real Piper output: the whole reading equals the sum
        // of its phrases (nothing inserted, nothing lost).
        let ordered = chunks.sorted { $0.0 < $1.0 }.map(\.1)
        let sum = ordered.compactMap { PiperTTS.duration(of: $0) }.reduce(0, +)
        let manual = result.audioURL.deletingLastPathComponent()
            .appendingPathComponent("manual-join.wav")
        _ = try PiperTTS.concatWavsByHand(ordered, into: manual)
        let joined = try #require(PiperTTS.duration(of: manual))
        print("LANE47 pieces=\(PiperTTS.speechPieces(for: giantText).count) "
            + "giantChars=\(giantText.count) sum=\(String(format: "%.3f", sum)) "
            + "joined=\(String(format: "%.3f", joined)) segments=\(result.segments.count)")
        #expect(abs(joined - sum) < 0.2)
    }

    private func voiceFileExists(_ voice: String, in fm: FileManager) -> Bool {
        guard let file = PiperTTS.voiceFileBase(for: voice) else { return false }
        let onnx = PiperTTS.voicesDir.appendingPathComponent(file + ".onnx")
        let json = PiperTTS.voicesDir.appendingPathComponent(file + ".onnx.json")
        return fm.fileExists(atPath: onnx.path) && fm.fileExists(atPath: json.path)
    }
}
