import Foundation

/// Remove do texto as partes que não devem ser lidas em voz alta.
///
/// Por que existir: PDFs e Markdown trazem muito material que é citação,
/// notação ou marcação. Ler "ver Figura 3, p. 47" ou "cf. [12], p. 210" em voz
/// alta é ruído; o essencial é ler o argumento, não a apparatus.
///
/// O filtro nunca inventa texto: quando remove uma passagem, deixa um espaço
/// para que a frase seguinte ainda faça sentido na leitura.
enum ReadAloudFilter {

    /// Padrões de trechos descartados, em ordem de conferência.
    ///
    /// Cada entrada é (regex, substituiPor). São verificados em sequência
    /// sobre o texto já tratado pelas etapas anteriores.
    private static let rules: [(pattern: String, template: String)] = [
        // Chamadas de nota coladas ao texto: "disso¹²", "hipótese¹", "6–7).²¹".
        // Pega o índice Unicode logo após qualquer caractere (inclusive
        // parêntese e ponto), que é onde a chamada costuma ficar.
        (#"[⁰¹²³⁴⁵⁶⁷⁸⁹²³¹]+"#, ""),
        // Notas entre colchetes no fim de um trecho: "anterior [12]."
        (#"[\s,;]*\[[\d\s,e;–-]{1,20}\]"#, ""),
        // Notas de rodapé e chamadas: "^1 Texto..." ou marcadores soltos.
        (#"^\s*\[\d+\]\s*"#, ""),
        // "nota 3", "notas 1 e 2", "cf. nota 2"
        (#"(?i)\b(nota|notas)\s+\d+([\s,e]+\d+)*\b[.,;:]?"#, ""),
        // Paginação dentro de parênteses: "(Carnap, 1934, p. 210)".
        // Vem antes da paginação solta de propósito: se a solta rodar primeiro,
        // consome o "p. 210" e deixa um ")" órfão no meio do texto.
        (#"(?i)\(\s*[^()]{0,60}?(p|pp?\.|pág\.|página)s?\s*\d+([\s–—-]+\d+)*\s*\)"#, ""),
        // Paginação solta: "p. 47", "pp. 12-15", "Figura 3, p. 47."
        (#"(?i)[,\s]*\b(pp?\.|pág\.|página)s?\s*\d+([\s–—-]+\d+)*\b[.,;:]?"#, ""),
        // Referências cruzadas: "Cf. Seção 4.2", "ver cap. 3", "Figura 3:".
        // O prefixo só é removido quando é palavra isolada seguida de PONTO ou
        // espaço: sem o ponto, "veremos" (ver + emos) seria cortado e o texto
        // perderia palavras — o que aconteceu na primeira versão.
        (#"(?i)(?<![A-Za-zÀ-ÿ])cf\.(?=\s|$)"#, ""),
        (#"(?i)(?<![A-Za-zÀ-ÿ])vide\b(?=\s+[A-Za-zÀ-ÿ])"#, ""),
        (#"(?i)(?<![A-Za-zÀ-ÿ])ver(?=\s+(cap\.|capítulo|seção|figura|tabela|gráfico|item|itens|p\.|pp\.))"#, ""),
        (#"(?i)(?<![A-Za-zÀ-ÿ])conforme\s+(o\s+|a\s+)?(cap\.|capítulo|seção|figura|tabela)"#, ""),
        // Referência cruzada exige o número: "Seção 4.2", "cap. 3", "Figura 3".
        // O TÍTULO fica de fora de propósito — "Chapter 21" é conteúdo, não
        // referência cruzada, e removê-lo fazia a leitura perder informação.
        (#"(?i)\b(seção|seções|secção|secções|cap\.|caps\.|capítulo|capítulos)\s*[\dIVX]+([\.\d]*)\b[.:–—-]?"#, ""),
        (#"(?i)\b(figure|figura|tabela|table|gráfico|grafico|quadro|imagem)\s*\d+\s*[.:–—-]?"#, ""),
        // Numeração de seção com ponto no início de linha: "1. What Is...".
        // Sem o ponto (ex.: "1 Introduction") fica como está: a regra sem o
        // ponto removia o "9" de datas como "9 Oct 2026".
        (#"(?m)^\s*\d{1,2}\.\s+(?=[A-Z])"#, ""),
        // Parágrafo de nota de rodapé, que o PDF intercala no corpo:
        // "Footnote 19. Van Fraassen argued...". É apparatus; não deve ser lido.
        (#"(?m)^\s*Footnote\s+\d+[.:]?.*$"#, ""),
        // "ibid.", "op. cit.", "et al.", "loco cit.". Consome também o ponto
        // e o espaço seguinte: sem isso sobra um "." órfão depois do nome
        // ("(Avery . 1944") e a regra de citação não casa mais.
        (#"(?i)\b(?:ibid|op\.?\s*cit|loco\s+cit|et\s+al)\.?\s*"#, ""),
        // "(nota 4)", "[nota 5]", "(*)"
        (#"\(\s*(nota|\*|\d{1,2})\s*\)"#, ""),
        (#"\*\s*\)"#, ""),
        // Asterisco solto de chamada de nota: "* Feigl (1956)". Remove só o
        // marcador: o restante da nota é conteúdo e fica para o bloco de
        // bibliografia tratar.
        (#"(?m)^\s*\*+\s*"#, ""),
        // Seções por símbolo: "§4", "§ 4.2", "§§ 3-5".
        (#"§{1,2}\s*[\d]+([\.\d]*)?([\s–—-]+[\d]+)*"#, ""),
        // Paginação de impressão: "Page 3 of 33", "Página 3 de 33".
        (#"(?m)^\s*(?:Page|Página)\s+\d+\s+(?:of|de)\s+\d+\s*$"#, ""),
        // Rodapé de impressão do navegador: "about:srcdoc", "about:blank".
        (#"(?m)^\s*about:\S*\s*$"#, ""),
        // Cabeçalho de impressão com data e hora: "10/10/26, 01:17".
        (#"(?m)^\s*\d{1,2}/\d{1,2}/\d{2,4}[,.]?\s*\d{1,2}:\d{2}(?::\d{2})?\s*$"#, ""),
        // Citação autor-ano entre parênteses: "(Carnap 1974, 256)",
        // "(Avery et al. 1944, 155)", "(Creath 1985, 122)" — com ou sem autor.
        // Exige o ano de 4 dígitos; sem ele não mexe, para não comer parêntese
        // de conteúdo.
        (#"(?i)\(\s*(?:[A-ZÀ-Þ][\p{L}'’.\-]+(?:[ \t]*(?:,|and|&|e)[ \t]*[A-ZÀ-Þ][\p{L}'’.\-]+|[ \t]+et[ \t]+al\.?)*,?[ \t]*)?\d{4}[a-z]?(?:[ \t]*,[ \t]*[\d–—\-]+)?\s*\)"#, ""),
        // Citação só de página entre parênteses: "(259)".
        (#"\(\s*\d{1,3}\s*\)"#, ""),
        // Linha de fórmula: contém conectivo lógico/matemático E (não tem
        // nenhuma minúscula OU tem até 60 caracteres). A segunda condição é
        // o que impede comer prosa que só menciona símbolos ("RHB = ∃X..."
        // no meio de uma frase de 90+ letras, medido em 2026-10-13: a regra
        // antiga apagava o trecho inteiro da nota 4 no modo filtrado). Linha
        // curta de prosa com símbolo ("see ∃X here") ainda cai — raro e
        // documentado; o status quo apagava tudo que tivesse símbolo.
        (#"(?m)^[^a-zà-ÿ\n]*[∀∃∧∨¬→↔⊨⊢≡≢⊂⊆∈∑∫∂±×÷√≤≥∞][^a-zà-ÿ\n]*$|(?m)^(?=.{0,60}$).*[∀∃∧∨¬→↔⊨⊢≡≢⊂⊆∈∑∫∂±×÷√≤≥∞].*$"#, ""),
        // Linha curta sem nenhuma minúscula: sobra de fórmula ("HB", "H I ).",
        // "T(t,o)"). Uma frase de verdade sempre tem alguma minúscula.
        (#"(?m)^[^a-zà-ÿ\n]{1,16}$"#, ""),
        // Fórmulas: remove o termo INTEIRO — operando, símbolo e operando. Sem
        // remover os três, sobra "e P(v) = 0" e a leitura fica sem sentido.
        // O operando é opcionalmente parentizado: "P(v)", "(a+b)", "42".
        (#"\b[A-Za-z]\w*\s*(?:\([A-Za-z0-9]+\))?\s*[=<>≤≥±×÷∑∫∂√]\s*(?:\([A-Za-z0-9]+\)|\d+(?:\.\d+)?|\w+)\b"#, ""),
        // Fórmulas inline: $...$ e \(...\)
        (#"\$[^$\n]{1,80}\$"#, ""),
        (#"\\\([^\\)]{1,80}\\\)"#, ""),
        // URLs soltas.
        (#"https?://\S+|www\.\S+"#, ""),
    ]

    /// Palavras que marcam o início da bibliografia (rótulo curto na metade final).
    private static let bibliographyKeywords = [
        "referencias bibliograficas", "referências bibliográficas",
        "bibliografia", "bibliography", "references", "works cited",
        "obras citadas", "leituras adicionais", "further reading",
    ]

    /// Índice do primeiro texto que abre a bibliografia, ou nil.
    ///
    /// Mesma regra do corte interno: rótulo curto (<= 60) na metade final.
    /// Serve ao pipeline por frases, que precisa truncar antes de repartir.
    static func bibliographyStart(in texts: [String]) -> Int? {
        texts.firstIndex(where: { texto in
            let l = texto.trimmingCharacters(in: .whitespaces).lowercased()
            guard !l.isEmpty, l.count <= 60 else { return false }
            return bibliographyKeywords.contains { l.contains($0) }
        }).flatMap { $0 >= texts.count / 2 ? $0 : nil }
    }

    /// Aplica o filtro ao texto.
    ///
    /// - Parameter mode: em PDFs, remove também cabeçalhos e rodapés
    ///   (número de página, título repetido), que senão viram fala inútil.
    static func clean(_ text: String, isPDF: Bool = false) -> String {
        // Normalização NFKC primeiro: unifica variantes de compatibilidade
        // (largura total, ligaduras, sobrescritos) antes de qualquer regra.
        var out = text.precomposedStringWithCompatibilityMapping

        // 0) Chamadas de nota em sobrescrito: "beliefs.¹", "(314).⁴". Precisa
        //    sair ANTES do reflow: no fim da linha o marcador esconde a
        //    pontuação e a linha seguinte (a nota de rodapé) acaba colada.
        out = out.replacingOccurrences(
            of: #"[⁰¹²³⁴⁵⁶⁷⁸⁹²³¹]+"#, with: "", options: .regularExpression)

        // 0) PDF: conserta hifenização e páginas partidas ANTES de reagrupar.
        //    A quebra de linha é a evidência da hifenização; se o reflow rodar
        //    antes, ela some e o hífen sobra grudado no meio da palavra.
        if isPDF { out = stripPDFArtifacts(out) }

        // 1) Reagrupa as linhas quebradas: as regras de apparatus dependem de
        //    ver a frase inteira, senão uma nota no fim da linha impressa
        //    ficaria colada na próxima.
        out = reflow(out)

        // 2) Trechos que não devem ser lidos (citações, bibliografia).
        out = stripQuotedBlocks(out)

        // 3) Regras de apparatus (notas, páginas, referências cruzadas).
        for rule in rules {
            guard let re = try? NSRegularExpression(
                pattern: rule.pattern, options: [.anchorsMatchLines]
            ) else { continue }
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: rule.template)
        }

        // 3) Limpeza final: linhas que ficaram só com pontuação e aspas.
        out = out
            .components(separatedBy: .newlines)
            .map { line -> String in
                let stripped = line.trimmingCharacters(in: .whitespaces)
                let semPontuacao = stripped.trimmingCharacters(
                    in: CharacterSet(charactersIn: ".,;:–—-()[]\"'“”…"))
                return semPontuacao.isEmpty && !stripped.isEmpty ? "" : line
            }
            .joined(separator: "\n")

        // 4) Espaços duplos, parênteses vazios, pontuação órfã e linhas vazias.
        out = out.replacingOccurrences(of: #"\(\s*\)|\[\s*\]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+([.,;:!?])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "([,;:])\\s*([.,;:!?])", with: "$2", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adapta uma frase para a fala: expansões que o `clean` não faz porque
    /// mudariam o texto exibido. O destaque segue o original; só o
    /// sintetizador recebe o adaptado. Inclui notação lógica ("R = ∃uT(u,o)"
    /// vira "R equals there exists u such that T of u, o"), no idioma da voz.
    /// - `lêNotas`: com `false`, o marcador de nota vira pausa e o corpo
    /// (fora da lista de leitura) nunca chega aqui. Default `true`.
    static func forSpeech(_ text: String, voice: String, lêNotas: Bool = true, marcador: Int? = nil) -> String {
        let pt = isPortugueseVoice(voice)
        // Blackboard-bold antes do NFKC: a normalização funde "ℕ" com "N",
        // "ℤ" com "Z" etc., e a tabela de regex já os receberia mortos.
        // Troca literal (sem regex), no idioma da voz.
        var out = text
        for (simbolo, en, ptMolde) in foldaveis {
            out = out.replacingOccurrences(of: simbolo, with: pt ? ptMolde : en)
        }
        out = out.precomposedStringWithCompatibilityMapping
        out = expandAbbreviations(out)
        // Anos por extenso só em português (a lista é PT); em inglês o motor
        // já lê "1944" como "nineteen forty-four" sozinho.
        if pt { out = spellOutYears(out) }
        out = expandLogic(out, portuguese: pt)
        out = expandFootnoteMarkers(out, portuguese: pt, anuncia: lêNotas, marcador: marcador)
        // As expansões podem duplicar espaços e vírgulas, ou colar vírgula
        // no próximo símbolo ("x,(W"). Ordem: primeiro colapsa, depois espaça.
        out = out.replacingOccurrences(of: "[ ]{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        out = out.replacingOccurrences(of: ",\\s*\\.", with: ".", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
        out = out.replacingOccurrences(of: ",([^\\s\\d])", with: ", $1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Voz em português (código "pt" ou sufixo "ptbr" das offline).
    static func isPortugueseVoice(_ voice: String) -> Bool {
        let v = voice.lowercased()
        return v.hasPrefix("pt") || v.contains("ptbr") || v.contains("pt-br")
    }

    /// Marcador de nota de rodapé colado ao texto ("argumento.7", "ideia,2",
    /// "hipótese12"): vira "nota de rodapé 7"/"footnote 7" no idioma da voz.
    ///
    /// Por que textual aqui: o `clean` já remove o sobrescrito Unicode antes
    /// de repartir as frases, então o que chega ao `forSpeech` é o dígito
    /// ASCII colado (o NFKC também funde "texto⁷" em "texto7"). A geometria
    /// (dígito pequeno e elevado nas caixas de `Phrase.WordBox`) distinguiria
    /// melhor o colado de "mp3", mas o `forSpeech` só recebe texto e voz —
    /// passar as caixas exigiria mexer nos chamadores (fora do escopo da
    /// fase 1). Na dúvida entre anunciar e calar, esta regra CALA: o colado
    /// de 1 dígito ("voz1", "mp3") fica como está; só o colado de 2 dígitos
    /// em palavra de 3+ letras minúsculas vira anúncio ("palavra12").
    /// Guarda forte comum: 1–2 dígitos (nunca 4, para não morder os anos
    /// 1500–2100 que o `spellOutYears` trata) e o dígito seguinte não pode
    /// ser letra, dígito nem ponto (protege "3.14", "3,14", "4.2.1" e "7z").
    /// O ponto e a vírgula exigem letra ou fecho antes (protegem "9 Oct",
    /// "Figura 7" e "1." de início de linha); o "3 x 4" não tem ponto nem
    /// dígito colado e passa intacto. O texto vem do catálogo `L`
    /// ("speech.footnote"), fonte única nos dois idiomas.
    private static func expandFootnoteMarkers(_ text: String, portuguese pt: Bool, anuncia: Bool = true, marcador: Int? = nil) -> String {
        // Sem anúncio (opção desligada): o marcador vira pausa curta, para a
        // frase correr sem prometer nota nenhuma.
        if !anuncia {
            var calado = text
            for padrao in [
                #"(?<=[A-Za-zÀ-ÿ\)\]"'”’])\.(\d{1,2})(?![\dA-Za-zÀ-ÿ.])"#,
                #"(?<=[A-Za-zÀ-ÿ\)\]"'”’]),(\d{1,2})(?![\dA-Za-zÀ-ÿ.])"#,
                #"([A-Za-zÀ-ÿ]{2,}[a-zà-ÿ])(\d{1,2})(?![\dA-Za-zÀ-ÿ.])"#,
            ] {
                guard let re = try? NSRegularExpression(pattern: padrao) else { continue }
                calado = re.stringByReplacingMatches(
                    in: calado, options: [],
                    range: NSRange(calado.startIndex..., in: calado),
                    withTemplate: ",")
            }
            return calado
        }
        let molde = L.get("speech.footnote", locale: pt ? .pt : .en)
        let marca1 = molde.replacingOccurrences(of: "{0}", with: "$1")
        let marca2 = molde.replacingOccurrences(of: "{0}", with: "$2")
        let regras: [(String, String)] = [
            // ".7" após letra ou fecho: "argumento.7" (não "3.14", que tem
            // dígito antes, nem ".5" solto, que tem espaço antes).
            (#"(?<=[A-Za-zÀ-ÿ\)\]"'”’])\.(\d{1,2})(?![\dA-Za-zÀ-ÿ.])"#, ", \(marca1),"),
            // ",2" após letra ou fecho: "ideia,2" (não "3,14", que tem
            // dígito antes).
            (#"(?<=[A-Za-zÀ-ÿ\)\]"'”’]),(\d{1,2})(?![\dA-Za-zÀ-ÿ.])"#, ", \(marca1),"),
            // Colado de 2 dígitos em palavra de 3+ letras minúsculas:
            // "palavra12" (não "mp3"/"B2", curtos, nem "abc123", longo).
            (#"([A-Za-zÀ-ÿ]{2,}[a-zà-ÿ])(\d{1,2})(?![\dA-Za-zÀ-ÿ.])"#, "$1, \(marca2),"),
        ]
        var out = text
        for (padrao, modelo) in regras {
            guard let re = try? NSRegularExpression(pattern: padrao) else { continue }
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: modelo)
        }
        // Marcador do pipeline sem expansão textual: o dígito veio em forma
        // que a regex cala ("mundo 7", "teoria7") — anuncia no fim da frase,
        // que é onde os corpos ligados começam. Sem duplicar: se a expansão
        // acima já anunciou este N, nada a fazer.
        if anuncia, let m = marcador {
            let anuncio = molde.replacingOccurrences(of: "{0}", with: "\(m)")
            if !out.localizedCaseInsensitiveContains(anuncio) {
                out += ", \(anuncio),"
            }
        }
        return out
    }

    /// Conjuntos blackboard-bold, que o NFKC funde com ASCII e por isso saem
    /// no `forSpeech` antes da normalização (aqui não há regex, só literal).
    private static let foldaveis: [(String, String, String)] = [
        ("ℕ", " the natural numbers ", " os números naturais "),
        ("ℤ", " the integers ", " os números inteiros "),
        ("ℚ", " the rational numbers ", " os números racionais "),
        ("ℝ", " the real numbers ", " os números reais "),
        ("ℂ", " the complex numbers ", " os números complexos "),
    ]

    /// Ferradura (⊃): superconjunto entre conjuntos, condicional entre fórmulas.
    ///
    /// Desempate da tabela pesquisada: perto de ∈/⊆/∪/∩/∅ (janela de 12
    /// caracteres dos dois lados) é conjunto; perto de ¬/∧/∨/⊢ é fórmula, que
    /// também é o padrão quando não há sinal nenhum. É heurística por
    /// natureza — a tabela manda não chutar quando há dúvida, e o padrão
    /// histórico do app era "implica".
    private static func resolveHorseshoe(_ text: String, portuguese pt: Bool) -> String {
        guard text.contains("⊃") else { return text }
        let marcas = Set("∈∪∩∅⊆⊂⊇")
        let janela = 12
        let sup = pt ? " é superconjunto de " : " is a superset of "
        let cond = pt ? " implica " : " implies "
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.count)
        var i = 0
        while i < chars.count {
            if chars[i] == "⊃" {
                let ini = max(0, i - janela)
                let fim = min(chars.count, i + janela + 1)
                let perto = String(chars[ini..<fim])
                out += perto.contains(where: marcas.contains) ? sup : cond
                i += 1
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Construtor de conjuntos `{x | φ}` / `{x : φ}`: a chave abre como
    /// "o conjunto de"/"the set of", a barra, os dois-pontos e o ∋ viram
    /// "tal que"/"such that", e a chave que fecha é SILÊNCIO (pausa de fim de
    /// enumeração). Só entra o que tem marcador de "tal que" dentro das
    /// chaves: sem ele, `{...}` é agrupamento (LaTeX, subscrito) e vira
    /// silêncio pela regra das chaves, não "o conjunto de".
    private static func expandSetBuilder(_ text: String, portuguese pt: Bool) -> String {
        guard text.contains("{"), let re = try? NSRegularExpression(pattern: #"\{([^{}]*)\}"#)
        else { return text }
        let abertura = pt ? "o conjunto de " : "the set of "
        // Pausa dos dois lados: "o conjunto de x, tal que, …".
        let talQue = pt ? ", tal que, " : ", such that, "
        var out = text
        // De trás para frente: as trocas no fim não mudam os offsets do início.
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let span = Range(m.range, in: out),
                  let conteudo = Range(m.range(at: 1), in: out)
            else { continue }
            var dentro = String(out[conteudo])
            guard dentro.contains(where: { "|:∶".contains($0) }) else { continue }
            for simbolo in ["|", ":", "∋", "∶"] {
                dentro = dentro.replacingOccurrences(of: simbolo, with: " \(talQue) ")
            }
            out.replaceSubrange(span, with: abertura + dentro + " ")
        }
        return out
    }

    /// Símbolos lógicos por extenso, no idioma da voz. A ordem importa: formas
    /// longas antes das curtas ("∃!" antes de "∃", "∉" antes de "∈").
    private static func expandLogic(_ text: String, portuguese pt: Bool) -> String {
        // (padrão, modelo EN, modelo PT). "$1" é o grupo capturado.
        var out = expandSetBuilder(text, portuguese: pt)
        out = resolveHorseshoe(out, portuguese: pt)
        let rules: [(String, String, String)] = [
            (#"∃!\s*([A-Za-z])"#, "there exists exactly one $1, such that,", "existe exatamente um $1, tal que,"),
            (#"∃\s*([A-Za-z])"#, "there exists $1, such that,", "existe $1, tal que,"),
            (#"∃"#, "there exists", "existe"),
            // Iota (℩x φ, descrição definida de Russell/PM): lê como o x tal que.
            (#"℩\s*([A-Za-z])"#, "the $1, such that", "o $1, tal que"),
            (#"℩"#, " such that ", " tal que "),
            (#"∀\s*([A-Za-z])"#, "for all $1,", "para todo $1,"),
            (#"∀"#, "for all", "para todo"),
            (#"ε\s*([A-Za-z])"#, "epsilon $1,", "épsilon $1,"),
            (#"ε"#, "epsilon", "épsilon"),
            // Modal: só os símbolos próprios. "[]" e "<>" ASCII ficam de fora
            // de propósito: colchete já vira pausa (e some como citação no
            // clean) e "<>" é o "diferente" ASCII — ler um ou outro como
            // "possivelmente" estragaria prosa comum.
            (#"□"#, " necessarily ", " necessariamente "),
            (#"◇"#, " possibly ", " possivelmente "),
            // ⊢/⊨ pedem pausa curta antes e depois (a voz precisa respirar entre as
            // premissas e a conclusão).
            (#"⊨"#, ", entails, ", ", acarreta, "),
            (#"\|="#, ", entails, ", ", acarreta, "),
            (#"⊢"#, ", proves, ", ", prova, "),
            (#"\|-"#, ", proves, ", ", prova, "),
            // Negações do turno: ⊬ "não prova", ⊭ "não acarreta".
            (#"⊬"#, ", does not prove, ", ", não prova, "),
            (#"⊭"#, ", does not entail, ", ", não acarreta, "),
            (#"<->"#, ", if and only if, ", ", se e somente se, "),
            (#"⇔"#, ", if and only if, ", ", se e somente se, "),
            (#"↔"#, ", if and only if, ", ", se e somente se, "),
            (#"=>"#, " implies ", " implica "),
            (#"⇒"#, " implies ", " implica "),
            (#"->"#, " implies ", " implica "),
            (#"→"#, " implies ", " implica "),
            // Implicação material: ⊇ (longa) antes de ⊃ (curta), por disciplina.
            // ⊃ decide pelo contexto — ver `resolveHorseshoe`; esta é só a rede
            // de segurança para o símbolo que sobrar.
            (#"⊇"#, " is a superset of ", " é superconjunto de "),
            (#"⊃"#, " implies ", " implica "),
            (#"∧"#, " and ", " e "),
            (#"∨"#, " or ", " ou "),
            (#"¬"#, " not ", " não "),
            (#"∪"#, " union ", " união "),
            (#"∩"#, " intersection ", " intersecção "),
            // Diferença: ∖ (próprio) é seguro; a barra ASCII só vale entre
            // operandos, senão comandos LaTeX como "\(" virariam "diferença".
            (#"∖"#, " difference ", " diferença "),
            (#"(?<=[A-Za-z0-9\)\]])\s*\\\s*(?=[A-Za-z0-9\(\[])"#, " difference ", " diferença "),
            (#"∅"#, " the empty set ", " o conjunto vazio "),
            (#"℘"#, " power set ", " conjunto das partes "),
            // ℕ ℤ ℚ ℝ ℂ ficam fora desta tabela de propósito: saem no
            // `forSpeech` antes do NFKC (ver `foldaveis`).
            // Produto: só o × próprio. O "x" ASCII (como em "3 x 4") fica
            // intacto de propósito — é letra comum em prosa.
            (#"×"#, " times ", " vezes "),
            // ∴/∵ pedem pausa antes (início de conclusão/justificativa).
            (#"∴"#, ", therefore ", ", portanto "),
            (#"∵"#, ", because ", ", porque "),
            (#"∉"#, " is not in ", " não pertence a "),
            (#"∈"#, " in ", " pertence a "),
            (#"⊆"#, " is a subset of ", " é subconjunto de "),
            (#"⊂"#, " is a proper subset of ", " é subconjunto próprio de "),
            // "≢" antes de "≡": a forma longa casa primeiro, senão o "≡"
            // dentro de "≢" seria lido como equivalência afirmada.
            (#"≢"#, " is not equivalent to ", " não é equivalente a "),
            (#"≡"#, " is equivalent to ", " é equivalente a "),
            (#"⊕"#, " xor ", " ou exclusivo "),
            (#"⊗"#, " tensor ", " tensor "),
            (#"≈"#, " is approximately equal to ", " é aproximadamente igual a "),
            (#"≃"#, " is asymptotically equal to ", " é assintoticamente igual a "),
            (#"∥"#, " is parallel to ", " é paralelo a "),
            // "∼" no começo (ou depois de abre-parêntese/vírgula) é negação
            // ("∼p" = "não p"); entre termos continua semelhança. Sem esta
            // regra o "∼p" saía "is similar to p", que está errado.
            (#"(^|[^A-Za-z0-9\)\]\s]\s*)∼\s*"#, "$1not ", "$1não "),
            (#"∼"#, " is similar to ", " é semelhante a "),
            // ⊥/⊤: em PT, "falso"/"verdadeiro" (aula brasileira); EN mantém
            // bottom/top, também aceitos na literatura em inglês.
            (#"⊥"#, " bottom ", " falso "),
            (#"⊤"#, " top ", " verdadeiro "),
            // "&" é a conjunção ASCII: em prosa (editoras, nomes) "and"/"e" é
            // sempre a leitura certa, então cobre sem risco.
            (#"&"#, " and ", " e "),
            // "§2" é "seção 2"/"section 2".
            (#"§\s*(\d+)"#, " section $1 ", " seção $1 "),
            // Primo (p'): só quando a letra está sozinha como token — assim
            // "it's", "O'Brien" e "students' rights" (apóstrofo entre letras)
            // não viram "line"/"prime".
            (#"(?:(?<=\s)|^)([A-Za-z])(['′])(?![\p{L}])"#, "$1 prime", "$1 linha"),
            // Cantos de Quine (e colchetes de Oxford): a leitura corrida não
            // verbaliza o canto — marca a menção com pausa e lê o conteúdo.
            (#"[⌜⟦]"#, ", ", ", "),
            (#"[⌝⟧]"#, "", ""),
            // Chave que sobrou (não era construtor de conjunto): silêncio.
            (#"[{}]"#, "", ""),
            // ASCII de comparação antes do "=" sozinho: "<=" e ">=" contêm
            // "=", e o lookaround do "=" já os ignora — sem estas regras o
            // leitor soletraria os pedaços ("<", "=").
            (#"<="#, " is less than or equal to ", " é menor ou igual a "),
            (#">="#, " is greater than or equal to ", " é maior ou igual a "),
            (#"!="#, " is not equal to ", " é diferente de "),
            (#"<>"#, " is not equal to ", " é diferente de "),
            (#"/="#, " is not equal to ", " é diferente de "),
            // "~" é a negação ASCII (forallx lista ~ como variante de ¬).
            (#"~"#, " not ", " não "),
            // "/" entre letras em prosa ("analytic/synthetic") lê "ou"; com
            // guarda para não morder "and/or" (a guarda vem DEPOIS da letra,
            // porque o lookbehind avalia antes de consumi-la). Fração
            // (dígitos) fica fora.
            (#"([A-Za-z])(?<!\band)(?<!\bou)\s*/\s*([A-Za-z])"#, "$1 or $2", "$1 ou $2"),
            // "^" entre letras/dígitos é sobrescrito: silêncio (nunca
            // "circumflex"), o número continua e a voz segue.
            (#"(?<=[A-Za-z0-9])\^(?=[A-Za-z0-9])"#, " ", " "),
            (#"(?<![=!<>])=(?![=])"#, " equals ", " é igual a "),
            (#"≠"#, " is not equal to ", " é diferente de "),
            (#"≤"#, " is less than or equal to ", " é menor ou igual a "),
            (#"≥"#, " is greater than or equal to ", " é maior ou igual a "),
            // Gregas pelo nome, nos dois idiomas (EN "alpha", PT "alfa").
            // Maiúsculas incluídas: o NFKC não funde grego com latim, então
            // "Α" (U+0391) nunca casa palavra comum escrita com "A".
            // O ponto do λ vira pausa, nunca "dot": "λx.M" = "lambda x, M".
            (#"λ\s*([A-Za-z])\s*\."#, "lambda $1, ", "lambda $1, "),
            (#"λ"#, " lambda ", " lambda "),
            (#"Λ"#, " lambda ", " lambda "),
            (#"α"#, " alpha ", " alfa "),
            (#"Α"#, " alpha ", " alfa "),
            (#"β"#, " beta ", " beta "),
            (#"Β"#, " beta ", " beta "),
            (#"γ"#, " gamma ", " gama "),
            (#"Γ"#, " gamma ", " gama "),
            (#"δ"#, " delta ", " delta "),
            (#"Δ"#, " delta ", " delta "),
            (#"φ"#, " phi ", " fi "),
            (#"Φ"#, " phi ", " fi "),
            (#"ψ"#, " psi ", " psi "),
            (#"Ψ"#, " psi ", " psi "),
            (#"ω"#, " omega ", " ômega "),
            (#"Ω"#, " omega ", " ômega "),
            (#"μ"#, " mu ", " mi "),
            (#"Μ"#, " mu ", " mi "),
            (#"π"#, " pi ", " pi "),
            (#"Π"#, " pi ", " pi "),
            (#"σ"#, " sigma ", " sigma "),
            (#"Σ"#, " sigma ", " sigma "),
            (#"τ"#, " tau ", " tau "),
            (#"Τ"#, " tau ", " tau "),
            (#"θ"#, " theta ", " teta "),
            (#"Θ"#, " theta ", " teta "),
            // "T(u, o)" vira "T of u, o": só MAIÚSCULA sozinha é functor, para
            // "postulate(" de palavra comum não virar "of".
            (#"\b([A-Z])\(([^()]*)\)"#, "$1 of $2", "$1 de $2"),
            // "RH" vira "R H" (nomes lidos letra a letra); o resto passa intacto.
            (#"([A-Z])(?=[A-Z])"#, "$1 ", "$1 "),
            // Subscrito com nome curto: "R_H" vira "R H" (não "R underline H").
            // O espaço vem ANTES do grupo capturado: o "_" só é removido.
            // O "_" solto continua virando espaço (variável ligada).
            (#"(?<=[A-Z])_([A-Za-z])"#, " $1", " $1"),
            (#"_"#, " ", " "),
            // "Wx" vira "W x" (variável ligada); palavra comum não tem o formato.
            (#"\b([A-Z])x\b"#, "$1 x", "$1 x"),
            // "A*" e "A∗" viram "A star".
            (#"([A-Za-z])[*∗]"#, "$1 star", "$1 estrela"),
            // Colchetes e par de ângulo viram pausa; parênteses a voz já respeita.
            (#"[\[\]⟨⟩]"#, ",", ","),
        ]
        for (pattern, en, ptTemplate) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: pt ? ptTemplate : en)
        }
        return out
    }

    /// Abreviaturas comuns por extenso (só as seguras, com ponto final).
    private static let abbreviations: [(pattern: String, spoken: String)] = [
        (#"(?i)\bSrta\."#, "senhorita"),
        (#"(?i)\bSra\."#, "senhora"),
        (#"(?i)\bSr\."#, "senhor"),
        (#"(?i)\bDra\."#, "doutora"),
        (#"(?i)\bDr\."#, "doutor"),
        (#"(?i)\bProfa\."#, "professora"),
        (#"(?i)\bProf\."#, "professor"),
        (#"(?i)\bAv\."#, "avenida"),
        (#"(?i)\bnº\.?"#, "número"),
        (#"(?i)\bart\."#, "artigo"),
        (#"(?i)\betc\."#, "etcétera"),
        (#"(?i)\bp\.\s*ex\."#, "por exemplo"),
    ]

    private static func expandAbbreviations(_ text: String) -> String {
        var out = text
        for (pattern, spoken) in abbreviations {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out),
                withTemplate: spoken)
        }
        return out
    }

    /// Anos de 1500–2100 por extenso ("1998" vira "mil novecentos e noventa
    /// e oito"). Só o numeral isolado; fora da faixa fica como está.
    static func spellOutYears(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\b(1[5-9]\d{2}|20\d{2}|2100)\b"#) else {
            return text
        }
        // De trás para frente: as trocas no fim não mudam os offsets do início.
        var out = text
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for m in matches {
            guard let numeral = Range(m.range(at: 1), in: text),
                  let ano = Int(text[numeral]),
                  let extenso = numeroPorExtenso(ano),
                  let alvo = Range(m.range, in: out)
            else { continue }
            out.replaceSubrange(alvo, with: extenso)
        }
        return out
    }

    private static let unidades = ["", "um", "dois", "três", "quatro", "cinco", "seis", "sete", "oito", "nove"]
    private static let dezADezenove = ["dez", "onze", "doze", "treze", "catorze", "quinze", "dezesseis", "dezessete", "dezoito", "dezenove"]
    private static let dezenas = ["", "", "vinte", "trinta", "quarenta", "cinquenta", "sessenta", "setenta", "oitenta", "noventa"]
    private static let centenas = ["", "cento", "duzentos", "trezentos", "quatrocentos", "quinhentos", "seiscentos", "setecentos", "oitocentos", "novecentos"]

    /// Número de 0–9999 por extenso (cobre os anos 1500–2100).
    static func numeroPorExtenso(_ n: Int) -> String? {
        guard (0...9999).contains(n) else { return nil }
        if n == 0 { return "zero" }
        if n == 100 { return "cem" }
        if n == 1000 { return "mil" }
        var partes: [String] = []
        var resto = n
        let mil = resto / 1000
        resto %= 1000
        var miolo = ""
        if resto > 0 {
            var trechos: [String] = []
            let c = resto / 100
            let dz = resto % 100
            if c > 0 { trechos.append(centenas[c]) }
            if dz > 0 {
                if dz < 10 {
                    trechos.append(unidades[dz])
                } else if dz < 20 {
                    trechos.append(dezADezenove[dz - 10])
                } else {
                    let d = dz / 10
                    let u = dz % 10
                    trechos.append(u == 0 ? dezenas[d] : "\(dezenas[d]) e \(unidades[u])")
                }
            }
            miolo = trechos.joined(separator: " e ")
        }
        if mil > 0 {
            if mil == 1 {
                // "mil novecentos…" (sem "e" depois de mil, como se fala).
                partes.append(resto > 0 ? "mil \(miolo)" : "mil")
            } else {
                partes.append(resto > 0 ? "\(centenaDezena(mil)) mil e \(miolo)" : "\(centenaDezena(mil)) mil")
            }
        } else if resto > 0 {
            partes.append(miolo)
        }
        return partes.joined(separator: " ")
    }

    private static func centenaDezena(_ n: Int) -> String {
        // Só chega aqui com 2–9 (milhar); sem "e" interno.
        numeroPorExtenso(n) ?? "\(n)"
    }

    /// Remove blocos de citação: linhas entre aspas, listas com citação e
    /// seções de bibliografia.
    private static func stripQuotedBlocks(_ text: String) -> String {
        var out = text

        // Bloco de citação: parágrafo que começa e termina entre aspas. O `.`
        // NÃO atravessa quebra de linha de propósito — a versão antiga usava
        // [\s\S] e casava de uma aspa até outra muitas linhas depois, apagando
        // seções inteiras do artigo (era o defeito grave no PDF real).
        if let re = try? NSRegularExpression(
            pattern: #"^[“\"]\s*\S.{40,}?[”\"][ \t]*$"#,
            options: [.anchorsMatchLines]
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }

        // Seções de bibliografia ao final: do rótulo em diante. O rótulo pode
        // vir com prefixo ("Selected Bibliography"), então casa por
        // palavra-chave numa linha curta, não por igualdade. Exige estar na
        // metade final do texto para não cortar uma menção no meio do corpo.
        let linhas = out.components(separatedBy: "\n")
        if let cutoff = bibliographyStart(in: linhas) {
            out = linhas[..<cutoff].joined(separator: "\n")
        }

        // Notas de rodapé em bloco: linhas curtas iniciadas por asterisco.
        if let re = try? NSRegularExpression(
            pattern: #"^\s*\*+\s*\S[^\n]{0,80}\n"#,
            options: [.anchorsMatchLines]
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out
    }

    /// Reagrupa linhas quebradas no meio de uma frase.
    ///
    /// Por que existe: a extração de PDF devolve o texto com quebras rígidas a
    /// cada linha impressa. Sem juntar, cada linha vira um curtíssimo trecho,
    /// a voz recomeça a cada uma e a leitura fica entrecortada.
    ///
    /// O critério é a LARGURA da linha, não a primeira letra da seguinte: numa
    /// frase justificada, todas as linhas chegam perto da margem e só a última
    /// linha do parágrafo é curta. Juntar pelo "começa com minúscula" deixava
    /// solta toda quebra antes de nome próprio ("...Boucher and | Forbes 2024"),
    /// fragmentando a leitura.
    static func reflow(_ text: String) -> String {
        let linhas = text.components(separatedBy: .newlines)
        let tamanhos = linhas
            .map { $0.trimmingCharacters(in: .whitespaces).count }
            .filter { $0 > 0 }
        // Largura "cheia" = 85% do percentil 75 dos comprimentos (as linhas de
        // corpo ocupam a coluna inteira; o p75 evita que um outlier infle).
        let ordenados = tamanhos.sorted()
        let larguraCheia: Int = {
            guard !ordenados.isEmpty else { return 30 }
            let p75 = ordenados[Int(Double(ordenados.count) * 0.75)]
            return max(30, Int(Double(p75) * 0.85))
        }()

        var saida: [String] = []
        var paragrafo = ""
        var ultimaFisica = ""

        for linha in linhas {
            let limpa = linha.trimmingCharacters(in: .whitespaces)
            if limpa.isEmpty {
                if !paragrafo.isEmpty { saida.append(paragrafo); paragrafo = "" }
                ultimaFisica = ""
                continue
            }
            // Continua o parágrafo se a linha anterior NÃO fechou frase e
            // chegou à largura da coluna (não é o fim de um parágrafo).
            let fechouFrase = ultimaFisica.last.map { ".!?…”".contains($0) } ?? false
            let anteriorCheia = ultimaFisica.count >= larguraCheia
            let proximaContinua = limpa.first.map {
                $0.isLowercase || "([“\"'".contains($0) || $0.isNumber
            } ?? false
            // Junta se a anterior NÃO fechou frase E a próxima parece
            // continuação (minúscula, parêntese, número) ou a anterior encheu
            // a coluna. O primeiro critério salva as quebras de página — ali a
            // última linha é curta mesmo no meio de um parágrafo; o segundo
            // salva as quebras antes de nome próprio ("(Boucher and | Forbes").
            let continua = !paragrafo.isEmpty && !fechouFrase
                && (proximaContinua || anteriorCheia)

            if continua {
                paragrafo += " " + limpa
            } else {
                if !paragrafo.isEmpty { saida.append(paragrafo) }
                paragrafo = limpa
            }
            ultimaFisica = limpa
        }
        if !paragrafo.isEmpty { saida.append(paragrafo) }
        return saida.joined(separator: "\n")
    }

    /// Remove linhas que se repetem em muitas páginas.
    ///
    /// Por que existe: a impressão de navegador/editor repete o título e a data
    /// no alto de cada folha e o rodapé embaixo. Sem remover, a voz lê o mesmo
    /// cabeçalho a cada virada de página — foi o pior defeito do PDF real do
    /// usuário (33 páginas, cabeçalho idêntico em todas).
    ///
    /// O critério é conservador: só descarta linha curta que aparece 3+ vezes
    /// e não termina frase. Um refrão de poema ou uma frase repetida no corpo
    /// terminam em pontuação e ficam intactos.
    private static func stripRepeatedLines(_ text: String) -> String {
        let linhas = text.components(separatedBy: "\n")
        var contagem: [String: Int] = [:]
        for linha in linhas {
            let l = linha.trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { contagem[l, default: 0] += 1 }
        }
        return linhas.filter { linha in
            let l = linha.trimmingCharacters(in: .whitespaces)
            guard let c = contagem[l], c >= 3 else { return true }
            let terminaFrase = ".,;:!?…".contains(l.last ?? " ")
            return !(l.count <= 80 && !terminaFrase)
        }.joined(separator: "\n")
    }

    /// Limpeza específica de PDF: cabeçalhos/rodapés repetidos.
    private static func stripPDFArtifacts(_ text: String) -> String {
        var out = stripRepeatedLines(text)
        // Rodapé com número de página. Roda ANTES do reflow porque o texto da
        // página pode continuar depois dele. NÃO come as quebras de linha em
        // volta: reflow substituído por espaço colava o parágrafo seguinte.
        out = out.replacingOccurrences(
            of: #"(?i)\bPage\s+\d+\s+(?:of|de)\s+\d+"#,
            with: "", options: .regularExpression)
        // Rodapé de impressão do navegador.
        out = out.replacingOccurrences(
            of: #"(?im)^\s*about:\S*\s*$"#, with: "", options: .regularExpression)
        // Números de página isolados em linha própria.
        if let re = try? NSRegularExpression(
            pattern: #"^\s*[-–—]?\s*\d{1,4}\s*[-–—]?\s*$"#,
            options: [.anchorsMatchLines]
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        // Data partida entre folhas: "7 de outubro de 20" numa página e "26" na
        // seguinte. Junta antes do reflow, senão viraria "de 20 Gilson".
        if let re = try? NSRegularExpression(
            pattern: #"(?m)^(\s*\d{1,2}\s+de\s+\p{L}+\s+de\s+\d{1,2})\n\s*(\d{1,2})\s*$"#,
            options: []
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "$1$2")
        }

        // "da §4", "do § 3", "na §4.2" — consome também o artigo, senão sobra
        // um "da" solto no texto.
        out = out.replacingOccurrences(
            of: #"\b(?:da|do|na|no|em)\s+§{1,2}\s*[\d]+([\.\d]*)?([\s–—-]+[\d]+)*"#,
            with: "", options: .regularExpression)

        // Seções por símbolo ANTES do reflow: a linha do PDF termina em "§" e o
        // número vem na linha seguinte; sem esta ordem o reflow junta o "§" à
        // palavra seguinte e a leitura diz "da Nós dois".
        out = out.replacingOccurrences(
            of: #"§{1,2}\s*[\d]+([\.\d]*)?([\s–—-]+[\d]+)*"#,
            with: "", options: .regularExpression)

        // Hifenização de fim de linha vira palavra inteira: "procu-\nrar" → "procurar".
        // Precisa rodar ANTES do reflow, senão a quebra some e o hífen sobra
        // no meio do texto.
        out = out.replacingOccurrences(
            of: #"(\p{L})-\n\s*(\p{L})"#, with: "$1$2", options: .regularExpression)
        // Hífen de quebra que sobrou no meio da linha: "procu- rar".
        out = out.replacingOccurrences(
            of: #"(\p{L})-\s+(\p{L})"#, with: "$1$2", options: .regularExpression)
        // Número de página partido ao meio: "7 de outubro de 20" + "26".
        if let re = try? NSRegularExpression(
            pattern: #"(\d{2,4})\n(\d{1,2})$"#,
            options: [.anchorsMatchLines]
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "$1$2")
        }
        // Cabeçalhos em caixa alta repetidos, no início das páginas.
        if let re = try? NSRegularExpression(
            pattern: #"^[A-ZÀ-Ü][A-ZÀ-Ü0-9 \.\,\;\:]{6,}$"#,
            options: [.anchorsMatchLines]
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        // Data no cabeçalho: "7 de outubro de 2026". A voz não deve ler o
        // cabeçalho repetido a cada página. Só quando a data está sozinha na
        // linha (cabeçalho), não quando é parte de uma frase.
        if let re = try? NSRegularExpression(
            pattern: #"(?m)^\s*\d{1,2}\s+de\s+\p{L}{3,12}\s+de\s+\d{4}\s*$"#,
            options: []
        ) {
            out = re.stringByReplacingMatches(
                in: out, options: [],
                range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out
    }
}