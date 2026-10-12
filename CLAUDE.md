# Murmur

macOS menu bar ambient-sound mixer (SwiftUI + AVAudioEngine). Full context, architecture, gotchas and TODO: **read `HANDOFF.md` first.**

Key rules:
- Xcode 27 is installed and selected (`xcode-select -p` → `/Applications/Xcode.app`), so the `@State` macro works. Older views still use the `State<T>(initialValue:)` + computed-property workaround from the CLT-only days; either style is fine.
- Build with `./build.sh`; verify with `build/Murmur.app/Contents/MacOS/Murmur --selftest` / `--playtest` / `--snapshot <prefix>`.
- After replacing the binary inside `build/Murmur.app`, re-sign: `codesign --force --deep -s - build/Murmur.app`.
- Never bundle third-party sounds or artwork from other apps; audio comes only from Moodist (Pixabay License / CC0) or is synthesized in code.
- UI strings are Russian.
- Sounds are never plain loops: recordings play as granular textures (`Texture.swift`, `Sound.layers`); only the clock uses an exact loop.
- `--snapshot` can't render Liquid Glass; `SelfTest.isRendering` swaps glass for a material so layout can still be checked.
