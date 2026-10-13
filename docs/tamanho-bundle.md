# Tamanho do bundle e vozes sob demanda

Auditoria medida em 2026-10-13 sobre o `EdgeSpeak.app` montado pelo
`build-app.sh`. Primeira rodada: release v0.1.0, zip de 222 MB, bundle de
280 MB (com o app em execução, sem rebuild). Segunda rodada, após remover
as vozes embutidas e podar a base Python, com rebuild medido: bundle de
130 MB e zip de 112 MB (mesmo `ditto -c -k` do empacotamento).

## Onde estão os megabytes

O bundle soma 280 MB. Os componentes, do maior ao menor: vozes 121 MB
(dois pares `.onnx` de 63.201.294 bytes cada, mais dois `.onnx.json` de ~5
KB), wheels 82 MB, base Python 75 MB e binário 1,7 MB. Os scripts e o ícone
somam menos de 1 MB. As vozes são 43% do bundle e a suspeita do dono se
confirma: são o maior componente isolado.

Nos wheels, três arquivos concentram quase tudo: o do Piper com 33 MB, o
do PyMuPDF com 23 MB e o do onnxruntime com 20 MB. O numpy leva 5,2 MB e o
restante fica abaixo de 2 MB somado.

## Quanto o zip encolheu

Vozes fora: o `.onnx` comprime pouco (cerca de 12%), e o zip caiu de 222 MB
para 112 MB medidos após o rebuild. A base Python podada (Tcl/Tk, idle,
headers, pip da base, `.pyc`) saiu de 75 MB para 46 MB — cerca de 29 MB a
menos no bundle, que foi de 280 MB para 130 MB. A conta fecha: 121 MB de
vozes mais 29 MB de poda, 150 MB cortados.

O que resta é motor, não bagunça: PyMuPDF (23 MB, extrai o texto), onnxruntime
(20 MB) mais Piper (33 MB, sintetizam offline) e numpy (5,2 MB). Abaixo dos
112 MB só trocando peça — não há build oficial menor desses três —, o que
fica como questão em aberta, sem dono.

## Origem e integridade das vozes

As cinco vozes do seletor vêm do repositório piper-voices no Hugging Face,
via `https://huggingface.co/rhasspy/piper-voices/resolve/main/`: Faber
(`pt/pt_BR/faber/medium`), Lessac (`en/en_US/lessac/medium`), Edresson
(`pt/pt_BR/edresson/low`), Cadu (`pt/pt_BR/cadu/medium`) e Jeff
(`pt/pt_BR/jeff/medium`). Três delas já baixavam sob demanda antes desta
mudança; Faber e Lessac eram as únicas embutidas.

Hoje não há checksum: a validação é piso de tamanho (1 MB no `.onnx`, 512
bytes no `.onnx.json`) mais leitura do `.onnx.json` como JSON, com download
para temporário `.part` no mesmo diretório e rename atômico só após
validado. A assessoria propõe, como passo seguinte, fixar o SHA-256 de cada
par no código após um download íntegro conferido — questão em aberto, sem
dono definido.

## Destino e primeira utilização

O destino é `~/Library/Application Support/EdgeSpeak/voices`, criado sob
demanda. A experiência mínima já existe no código e não muda: ao escolher
uma voz offline pela primeira vez, o status mostra o download com
megabytes (`Baixando a voz offline (X/Y MB)…`, cerca de 63 MB, uma única
vez), depois o carregamento e a síntese frase a frase. Sem rede nesse
momento, a leitura offline falha com erro legível — consequência assumida
da decisão de produto. Observação menor: o `PiperTTS` emite essas mensagens
como literais em pt-BR, sem passar pelas chaves `progress.downloadingVoice*`
do `L10n`; a tradução para o inglês existe nas chaves mas não é usada ali.

## Migração de quem já tem o app

Nenhuma cópia é necessária. Quem já baixou vozes para o Application Support
continua com elas válidas (a validação de cache as aceita). Quem usava as
vozes embutidas do bundle antigo baixa uma vez, cerca de 63 MB, na primeira
leitura após atualizar. O `bundledVoicesDir` foi mantido no Swift de
propósito: no bundle novo ele retorna nil sem custo, e em dev continua
servindo `Build/staging/voices` antes da rede.

## O que mudou nesta tarefa

O `build-app.sh`: o passo 3 deixou de baixar e embutir as vozes, o `cp` de
`voices` para `Resources` saiu, e um passo 2b poda a base (Tcl/Tk, idle,
headers, pip da base, `.pyc`) depois dos downloads, que usam `$BASE -m pip`.
O runtime nunca usa o pip da base — nasce o venv por `base -m venv`
(ensurepip mantido) e instala pelos wheels com o pip do próprio venv —, e
nenhum script do app importa tkinter. Verificação do orquestrador após o
rebuild com o app fechado: venv de teste criado pela base podada com pip
26.2.1 via ensurepip, `swift test` com 111 testes em 13 suítes verdes,
bundle de 130 MB e zip de 112 MB. Nenhum Swift foi tocado.

## Texto proposto para o README (não aplicado)

"A leitura offline baixa a voz escolhida uma única vez (cerca de 60 MB por
voz, em `~/Library/Application Support/EdgeSpeak/voices`) e depois funciona
sem rede. O download exige internet; cada voz é baixada uma só vez."
