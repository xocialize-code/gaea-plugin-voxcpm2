import GaeaPluginKit
import VoxCPM2Plugin

// The plugin's worker: VoxCPM2Plugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(voxCPM2Plugin)
