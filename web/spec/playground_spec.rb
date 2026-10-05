# ポータル全体 (URLMap で束ねた 5 つのアプリ) を、サーバーを起動せずに call(env) でテストする
require_relative "../../02_minispec/lib/minispec"
require "tmpdir"
require "fileutils"

TMP_LEDGER = File.join(Dir.tmpdir, "playground_spec_ledger_#{Process.pid}.rb")
FileUtils.cp(File.expand_path("../../01_kakeibo/data/2026.rb", __dir__), TMP_LEDGER)
ENV["KAKEIBO_FILE"] = TMP_LEDGER
TMP_RULES = File.join(Dir.tmpdir, "playground_spec_rules_#{Process.pid}.rb")
FileUtils.cp(File.expand_path("../../01_kakeibo/data/rules.rb", __dir__), TMP_RULES)
ENV["KAKEIBO_RULES"] = TMP_RULES
TMP_CUSTOM = Dir.mktmpdir("playground_spec_custom")
ENV["ADVENTURE_CUSTOM_DIR"] = TMP_CUSTOM
ENV["TODO_DB"] ||= File.join(Dir.tmpdir, "playground_spec_todo_#{Process.pid}.json")
require_relative "../server"
MiniSpec.after_suite do
  [TMP_LEDGER, TMP_RULES, ENV["TODO_DB"]].each { File.delete(_1) if File.exist?(_1) }
  FileUtils.rm_rf(TMP_CUSTOM)
end

module PortalHelpers
  def jar = @jar ||= {}

  def call(method, path, **form)
    path, query = path.split("?", 2)
    body = form.empty? ? "" : URI.encode_www_form(form)
    env = {
      "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => query.to_s, "SCRIPT_NAME" => "",
      "CONTENT_TYPE" => ("application/x-www-form-urlencoded" unless form.empty?), "rack.input" => StringIO.new(body),
      "HTTP_COOKIE" => jar.map { "#{_1}=#{_2}" }.join("; ")
    }
    status, headers, chunks = PLAYGROUND.call(env)
    if (cookie = headers["set-cookie"])
      name, value = cookie.split(";").first.split("=", 2)
      jar[name] = value
    end
    [status, headers, chunks.join.force_encoding(Encoding::UTF_8)]
  end

  # リダイレクトを 1 回たどる
  def follow(method, path, **form)
    status, headers, = call(method, path, **form)
    expect(status).to eq 303
    call("GET", headers["location"].sub(/#.*/, ""))
  end
end

describe MiniWeb::URLMap do
  let(:map) do
    MiniWeb::URLMap.new(
      "/a" => ->(env) { [200, {}, ["a #{env['SCRIPT_NAME']} #{env['PATH_INFO']}"]] },
      "/" => ->(env) { [200, {}, ["root #{env['PATH_INFO']}"]] }
    )
  end

  def get(path) = map.call("PATH_INFO" => path)[2].first

  it "前方一致したアプリに SCRIPT_NAME と残りのパスを渡す" do
    expect(get("/a/x/y")).to eq "a /a /x/y"
    expect(get("/a")).to eq "a /a /"
  end

  it "/ab のように途中で切れる一致はしない" do
    expect(get("/ab")).to eq "root /ab"
  end
end

describe "Ruby Playground" do
  include PortalHelpers

  it "トップページに 4 つのアプリが並ぶ" do
    status, _, body = call("GET", "/")
    expect(status).to eq 200
    expect(body).to include("家計簿 DSL", "MiniSpec", "テキストアドベンチャー", "TODO・日程表")
  end

  it "共通の CSS を配信する" do
    status, headers, = call("GET", "/assets/playground.css")
    expect(status).to eq 200
    expect(headers["content-type"]).to include("text/css")
  end

  describe "家計簿" do
    it "月を指定してグラフと明細を表示する" do
      _, _, body = call("GET", "/kakeibo/?month=2026-09")
      expect(body).to include("カテゴリ別の支出", "月ごとの支出", "9月の明細", "焼肉", 'class="on">2026年09月')
    end

    it "フォームから追加すると DSL ファイルに 1 行追記される" do
      # '#{' を含むタイトルでも、コードとして実行されずに文字列のまま保存されること
      tricky = 'テスト"#{1 + 1}"'
      _, _, body = follow("POST", "/kakeibo/entries", kind: "expense", title: tricky, amount: "1234",
                                                      date: "2026-10-06", category: "food", new_category: "")
      expect(body).to include("追加しました")
      expect(File.read(TMP_LEDGER, encoding: "UTF-8")).to include('expense "テスト\"\#{1 + 1}\"", 1234, :food, on: "2026-10-06"')
      expect(Kakeibo.load(TMP_LEDGER).find { _1.amount == 1234 }.title).to eq tricky
    end

    it "不正な入力は追記しない" do
      before = File.read(TMP_LEDGER)
      _, _, body = follow("POST", "/kakeibo/entries", kind: "expense", title: "x", amount: "-5", date: "2026-10-06", category: "food")
      expect(body).to include("金額は正の整数")
      follow("POST", "/kakeibo/entries", kind: "expense", title: "x", amount: "5", date: "2026-10-06", category: "Food; system")
      expect(File.read(TMP_LEDGER)).to eq before
    end

    it "DSL ファイルをハイライト付きで表示する" do
      _, _, body = call("GET", "/kakeibo/source")
      expect(body).to include('<span class="k">every_month</span>', '<span class="y">:salary</span>')
    end
  end

  it "テスト画面 (実行前)" do
    _, _, body = call("GET", "/spec/")
    expect(body).to include("▶ テストを実行")
  end

  describe "アドベンチャー" do
    it "ゲームを始めてコマンドを送ると、ログに結果が追加される" do
      _, _, body = follow("POST", "/adventure/new", world: "village")
      expect(body).to include("村の広場", "💬 村長")
      _, _, body = follow("POST", "/adventure/play", command: "村長と話す")
      expect(body).to include("&gt; 村長と話す", "ランタン を受け取った")
      expect(body).to include("<li>ランタン</li>")
    end

    it "クリアすると「もう一度遊ぶ」になる" do
      follow("POST", "/adventure/new", world: "village")
      body = nil
      %w[話す 西 銅貨を取る 東 東 銅貨を渡す 西 北 パンを門番に渡す 北 ランタンを使う かけらを取る 南 南].each do |cmd|
        _, _, body = follow("POST", "/adventure/play", command: cmd)
      end
      expect(body).to include("再び星が輝いた", "もう一度遊ぶ")
    end

    it "存在しないゲームは 404" do
      expect(call("POST", "/adventure/new", world: "nope")[0]).to eq 404
    end
  end

  it "TODO は /todo の下で動き、リンクやリダイレクトに /todo が付く" do
    _, _, body = follow("POST", "/todo/todos", title: "ポータルから")
    expect(body).to include("ポータルから", 'action="/todo/todos"', 'href="/todo/style.css"', "← Ruby Playground")
  end
end

describe "Ruby Playground (拡張)" do
  include PortalHelpers

  describe "シナリオエディタ" do
    let(:source) do
      <<~RUBY
        game "テスト用", id: :spec_game do
          start :a
          room(:a, "はじまり") { desc "ここ"; exits_to north: :b }
          room(:b, "ゴール") { exits_to south: :a }
          goal("ついた") { |s| s.room == :b }
        end
      RUBY
    end

    it "組み込みシナリオを元に開くと、エディタで編集できる形になっている" do
      _, _, body = call("GET", "/adventure/editor?from=mendou")
      expect(body).to include("game &quot;めんどう退治", "id: :my_mendou")
      expect(body).not_to include("Adventure.game", "require_relative")
    end

    it "危ないコードは実行せず、行番号つきで問題を返す" do
      _, _, body = call("POST", "/adventure/editor", source: %(game "x", id: :x do\n  system("calc")\nend), action: "play")
      expect(body).to include("2 行目", "メソッド system は使えません")
    end

    it "検査 → 試し遊び → 保存 → 一覧に出る → 削除" do
      _, _, body = call("POST", "/adventure/editor", source:, action: "check")
      expect(body).to include("✓ 問題ありません", "部屋 2")

      _, _, body = follow("POST", "/adventure/editor", source:, action: "play")
      expect(body).to include("はじまり", "エディタに戻る")
      _, _, body = follow("POST", "/adventure/play", command: "北")
      expect(body).to include("ついた", "もう一度遊ぶ")
      expect(Adventure.registry).not_to include(:spec_game) # 試し遊びでは登録しない

      _, _, body = follow("POST", "/adventure/editor", source:, action: "save")
      expect(body).to include("「テスト用」を保存しました", "自作")
      expect(File.exist?(File.join(TMP_CUSTOM, "spec_game.adv"))).to eq true

      follow("POST", "/adventure/editor/delete", id: "spec_game")
      expect(File.exist?(File.join(TMP_CUSTOM, "spec_game.adv"))).to eq false
      expect(call("POST", "/adventure/editor/delete", id: "../server")[0]).to eq 400
    end
  end

  describe "明細 CSV の取り込み" do
    def upload(csv_bytes, filename = "card.csv")
      data = "data:text/csv;base64,#{[csv_bytes].pack('m0')}"
      status, headers, = call("POST", "/kakeibo/import", data:, filename:)
      expect(status).to eq 303
      headers["location"]
    end

    it "Shift_JIS をアップロード → 確認 → カテゴリを直して取り込み → ルールを覚える" do
      csv = "ご利用日,ご利用店名,ご利用金額\r\n2026/10/20,ＪＲ東海,1500\r\n2026/10/21,鈴木書房,2200\r\n2026/10/22,カード引落,9999\r\n"
      preview = upload(csv.encode(Encoding::Windows_31J).b)
      token = preview[/token=(\w+)/, 1]
      _, _, body = call("GET", preview)
      expect(body).to include("Shift_JIS", "JR東海", "鈴木書房", "除外", "カード明細と二重に数えない")

      _, _, body = follow("POST", "/kakeibo/import/commit", token:, map_date: "0", map_title: "1", map_expense: "2", map_income: "",
                                                            include_0: "1", category_0: "transport",
                                                            include_1: "1", category_1: "books", learn_1: "1")
      expect(body).to include("2 件を取り込みました", "ルールを 1 件覚えました")
      ledger = File.read(TMP_LEDGER, encoding: "UTF-8")
      expect(ledger).to include("# CSV 取り込み: card.csv", 'expense "JR東海", 1500, :transport, on: "2026-10-20"')
      expect(ledger).not_to include("カード引落")
      expect(File.read(TMP_RULES, encoding: "UTF-8")).to include('rule("鈴木書房", :books)')

      # 同じ CSV をもう一度読むと、取り込み済みの行は重複になる
      _, _, body = call("GET", upload(csv.encode(Encoding::Windows_31J).b))
      expect(body).to include("重複 2")
    end

    it "空のアップロードは戻される" do
      _, _, body = follow("POST", "/kakeibo/import", data: "", text: "")
      expect(body).to include("CSV を選ぶか、貼り付けてください")
    end
  end

  it "日程表の週表示が /todo の下で動く" do
    follow("POST", "/todo/todos", title: "定例会", due: "2026-10-06", start: "09:00", finish: "10:00", back: "/week?date=2026-10-06")
    _, _, body = call("GET", "/todo/week?date=2026-10-06")
    expect(body).to include("定例会", "09:00–10:00", 'href="/todo/week?date=2026-09-28"')
  end
end
