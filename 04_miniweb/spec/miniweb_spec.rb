# Rack 方式なので、サーバーを起動せずに TodoApp.call(env) を直接呼んでテストできる
require_relative "../../02_minispec/lib/minispec"
require "tmpdir"

ENV["QUIET"] = "1"
ENV["TODO_DB"] = File.join(Dir.tmpdir, "miniweb_spec_#{Process.pid}.json")
require_relative "../app"
MiniSpec.after_suite { File.delete(ENV["TODO_DB"]) if File.exist?(ENV["TODO_DB"]) }

# ブラウザの代わり: Cookie を覚えておき、次のリクエストで送る
module RequestHelpers
  def cookies = @cookies ||= {}

  # request("POST", "/todos", "title" => "x") の "title" => "x" は Ruby 3 ではキーワード引数扱いになる
  # (文字列キーでも)。そこで **fields で受けてフォームとして使う。
  def request(method, path, json: nil, app: TodoApp, **fields)
    form = fields.empty? ? nil : fields
    path, query = path.split("?", 2)
    body, type =
      if json then [JSON.generate(json), "application/json"]
      elsif form then [URI.encode_www_form(form), "application/x-www-form-urlencoded"]
      else ["", nil]
      end
    env = {
      "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => query.to_s,
      "CONTENT_TYPE" => type, "rack.input" => StringIO.new(body),
      "HTTP_COOKIE" => cookies.map { "#{_1}=#{_2}" }.join("; ")
    }
    app.call(env).tap do |_, headers, _|
      name, value = headers["set-cookie"]&.split(";")&.first&.split("=", 2)
      cookies[name] = value if name
    end
  end

  def page = request("GET", "/")[2].join
  def store = TodoApp.settings[:store]
end

describe MiniWeb::Base do
  include RequestHelpers

  it "ルートのパターンを名前付きキャプチャの正規表現にする" do
    pattern = MiniWeb::Base.compile("/users/:id/posts/:post_id")
    expect(pattern.match("/users/3/posts/9").named_captures).to eq("id" => "3", "post_id" => "9")
    expect(pattern).not_to match("/users/3")
  end

  it "サブクラスごとにルート表が分かれる" do
    a = Class.new(MiniWeb::Base) { get("/") { "A" } }
    b = Class.new(MiniWeb::Base) { get("/") { "B" } }
    expect(request("GET", "/", app: a)[2]).to eq ["A"]
    expect(request("GET", "/", app: b)[2]).to eq ["B"]
  end

  it "HEAD は GET のルートで処理する" do
    app = Class.new(MiniWeb::Base) { get("/") { "hi" } }
    expect(request("HEAD", "/", app:)[0]).to eq 200
  end

  it "ルート内の例外は 500 になる" do
    app = Class.new(MiniWeb::Base) { get("/") { raise "boom" } }
    status, _, body = request("GET", "/", app:)
    expect(status).to eq 500
    expect(body.join).to include("boom")
  end
end

describe MiniWeb::Middleware::Session do
  include RequestHelpers

  let(:secret) { "s" * 32 }
  let(:app) do
    counter = Class.new(MiniWeb::Base) do
      get("/") { (session["n"] = session.fetch("n", 0) + 1).to_s }
      get("/peek") { session.fetch("n", 0).to_s }
    end
    MiniWeb::Middleware::Session.new(counter, secret:)
  end

  it "Cookie で値がリクエストをまたいで保持される" do
    expect(request("GET", "/", app:)[2]).to eq ["1"]
    expect(request("GET", "/", app:)[2]).to eq ["2"]
  end

  it "変更がなければ Set-Cookie を返さない" do
    expect(request("GET", "/peek", app:)[1]).not_to include("set-cookie")
  end

  it "改ざんされた Cookie は無視する" do
    request("GET", "/", app:)
    data, signature = cookies["miniweb.session"].split("--")
    forged = [JSON.generate("n" => 999)].pack("m0").tr("+/", "-_")
    cookies["miniweb.session"] = "#{forged}--#{signature}"
    expect(request("GET", "/peek", app:)[2]).to eq ["0"]
    expect(data).not_to eq forged
  end

  it "短すぎる秘密鍵は拒否する" do
    expect { MiniWeb::Middleware::Session.new(->(_) {}, secret: "short") }.to raise_error(ArgumentError)
  end
end

describe MiniWeb::Middleware::Static do
  include RequestHelpers

  let(:fallback) { ->(_env) { [404, {}, ["app"]] } }
  let(:static) { MiniWeb::Middleware::Static.new(fallback, root: File.join(__dir__, "../public")) }

  it "public/ のファイルを Content-Type 付きで返す" do
    status, headers, body = request("GET", "/style.css", app: static)
    expect(status).to eq 200
    expect(headers["content-type"]).to include("text/css")
    expect(body.join).to include("--ruby")
  end

  it "ディレクトリの外 (../) には出られない" do
    expect(request("GET", "/../app.rb", app: static)[2]).to eq ["app"]
  end

  it "POST は素通しする" do
    expect(request("POST", "/style.css", app: static)[2]).to eq ["app"]
  end
end

describe TodoApp do
  include RequestHelpers

  before { store.all.each { store.delete(_1.id) } }

  it "トップページが表示される" do
    status, headers, body = request("GET", "/")
    expect(status).to eq 200
    expect(headers["content-type"]).to include("text/html")
    expect(body.join).to include("TODO・日程表", "タスクはありません", "/style.css")
  end

  it "追加すると / にリダイレクトし、フラッシュは一度だけ出る (HTML エスケープ付き)" do
    status, headers, = request("POST", "/todos", "title" => "<b>牛乳</b>を買う")
    expect(status).to eq 303
    expect(headers["location"]).to eq "/"
    first = page
    expect(first).to include("&lt;b&gt;牛乳&lt;/b&gt;を買う", "を追加しました")
    expect(page).not_to include("を追加しました")
  end

  it "空のタイトルや不正な日付はエラーメッセージを出して追加しない" do
    request("POST", "/todos", "title" => "  ")
    expect(page).to include("タイトルを入力してください")
    request("POST", "/todos", "title" => "x", "due" => "2026-13-45")
    expect(page).to include("日付が正しくありません")
    expect(store.all).to be_empty
  end

  it "完了切り替えとフィルタ。フィルタはセッションに記憶される" do
    request("POST", "/todos", "title" => "A")
    request("POST", "/todos", "title" => "B")
    request("POST", "/todos/#{store.all.first.id}/toggle")

    expect(request("GET", "/?filter=done")[2].join).to match(/class="title">\s*A\s*</)
    expect(page).not_to match(/class="title">\s*B\s*</) # クエリなしでも前回の「完了」フィルタのまま
    expect(request("GET", "/?filter=active")[2].join).not_to match(/class="title">\s*A\s*</)
  end

  it "期限順に並べ替え、期限切れを表示する" do
    today = Date.today
    request("POST", "/todos", "title" => "期限なし")
    request("POST", "/todos", "title" => "来週", "due" => (today + 7).iso8601)
    request("POST", "/todos", "title" => "昨日", "due" => (today - 1).iso8601)
    html = request("GET", "/?sort=due")[2].join
    expect(html.index("昨日")).to be < html.index("来週")
    expect(html.index("来週")).to be < html.index("期限なし")
    expect(html).to include("1日超過", "期限切れ 1 件")
  end

  describe "日程表" do
    it "時刻つきの予定を追加すると、重なる予定があれば警告する" do
      request("POST", "/todos", "title" => "会議", "due" => "2026-10-07", "start" => "14:00", "finish" => "15:00")
      request("POST", "/todos", "title" => "歯医者", "due" => "2026-10-07", "start" => "14:30", "finish" => "15:30")
      expect(page).to include("10/7 14:00–15:00「会議」 と時間が重なっています")
      request("POST", "/todos", "title" => "散歩", "due" => "2026-10-07", "start" => "15:30")
      expect(page).not_to include("重なっています") # 15:30 開始はちょうど終わったあとなので重ならない
    end

    it "時刻と繰り返しの入力ミスを止める" do
      request("POST", "/todos", "title" => "x", "start" => "10:00")
      expect(page).to include("日付を入れてください")
      request("POST", "/todos", "title" => "x", "due" => "2026-10-07", "start" => "10:00", "finish" => "09:00")
      expect(page).to include("終了時刻は開始時刻より後")
      request("POST", "/todos", "title" => "x", "due" => "2026-10-07", "finish" => "09:00")
      expect(page).to include("終了時刻だけは指定できません")
      request("POST", "/todos", "title" => "x", "due" => "2026-10-07", "cost" => "-5")
      expect(page).to include("費用は正の整数")
      expect(store.all).to be_empty
    end

    it "週表示に、繰り返しの予定が毎週出る" do
      request("POST", "/todos", "title" => "定例", "due" => "2026-10-05", "start" => "10:00", "finish" => "11:00",
                                "repeat" => "weekly", "cost" => "500", "category" => "food")
      html = request("GET", "/week?date=2026-10-14")[2].join
      expect(html).to include("2026年10月12日 〜 10月18日", "定例", "10:00–11:00 ↻", "今週の予定の費用 ¥500")
      expect(request("GET", "/week?date=2026-09-30")[2].join).not_to include("定例") # 開始日より前の週
    end

    it "JSON API でも同じ検証が効く" do
      expect(request("POST", "/api/todos", json: { title: "a", due: "2026-10-07", start: "25:00" })[0]).to eq 422
      status, _, body = request("POST", "/api/todos", json: { title: "a", due: "2026-10-07", start: "09:00", repeat: "weekdays" })
      expect(status).to eq 201
      expect(JSON.parse(body.join)).to satisfy { _1["repeat"] == "weekdays" && _1["finish"].nil? }
    end
  end

  it "_method=delete で DELETE ルートに届く (MethodOverride)" do
    request("POST", "/todos", "title" => "消す")
    expect { request("POST", "/todos/#{store.all.first.id}", "_method" => "delete") }
      .to change { store.all.size }.by(-1)
    expect(page).to include("「消す」を削除しました")
  end

  it "静的ファイルとファビコン" do
    expect(request("GET", "/favicon.svg")[1]["content-type"]).to eq "image/svg+xml"
  end

  describe "JSON API" do
    it "一覧と個別取得" do
      request("POST", "/todos", "title" => "API")
      status, headers, body = request("GET", "/api/todos")
      expect(status).to eq 200
      expect(headers["content-type"]).to eq "application/json"
      expect(JSON.parse(body.join).first["title"]).to eq "API"
      expect(request("GET", "/api/todos/9999")[0]).to eq 404
    end

    it "POST で作成すると 201" do
      status, _, body = request("POST", "/api/todos", json: { title: "JSONから", due: "2026-12-24" })
      expect(status).to eq 201
      expect(JSON.parse(body.join)).to satisfy { _1["title"] == "JSONから" && _1["due"] == "2026-12-24" }
    end

    it "title がない・日付が不正なら 422" do
      expect(request("POST", "/api/todos", json: { due: "2026-12-24" })[0]).to eq 422
      expect(request("POST", "/api/todos", json: { title: "x", due: "tomorrow" })[0]).to eq 422
    end
  end

  it "未定義のパスは 404" do
    expect(request("GET", "/nope")[0]).to eq 404
  end
end

describe MiniWeb::Request do
  it "不正な UTF-8 は置換文字にして例外にしない" do
    bad = "title=%82%A0%82%A2" # Shift_JIS の「あい」
    env = { "CONTENT_TYPE" => "application/x-www-form-urlencoded", "rack.input" => StringIO.new(bad) }
    expect(MiniWeb::Request.new(env).params["title"]).to be_valid_encoding
    json_env = { "CONTENT_TYPE" => "application/json", "rack.input" => StringIO.new("{\"title\":\"\x82\xA0\"}".b) }
    expect(MiniWeb::Request.new(json_env).json[:title]).to be_valid_encoding
  end
end

describe TodoStore::Todo do
  def todo(**attrs) = TodoStore::Todo.new(id: rand(1000), title: "t", done: false, **attrs)

  it "繰り返しの種類ごとに、その日に起きるかを判定する" do
    monday = Date.new(2026, 10, 5)
    week = (monday..monday + 6)
    expect(todo(due: "2026-10-05", repeat: "weekdays").occurrences(week).map(&:wday)).to eq [1, 2, 3, 4, 5]
    expect(todo(due: "2026-10-07", repeat: "weekly").occurrences(monday..monday + 20).map(&:day)).to eq [7, 14, 21]
    expect(todo(due: "2026-01-31", repeat: "monthly").occurs_on?(Date.new(2026, 2, 28))).to eq false # 31 日がない月は飛ばす
    expect(todo(due: "2026-10-05", repeat: "daily", until: "2026-10-06").occurrences(week).size).to eq 2
  end

  it "終了時刻がなければ 1 時間の予定とみなして重なりを判定する" do
    a = todo(id: 1, due: "2026-10-05", start: "10:00")
    b = todo(id: 2, due: "2026-10-05", start: "10:59")
    c = todo(id: 3, due: "2026-10-05", start: "11:00", finish: "11:30")
    expect(TodoStore.conflicts([a, b, c], Date.new(2026, 10, 5)).map { _1.map(&:id) }).to eq [[1, 2], [2, 3]]
  end
end

describe "週表示のレーン割り当て" do
  def ev(id, start, finish) = TodoStore::Todo.new(id:, title: id.to_s, due: "2026-10-07", start:, finish:)
  def lanes(*events) = TodoApp.new.lane_layout(events).to_h { |e, lane, total| [e.id, [lane, total]] }

  it "重なりのない予定は全幅、重なる塊の中だけ分ける" do
    expect(lanes(ev(1, "07:00", "07:40"), ev(2, "14:00", "15:00"), ev(3, "14:30", "15:30")))
      .to eq(1 => [0, 1], 2 => [0, 2], 3 => [1, 2])
  end

  it "A と B、B と C が重なれば、A と C が重ならなくても同じ塊。空いたレーンは使い回す" do
    expect(lanes(ev(1, "10:00", "11:00"), ev(2, "10:30", "12:00"), ev(3, "11:00", "11:30")))
      .to eq(1 => [0, 2], 2 => [1, 2], 3 => [0, 2])
  end
end
