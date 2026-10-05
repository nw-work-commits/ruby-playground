# 別の Ruby VM の中で、全アプリのテストを MiniSpec でまとめて走らせ、結果を JSON で返す。
#
# run_specs.rb と同じファイルを読む。ただし at_exit での自動実行は止めて、自分で run する。
# ブラウザの Ruby VM は「終了」しないので、at_exit が動かないため。
ENV["MINISPEC_NO_AUTORUN"] = "1"
ENV["QUIET"] = "1"
require_relative "wasm_env"
require "stringio"

module SpecRunner
  ROOT = "/app"

  def self.run(filter)
    Dir.chdir(ROOT)
    Dir[File.join(ROOT, "*/spec/*_spec.rb")].sort.each { require _1 }
    out = StringIO.new
    options = { out:, format: :json }
    options[:filter] = filter.to_s unless filter.to_s.empty?
    MiniSpec.run(**options)
    MiniSpec.after_suite_hooks.each(&:call)
    out.string.lines.reverse.find { _1.start_with?("{") }.to_s
  end
end
