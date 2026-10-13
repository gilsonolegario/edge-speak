import Testing

@testable import EdgeSpeak

/// Notas de rodapé fim a fim: ligar corpo ao marcador, ler na hora e pular.
///
/// Motivação do dono: o marcador era lido "ponto sete"; anunciado sem o corpo
/// ("nota de rodapé 7" + texto corrido) é promessa sem entrega — engana. Aqui
/// o corpo vai para logo após a frase do marcador (é lido direto), número
/// solto sem corpo é silêncio, e a opção desliga tudo (marcador vira pausa).
@MainActor
struct FootnoteTests {
    private let pt = "pt-BR-FranciscaNeural"
    private let en = "en-US-AndrewNeural"

    private func frase(_ i: Int, _ texto: String, pagina: Int?) -> TextImport.Phrase {
        TextImport.Phrase(index: i, text: texto, page: pagina, rects: [])
    }

    private func fraseSup(_ i: Int, _ texto: String, pagina: Int?, palavras: [(String, Bool)]) -> TextImport.Phrase {
        let caixas = palavras.map { (t, s) in
            TextImport.Phrase.WordBox(text: t, rect: .zero, page: pagina, sup: s)
        }
        return TextImport.Phrase(index: i, text: texto, page: pagina, rects: [], words: caixas)
    }

    /// Corpo na mesma página vai para logo após a frase do marcador, sem o
    /// número e marcado com o número da nota.
    @Test func corpoVaiParaAposOMarcador() {
        let lista = [
            frase(0, "argumento.7 segue aqui", pagina: 0),
            frase(1, "outra frase no meio", pagina: 0),
            frase(2, "7 Autores afirmam isto aqui", pagina: 0),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(fora.map(\.index) == [0, 2, 1])
        #expect(fora[1].text == "Autores afirmam isto aqui")
        #expect(fora[1].notaNumero == 7)
    }

    /// Notas de fim (corpo páginas depois) ligam ao marcador anterior mais
    /// próximo no documento.
    @Test func notaDeFimLigaAtras() {
        let lista = [
            frase(0, "tese.3 defendida", pagina: 0),
            frase(1, "meio do texto", pagina: 1),
            frase(2, "3 Referência completa aqui", pagina: 5),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(fora.map(\.index) == [0, 2, 1])
        #expect(fora[1].notaNumero == 3)
    }

    /// Número solto com página (rótulo sem corpo, como os "1".."15" do artigo
    /// de teste) é descartado — lido, viraria "um". Sem página (editor),
    /// fica intacto.
    @Test func numeroSoltoCaiSoComPagina() {
        let comPagina = [frase(0, "15", pagina: 2), frase(1, "texto", pagina: 2)]
        #expect(TextImport.resolveFootnotes(comPagina).map(\.index) == [1])
        let semPagina = [frase(0, "15", pagina: nil)]
        #expect(TextImport.resolveFootnotes(semPagina).count == 1)
    }

    /// Sem marcador, o corpo fica intacto onde está (pode ser data: mexer
    /// seria corrupção).
    @Test func semMarcadorNaoMoveNemTiraNumero() {
        let lista = [frase(0, "9 Texto longo sem marcador por aqui", pagina: 4)]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(fora.count == 1)
        #expect(fora[0].text == "9 Texto longo sem marcador por aqui")
        #expect(fora[0].notaNumero == nil)
    }

    /// Os índices das frases que ficam não mudam (são propriedade, não
    /// posição) — destaque e salto seguem valendo após a resolução.
    @Test func indicesPreservados() {
        let lista = [
            frase(0, "abertura.4 aqui", pagina: 0),
            frase(1, "4 Corpo longo da nota aqui", pagina: 0),
            frase(2, "fecho", pagina: 0),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(Set(fora.map(\.index)) == [0, 1, 2])
        #expect(fora.map(\.index) == [0, 1, 2])
    }

    /// Opção desligada: o marcador vira pausa (sem "nota de rodapé").
    @Test func opcaoDesligadaCalaOMarcador() {
        let calado = ReadAloudFilter.forSpeech("argumento.7 segue", voice: pt, lêNotas: false)
        #expect(!calado.contains("nota de rodapé"))
        #expect(calado.contains("argumento"))
        #expect(calado.contains("segue"))
    }

    /// Opção ligada (default): anuncia nos dois idiomas.
    @Test func opcaoLigadaAnuncia() {
        #expect(ReadAloudFilter.forSpeech("argumento.7 segue", voice: pt).contains("nota de rodapé 7"))
        #expect(ReadAloudFilter.forSpeech("argumento.7 segue", voice: en).contains("footnote 7"))
    }

    /// Texto acadêmico pressupõe nota anunciada: default ligado.
    @Test func defaultLeNotas() {
        #expect(AppSetting.footnoteDefault == true)
    }

    /// Sinal geométrico vence: marcador sobrescrito liga o corpo mesmo sem
    /// cola textual (".7"/",7"/"o7") na frase.
    @Test func marcadorSobrescritoLigaSemColaTextual() {
        let lista = [
            fraseSup(0, "argumento segue aqui", pagina: 0, palavras: [("argumento", false), ("7", true), ("segue", false)]),
            frase(1, "outra frase no meio", pagina: 0),
            frase(2, "7 Autores afirmam isto aqui", pagina: 0),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(fora.map(\.index) == [0, 2, 1])
        #expect(fora[1].notaNumero == 7)
    }

    /// Sobrescrito com número diverso não casa (não vira marcador da nota).
    @Test func sobrescritoDeOutroNumeroNaoCasa() {
        let lista = [
            fraseSup(0, "argumento segue aqui", pagina: 0, palavras: [("argumento", false), ("8", true)]),
            frase(1, "7 Autores afirmam isto aqui", pagina: 0),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(fora.count == 2)
        #expect(fora[1].notaNumero == nil)
        #expect(fora[1].text.hasPrefix("7 "))
    }

    /// Palavra não sobrescrita com o número não é marcador geométrico (a
    /// reserva textual segue valendo só com cola: sem cola, não move).
    @Test func numeroSemSupNaoViraMarcadorGeometrico() {
        let lista = [
            fraseSup(0, "argumento segue aqui", pagina: 0, palavras: [("argumento", false), ("7", false)]),
            frase(1, "7 Autores afirmam isto aqui", pagina: 0),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].notaNumero == nil)
    }
}