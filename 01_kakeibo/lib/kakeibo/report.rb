# レポート出力。Refinements で Integer に `to_yen` を「このファイルの中だけ」生やす。
require_relative "../kakeibo"

module Kakeibo
  module YenFormat
    refine Integer do
      # 1234567.to_yen #=> "¥1,234,567"
      def to_yen = "#{'-' if negative?}¥#{abs.to_s.reverse.scan(/\d{1,3}/).join(',').reverse}"
    end

    # 全角文字を幅 2 として左寄せ・右寄せする (日本語の桁揃え用)
    refine String do
      def display_width = each_char.sum { _1.bytesize > 1 && _1 != "¥" ? 2 : 1 }
      def ljust_w(width) = self + " " * [width - display_width, 0].max
      def rjust_w(width) = " " * [width - display_width, 0].max + self
    end
  end

  class Report
    using YenFormat

    LABELS = Hash.new { |_, key| key.to_s }.merge(
      food: "食費", daily: "日用品", fun: "娯楽", transport: "交通費",
      housing: "住居", utility: "光熱費", books: "書籍", fixed: "固定費", misc: "その他",
      income: "収入", salary: "給与", bonus: "賞与"
    ).freeze

    BAR_WIDTH = 30

    def initialize(ledger, out: $stdout)
      @ledger = ledger
      @out = out
    end

    def summary
      @ledger.months.each { month(_1) }
      line "=" * 50
      line "全期間  収入 #{@ledger.incomes.total.to_yen}  支出 #{@ledger.expenses.total.to_yen}  収支 #{@ledger.balance.to_yen}"
    end

    def month(month)
      ledger = @ledger.in_month(month)
      line "=" * 50
      line "#{month}  収入 #{ledger.incomes.total.to_yen}  支出 #{ledger.expenses.total.to_yen}  収支 #{ledger.balance.to_yen}"
      line "-" * 50
      chart(ledger.expenses.by_category)
      ledger.over_budget.each do |category, (spent, limit)|
        line "  ⚠ #{LABELS[category]} が予算オーバー: #{spent.to_yen} / #{limit.to_yen} (+#{(spent - limit).to_yen})"
      end
    end

    # 前月比の表。増えたカテゴリは ▲、減ったカテゴリは ▼
    def compare(month)
      rows = @ledger.compare(month).sort_by { -_2[2].abs }
      line "#{month} の前月比 (支出)"
      line "-" * 50
      line "  #{'カテゴリ'.ljust_w(8)} #{'今月'.rjust_w(10)} #{'前月'.rjust_w(10)}   増減"
      rows.each do |category, (now, before, diff)|
        mark = diff.positive? ? "▲" : diff.negative? ? "▼" : " "
        line "  #{LABELS[category].ljust_w(8)} #{now.to_yen.rjust_w(10)} #{before.to_yen.rjust_w(10)}  #{mark} #{diff.abs.to_yen}"
      end
      total_diff = rows.sum { _2[2] }
      line "-" * 50
      line "  合計 #{total_diff.positive? ? '+' : ''}#{total_diff.to_yen}"
    end

    def entries(month = nil)
      ledger = month ? @ledger.in_month(month) : @ledger
      ledger.sort_by(&:date).each do |e|
        sign = e.income? ? "+" : "-"
        line "#{e.date}  #{LABELS[e.category].ljust_w(8)} #{"#{sign}#{e.amount.to_yen}".rjust_w(10)}  #{e.title}"
      end
    end

    private

    def chart(totals)
      max = totals.values.max or return
      totals.each do |category, amount|
        bar = "█" * (amount * BAR_WIDTH / max)
        budget = @ledger.budgets[category]
        note = budget ? " (予算 #{budget.to_yen})" : ""
        line "  #{LABELS[category].ljust_w(8)} #{bar.ljust(BAR_WIDTH)} #{amount.to_yen.rjust_w(10)}#{note}"
      end
    end

    def line(text) = @out.puts(text)
  end
end
