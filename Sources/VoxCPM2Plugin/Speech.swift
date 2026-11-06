import Foundation
import GaeaPluginKit
import GaeaProtocol

// The text plan (`[pause Ns]`), languages, the reference clip, and the package's 16-bit WAVs. Adapted from
// gaea-plugin-indextts's Speech.swift; VoxCPM2 speaks at 48 kHz.

public let sampleRate = 48000
public let defaultPauseSeconds = 0.5
public let maxPauseSeconds = 10.0
public let maxVoiceRefSeconds = 20.0

/// The 30 languages VoxCPM2 speaks (its model card), as MES base subtags (BCP 47). The model takes no language: it reads
/// the text, so `language` is only a gate here, and reported when the request names it.
public let languageTags = ["ar", "my", "zh", "da", "nl", "en", "fi", "fr", "de", "el", "he", "hi", "id", "it", "ja", "km",
                           "ko", "lo", "ms", "no", "pl", "pt", "ru", "es", "sw", "sv", "tl", "th", "tr", "vi"]

/// The languages `design_voice` offers, each with the sentence a sample reads when the request gives none (Audio §3.1).
public let designLanguages: [(tag: String, sample: String)] = [
    ("en", "Hello! This is how I sound when I read a sentence aloud."),
    ("zh", "你好！这是我朗读一句话时的声音。"),
    ("ja", "こんにちは。これが、文を読み上げるときの私の声です。"),
    ("ko", "안녕하세요! 제가 문장을 소리 내어 읽을 때 이런 목소리예요."),
    ("es", "¡Hola! Así suena mi voz cuando leo una frase en voz alta."),
    ("fr", "Bonjour ! Voici ma voix quand je lis une phrase à voix haute."),
    ("de", "Hallo! So klinge ich, wenn ich einen Satz vorlese."),
    ("it", "Ciao! Questa è la mia voce quando leggo una frase ad alta voce."),
    ("pt", "Olá! É assim que soa a minha voz quando leio uma frase em voz alta."),
    ("ru", "Привет! Так звучит мой голос, когда я читаю фразу вслух."),
    ("nl", "Hallo! Zo klink ik wanneer ik een zin hardop voorlees."),
    ("id", "Halo! Beginilah suara saya saat membaca sebuah kalimat dengan keras."),
]

/// A request's language as a base subtag (`pt-BR` → `pt`), refusing one outside `tags`. MES gates `language` by the
/// offer's `supports.languages` first, so this is a second check.
public func language(_ tag: String?, among tags: [String] = languageTags) throws -> String? {
    guard let tag else { return nil }
    let base = String(tag.split(separator: "-").first ?? "").lowercased()
    guard tags.contains(base) else {
        throw GPPError(.invalidRequest, "VoxCPM2 doesn't speak \(tag) here.", detail: ["param": "language"])
    }
    return base
}

// MARK: - The text plan

/// One piece of the plan: words for one generation, or silence.
public enum Piece: Sendable, Equatable {
    case words(String)
    case pause(Double)
}

/// The text as pieces (Audio §2.2's cue syntax: `[pause Ns]`, `[pause]`, and `\[` for a literal bracket). MESKit has
/// already removed every other cue (`cue_unsupported`). The model reads long text in one pass, so words are cut only at
/// pauses.
public func plan(_ text: String) throws -> [Piece] {
    var pieces: [Piece] = []
    var buffer = ""
    func flush() {
        let words = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { pieces.append(.words(words)) }
        buffer = ""
    }
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "[" {
            buffer.append("[")
            i = text.index(i, offsetBy: 2)
            continue
        }
        if c == "[", let close = text[i...].firstIndex(of: "]"),
           let m = text[text.index(after: i)..<close].wholeMatch(of: /pause(?: ([0-9]+(?:\.[0-9]+)?)s)?/) {
            let seconds = m.1.flatMap { Double($0) } ?? defaultPauseSeconds
            guard seconds <= maxPauseSeconds else {
                throw GPPError(.invalidRequest, "A pause is at most \(Int(maxPauseSeconds)) s.", detail: ["param": "text"])
            }
            flush()
            if seconds > 0 { pieces.append(.pause(seconds)) }
            i = text.index(after: close)
            continue
        }
        buffer.append(c)
        i = text.index(after: i)
    }
    flush()
    guard pieces.contains(where: { if case .words = $0 { true } else { false } }) else {
        throw GPPError(.invalidRequest, "There are no words to speak, only pauses.", detail: ["param": "text"])
    }
    return pieces
}

/// Draws the plan piece by piece with `draw`, and returns the 16-bit samples, pauses included.
public func speak(_ pieces: [Piece], draw: (String) async throws -> Data) async throws -> Data {
    var all = Data()
    for piece in pieces {
        try Task.checkCancellation()
        switch piece {
        case .words(let words): all.append(try pcm16(try await draw(words)))
        case .pause(let seconds): all.append(silence(seconds))
        }
    }
    return all
}

// MARK: - The reference clip

/// A reference clip as the package takes it: mono 16-bit PCM WAV, at most `maxVoiceRefSeconds`, with the warnings for
/// what was changed. Gaea sends every audio input as a canonical 16-bit WAV (a 44-byte header), at its own rate and
/// channels.
public func reference(_ wav: Data) throws -> (wav: Data, seconds: Double, warnings: [Warning]) {
    guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8), wav[wav.startIndex + 8..<wav.startIndex + 12] == Data("WAVE".utf8),
          wav[wav.startIndex + 36..<wav.startIndex + 40] == Data("data".utf8) else {
        throw GPPError(.invalidRequest, "voice_ref isn't a 16-bit PCM WAV.", detail: ["param": "voice_ref"])
    }
    func u16(_ at: Int) -> Int { Int(wav[wav.startIndex + at]) | Int(wav[wav.startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    let channels = u16(22), rate = u32(24), bits = u16(34)
    guard u16(20) == 1, bits == 16, (1...2).contains(channels), rate > 0 else {
        throw GPPError(.invalidRequest, "voice_ref isn't a mono or stereo 16-bit PCM WAV.", detail: ["param": "voice_ref"])
    }
    var pcm = wav.subdata(in: (wav.startIndex + 44)..<wav.endIndex)
    var warnings: [Warning] = []
    var samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    if channels == 2 {
        samples = stride(from: 0, to: samples.count - 1, by: 2).map { Int16((Int(samples[$0]) + Int(samples[$0 + 1])) / 2) }
        warnings.append(Warning(code: "audio_downmixed", message: "The reference was mixed down to mono.", param: "voice_ref"))
    }
    let most = Int(maxVoiceRefSeconds) * rate
    if samples.count > most {
        samples = Array(samples[..<most])
        warnings.append(Warning(code: "voice_ref_trimmed", message: "The reference was trimmed to its first \(Int(maxVoiceRefSeconds)) s.",
                                param: "voice_ref"))
    }
    guard samples.count >= rate else {
        throw GPPError(.invalidRequest, "voice_ref is shorter than a second.", detail: ["param": "voice_ref"])
    }
    if channels == 1, warnings.isEmpty { return (wav, Double(samples.count) / Double(rate), []) }
    pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    return (wav16(pcm, rate: rate), Double(samples.count) / Double(rate), warnings)
}

// MARK: - WAV

/// The 16-bit PCM inside one of the package's WAVs (its `encodeWAV16`: a 44-byte header, mono, 48 kHz).
public func pcm16(_ wav: Data) throws -> Data {
    guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8), wav[wav.startIndex + 8..<wav.startIndex + 12] == Data("WAVE".utf8),
          wav[wav.startIndex + 36..<wav.startIndex + 40] == Data("data".utf8) else {
        throw GPPError(.modelError, "VoxCPM2 returned audio that isn't its usual 16-bit WAV.")
    }
    return wav.subdata(in: (wav.startIndex + 44)..<wav.endIndex)
}

/// Silence: `seconds` of 16-bit zeros at the output rate.
public func silence(_ seconds: Double) -> Data { Data(count: Int((seconds * Double(sampleRate)).rounded()) * 2) }

/// A mono 16-bit WAV of `pcm` at `rate` (the output rate by default).
public func wav16(_ pcm: Data, rate: Int = sampleRate) -> Data {
    var out = Data(capacity: 44 + pcm.count)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
    out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    out.append(pcm)
    return out
}

/// MES seeds are 0 to 2³² − 1 (Audio §1.8); a job without one gets one.
public func seed(_ job: Job) -> UInt64 { job.seed.map { $0 & 0xFFFF_FFFF } ?? UInt64.random(in: 0..<(1 << 32)) }
