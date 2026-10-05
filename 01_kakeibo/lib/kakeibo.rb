# Kakeibo - Ruby の文法をそのまま「家計簿の書式」にする DSL
#
# 使っている Ruby の仕組み:
#   - instance_eval: 家計簿ファイル (ただの Ruby コード) を Builder の文脈で評価する
#   - method_missing: `food "ランチ", 980` のように「カテゴリ名 = メソッド名」で書ける
#   - Data.define: 不変な値オブジェクト (Ruby 3.2+)
#   - Enumerable: each を定義するだけで select / sum / group_by などが全部使える
#   - 動的なメソッド定義: 期間で絞り込んだ Ledger も同じ API で扱える

require "date"
require "set"

module Kakeibo
  class Error < StandardError; end

  Entry = Data.define(:date, :title, :amount, :category, :kind) do
    def expense? = kind == :expense
    def income?  = kind == :income
    def month    = date.strftime("%Y-%m")
  end

  class Ledger
    include Enumerable

    attr_reader :budgets

    def initialize(entries = [], budgets = {})
      @entries = entries
      @budgets = budgets
    end

    def each(&) = @entries.each(&)
    def add(entry) = tap { @entries << entry }

    def expenses = Ledger.new(select(&:expense?), budgets)
    def incomes  = Ledger.new(select(&:income?), budgets)
    def total    = sum(&:amount)
    def balance  = incomes.total - expenses.total
    def months   = map(&:month).uniq.sort

    def in_month(month) = Ledger.new(select { _1.month == month }, budgets)

    # 前月比: { food: [今月, 前月, 差額], ... }  (どちらかの月にあるカテゴリすべて)
    def compare(month)
      prev = (Date.strptime(month, "%Y-%m") << 1).strftime("%Y-%m")
      now_totals = in_month(month).expenses.by_category
      prev_totals = in_month(prev).expenses.by_category
      (now_totals.keys | prev_totals.keys).to_h do |cat|
        now, before = now_totals.fetch(cat, 0), prev_totals.fetch(cat, 0)
        [cat, [now, before, now - before]]
      end
    end

    # { food: 12000, fun: 3000, ... } を金額の大きい順に
    def by_category
      group_by(&:category).transform_values { _1.sum(&:amount) }
                          .sort_by { -_2 }.to_h
    end

    # 予算超過したカテゴリ => [使った額, 予算]
    def over_budget
      expenses.by_category.filter_map do |category, spent|
        limit = budgets[category]
        [category, [spent, limit]] if limit && spent > limit
      end.to_h
    end
  end

  # 家計簿ファイルを評価する文脈。ここに定義したメソッドがそのまま「書式」になる。
  class Builder
    attr_reader :ledger

    # base_dir: from_schedule の相対パスの基準 (家計簿ファイルのあるフォルダ)
    def initialize(ledger = Ledger.new, base_dir: Dir.pwd)
      @ledger = ledger
      @base_dir = base_dir
      @month = nil
      @day = nil
      @months = Set.new
      @recurring = []
      @schedules = []
    end

    # 日程表 (04_miniweb の todos.json) で「費用」を入れた予定を、支出として取り込む。
    #   from_schedule "../../04_miniweb/todos.json"
    # 繰り返しの予定は、month で書いた月の中だけに展開する。ファイルが無ければ何もしない。
    def from_schedule(path) = @schedules << File.expand_path(path, @base_dir)

    # budget food: 30_000, fun: 10_000
    def budget(**limits) = ledger.budgets.merge!(limits)

    def month(year_month, &block)
      @month = parse_month(year_month)
      @months << @month
      instance_eval(&block) if block
    ensure
      @month = nil
    end

    # 毎月くり返す収支。ブロックは「保存」しておき、finish でまとめて各月に展開する。
    #   every_month day: 25 do
    #     income "給料", 280_000, :salary
    #   end
    # day: が月末を超える場合 (31日など) はその月の末日になる。from: / to: で期間を限定できる。
    def every_month(day: 1, from: nil, to: nil, &block)
      raise Error, "every_month にはブロックが必要です" unless block

      @recurring << { day:, from: from && parse_month(from), to: to && parse_month(to), block: }
    end

    # 定期収支を展開して Ledger を返す。対象月は month で書いた月 (from / to で絞り込み)。
    def finish
      @recurring.each do |rule|
        months_for(rule).each do |m|
          @month = m
          day([rule[:day], Date.new(m.year, m.month, -1).day].min, &rule[:block])
        ensure
          @month = nil
        end
      end
      @recurring.clear
      @schedules.each { import_schedule(_1) }
      @schedules.clear
      ledger
    end

    def day(number, &block)
      raise Error, "day は month ブロックの中で使ってください" unless @month

      @day = Date.new(@month.year, @month.month, number)
      instance_eval(&block)
    ensure
      @day = nil
    end

    def expense(title, amount, category = :misc, on: nil)
      record(:expense, title, amount, category, on)
    end

    def income(title, amount, category = :income, on: nil)
      record(:income, title, amount, category, on)
    end

    # 毎月の固定費: fixed "家賃", 80_000, :housing  (month ブロック内で 1日付け)
    def fixed(title, amount, category = :fixed)
      raise Error, "fixed は month ブロックの中で使ってください" unless @month

      record(:expense, title, amount, category, @month)
    end

    # food "ランチ", 980  →  expense "ランチ", 980, :food
    def method_missing(name, *args, **opts, &block)
      title, amount = args
      if args.size == 2 && title.is_a?(String) && amount.is_a?(Integer) && block.nil?
        expense(title, amount, name, **opts)
      else
        super
      end
    end

    # to_str / to_ary などの暗黙変換には反応しない (puts などが誤作動するため)
    def respond_to_missing?(name, include_private = false) = !name.start_with?("to_") || super

    private

    def record(kind, title, amount, category, date)
      raise Error, "金額は正の整数で書いてください: #{title} #{amount.inspect}" unless amount.is_a?(Integer) && amount.positive?

      date = Date.parse(date) if date.is_a?(String)
      date ||= @day or raise Error, "日付がありません: #{title} (day ブロック内か on: で指定)"
      ledger.add(Entry.new(date:, title:, amount:, category: category.to_sym, kind:))
    end

    def parse_month(text) = Date.strptime(text, "%Y-%m")

    def import_schedule(path)
      return unless File.exist?(path)

      require_relative "../../04_miniweb/todo_store" # 繰り返しの判定は日程表と同じものを使う
      month_range = @months.min && (@months.min..Date.new(@months.max.year, @months.max.month, -1))
      TodoStore.new(path).all.select(&:cost).each do |todo|
        dates = todo.repeating? ? (month_range ? todo.occurrences(month_range) : []) : [todo.due_date].compact
        dates.select! { |d| !todo.repeating? || @months.any? { _1.year == d.year && _1.month == d.month } }
        dates.each do |date|
          ledger.add(Entry.new(date:, title: "📅 #{todo.title}", amount: todo.cost,
                               category: (todo.category || :misc).to_sym, kind: :expense))
        end
      end
    end

    def months_for(rule)
      @months.sort.select do |m|
        (rule[:from].nil? || m >= rule[:from]) && (rule[:to].nil? || m <= rule[:to])
      end
    end
  end

  def self.define(&block) = Builder.new.tap { _1.instance_eval(&block) }.finish

  def self.load(path)
    builder = Builder.new(base_dir: File.dirname(File.expand_path(path)))
    builder.instance_eval(File.read(path, encoding: "UTF-8"), path)
    builder.finish
  end
end
