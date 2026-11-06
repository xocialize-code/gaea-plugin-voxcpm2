import Foundation
import GaeaProtocol
import MLXServeCore
import MLXToolKit
import MLXVoxCPM2TTS
import VoxCPM2Plugin

// The in-process reference for the plugin: VoxCPM2 loaded by MLXServeEngine in this process, with the lane configuration,
// the requests and the seeding the worker uses (VoxCPM2Plugin). The WAV is written to --out (speak) or --out-dir as
// samples-<i>.wav (design), and one JSON line of timings is printed. Not part of the plugin bundle.
//
//   voxcpm2-inproc speak [--text <text> | --text-file <path>] [--ref <wav> [--ref-text <transcript>]] [--language en]
//                        [--emotion <label>] [--emotion-description <text>] [--seed 42] [--models-root <dir>] [--out <wav>]
//   voxcpm2-inproc design --description <text> [--text <sample>] [--language en] [--count 1] [--seed 42]
//                         [--models-root <dir>] [--out-dir <dir>]

var args = Array(CommandLine.arguments.dropFirst())
let mode = args.isEmpty ? "speak" : args.removeFirst()
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let seed = UInt64(option("--seed") ?? "") ?? 42
let modelsRoot = URL(fileURLWithPath: option("--models-root") ?? "/Volumes/DEV_VOL1/Models/Models", isDirectory: true)

// The budget Gaea sends a worker on a large Mac.
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: true))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(modelID)
_ = try await engine.register(VoxCPM2TTSPackage.registration, configuration: lanes[0].configuration, id: id)
var clock = ContinuousClock.now
_ = try await engine.prepare(.tts, package: id)
var result: [String: Any] = ["model": modelID, "seed": seed, "prepare_s": seconds(since: clock)]
let run: (TTSRequest) async throws -> any CapabilityResponse = { try await engine.run($0, package: id) }

clock = ContinuousClock.now
if mode == "design" {
    let plan = try designPlan(description: option("--description"), text: option("--text"), language: option("--language"),
                              count: Int(option("--count") ?? ""), seed: seed)
    let dir = URL(fileURLWithPath: option("--out-dir") ?? ".", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for i in 0..<plan.count {
        let wav = try await draw(request(plan, sample: i), seed: plan.seed + UInt64(i), run: run)
        try wav16(try pcm16(wav)).write(to: dir.appending(path: "samples-\(i).wav"))
    }
    result["text"] = plan.text
    result["count"] = plan.count
} else {
    let text = try option("--text-file").map { try String(contentsOfFile: $0, encoding: .utf8) }
        ?? option("--text") ?? "Gaea speaks. This sentence came from a signed plugin, over its own protocol."
    var fields: [String: JSONValue] = [:]
    if let label = option("--emotion") { fields["label"] = .string(label) }
    if let description = option("--emotion-description") { fields["description"] = .string(description) }
    // A job of its own, keyed by the job as the worker keys a reference that isn't an asset.
    let plan = try speakPlan(text: text, reference: try option("--ref").map { try Data(contentsOf: URL(fileURLWithPath: $0)) },
                             transcript: option("--ref-text"), language: option("--language"),
                             emotion: fields.isEmpty ? nil : .object(fields), asset: nil, job: "inproc", seed: seed)
    let pcm = try await speak(plan.pieces) { words in try await draw(request(plan, words: words), seed: plan.seed, run: run) }
    if plan.reference != nil { _ = try? await run(eviction([plan.cacheKey])) }
    if let out = option("--out") { try wav16(pcm).write(to: URL(fileURLWithPath: out)) }
    result["voice"] = plan.mode.rawValue
    result["audio_s"] = Double(pcm.count / 2) / Double(sampleRate)
}
result["run_s"] = seconds(since: clock)
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
