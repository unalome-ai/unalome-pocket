# Unalome Pocket

Open LLMs that run entirely on your iPhone, iPad and Mac. No account, no cloud, no telemetry.

> Working name. Early development: chat with downloaded MLX models or Apple's built-in model.
> In the Simulator, chats use a scripted demo engine (MLX needs a real GPU).

## Requirements

- Xcode 27 or later, iOS 26 / macOS 26 SDKs
- Xcode's Metal Toolchain, which MLX needs to compile its GPU kernels:
  `xcodebuild -downloadComponent MetalToolchain`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build

Signing reads your team from a local, git-ignored file:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set DEVELOPMENT_TEAM
xcodegen generate                                        # creates UnalomePocket.xcodeproj
open UnalomePocket.xcodeproj
```

Run the package tests:

```sh
cd Packages/PocketKit && swift test
```

The MLX integration test downloads the smallest catalog model (about 650 MB) and is opt-in:

```sh
POCKETKIT_MLX_INTEGRATION=1 swift test --filter MLXIntegrationTests
```

## Layout

- `project.yml` – XcodeGen spec for the multiplatform app target
- `Config/` – build settings; `Local.xcconfig` (not committed) holds your signing team
- `catalog/catalog.json` – the curated model catalog (also bundled in the app)
- `App/` – app entry, engine selection, Info.plist, entitlements, privacy manifest, assets
- `Packages/PocketKit/` – the local Swift package
  - `UnalomeDesign` – colour, gradient, radius and type tokens; Inter font; glass components
  - `ChatCore` – `ChatEngine` protocol, `EngineHost`, `ScriptedEngine`, SwiftData models, conversation store
  - `ModelCatalog` – catalog, device profile, recommender, Hugging Face metadata, downloader, storage
  - `MLXEngine` – downloaded models through mlx-swift-lm
  - `AppleEngine` – Apple's on-device model through FoundationModels
  - `Features` – onboarding, models, conversations and chat screens

## Licence

Apache License 2.0, see [LICENSE](LICENSE).
The bundled Inter typeface is licensed under the SIL Open Font License 1.1, see
`Packages/PocketKit/Sources/UnalomeDesign/Resources/Fonts/Inter-LICENSE.txt`.
Each model has its own licence, shown before it downloads.

Third-party code (to list in an in-app licences screen, which does not exist yet):
mlx-swift and mlx-swift-lm (MIT), swift-transformers (Apache 2.0),
swift-markdown (Apache 2.0) and its cmark-gfm fork swift-cmark (BSD 2-Clause).
