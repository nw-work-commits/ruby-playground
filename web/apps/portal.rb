require_relative "playground_app"

class Portal < PlaygroundApp
  APPS = [
    { path: "/kakeibo", num: "01", name: "家計簿 DSL",
      text: "Ruby のコードがそのまま家計簿になる。月別グラフ・予算アラート・前月比。銀行・カードの明細 CSV (Shift_JIS 可) をルールで振り分けて取り込み、日程表の費用も自動で入る。",
      tags: %w[instance_eval method_missing Enumerable Refinements Encoding] },
    { path: "/spec", num: "02", name: "MiniSpec",
      text: "自作の RSpec 風テストフレームワーク。ボタン 1 つで 4 アプリ全部のテストを走らせ、結果をツリーで表示する。",
      tags: %w[Class.new define_method instance_exec at_exit] },
    { path: "/adventure", num: "03", name: "テキストアドベンチャー",
      text: "ポートフォリオを元にしたオリジナル「めんどう退治」を含む 3 本のシナリオ。ブラウザのエディタで自分のシナリオを書いて、すぐ遊べる (Prism で検査してから実行)。",
      tags: %w[DSL case/in Marshal Prism] },
    { path: "/todo", num: "04", name: "TODO・日程表",
      text: "時刻つきの予定・繰り返し・重なりの警告・週のタイムライン。費用を入れた予定は家計簿に自動で入る。このサイト自体を動かしている自作フレームワーク上で動く。",
      tags: %w[Rack catch/throw ERB OpenSSL::HMAC] }
  ].freeze

  get "/" do
    erb :"portal/index"
  end
end
