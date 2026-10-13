import SwiftUI
import AppKit

/// Barra de controle flutuante no estilo OSC do IINA.
///
/// Só carrega o transporte da leitura: o que é ação de documento (abrir
/// arquivo, voz, ritmo, opções) mora na `Toolbar`. Recebe o estado já montado
/// e devolve intenções por callback, sem conhecer a lista de frases nem a voz.
///
/// O motor permanece o `StreamingPlayer` interno: o `edge-playback`
/// (invólucro do mpv) foi descartado porque não devolve tempos de palavra nem
/// permite pular por frase — copia-se o desenho do IINA, não o tocador.
struct PlayerBar: View {
    @ObservedObject var controller: SpeechController

    /// Caracteres da lista ativa, mostrados quando ainda não há posição.
    let textLength: Int
    /// Habilita o play (há texto/áudio e nenhuma síntese bloqueando).
    let canPlay: Bool
    /// Alterna play/pausa; resolve a lista e a voz, que só a `ContentView` conhece.
    let onTogglePlay: () -> Void

    /// Navegação manual do transporte (trilho arrastado ou ±15 s), chamado
    /// depois de buscar o áudio: a `ContentView` usa para levar o PDF ao trecho
    /// correspondente mesmo com o "Seguir leitura" desligado.
    let onTransport: () -> Void

    /// Idioma da interface (PT padrão); as ajudas saem do catálogo `L`.
    @AppStorage(AppSetting.languageKey) private var appLanguageRaw: String = AppSetting.languageDefault
    private var idioma: L.Idioma { L.Idioma(rawValue: appLanguageRaw) ?? .pt }

    /// Valor do ponteiro durante o arrasto do trilho; nil devolve o tempo ao player.
    @State private var dragValue: Double?

    var body: some View {
        VStack(spacing: 6) {
            // Barra de progresso só quando a síntese ainda não deu som.
            if controller.isBusy, synthesisFraction == nil {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack(spacing: 10) {
                stopOrCancelButton

                if hasPosition { skipButton(-15) }
                playButton
                if hasPosition { skipButton(15) }

                timeAndScrubber
                volumeControl

                if canSave {
                    barButton("square.and.arrow.down", L.get("player.exportAudio", locale: idioma)) {
                        controller.exportMP3()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    // MARK: - Ações

    /// Cancelar durante a síntese; parar quando há áudio tocando ou pausado.
    @ViewBuilder
    private var stopOrCancelButton: some View {
        if controller.isBusy {
            barButton("xmark", L.get("player.stopSynthesis", locale: idioma)) {
                controller.cancelSynthesis()
            }
            .keyboardShortcut(".", modifiers: .command)
        } else if canStop {
            barButton("stop.fill", L.get("player.stopReading", locale: idioma)) {
                controller.stopPlayback()
            }
        }
    }

    private func skipButton(_ seconds: TimeInterval) -> some View {
        let forward = seconds > 0
        return barButton(
            forward ? "goforward.15" : "gobackward.15",
            forward
                ? L.get("player.skipForward", locale: idioma)
                : L.get("player.skipBack", locale: idioma)
        ) {
            controller.skip(seconds)
            onTransport()
        }
        .disabled(controller.isBusy)
    }

    /// Botão central circular, como no IINA. Enter alterna; espaço é tratado
    /// na `ContentView` (só fora do editor), por isso não há atalho aqui.
    ///
    /// O ícone é sempre play/pausa de verdade — nunca `hourglass` durante a
    /// síntese: enquanto a primeira fatia não chega, o botão fica desabilitado
    /// (evita que um segundo clique cancele e reinicie a síntese) mas mostra
    /// play, em vez de parecer travado.
    private var playButton: some View {
        Button {
            onTogglePlay()
        } label: {
            Image(systemName: canPause ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill((!canPlay && !canPause) ? Color.gray.opacity(0.5) : Color.accentColor)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(!canPause && (!canPlay || controller.isBusy))
        .accessibilityLabel(Text(canPause
            ? L.get("player.pause", locale: idioma)
            : L.get("player.play", locale: idioma)))
        .help(L.get("player.playPauseHelp", locale: idioma))
    }

    /// Tempo + trilho quando há posição; senão, a contagem de caracteres.
    @ViewBuilder
    private var timeAndScrubber: some View {
        if hasPosition {
            Text("\(Self.formatTime(scrubPosition)) / \(Self.formatTime(controller.knownDuration))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 96, alignment: .leading)

            Slider(
                value: Binding(
                    get: { scrubPosition },
                    set: { dragValue = $0 }
                ),
                in: 0...max(controller.knownDuration, 0.1)
            )
            .onChange(of: dragValue) { _, newValue in
                if let newValue {
                    controller.seek(to: newValue)
                    onTransport()
                }
            }
            // Devolve `dragValue` a nil ao soltar. Sem isto o valor local ficava
            // preso no último ponto arrastado, e `scrubPosition` (que prefere o
            // ponteiro ao player) congelava o tempo e o trilho pelo resto da
            // sessão — o áudio seguia e a barra ficava parada.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { _ in dragValue = nil }
            )
            .help(L.get("player.scrubHelp", locale: idioma))
        } else {
            Spacer(minLength: 0)
            Text(L.get("player.charCount", locale: idioma, args: textLength))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .help(L.get("player.textSizeHelp", locale: idioma))
            Spacer(minLength: 0)
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: volumeIcon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(
                value: Binding(
                    get: { Double(controller.volume) },
                    set: { controller.volume = Float($0) }
                ),
                in: 0...1
            )
            .frame(width: 72)
            .help(L.get("player.volumeHelp", locale: idioma))
        }
    }

    private func barButton(_ system: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: - Estado derivado

    private var hasPosition: Bool { controller.hasAudio && controller.knownDuration > 0 }
    private var canPause: Bool { controller.isPlaying && !controller.isPaused }
    private var canStop: Bool { controller.isPlaying || controller.isPaused }
    private var canSave: Bool { controller.hasAudio && !controller.isBusy }

    private var scrubPosition: Double {
        min(dragValue ?? controller.elapsed, controller.knownDuration)
    }

    private var volumeIcon: String {
        let v = controller.volume
        if v <= 0.01 { return "speaker.slash.fill" }
        if v < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }

    private var synthesisFraction: Double? {
        guard controller.isBusy, controller.totalChunks > 0 else { return nil }
        return Double(controller.completedChunks) / Double(controller.totalChunks)
    }

    /// Formata segundos como `m:ss` (ou `h:mm:ss` para áudios longos).
    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
