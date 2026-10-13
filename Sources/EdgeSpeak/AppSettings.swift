import Foundation

/// Nomes e padrões de todas as preferências do EdgeSpeak, num lugar só.
///
/// A janela de Ajustes e o `ContentView` leem e gravam a MESMA chave com o
/// MESMO padrão, sempre por estas constantes — nunca repetindo a string da
/// chave à mão em dois arquivos. `voice` e `fontSize` mantêm os nomes que já
/// estavam persistidos; ritmo, acompanhamento e texto integral ganham chaves
/// novas porque até aqui viviam só como `@State` da sessão.
enum AppSetting {
    static let voiceKey = "voice"
    static let voiceDefault = "en-US-AndrewNeural"

    /// Cadência persistida como o `percent: Int` de `EdgeTTS.Rate`.
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

    /// Limites: abaixo de 12 o texto fica ilegível; acima de 42 a janela
    /// mínima deixa de caber, o que empurraria o texto para fora da vista.
    static let minFontSize: Double = 12
    static let maxFontSize: Double = 42

    /// Catálogo completo de vozes online (edge-tts, verificado em 2026-10-10).
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

    /// Rótulo curto para o menu: nome (país, gênero), em ordem alfabética.
    static let voiceLabels: [String: String] = [
        "en-US-AnaNeural": "Ana (EUA, feminino)",
        "en-US-AndrewNeural": "Andrew (EUA, masculino)",
        "en-US-AriaNeural": "Aria (EUA, feminino)",
        "en-US-AvaNeural": "Ava (EUA, feminino)",
        "en-US-BrianNeural": "Brian (EUA, masculino)",
        "en-US-ChristopherNeural": "Christopher (EUA, masculino)",
        "en-US-EmmaNeural": "Emma (EUA, feminino)",
        "en-US-EricNeural": "Eric (EUA, masculino)",
        "en-US-GuyNeural": "Guy (EUA, masculino)",
        "en-US-JennyNeural": "Jenny (EUA, feminino)",
        "en-US-MichelleNeural": "Michelle (EUA, feminino)",
        "en-US-RogerNeural": "Roger (EUA, masculino)",
        "en-US-SteffanNeural": "Steffan (EUA, masculino)",
        "en-AU-NatashaNeural": "Natasha (Austrália, feminino)",
        "en-AU-WilliamMultilingualNeural": "William (Austrália, masculino)",
        "en-CA-ClaraNeural": "Clara (Canadá, feminino)",
        "en-CA-LiamNeural": "Liam (Canadá, masculino)",
        "en-GB-LibbyNeural": "Libby (Reino Unido, feminino)",
        "en-GB-MaisieNeural": "Maisie (Reino Unido, feminino)",
        "en-GB-RyanNeural": "Ryan (Reino Unido, masculino)",
        "en-GB-SoniaNeural": "Sonia (Reino Unido, feminino)",
        "en-GB-ThomasNeural": "Thomas (Reino Unido, masculino)",
        "en-HK-SamNeural": "Sam (Hong Kong, masculino)",
        "en-HK-YanNeural": "Yan (Hong Kong, feminino)",
        "en-IE-ConnorNeural": "Connor (Irlanda, masculino)",
        "en-IE-EmilyNeural": "Emily (Irlanda, feminino)",
        "en-IN-NeerjaNeural": "Neerja (Índia, feminino)",
        "en-IN-PrabhatNeural": "Prabhat (Índia, masculino)",
        "en-KE-AsiliaNeural": "Asilia (Quênia, feminino)",
        "en-KE-ChilembaNeural": "Chilemba (Quênia, masculino)",
        "en-NG-AbeoNeural": "Abeo (Nigéria, masculino)",
        "en-NG-EzinneNeural": "Ezinne (Nigéria, feminino)",
        "en-NZ-MitchellNeural": "Mitchell (Nova Zelândia, masculino)",
        "en-NZ-MollyNeural": "Molly (Nova Zelândia, feminino)",
        "en-PH-JamesNeural": "James (Filipinas, masculino)",
        "en-PH-RosaNeural": "Rosa (Filipinas, feminino)",
        "en-SG-LunaNeural": "Luna (Singapura, feminino)",
        "en-SG-WayneNeural": "Wayne (Singapura, masculino)",
        "en-TZ-ElimuNeural": "Elimu (Tanzânia, masculino)",
        "en-TZ-ImaniNeural": "Imani (Tanzânia, feminino)",
        "en-ZA-LeahNeural": "Leah (África do Sul, feminino)",
        "en-ZA-LukeNeural": "Luke (África do Sul, masculino)",
        "pt-BR-FranciscaNeural": "Francisca (BR, feminino)",
        "pt-BR-AntonioNeural": "Antonio (BR, masculino)",
        "pt-BR-ThalitaMultilingualNeural": "Thalita (BR, feminino)",
        "pt-PT-DuarteNeural": "Duarte (PT, masculino)",
        "pt-PT-RaquelNeural": "Raquel (PT, feminino)",
    ]

    static func label(for voice: String) -> String {
        if PiperTTS.isOfflineVoice(voice) { return PiperTTS.label(for: voice) }
        return voiceLabels[voice] ?? voice
    }

    /// Voz guardada ainda existe no catálogo (offline + EN + PT)?
    static func isKnown(_ voice: String) -> Bool {
        (PiperTTS.offlineVoices + englishVoices + portugueseVoices).contains(voice)
    }
}

/// Posição de leitura salva por documento+voz, para retomar onde parou.
///
/// Desenho: UM dicionário `[chave: segundos]` sob `defaultsKey`; cada entrada
/// junta o identificador do documento (URL do arquivo) e a voz, então trocar
/// de voz não puxa a posição da outra. O padrão "sem posição" é a AUSÊNCIA da
/// entrada (não zero): reabrir sem nunca ter pausado/parado não busca nada.
///
/// Tudo passa por `defaults` injetável para o round-trip ser testável sem UI
/// (basta uma suite efêmera de `UserDefaults`).
enum ReadingPositionStore {
    /// Chave do dicionário no `UserDefaults`.
    static let defaultsKey = "readingPositions"

    /// Abaixo disto, retomar é o mesmo que começar do zero — nem guarda nem busca.
    static let minimumResume: TimeInterval = 3

    /// Chave estável da entrada: documento + voz. Sem a cadência de propósito:
    /// o áudio pode mudar de duração entre cadências, e a guarda `shouldResume`
    /// já barra qualquer busca além do medido.
    static func key(documentID: String, voice: String) -> String {
        "\(documentID)##\(voice)"
    }

    /// Segundos guardados, ou nil quando nunca pausou/parou ali ("sem posição").
    static func load(
        documentID: String, voice: String,
        defaults: UserDefaults = .standard
    ) -> TimeInterval? {
        let pos = doubles(defaults.dictionary(forKey: defaultsKey) ?? [:])[key(documentID: documentID, voice: voice)]
        guard let pos, pos > 0 else { return nil }
        return pos
    }

    /// Guarda a posição (chamar na pausa/parada, com o relógio ainda vivo).
    static func save(
        documentID: String, voice: String, position: TimeInterval,
        defaults: UserDefaults = .standard
    ) {
        guard position >= minimumResume else { return }
        var all = doubles(defaults.dictionary(forKey: defaultsKey) ?? [:])
        all[key(documentID: documentID, voice: voice)] = position
        defaults.set(all, forKey: defaultsKey)
    }

    /// Esquece a posição (leitura concluída ou transcrição descartada).
    static func clear(
        documentID: String, voice: String,
        defaults: UserDefaults = .standard
    ) {
        var all = doubles(defaults.dictionary(forKey: defaultsKey) ?? [:])
        all.removeValue(forKey: key(documentID: documentID, voice: voice))
        defaults.set(all, forKey: defaultsKey)
    }

    /// Só retoma quando há o que retomar E o áudio medido já cobre o ponto —
    /// nunca busca além do que chegou (senão, começa do zero).
    static func shouldResume(saved: TimeInterval?, knownDuration: TimeInterval) -> Bool {
        guard let saved, saved >= minimumResume else { return false }
        guard knownDuration > 0, saved <= knownDuration else { return false }
        return true
    }

    /// Lê o dicionário do `UserDefaults` tolerando número vindo como Double ou NSNumber.
    private static func doubles(_ dict: [String: Any]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, v) in dict {
            if let d = v as? Double { out[k] = d }
            else if let n = v as? NSNumber { out[k] = n.doubleValue }
        }
        return out
    }
}
