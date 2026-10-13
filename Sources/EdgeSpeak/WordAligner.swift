import CoreGraphics
import Foundation

/// Casa a palavra falada com a caixa correspondente no PDF, em uma única
/// passada que só anda para frente.
///
/// Por que isto é um objeto e não um cálculo a cada quadro: o casamento tem de
/// ser monotônico ao longo da leitura INTEIRA da frase. Recalculado do zero a
/// cada tique (o destaque repinta 10x por segundo), uma palavra que não casa
/// no meio da frase deixava o cursor parado e todas as seguintes passavam a
/// casar com posições erradas — o amarelo voltava para a ocorrência anterior e
/// produzia os "pequenos saltos" que o dono viu.
///
/// E por que a busca usa a VIZINHA: palavra idêntica repetida ("the … the")
/// não se distingue sozinha — é o par com a seguinte e a continuação da
/// anterior que dizem qual das duas é a fala. A palavra isolada é o último
/// recurso.
///
/// Regras:
/// - Trocar de frase (ou o índice de palavra andar para trás, como num salto)
///   reinicia o cursor: a lista de caixas é outra.
/// - Palavra falada sem caixa correspondente é pulada SEM consumir posição do
///   PDF — senão as palavras seguintes roubariam a ocorrência que era dela.
/// - O mapa palavra→caixa fica guardado: pedir a mesma palavra de novo não
///   recalcula nada.
@MainActor
final class WordAligner {
    /// Caixa do PDF de cada palavra da frase, na ordem de leitura.
    typealias Caixa = TextImport.Phrase.WordBox

    /// Índice global da frase a que o cursor pertence; -1 = nenhum.
    private var frase: Int = -1
    /// Próxima palavra falada ainda não processada.
    private var proxima: Int = 0
    /// Posição no PDF a partir da qual se procura (nunca retrocede).
    private var cursor: Int = 0
    /// Mapa palavra falada → índice da caixa no PDF.
    private var mapa: [Int: Int] = [:]

    /// Reduz a palavra ao que compara: minúsculas, só letras e dígitos.
    static func normalizada(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Caixa da palavra `alvo` da frase `fraseAlvo`. `nil` quando não há caixa
    /// casada — nunca uma caixa vizinha inventada.
    func caixa(frase fraseAlvo: Int, alvo: Int, faladas: [EdgeTTS.Segment.Word], pdf: [Caixa]) -> CGRect? {
        if fraseAlvo != frase { reinicia(frase: fraseAlvo) }
        if alvo < proxima { reinicia(frase: fraseAlvo) }
        while proxima <= alvo, proxima < faladas.count {
            casa(palavra: proxima, faladas: faladas, pdf: pdf)
            proxima += 1
        }
        guard let j = mapa[alvo], j < pdf.count else { return nil }
        return pdf[j].rect
    }

    /// Procura a caixa da palavra `i` a partir do cursor, nesta ordem:
    /// 1. continuação da palavra anterior (a mais forte: já sabemos onde a
    ///    anterior caiu, e a fala segue em ordem);
    /// 2. par com a palavra seguinte (desambigua repetidas);
    /// 3. palavra sozinha.
    /// Sem casamento: não consome a posição do PDF.
    private func casa(palavra i: Int, faladas: [EdgeTTS.Segment.Word], pdf: [Caixa]) {
        let alvo = Self.normalizada(faladas[i].text)
        guard !alvo.isEmpty else { return }

        if let anterior = mapa[i - 1], anterior + 1 < pdf.count,
           Self.normalizada(pdf[anterior + 1].text) == alvo {
            guarda(i, j: anterior + 1)
            return
        }
        if i + 1 < faladas.count {
            let seguinte = Self.normalizada(faladas[i + 1].text)
            if !seguinte.isEmpty {
                var j = cursor
                while j + 1 < pdf.count {
                    if Self.normalizada(pdf[j].text) == alvo,
                       Self.normalizada(pdf[j + 1].text) == seguinte {
                        guarda(i, j: j)
                        return
                    }
                    j += 1
                }
            }
        }
        var j = cursor
        while j < pdf.count {
            if Self.normalizada(pdf[j].text) == alvo {
                guarda(i, j: j)
                return
            }
            j += 1
        }
    }

    private func guarda(_ palavra: Int, j: Int) {
        mapa[palavra] = j
        cursor = j + 1
    }

    private func reinicia(frase nova: Int) {
        frase = nova
        proxima = 0
        cursor = 0
        mapa = [:]
    }
}