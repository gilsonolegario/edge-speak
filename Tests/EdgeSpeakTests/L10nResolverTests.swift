import Foundation
import Testing

@testable import EdgeSpeak

/// Resolvedor de padrão do `L.get`: interpolação posicional e fallback.
/// Sem rede nem áudio — só o catálogo em memória.
struct L10nResolverTests {
    /// Sem `locale`, o padrão é português (comportamento atual).
    @Test func padraoEPortugues() {
        #expect(L.get("status.playing") == "Tocando…")
        #expect(L.padrao == .pt)
    }

    /// Com `.en`, volta o texto inglês quando a chave existe.
    @Test func inglesQuandoHaChave() {
        #expect(L.get("status.playing", locale: .en) == "Playing…")
    }

    /// Um argumento ocupa o `{0}`.
    @Test func interpolaUmArgumento() {
        #expect(L.get("status.openFailed", args: "fim.pdf") == "Falha ao abrir: fim.pdf")
    }

    /// Vários argumentos ocupam `{0}`, `{1}`… em ordem, nos dois idiomas.
    @Test func interpolaVariosArgumentos() {
        #expect(L.get("status.fileLoaded", args: "tese.pdf", 4120) == "Arquivo carregado: tese.pdf (4120 caracteres).")
        #expect(L.get("progress.chunkFraction", locale: .en, args: 3, 12) == "Synthesizing 3/12…")
    }

    /// Sem a chave no EN, cai para o PT (com interpolação aplicada).
    @Test func caiParaPortuguesQuandoFaltaIngles() {
        let tabelas: [L.Idioma: [String: String]] = [
            .pt: ["só.pt": "Só em PT {0}"],
            .en: [:],
        ]
        #expect(L.resolve("só.pt", locale: .en, args: ["X"], tabelas: tabelas) == "Só em PT X")
    }

    /// Sem a chave em nenhum idioma, devolve a própria chave (nunca vazio).
    @Test func chaveDesconhecidaDevolveAChave() {
        #expect(L.get("chave.que.nao.existe", locale: .en) == "chave.que.nao.existe")
    }

    /// Argumento a mais não quebra a frase.
    @Test func argumentoExtraNaoQuebra() {
        #expect(L.get("status.playing", args: "sobra") == "Tocando…")
    }

    /// Chave do `@AppStorage` de idioma e seu padrão (PT).
    @Test func chaveDeIdiomaEDefault() {
        #expect(AppSetting.languageKey == "appLanguage")
        #expect(AppSetting.languageDefault == "pt")
    }
}
