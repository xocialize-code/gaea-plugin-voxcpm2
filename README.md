# gaea-plugin-voxcpm2

[VoxCPM2](https://huggingface.co/openbmb/VoxCPM2) (OpenBMB) as a [Gaea](https://github.com/xocialize-code/gaea) plugin on
MES Audio 0.1: 48 kHz speech in 30 languages. The voice can be one of the model's own, a clone of a clip, or one
designed from a description. It runs [mlx-voxcpm2-tts-swift](https://github.com/xocialize/mlx-voxcpm2-tts-swift) through
MLXEngine, on GaeaPluginKit.

Install it in Gaea with `gaea plugins add https://github.com/xocialize-code/gaea-plugin-voxcpm2`.

## The offers

One model, `voxcpm2`, on two operations, so the checkpoint is loaded once.

**`audio.speak`**

| | |
|---|---|
| Voice | **None:** the model's own voice, which changes with the seed. **`voice_ref`** (1 to 20 s; longer is trimmed): a clone of the clip. **`voice_ref` + `voice_ref_text`**: a continuation from the clip, the closest clone |
| Languages | 30, read from the text (the model takes no language): ar, my, zh, da, nl, en, fi, fr, de, el, he, hi, id, it, ja, km, ko, lo, ms, no, pl, pt, ru, es, sw, sv, tl, th, tr, vi |
| Emotion | A label (`neutral`, `happy`, `angry`, `sad`, `afraid`, `disgusted`, `melancholic`, `surprised`, `calm`) or `emotion.description`, which wins. No intensity (`emotion_intensity_ignored`) |
| Not offered | `speed` and `target_duration_s`: the model has no control for them |
| Cues | `[pause Ns]`; Gaea removes any other cue with `cue_unsupported` |

**`audio.design_voice`**: a voice from a description, read back as 1 to 4 samples of one sentence at seed + i. Without
`text`, the sample is a fixed sentence in the request's language: en, zh, ja, ko, es, fr, de, it, pt, ru, nl or id. Keep
the sample you like as an asset, and clone it through `audio.speak` with `voice_ref` and `voice_ref_text`.

**Both:** 16-bit mono WAV at 48 kHz, which Gaea converts to what the request asks for. One lane, `bf16`: the weights
run as fp32 (bf16 glitches on Metal), about 9.3 GB resident and 4 GB more while running, on a Pro chip or better. A
seeded request is reproducible. A reference that is an MES asset is encoded once and kept under the asset; any other is
forgotten when its job ends. Licence: Apache-2.0, the weights and this plugin.

## Building and checking

```
swift test
scripts/build-plugin.sh                 # the worker, manifest.json (validated), the signed bundle and its zip in dist/
scripts/check-plugin.sh                 # drive the bundle over GPP with every .build hidden, plus the metallib control
scripts/golden.sh <out-dir>             # seeded cases over GPP against voxcpm2-inproc, byte for byte
```

The checks read VoxCPM2's weights from `CHECK_MODELS_ROOT` (default `/Volumes/DEV_VOL1/Models/Models`) and never
download. `scripts/fixtures/ref-en.wav` is the reference clip they clone, made with macOS's `say`.

`voxcpm2-inproc speak|design …` runs the same package in-process with the worker's requests and seeding, for comparison.

`Package.swift` names the fleet's mlx-swift fork (`xocialize/mlx-swift`), as mlx-engine-swift 0.74.1 does. A root line
naming ml-explore's URL would win, and could drop the fix for a leak that kills workers that reload quantized models
(Gaea AB-L-0330).

## Releasing

Push a `v<version>` tag matching the manifest's version. CI (`.github/workflows/release.yml`, the `xcode-27` runner)
builds, signs, notarizes and publishes the zip, its sha256 and `manifest.json`. CI secrets: `DEVELOPER_ID_P12_BASE64`,
`DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD`, organization secrets on xocialize-code.
