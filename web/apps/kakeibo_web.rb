# 家計簿 DSL の Web 版。DSL ファイル (Ruby コード) を毎回読み込んで表示し、
# 画面から追加した支出は「DSL の 1 行」としてファイル末尾に追記する。
require "strscan"
require_relative "playground_app"
require_relative "../../01_kakeibo/lib/kakeibo/report"
require_relative "../../01_kakeibo/lib/kakeibo/importer"

class KakeiboWeb < PlaygroundApp
  using Kakeibo::YenFormat # Integer#to_yen をこのファイルの中だけで使う

  set :ledger_path, ENV.fetch("KAKEIBO_FILE") { File.expand_path("../../01_kakeibo/data/2026.rb", __dir__) }
  set :rules_path, ENV.fetch("KAKEIBO_RULES") { File.expand_path("../../01_kakeibo/data/rules.rb", __dir__) }
  set :sample_csv, File.expand_path("../../01_kakeibo/data/sample_card.csv", __dir__)
  use MiniWeb::Middleware::Session, secret: SECRET, key: "kakeibo.session"

  WRITE_LOCK = Mutex.new
  IMPORTS = {} # トークン → アップロードされた CSV (確定するまでサーバーのメモリに置く)
  MAX_CSV_BYTES = 2_000_000
  LABELS = Kakeibo::Report::LABELS
  EXPENSE_CATEGORIES = %i[food daily fun transport housing utility books misc].freeze
  INCOME_CATEGORIES = %i[salary bonus income].freeze
  KEYWORDS = %w[do end unless if each month day every_month budget income expense fixed from_schedule].freeze

  helpers do
    # ERB テンプレートは別ファイル (別スコープ) なので refinement は届かない → ヘルパー経由で使う
    def yen(amount) = amount.to_yen
    def label(category) = LABELS[category]
    def ledger_path = self.class.settings[:ledger_path]
    def rules_path = self.class.settings[:rules_path]
    def category_options = (EXPENSE_CATEGORIES + INCOME_CATEGORIES).map { [_1, label(_1)] }

    def importer_for(upload)
      Kakeibo::Importer.new(upload[:text], rules: Kakeibo::Rules.load(rules_path), ledger: Kakeibo.load(ledger_path))
    end

    # クエリの date=0&title=1… から列の対応を作る。なければ見出しから推測
    def mapping_from(params, importer)
      guessed = importer.guess_mapping
      return guessed unless params.key?("map_date")

      guessed.keys.to_h { |field| [field, Integer(params["map_#{field}"].to_s, exception: false)] }
    end
    def pct(value, max) = max.zero? ? 0 : (value * 100.0 / max).round(2)
  end

  get "/" do
    @title = "家計簿"
    begin
      @ledger = Kakeibo.load(ledger_path)
    rescue StandardError, SyntaxError => e
      @load_error = "#{e.class}: #{e.message}"
      next erb :"kakeibo/index"
    end
    @months = @ledger.months
    @month = @months.include?(params["month"]) ? params["month"] : @months.last
    @current = @ledger.in_month(@month.to_s)
    @by_category = @current.expenses.by_category
    @compare = @month ? @ledger.compare(@month) : {}
    @trend = @months.map { |m| [m, @ledger.in_month(m).expenses.total] }
    erb :"kakeibo/index"
  end

  post "/entries" do
    kind = params["kind"] == "income" ? :income : :expense
    title = params["title"].to_s.strip
    amount = Integer(params["amount"].to_s.delete(",_"), exception: false)
    date = (Date.iso8601(params["date"].to_s) rescue nil)
    category = params["new_category"].to_s.strip.then { _1.empty? ? params["category"].to_s : _1 }

    error =
      if title.empty? || title.size > 40 then "内容は 1〜40 文字で入力してください"
      elsif amount.nil? || !amount.positive? then "金額は正の整数で入力してください"
      elsif date.nil? then "日付が正しくありません"
      elsif !category.match?(/\A[a-z][a-z0-9_]{0,19}\z/) then "カテゴリは英小文字で入力してください (例: hobby)"
      end
    if error
      flash[:error] = error
      redirect "/"
    end

    # String#inspect は Ruby の文字列リテラルとして正しい形を返す ("#{" もエスケープされる)
    line = %(#{kind} #{title.inspect}, #{amount}, :#{category}, on: "#{date.iso8601}")
    append_entry(line)
    flash[:notice] = "追加しました: #{line}"
    redirect "/?month=#{date.strftime('%Y-%m')}"
  end

  get "/source" do
    @title = "家計簿 DSL ファイル"
    @source = File.read(ledger_path, encoding: "UTF-8")
    erb :"kakeibo/source"
  end

  # ---------------------------------------------------------------- CSV 取り込み
  get "/import" do
    @title = "明細 CSV の取り込み"
    @rules = Kakeibo::Rules.load(rules_path).rules
    erb :"kakeibo/import"
  end

  get "/import/sample.csv" do
    headers["content-type"] = "text/csv; charset=Shift_JIS"
    headers["content-disposition"] = %(attachment; filename="sample_card.csv")
    File.binread(self.class.settings[:sample_csv])
  end

  # ファイルは画面の JavaScript が Base64 にして送ってくる (フォームのファイル送信 = multipart は未対応のため)
  post "/import" do
    bytes =
      if (data = params["data"].to_s).empty? then params["text"].to_s.b
      else data.sub(/\Adata:[^,]*,/, "").unpack1("m")
      end
    if bytes.empty? || bytes.bytesize > MAX_CSV_BYTES
      flash[:error] = bytes.empty? ? "CSV を選ぶか、貼り付けてください" : "ファイルが大きすぎます (2MB まで)"
      redirect "/import"
    end
    text, encoding = Kakeibo::Importer.decode(bytes)
    token = SecureRandom.hex(12)
    WRITE_LOCK.synchronize do
      IMPORTS.delete(IMPORTS.keys.first) while IMPORTS.size >= 20
      IMPORTS[token] = { text:, encoding:, filename: File.basename(params["filename"].to_s)[0, 80] }
    end
    redirect "/import/preview?token=#{token}"
  end

  get "/import/preview" do
    @title = "取り込みの確認"
    @token = params["token"].to_s
    @upload = WRITE_LOCK.synchronize { IMPORTS[@token] } or redirect("/import")
    @importer = importer_for(@upload)
    @mapping = mapping_from(params, @importer)
    @rows = @importer.rows(@mapping)
    erb :"kakeibo/preview"
  rescue Kakeibo::Error, CSV::MalformedCSVError => e
    flash[:error] = "CSV を読めませんでした: #{e.message}"
    redirect "/import"
  end

  post "/import/commit" do
    upload = WRITE_LOCK.synchronize { IMPORTS[params["token"].to_s] } or redirect("/import")
    importer = importer_for(upload)
    rows = importer.rows(mapping_from(params, importer)).select(&:importable?)
    chosen = rows.select { params["include_#{_1.index}"] == "1" }
    learned = []
    chosen.each do |row|
      category = params["category_#{row.index}"].to_s
      row.category = category.to_sym if category.match?(/\A[a-z][a-z0-9_]{0,19}\z/)
      learned << row if params["learn_#{row.index}"] == "1"
    end
    if chosen.empty?
      flash[:error] = "取り込む明細が選ばれていません"
      redirect "/import/preview?token=#{params['token']}"
    end

    append_lines(chosen.map { Kakeibo::Importer.to_dsl(_1) },
                 comment: "CSV 取り込み: #{upload[:filename]} (#{Date.today.iso8601}, #{chosen.size} 件)")
    learn_rules(learned)
    WRITE_LOCK.synchronize { IMPORTS.delete(params["token"].to_s) }
    flash[:notice] = "#{chosen.size} 件を取り込みました" + (learned.any? ? "。ルールを #{learned.size} 件覚えました" : "")
    redirect "/?month=#{chosen.map(&:date).max.strftime('%Y-%m')}"
  end

  private

  def append_entry(line) = append_lines([line], comment: nil, suffix: " # web")

  # 追記して読み込めるか確かめ、壊れたら元に戻す
  def append_lines(lines, comment:, suffix: "")
    WRITE_LOCK.synchronize do
      original = File.read(ledger_path, encoding: "UTF-8")
      block = [("\n# #{comment}" if comment), *lines.map { "#{_1}#{suffix}" }].compact.join("\n")
      File.write(ledger_path, "#{original.chomp}\n#{block}\n")
      Kakeibo.load(ledger_path)
    rescue StandardError, SyntaxError
      File.write(ledger_path, original)
      raise
    end
  end

  # 「次回からこのカテゴリ」→ rules.rb に 1 行足す (同じ内容のルールがあれば足さない)
  def learn_rules(rows)
    return if rows.empty?

    WRITE_LOCK.synchronize do
      current = File.exist?(rules_path) ? File.read(rules_path, encoding: "UTF-8") : ""
      added = rows.uniq(&:title).filter_map do |row|
        line = "rule(#{row.title.inspect}, :#{row.category})"
        line unless current.include?(line)
      end
      File.write(rules_path, "#{current.chomp}\n#{added.join("\n")}\n") if added.any?
    end
  end

  # Ruby コードの簡易ハイライト。StringScanner で先頭から順に「何が来たか」を判定していく
  def highlight(source)
    scanner = StringScanner.new(source)
    html = +""
    until scanner.eos?
      html <<
        if (t = scanner.scan(/#[^\n]*/)) then %(<span class="c">#{h t}</span>)
        elsif (t = scanner.scan(/"(?:\\.|[^"\\])*"/)) then %(<span class="s">#{h t}</span>)
        elsif (t = scanner.scan(/:[a-z_]\w*|[a-z_]\w*:(?=\s)/)) then %(<span class="y">#{h t}</span>)
        elsif (t = scanner.scan(/[A-Za-z_]\w*[?!]?/)) then KEYWORDS.include?(t) ? %(<span class="k">#{t}</span>) : h(t)
        else h(scanner.getch)
        end
    end
    html
  end
end
