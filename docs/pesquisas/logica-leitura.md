# Leitura em voz alta de fórmulas lógicas — EN + PT-BR (guia para filtro TTS)

Data: 2026-10-13. Propósito: guiar filtro texto-para-fala que decide o que verbalizar, o que virar pausa e o que silenciar.
Convenção de status por linha: [P] padrão estabelecido (múltiplos manuais) · [S] suportado por fonte (1–2 fontes) · [I] inferência da assessoria (sem fonte direta) · [?] não achado, não inventar.

## 1. Proposicionais e constantes

| Símb. | EN | PT-BR | Prosódia / quando NÃO verbalizar | St |
|---|---|---|---|---|
| ¬ | not; "not A" / "it is not the case that A" | "não A" / "não é o caso que A" | Sem pausa antes do escopo; nunca "negation sign". Em aula, "it is not the case that" só com escopo longo | [P] |
| ~ (ASCII ¬) | not | não | Idem ¬. Filtro: mapear ~→¬ antes do TTS | [P] |
| ∧ | and | e | Pausa curta nas bordas só se ambíguo; "A and B". Nunca "wedge/land" em leitura didática (só em soletração) | [P] |
| & (ASCII ∧) | and | e | Idem ∧ | [P] |
| ∨ | or (inclusive) | ou (inclusivo) | "A or B". "Vel" só em soletração, nunca em aula | [P] |
| \| / v (ASCII ∨) | or | ou | Filtro: \| ambíguo (v. barra/disjunção); em contexto proposicional puro, ler "or"/"ou" [I]; se entre termos de conjunto, preferir "tal que" v. §5 | [I] |
| → | "if A then B" / "A implies B" / "A only if B" | "se A então B" / "A implica B" | Sem pausa interna; antecedente→consequente em ordem. "Implies" é vernacular; em metalógica estrita distingue-se → (conectivo) de ⇒ (implicação válida) | [P] |
| -> (ASCII →) | if…then / implies | se…então / implica | Idem → | [P] |
| => (ASCII ⇒/→) | implies | implica | Idem; em código costuma ser ⇒ | [S] |
| ↔ | "A if and only if B" / "A iff B" ("iff" só escrito/falado entre lógicos) | "A se e somente se B" | Sem pausa interna; ordem esquerda→direita | [P] |
| <-> (ASCII ↔) | iff | se e somente se | Idem ↔ | [S] |
| ⊥ | "falsum" / "bottom" / "contradiction" / "false" | "falso" / "absurdo" / "contradição" | Sem pausa; nunca soletrar "perp". Em prova, "from absurdity/contradiction" conforme contexto | [P] |
| ⊤ | "verum" / "top" / "true/tautology" | "verdadeiro" / "tautologia" | Idem ⊥ | [P] |

## 2. Quantificadores (a pausa vai DEPOIS da variável)

| Símb. | EN | PT-BR | Prosódia / quando NÃO verbalizar | St |
|---|---|---|---|---|
| ∀x φ | "for all x, φ" / "for every x, φ" / "for each x, φ" | "para todo x, φ" / "para todo x vale que φ" | **Pausa obrigatória (vírgula prosódica) após a variável**, antes da matriz: "for all x [pausa] x is mortal". forallx Calgary: "∀x,H(x)" lê-se "for all x, x is H". Nunca ler o símbolo isolado sem a variável ("for all, x…") | [P] |
| ∃x φ | "there is an x such that φ" / "there exists x such that φ" / "for some x, φ" | "existe x tal que φ" / "há x tal que φ" / "para algum x, φ" | Pausa após variável; "such that/tal que" obrigatório antes da matriz quando ela é aberta. Forma curta "there is x, φ" só com pausa marcada | [P] |
| ∃!x φ | "there exists exactly one x such that φ" / "there is a unique x such that φ" | "existe um único x tal que φ" / "existe exatamente um x tal que φ" | Idem ∃ + ênfase em "unique/único"; pausa após variável | [P] |
| ∀x∈D / ∃x∈D (restrito) | "for all x in D, …" / "there is x in D such that …" | "para todo x em D, …" / "existe x em D tal que …" | O "∈" restritivo lê-se "in/em", sem pausa antes dele; pausa depois do domínio | [P] |
| : após quantificador (∀x: φ) | "such that" (raro) ou só pausa | "tal que" ou só pausa | Em aula moderna lê-se como vírgula/pausa, não "colon". Filtro TTS: converter em pausa, não verbalizar "dois-pontos" | [S] |

## 3. Identidade

| Símb. | EN | PT-BR | Prosódia / quando NÃO verbalizar | St |
|---|---|---|---|---|
| = | "equals" / "is equal to" / "is" (coloquial: "x is y") | "igual a" / "é igual a" / "é" (coloquial) | Sem pausa; ordem esq→dir | [P] |
| ≠ (!=, <>, /=) | "is not equal to" / "is different from" | "é diferente de" / "não é igual a" | Idem; ASCII != / <> mapeiam para ≠ [P para ≠; S para ASCII] | [S] |

## 4. Modais □ ◇

| Símb. | EN | PT-BR | Prosódia / quando NÃO verbalizar | St |
|---|---|---|---|---|
| □A | "necessarily A" / "it is necessary that A" / "box A" (só metalinguagem) | "necessariamente A" / "é necessário que A" | Operador anteposto, sem pausa interna; escopo por pausa/frase. Leitura "box" só ao soletrar, nunca em aula | [P] |
| ◇A | "possibly A" / "it is possible that A" / "diamond A" (só metalinguagem) | "possivelmente A" / "é possível que A" | Idem □ | [P] |
| Nota | Leituras deônticas/epistêmicas/temporais ("it is obligatory/known that", "it will always be") seguem o mesmo padrão prosódico, trocando o advérbio | "é obrigatório que / sabe-se que / será sempre que" etc. | Nunca verbalizar "square/diamond" em leitura fluente | [S] |

## 5. Consequência / metalógica

| Símb. | EN | PT-BR | Prosódia / quando NÃO verbalizar | St |
|---|---|---|---|---|
| ⊢ (single turnstile) | "proves" / "derives" / "yields"; "Γ proves B"; "B is derivable from Γ"; ⊢B = "B is a theorem" | "prova" / "deriva"; "Γ prova B"; "B é derivável de Γ"; ⊢B = "B é teorema" | Pausa curta antes/depois; lista de premissas à esquerda lê-se com "and/e" ou pausa enumerativa. Nunca "turnstile" em leitura fluente | [P] |
| ⊨ (double turnstile) | "entails" / "semantically entails" / "models"; "Γ entails B"; ⊨B = "B is a tautology/valid" | "acarreta (semanticamente)" / "tem B como consequência semântica"; ⊨B = "B é tautologia/válida" | Idem ⊢; distinção ⊢ (prova) vs ⊨ (verdade) deve sair na palavra, não no símbolo | [P] |
| \|- (ASCII ⊢) | proves | prova | Mapear para ⊢ | [S] |
| \|= (ASCII ⊨) | entails | acarreta | Mapear para ⊨ | [S] |
| ⊬ / ⊭ | "does not prove / does not entail" | "não prova / não acarreta" | Idem, com negação anteposta | [S] |

## 6. Conjuntos e construtor

| Símb. | EN | PT-BR | Prosódia / quando NÃO verbalizar | St |
|---|---|---|---|---|
| ∈ | "is in" / "is an element of" / "belongs to" | "pertence a" / "é elemento de" / "está em" | Sem pausa | [P] |
| ∉ | "is not in" | "não pertence a" | Idem | [P] |
| ⊆ | "is a subset of" (impróprio, admite igualdade) | "está contido em" / "é subconjunto de" | Sem pausa; não distinguir ⊆/⊂ na fala a menos que o texto exija ("…or equal") | [P] |
| ⊂ (ambíguo: próprio em muitos textos, impróprio em outros) | "is a (proper) subset of" | "está contido propriamente em" (quando próprio) | Filtro: ler "subset/subconjunto"; só explicitar "proper/propriamente" se o livro definir ⊂ como próprio | [S] |
| ⊇ / ⊃ (conjuntos) | "is a superset of" | "contém" / "é superconjunto de" | Idem ⊆/⊂ espelhado | [P] |
| ∪ | "union" / "A union B" | "união" / "A união B" | Sem pausa | [P] |
| ∩ | "intersection" | "intersecção" | Sem pausa | [P] |
| ∖ (menos conjunto) | "minus" / "set-minus" / "without" | "menos" / "diferença" | "A minus B" / "A menos B" | [S] |
| ∅ | "the empty set" | "o conjunto vazio" | Nunca "zero/circle"; artigo definido obrigatório | [P] |
| ℘ / P (potência) | "the power set of A" | "o conjunto das partes de A" | Nunca "P caligráfico"; ler a função, não a fonte | [S] |
| {x \| φ} / {x : φ} | "the set of x such that φ" / "the set of all x such that φ" | "o conjunto dos x tais que φ" | **Chaves: ler "the set of/o conjunto (de)" no abrir e NADA no fechar** (o fechar vira pausa/entonação descendente). Barra \| e dois-pontos : **ambos** lêem-se "such that/tal que" neste contexto — nunca "bar/barra" nem "colon/dois-pontos". Pausa após "such that/tal que" | [P] |
| {a,b,c} (extensão) | "the set containing a, b and c" | "o conjunto contendo a, b e c" | Abrir: "the set (containing)/o conjunto"; vírgulas internas viram pausa enumerativa, não "comma". Fechar: silêncio | [S] |

## 7. Gregas, iota, cantos, functores, primos

| Símb. | EN | PT-BR | Prosódia / quando NÃO verbalizar | St |
|---|---|---|---|---|
| φ ψ χ θ α β γ … (metavariáveis) | "phi/psi/chi/theta/alpha…" (pronúncia inglesa da letra) | "fi/psi/qui/teta/alfa/beta/gama…" | Sem pausa; φ sobre sentença lê-se como a sentença que instancia ("phi" = nome, não conteúdo) | [P] |
| ℩x φ (iota, descrições definidas — Russell/PM) | "the x such that φ" / "the unique x such that φ" | "o x tal que φ" / "o único x tal que φ" | Idem quantificador: pausa após variável; "iota" só em soletração. Uso atual raro fora de história/lógica livre | [S] |
| ⌜φ⌝ (cantos de Quine, quasi-citação) | "quasi-quote phi" / "quote-phi" / "the expression phi" (didático: "quine-quote…end-quote") | "quase-citação de fi" / "a expressão fi" | Em aula quase sempre se **ignora** o canto e lê-se o conteúdo, marcando menção com pausa+entoação ("a expressão…"). Verbalizar "quine corners" só quando o tema É a citação. Alternativa ⟦ ⟧ ("Oxford brackets") idem | [S] |
| F(x,y) | "F of x and y" / "F applied to x, y" (predicado: "x bears F to y" conforme leitura) | "F de x e y" / "F aplicado a x, y" | Vírgula interna = pausa curta, nunca "comma". Parênteses do functor: silêncio (a justaposição + "of/de" já desambigua) | [S] |
| p' (primo) | "p prime" | "p linha" | Sem pausa; p'' = "p double-prime"/"p duas-linhas"; nunca "apóstrofo" em leitura fluente | [S] |

## 8. Pontuação dentro de fórmula (regra geral: PAUSA, não palavra)

| Símb. | EN | PT-BR | Prosódia / quando NÃO verbalizar | St |
|---|---|---|---|---|
| ( ) em fórmulas aninhadas | pausa + agrupamento entoacional; "open/close paren" SÓ para ditar ou desfazer ambiguidade ("open paren A or B close paren, and C") | pausa + agrupamento; "abre/fecha parêntese" SÓ ditando ou desfazendo ambiguidade | **Padrão de aula/audiolivro: NÃO verbalizar; trocar por pausa e contorno.** MathSpeak verboso soletra; ClearSpeak/aula suprime. Filtro TTS: default = silêncio; modo ditado = verbalizar | [S] |
| , (vírgula lógica: ∀x, φ; F(x,y); Γ, A ⊢) | pausa curta ("comma" nunca em leitura fluente) | pausa curta | Em enumeração de premissas vira "and/e" final: "A, B ⊢ C" = "A and B prove C" | [S] |
| ; (ponto-e-vírgula) | pausa média (fronteira maior que vírgula) | pausa média | Nunca "semicolon"; separa sequentes/ramos | [I] |
| : "such that" (∃x: φ; {x: φ}) | "such that" + pausa | "tal que" + pausa | Nunca "colon" em leitura fluente | [S] |
| : proporção/razão/tipo (a:b; x:A) | "is to" / "of" / "has type" | "está para" / "de" / "de tipo" | Decidir pelo contexto: antes de fórmula = tal-que; entre termos = proporção/tipo | [I] |

## 9. Miscelânea pedida

| Símb. | EN | PT-BR | Prosódia / quando NÃO verbalizar | St |
|---|---|---|---|---|
| §N | "section N" | "seção N" | Sem pausa interna | [S] |
| / em "A/B" prosaico | "A slash B" → resolver: "A or B" / "A per B" / "A over B" conforme contexto | "A barra B" → resolver: "A ou B" / "A por B" | Em prosa lógica, quase sempre "or/ou" ou fração; nunca deixar o TTS dizer "slash" no produto final [I para a recomendação de resolver] | [I] |
| ∴ | "therefore" / "hence" | "logo" / "portanto" | Pausa antes; início de conclusão | [P] |
| ∵ | "because" / "since" | "porque" / "pois" | Pausa antes | [P] |
| ⊕ | "xor" / "exclusive or" (conjuntos: "symmetric difference") | "ou exclusivo" (conjuntos: "diferença simétrica") | Sem pausa | [S] |
| ⊗ | "tensor (product)" (linear: "multiplicative conjunction") | "produto tensorial" | Sem pausa; em lógica linear, "times/vezes" conforme manual | [S] |
| ≈ | "is approximately equal to" | "é aproximadamente igual a" | Sem pausa | [P] |
| ≃ / ∼ | "is equivalent to / is similar to / is isomorphic to" (contexto!) | "é equivalente a / é semelhante a" | ∼ em lógica costuma ser negação alternativa ("not/não"); decidir pelo manuscrito: entre fórmulas = negação; entre termos = semelhança | [S] |
| ∥ | "is parallel to" / "is independent of" (prova: "is parallel") | "é paralelo a" / "é independente de" | Sem pausa | [S] |
| × | "times" / "cross (product)" / "Cartesian product" | "vezes" / "produto cartesiano" | Sem pausa | [P] |
| λ (x. M, λx.M) | "lambda x (dot) M" → didático "the function x maps to M" | "lambda x, M" → "a função que leva x em M" | O ponto do λ vira pausa, nunca "dot/ponto" | [S] |
| ≡ | "is identically / is defined as" (lógica: "is logically equivalent"; congruência conforme contexto) | "é idêntico a / é definido como" (lógica: "é logicamente equivalente") | Sem pausa; ≡ vs ↔: ≡ é metalógica/definição, ↔ é conectivo — a fala marca com "is defined as/é definido como" vs "iff/se e somente se" | [S] |
| ≢ | "is not equivalent/identical to" | "não é equivalente a" | Idem ≡ negado | [S] |
| ≤ ≥ < > | "is less/greater than (or equal to)" | "é menor/maior (ou igual a) que" | Sem pausa | [P] |
| <= >= != <> (ASCII) | mapear para ≤ ≥ ≠ | mapear idem | Filtro resolve antes do TTS | [S] |
| ⇒ | "implies" (metalógico: "if…then" válido) | "implica" | Distinção didática BR (UFR): → conectivo interno, ⇒ relação metateórica válida. Na fala corrida ambos saem "se…então/implica"; em aula de metalógica marcar "implies yields" | [P] |
| ⇔ | "iff" / "is equivalent to" | "se e somente se" / "é equivalente a" | Idem ⇒ espelhado | [P] |
| ⇒ vs ⊃ (ferradura) | Aula atual: ambos "if…then/implies"; ⊃ histórico (Principia) = condicional | "se…então / implica" para ambos | **Como decidir ⊃**: entre proposições/fórmulas = implicação ("se…então"); entre termos de conjunto (A⊃B com letras de conjunto) = superconjunto ("contém"). Desempate: se cercado por ∈/⊆/∪/∩/∅ = conjunto; se cercado por ¬/∧/∨/⊢ = condicional. Na dúvida, manter a ambiguidade e anotar [?] em vez de chutar | [S] |
| ^ _ (sobre/subscrito) | "to the / sub" → didático: "x squared / x sub n" | "elevado a / índice" → "x ao quadrado / x índice n" | Nunca "caret/underline/circumflex"; número vira ordinal/elevado, letra vira índice | [S] |
| ° ′ ″ | "degrees / minutes / seconds" (geom.); em lógica ′=primo (v. p') | "graus / minutos / segundos"; ′ lógico = "linha" | ° em lógica pura é raro; não confundir ′ (primo) com ' (aspa) | [S] |

## 10. O que deve ser SILÊNCIO (nunca verbalizar no produto final)

1. Parênteses/colchetes de agrupamento em leitura fluente (viram pausa+entoação; só ditado verbaliza) [S].
2. Chave de fechadura `}` do construtor (o abrir virou "o conjunto de"; o fechar é pausa descendente) [S].
3. Espaços, quebras de linha, fonte/tamanho/cor, número de fórmula/label ("(3)" de numeração), cabeçalho de prova — viram pausa ou nada [I].
4. `'` como apóstrofo tipográfico quando for primo (vira "prime/linha", nunca "apostrophe") [S].
5. `|` e `:` quando forem "tal que" (vira a palavra, nunca "bar/colon") [S].
6. Subscrito meramente tipográfico de variável ligada repetida (o índice diferencia na escrita; na fala mantém-se o nome + pausa, sem dizer "subscrito") [I].

## Fontes principais

- Magnus (forallx Calgary) — leituras "for all x / there is…such that", ⊢/⊨, modais; Apêndice A (variantes ¬ ∼, ∧ &, ∨, → ⊃, ↔ ≡): https://forallx.openlogicproject.org/html/Ch23.html · https://forallx.openlogicproject.org/html/Ch42.html · https://forallx.openlogicproject.org/html/A1.html
- List of logic symbols (leituras "implies; iff; for all; there exists; proves/entails; therefore/∴"): https://en.wikipedia.org/wiki/List_of_logic_symbols (via latexedit/geeksforgeeks espelho) + Turnstile/Double-turnstile: https://en.wikipedia.org/wiki/Turnstile_(symbol) · https://en.wikipedia.org/wiki/Double_turnstile
- SEP Modal Logic ("necessarily/possibly", □/◇ como quantificadores) + Boxes&Diamonds OpenLogic ("□p = necessarily p"): https://plato.stanford.edu/archives/fall2025/entries/logic-modal · https://bd.openlogicproject.org/bd-screen.pdf
- SEP Quotation / Quasi-quotation (cantos ⌜⌝, menção vs uso): https://en.wikipedia.org/wiki/Quasi-quotation · discussão https://philosophy.stackexchange.com/questions/94264/quines-quasi-quotation
- Iota ℩ (Russell/PM, "the y satisfying φ"): https://philosophy.stackexchange.com/questions/51563/what-is-the-symbol-in-formal-logic
- Horseshoe ⊃ (condicional vs superset, Principia): https://en.wikipedia.org/wiki/Horseshoe_(symbol)
- Therefore ∴ ("read therefore"): https://en.wikipedia.org/wiki/Therefore_sign
- MathSpeak/ClearSpeak/SRE (pausa vs verbalização, parênteses, "such that", MathJax a11y, ERIC RR-16-23 ClearSpeak): https://docs.mathjax.org/en/v4.1/basic/a11y-extensions.html · http://speechruleengine.org/ · https://files.eric.ed.gov/fulltext/ED570857.pdf · https://github.com/Speech-Rule-Engine/speech-rule-engine
- PT-BR: UFS Fundamentos de Matemática Aula 2 (¬ ∼, → ⊃, ∀ "para todo/qualquer que seja", ∃ "existe/existe pelo menos um"): https://cesad.ufs.br/ORBI/public/uploadCatalago/15243116022012Fundamentos_de_Matematica_aula_2.pdf · UFR Lógica e Conjuntos (¬ "não p", ∀/∃, → vs ⇒, ↔ vs ⇔): https://ufr.edu.br/matematica/wp-content/uploads/2026/05/Logica-e-Conjuntos.pdf · UFSC dicionário (~ ¬ negação, → ⇒ condicional, ∀ ∃ ∨ ∧, / "tal que", ∈ "pertence"): https://repositorio.ufsc.br/bitstream/handle/123456789/91633/258964.pdf?sequence=1
