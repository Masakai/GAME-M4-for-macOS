# GAME-M4

[English](README.md)

GAME 言語(大西博氏、月刊アスキー 1978 年)のインタプリタとコンパイラです。Apple Silicon の macOS で、エミュレータを使わずに動きます。構文は Glow65 の GAME65G と同じです。

- インタプリタ: Swift で書いた。GAME65G の動きをルーチンごとに移している
- コンパイラ: Swift で書いた。GAME のプログラムを ARM64 のアセンブリに変換し、Xcode の `as` と `clang` で Mach-O の実行ファイルにする
- アプリ: エディタと端末を並べた SwiftUI のアプリ。インタプリタでの実行と、コンパイルしての実行ができる
- CLI: `gamem4`

言語の説明は [GAME-M4.ja.md](GAME-M4.ja.md) にあります。

## 必要なもの

- macOS 14 以降、Apple Silicon
- Xcode(Swift 5.9 以降)。コンパイラは `xcrun as` と `xcrun clang` を使う

## ビルド

ビルドの作業領域は Dropbox の外に置きます。

```bash
swift build --scratch-path ~/Library/Caches/GAME-M4/build
```

```bash
Tools/build_app.sh
```

`Tools/build_app.sh` は `dist/GAME-M4.app` を作ります。既定の署名は ad-hoc です。環境変数 `GAMEM4_SIGN_IDENTITY` に Developer ID の証明書を指定すると、Hardened Runtime とタイムスタンプを付けて署名します(公証は別に `xcrun notarytool` で行います)。`gamem4` も `GAME-M4.app/Contents/MacOS/gamem4` に入ります。

## 使い方

```bash
~/Library/Caches/GAME-M4/build/debug/gamem4 examples/mandel.gam
```

```bash
~/Library/Caches/GAME-M4/build/debug/gamem4 compile examples/startrek.gam -o startrek
```

## テスト

```bash
swift test --scratch-path ~/Library/Caches/GAME-M4/build
```

- `GameCoreTests`: インタプリタ。Glow65 の GAME65G のテスト 41 件を移したものと、asm から読み取った動きのテスト
- `GameCompilerTests`: 同じプログラムをインタプリタとコンパイル版で動かし、出力がバイト単位で一致することを確かめる。Star Trek も含む

## 速さ

`10 S=0 I=1,10000 J=1,1000 S=S+J*I @=J+1 @=I+1`(内側のループ 1000 万回)を、リリースビルドで測った(2026-11-07、M4)。

| 方式 | 時間 |
|---|---|
| インタプリタ(`gamem4 bench.gam`) | 約 1.0 秒 |
| コンパイルしたプログラム | 約 0.03 秒 |

`examples/mandel.gam`(マンデルブロ集合、64 桁 × 25 行、反復の上限 20000)では、インタプリタが約 3.4 秒、コンパイルしたプログラムが約 0.04 秒だった。アプリを起動したときのエディタには、このプログラムが入っている。

## 構成

| 場所 | 内容 |
|---|---|
| `Sources/GameCore` | 仮想メモリ、行エディタ、インタプリタ、入出力 |
| `Sources/GameCompiler` | 構文解析、ARM64 のコード生成、ランタイム(`Runtime/gm_runtime.c`)、`as`/`clang` の呼び出し |
| `Sources/gamem4` | CLI |
| `Sources/GameM4App` | アプリ |
| `documents/designs/` | 設計書 |

ランタイムの C を直したら、`Tools/embed_runtime.sh` で `Sources/GameCompiler/RuntimeSource.swift` を作り直します。

## ライセンス

MIT License。[NOTICE.md](NOTICE.md) に、GAME 言語と GAME65G との関係を書いています。
