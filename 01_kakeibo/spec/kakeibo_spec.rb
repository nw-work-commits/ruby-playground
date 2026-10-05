# 自作テストフレームワーク (02_minispec) で家計簿をテストする
require_relative "../../02_minispec/lib/minispec"
require_relative "../lib/kakeibo/report"
require "stringio"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../lib/kakeibo/importer"

describe Kakeibo do
  let(:ledger) do
    Kakeibo.define do
      budget food: 1_000

      month "2026-10" do
        fixed "家賃", 50_000, :housing
        day(1) { food "ランチ", 800 }
        day(2) do
          food "夕食", 700
          income "給料", 200_000
        end
      end
    end
  end

  it "method_missing でカテゴリ名をメソッドとして書ける" do
    lunch = ledger.find { _1.title == "ランチ" }
    expect(lunch.category).to eq :food
    expect(lunch.date).to eq Date.new(2026, 10, 1)
    expect(lunch).to be_expense
  end

  it "fixed は月の 1 日付けになる" do
    expect(ledger.find { _1.title == "家賃" }.date.day).to eq 1
  end

  it "Enumerable で集計できる" do
    expect(ledger.expenses.total).to eq 51_500
    expect(ledger.incomes.total).to eq 200_000
    expect(ledger.balance).to eq 148_500
    expect(ledger.expenses.by_category.keys).to eq %i[housing food]
  end

  it "予算オーバーを検出する" do
    expect(ledger.over_budget).to eq(food: [1_500, 1_000])
  end

  it "月で絞り込んでも予算情報を引き継ぐ" do
    expect(ledger.in_month("2026-10").budgets).to eq(food: 1_000)
    expect(ledger.in_month("2026-11")).to be_none
  end

  context "書き間違えたとき" do
    it "日付がないとエラー" do
      expect { Kakeibo.define { food "ランチ", 800 } }.to raise_error(Kakeibo::Error, /日付/)
    end

    it "金額がマイナスだとエラー" do
      expect { Kakeibo.define { expense "x", -1, on: "2026-10-01" } }.to raise_error(Kakeibo::Error, /正の整数/)
    end

    it "引数の形が違う呼び出しは NoMethodError" do
      expect { Kakeibo.define { food "金額なし" } }.to raise_error(NoMethodError)
    end
  end

  describe Kakeibo::Report do
    let(:out) { StringIO.new }

    it "月次レポートに予算オーバーの警告が出る" do
      Kakeibo::Report.new(ledger, out:).month("2026-10")
      expect(out.string).to include("収支 ¥148,500", "食費 が予算オーバー")
    end
  end

  it "サンプルデータを読み込める" do
    sample = Kakeibo.load(File.expand_path("../data/2026.rb", __dir__))
    expect(sample.months).to eq %w[2026-08 2026-09 2026-10]
    expect(sample.map(&:category)).to include(:books, :salary)
  end

  describe "every_month" do
    let(:recurring) do
      Kakeibo.define do
        every_month(day: 31) { income "給料", 100 }
        every_month(day: 15, from: "2026-03") { subscription "動画", 10 }
        month "2026-02"
        month "2026-03"
        month "2026-04"
      end
    end

    it "month で宣言した全ての月に展開される" do
      expect(recurring.incomes.map(&:month)).to eq %w[2026-02 2026-03 2026-04]
    end

    it "月末を超える日は末日に丸める" do
      expect(recurring.incomes.map { _1.date.day }).to eq [28, 31, 30]
    end

    it "from: で開始月を限定できる" do
      expect(recurring.expenses.map(&:month)).to eq %w[2026-03 2026-04]
    end

    it "ブロックがないとエラー" do
      expect { Kakeibo.define { every_month(day: 1) } }.to raise_error(Kakeibo::Error)
    end
  end

  describe "#compare" do
    let(:two_months) do
      Kakeibo.define do
        month("2026-09") { day(1) { food "a", 1_000; fun "b", 500 } }
        month("2026-10") { day(1) { food "a", 1_500; daily "c", 300 } }
      end
    end

    it "前月との差額をカテゴリごとに返す (片方にしかないカテゴリも含む)" do
      expect(two_months.compare("2026-10")).to eq(
        food: [1_500, 1_000, 500], daily: [300, 0, 300], fun: [0, 500, -500]
      )
    end

    it "前月比レポート" do
      out = StringIO.new
      Kakeibo::Report.new(two_months, out:).compare("2026-10")
      expect(out.string).to include("▲ ¥500", "▼ ¥500", "合計 +¥300")
    end
  end
end

describe "from_schedule (日程表との連携)" do
  let(:dir) { Dir.mktmpdir("kakeibo") }
  after { FileUtils.rm_rf(dir) }

  def write_schedule(todos)
    File.write(File.join(dir, "todos.json"), JSON.generate(todos))
    File.write(File.join(dir, "ledger.rb"), <<~RUBY)
      from_schedule "todos.json"
      month "2026-10"
      month "2026-11"
    RUBY
    Kakeibo.load(File.join(dir, "ledger.rb"))
  end

  it "費用つきの予定だけを、支出として取り込む" do
    ledger = write_schedule([
      { id: 1, title: "飲み会", due: "2026-10-09", start: "19:00", cost: 4000, category: "food" },
      { id: 2, title: "会議", due: "2026-10-09", start: "10:00" }
    ])
    expect(ledger.map(&:title)).to eq ["📅 飲み会"]
    expect(ledger.first).to satisfy { _1.amount == 4000 && _1.category == :food && _1.date == Date.new(2026, 10, 9) }
  end

  it "繰り返しの予定は、家計簿に書いた月の中だけに展開する" do
    ledger = write_schedule([{ id: 1, title: "ジム", due: "2026-09-01", repeat: "weekly", until: "2026-11-10", cost: 500, category: "fun" }])
    expect(ledger.map(&:date).map(&:to_s)).to eq %w[2026-10-06 2026-10-13 2026-10-20 2026-10-27 2026-11-03 2026-11-10]
  end

  it "ファイルが無ければ何もしない" do
    File.write(File.join(dir, "ledger.rb"), %(from_schedule "none.json"\nmonth "2026-10"))
    expect(Kakeibo.load(File.join(dir, "ledger.rb")).count).to eq 0
  end
end

describe Kakeibo::Importer do
  let(:rules) do
    Kakeibo::Rules.new.tap do |r|
      r.skip(/カード.*引落/, "二重計上")
      r.income_rule(/給与/, :salary)
      r.rule(/JR|Suica/i, :transport)
      r.rule("セブン", :food)
    end
  end
  let(:ledger) { Kakeibo.define { expense "セブン-イレブン", 540, :food, on: "2026-10-01" } }

  it "Shift_JIS の CSV を UTF-8 に直す。BOM 付き UTF-8 はそのまま" do
    sjis = "日付,内容\r\n".encode(Encoding::Windows_31J).b
    expect(Kakeibo::Importer.decode(sjis)).to eq ["日付,内容\r\n", "Shift_JIS"]
    expect(Kakeibo::Importer.decode("﻿日付".b)).to eq ["日付", "UTF-8"]
  end

  it "見出しから列を推測する (「入金」は「金額」より優先)" do
    imp = Kakeibo::Importer.new("取引日,摘要,お引出し,お預入れ,残高\n", rules:)
    expect(imp.guess_mapping).to eq(date: 0, title: 1, income: 3, expense: 2)
  end

  it "全角・返金・重複・除外・読めない行を見分ける" do
    csv = <<~CSV
      ご利用日,ご利用店名,ご利用金額
      2026/10/01,セブン-イレブン,540
      2026/10/02,ＪＲ東海　モバイルＳｕｉｃａ,"3,000"
      2026/10/03,AMAZON(返品),-1200
      2026/10/04,カード　引落,45000
      不明,何か,100
      2026/10/05,ラーメン,¥980
      2026/10/05,ラーメン,¥980
    CSV
    imp = Kakeibo::Importer.new(csv, rules:, ledger:)
    rows = imp.rows(imp.guess_mapping)
    expect(rows.map(&:status)).to eq %i[duplicate new new skip error new duplicate]
    expect(rows[1]).to satisfy { _1.title == "JR東海 モバイルSuica" && _1.amount == 3000 && _1.category == :transport }
    expect(rows[2]).to satisfy { _1.kind == :income && _1.amount == 1200 }
    expect(rows[5]).to satisfy { _1.amount == 980 && _1.category == :misc && _1.rule.nil? }
  end

  it "年のない日付は今年として読む" do
    imp = Kakeibo::Importer.new("日付,内容,金額\n10/03,a,1\n", year: 2026)
    expect(imp.rows(imp.guess_mapping).first.date).to eq Date.new(2026, 10, 3)
  end

  it "取り込む行は、どんな文字列でも安全な DSL になる" do
    row = Kakeibo::Importer::Row.new(date: Date.new(2026, 10, 1), title: 'a"#{exit}', amount: 1, kind: :expense, category: :misc)
    line = Kakeibo::Importer.to_dsl(row)
    expect(Kakeibo.define { instance_eval(line) }.first.title).to eq 'a"#{exit}'
  end

  it "サンプルの rules.rb とサンプル CSV を読める" do
    data = File.expand_path("../data", __dir__)
    text, encoding = Kakeibo::Importer.decode(File.binread(File.join(data, "sample_card.csv")))
    imp = Kakeibo::Importer.new(text, rules: Kakeibo::Rules.load(File.join(data, "rules.rb")))
    expect(encoding).to eq "Shift_JIS"
    expect(imp.rows(imp.guess_mapping).map(&:status).tally).to eq(new: 10, skip: 1)
  end
end
