# ブラウザの Ruby (ruby.wasm) と、ふつうの Ruby の差を埋める。bridge.rb と spec_runner.rb の最初に読む。
#
# 1. socket が無い → 代わりのファイル (browser/stub/socket.rb) を読ませる
# 2. 一時フォルダの権限を判定できず、Dir.tmpdir が見つからないと言う → /tmp を直接使う
require "tmpdir"

$LOAD_PATH.unshift(File.join(__dir__, "stub"))

def Dir.tmpdir = "/tmp"
