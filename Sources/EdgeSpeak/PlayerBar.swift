import SwiftUI
import AppKit

/// Plano item 30: the ONLY home of the floating bar's two layout numbers.
/// `ContentView` reserves the bottom band with `reserve` (bar ≈ 60 pt + the
/// `gap` below) and places the bar with `gap`; if the bar ever grows (e.g.
/// the progress readout wrapping to two lines) BOTH numbers change here, or
/// the bar covers the last line of the text again. Never repeat these
/// literals in the call sites.
enum PlayerBarMetrics {
    /// Bottom padding between the window content and the floating bar.
    static let gap: CGFloat = 14
    /// Content bottom clearance while the bar is visible (bar height + gap).
    static let reserve: CGFloat = 74
}

/// Floating control bar in the IINA OSC style.
///
/// It only carries the reading transport: what is document action (open
/// file, voice, cadence, options) lives in the `Toolbar`. It receives state already assembled
/// and returns intents via callback, without knowing the sentence list nor the voice.
///
/// The engine remains the internal `StreamingPlayer`: `edge-playback`
/// (an mpv wrapper) was discarded because it returns no word times nor
/// allows jumping by sentence — the IINA design is copied, not the player.
struct PlayerBar: View {
    @ObservedObject var controller: SpeechController

    /// Characters of the active list, shown when there is no position yet.
    let textLength: Int
    /// Enables play (there is text/audio and no synthesis blocking).
    let canPlay: Bool
    /// Plano item 20: frase anterior/próxima existem quando há áudio para
    /// mover dentro (a mesma régua do ±15 s, `controller.canSkip`) — aparecem
    /// junto dos vizinhos ±15 s (mesma condição `hasPosition`).
    let canNavigateSentences: Bool
    /// Toggles play/pause; resolves the list and the voice, which only `ContentView` knows.
    let onTogglePlay: () -> Void

    /// Manual transport navigation (track dragged or ±15 s), called
    /// after seeking the audio: `ContentView` uses it to bring the PDF to the corresponding
    /// passage even with "Follow reading" off.
    let onTransport: () -> Void

    /// Plano item 20: vizinha de frase (−1 anterior, +1 próxima); roteia por
    /// `clickToPlay` em `ContentView`.
    let onSentenceStep: (Int) -> Void

    /// Interface language (EN default); tooltips come from the `L` catalog.
    @AppStorage(AppSetting.languageKey) private var appLanguageRaw: String = AppSetting.languageDefault
    private var language: L.Language { L.Language(rawValue: appLanguageRaw) ?? .en }

    /// Minimum gap between seeks while scrubbing.
    private static let scrubThrottle: TimeInterval = 0.25

    /// Pointer value during the track drag; nil returns the time to the player.
    @State private var dragValue: Double?

    /// Plano item 27: pointer over the main button (hover feedback).
    @State private var playHovered = false
    @State private var isDragging = false
    @State private var pendingSeekTask: Task<Void, Never>?
    @State private var lastSeekAt: Date?

    var body: some View {
        VStack(spacing: 6) {
            // Progress bar only while synthesis has not produced sound yet.
            if controller.isBusy, synthesisFraction == nil {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack(spacing: 10) {
                // Plano item 27: os MESMOS controles sempre presentes — quem
                // desaparece desloca os vizinhos a cada transição de leitura.
                // Quem não pode agir, fica desabilitado (incl. stop/cancel).
                stopOrCancelButton
                sentenceStepButton(-1)
                skipButton(-15)
                playButton
                skipButton(15)
                sentenceStepButton(1)

                timeAndScrubber
                volumeControl

                barButton("square.and.arrow.down", L.get("player.exportAudio", locale: language), accessibilityLabelText: L.get("player.exportAudio", locale: language)) {
                    controller.exportMP3()
                }
                .disabled(!canSave)
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

    // MARK: - Actions

    /// Plano item 27: cancel/stop ocupa sempre o MESMO lugar — síntese mostra
    /// o cancelar; fora dela, o parar (desabilitado quando não há o parar).
    /// O ⌘. continua amarrado ao item (inofensivo desabilitado).
    private var stopOrCancelButton: some View {
        let busy = controller.isBusy
        let helpKey = busy ? "player.stopSynthesis" : "player.stopReading"
        return barButton(
            busy ? "xmark" : "stop.fill",
            L.get(helpKey, locale: language),
            accessibilityLabelText: L.get(helpKey, locale: language)
        ) {
            busy ? controller.cancelSynthesis() : controller.stopPlayback()
        }
        .disabled(!busy && !canStop)
        .keyboardShortcut(".", modifiers: .command)
    }

    /// Plano item 20: frase anterior (−1) / próxima (+1). Ícones de fim de
    /// trilho (`backward.end`/`forward.end`): pulo de FRASE, não de tempo.
    /// `onSentenceStep` roteia por `clickToPlay` em ContentView — jump à
    /// frente, follow reativado e pending de `jumpToSegment` já são de casa.
    private func sentenceStepButton(_ direction: Int) -> some View {
        let previous = direction < 0
        let labelText = previous
            ? L.get("ui.previousSentence", locale: language)
            : L.get("ui.nextSentence", locale: language)
        return barButton(
            previous ? "backward.end" : "forward.end",
            labelText,
            accessibilityLabelText: labelText
        ) {
            onSentenceStep(direction)
            onTransport()
        }
        .disabled(!canNavigateSentences)
    }

    private func skipButton(_ seconds: TimeInterval) -> some View {
        let forward = seconds > 0
        let labelText = forward
            ? L.get("player.skipForward", locale: language)
            : L.get("player.skipBack", locale: language)
        return barButton(
            forward ? "goforward.15" : "gobackward.15",
            labelText,
            accessibilityLabelText: labelText
        ) {
            controller.skip(seconds)
            onTransport()
        }
        // Enabled whenever there is a measured position to move within — NOT
        // while `isBusy`. Synthesis runs for minutes on a long text, and gating
        // on it left the ±15 s dead for the whole reading, exactly when it was
        // wanted. The seek itself already clamps to the audio that exists
        // (`canSkip`), so jumping during synthesis is safe.
        .disabled(!controller.canSkip)
    }

    /// Central circular button, as in IINA. Enter toggles; space is handled
    /// in `ContentView` (only outside the editor), hence no shortcut here.
    ///
    /// The icon is always a real play/pause — never `hourglass` during
    /// synthesis: while the first slice does not arrive, the button is disabled
    /// (prevents a second click from canceling and restarting synthesis) but shows
    /// play, instead of looking stuck.
    ///
    /// Paused DURING synthesis the button stays live: the audio already
    /// synthesized is resumable, and `SpeechController.play` has the branch
    /// that spends the hold (`isPaused && isBusy && inflight == key`) instead
    /// of restarting. With the button dead, pausing mid-synthesis left cancel
    /// (⌘.) as the only way out.
    /// Plano item 27: cor de SISTEMA para o play desabilitado (nada de cinza
    /// arbitrário: `unemphasizedSelectedContentBackgroundColor`) e hover real
    /// no botão principal — `.borderless` + `onHover` clareiam o círculo, o
    /// padrão dos botões grandes dos players nativos.
    private var playButton: some View {
        let disabled = !canPause && (!canPlay || playHasNothingToDo)
        return Button {
            onTogglePlay()
        } label: {
            Image(systemName: canPause ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(disabled ? Color.secondary : .white)
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(
                        disabled
                            ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                            : (playHovered
                                ? Color.accentColor.opacity(0.85)
                                : Color.accentColor))
                )
                .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .onHover { playHovered = $0 }
        .keyboardShortcut(.defaultAction)
        .disabled(disabled)
        .accessibilityLabel(Text(canPause
            ? L.get("player.pause", locale: language)
            : L.get("player.play", locale: language)))
        .help(L.get("player.playPauseHelp", locale: language))
        .accessibilityHint(Text(L.get("player.playPauseHelp", locale: language)))
    }

    /// Time + track when there is a position; otherwise, the character count.
    @ViewBuilder
    private var timeAndScrubber: some View {
        if hasPosition {
            Text("\(Self.formatTime(scrubPosition)) / \(Self.formatTime(controller.knownDuration))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 96, alignment: .leading)
                .accessibilityLabel(Text(L.get("player.positionLabel", locale: language, args: Self.formatTime(scrubPosition), Self.formatTime(controller.knownDuration))))

            Slider(
                value: Binding(
                    get: { scrubPosition },
                    set: { dragValue = $0 }
                ),
                in: 0...max(controller.knownDuration, 0.1)
            )
            .onChange(of: dragValue) { _, newValue in
                guard let newValue else { return }
                // Throttled while dragged (one seek per `scrubThrottle` at
                // most); outside the drag — keyboard arrows end no gesture —
                // the trailing task delivers the newest value plus the PDF
                // reveal. The drag itself reveals only at the end.
                throttledSeek(to: newValue, reveal: !isDragging)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isDragging = true }
                    .onEnded { _ in
                        isDragging = false
                        // End of the drag: the last pointer value always lands,
                        // and the PDF comes to the passage once (not per tick).
                        if let value = dragValue {
                            pendingSeekTask?.cancel()
                            pendingSeekTask = nil
                            lastSeekAt = Date()
                            controller.seek(to: value)
                            onTransport()
                        }
                        dragValue = nil
                    }
            )
            .help(L.get("player.scrubHelp", locale: language))
            .accessibilityLabel(Text(L.get("player.scrubHelp", locale: language)))
        } else {
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(L.get("player.charCount", locale: language, args: textLength))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(L.get("player.charCount", locale: language, args: textLength)))
                Text(L.get("player.synthesisEstimate", locale: language))
                    .font(.caption2)
                    // Plano item 25: .tertiary abaixo/limite de 4,5:1 em
                    // legenda informativa; .secondary mantém a hierarquia.
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .help(L.get("player.textSizeHelp", locale: language))
            Spacer(minLength: 0)
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: volumeIcon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(controller.volume) },
                    set: { controller.volume = Float($0) }
                ),
                in: 0...1
            )
            .frame(width: 72)
            .help(L.get("player.volumeHelp", locale: language))
            .accessibilityLabel(Text(L.get("player.volumeHelp", locale: language)))
        }
    }

    /// One step of `delta` sentences. The shortcut is on the button itself, so it
/// works wherever the window has focus — including over the PDF and the panel,
    /// which is the point: the document walks without the pointer.
    private func sentenceButton(_ system: String, _ label: String, _ delta: Int) -> some View {
        Button {
            controller.stepSentence(by: delta)
        } label: {
            Image(systemName: system)
        }
        .buttonStyle(.borderless)
        .disabled(!hasPosition)
        .keyboardShortcut(KeyEquivalent(Character("\u{21E7}")), modifiers: delta < 0 ? [.option, .shift] : [.option])
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private func barButton(_ system: String, _ help: String, accessibilityLabelText: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(Text(accessibilityLabelText ?? help))
    }

    /// Scrub seek with throttle: a tick in the open interval is dropped during
    /// the drag (the end of the drag lands the value) or scheduled as trailing
    /// task outside it (keyboard bursts: the newest value plus the reveal).
    private func throttledSeek(to value: Double, reveal: Bool) {
        let sinceLast = lastSeekAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard sinceLast >= Self.scrubThrottle else {
            guard !isDragging else { return }
            let wait = Self.scrubThrottle - sinceLast
            pendingSeekTask?.cancel()
            pendingSeekTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                lastSeekAt = Date()
                controller.seek(to: value)
                if reveal { onTransport() }
            }
            return
        }
        lastSeekAt = Date()
        controller.seek(to: value)
        if reveal { onTransport() }
    }

    // MARK: - Derived state

    private var hasPosition: Bool { controller.hasAudio && controller.knownDuration > 0 }
    private var canPause: Bool { controller.isPlaying && !controller.isPaused }
    private var canStop: Bool { controller.isPlaying || controller.isPaused }
    private var canSave: Bool { controller.hasAudio && !controller.isBusy }

    /// Nothing playing and nothing to resume: the first slice of a synthesis
    /// already running has not arrived. A click there is a no-op (`play()`
    /// returns on the in-flight key) and canceling is what ⌘. is for, so the
    /// button stays dead — but ONLY there. Gating on the whole `isBusy` also
    /// covered "paused mid-synthesis", where the controller does resume
    /// (`streamer.resume()`), and Play stayed gray until the ending of a
    /// synthesis that lasts minutes.
    private var playHasNothingToDo: Bool {
        controller.isBusy && !controller.isPlaying && !controller.isPaused
    }

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

    /// Formats seconds as `m:ss` (or `h:mm:ss` for long audios).
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
