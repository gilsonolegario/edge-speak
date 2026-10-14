import Foundation

/// Names and defaults of every EdgeSpeak preference, in a single place.
///
/// The Settings window and `ContentView` read and write the SAME key with the
/// SAME default, always through these constants — never repeating the key
/// string by hand in two files. `voice` and `fontSize` keep the names that were
/// already persisted; cadence, follow and integral text get new keys
/// because until now they lived only as session `@State`.
enum AppSetting {
    static let voiceKey = "voice"
    static let voiceDefault = "en-US-AndrewNeural"

    /// Cadence persisted as `EdgeTTS.Rate`'s `percent: Int`.
    static let rateKey = "readingRatePercent"
    static let rateDefault = 0

    static let followKey = "followReading"
    static let followDefault = true

    static let integralKey = "integralText"
    static let integralDefault = false

    static let footnoteKey = "readFootnotes"
    static let footnoteDefault = true

    static let fontKey = "fontSize"
    static let fontDefault: Double = 17

    /// Limits: below 12 the text becomes illegible; above 42 the minimum
    /// window no longer fits, which would push the text out of view.
    static let minFontSize: Double = 12
    static let maxFontSize: Double = 42

    /// Full catalog of online voices (edge-tts, checked on 2026-10-10).
    static let englishVoices = [
        "en-US-AnaNeural",
        "en-US-AndrewNeural",
        "en-US-AriaNeural",
        "en-US-AvaNeural",
        "en-US-BrianNeural",
        "en-US-ChristopherNeural",
        "en-US-EmmaNeural",
        "en-US-EricNeural",
        "en-US-GuyNeural",
        "en-US-JennyNeural",
        "en-US-MichelleNeural",
        "en-US-RogerNeural",
        "en-US-SteffanNeural",
        "en-AU-NatashaNeural",
        "en-AU-WilliamMultilingualNeural",
        "en-CA-ClaraNeural",
        "en-CA-LiamNeural",
        "en-GB-LibbyNeural",
        "en-GB-MaisieNeural",
        "en-GB-RyanNeural",
        "en-GB-SoniaNeural",
        "en-GB-ThomasNeural",
        "en-HK-SamNeural",
        "en-HK-YanNeural",
        "en-IE-ConnorNeural",
        "en-IE-EmilyNeural",
        "en-IN-NeerjaNeural",
        "en-IN-PrabhatNeural",
        "en-KE-AsiliaNeural",
        "en-KE-ChilembaNeural",
        "en-NG-AbeoNeural",
        "en-NG-EzinneNeural",
        "en-NZ-MitchellNeural",
        "en-NZ-MollyNeural",
        "en-PH-JamesNeural",
        "en-PH-RosaNeural",
        "en-SG-LunaNeural",
        "en-SG-WayneNeural",
        "en-TZ-ElimuNeural",
        "en-TZ-ImaniNeural",
        "en-ZA-LeahNeural",
        "en-ZA-LukeNeural",
    ]

    static let portugueseVoices = [
        "pt-BR-FranciscaNeural",
        "pt-BR-AntonioNeural",
        "pt-BR-ThalitaMultilingualNeural",
        "pt-PT-DuarteNeural",
        "pt-PT-RaquelNeural",
    ]

    /// Short label for the menu: name (country, gender). Comes from the `L`
    /// catalog (keys `voice.*`), in the requested language; an unknown voice becomes
    /// the identifier itself.
    static func label(for voice: String, locale: L.Language) -> String {
        if PiperTTS.isOfflineVoice(voice) { return PiperTTS.label(for: voice, locale: locale) }
        let key = "voice.\(voice)"
        let resolved = L.resolve(key, locale: locale)
        return resolved == key ? voice : resolved
    }

    static func isKnown(_ voice: String) -> Bool {
        (PiperTTS.offlineVoices + englishVoices + portugueseVoices).contains(voice)
    }
}

/// Saved reading position per document+voice, to resume where it stopped.
///
/// Design: ONE dictionary `[key: seconds]` under `defaultsKey`; each entry
/// joins the document identifier (the file URL) and the voice, so switching
/// voices does not pull the other one's position. The "no position" default is the ABSENCE of the
/// entry (not zero): reopening without ever pausing/stopping searches nothing.
///
/// Everything goes through an injectable `defaults` so the round-trip is testable without UI
/// (an ephemeral `UserDefaults` suite suffices).
enum ReadingPositionStore {
    static let defaultsKey = "readingPositions"

    /// Below this, resuming is the same as starting from scratch — neither stores nor seeks.
    static let minimumResume: TimeInterval = 3

    /// Stable key of the entry: document + voice. No cadence on purpose:
    /// the audio can change duration across cadences, and the `shouldResume`
    /// guard already blocks any seek beyond what was measured.
    static func key(documentID: String, voice: String) -> String {
        "\(documentID)##\(voice)"
    }

    /// Stored seconds, or nil when never paused/stopped there ("no position").
    static func load(
        documentID: String, voice: String,
        defaults: UserDefaults = .standard
    ) -> TimeInterval? {
        let position = doubles(defaults.dictionary(forKey: defaultsKey) ?? [:])[key(documentID: documentID, voice: voice)]
        guard let position, position > 0 else { return nil }
        return position
    }

    /// Stores the position (call on pause/stop, with the clock still live).
    static func save(
        documentID: String, voice: String, position: TimeInterval,
        defaults: UserDefaults = .standard
    ) {
        guard position >= minimumResume else { return }
        var all = doubles(defaults.dictionary(forKey: defaultsKey) ?? [:])
        all[key(documentID: documentID, voice: voice)] = position
        defaults.set(all, forKey: defaultsKey)
    }

    /// Forgets the position (reading finished or transcription discarded).
    static func clear(
        documentID: String, voice: String,
        defaults: UserDefaults = .standard
    ) {
        var all = doubles(defaults.dictionary(forKey: defaultsKey) ?? [:])
        all.removeValue(forKey: key(documentID: documentID, voice: voice))
        defaults.set(all, forKey: defaultsKey)
    }

    /// Resumes only when there is something to resume AND the measured audio already covers the point —
    /// never seeks beyond what arrived (otherwise, starts from scratch).
    static func shouldResume(saved: TimeInterval?, knownDuration: TimeInterval) -> Bool {
        guard let saved, saved >= minimumResume else { return false }
        guard knownDuration > 0, saved <= knownDuration else { return false }
        return true
    }

    /// Reads the dictionary from `UserDefaults`, tolerating numbers arriving as Double or NSNumber.
    private static func doubles(_ dict: [String: Any]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, v) in dict {
            if let d = v as? Double { out[k] = d }
            else if let n = v as? NSNumber { out[k] = n.doubleValue }
        }
        return out
    }
}
