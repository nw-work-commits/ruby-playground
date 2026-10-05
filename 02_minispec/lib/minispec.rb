# MiniSpec - RSpec 風の小さなテストフレームワーク
#
# 使っている Ruby の仕組み:
#   - describe ごとに「無名クラス」を作り、ネストは継承で表現する (Class.new(superclass))
#   - let は define_method でメモ化付きメソッドを動的に定義する
#   - before / it のブロックは instance_exec でテストインスタンス上で実行する
#   - be_empty / be_nil などは method_missing で述語メソッド (empty? / nil?) に変換する
#   - at_exit で自動実行 (minitest/autorun と同じ発想)
#   - define_matcher: Matchers モジュールにあとからメソッドを足す (オープンクラス)
#
# 実行オプション:  ruby xxx_spec.rb -e "名前の一部"  -f doc

require "json"

module MiniSpec
  class ExpectationFailed < StandardError; end

  # ---------------------------------------------------------------- Matcher
  class Matcher
    attr_reader :description

    def initialize(description, &predicate)
      @description = description
      @predicate = predicate
    end

    def matches?(actual) = @predicate.call(actual)
  end

  module Matchers
    def eq(expected)         = Matcher.new("eq #{expected.inspect}") { _1 == expected }
    def be_a(klass)          = Matcher.new("be a #{klass}") { _1.is_a?(klass) }
    # be(x) は同一オブジェクト。引数なしの be は比較演算子を受け付ける: expect(1).to be < 2
    def be(*args)
      return ComparisonBuilder.new if args.empty?

      Matcher.new("be #{args.first.inspect}") { _1.equal?(args.first) }
    end
    def match(pattern)       = Matcher.new("match #{pattern.inspect}") { pattern.match?(_1) }
    def include(*items)      = Matcher.new("include #{items.map(&:inspect).join(', ')}") { |a| items.all? { a.include?(_1) } }
    def be_within(delta)     = WithinBuilder.new(delta)
    def satisfy(desc = "satisfy block", &block) = Matcher.new(desc, &block)

    # expect { ... }.to raise_error(ZeroDivisionError, /divided/)
    def raise_error(klass = StandardError, message = nil)
      Matcher.new("raise #{klass}#{" (#{message.inspect})" if message}") do |block|
        block.call
        false
      rescue klass => e
        message.nil? || message === e.message
      end
    end

    # expect { x += 1 }.to change { x }.by(1)
    def change(&reader) = ChangeBuilder.new(reader)

    WithinBuilder = Struct.new(:delta) do
      def of(expected)
        Matcher.new("be within #{delta} of #{expected}") { (_1 - expected).abs <= delta }
      end
    end

    # 演算子もただのメソッドなので define_method で定義できる
    class ComparisonBuilder
      %i[< <= > >= == !=].each do |op|
        define_method(op) do |expected|
          Matcher.new("be #{op} #{expected.inspect}") { |actual| actual.public_send(op, expected) }
        end
      end
    end

    ChangeBuilder = Struct.new(:reader) do
      def by(amount)
        Matcher.new("change by #{amount}") do |block|
          before = reader.call
          block.call
          reader.call - before == amount
        end
      end
    end

    # be_empty → empty?, be_positive → positive?, be_nil → nil? ...
    def method_missing(name, *args, &block)
      return super unless name.start_with?("be_")

      predicate = :"#{name.to_s.delete_prefix('be_')}?"
      Matcher.new(name.to_s.tr("_", " ")) { _1.public_send(predicate, *args) }
    end

    def respond_to_missing?(name, include_private = false) = name.start_with?("be_") || super
  end

  # ---------------------------------------------------------------- Expectation
  class Expectation
    def initialize(actual) = @actual = actual

    def to(matcher)
      return if matcher.matches?(@actual)

      raise ExpectationFailed, "expected #{inspect_actual} to #{matcher.description}"
    end

    def not_to(matcher)
      return unless matcher.matches?(@actual)

      raise ExpectationFailed, "expected #{inspect_actual} not to #{matcher.description}"
    end
    alias to_not not_to

    private

    def inspect_actual = @actual.is_a?(Proc) ? "block" : @actual.inspect
  end

  # ---------------------------------------------------------------- ExampleGroup
  Example = Struct.new(:group, :description, :block, :location) do
    def full_description = "#{group.full_description} #{description}"
  end
  Result  = Struct.new(:example, :status, :error)

  class ExampleGroup
    include Matchers

    class << self
      attr_accessor :description

      def examples = @examples ||= []
      def children = @children ||= []
      def own_befores = @own_befores ||= []
      def own_afters = @own_afters ||= []

      # 親クラスから順に before を集める (継承チェーン = describe のネスト)
      def befores = group_chain.flat_map(&:own_befores)
      # after は内側から外側へ
      def afters = group_chain.reverse.flat_map(&:own_afters)

      def group_chain = ancestors.select { _1.is_a?(Class) && _1 <= ExampleGroup }.reverse

      def full_description
        parent = superclass
        [(parent.full_description if parent.respond_to?(:description) && parent.description), description].compact.join(" ")
      end

      def describe(description, &block)
        child = Class.new(self)
        child.description = description.to_s
        child.class_eval(&block)
        children << child
        child
      end
      alias context describe

      def it(description = "(no description)", &block)
        examples << Example.new(self, description, block, caller_locations(1, 1).first)
      end

      def before(&block) = own_befores << block
      def after(&block) = own_afters << block

      # let(:user) { User.new } → user メソッドを定義 (1テスト内でメモ化)
      def let(name, &block)
        define_method(name) do
          @__memo ||= {}
          @__memo.fetch(name) { @__memo[name] = instance_exec(&block) }
        end
      end

      def subject(&block) = let(:subject, &block)

      def all_examples = examples + children.flat_map(&:all_examples)
    end

    def expect(actual = nil, &block) = Expectation.new(block || actual)
  end

  # ---------------------------------------------------------------- Runner
  module Color
    refine String do
      def green  = "\e[32m#{self}\e[0m"
      def red    = "\e[31m#{self}\e[0m"
      def yellow = "\e[33m#{self}\e[0m"
      def gray   = "\e[90m#{self}\e[0m"
    end
  end
  using Color

  class << self
    def groups = @groups ||= []

    def describe(description, &block) = build(description, &block).tap { groups << _1 }

    # 登録せずにグループを作る (ランナー自体のテスト用)
    def build(description, &block)
      Class.new(ExampleGroup).tap do |group|
        group.description = description.to_s
        group.class_eval(&block)
      end
    end

    # 自作マッチャーを定義する。ブロックは (actual, *期待値) を受け取って真偽を返す。
    #   MiniSpec.define_matcher(:have_size) { |actual, n| actual.size == n }
    #   expect([1, 2]).to have_size(2)
    def define_matcher(name, &predicate)
      Matchers.define_method(name) do |*expected|
        description = [name.to_s.tr("_", " "), *expected.map(&:inspect)].join(" ")
        Matcher.new(description) { |actual| predicate.call(actual, *expected) }
      end
    end

    # コマンドライン引数を解釈する:  -e 名前の一部  /  -f doc  (ドキュメント形式で表示)
    def parse_options(argv)
      require "optparse"
      options = {}
      OptionParser.new do |o|
        o.on("-e", "--example PATTERN", "名前に PATTERN を含むテストだけ実行") { options[:filter] = _1 }
        o.on("-f", "--format FORMAT", %w[progress doc json], "出力形式 (progress / doc / json)") { options[:format] = _1.to_sym }
      end.parse(argv)
      options
    end

    def run(groups: self.groups, **options) = Runner.new(groups, **options).run

    # 全テストのあとに 1 回だけ実行する (一時ファイルの削除など)。
    # 自分で at_exit を書くと、at_exit は「後に登録したものが先に」動くので、テストより前に走ってしまう。
    def after_suite(&block) = after_suite_hooks << block
    def after_suite_hooks = @after_suite_hooks ||= []
  end

  # 実行時の状態 (出力先・絞り込み・形式) はインスタンスに持たせる。
  # → テストの中から別のランナーを動かしても、外側の実行に影響しない。
  class Runner
    def initialize(groups, out: $stdout, filter: nil, format: :progress)
      @groups = groups
      @out = out
      @filter = filter&.encode(Encoding::UTF_8) # Windows では ARGV が Windows-31J のことがある
      @format = format
    end

    def run
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = @groups.flat_map { run_group(_1, 0) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      if @format == :json
        @out.puts JSON.generate(to_json_report(results, elapsed))
      else
        @out.puts unless @format == :doc
        report(results, elapsed)
      end
      results.none? { %i[failed error].include?(_1.status) }
    end

    # 機械向けの結果 (Web 画面などで使う)。path はネストした describe の説明の配列
    def to_json_report(results, elapsed)
      {
        summary: { total: results.size, elapsed:, **results.map(&:status).tally.transform_keys(&:to_s) },
        examples: results.map do |r|
          {
            path: r.example.group.group_chain.filter_map(&:description),
            description: r.example.description,
            status: r.status,
            error: r.error && "#{r.error.class}: #{r.error.message}",
            location: r.example.location && "#{File.basename(r.example.location.path)}:#{r.example.location.lineno}"
          }
        end
      }
    end

    private

    def selected?(example) = @filter.nil? || example.full_description.include?(@filter)

    def run_group(group, depth)
      return [] if group.all_examples.none? { selected?(_1) }

      @out.puts "#{'  ' * depth}#{group.description}" if @format == :doc

      own = group.examples.select { selected?(_1) }.map { |ex| run_example(ex).tap { print_result(_1, depth + 1) } }
      own + group.children.flat_map { run_group(_1, depth + 1) }
    end

    def run_example(example)
      return Result.new(example, :pending, nil) if example.block.nil?

      instance = example.group.new
      begin
        example.group.befores.each { instance.instance_exec(&_1) }
        instance.instance_exec(&example.block)
        Result.new(example, :passed, nil)
      ensure
        example.group.afters.each { instance.instance_exec(&_1) }
      end
    rescue ExpectationFailed => e
      Result.new(example, :failed, e)
    rescue StandardError => e
      Result.new(example, :error, e)
    end

    def print_result(result, depth)
      return if @format == :json

      if @format == :doc
        mark, color = { passed: ["✓", :green], pending: ["…", :yellow] }.fetch(result.status, ["✗", :red])
        suffix = result.status == :pending ? " (保留)" : ""
        @out.puts "#{'  ' * depth}#{"#{mark} #{result.example.description}#{suffix}".public_send(color)}"
      else
        @out.print({ passed: ".".green, pending: "*".yellow, failed: "F".red, error: "E".red }[result.status])
      end
    end

    def report(results, elapsed)
      failures = results.select { %i[failed error].include?(_1.status) }
      failures.each.with_index(1) do |r, i|
        @out.puts
        @out.puts "  #{i}) #{r.example.full_description}"
        @out.puts "     #{r.error.class}: #{r.error.message}".red
        @out.puts "     # #{r.example.location.path}:#{r.example.location.lineno}".gray
      end
      counts = results.map(&:status).tally
      summary = "#{results.size} examples, #{failures.size} failures"
      summary += ", #{counts[:pending]} pending" if counts[:pending]
      @out.puts
      @out.puts "Finished in #{format('%.3f', elapsed)} seconds".gray
      @out.puts(failures.empty? ? summary.green : summary.red)
      @out.puts "(-e #{@filter.inspect} に一致するテストはありません)".yellow if results.empty? && @filter
    end
  end

  # トップレベルで describe を書けるようにする
  module DSL
    def describe(...) = MiniSpec.describe(...)
  end
end

TOPLEVEL_BINDING.receiver.extend(MiniSpec::DSL)

unless ENV["MINISPEC_NO_AUTORUN"]
  at_exit do
    next unless $!.nil?

    ok = MiniSpec.run(**MiniSpec.parse_options(ARGV))
    MiniSpec.after_suite_hooks.each(&:call)
    exit(ok)
  end
end
