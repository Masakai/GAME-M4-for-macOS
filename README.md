# GAME-M4

[日本語](README.ja.md)

An interpreter and a compiler for the GAME language (Hiroshi Onishi, ASCII magazine, 1978) that run natively on Apple Silicon Macs. The syntax is the same as GAME65G in Glow65.

- Interpreter: written in Swift, ported routine by routine from GAME65G
- Compiler: written in Swift. It translates a GAME program to ARM64 assembly and links it with a small C runtime into a Mach-O executable using Xcode's `as` and `clang`
- App: a SwiftUI app with an editor and a terminal
- CLI: `gamem4`

The language reference is in Japanese: [GAME-M4.ja.md](GAME-M4.ja.md).

## Requirements

- macOS 14 or later on Apple Silicon
- Xcode (Swift 5.9 or later)

## Build and test

```bash
swift build --scratch-path ~/Library/Caches/GAME-M4/build
```

```bash
swift test --scratch-path ~/Library/Caches/GAME-M4/build
```

```bash
Tools/build_app.sh
```

## Usage

```bash
gamem4 prog.gam
```

```bash
gamem4 compile prog.gam -o prog
```

## License

MIT License. See [NOTICE.md](NOTICE.md).
