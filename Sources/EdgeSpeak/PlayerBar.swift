import SwiftUI
import AppKit

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
    /// Toggles play/pause; resolves the list and the voice, which only `ContentView` knows.
    let onTogglePlay: () -> Void

    /// Manual transport navigation (track dragged or ±15 s), called
    /// after seeking the audio: `ContentView` uses it to bring the PDF to the corresponding
    /// passage even with "Follow reading" off.
    let onTransport: () -> Void

    /// Interface language (EN default); tooltips come from the `L` catalog.
    @AppStorage(AppSetting.languageKey) private var appLanguageRaw: String = AppSetting.languageDefault
    private var language: L.Language { L.Language(rawValue: appLanguageRaw) ?? .en }

    /// Pointer value during the track drag; nil returns the time to the player.
    @State private var dragValue: Double?

    var body: some View {
        VStack(spacing: 6) {
            // Progress bar only while synthesis has not produced sound yet.
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
                    barButton("square.and.arrow.down", L.get("player.exportAudio", locale: language), accessibilityLabelText: L.get("player.exportAudio", locale: language)) {
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

    // MARK: - Actions

    /// Cancel during synthesis; stop when audio is playing or paused.
    @ViewBuilder
    private var stopOrCancelButton: some View {
        if controller.isBusy {
            barButton("xmark", L.get("player.stopSynthesis", locale: language), accessibilityLabelText: L.get("player.stopSynthesis", locale: language)) {
                controller.cancelSynthesis()
            }
            .keyboardShortcut(".", modifiers: .command)
        } else if canStop {
            barButton("stop.fill", L.get("player.stopReading", locale: language), accessibilityLabelText: L.get("player.stopReading", locale: language)) {
                controller.stopPlayback()
            }
        }
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
        .disabled(controller.isBusy)
    }

    /// Central circular button, as in IINA. Enter toggles; space is handled
    /// in `ContentView` (only outside the editor), hence no shortcut here.
    ///
    /// The icon is always a real play/pause — never `hourglass` during
    /// synthesis: while the first slice does not arrive, the button is disabled
    /// (prevents a second click from canceling and restarting synthesis) but shows
    /// play, instead of looking stuck.
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
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(!canPause && (!canPlay || controller.isBusy))
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
                if let newValue {
                    controller.seek(to: newValue)
                    onTransport()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { _ in dragValue = nil }
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
                    .foregroundStyle(.tertiary)
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

    private func barButton(_ system: String, _ help: String, accessibilityLabelText: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(Text(accessibilityLabelText ?? help))
    }

    // MARK: - Derived state

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
