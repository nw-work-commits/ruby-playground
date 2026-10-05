# MiniWeb の上で動く TODO・日程表アプリ
#   起動: ruby app.rb  →  http://127.0.0.1:4567
require "securerandom"
require_relative "lib/miniweb"
require_relative "todo_store"

class TodoApp < MiniWeb::Base
  set :views, File.join(__dir__, "views")
  set :store, TodoStore.new(ENV.fetch("TODO_DB") { File.join(__dir__, "todos.json") })

  # 直接起動したときだけログを出す (ポータルに載せたときはポータル側でまとめて出す)
  use MiniWeb::Middleware::Logger if $PROGRAM_NAME == __FILE__
  use MiniWeb::Middleware::Static, root: File.join(__dir__, "public")
  # 秘密鍵は環境変数から。なければ起動ごとにランダム (再起動するとセッションはリセット)
  use MiniWeb::Middleware::Session, secret: ENV.fetch("SESSION_SECRET") { SecureRandom.hex(32) }, key: "todo.session"
  use MiniWeb::Middleware::MethodOverride

  FILTERS = {
    "all"    => ["すべて", ->(_) { true }],
    "active" => ["未完了", ->(t) { !t.done }],
    "done"   => ["完了",   ->(t) { t.done }]
  }.freeze

  # 日付なしは最後。sort_by に配列を返すと「1つ目で比べて、同じなら2つ目」になる
  SORTS = {
    "created" => ["作成順", ->(t) { [t.id] }],
    "due"     => ["日付順", ->(t) { [t.due ? 0 : 1, t.due.to_s, t.start || "99:99", t.id] }],
    "title"   => ["名前順", ->(t) { [t.title.downcase, t.id] }]
  }.freeze

  TIME = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/
  CATEGORY = /\A[a-z][a-z0-9_]{0,19}\z/
  CATEGORIES = { "food" => "食費", "fun" => "娯楽", "transport" => "交通費", "daily" => "日用品",
                 "books" => "書籍", "misc" => "その他" }.freeze

  helpers do
    def store = self.class.settings[:store]

    # クエリで指定されたら覚えておき、指定がなければ前回の値を使う (セッション)
    def remembered(key, choices, default)
      session[key] = params[key] if choices.key?(params[key])
      choices.key?(session[key]) ? session[key] : default
    end

    def parse_due(text)
      return nil if text.to_s.empty?

      Date.iso8601(text.to_s).iso8601
    rescue Date::Error
      :invalid
    end

    def blank_to_nil(value) = value.to_s.strip.then { _1.empty? ? nil : _1 }

    # フォームと JSON API で共通の入力チェック。[属性, エラーメッセージ] を返す
    def event_attrs(input)
      due = parse_due(input["due"])
      start = blank_to_nil(input["start"])
      finish = blank_to_nil(input["finish"])
      repeat = TodoStore::REPEATS.key?(input["repeat"].to_s) ? input["repeat"].to_s : "none"
      repeat_until = parse_due(input["until"])
      cost_text = blank_to_nil(input["cost"])&.delete(",")
      cost = cost_text && Integer(cost_text, exception: false)
      category = blank_to_nil(input["category"])

      error =
        if due == :invalid then "日付が正しくありません"
        elsif repeat_until == :invalid then "繰り返しの終了日が正しくありません"
        elsif start && !TIME.match?(start) then "開始時刻は HH:MM で入力してください"
        elsif finish && !TIME.match?(finish) then "終了時刻は HH:MM で入力してください"
        elsif finish && !start then "終了時刻だけは指定できません (開始時刻も入れてください)"
        elsif start && finish && finish <= start then "終了時刻は開始時刻より後にしてください"
        elsif (start || repeat != "none") && due.nil? then "時刻や繰り返しを使うときは日付を入れてください"
        elsif repeat_until && due && repeat_until < due then "繰り返しの終了日は開始日より後にしてください"
        elsif cost_text && !(cost&.positive?) then "費用は正の整数で入力してください"
        elsif category && !CATEGORY.match?(category) then "カテゴリは英小文字で入力してください"
        end
      return [nil, error] if error

      attrs = { due:, start:, finish:, repeat: (repeat unless repeat == "none"), until: (repeat_until unless repeat == "none"),
                cost:, category: (category || "misc" if cost) }
      [attrs, nil]
    end

    # 追加した予定と重なる予定を、これから 4 週間ぶん探す
    def conflicts_for(todo)
      return [] unless todo.timed?

      dates = todo.repeating? ? (todo.due_date..todo.due_date + 27).to_a : [todo.due_date]
      others = store.all
      dates.lazy.flat_map do |date|
        TodoStore.conflicts(others, date).filter_map { |a, b| [date, a.id == todo.id ? b : a] if [a.id, b.id].include?(todo.id) }
      end.first(3)
    end

    def due_label(todo)
      return todo.repeat_label if todo.repeating?

      days = (todo.due_date - Date.today).to_i
      case days
      when ...0 then "#{-days}日超過"
      when 0 then "今日"
      when 1 then "明日"
      else todo.due_date.strftime("%-m/%-d")
      end
    end

    def monday_of(date) = date - ((date.wday - 1) % 7)

    # 重なる予定を横に並べるための「レーン」割り当て。
    # まず時間がつながっている予定どうしを「塊」にまとめ (slice_when)、塊の中だけで空いている一番左のレーンに入れる。
    # → 午後に 2 つ重なっていても、朝の予定は全幅のまま
    def lane_layout(events)
      cluster_end = nil
      clusters = events.sort_by(&:start_min).slice_when do |prev, event|
        cluster_end = [cluster_end || 0, prev.end_min].max
        (event.start_min >= cluster_end).tap { cluster_end = nil if _1 }
      end
      clusters.flat_map do |cluster|
        lane_ends = []
        placed = cluster.map do |event|
          lane = lane_ends.index { _1 <= event.start_min } || lane_ends.size
          lane_ends[lane] = event.end_min
          [event, lane]
        end
        placed.map { |event, lane| [event, lane, lane_ends.size] }
      end
    end

    def yen(amount) = "¥#{amount.to_s.reverse.scan(/\d{1,3}/).join(',').reverse}"
  end

  get "/" do
    @filter = remembered("filter", FILTERS, "all")
    @sort = remembered("sort", SORTS, "created")
    todos = store.all
    @remaining = todos.count { !_1.done }
    @overdue = todos.count(&:overdue?)
    @todos = todos.select(&FILTERS[@filter][1]).sort_by(&SORTS[@sort][1])
    erb :index
  end

  # 週表示: /week?date=2026-10-07 (その日を含む月曜〜日曜)
  get "/week" do
    base = (Date.iso8601(params["date"].to_s) rescue Date.today)
    @monday = monday_of(base)
    @days = (@monday..@monday + 6).to_a
    todos = store.all
    @timed = @days.to_h { |d| [d, todos.select { _1.timed? && _1.occurs_on?(d) }.sort_by(&:start_min)] }
    @allday = @days.to_h { |d| [d, todos.select { !_1.timed? && _1.occurs_on?(d) }] }
    @conflicts = @days.to_h { |d| [d, TodoStore.conflicts(todos, d)] }
    minutes = @timed.values.flatten.flat_map { [_1.start_min, _1.end_min] }
    @first_hour = [7, *minutes.map { _1 / 60 }].min
    @last_hour = [21, *minutes.map { (_1 + 59) / 60 }].max.clamp(0, 24)
    @week_cost = @days.sum { |d| (@timed[d] + @allday[d]).sum { _1.cost.to_i } }
    erb :week
  end

  post "/todos" do
    title = params["title"].to_s.strip
    attrs, error = event_attrs(params)
    back = params["back"].to_s.start_with?("/week") ? params["back"] : "/"
    if title.empty?
      flash[:error] = "タイトルを入力してください"
    elsif error
      flash[:error] = error
    else
      todo = store.add(title, **attrs)
      flash[:notice] = "「#{title}」を追加しました"
      if (hits = conflicts_for(todo)).any?
        flash[:warning] = "⚠ " + hits.map { |date, other| "#{date.strftime('%-m/%-d')} #{other.time_label}「#{other.title}」" }.join("、") + " と時間が重なっています"
      end
    end
    redirect back
  end

  # "/todos/:id" より先に定義する (上から順にマッチするため)
  delete "/todos/done" do
    count = store.all.count(&:done)
    store.clear_done
    flash[:notice] = "完了済みの #{count} 件を削除しました"
    redirect "/"
  end

  post "/todos/:id/toggle" do |id|
    store.toggle(id) or halt 404, "not found"
    redirect "/"
  end

  delete "/todos/:id" do |id|
    todo = store.find(id) or halt 404, "not found"
    store.delete(id)
    flash[:notice] = "「#{todo.title}」を削除しました"
    redirect params["back"].to_s.start_with?("/week") ? params["back"] : "/"
  end

  # ---- JSON API ----
  get "/api/todos" do
    json store.all.map(&:to_h)
  end

  get "/api/todos/:id" do |id|
    todo = store.find(id) or halt 404, json(error: "not found")
    json todo.to_h
  end

  # curl -X POST -H "Content-Type: application/json" -d '{"title":"会議","due":"2026-10-10","start":"14:00"}' http://127.0.0.1:4567/api/todos
  post "/api/todos" do
    case request.json
    in { title: String => title, **rest } unless title.strip.empty?
      attrs, error = event_attrs(rest.transform_keys(&:to_s))
      halt 422, json(error:) if error
      halt 201, json(store.add(title.strip, **attrs).to_h)
    else
      halt 422, json(error: "title is required")
    end
  end
end

TodoApp.run!(port: ENV.fetch("PORT", 4567).to_i) if $PROGRAM_NAME == __FILE__
