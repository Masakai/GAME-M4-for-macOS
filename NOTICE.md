# NOTICE

GAME-M4 は、GAME 言語のインタプリタとコンパイラを、Apple Silicon の macOS 向けに Swift で書いたものである。

## ライセンス

- このリポジトリのコードと文書: `LICENSE`(MIT License、Copyright (c) 2026 masanorisakai)。

## GAME 言語について

- GAME 言語は、大西博氏が月刊アスキー(1978 年)で発表した言語である。
- GAME-M4 は、同じ作者の GAME65G(Glow65 の 6502 用 GAME インタプリタ、MIT License)の仕様とソースをもとに、Swift と C で書き直した。GAME65G は、公開された言語の仕様(月刊アスキーの特集「GAME65 & GAME-MZ」の記事)をもとに一から書いたものである。
- 鈴木仁志氏の GAME65(PET 用)とは別物である。GAME65 のコードや内部構成は使っていない。ほかの GAME 処理系のソースコードも参照していない。
- 仕様と、独自に決めた点は `documents/designs/2026-11-07-game-m4.md` にある。

## 例とテストのプログラム

- `Tests/GameCompilerTests/Programs/startrek.gam` と `examples/startrek.gam` は、Glow65 の `examples/startrek.gam`(同じ作者、MIT License)の写しである。1970 年代の Star Trek のゲームにならって書いたもので、元のゲームのコードは使っていない。

## 利用しているもの(同梱していない)

- Xcode の `as`、`clang`、`ld`: コンパイラが `xcrun` で呼ぶ。利用者の Mac に Xcode か Command Line Tools が必要。
