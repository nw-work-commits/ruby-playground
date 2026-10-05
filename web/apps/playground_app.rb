# ポータルに載せるアプリの共通の親クラス。テンプレートの場所とヘルパーを共有する。
require "securerandom"
require_relative "../../04_miniweb/lib/miniweb"

class PlaygroundApp < MiniWeb::Base
  set :views, File.expand_path("../views", __dir__)

  NAV = [
    ["/kakeibo", "家計簿"],
    ["/spec", "テスト"],
    ["/adventure", "アドベンチャー"],
    ["/todo", "TODO"]
  ].freeze

  # 起動ごとのランダムな鍵 (SESSION_SECRET があればそれを使う)
  SECRET = ENV.fetch("SESSION_SECRET") { SecureRandom.hex(32) }

  helpers do
    def current_section = request.env["SCRIPT_NAME"].to_s
    def page_title = @title ? "#{@title} · Ruby Playground" : "Ruby Playground"
  end
end
