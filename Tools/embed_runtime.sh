#!/bin/bash
# Sources/GameCompiler/Runtime/gm_runtime.c を、Swift の文字列として RuntimeSource.swift に埋め込む。
# ランタイムを直したら、このスクリプトを実行する(テスト testEmbeddedRuntimeMatchesFile が食い違いを見つける)。
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=Sources/GameCompiler/Runtime/gm_runtime.c
OUT=Sources/GameCompiler/RuntimeSource.swift
{
    echo "// このファイルは Tools/embed_runtime.sh が $SRC から作る。直接編集しない。"
    echo ""
    echo "enum RuntimeSource {"
    echo "    static let text = #\"\"\""
    cat "$SRC"
    echo ""
    echo "\"\"\"#"
    echo "}"
} > "$OUT"
echo "書き出した: $OUT"
