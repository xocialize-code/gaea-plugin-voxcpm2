import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLX
import MLXToolKit
import MLXVoxCPM2TTS

// gaea-plugin-voxcpm2: OpenBMB's VoxCPM2 (Apache-2.0) on MES Audio 0.1 (Gaea G5 order 2, AB-T-0453). One model, `voxcpm2`,
// on two operations, so the 2B checkpoint is loaded once:
//
// - audio.speak in three ways (Audio §3.2): the model's own voice with no reference (a default voice that varies with
//   the seed); a clone of `voice_ref`; and, with `voice_ref_text`, a continuation clone (the package's "Ultimate
//   Cloning", the closest). Thirty languages, read from the text: the model takes no language, so `language` is a gate.
// - audio.design_voice (Audio §3.1): a voice from a description, read back as `count` samples of one sentence at
//   seed + i. The sample is the voice: a client clones it with voice_ref.
//
// Emotion and delivery ride the model's one inline control, `(description)text`: an MES label (the eight the package's
// shared vocabulary names, `neutral` sending none) or `emotion.description`, which wins as it says more. There is no
// intensity, speed or duration control.
//
// One lane: the bf16 weights, which the package runs as fp32 (bf16 glitches on Metal), about 9.3 GB resident and 4 GB
// more while it runs. The worker passes the seed to the package, which seeds MLX after any reference encode, and seeds
// MLX itself too: the same request gives the same WAV, here and in voxcpm2-inproc.
//
// The reference's encoded prompt is what the package can cache, under a key the worker gives it (mlx-voxcpm2-tts-swift
// 0.6.0, AB-A-0251): MES Base §13 rule 6, an asset's reference is keyed by its asset id, kept while the asset lives, and
// evicted when Gaea says it's gone (`onAssetRemoved`); any other reference is keyed by the job and evicted when the job
// ends (rules 1–4).

public let modelID = "voxcpm2"
public let maxTextChars = 1500, maxDescriptionChars = 500, maxSamples = 4

/// The MES emotion labels the package's shared vocabulary takes (Audio §2.1); `neutral` sends none.
public let emotions = ["neutral", "happy", "angry", "sad", "afraid", "disgusted", "melancholic", "surprised", "calm"]

public let lanes = [LaneDefinition(id: "bf16", default: true, configuration: VoxCPM2Configuration())]

// MARK: - speak

/// How the voice is chosen (Audio §3.2).
public enum VoiceMode: String, Sendable { case `default`, clone, continuation }

/// What a speak job asks of the package, validated.
public struct SpeakPlan: Sendable {
    public var pieces: [Piece]
    public var mode: VoiceMode
    public var reference: Data?
    public var transcript: String?
    public var emotion: TTSEmotion?
    public var seed: UInt64
    /// The package's cache key: the asset id, else one for this job alone.
    public var cacheKey: String
    /// Whether the key is the job's own, to evict when it ends.
    public var jobScoped: Bool
    public var warnings: [Warning]
    public var effective: [String: JSONValue]
}

/// The typed emotion an MES `emotion` asks for: the description when there is one, else the label (`neutral`: none).
public func emotion(_ value: JSONValue?) throws -> TTSEmotion? {
    guard let value else { return nil }
    if let description = value["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
        return .textDescription(description)
    }
    guard let label = value["label"]?.stringValue else { return nil }
    guard emotions.contains(label) else {
        throw GPPError(.invalidRequest, "VoxCPM2 can't act \(label).", detail: ["param": "emotion", "mes_code": "unsupported_parameter"])
    }
    return label == "neutral" ? nil : .categorical(label)
}

public func speakPlan(text: String?, reference wav: Data?, transcript: String?, language tag: String?, emotion value: JSONValue?,
                      asset: String?, job: String, seed: UInt64) throws -> SpeakPlan {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GPPError(.invalidRequest, "audio.speak needs text.", detail: ["param": "text"])
    }
    guard text.count <= maxTextChars else {
        throw GPPError(.invalidRequest, "VoxCPM2 speaks at most \(maxTextChars) characters at a time.",
                       detail: ["param": "text", "mes_code": "out_of_limits"])
    }
    let pieces = try plan(text)
    var warnings: [Warning] = []
    var effective: [String: JSONValue] = ["seed": .int(Int64(seed))]
    if let lang = try language(tag) { effective["language"] = .string(lang) }
    let typed = try emotion(value)
    if let value {
        effective["emotion"] = value
        if value["intensity"] != nil {
            warnings.append(Warning(code: "emotion_intensity_ignored", message: "VoxCPM2 takes no emotion intensity.", param: "emotion"))
        }
    }
    var mode = VoiceMode.default
    var clip: Data?
    var script: String?
    if let wav {
        let (checked, seconds, refWarnings) = try reference(wav)
        clip = checked
        warnings += refWarnings
        effective["x-voxcpm2.voice_ref_s"] = .double((seconds * 100).rounded() / 100)
        let said = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        script = said?.isEmpty == false ? said : nil
        mode = script == nil ? .clone : .continuation
    }
    effective["x-voxcpm2.voice"] = .string(mode.rawValue)
    return SpeakPlan(pieces: pieces, mode: mode, reference: clip, transcript: script, emotion: typed, seed: seed,
                     cacheKey: asset ?? "job:\(job)", jobScoped: asset == nil, warnings: warnings, effective: effective)
}

/// The engine request for one piece of a speak plan.
public func request(_ plan: SpeakPlan, words: String) -> TTSRequest {
    var meta: MetaData = ["seed": .int(Int(plan.seed))]
    var voice = VoiceSelector(.auto)
    if let reference = plan.reference {
        voice = VoiceSelector(.referenceAudio(Audio(format: .wav, data: reference, sampleRate: nil, channels: 1)))
        meta["voiceCacheKey"] = .string(plan.cacheKey)
    }
    return TTSRequest(text: words, voice: voice, referenceTranscript: plan.transcript, emotion: plan.emotion, metaData: meta)
}

/// The package's eviction call for cache keys (AB-A-0251): empty text, no synthesis.
public func eviction(_ keys: [String]) -> TTSRequest {
    TTSRequest(text: "", metaData: ["evictVoiceCacheKeys": .array(keys.map { .string($0) })])
}

/// Seeds MLX's random state, then draws `request` through `run` and returns the WAV.
public func draw(_ request: TTSRequest, seed: UInt64, run: (TTSRequest) async throws -> any CapabilityResponse) async throws -> Data {
    MLXRandom.seed(seed)
    guard let response = try await run(request) as? TTSResponse else {
        throw GPPError(.modelError, "VoxCPM2 returned no audio.")
    }
    return response.audio.data
}

let speakOperation = EngineOperation("audio.speak") { job, session in
    let plan = try speakPlan(text: try job.text("text"), reference: try job.input("voice_ref").map { try Data(contentsOf: $0) },
                             transcript: try job.text("voice_ref_text"), language: job.param("language")?.stringValue,
                             emotion: job.param("emotion"), asset: job.asset("voice_ref"), job: job.job, seed: seed(job))
    let send: (TTSRequest) async throws -> any CapabilityResponse = { try await session.run($0 as! any WireRequest) }
    let keyed = plan.reference != nil && plan.jobScoped
    let pcm: Data
    do {
        pcm = try await speak(plan.pieces) { words in try await draw(request(plan, words: words), seed: plan.seed, run: send) }
    } catch {
        if keyed { _ = try? await send(eviction([plan.cacheKey])) }
        throw error
    }
    // A reference that isn't an asset lives no longer than its job (MES Base §13 rules 1–4).
    if keyed { _ = try? await send(eviction([plan.cacheKey])) }
    let url = session.outputDir.appending(path: "audio-0.wav")
    try wav16(pcm).write(to: url)
    return RunResult(outputs: [.file("audio", url, mediaType: "audio/wav")], effective: plan.effective, warnings: plan.warnings)
}

// MARK: - design_voice

/// What a design job asks: the description, the sample sentence, the language and how many samples.
public struct DesignPlan: Sendable {
    public var description: String
    public var text: String
    public var language: String
    public var count: Int
    public var seed: UInt64
}

public func designPlan(description: String?, text: String?, language tag: String?, count: Int?, seed: UInt64) throws -> DesignPlan {
    guard let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty else {
        throw GPPError(.invalidRequest, "audio.design_voice needs a description.", detail: ["param": "description"])
    }
    guard description.count <= maxDescriptionChars else {
        throw GPPError(.invalidRequest, "A description is at most \(maxDescriptionChars) characters.",
                       detail: ["param": "description", "mes_code": "out_of_limits"])
    }
    let lang = try language(tag, among: designLanguages.map(\.tag)) ?? "en"
    let count = count ?? 1
    guard (1...maxSamples).contains(count) else {
        throw GPPError(.invalidRequest, "VoxCPM2 designs 1–\(maxSamples) samples at a time.",
                       detail: ["param": "count", "mes_code": "out_of_limits"])
    }
    let sentence = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sample = sentence?.isEmpty == false ? sentence! : designLanguages.first { $0.tag == lang }!.sample
    guard sample.count <= maxTextChars else {
        throw GPPError(.invalidRequest, "The sample text is at most \(maxTextChars) characters.",
                       detail: ["param": "text", "mes_code": "out_of_limits"])
    }
    return DesignPlan(description: description, text: sample, language: lang, count: count, seed: seed)
}

/// The engine request for sample `i` of a design: the sample sentence in the described voice, at seed + i.
public func request(_ plan: DesignPlan, sample i: Int) -> TTSRequest {
    TTSRequest(text: plan.text, voice: VoiceSelector(.auto), emotion: .textDescription(plan.description),
               metaData: ["seed": .int(Int(plan.seed) + i)])
}

let designOperation = EngineOperation("audio.design_voice") { job, session in
    let plan = try designPlan(description: try job.text("description"), text: try job.text("text"),
                              language: job.param("language")?.stringValue, count: job.param("count")?.intValue, seed: seed(job))
    var warnings: [Warning] = []
    if job.param("prompt_enhance")?.stringValue == "on" {
        warnings.append(Warning(code: "prompt_enhance_ignored", message: "VoxCPM2 reads the description as written.",
                                param: "prompt_enhance"))
    }
    var outputs: [Output] = []
    for i in 0..<plan.count {
        let wav = try await draw(request(plan, sample: i), seed: plan.seed + UInt64(i)) { try await session.run($0 as! any WireRequest) }
        let url = session.outputDir.appending(path: "samples-\(i).wav")
        try wav16(try pcm16(wav)).write(to: url)
        outputs.append(.file("samples", url, mediaType: "audio/wav"))
    }
    let effective: [String: JSONValue] = ["seed": .int(Int64(plan.seed)), "text": .string(plan.text),
                                          "language": .string(plan.language), "count": .int(Int64(plan.count))]
    return RunResult(outputs: outputs, effective: effective, warnings: warnings)
}

// MARK: - The plugin

let license: JSONValue = ["spdx": "Apache-2.0", "commercial_use": true, "terms_url": "https://huggingface.co/openbmb/VoxCPM2"]

let model = ModelDefinition.engine(VoxCPM2TTSPackage.self, id: modelID, title: "VoxCPM2", lanes: lanes,
                                   operations: [speakOperation, designOperation])

let speakOffer = PluginManifest.Offer(
    operation: "audio.speak", profile: "audio",
    model: [
        "id": .string(modelID), "title": "VoxCPM2",
        "license": license, "memory_class": "large", "speed_class": "standard", "quality_tiers": ["standard"],
        "notes": "48 kHz speech in 30 languages, read from the text. Without a reference it speaks in a voice of its own that changes with the seed; with voice_ref (1 to 20 s) it clones the clip, and with the clip's transcript (voice_ref_text) it continues from it, the closest clone. Give an emotion label, or describe the delivery in words (\"whispering, as if telling a secret\"); [pause 1s] adds silence.",
        "supports": [
            "default_voice": true, "voice_ref": true, "voice_ref_text": "optional",
            "languages": .array(languageTags.map { .string($0) }),
            "emotions": .array(emotions.map { .string($0) }), "emotion_description": true,
            "cues": ["pause"], "sample_rate": .int(Int64(sampleRate)), "channels": 1,
        ],
        "limits": ["max_text_chars": .int(Int64(maxTextChars)), "max_voice_ref_s": .double(maxVoiceRefSeconds)],
    ])

let designOffer = PluginManifest.Offer(
    operation: "audio.design_voice", profile: "audio",
    model: [
        "id": .string(modelID), "title": "VoxCPM2",
        "license": license, "memory_class": "large", "speed_class": "standard", "quality_tiers": ["standard"],
        "notes": "Describe a voice in a sentence or two (age, pitch, pace, accent, character), and hear it read a sample at 48 kHz. Keep the sample you like as an asset and clone it with voice_ref.",
        "supports": ["languages": .array(designLanguages.map { .string($0.tag) }), "sample_rate": .int(Int64(sampleRate)), "channels": 1],
        "limits": ["max_text_chars": .int(Int64(maxDescriptionChars)), "max_count": .int(Int64(maxSamples))],
    ])

/// Gaea says an asset is gone: the model forgets the reference it cached under it, if it's loaded.
let forgetAsset: @Sendable (String, ResidentEngine) async -> Void = { asset, resident in
    _ = try? await resident.run(eviction([asset]), model: modelID)
}

public let voxCPM2Plugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.voxcpm2", version: "0.1.0", minGaea: "1.0.0", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-voxcpm2", title: "VoxCPM2",
    summary: "VoxCPM2 (OpenBMB): 48 kHz speech in 30 languages in a voice of its own, cloned from a clip, or designed from a description (MES audio.speak and audio.design_voice).",
    license: "Apache-2.0", executable: "gaea-voxcpm2-worker",
    models: [model], offers: [speakOffer, designOffer], onAssetRemoved: forgetAsset)
