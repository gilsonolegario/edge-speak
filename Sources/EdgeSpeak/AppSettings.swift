import Foundation
import NaturalLanguage

/// Names and defaults of every EdgeSpeak preference, in a single place.
///
/// The Settings window and `ContentView` read and write the SAME key with the
/// SAME default, always through these constants — never repeating the key
/// string by hand in two files. `voice` and `fontSize` keep the names that were
/// already persisted; cadence, follow and integral text get new keys
/// because until now they lived only as session `@State`.
enum AppSetting {
    static let voiceKey = "voice"
    /// PT-BR offline voice (owner decision 2026-10-17, "PT-BR by default").
    /// Offline on purpose: the online Microsoft voices are refusing
    /// connections worldwide since 2026-10-10 (catalog: `status.onlineBlocked`),
    /// so a fresh install must be able to speak without network. `@AppStorage`
    /// only applies the default when the key is absent — a saved choice wins.
    static let voiceDefault = PiperTTS.faberPtBR

    /// Cadence persisted as `EdgeTTS.Rate`'s `percent: Int`.
    static let rateKey = "readingRatePercent"
    static let rateDefault = 0

    static let followKey = "followReading"
    static let followDefault = true

    static let integralKey = "integralText"
    static let integralDefault = false

    static let footnoteKey = "readFootnotes"
    static let footnoteDefault = true

    /// Automatic resume of the saved position when a document already read is
    /// reopened. Default true because that is the app's behavior since 0.1.0 —
    /// the switch used to be inert (it wrote a key nobody read), so the default
    /// keeps what users already had instead of silently turning resume off.
    /// Absent key == default: the Settings toggle binds here via `@AppStorage`,
    /// and an explicit "no" is the only thing that turns the resume off.
    static let resumeKey = "resumeFromLast"
    static let resumeDefault = true

    /// Playback volume (0…1). It was the only preference living outside
    /// `AppSetting`: the bar's slider started at 100% on every launch. Stored as
    /// `Double` (the type `UserDefaults` keeps), read back as `Float` by the
    /// controller — the two ends of the bar agree by construction.
    static let volumeKey = "readingVolume"
    static let volumeDefault: Double = 1.0

    /// Volume read from `defaults`, clamped to 0…1.
    ///
    /// Absent key means the default (an explicit 0 is a real choice and is kept);
    /// a value outside the range (hand-edited plist, migration) falls back to the
    /// default instead of silencing the reading. Injectable so the round-trip is
    /// testable without touching the real preferences.
    static func loadVolume(defaults: UserDefaults = .standard) -> Double {
        guard let stored = defaults.object(forKey: volumeKey) as? NSNumber else {
            return volumeDefault
        }
        let value = stored.doubleValue
        guard value.isFinite, (0...1).contains(value) else { return volumeDefault }
        return value
    }

    /// Stores the volume clamped to 0…1 (the only range `AVAudioPlayer.volume` accepts).
    static func saveVolume(_ value: Double, defaults: UserDefaults = .standard) {
        guard value.isFinite else { return }
        defaults.set(min(1, max(0, value)), forKey: volumeKey)
    }

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

/// Item 57b of the improvement plan (2026-10-17): detects the language of a
/// document's text on-device (`NLLanguageRecognizer`, no network anywhere in
/// this path) and suggests a compatible voice the app can actually speak.
///
/// The suggestion prefers OFFLINE voices on purpose: the online Microsoft
/// voices are refusing connections worldwide since 2026-10-10 (registered in
/// the catalog as `status.onlineBlocked`), while the offline Piper voices
/// always work. Languages without any voice in the app (German, French…) come
/// back with `voice == nil` — the honest "detected, but nothing to speak with".
enum DocumentLanguage {
    struct Suggestion: Equatable {
        /// Language the recognizer believes the text is in.
        let language: NLLanguage
        /// Compatible voice, when the app has one; `nil` otherwise.
        let voice: String?
    }

    /// Below this confidence the recognizer is guessing; better ask with more text.
    static let minimumConfidence: Double = 0.3

    /// Pure: same text in, same suggestion out. A fresh recognizer per call
    /// keeps the result independent of previous scans, so tests and call sites
    /// never depend on execution order.
    static func suggest(for text: String) -> Suggestion? {
        let recognizer = NLLanguageRecognizer()
        // ObjC `processString:` imports as `processString(_:)` here (the
        // usual `process(_:)` refinement is not available in this SDK).
        recognizer.processString(text)
        guard let (language, confidence) =
            recognizer.languageHypotheses(withMaximum: 5)
                .max(by: { $0.value < $1.value }),
              confidence >= minimumConfidence
        else { return nil }
        return Suggestion(language: language, voice: voice(for: language))
    }

    /// Language → voice the app can speak. Portuguese and English only; the
    /// offline pick (not the catalog's first online voice) because of the
    /// worldwide online block registered as `status.onlineBlocked`.
    static func voice(for language: NLLanguage) -> String? {
        switch language {
        case .portuguese: return PiperTTS.faberPtBR
        case .english: return PiperTTS.lessacEnUS
        default: return nil
        }
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

    /// Separator between document and voice in the entry key.
    private static let entrySeparator = "##"

    /// Stable key of the entry: document + voice. No cadence on purpose:
    /// the audio can change duration across cadences, and the `shouldResume`
    /// guard already blocks any seek beyond what was measured.
    static func key(documentID: String, voice: String) -> String {
        "\(documentID)\(entrySeparator)\(voice)"
    }

    /// Document identifier of an entry key ("documento##voz"), nil when the key
    /// does not follow the format.
    static func documentID(fromKey key: String) -> String? {
        guard let separator = key.range(of: entrySeparator) else { return nil }
        let document = String(key[key.startIndex..<separator.lowerBound])
        return document.isEmpty ? nil : document
    }

    /// Whether the entry's document still resolves on disk. The identifier is
    /// the file URL's `absoluteString`; anything that is NOT a file URL (a
    /// plain name, a future format) counts as existing — the pruning erases
    /// only what it can judge.
    static func documentExistsOnDisk(_ documentID: String) -> Bool {
        guard let url = URL(string: documentID), url.isFileURL else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Entries whose document no longer resolves on disk are dropped (item 52
    /// of the robustness lane, 2026-10-17): one entry per document+voice lived
    /// in `UserDefaults` forever, 300 documents read in a year and nothing
    /// cleaned up by itself. Pure about the check, so the suite drives it.
    static func pruningMissingDocuments(
        _ all: [String: Double],
        documentExists: (String) -> Bool = documentExistsOnDisk
    ) -> [String: Double] {
        all.filter { entry, _ in
            // An unreadable key is kept: never erase what cannot be judged.
            guard let document = documentID(fromKey: entry) else { return true }
            return documentExists(document)
        }
    }

    /// Stored seconds, or nil when never paused/stopped there ("no position").
    static func load(
        documentID: String, voice: String,
        defaults: UserDefaults = .standard
    ) -> TimeInterval? {
        let stored = doubles(defaults.dictionary(forKey: defaultsKey) ?? [:])
        // The pruning rides on the read: it is the moment the app touches the
        // dictionary anyway, with no timer and no daemon.
        let all = pruningMissingDocuments(stored)
        if all.count != stored.count {
            defaults.set(all, forKey: defaultsKey)
        }
        let position = all[key(documentID: documentID, voice: voice)]
        guard let position, position > 0 else { return nil }
        return position
    }

    /// Drops entries whose document no longer exists on disk.
    static func prune(defaults: UserDefaults = .standard) {
        let all = defaults.dictionary(forKey: defaultsKey) ?? [:]
        var kept: [String: Any] = [:]
        var changed = false
        for (k, v) in all {
            let docID = k.split(separator: "#", maxSplits: 2).first.map(String.init) ?? k
            // documentID may be a URL/path; check existence when it looks like a path.
            let exists: Bool
            if docID.contains("/") {
                exists = FileManager.default.fileExists(atPath: docID)
            } else {
                exists = true
            }
            if exists {
                kept[k] = v
            } else {
                changed = true
            }
        }
        if changed { defaults.set(kept, forKey: defaultsKey) }
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

/// Recently opened documents, most recent first.
///
/// Why the app keeps its own list: it remembers WHERE a reading stopped (see
/// `ReadingPositionStore`) but not WHICH file it was, so the document the app
/// "remembers" could not be reopened with a click. Stored as plain
/// `UserDefaults` (same injectable `defaults` seam) rather than
/// `NSDocumentController`, which would claim a document lifecycle the app does
/// not have — it is a single reading window, not a multi-document editor.
enum RecentDocuments {
    static let defaultsKey = "recentDocuments"
    /// Bounded so a long reading life cannot grow the preference without end.
    static let limit = 12

    /// Files most recent first. Entries whose URL no longer parses are dropped on
    /// read, so a corrupted preference cannot wedge the menu.
    static func load(defaults: UserDefaults = .standard) -> [URL] {
        let raw = defaults.stringArray(forKey: defaultsKey) ?? []
        return raw.prefix(limit).compactMap { URL(string: $0) }
    }

    /// Moves `url` to the front, adding it if new and dropping duplicates and
    /// whatever falls past `limit`.
    static func note(_ url: URL, defaults: UserDefaults = .standard) {
        let id = url.absoluteString
        var entries = (defaults.stringArray(forKey: defaultsKey) ?? [])
            .filter { $0 != id && URL(string: $0) != nil }
        entries.insert(id, at: 0)
        defaults.set(Array(entries.prefix(limit)), forKey: defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
