import Foundation
import Testing

@testable import EdgeSpeak

/// Completude do catálogo PT/EN: nenhuma chave sem par e nenhum padrão com
/// furos entre os idiomas. A fase 2 troca o idioma em tempo real; um `{0}`
/// faltando no EN quebraria a frase na cara do usuário.
struct L10nCompletenessTests {
    /// Toda chave PT tem EN e vice-versa.
    @Test func chavesIguaisNosDoisIdiomas() {
        let pt = Set(L.pt.keys)
        let en = Set(L.en.keys)
        #expect(pt == en, "sem EN: \(pt.subtracting(en).sorted()); sem PT: \(en.subtracting(pt).sorted())")
    }

    /// Nenhum texto vazio nos dois idiomas.
    @Test func nenhumTextoVazio() {
        for (chave, valor) in L.pt {
            #expect(!valor.isEmpty, "PT vazio: \(chave)")
        }
        for (chave, valor) in L.en {
            #expect(!valor.isEmpty, "EN vazio: \(chave)")
        }
    }

    /// Os marcadores `{n}` de cada chave são os mesmos em PT e EN (mesma
    /// aridade, para o `L.get` da fase 2 interpolar igual nos dois).
    @Test func marcadoresIguaisNosDoisIdiomas() {
        for (chave, textoPT) in L.pt {
            guard let textoEN = L.en[chave] else {
                #expect(Bool(false), "sem EN: \(chave)")
                continue
            }
            #expect(
                marcadores(de: textoPT) == marcadores(de: textoEN),
                "marcadores divergem: \(chave)")
        }
    }

    /// Nenhum resto de interpolação Swift `\(` escapou para o catálogo (o
    /// padrão usa `{n}`, nunca `\(…)`).
    @Test func semInterpolacaoSwiftNoCatalogo() {
        for (chave, valor) in L.pt {
            #expect(!valor.contains("\\("), "PT com \\(: \(chave)")
        }
        for (chave, valor) in L.en {
            #expect(!valor.contains("\\("), "EN com \\(: \(chave)")
        }
    }

    /// Amostra das chaves que a fase 2 vai resolver via `L.get`: todas
    /// existem e voltam sem cair no fallback da própria chave.
    @Test func chavesDaFase2Existem() {
        let amostra = [
            "status.playing", "status.paused", "status.finished",
            "status.synthesizing", "status.openFailed", "status.fileLoaded",
            "ui.openFile", "ui.followReading", "ui.settings",
            "player.play", "player.pause", "player.charCount",
            "settings.rateLabel", "settings.fontSize",
            "progress.chunkFraction", "error.synthesisFailed",
            "rate.normal", "section.english",
            "voice.en-US-AndrewNeural", "voice.offline-faber-ptbr",
        ]
        for chave in amostra {
            #expect(L.get(chave, locale: .pt) == L.pt[chave], "sem PT: \(chave)")
            #expect(L.get(chave, locale: .en) == L.en[chave], "sem EN: \(chave)")
        }
    }

    /// Lê os índices dos marcadores `{n}` de um padrão, em ordem.
    private func marcadores(de texto: String) -> [Int] {
        var achados: [Int] = []
        var resto = texto[...]
        while let abre = resto.firstIndex(of: "{") {
            let depois = resto[resto.index(after: abre)...]
            if let fecha = depois.firstIndex(of: "}"),
               let n = Int(depois[..<fecha]) {
                achados.append(n)
            }
            resto = resto[resto.index(after: abre)...]
        }
        return achados.sorted()
    }
}
