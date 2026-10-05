# 銀行・カードの明細 CSV を取り込む。
#
#   - 文字コード: 日本の銀行・カード会社の CSV は Shift_JIS (Windows-31J) が多い。
#     UTF-8 として正しく読めなければ Windows-31J とみなして変換する (BOM 付き UTF-8 にも対応)
#   - 列: 見出しの名前 (「ご利用日」「摘要」「お引出し」…) から日付・内容・金額の列を推測する
#   - カテゴリ: rules.rb (これも Ruby の DSL) のルールで振り分ける
#   - 二重取り込み: 家計簿にすでに同じ「日付・内容・金額」があれば重複として外す
require "csv"
require "date"
require_relative "../kakeibo"

module Kakeibo
  # 全角・半角の違いを吸収してから比べる (「ＪＲ」も「JR」も同じ)
  def self.normalize(text) = text.to_s.unicode_normalize(:nfkc).strip

  class Rules
    Rule = Data.define(:pattern, :category, :kind, :reason) do
      def match?(title)
        text = Kakeibo.normalize(title)
        pattern.is_a?(Regexp) ? pattern.match?(text) : text.include?(Kakeibo.normalize(pattern))
      end
    end

    attr_reader :rules

    def self.load(path)
      new.tap { _1.instance_eval(File.read(path, encoding: "UTF-8"), path) if path && File.exist?(path) }
    end

    def initialize = @rules = []

    # --- rules.rb の DSL ---
    def rule(pattern, category) = @rules << Rule.new(pattern:, category: category.to_sym, kind: :expense, reason: nil)
    def income_rule(pattern, category = :income) = @rules << Rule.new(pattern:, category: category.to_sym, kind: :income, reason: nil)
    def skip(pattern, reason = "ルールで除外") = @rules << Rule.new(pattern:, category: nil, kind: :skip, reason:)

    # 除外ルールは収入・支出どちらにも効く
    def match(title, kind) = rules.find { |r| (r.kind == kind || r.kind == :skip) && r.match?(title) }
  end

  class Importer
    Row = Struct.new(:index, :date, :title, :amount, :kind, :category, :status, :note, :rule, keyword_init: true) do
      def importable? = status == :new
      def key = [date, Kakeibo.normalize(title), amount]
    end

    COLUMN_HINTS = {
      date:    /日付|利用日|取引日|年月日|計上日|date/i,
      title:   /内容|摘要|店名|利用先|ご利用先|取引先|お取引|明細|description|memo|payee/i,
      expense: /出金|お引出し|引出|支払|ご利用金額|利用金額|金額|amount|withdraw/i,
      income:  /入金|お預入れ|預入|deposit/i
    }.freeze
    DATE_FORMATS = ["%Y/%m/%d", "%Y-%m-%d", "%Y.%m.%d", "%Y%m%d", "%Y年%m月%d日"].freeze

    attr_reader :headers, :body, :encoding

    # bytes: アップロードされたファイルの中身そのもの
    def self.decode(bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8).delete_prefix("﻿")
      return [text, "UTF-8"] if text.valid_encoding?

      [bytes.dup.force_encoding(Encoding::Windows_31J).encode(Encoding::UTF_8, invalid: :replace, undef: :replace), "Shift_JIS"]
    end

    def initialize(text, rules: Rules.new, ledger: Ledger.new, year: Date.today.year)
      table = CSV.parse(text.gsub("\r\n", "\n"), liberal_parsing: true).reject { |r| r.compact.all? { _1.strip.empty? } }
      raise Error, "CSV が空です" if table.empty?

      @headers, *@body = table
      @headers = @headers.map { Kakeibo.normalize(_1) }
      @rules = rules
      @existing = ledger.map { [_1.date, Kakeibo.normalize(_1.title), _1.amount] }.to_set
      @year = year
    end

    # 見出しから列を推測する。「入金」と「金額」のように両方に当てはまる列は、より具体的な income を優先
    def guess_mapping
      used = []
      %i[date title income expense].to_h do |field|
        index = headers.each_index.find { |i| !used.include?(i) && COLUMN_HINTS[field].match?(headers[i]) }
        used << index if index
        [field, index]
      end
    end

    def rows(mapping)
      seen = Set.new
      body.each_with_index.map do |cells, i|
        row = build_row(i, cells, mapping)
        if row.status == :new
          if @existing.include?(row.key) then row.status, row.note = :duplicate, "家計簿に同じ明細があります"
          elsif seen.include?(row.key) then row.status, row.note = :duplicate, "CSV の中で重複しています"
          end
          seen << row.key
        end
        row
      end
    end

    # 家計簿 DSL の行にする (String#inspect で、どんな文字列も安全な Ruby の文字列リテラルになる)
    def self.to_dsl(row)
      %(#{row.kind} #{row.title.inspect}, #{row.amount}, :#{row.category}, on: "#{row.date.iso8601}")
    end

    private

    def build_row(index, cells, mapping)
      date = parse_date(cells[mapping[:date]]) if mapping[:date]
      title = Kakeibo.normalize(cells[mapping[:title]]) if mapping[:title]
      expense = parse_amount(cells[mapping[:expense]]) if mapping[:expense]
      income = parse_amount(cells[mapping[:income]]) if mapping[:income]

      kind, amount, note =
        if income&.positive? then [:income, income, nil]
        elsif expense&.negative? then [:income, -expense, "マイナスの金額 (返金) を収入にしました"]
        elsif expense&.positive? then [:expense, expense, nil]
        end

      row = Row.new(index:, date:, title:, amount:, kind:, status: :new, note:)
      return row.tap { _1.status, _1.note = :error, "日付が読めません" } unless date
      return row.tap { _1.status, _1.note = :error, "内容が空です" } if title.to_s.empty?
      return row.tap { _1.status, _1.note = :error, "金額が読めません" } unless amount

      if (rule = @rules.match(title, kind))
        row.rule = rule
        return row.tap { _1.status, _1.note = :skip, rule.reason } if rule.kind == :skip

        row.category = rule.category
      else
        row.category = kind == :income ? :income : :misc
      end
      row
    end

    def parse_date(text)
      text = Kakeibo.normalize(text)
      DATE_FORMATS.each do |format|
        return Date.strptime(text, format)
      rescue Date::Error
        next
      end
      Date.strptime("#{@year}/#{text}", "%Y/%m/%d") # 「10/03」のように年がない明細
    rescue Date::Error
      nil
    end

    # "¥1,234" "1,234円" "(500)" "△500" "-500" を整数に
    def parse_amount(text)
      text = Kakeibo.normalize(text).delete(",¥\\円 ")
      return nil if text.empty?

      negative = text.match?(/\A[(△▲-]/)
      value = Integer(text.delete("()△▲-"), exception: false) or return nil
      negative ? -value : value
    end
  end
end
