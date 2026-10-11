# Third-party notices

kooky bundles or links the following third-party projects. Each retains its
upstream license; nothing here is dual-licensed under kooky's MIT.

## Bundled in the source tree

### Onest (font)
- Source: <https://github.com/google/fonts/tree/main/ofl/onest>
- Designer: Martín Sznaider, Indian Type Foundry
- License: SIL Open Font License 1.1
- File: `Sources/KookyKit/Resources/Fonts/Onest.ttf`

### JetBrains Mono (font)
- Source: <https://github.com/JetBrains/JetBrainsMono>
- License: SIL Open Font License 1.1
- File: `Sources/KookyKit/Resources/Fonts/JetBrainsMono-Regular.ttf`

### Shiki terminal theme palettes
- Source: <https://github.com/shikijs/shiki/tree/main/packages/themes>
- Package: `@shikijs/themes` 3.23.0
- License: MIT
- Use: background, foreground, cursor, selection, and 16-color ANSI tables in
  `Sources/KookyKit/Resources/themes/` Ghostty theme files

Copyright (c) 2021 Pine Wu
Copyright (c) 2023 Anthony Fu <https://github.com/antfu>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### lobe-icons (brand PNGs)
- Source: <https://github.com/lobehub/lobe-icons>
- License: MIT
- Files: `Sources/KookyKit/Resources/Icons/{claudecode,codex,gemini,opencode,amp,cursor,githubcopilot,grok,antigravity,kimi,kiro}.png`

### Pi logo (brand PNG)
- Source: <https://pi.dev> (press kit)
- Owner: Earendil Inc.
- License: MIT
- File: `Sources/KookyKit/Resources/Icons/pi.png`

### Droid logo (brand PNG)
- Source: <https://factory.ai> (site favicon)
- Owner: Factory AI, Inc.
- File: `Sources/KookyKit/Resources/Icons/droid.png`

### Oh My Pi logo (brand PNG)
- Source: <https://omp.sh> (site favicon)
- Owner: <https://github.com/can1357/oh-my-pi> — MIT
- File: `Sources/KookyKit/Resources/Icons/omp.png`

### Reasonix logo (brand PNG)
- Source: <https://reasonix.io> (site favicon)
- Owner: <https://github.com/esengine/DeepSeek-Reasonix> — MIT
- File: `Sources/KookyKit/Resources/Icons/reasonix.png`

## Pulled at build time

### TDLib and TDLibFramework
- Telegram API client, used locally by AgentPad (an independent, unofficial client).
- TDLib: <https://github.com/tdlib/td/tree/42e6a5259551178d1dab54a22ad96d14bd906e20>, version 1.8.67; Boost Software License 1.0 (`licenses/TDLib-BSL-1.0.txt`).
- Copyright Aliaksei Levin and Arseny Smirnov, 2014–2026.
- Swiftgram package: <https://github.com/Swiftgram/TDLibFramework/tree/9ebb0e55a3607f10f24b3fc3e663bd38e7743ad2>; MIT (`licenses/TDLibFramework-MIT.txt`).
- Static artifact: `1.8.67-42e6a525/TDLibFramework.zip`, SHA-256 `98789e70d89654414a1415cf778a5071c93cf96501c98fc25d7ef8d12d18fdf5`.
- Vendor build recipe: the pinned package's `.github/workflows/build.yml`, `builder/` patches and the TDLib Apple example. It builds OpenSSL separately, then combines the static libraries in the framework. The supplied binary identifies OpenSSL 3.1.5; Apache 2.0 (`licenses/OpenSSL-3.1.5-Apache-2.0.txt`). Copyright The OpenSSL Project Authors.
- System zlib and libc++ are linked dynamically; zlib notice in `licenses/zlib.txt`. No TDLibKit Swift DTOs are included.
- The vendor publishes build recipes, not a complete object-level provenance attestation. Pin/checksum verification does not establish the provenance of every object.
- License files accompany the installed app in `Contents/Resources/licenses`.

### libghostty
- Source: <https://github.com/ghostty-org/ghostty>
- License: MIT
- Distribution: prebuilt `GhosttyKit.xcframework` fetched by `scripts/setup-libghostty.sh` into `Vendor/` (gitignored)
