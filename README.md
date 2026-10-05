# Ruby の特性を活かした 4 つのアプリ

外部 gem なし・標準ライブラリだけで作っています (Ruby 3.4)。

**▶ ブラウザでそのまま動かす：https://nw-work-commits.github.io/ruby-playground/**

インストール不要です。Ruby 本体 ([ruby.wasm](https://github.com/ruby/ruby.wasm)) をブラウザに読み込み、
このリポジトリの Ruby のコードを**そのまま**ブラウザの中で動かしています（下の「ブラウザ版のしくみ」）。

| ディレクトリ | アプリ | 主に使っている Ruby の仕組み |
|---|---|---|
| `01_kakeibo` | 家計簿 DSL + CLI | `instance_eval` / `method_missing` / ブロックを保存して後で評価 / `Enumerable` / `Data.define` / Refinements |
| `02_minispec` | RSpec 風テストフレームワーク | 無名クラスと継承 / `define_method` / 演算子メソッド / `instance_exec` / `method_missing` / `at_exit` |
| `03_adventure` | テキストアドベンチャーエンジン (3 シナリオ + エディタ) | DSL / パターンマッチ (`case/in`) / `Marshal` によるセーブ / `binding.local_variable_get` / Prism による構文木の検査 |
| `04_miniweb` | Sinatra 風 Web フレームワーク + TODO・日程表 | クラスマクロ / `catch`/`throw` / ERB + `binding` / Rack 方式のミドルウェア / `OpenSSL::HMAC` / `TCPServer` + `Thread` / `slice_when` |

## ブラウザで全部見る (Ruby Playground)

```
ruby web/server.rb     # → http://127.0.0.1:3000
```

| URL | 内容 |
|---|---|
| `/` | ポータル |
| `/kakeibo` | 家計簿: 月別のカテゴリ棒グラフ (予算線付き)・月ごとの推移・前月比・明細。フォームから追加すると DSL ファイルに 1 行追記される。`/kakeibo/source` で DSL ファイルを色付き表示 |
| `/kakeibo/import` | 銀行・カードの明細 CSV を取り込む (下の「CSV 取り込み」) |
| `/spec` | 「▶ テストを実行」で全テストを別プロセスで実行し、結果をツリー表示 (名前で絞り込み可) |
| `/adventure` | 3 つのシナリオをブラウザで遊べる。移動・会話はボタンでもできる |
| `/adventure/editor` | シナリオを DSL で書いて、その場で試し遊び・保存 |
| `/todo` | TODO・日程表 (リスト表示と週表示) |

## ブラウザ版のしくみ

サーバー版 (`ruby web/server.rb`) は、`TCPServer` で受けたリクエストから env を組み立てて
`PLAYGROUND.call(env)` を呼んでいます。4 つのアプリはどれも `call(env)` を持つだけの Rack 方式なので、
**「受ける部分」だけを置き換えれば、残りはそのままブラウザで動きます。** 置き換えは `browser/` の中だけで、
アプリ側のコードは変えていません。

| ファイル | 役割 |
|---|---|
| `index.html` / `browser/boot.js` | Ruby 本体を起動し、画面のリンクとフォームを横取りして `PLAYGROUND.call(env)` を呼ぶ。CSS や画像もサーバー版と同じくアプリに頼んで受け取る |
| `browser/bridge.rb` | JS から受け取ったリクエストで、`MiniWeb::Server#handle` と同じ形の env を組み立てる |
| `browser/spec_runner.rb` | テストを**もう 1 つ別の Ruby VM** で走らせる。サーバー版の「別プロセスで走らせて、サーバーの状態を汚さない」をブラウザで再現したもの |
| `browser/wasm_env.rb` | ブラウザの Ruby との差を埋める (`socket` が無い／一時フォルダの権限を判定できない) |
| `browser/make_manifest.rb` | ブラウザに読み込むファイルの一覧 (`browser/files.json`) を作る。ファイルを足したら `ruby browser/make_manifest.rb` |

ブラウザ版の注意:
- 家計簿・TODO・アドベンチャーのセーブなどへの書き込みは、ブラウザの中の仮のフォルダに保存されます。**ページを再読み込みすると元に戻ります**
- 最初の 1 回は Ruby 本体 (約 9MB) の読み込みに数秒かかります。2 回目からはブラウザに残ります

## 今回の拡張

### 日程表 (`/todo/week`)
- 予定に **開始・終了時刻** を付けられる。終了を省略すると 1 時間の予定として扱う
- **繰り返し**: 毎日・平日・毎週・毎月、終了日つき。毎月 31 日のように存在しない日の月は飛ばす
- **重なりの警告**: 追加した時点で、今後 4 週間の予定と重なっていれば「⚠ 10/7 14:00–15:00『会議』と時間が重なっています」と出る。週表示では重なった予定を横に並べ、オレンジの枠で示す (重なりのない予定は全幅のまま)
- 週表示には現在時刻の線、終日の TODO、その週の予定の費用の合計

### 日程表 → 家計簿
予定に **費用とカテゴリ** を入れておくと、家計簿 DSL の 1 行でそのまま支出になります。繰り返しの予定 (毎週のジム 500 円など) は、家計簿に書いた月の中だけに展開します。

```ruby
from_schedule "../../04_miniweb/todos.json"   # 01_kakeibo/data/2026.rb
```

### CSV 取り込み (`/kakeibo/import`)
- **Shift_JIS** のままの明細 CSV を読める (UTF-8 として読めなければ Windows-31J とみなして変換。BOM 付き UTF-8 も可)
- 見出し (「ご利用日」「摘要」「お引出し」「お預入れ」…) から列を推測。画面で選び直せる
- 全角の「ＪＲ東海　モバイルＳｕｉｃａ」も NFKC 正規化して「JR東海 モバイルSuica」として扱う。「(500)」「△500」「-2,480」も読める。マイナスの金額 (返金) は収入にする
- カテゴリは **ルールファイル** [01_kakeibo/data/rules.rb](01_kakeibo/data/rules.rb) (これも Ruby の DSL) で振り分け。取り込み画面で「次回から」にチェックすると、ルールが 1 行追記されて次から自動になる
- 銀行の明細にある **カード引き落とし** は、カード明細と二重に数えてしまうので `skip` ルールで除外。家計簿にすでにある明細 (同じ日付・内容・金額) は重複として外す
- サンプル: [01_kakeibo/data/sample_card.csv](01_kakeibo/data/sample_card.csv) (Shift_JIS)

### オリジナルシナリオ「めんどう退治 ── しくみで消す者」
N.W. のポートフォリオの「めんどうな作業が、心底嫌い。だから、消す方法ばかり考えてきた」と、渡ってきた現場 (専門学校の C 言語、メーカーの Excel VBA、組み込みの巨大ソース、工場、職人の波形、月 10 万円を 0 円にした内製化) を、一つの建物の各フロアにしたシナリオです。三つの現場で「読み解く力」「測る目」「現場の感覚」を得て、組み合わせて「しくみ」を作り、サーバー室の請求書の亡霊を消します。

このためにエンジンへ次の機能を足しました。
- `answer`: NPC の問いかけに「○○と言う」で答える (全角・大小文字・句読点の違いは吸収)
- `recipe` と「作る」コマンド: 材料をそろえて組み立てる
- `fixed: true`: 持ち運べない置物
- `leaves_when`: フラグが立つと NPC が姿を消す

### シナリオエディタ (`/adventure/editor`)
ブラウザで DSL を書いて「検査する」「▶ 試しに遊ぶ」「保存して一覧に追加」ができます。組み込みシナリオを「これを元に書く」で開いて改造することもできます。保存先は `03_adventure/games/custom/*.adv` で、コンソール版 (`ruby 03_adventure/bin/play`) のメニューにも出ます。

送られてきたコードは、Ruby 3.4 に標準で入っている構文解析器 **Prism** で構文木にしてから検査します。DSL の命令と `state` の操作以外 (定数 `File`・`system`・バッククォート・`send`・`eval`・代入・`#{}` など) が 1 つでもあれば、実行せずに行番号つきでエラーを返します ([03_adventure/lib/adventure/script.rb](03_adventure/lib/adventure/script.rb))。

仕組み: [web/server.rb](web/server.rb) で `MiniWeb::URLMap` を使い、パスごとにアプリを振り分けています。どのアプリも `call(env)` を持つだけなので、単体で動く TodoApp もそのまま `/todo` に載せられます (リンクやリダイレクトには、`url()` ヘルパーでマウント先の `/todo` が自動で付きます)。

---

4つのアプリのテストはすべて、自作の **MiniSpec** で書いています (`web/spec` にはポータル全体のテストもあります)。

```
ruby run_specs.rb              # 全部
ruby run_specs.rb -f doc       # ツリー表示
ruby run_specs.rb -e セッション  # 名前に「セッション」を含むテストだけ
```

---

## 01 家計簿 DSL

家計簿ファイル (`data/2026.rb`) は「書式」に見えますが、中身はただの Ruby コードです。

```ruby
budget food: 40_000, fun: 15_000

every_month day: 25 do                 # 毎月の定期収支 (月末を超える日は末日に丸める)
  income "給料", 280_000, :salary
end
every_month day: 15, from: "2026-10" do # 期間限定のサブスク
  fun "動画配信サービス", 990
end

month "2026-10" do
  day 3 do
    food "スーパー", 5_120      # カテゴリ名がそのままメソッド名 (method_missing)
    fun  "ゲーム", 8_980
  end
end
```

```
cd 01_kakeibo
ruby bin/kakeibo report  data/2026.rb             # 月ごとのサマリー + グラフ + 予算アラート
ruby bin/kakeibo compare data/2026.rb -m 2026-10  # 前月比 (▲増 ▼減)
ruby bin/kakeibo list    data/2026.rb -m 2026-10  # 明細
ruby bin/kakeibo csv     data/2026.rb > out.csv
ruby bin/kakeibo check   data/2026.rb             # 予算オーバーなら終了コード 1
```

`every_month` のブロックはその場では実行せず、保存しておきます。ファイルを読み終えたら (`finish`)、`month` で書いたすべての月にまとめて展開します。

## 02 MiniSpec

```ruby
require_relative "lib/minispec"

MiniSpec.define_matcher(:have_size) { |actual, n| actual.size == n }   # 自作マッチャー

describe Stack do
  let(:stack) { Stack.new }
  after { puts "後片付け" }                                  # 失敗しても実行される

  it("最初は空") { expect(stack).to be_empty }               # be_empty → empty? (method_missing)
  it("pop で例外") { expect { stack.pop }.to raise_error(IndexError) }
  it("比較")      { expect(stack.size).to be < 1 }           # < もただのメソッド
end
```

```
ruby 02_minispec/spec/minispec_spec.rb -f doc
ruby 02_minispec/spec/minispec_spec.rb -e Stack
```

- `describe` は無名クラスを作り、ネストした `context` はそのサブクラスになります。`before` は外側から内側へ、`after` は内側から外側へ、継承チェーンをたどって実行されます
- 実行時の状態は `Runner` インスタンスが持ちます。そのため、テストの中からランナーを動かしてランナー自体をテストできます (セルフホスティング)

## 03 テキストアドベンチャー

```
cd 03_adventure
ruby bin/play            # メニューから選ぶ
ruby bin/play village    # 「星降る村」を直接起動
```

| シナリオ | 内容 |
|---|---|
| 古城の謎 (`games/castle.rb`) | 鍵・暗闇・合言葉で開く扉。中庭の亡霊がヒントをくれる |
| 星降る村 (`games/village.rb`) | 村人と話し、銅貨 → パン → 門番 と交換して道を開く |

NPC も DSL で書きます。

```ruby
npc :guard, "門番" do
  line "通っていいぞ", when: :guard_ok                  # 条件付きのセリフ (フラグ or 所持品)
  line "腹が減って…何か食わせてくれたら通してやる"      # 条件なし = いつものセリフ
  trade :bread, sets: :guard_ok, message: "うまい！"     # パンを渡すとフラグが立つ
end

room :bridge, "つり橋" do
  npcs :guard
  lock :north, flag: :guard_ok, message: "門番が通せんぼしている。"
end
```

- 入力は「北」「n」「鍵を取る」「取る 鍵」「take key」「村長と話す」「パンを門番に渡す」のどれでもよく、パターンマッチで解釈します
- `when:` は Ruby の予約語ですが、キーワード引数の名前には使えます。中身は `binding.local_variable_get(:when)` で取り出します
- `セーブ` / `ロード` は、ゲーム状態を `Marshal` でそのまま保存・復元します (`saves/` に保存)
- 自作ゲームは `Adventure.game "タイトル", id: :my_game do ... end` と書いたファイルを `games/` に置けば、メニューに出ます

## 04 MiniWeb + TODO アプリ

```
cd 04_miniweb
ruby app.rb      # → http://127.0.0.1:4567
```

```ruby
class TodoApp < MiniWeb::Base
  use MiniWeb::Middleware::Static, root: "public"
  use MiniWeb::Middleware::Session, secret: ENV.fetch("SESSION_SECRET")
  use MiniWeb::Middleware::MethodOverride

  post "/todos" do
    store.add(params["title"])
    flash[:notice] = "追加しました"     # 次のページで一度だけ表示
    redirect "/"
  end

  post "/api/todos" do
    case request.json                    # JSON をパターンマッチで分解
    in { title: String => title } then halt 201, json(store.add(title).to_h)
    else halt 422, json(error: "title is required")
    end
  end
end
```

- **TODO の機能**: 期限 (期限切れ・今日までを強調)、並べ替え (作成順・期限順・名前順)、絞り込み。絞り込みと並べ替えは**セッションに記憶**されます
- **セッション**: JSON → Base64 にした中身に HMAC-SHA256 の署名を付けて Cookie に保存します。改ざんされた Cookie は無視します。秘密鍵は環境変数 `SESSION_SECRET` で指定します (指定がなければ起動ごとにランダム)
- **静的ファイル**: `public/` (CSS・アイコン) を配信します。`../` でディレクトリの外へ出るパスは拒否します
- **HTTP サーバー**も `TCPServer` で自作しているので、リクエストを解析する流れを全部コードで追えます
- アプリは `call(env) → [status, headers, body]` という Rack 方式なので、サーバーを起動しなくても `TodoApp.call(env)` を直接呼んでテストできます
- JSON API: `GET /api/todos`, `GET /api/todos/:id`, `POST /api/todos` (`{"title": "...", "due": "YYYY-MM-DD"}`)
