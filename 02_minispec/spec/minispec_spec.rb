# MiniSpec 自身を MiniSpec でテストする (セルフホスティング)
require_relative "../lib/minispec"
require "stringio"

class Stack
  def initialize = @items = []
  def push(x) = tap { @items.push(x) }
  def pop = @items.pop || raise(IndexError, "stack is empty")
  def size = @items.size
  def empty? = @items.empty?
end

describe Stack do
  let(:stack) { Stack.new }

  it "最初は空" do
    expect(stack).to be_empty
    expect(stack.size).to eq 0
  end

  it "空のときに pop すると例外" do
    expect { stack.pop }.to raise_error(IndexError, /empty/)
  end

  it "push でサイズが 1 増える" do
    expect { stack.push(1) }.to change { stack.size }.by(1)
  end

  context "要素が入っているとき" do
    before { stack.push(1).push(2) }

    it "最後に入れたものから取り出す" do
      expect(stack.pop).to eq 2
      expect(stack.pop).to eq 1
    end

    it "空ではない" do
      expect(stack).not_to be_empty
    end
  end
end

describe "Matchers" do
  it "be_a / include / match / be_within" do
    expect("hello").to be_a(String)
    expect([1, 2, 3]).to include(1, 3)
    expect("ruby 3.4").to match(/\d\.\d/)
    expect(3.14159).to be_within(0.01).of(3.14)
    expect(5).to satisfy("be odd", &:odd?)
  end

  it "be と比較演算子" do
    expect(3).to be > 2
    expect(3).to be <= 3
    expect(3).not_to be < 1
    expect { expect(1).to be >= 5 }.to raise_error(MiniSpec::ExpectationFailed, "expected 1 to be >= 5")
  end

  it "let はテストごとにリセットされ、テスト内ではメモ化される" do
    counter = 0
    group = Class.new(MiniSpec::ExampleGroup) { let(:value) { counter += 1 } }
    a = group.new
    expect(a.value).to eq 1
    expect(a.value).to eq 1
    expect(group.new.value).to eq 2
  end

  it "失敗時は ExpectationFailed を投げる" do
    expect { expect(1).to eq 2 }.to raise_error(MiniSpec::ExpectationFailed, "expected 1 to eq 2")
  end

  it "保留中のテスト (ブロックなし)"
end

MiniSpec.define_matcher(:have_size) { |actual, n| actual.size == n }
MiniSpec.define_matcher(:be_between) { |actual, lo, hi| actual.between?(lo, hi) }

describe "define_matcher" do
  it "自作マッチャーが使える" do
    expect([1, 2, 3]).to have_size(3)
    expect(5).to be_between(1, 10)
    expect(50).not_to be_between(1, 10)
  end

  it "失敗メッセージに期待値が入る" do
    expect { expect([1]).to have_size(2) }.to raise_error(MiniSpec::ExpectationFailed, "expected [1] to have size 2")
  end
end

describe "before / after" do
  let(:log) { [] }

  before { log << :outer_before }
  after { log << :outer_after }

  context "ネストすると" do
    before { log << :inner_before }
    after { log << :inner_after }

    it "before は外→内、after は内→外の順" do
      expect(log).to eq %i[outer_before inner_before]
      group = self.class
      expect(group.afters.size).to eq 2
      instance = group.new
      group.afters.each { instance.instance_exec(&_1) }
      expect(instance.log).to eq %i[inner_after outer_after]
    end
  end

  it "after はテストが失敗しても実行される" do
    cleaned = false
    group = MiniSpec.build("x") do
      after { cleaned = true }
      it("落ちる") { expect(1).to eq 2 }
    end
    MiniSpec.run(groups: [group], out: StringIO.new)
    expect(cleaned).to eq true
  end
end

describe MiniSpec::Runner do
  let(:out) { StringIO.new }
  let(:group) do
    MiniSpec.build("計算") do
      it("足し算") { expect(1 + 1).to eq 2 }
      context("割り算") do
        it("ゼロ除算") { expect { 1 / 0 }.to raise_error(ZeroDivisionError) }
        it("わざと失敗") { expect(4 / 2).to eq 3 }
      end
    end
  end

  def run_with(**opts) = MiniSpec.run(groups: [group], out:, **opts)

  it "失敗があれば false を返し、場所を表示する" do
    expect(run_with).to eq false
    expect(out.string).to include("3 examples, 1 failures", "計算 割り算 わざと失敗", "minispec_spec.rb")
  end

  it "-e で名前に一致するものだけ実行する" do
    expect(run_with(filter: "ゼロ")).to eq true
    expect(out.string).to include("1 examples, 0 failures")
  end

  it "一致しないときはそう表示する" do
    run_with(filter: "存在しない")
    expect(out.string).to include("一致するテストはありません")
  end

  it "doc 形式ではネストをインデントして表示する" do
    run_with(format: :doc)
    expect(out.string).to include("計算\n", "  割り算\n", "✓ 足し算", "✗ わざと失敗")
  end

  it "json 形式ではネストの経路と結果を JSON で出す" do
    run_with(format: :json)
    report = JSON.parse(out.string)
    expect(report["summary"]).to satisfy { _1["total"] == 3 && _1["failed"] == 1 }
    failed = report["examples"].find { _1["status"] == "failed" }
    expect(failed["path"]).to eq %w[計算 割り算]
    expect(failed["error"]).to include("expected 2 to eq 3")
  end

  it "コマンドライン引数を解釈する" do
    expect(MiniSpec.parse_options(%w[-e foo -f doc])).to eq(filter: "foo", format: :doc)
  end
end
