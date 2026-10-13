import CoreGraphics
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

    /// Frase com geometria (topo em coords PDFKit, origem embaixo), para os
    /// testes de régua: o que está acima dela é texto corrido.
    private func fraseCaixa(_ i: Int, _ texto: String, pagina: Int?, topo: CGFloat) -> TextImport.Phrase {
        TextImport.Phrase(
            index: i, text: texto, page: pagina,
            rects: [CGRect(x: 100, y: topo - 10, width: 300, height: 10)])
    }

    /// Com régua, data acima dela fica intacta mesmo com marcador por perto;
    /// só o corpo abaixo liga.
    @Test func reguaSeparaDataDeCorpo() {
        let regras: [Int: CGFloat] = [0: 100]
        let lista = [
            fraseCaixa(0, "tese aqui.12", pagina: 0, topo: 500),
            fraseCaixa(1, "12 de outubro de 2026 registra o fato aqui", pagina: 0, topo: 400),
            fraseCaixa(2, "12 Corpo longo da nota aqui", pagina: 0, topo: 50),
        ]
        let fora = TextImport.resolveFootnotes(lista, regras: regras)
        #expect(fora.map(\.index) == [0, 2, 1])
        #expect(fora[1].notaNumero == 12)
        #expect(fora[2].text == "12 de outubro de 2026 registra o fato aqui")
        #expect(fora[2].notaNumero == nil)
    }

    /// Com régua, número solto acima dela é conteúdo e fica; abaixo, some.
    @Test func reguaNumeroSolto() {
        let regras: [Int: CGFloat] = [0: 100]
        let acima = TextImport.resolveFootnotes(
            [fraseCaixa(0, "7", pagina: 0, topo: 500)], regras: regras)
        #expect(acima.count == 1)
        let abaixo = TextImport.resolveFootnotes(
            [fraseCaixa(0, "7", pagina: 0, topo: 50)], regras: regras)
        #expect(abaixo.isEmpty)
    }

    /// Sem régua (JSON antigo, via sem Python), vale a heurística de sempre.
    @Test func semReguaHeuristica() {
        let lista = [
            frase(0, "tese aqui.5", pagina: 0),
            frase(1, "5 Corpo longo da nota aqui", pagina: 0),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].notaNumero == 5)
    }

    /// Várias notas sob a mesma régua: a ligada move, a sem marcador fica
    /// sem número e marcada (não é lida como texto corrido).
    @Test func variasNotasSobRegua() {
        let regras: [Int: CGFloat] = [0: 100]
        let lista = [
            fraseCaixa(0, "tese aqui.7", pagina: 0, topo: 500),
            fraseCaixa(1, "7 Corpo longo da sete aqui", pagina: 0, topo: 60),
            fraseCaixa(2, "8 Outro corpo longo aqui", pagina: 0, topo: 40),
        ]
        let fora = TextImport.resolveFootnotes(lista, regras: regras)
        #expect(fora.map(\.index) == [0, 1, 2])
        #expect(fora[1].notaNumero == 7)
        #expect(fora[2].text == "Outro corpo longo aqui")
        #expect(fora[2].notaNumero == 8)
    }

    /// Número solto abaixo da régua continua descartado mesmo em sequência
    /// (é rótulo sem corpo, não nota posterior legível).
    @Test func sequenciaNumeroSoltoAbaixoDaRegua() {
        let regras: [Int: CGFloat] = [0: 100]
        let lista = [
            fraseCaixa(0, "tese aqui.7", pagina: 0, topo: 500),
            fraseCaixa(1, "7 Corpo longo da sete aqui", pagina: 0, topo: 60),
            fraseCaixa(2, "8", pagina: 0, topo: 40),
        ]
        let fora = TextImport.resolveFootnotes(lista, regras: regras)
        // O "8" solto abaixo da régua continua descartado (rótulo sem corpo),
        // mas a sequência 7→8 fica registrada na ligação da 7.
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].notaNumero == 7)
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

    /// Ordem crescente (técnica do archilles-scriptor): corpos fora de ordem
    /// no arquivo ligam cada um ao seu marcador (marcadores em ordem, que
    /// é o caso real; marcador fora de ordem não é procurado para trás).
    @Test func ordemCrescenteLigaCadaUmAoSeu() {
        let lista = [
            frase(0, "sete aqui.7", pagina: 0),
            frase(1, "nove aqui.9", pagina: 0),
            frase(2, "9 corpo longo da nove aqui", pagina: 0),
            frase(3, "7 corpo longo da sete aqui", pagina: 0),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(Set(fora.map(\.index)) == [0, 1, 2, 3])
        let pos = Dictionary(uniqueKeysWithValues: fora.enumerated().map { ($1.index, $0) })
        #expect(pos[3] == pos[0]! + 1)
        #expect(pos[2] == pos[1]! + 1)
        #expect(fora[pos[3]!].notaNumero == 7)
        #expect(fora[pos[2]!].notaNumero == 9)
    }

    /// Regressão: com dois corpos para ligar, mover o segundo não pode
    /// deslocar a posição do primeiro (antes, a frase errada saía da lista).
    @Test func duasLigacoesSemPerderFrase() {
        let lista = [
            frase(0, "sete aqui.7", pagina: 0),
            frase(1, "enchimento um", pagina: 0),
            frase(2, "enchimento dois", pagina: 0),
            frase(3, "enchimento três", pagina: 0),
            frase(4, "nove aqui.9", pagina: 0),
            frase(5, "enchimento quatro", pagina: 0),
            frase(6, "enchimento cinco", pagina: 0),
            frase(7, "7 corpo longo da sete aqui", pagina: 0),
            frase(8, "9 corpo longo da nove aqui", pagina: 0),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(fora.count == 9)
        #expect(Set(fora.map(\.index)) == Set(0..<9))
        let pos = Dictionary(uniqueKeysWithValues: fora.enumerated().map { ($1.index, $0) })
        #expect(pos[7] == pos[0]! + 1)
        #expect(pos[8] == pos[4]! + 1)
    }

    /// Sem marcador no alcance (após o anterior), o corpo fica intacto em
    /// vez de grudar no marcador errado.
    @Test func semAlcanceNaoGrudaErrado() {
        let lista = [
            frase(0, "sete aqui.7", pagina: 0),
            frase(1, "7 corpo longo da sete aqui", pagina: 0),
            frase(2, "8 dias depois do evento central", pagina: 0),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(fora.map(\.index) == [0, 1, 2])
        #expect(fora[2].text == "8 dias depois do evento central")
        #expect(fora[2].notaNumero == nil)
    }

    // MARK: - Corpo colado ao número (Neutrality v80)

    /// Corpo colado ao marcador ("1The first edition..."), abaixo da régua:
    /// ainda é nota e vai para o marcador. O PDF acadêmico típico junta o
    /// número ao texto sem espaço; sem isto a nota ficava no fluxo da página.
    @Test func corpoColadoAoNumeroVaiParaOMarcador() {
        let regras: [Int: CGFloat] = [0: 100]
        let lista = [
            fraseCaixa(0, "tese aqui.1", pagina: 0, topo: 500),
            fraseCaixa(1, "1The first edition associates the way with instrumentalism", pagina: 0, topo: 50),
        ]
        let fora = TextImport.resolveFootnotes(lista, regras: regras)
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].notaNumero == 1)
        #expect(fora[1].text.hasPrefix("The first edition"))
        #expect(!fora[1].text.hasPrefix("1"))
    }

    /// Continuações da mesma nota (linhas seguintes abaixo da régua, sem novo
    /// número) sobem junto com o corpo, na ordem do rodapé. Sem isto, só a
    /// primeira frase ia para o marcador e o resto da nota ficava no fluxo.
    @Test func continuacoesDaNotaSobemJuntas() {
        let regras: [Int: CGFloat] = [0: 100]
        let lista = [
            fraseCaixa(0, "tese aqui.2", pagina: 0, topo: 500),
            fraseCaixa(1, "2Demopoulos makes the preservation a condition of adequacy", pagina: 0, topo: 60),
            fraseCaixa(2, "and truth is a condition of the reconstruction of Carnap", pagina: 0, topo: 45),
            fraseCaixa(3, "he argues that a claim of structural similarity is significant", pagina: 0, topo: 30),
            fraseCaixa(4, "frase corrida acima da zona de notas aqui", pagina: 0, topo: 400),
        ]
        let fora = TextImport.resolveFootnotes(lista, regras: regras)
        #expect(fora.map(\.index) == [0, 1, 2, 3, 4])
        #expect(fora[1].notaNumero == 2)
        #expect(fora[2].notaNumero == 2)
        #expect(fora[3].notaNumero == 2)
        #expect(fora[4].notaNumero == nil)
    }

    /// Acima da régua a regra antiga continua valendo: número colado não é
    /// nota (pode ser ano ou texto corrido), e nada se move.
    @Test func acimaDaReguaColadoNaoENota() {
        let regras: [Int: CGFloat] = [0: 100]
        let lista = [
            fraseCaixa(0, "tese aqui.1", pagina: 0, topo: 500),
            fraseCaixa(1, "1The year 2024 brought a change in the field of study", pagina: 0, topo: 300),
        ]
        let fora = TextImport.resolveFootnotes(lista, regras: regras)
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].notaNumero == nil)
    }

    /// Sem régua (via PDFKit, sem PyMuPDF), o colado não liga: sem a zona
    /// confirmada, arriscaria comer texto corrido. Vale a regra antiga.
    @Test func semReguaColadoNaoLiga() {
        let lista = [
            frase(0, "tese aqui.1", pagina: 0),
            frase(1, "1The first edition associates the way with instrumentalism", pagina: 0),
        ]
        let fora = TextImport.resolveFootnotes(lista)
        #expect(fora.map(\.index) == [0, 1])
        #expect(fora[1].notaNumero == nil)
    }
}