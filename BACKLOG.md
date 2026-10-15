# BACKLOG — estado do app e do código em 2026-10-15

Legenda: [NO AR] verificado no aplicativo aberto em 2026-10-15 · [NA MAIN]
está no código, sem rechecagem ao vivo · [ABERTO] não implementado ·
[IDEIA] proposta, sem dono · [DESCARTADO] avaliado e recusado.

Sem suite automatizada e sem diretório de pesquisa desde 2026-10-15, por
decisão do dono (cópias fora do repositório). Verificação é `swift build`
mais o aplicativo ao vivo. Contagens de testes e links de documentos
antigos foram removidos deste arquivo por não corresponderem mais ao
código.

## Verificado ao vivo em 2026-10-15 (binário da junção, Neutrality_v82)

- [NO AR] Sem repetição da primeira leitura: o salto gasta a espera do
  pré-buffer em vez de ser desfeito por ela.
- [NO AR] Destaque acompanha desde a abertura: liberação na sonda de
  duração, timer reinstalado na retomada, posicionamento imediato.
- [NO AR] Clique no PDF toca da frase clicada (inclusive com o buffer
  ainda segurando o início): o destaque nasceu na frase 3 no instante
  zero e avançou monótono por 159 amostras, sem voltar uma frase,
  atravessando a troca de fatia até a pausa do usuário.
- [NO AR] Amarelo de palavra sobre o azul de frase, painel e PDF.
- [NO AR] Trilho com posição real e duração conhecida (1:17 / 13:58 na
  sessão); pausa retoma; posição salva por documento e voz.

## No código, sem rechecagem ao vivo

- [NA MAIN] Amarelo na página da própria caixa (palavras que continuam
  na página seguinte).
- [NA MAIN] Contexto do painel religado a cada atualização e alinhador
  invalidado na troca de documento.
- [NA MAIN] Casamento por palavra inteira no painel (citações com ano
  por extenso: a expansão vira falta limpa em vez de arrastar o cursor).
- [NA MAIN] Nudge contido pela duração da palavra; abertura rápida com
  fatias iniciais curtas (refino da outra raia, já na main).
- [NA MAIN] Notas: marcador anunciado, corpo ligado após o anúncio,
  régua como zona, opção de leitura, modos integral/filtrado.
- [NA MAIN] Motores online/offline, cache em disco, venv empacotado,
  exportação de áudio, temporizador, diagnóstico copiável, tradução
  PT/EN com seletor, descarte de transcrição.
- [ABERTO] Aparar somente o silêncio inicial da fatia (conflita com o
  respiro de fronteira do desenho atual — decisão humana pendente).
- [ABERTO] Rechecagem ao vivo do amarelo em citação com ano e página.

## Limites honestos (não são bugs)

- O artigo de teste não tem corpo de nota na camada de texto: só o
  marcador é anunciado.
- Símbolo que chega como imagem não é lido; voz online depende do
  endpoint da Microsoft.
- Sair antes dos 100% da síntese não deixa áudio em cache: reabrir
  sintetiza de novo desde o início.

## Ideias sem dono

- Dicionário de pronúncia, exportação com tempos, fila de documentos,
  sumário como capítulos: valor real, custo moderado.
- Sucessor do Piper (`sherpa-onnx`): avaliar somente se o Piper falhar.

## Descartados

- Modo ditado, estatísticas, IDs estáveis entre modos (sem consumidor).
- Branch de tradução integral: divergida e obsoleta; a tradução
  corrente segue no código.
- Sondas temporárias de diagnóstico e autoplay sob variável de
  ambiente: andaime de sessão, fora dos commits.
