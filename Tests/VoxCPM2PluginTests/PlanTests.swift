import Foundation
import GaeaProtocol
import MLXToolKit
import Testing
@testable import VoxCPM2Plugin

/// A 16-bit WAV of `seconds` of silence at `rate`, `channels` wide.
func clip(_ seconds: Double, rate: Int = 16000, channels: Int = 1) -> Data {
    var out = Data()
    let pcm = Data(count: Int(seconds * Double(rate)) * 2 * channels)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
    out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate))
    u32(UInt32(rate * 2 * channels)); u16(UInt16(2 * channels)); u16(16)
    out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    out.append(pcm)
    return out
}

func plan(_ text: String = "Hello there.", ref: Data? = nil, transcript: String? = nil, language: String? = nil,
          emotion: JSONValue? = nil, asset: String? = nil) throws -> SpeakPlan {
    try speakPlan(text: text, reference: ref, transcript: transcript, language: language, emotion: emotion, asset: asset,
                  job: "j1", seed: 7)
}

@Suite("Requests")
struct PlanTests {
    @Test func pausesSplitTheText() throws {
        #expect(try VoxCPM2Plugin.plan("Hello there. [pause 1.5s] Second [pause] end \\[aside]")
            == [.words("Hello there."), .pause(1.5), .words("Second"), .pause(0.5), .words("end [aside]")])
        #expect(throws: GPPError.self) { try VoxCPM2Plugin.plan("[pause 1s]") }
    }

    @Test func theVoiceIsTheDefaultACloneOrAContinuation() throws {
        let zero = try plan()
        #expect(zero.mode == .default && request(zero, words: "Hi").voice.selection == .auto)
        #expect(request(zero, words: "Hi").metaData["voiceCacheKey"] == nil)
        let clone = try plan(ref: clip(3))
        #expect(clone.mode == .clone && clone.transcript == nil && clone.cacheKey == "job:j1" && clone.jobScoped)
        let cont = try plan(ref: clip(3), transcript: " The words in the clip. ", asset: "ast_1")
        #expect(cont.mode == .continuation && cont.transcript == "The words in the clip." && !cont.jobScoped)
        let r = request(cont, words: "Hi")
        #expect(r.referenceTranscript == "The words in the clip." && r.metaData["voiceCacheKey"] == .string("ast_1"))
        #expect(r.metaData["seed"] == .int(7))
        #expect(cont.effective["x-voxcpm2.voice"] == .string("continuation"))
        #expect(throws: GPPError.self) { try plan(ref: clip(0.5)) }
    }

    @Test func emotionsAndLanguages() throws {
        #expect(try plan(emotion: ["label": "happy"]).emotion == .categorical("happy"))
        #expect(try plan(emotion: ["label": "neutral"]).emotion == nil)
        #expect(try plan(emotion: ["label": "sad", "description": "whispering a secret"]).emotion == .textDescription("whispering a secret"))
        #expect(throws: GPPError.self) { try plan(emotion: ["label": "excited"]) }
        #expect(try plan(emotion: ["label": "sad", "intensity": 0.5]).warnings.map(\.code) == ["emotion_intensity_ignored"])
        #expect(try plan(language: "pt-BR").effective["language"] == .string("pt"))
        #expect(try plan().effective["language"] == nil)
        #expect(throws: GPPError.self) { try plan(language: "uk") }
        #expect(languageTags.count == 30 && Set(languageTags).count == 30)
    }

    @Test func designSamplesUseSeedPlusI() throws {
        let d = try designPlan(description: "a deep calm voice", text: nil, language: "fr", count: 3, seed: 10)
        #expect(d.text.hasPrefix("Bonjour") && d.count == 3)
        let r = request(d, sample: 2)
        #expect(r.metaData["seed"] == .int(12) && r.emotion == .textDescription("a deep calm voice") && r.voice.selection == .auto)
        #expect(throws: GPPError.self) { try designPlan(description: " ", text: nil, language: nil, count: 1, seed: 1) }
        #expect(throws: GPPError.self) { try designPlan(description: "x", text: nil, language: nil, count: 5, seed: 1) }
        #expect(throws: GPPError.self) { try designPlan(description: "x", text: nil, language: "th", count: 1, seed: 1) }
        #expect(eviction(["a"]).text.isEmpty && lanes.map(\.id) == ["bf16"])
    }
}
