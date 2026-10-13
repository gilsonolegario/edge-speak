import CoreGraphics
import Foundation

/// Alinha a sequência de palavras FALADAS com a sequência de palavras do PDF,
/// e diz qual caixa corresponde a cada palavra falada.
///
/// Por que alinhar e não procurar palavra a palavra: a leitura em voz alta
/// NUNCA tem a mesma sequência de palavras do PDF. Onde o PDF põe um símbolo,
/// a voz põe uma frase — "∃uT (u,o)" vira "there exists u, such that, T of
/// u" (6 palavras para 3 caixas). Procurar palavra a palavra obrigava as
/// palavras de expansão a casar com alguma caixa do PDF, e como elas são
/// palavras COMUNS ("and", "such", "there"), elas roubavam a caixa de uma
/// palavra de prosa logo adiante: o amarelo ia para o lado errado. Era esse o
/// "pula de lado a lado" que o dono viu.
///
/// Por que alinhamento global (Needleman–Wunsch) e não guloso: casar palavra
/// a palavra resolve o caso comum, mas quebra justamente aqui, onde o
/// comprimento das duas sequências é diferente por construção. O alinhamento
/// global prefere deixar a palavra de expansão SEM caixa a distorcer o resto,
/// porque distorcer custa mais caro.
///
/// Como fica em voz alta: as palavras de expansão não têm caixa (o amarelo
/// pisca entre elas, sem pular); as palavras reais ficam na caixa certa. É a
/// consequência honesta de ler fórmulas por extenso, e é o que se espera de
/// um karaokê.
///
/// Custo por operação:
/// - casar palavras iguais: 0
/// - pular (expansão sem caixa, ou caixa sem palavra falada): 1
/// - trocar (par não igual): 3 — mais caro que pular, porque trocar distorce
///   a sequência; pular apenas admite que não havia caixa.
@MainActor
final class WordAligner {
    /// Caixa do PDF de cada palavra da frase, na ordem de leitura.
    typealias Caixa = TextImport.Phrase.WordBox

    private static let custoPular: Int = 1
    private static let custoTrocar: Int = 3

    /// Reduz a palavra ao que compara: minúsculas, só letras e dígitos.
    static func normalizada(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Índice da caixa do PDF que corresponde a cada palavra falada; `nil`
    /// quando a palavra é de expansão (não tem caixa própria).
    ///
    /// Alinhamento global com desempate explícito: numa diagonal com mesmo
    /// custo, prefere CASAR (a palavra é a mesma das duas pontas), depois
    /// pular a palavra falada (expansão), depois pular a caixa do PDF. A
    /// preferência por casar é o que mantém `the … the` na ocorrência certa.
    func alinha(faladas: [String], pdf: [Caixa]) -> [Int?] {
        let n = faladas.count
        let m = pdf.count
        guard n > 0, m > 0 else { return [Int?](repeating: nil, count: n) }

        let faladasNorm = faladas.map(Self.normalizada)
        let pdfNorm = pdf.map { Self.normalizada($0.text) }

        // dp[i][j] = custo de alinhar as primeiras i faladas com as j caixas.
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { dp[i][0] = i * Self.custoPular }
        for j in 1...m { dp[0][j] = j * Self.custoPular }
        for i in 1...n {
            for j in 1...m {
                let casar = faladasNorm[i - 1] == pdfNorm[j - 1]
                    ? dp[i - 1][j - 1]
                    : dp[i - 1][j - 1] + Self.custoTrocar
                let pularFala = dp[i - 1][j] + Self.custoPular
                let pularCaixa = dp[i][j - 1] + Self.custoPular
                dp[i][j] = min(casar, pularFala, pularCaixa)
            }
        }

        // Backtrace: de (n, m) até (0, 0). Empate vai para casar.
        var mapa = [Int?](repeating: nil, count: n)
        var i = n
        var j = m
        while i > 0 && j > 0 {
            let casar = faladasNorm[i - 1] == pdfNorm[j - 1]
            let custoCasar = casar ? dp[i - 1][j - 1] : dp[i - 1][j - 1] + Self.custoTrocar
            if dp[i][j] == custoCasar {
                if casar { mapa[i - 1] = j - 1 }
                i -= 1
                j -= 1
            } else if dp[i][j] == dp[i - 1][j] + Self.custoPular {
                i -= 1 // expansão: sem caixa
            } else {
                j -= 1 // caixa sem palavra falada
            }
        }
        return mapa
    }

    /// Atalho de teste: caixa da palavra `alvo` já alinhada.
    func caixa(alinhado: [Int?], alvo: Int, pdf: [Caixa]) -> CGRect? {
        guard alvo >= 0, alvo < alinhado.count,
              let k = alinhado[alvo], k >= 0, k < pdf.count
        else { return nil }
        return pdf[k].rect
    }

    // MARK: - Cache por frase

    /// Frase do alinhamento guardado e o próprio mapa.
    private var fraseAtual = -1
    private var mapa: [Int?] = []
    private var falaContagem = -1
    private var caixaContagem = -1

    /// Caixa da palavra `alvo` da frase `frase`, alinhando uma vez e reaproveitando
    /// enquanto for a mesma frase. Chamado a cada tique do destaque (10 Hz): o
    /// alinhamento é O(n·m) e não pode rodar a cada quadro.
    func caixa(frase: Int, alvo: Int, faladas: [String], pdf: [Caixa]) -> CGRect? {
        if frase != fraseAtual
            || faladas.count != falaContagem
            || pdf.count != caixaContagem {
            fraseAtual = frase
            falaContagem = faladas.count
            caixaContagem = pdf.count
            mapa = alinha(faladas: faladas, pdf: pdf)
        }
        return caixa(alinhado: mapa, alvo: alvo, pdf: pdf)
    }
}