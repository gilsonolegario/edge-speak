import Foundation
import CryptoKit

/// Cache em disco da síntese: chave = hash(texto+voz+cadência).
///
/// Guarda o MP3 final + os segmentos globais. Reabrir o mesmo PDF com a mesma
/// voz e cadência toca sem rede. Vive em Caches (não no temporário, que o
/// motor limpa a cada síntese).
enum CacheDisco {
    struct Hit: Sendable {
        let audioURL: URL
        let segments: [EdgeTTS.Segment]
    }

    /// Chave estável para (texto, voz, cadência).
    ///
    /// `v2` invalida o cache gravado antes do karaokê: aqueles segmentos não
    /// têm `words`, e reaproveitá-los calaria o destaque por palavra para
    /// sempre no mesmo documento.
    static func key(text: String, voice: String, rate: EdgeTTS.Rate) -> String {
        let raw = "v2|\(voice)|\(rate.percent)|\(text)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeSpeak", isDirectory: true)
    }

    private static let lock = NSLock()
    private static var lastPrune = Date.distantPast

    /// Teto do cache: entradas mais velhas que isso saem, mesmo com espaço.
    /// 30 dias cobre releituras do mesmo PDF no mês sem guardar para sempre.
    private static let maxAge: TimeInterval = 30 * 24 * 3_600
    /// Teto do cache: acima disso, saem as mais antigas primeiro.
    /// 2 GB ≈ dezenas de audiobooks médios; abaixo do que lotaria o disco.
    private static let maxTotalBytes: Int = 2 * 1_024 * 1_024 * 1_024
    /// Poda cara (varre o diretório): no máximo uma vez por execução/minuto.
    private static let pruneInterval: TimeInterval = 60
    /// Margem anti-piso: nunca remove entrada gravada há menos que isso,
    /// mesmo que o total estoure — protege a leitura corrente.
    private static let gracePeriod: TimeInterval = 60

    private static func paths(for key: String) -> (audio: URL, segments: URL) {
        let base = dir.appendingPathComponent(key, isDirectory: true)
        // Offline guarda WAV concatenado; online, MP3. O manifesto é o mesmo.
        let fm = FileManager.default
        let wav = base.appendingPathComponent("audio.wav")
        let audio = fm.fileExists(atPath: wav.path)
            ? wav : base.appendingPathComponent("audio.mp3")
        return (audio, base.appendingPathComponent("segments.json"))
    }

    /// Devolve o áudio + segmentos guardados, ou nil em qualquer falta.
    static func lookup(key: String) -> Hit? {
        let fm = FileManager.default
        let (audio, json) = paths(for: key)
        guard let size = (try? fm.attributesOfItem(atPath: audio.path))?[.size] as? Int,
              size > 0,
              let data = try? Data(contentsOf: json),
              let segments = try? JSONDecoder().decode([EdgeTTS.Segment].self, from: data),
              !segments.isEmpty
        else { return nil }
        return Hit(audioURL: audio, segments: segments)
    }

    /// Guarda o resultado final. Falha em silêncio: cache é otimização.
    static func store(key: String, audioURL: URL, segments: [EdgeTTS.Segment]) {
        guard !segments.isEmpty else { return }
        let fm = FileManager.default
        // A extensão segue o áudio real (WAV offline, MP3 online); o
        // `lookup` acha qualquer um dos dois pelo mesmo hash texto+voz+rate.
        let base = dir.appendingPathComponent(key, isDirectory: true)
        let ext = audioURL.pathExtension.lowercased() == "wav" ? "wav" : "mp3"
        let audio = base.appendingPathComponent("audio.\(ext)")
        let json = base.appendingPathComponent("segments.json")
        do {
            try fm.createDirectory(
                at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: audio.path) { try fm.removeItem(at: audio) }
            try fm.copyItem(at: audioURL, to: audio)
            let data = try JSONEncoder().encode(segments)
            try data.write(to: json, options: .atomic)
        } catch {
            // Sem cache, só sem atalho: a leitura segue do temporário.
            try? fm.removeItem(at: audio.deletingLastPathComponent())
        }
        schedulePrune(preserving: key)
    }

    /// Remove a entrada da chave (pasta inteira). Falha em silêncio: cache
    /// é otimização, como o resto do tipo.
    static func remove(key: String) {
        let base = dir.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.removeItem(at: base)
    }

    /// Agenda a poda fora da thread corrente e no máximo 1x por minuto.
    private static func schedulePrune(preserving key: String) {
        lock.lock()
        let due = Date().timeIntervalSince(lastPrune) >= pruneInterval
        if due { lastPrune = Date() }
        lock.unlock()
        guard due else { return }
        Task.detached(priority: .background) { prune(preserving: key) }
    }

    /// Remove entradas velhas demais e, acima do teto, as mais antigas.
    /// Nunca toca na chave em uso nem nas gravadas dentro da margem.
    /// Falha em silêncio: cache é otimização, não pode quebrar a leitura.
    private static func prune(preserving currentKey: String) {
        let fm = FileManager.default
        let root = dir
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let now = Date()
        var entries: [(name: String, mtime: Date, size: Int)] = []
        var total = 0
        for name in names {
            if name == currentKey { continue }
            let base = root.appendingPathComponent(name, isDirectory: true)
            guard let mtime = (try? fm.attributesOfItem(atPath: base.path))?[.modificationDate] as? Date
            else { continue }
            if now.timeIntervalSince(mtime) < gracePeriod { continue }
            var size = 0
            if let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in walker {
                    size += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                }
            }
            entries.append((name, mtime, size))
            total += size
        }
        // Primeiro a idade: o que passou de maxAge sai de imediato.
        for e in entries where now.timeIntervalSince(e.mtime) > maxAge {
            try? fm.removeItem(at: root.appendingPathComponent(e.name))
            total -= e.size
        }
        // Depois o tamanho: das mais antigas para as novas até caber no teto.
        if total > maxTotalBytes {
            for e in entries
                .filter({ now.timeIntervalSince($0.mtime) <= maxAge })
                .sorted(by: { $0.mtime < $1.mtime })
            {
                if total <= maxTotalBytes { break }
                try? fm.removeItem(at: root.appendingPathComponent(e.name))
                total -= e.size
            }
        }
    }
}
