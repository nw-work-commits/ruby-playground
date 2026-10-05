# ブラウザ版が読み込むファイルの一覧 (browser/files.json) を作る。
#   ruby browser/make_manifest.rb
#
# git に入っている (または入れる予定の) ファイルのうち、ブラウザで Ruby が読むものだけを並べる。
# ブラウザ版の入口 (index.html / boot.js など) と説明書きは、Ruby からは読まないので外す。
require "json"

root = File.expand_path("..", __dir__)
files = Dir.chdir(root) { IO.popen(%w[git ls-files -z --cached --others --exclude-standard], &:read).split("\0") }

skip = lambda do |path|
  next true if %w[index.html .nojekyll .gitignore README.md].include?(path)
  next true if path.start_with?("browser/") && !path.end_with?(".rb")

  false
end

list = files.reject(&skip).uniq.sort
File.write(File.join(__dir__, "files.json"), "#{JSON.pretty_generate(list)}\n")
puts "browser/files.json: #{list.size} ファイル"
