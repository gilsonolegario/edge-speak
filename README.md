# EdgeSpeak

Leitor de PDF e texto com leitura em voz alta em fluxo. Cada fatia sintetizada começa a tocar assim que fica pronta, sem esperar a síntese do documento inteiro. A frase em leitura fica destacada no PDF e no painel de texto; com voz online, a palavra em leitura também é destacada.

## Motores

Duas vozes no mesmo transporte. A troca é feita pelo seletor de voz na toolbar.

Online (edge-tts): vozes neurais da Microsoft, exige rede. Devolve tempos por palavra, por isso o destaque palavra a palavra só existe neste modo.

Offline (Piper): síntese local, uma frase por vez, sem tempos de palavra. Neste modo há destaque da frase, sem karaokê por palavra. As vozes offline aparecem numa seção própria do seletor; o crédito e a licença de cada voz estão no CREDITS.md.

## Compilar e rodar

Pré-requisito: macOS 14+ e SwiftPM. O bundle embute o ambiente Python do motor online, então a máquina de destino não precisa de nada além do sistema e de rede para as vozes online.

```sh
swift build
swift test
./build-app.sh   # gera EdgeSpeak.app na raiz do projeto
```

O `./build-app.sh` baixa a base Python, os wheels e as vozes embutidas na primeira execução e monta o `.app` com tudo dentro. Detalhes do conteúdo do bundle estão no cabeçalho do próprio script.

Arquivos abrem de três formas: botão Abrir na toolbar (PDF, Markdown ou texto), duplo-clique no Finder com "Abrir com o EdgeSpeak" e arraste do arquivo ao ícone do app.

## Interface

O desenho segue o IINA. Toolbar no topo com Abrir, seletor de voz e menu de opções (ritmo, modo de texto e fonte). Abaixo fica o conteúdo: o PDF quando há documento, senão o painel de texto. Na base, uma barra de controle flutuante sempre visível carrega o transporte: play/pausa, trilho, ±15 s e volume.

Atalhos: Enter alterna play/pausa. Espaço faz o mesmo fora do editor de texto e fora do PDF, e é ignorado durante a síntese. Opção com seta esquerda ou direita pula 15 s para trás ou para a frente, exceto durante a escrita e durante a síntese.

## Onde vive o estado

O áudio sintetizado fica em cache em disco, com chave por texto, voz e cadência: reabrir o mesmo documento com a mesma voz e o mesmo ritmo reaproveita o áudio guardado em `Caches/EdgeSpeak`. O ambiente Python do motor online viaja dentro do bundle e é preparado no primeiro uso, em `Application Support/EdgeSpeak`.

## Contratos e créditos

O contrato de interfaces (arquivos, funções e regras entre camadas) está no INTERFACE.md. Os créditos e licenças das vozes offline estão no CREDITS.md.
