import Testing

@testable import EdgeSpeak

/// Read-aloud of logical formulas: what each symbol becomes in each
/// language, without ruining common prose.
///
/// Unverified pending item: PDF extraction may deliver these symbols
/// differently (entity, LaTeX, image); no formula PDF has been measured.
/// The tests cover the pure function, with no audio synthesis and no network.
///
/// Style note: it uses swift-testing (`@Test`, `#expect`), like the other
/// suites in the repo, instead of XCTest.
struct ReadAloudFilterTests {
    private let en = "en-US-AndrewNeural"
    private let pt = "pt-BR-FranciscaNeural"

    private func speech(_ text: String, voice: String) -> String {
        ReadAloudFilter.forSpeech(text, voice: voice)
    }

    // MARK: - Symbols that already exist (EN + PT, exact text)

    @Test func existingSymbols() {
        let cases: [(String, String, String)] = [
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
        for (entrada, esperadoEN, esperadoPT) in cases {
            #expect(speech(entrada, voice: en) == esperadoEN)
            #expect(speech(entrada, voice: pt) == esperadoPT)
        }
    }

    // MARK: - New symbols

    @Test func modal() {
        #expect(speech("□p", voice: en) == "necessarily p")
        #expect(speech("□p", voice: pt) == "necessariamente p")
        #expect(speech("◇q", voice: en) == "possibly q")
        #expect(speech("◇q", voice: pt) == "possivelmente q")
    }

    @Test func materialImplication() {
        #expect(speech("p ⊃ q", voice: en) == "p implies q")
        #expect(speech("p ⊃ q", voice: pt) == "p implica q")
        #expect(speech("A ⊇ B", voice: en) == "A is a superset of B")
        #expect(speech("A ⊇ B", voice: pt) == "A é superconjunto de B")
    }

    @Test func setsAreSupersetOrConditional() {
        let cases: [(String, String, String)] = [
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
        for (entrada, esperadoEN, esperadoPT) in cases {
            #expect(speech(entrada, voice: en) == esperadoEN)
            #expect(speech(entrada, voice: pt) == esperadoPT)
        }
    }

    @Test func consequence() {
        // ∴/∵ require a pause before: the conclusion breathes after the pause.
        #expect(speech("∴ p", voice: en) == ", therefore p")
        #expect(speech("∴ p", voice: pt) == ", portanto p")
        #expect(speech("∵ p", voice: en) == ", because p")
        #expect(speech("∵ p", voice: pt) == ", porque p")
    }

    @Test func algebra() {
        let cases: [(String, String, String)] = [
            ("p ⊕ q", "p xor q", "p ou exclusivo q"),
            ("p ⊗ q", "p tensor q", "p tensor q"),
            ("a ≈ b", "a is approximately equal to b", "a é aproximadamente igual a b"),
            ("a ≃ b", "a is asymptotically equal to b", "a é assintoticamente igual a b"),
            ("p ≢ q", "p is not equivalent to q", "p não é equivalente a q"),
            ("a ∥ b", "a is parallel to b", "a é paralelo a b"),
            ("a ∼ b", "a is similar to b", "a é semelhante a b"),
        ]
        for (entrada, esperadoEN, esperadoPT) in cases {
            #expect(speech(entrada, voice: en) == esperadoEN)
            #expect(speech(entrada, voice: pt) == esperadoPT)
        }
    }

    @Test func greekLetters() {
        let cases: [(String, String, String)] = [
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
        for (entrada, esperadoEN, esperadoPT) in cases {
            #expect(speech(entrada, voice: en) == esperadoEN)
            #expect(speech(entrada, voice: pt) == esperadoPT)
        }
    }

    @Test func asciiComparison() {
        let cases: [(String, String, String)] = [
            ("a <= b", "a is less than or equal to b", "a é menor ou igual a b"),
            ("a >= b", "a is greater than or equal to b", "a é maior ou igual a b"),
            ("a != b", "a is not equal to b", "a é diferente de b"),
            ("a <> b", "a is not equal to b", "a é diferente de b"),
        ]
        for (entrada, esperadoEN, esperadoPT) in cases {
            #expect(speech(entrada, voice: en) == esperadoEN)
            #expect(speech(entrada, voice: pt) == esperadoPT)
        }
    }

    @Test func overUnderInPortuguese() {
        // ⊥ and ⊤ in PT follow the Brazilian class: "falso"/"verdadeiro".
        #expect(speech("⊥", voice: en) == "bottom")
        #expect(speech("⊥", voice: pt) == "falso")
        #expect(speech("⊤", voice: en) == "top")
        #expect(speech("⊤", voice: pt) == "verdadeiro")
    }

    // MARK: - Researched table (logica-leitura.md)

    @Test func referenceSection() {
        #expect(speech("adopted for the sake of explanation (§2).", voice: en)
                == "adopted for the sake of explanation ( section 2 ).")
        #expect(speech("adopted for the sake of explanation (§2).", voice: pt)
                == "adopted for the sake of explanation ( seção 2 ).")
    }

    @Test func variablePrime() {
        // Only a lone letter becomes prime; an apostrophe between letters stays intact.
        // The UPPERCASE functor becomes "of"; the lowercase does not (the same care
        // that already keeps "postulate(" from becoming "of".
        #expect(speech("p'", voice: en) == "p prime")
        #expect(speech("p'", voice: pt) == "p linha")
        #expect(speech("f'(x)", voice: en) == "f prime(x)")
        #expect(speech("it's the role", voice: en) == "it's the role")
        #expect(speech("O'Brien", voice: en) == "O'Brien")
    }

    @Test func iotaOfDefinedDescription() {
        #expect(speech("℩x φ(x)", voice: en) == "the x, such that phi (x)")
        #expect(speech("℩x φ(x)", voice: pt) == "o x, tal que fi (x)")
    }

    @Test func quineCorners() {
        // In fluent reading the corner is not verbalized: mark a mention with a pause.
        #expect(speech("⌜φ⌝", voice: en) == ", phi")
        #expect(speech("⌜φ⌝", voice: pt) == ", fi")
    }

    @Test func asciiAndConjunction() {
        #expect(speech("Brace & World", voice: en) == "Brace and World")
        #expect(speech("Brace & World", voice: pt) == "Brace e World")
    }

    @Test func setBuilder() {
        #expect(speech("{x | φ(x)}", voice: en) == "the set of x, such that, phi (x)")
        #expect(speech("{x | φ(x)}", voice: pt) == "o conjunto de x, tal que, fi (x)")
        #expect(speech("{x : φ(x)}", voice: en) == "the set of x, such that, phi (x)")
        #expect(speech("{x : φ(x)}", voice: pt) == "o conjunto de x, tal que, fi (x)")
        // Without the "such that" marker the brace is grouping: silence, and not
        // "the set of" (that is what ruined the subscript "R_{x}").
        #expect(speech("{a, b}", voice: en) == "a, b")
    }

    @Test func horseshoeAccordingToContext() {
        // Between sets, ⊃ is superset; between formulas, conditional.
        #expect(speech("A ∈ B ⊃ C", voice: en) == "A in B is a superset of C")
        #expect(speech("A ∈ B ⊃ C", voice: pt) == "A pertence a B é superconjunto de C")
        #expect(speech("p ⊃ q", voice: en) == "p implies q")
        #expect(speech("p ⊃ q", voice: pt) == "p implica q")
    }

    @Test func signatureSubscript() {
        // R_H is the article's example: the space must stay between R and H.
        #expect(speech("R_H", voice: en) == "R H")
        #expect(speech("R_H", voice: pt) == "R H")
        #expect(speech("R_H_B", voice: en) == "R H B")
        #expect(speech("lower_t", voice: en) == "lower t")
        // A subscript in braces is LaTeX, not a set constructor.
        #expect(speech("R_{x}", voice: en) == "R x")
    }

    @Test func turnNegations() {
        // Γ is Greek: it comes out by name before the turn rule.
        #expect(speech("Γ ⊬ B", voice: en) == "gamma, does not prove, B")
        #expect(speech("Γ ⊬ B", voice: pt) == "gama, não prova, B")
        #expect(speech("Γ ⊭ B", voice: en) == "gamma, does not entail, B")
        #expect(speech("Γ ⊭ B", voice: pt) == "gama, não acarreta, B")
    }

    /// Real excerpts from the test article (Neutrality v80) with what the reader
    /// should say: no glued "R H", no spelled-out §.
    @Test func articleExcerpts() {
        #expect(speech("(§2)", voice: en) == "( section 2 )")
        #expect(speech("(§2)", voice: pt) == "( seção 2 )")
        #expect(speech("Brace & World.", voice: en) == "Brace and World.")
        #expect(
            speech("B(A) |= H(A) ↔RHB.", voice: en)
                == "B of A, entails, H of A, if and only if, R H B.")
        #expect(
            speech("B(A) |= H(A) ↔RHB.", voice: pt)
                == "B de A, acarreta, H de A, se e somente se, R H B.")
    }

    /// ASCII that was missing: ~ (negation), |- (turn), /= (different).
    @Test func asciiLogical() {
        #expect(speech("~p", voice: en) == "not p")
        #expect(speech("~p", voice: pt) == "não p")
        #expect(speech("p |- q", voice: en) == "p, proves, q")
        #expect(speech("p |- q", voice: pt) == "p, prova, q")
        #expect(speech("a/=b", voice: en) == "a is not equal to b")
        #expect(speech("a/=b", voice: pt) == "a é diferente de b")
    }

    /// "∼" at the start is negation; between terms it is still similarity.
    @Test func tildeOrSimilarity() {
        #expect(speech("∼p", voice: en) == "not p")
        #expect(speech("∼p", voice: pt) == "não p")
        #expect(speech("(∼p)", voice: en) == "(not p)")
        #expect(speech("a ∼ b", voice: en) == "a is similar to b")
        #expect(speech("a ∼ b", voice: pt) == "a é semelhante a b")
    }

    /// "/" between letters in prose becomes "or"; "and/or" stays intact.
    @Test func proseSlash() {
        #expect(speech("analytic/synthetic", voice: en) == "analytic or synthetic")
        #expect(speech("analytic/synthetic", voice: pt) == "analytic ou synthetic")
        #expect(speech("and/or", voice: en) == "and/or")
    }

    /// "^" between letters/digits is superscript: silence, no "circumflex".
    @Test func hatSuperscript() {
        #expect(speech("x^2", voice: en) == "x 2")
        #expect(speech("x^2", voice: pt) == "x 2")
    }

    /// The λ dot becomes a pause: "λx.M" = "lambda x, M".
    @Test func lambdaDot() {
        #expect(speech("λx.M", voice: en) == "lambda x, M")
        #expect(speech("λx.M", voice: pt) == "lambda x, M")
    }

    // MARK: - Whole formulas

    @Test func docstringFormula() {
        #expect(
            speech("R = ∃uT(u,o)", voice: en)
                == "R equals there exists u, such that, T of u, o")
        #expect(
            speech("R = ∃uT(u,o)", voice: pt)
                == "R é igual a existe u, tal que, T de u, o")
    }

    @Test func wholeFormulas() {
        let cases: [(String, String, String)] = [
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
        for (entrada, esperadoEN, esperadoPT) in cases {
            #expect(speech(entrada, voice: en) == esperadoEN)
            #expect(speech(entrada, voice: pt) == esperadoPT)
        }
    }

    // MARK: - Non-regression (common prose intact)

    @Test func proseDoesNotRegress() {
        let sentence = "João e Maria foram, mas Pedro ou Ana não vieram."
        #expect(speech(sentence, voice: en) == sentence)
        #expect(speech(sentence, voice: pt) == sentence)
        // The ASCII "x" of "3 x 4" is a common letter: it stays intact (only the
        // proper × reads "times".
        let counter = "O cálculo de 3 x 4 aparece no texto."
        #expect(speech(counter, voice: en) == counter)
        // A date without the year spelled out in PT; with the year in EN the engine reads it.
        let data = "A reunião é em 7 de outubro."
        #expect(speech(data, voice: pt) == data)
        let date = "The meeting is on 9 Oct 2026."
        #expect(speech(date, voice: en) == date)
        // A word ending in "s" and a hyphenated verb: no star rule
        // nor arrow rule to bite.
        let hyphen = "Os carros movem-se rápido."
        #expect(speech(hyphen, voice: pt) == hyphen)
    }

    @Test func abbreviationAndDisplay() {
        // Speech expands; the display (clean) keeps the original.
        #expect(speech("O Dr. Silva chegou.", voice: pt).contains("doutor"))
        #expect(ReadAloudFilter.clean("O Dr. Silva chegou.").contains("Dr."))
    }

    // MARK: - Central contract

    @Test func speechDoesNotChangeDisplay() {
        // The speech path expands the logic; the display path never inserts
        // spoken words ("exists" does not appear in the clean).
        #expect(speech("R = ∃uT(u,o)", voice: en).contains("there exists"))
        #expect(!ReadAloudFilter.clean("R = ∃uT(u,o)").contains("exists"))
    }

    // MARK: - Glued footnote marker (phase 1)

    @Test func markerAfterPeriod() {
        #expect(speech("o argumento.7 segue", voice: pt) == "o argumento, nota de rodapé 7, segue")
        #expect(speech("o argumento.7 segue", voice: en) == "o argumento, footnote 7, segue")
        #expect(speech("o argumento.1 segue", voice: pt) == "o argumento, nota de rodapé 1, segue")
        #expect(speech("o argumento.12 segue", voice: pt) == "o argumento, nota de rodapé 12, segue")
    }

    @Test func markerAfterCommaIsGlued() {
        #expect(speech("a ideia,2 segue", voice: pt) == "a ideia, nota de rodapé 2, segue")
        #expect(speech("a ideia,2 segue", voice: en) == "a ideia, footnote 2, segue")
        // Superscript lost in extraction: the PT sample word + "12", see below.
        #expect(speech("a hipótese12 segue", voice: pt) == "a hipótese, nota de rodapé 12, segue")
        #expect(speech("a hipótese12 segue", voice: en) == "a hipótese, footnote 12, segue")
    }

    @Test func markerDoesNotBiteProse() {
        // Years are still spelled out in PT (never "footnote").
        #expect(speech("Em 1944 acabou.", voice: pt) == "Em mil novecentos e quarenta e quatro acabou.")
        // Decimals, figure, dates, section, enumeration and count pass intact.
        #expect(speech("vale 3.14 aqui", voice: pt) == "vale 3.14 aqui")
        #expect(speech("vale 3,14 aqui", voice: pt) == "vale 3,14 aqui")
        #expect(speech("ver Figura 7 aqui", voice: pt) == "ver Figura 7 aqui")
        #expect(speech("em 7 de outubro", voice: pt) == "em 7 de outubro")
        #expect(speech("adotado (§2).", voice: pt) == "adotado ( seção 2 ).")
        #expect(speech("1. What Is This", voice: en) == "1. What Is This")
        #expect(speech("O cálculo de 3 x 4 aparece.", voice: pt) == "O cálculo de 3 x 4 aparece.")
        // A short glued run is an acronym, not a note: it stays as is.
        #expect(speech("o mp3 toca", voice: pt) == "o mp3 toca")
    }

    // MARK: - Formula line does not eat prose (N4 regression)

    @Test func formulaDoesNotEatProseWithSymbol() {
        // The formula-line rule may only bite a line with no lowercase or a
        // very short one; long prose with a symbol in the middle stays
        // (regression: note 4 vanished from filtered mode, measured 2026-10-13).
        let prosa = "The enlarged Ramsey sentence RHB = ∃X [H(X) ∧B(X)] is now "
            + "false, since its witness would have to contain a alone."
        #expect(ReadAloudFilter.clean(prosa, isPDF: true).contains("witness"))
        // Linha que é só fórmula continua fora.
        #expect(!ReadAloudFilter.clean("∃X φ(X)", isPDF: true).contains("∃"))
    }

    // MARK: - Citations are unwrapped, not deleted (owner choice)

    @Test func citationsUnwrapKeepingEtAl() {
        // Author-year keeps its content without parens; "et al." stays.
        #expect(ReadAloudFilter.clean("(Bhattacharyya et al., 1990, 115, 118).", isPDF: true).contains("Bhattacharyya et al., 1990, 115, 118"))
        #expect(!ReadAloudFilter.clean("(Bhattacharyya et al., 1990, 115, 118).", isPDF: true).contains("("))
        // Pure apparatus still goes: ibid/op.cit. carry no content.
        #expect(!ReadAloudFilter.clean("said (ibid., 1956) loudly", isPDF: true).contains("ibid"))
    }

    // MARK: - Onda 1 (2026-10-17): ajustes finos do caminho da fala

    /// Regra curta sem minúsculas: título em capiturada é conteúdo.
    @Test func capsTitleSurvivesClean() {
        let out = ReadAloudFilter.clean("THE PROBLEM\nThe problem is real.", isPDF: false)
        #expect(out.contains("THE PROBLEM"))
        // Linha de artefato (sem letra nenhuma) continua fora.
        let artefato = ReadAloudFilter.clean("12\nBody text stays.", isPDF: false)
        #expect(!artefato.hasPrefix("12") && artefato.contains("Body text stays."))
    }

    /// Sigla vira soletrado; a lista toda em maiúsculas (título) fica intacta
    /// pela guarda de run ("CARNAP AND THE AUFBAU"). "MAD" é sigla curta como
    /// qualquer outra: o app vivo soletra ("M A D"), e é o comportamento que
    /// o dono usa.
    @Test func acronymOnlyIsSpelled() {
        #expect(speech("CARNAP AND THE AUFBAU said", voice: en)
            == "CARNAP AND THE AUFBAU said")
        #expect(speech("MAD and IBM agreed", voice: en) == "M A D and I B M agreed")
        #expect(speech("RH segue", voice: pt) == "R H segue")
    }

    /// `etc.` bilíngue; `p.`/`pp.` têm número após, ou não são páginas.
    @Test func bilingualAbbreviations() {
        #expect(speech("Feigl, etc. finished.", voice: en).contains("et cetera"))
        #expect(speech("Feigl, etc. finished.", voice: pt).contains("etcétera"))
        #expect(speech("see e.g. Carnap 1930", voice: en).contains("for example"))
        #expect(speech("cf. Seção 4.2 explica", voice: pt).contains("conferir"))
        #expect(speech("Avery et al. (1944) argued", voice: en).contains("and others"))
        #expect(speech("Cite p. 47 aqui", voice: en).contains("page 47"))
        #expect(speech("Cite pp. 10-15 aqui", voice: pt).contains("páginas 10"))
        // Sem número não é página: a nota "A. P." passa intacta.
        #expect(speech("por A. P. Morse", voice: en) == "por A. P. Morse")
    }

    /// Ano: 2100 é "dois mil e cem"; quantidade não vende o ano.
    @Test func yearSpelling() {
        #expect(speech("em 2100 acaba.", voice: pt) == "em dois mil e cem acaba.")
        #expect(speech("em 1944 abriu.", voice: pt) == "em mil novecentos e quarenta e quatro abriu.")
        // Sem contexto de data, a voz natural do motor vale.
        #expect(speech("1900 abriu.", voice: pt) == "1900 abriu.")
    }

    /// Préposição antes de "p. 47" sai junto da notação.
    @Test func prepositionDiesWithPageNumber() {
        let out = ReadAloudFilter.clean("The proof is on p. 47 nessa linha.", isPDF: false)
        #expect(!out.contains("p. 47"))
        #expect(!out.contains(" on "))
        #expect(out.contains("nessa linha"))
    }

    /// Hífen de quebra de linha colando também em .txt/.md; travessão entre
    /// espaços NÃO cola.
    @Test func textHyphenJoinsButSpacedDashStays() {
        #expect(ReadAloudFilter.clean("argu-\nment closed.", isPDF: false).contains("argument"))
        #expect(ReadAloudFilter.clean("argu‐\nment closed.", isPDF: false).contains("argument"))
        #expect(ReadAloudFilter.clean("the author - a philosopher - said", isPDF: false)
            .contains("author - a philosopher"))
        // O hífen colado com espaço à direita continua cola (resíduo de quebra).
        #expect(ReadAloudFilter.clean("procu- rar aqui", isPDF: false).contains("procurar"))
    }
}
