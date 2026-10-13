import Testing

@testable import EdgeSpeak

/// Leitura em voz alta de fórmulas lógicas: o que cada símbolo vira em cada
/// idioma, sem estragar prosa comum.
///
/// Pendência não verificada: a extração de PDF pode entregar estes símbolos
/// de outro jeito (entidade, LaTeX, imagem); não há PDF de fórmulas medido.
/// Os testes cobrem a função pura, sem síntese de áudio nem rede.
///
/// Nota de estilo: usa swift-testing (`@Test`, `#expect`), como as demais
/// suítes do repositório, em vez de XCTest.
struct ReadAloudFilterTests {
    private let en = "en-US-AndrewNeural"
    private let pt = "pt-BR-FranciscaNeural"

    private func fala(_ texto: String, voz: String) -> String {
        ReadAloudFilter.forSpeech(texto, voice: voz)
    }

    // MARK: - Símbolos já existentes (EN + PT, texto exato)

    @Test func simbolosExistentes() {
        let casos: [(String, String, String)] = [
            ("∃x", "there exists x, such that,", "existe x, tal que,"),
            ("∃!x", "there exists exactly one x, such that,", "existe exatamente um x, tal que,"),
            ("∀x", "for all x,", "para todo x,"),
            ("εx", "epsilon x,", "épsilon x,"),
            ("p ⊨ q", "p, entails, q", "p, acarreta, q"),
            ("p |= q", "p, entails, q", "p, acarreta, q"),
            ("p ⊢ q", "p, proves, q", "p, prova, q"),
            ("p <-> q", "p, if and only if, q", "p, se e somente se, q"),
            ("p ⇔ q", "p, if and only if, q", "p, se e somente se, q"),
            ("p ↔ q", "p, if and only if, q", "p, se e somente se, q"),
            ("p => q", "p implies q", "p implica q"),
            ("p ⇒ q", "p implies q", "p implica q"),
            ("p -> q", "p implies q", "p implica q"),
            ("p → q", "p implies q", "p implica q"),
            ("p ∧ q", "p and q", "p e q"),
            ("p ∨ q", "p or q", "p ou q"),
            ("¬p", "not p", "não p"),
            ("x ∉ A", "x is not in A", "x não pertence a A"),
            ("x ∈ A", "x in A", "x pertence a A"),
            ("A ⊆ B", "A is a subset of B", "A é subconjunto de B"),
            ("A ⊂ B", "A is a proper subset of B", "A é subconjunto próprio de B"),
            ("p ≡ q", "p is equivalent to q", "p é equivalente a q"),
            ("R = S", "R equals S", "R é igual a S"),
            ("x ≠ y", "x is not equal to y", "x é diferente de y"),
            ("a ≤ b", "a is less than or equal to b", "a é menor ou igual a b"),
            ("a ≥ b", "a is greater than or equal to b", "a é maior ou igual a b"),
            ("T(u,o)", "T of u, o", "T de u, o"),
            ("R_H", "R H", "R H"),
            ("A*", "A star", "A estrela"),
            ("[a]", ", a,", ", a,"),
        ]
        for (entrada, esperadoEN, esperadoPT) in casos {
            #expect(fala(entrada, voz: en) == esperadoEN)
            #expect(fala(entrada, voz: pt) == esperadoPT)
        }
    }

    // MARK: - Símbolos novos

    @Test func modal() {
        #expect(fala("□p", voz: en) == "necessarily p")
        #expect(fala("□p", voz: pt) == "necessariamente p")
        #expect(fala("◇q", voz: en) == "possibly q")
        #expect(fala("◇q", voz: pt) == "possivelmente q")
    }

    @Test func implicacaoMaterial() {
        #expect(fala("p ⊃ q", voz: en) == "p implies q")
        #expect(fala("p ⊃ q", voz: pt) == "p implica q")
        #expect(fala("A ⊇ B", voz: en) == "A is a superset of B")
        #expect(fala("A ⊇ B", voz: pt) == "A é superconjunto de B")
    }

    @Test func conjuntos() {
        let casos: [(String, String, String)] = [
            ("A ∪ B", "A union B", "A união B"),
            ("A ∩ B", "A intersection B", "A intersecção B"),
            ("A ∖ B", "A difference B", "A diferença B"),
            ("A\\B", "A difference B", "A diferença B"),
            ("∅", "the empty set", "o conjunto vazio"),
            ("℘(A)", "power set (A)", "conjunto das partes (A)"),
            ("ℕ", "the natural numbers", "os números naturais"),
            ("ℤ", "the integers", "os números inteiros"),
            ("ℚ", "the rational numbers", "os números racionais"),
            ("ℝ", "the real numbers", "os números reais"),
            ("ℂ", "the complex numbers", "os números complexos"),
            ("A × B", "A times B", "A vezes B"),
        ]
        for (entrada, esperadoEN, esperadoPT) in casos {
            #expect(fala(entrada, voz: en) == esperadoEN)
            #expect(fala(entrada, voz: pt) == esperadoPT)
        }
    }

    @Test func consequencia() {
        // ∴/∵ pedem pausa antes: a conclusão respira depois da pausa.
        #expect(fala("∴ p", voz: en) == ", therefore p")
        #expect(fala("∴ p", voz: pt) == ", portanto p")
        #expect(fala("∵ p", voz: en) == ", because p")
        #expect(fala("∵ p", voz: pt) == ", porque p")
    }

    @Test func algebra() {
        let casos: [(String, String, String)] = [
            ("p ⊕ q", "p xor q", "p ou exclusivo q"),
            ("p ⊗ q", "p tensor q", "p tensor q"),
            ("a ≈ b", "a is approximately equal to b", "a é aproximadamente igual a b"),
            ("a ≃ b", "a is asymptotically equal to b", "a é assintoticamente igual a b"),
            ("p ≢ q", "p is not equivalent to q", "p não é equivalente a q"),
            ("a ∥ b", "a is parallel to b", "a é paralelo a b"),
            ("a ∼ b", "a is similar to b", "a é semelhante a b"),
        ]
        for (entrada, esperadoEN, esperadoPT) in casos {
            #expect(fala(entrada, voz: en) == esperadoEN)
            #expect(fala(entrada, voz: pt) == esperadoPT)
        }
    }

    @Test func gregas() {
        let casos: [(String, String, String)] = [
            ("λx", "lambda x", "lambda x"),
            ("α", "alpha", "alfa"),
            ("β", "beta", "beta"),
            ("γ", "gamma", "gama"),
            ("δ", "delta", "delta"),
            ("φ", "phi", "fi"),
            ("ψ", "psi", "psi"),
            ("ω", "omega", "ômega"),
            ("μ", "mu", "mi"),
            ("π", "pi", "pi"),
            ("σ", "sigma", "sigma"),
            ("τ", "tau", "tau"),
            ("θ", "theta", "teta"),
            ("Ω", "omega", "ômega"),
        ]
        for (entrada, esperadoEN, esperadoPT) in casos {
            #expect(fala(entrada, voz: en) == esperadoEN)
            #expect(fala(entrada, voz: pt) == esperadoPT)
        }
    }

    @Test func asciiComparacao() {
        let casos: [(String, String, String)] = [
            ("a <= b", "a is less than or equal to b", "a é menor ou igual a b"),
            ("a >= b", "a is greater than or equal to b", "a é maior ou igual a b"),
            ("a != b", "a is not equal to b", "a é diferente de b"),
            ("a <> b", "a is not equal to b", "a é diferente de b"),
        ]
        for (entrada, esperadoEN, esperadoPT) in casos {
            #expect(fala(entrada, voz: en) == esperadoEN)
            #expect(fala(entrada, voz: pt) == esperadoPT)
        }
    }

    @Test func topoFundoEmPortugues() {
        // ⊥ e ⊤ em PT seguem a aula brasileira: "falso"/"verdadeiro".
        #expect(fala("⊥", voz: en) == "bottom")
        #expect(fala("⊥", voz: pt) == "falso")
        #expect(fala("⊤", voz: en) == "top")
        #expect(fala("⊤", voz: pt) == "verdadeiro")
    }

    // MARK: - Tabela pesquisada (logica-leitura.md)

    @Test func secaoDeReferencia() {
        #expect(fala("adopted for the sake of explanation (§2).", voz: en)
                == "adopted for the sake of explanation ( section 2 ).")
        #expect(fala("adopted for the sake of explanation (§2).", voz: pt)
                == "adopted for the sake of explanation ( seção 2 ).")
    }

    @Test func primoDeVariavel() {
        // Só letra sozinha vira primo; apóstrofo entre letras fica intacto.
        // O functor MAIÚSCULO vira "of"; o minúsculo não (o mesmo cuidado
        // que já evita "postulate(" virar "of").
        #expect(fala("p'", voz: en) == "p prime")
        #expect(fala("p'", voz: pt) == "p linha")
        #expect(fala("f'(x)", voz: en) == "f prime(x)")
        #expect(fala("it's the role", voz: en) == "it's the role")
        #expect(fala("O'Brien", voz: en) == "O'Brien")
    }

    @Test func iotaDeDescricaoDefinida() {
        #expect(fala("℩x φ(x)", voz: en) == "the x, such that phi (x)")
        #expect(fala("℩x φ(x)", voz: pt) == "o x, tal que fi (x)")
    }

    @Test func cantosDeQuine() {
        // Em leitura corrida o canto não se verbaliza: marca menção com pausa.
        #expect(fala("⌜φ⌝", voz: en) == ", phi")
        #expect(fala("⌜φ⌝", voz: pt) == ", fi")
    }

    @Test func conjuncaoAsciiE() {
        #expect(fala("Brace & World", voz: en) == "Brace and World")
        #expect(fala("Brace & World", voz: pt) == "Brace e World")
    }

    @Test func construtorDeConjuntos() {
        #expect(fala("{x | φ(x)}", voz: en) == "the set of x, such that, phi (x)")
        #expect(fala("{x | φ(x)}", voz: pt) == "o conjunto de x, tal que, fi (x)")
        #expect(fala("{x : φ(x)}", voz: en) == "the set of x, such that, phi (x)")
        #expect(fala("{x : φ(x)}", voz: pt) == "o conjunto de x, tal que, fi (x)")
        // Sem marcador de "tal que" a chave é agrupamento: silêncio, e não
        // "o conjunto de" (era o que estragava o subscrito "R_{x}").
        #expect(fala("{a, b}", voz: en) == "a, b")
    }

    @Test func ferraduraConformeContexto() {
        // Entre conjuntos, ⊃ é superconjunto; entre fórmulas, condicional.
        #expect(fala("A ∈ B ⊃ C", voz: en) == "A in B is a superset of C")
        #expect(fala("A ∈ B ⊃ C", voz: pt) == "A pertence a B é superconjunto de C")
        #expect(fala("p ⊃ q", voz: en) == "p implies q")
        #expect(fala("p ⊃ q", voz: pt) == "p implica q")
    }

    @Test func subscritoDeAssinatura() {
        // R_H é o exemplo do artigo: o espaço tem de ficar entre R e H.
        #expect(fala("R_H", voz: en) == "R H")
        #expect(fala("R_H", voz: pt) == "R H")
        #expect(fala("R_H_B", voz: en) == "R H B")
        #expect(fala("lower_t", voz: en) == "lower t")
        // Subscrito entre chaves é LaTeX, não construtor de conjunto.
        #expect(fala("R_{x}", voz: en) == "R x")
    }

    @Test func negacoesDoTurno() {
        // Γ é grego: sai pelo nome antes da regra do turno.
        #expect(fala("Γ ⊬ B", voz: en) == "gamma, does not prove, B")
        #expect(fala("Γ ⊬ B", voz: pt) == "gama, não prova, B")
        #expect(fala("Γ ⊭ B", voz: en) == "gamma, does not entail, B")
        #expect(fala("Γ ⊭ B", voz: pt) == "gama, não acarreta, B")
    }

    /// Trechos reais do artigo de teste (Neutrality v80) com o que o leitor
    /// deve dizer: nada de "R H" colado, nada de § soletrado.
    @Test func trechosDoArtigo() {
        #expect(fala("(§2)", voz: en) == "( section 2 )")
        #expect(fala("(§2)", voz: pt) == "( seção 2 )")
        #expect(fala("Brace & World.", voz: en) == "Brace and World.")
        #expect(
            fala("B(A) |= H(A) ↔RHB.", voz: en)
                == "B of A, entails, H of A, if and only if, R H B.")
        #expect(
            fala("B(A) |= H(A) ↔RHB.", voz: pt)
                == "B de A, acarreta, H de A, se e somente se, R H B.")
    }

    /// ASCII que faltava: ~ (negação), |- (turno), /= (diferente).
    @Test func asciiLogico() {
        #expect(fala("~p", voz: en) == "not p")
        #expect(fala("~p", voz: pt) == "não p")
        #expect(fala("p |- q", voz: en) == "p, proves, q")
        #expect(fala("p |- q", voz: pt) == "p, prova, q")
        #expect(fala("a/=b", voz: en) == "a is not equal to b")
        #expect(fala("a/=b", voz: pt) == "a é diferente de b")
    }

    /// "∼" no começo é negação; entre termos continua semelhança.
    @Test func tilOuSemelhanca() {
        #expect(fala("∼p", voz: en) == "not p")
        #expect(fala("∼p", voz: pt) == "não p")
        #expect(fala("(∼p)", voz: en) == "(not p)")
        #expect(fala("a ∼ b", voz: en) == "a is similar to b")
        #expect(fala("a ∼ b", voz: pt) == "a é semelhante a b")
    }

    /// "/" entre letras em prosa vira "ou"; "and/or" fica intacto.
    @Test func barraDeProsa() {
        #expect(fala("analytic/synthetic", voz: en) == "analytic or synthetic")
        #expect(fala("analytic/synthetic", voz: pt) == "analytic ou synthetic")
        #expect(fala("and/or", voz: en) == "and/or")
    }

    /// "^" entre letras/dígitos é sobrescrito: silêncio, sem "circumflex".
    @Test func chapeuDeSobrescrito() {
        #expect(fala("x^2", voz: en) == "x 2")
        #expect(fala("x^2", voz: pt) == "x 2")
    }

    /// O ponto do λ vira pausa: "λx.M" = "lambda x, M".
    @Test func pontoDoLambda() {
        #expect(fala("λx.M", voz: en) == "lambda x, M")
        #expect(fala("λx.M", voz: pt) == "lambda x, M")
    }

    // MARK: - Fórmulas inteiras

    @Test func formulaDoDocstring() {
        #expect(
            fala("R = ∃uT(u,o)", voz: en)
                == "R equals there exists u, such that, T of u, o")
        #expect(
            fala("R = ∃uT(u,o)", voz: pt)
                == "R é igual a existe u, tal que, T de u, o")
    }

    @Test func formulasInteiras() {
        let casos: [(String, String, String)] = [
            ("∀x∈A", "for all x, in A", "para todo x, pertence a A"),
            ("p ⊃ q", "p implies q", "p implica q"),
            ("□p → ◇q", "necessarily p implies possibly q", "necessariamente p implica possivelmente q"),
            ("A ∪ B ⊆ C", "A union B is a subset of C", "A união B é subconjunto de C"),
            ("x ≠ ∅", "x is not equal to the empty set", "x é diferente de o conjunto vazio"),
            ("℘(A)", "power set (A)", "conjunto das partes (A)"),
            (
                "a <= b != c",
                "a is less than or equal to b is not equal to c",
                "a é menor ou igual a b é diferente de c"
            ),
            ("∴ p", ", therefore p", ", portanto p"),
            ("λx", "lambda x", "lambda x"),
            ("⟨a, b⟩ ∈ R", ", a, b, in R", ", a, b, pertence a R"),
        ]
        for (entrada, esperadoEN, esperadoPT) in casos {
            #expect(fala(entrada, voz: en) == esperadoEN)
            #expect(fala(entrada, voz: pt) == esperadoPT)
        }
    }

    // MARK: - Não regressão (prosa comum intacta)

    @Test func prosaNaoRegride() {
        let frase = "João e Maria foram, mas Pedro ou Ana não vieram."
        #expect(fala(frase, voz: en) == frase)
        #expect(fala(frase, voz: pt) == frase)
        // O "x" ASCII de "3 x 4" é letra comum: fica intacto (só × próprio lê
        // "vezes").
        let conta = "O cálculo de 3 x 4 aparece no texto."
        #expect(fala(conta, voz: en) == conta)
        // Data sem ano por extenso em PT; com ano em EN o motor lê sozinho.
        let data = "A reunião é em 7 de outubro."
        #expect(fala(data, voz: pt) == data)
        let date = "The meeting is on 9 Oct 2026."
        #expect(fala(date, voz: en) == date)
        // Palavra terminada em "s" e verbo com hífen: sem regra de estrela
        // nem de seta para morder.
        let hifen = "Os carros movem-se rápido."
        #expect(fala(hifen, voz: pt) == hifen)
    }

    @Test func abreviaturaEDisplay() {
        // A fala expande; a exibição (clean) mantém o original.
        #expect(fala("O Dr. Silva chegou.", voz: pt).contains("doutor"))
        #expect(ReadAloudFilter.clean("O Dr. Silva chegou.").contains("Dr."))
    }

    // MARK: - Contrato central

    @Test func falaNaoAlteraExibicao() {
        // O caminho de fala expande a lógica; o de exibição nunca insere
        // palavra falada ("exists" não aparece no clean).
        #expect(fala("R = ∃uT(u,o)", voz: en).contains("there exists"))
        #expect(!ReadAloudFilter.clean("R = ∃uT(u,o)").contains("exists"))
    }
}
