# ブラウザのエディタから送られてくるシナリオ (Ruby の DSL) を、安全に読み込むための仕組み。
#
# Ruby のコードをそのまま instance_eval すると、File.delete でも system でも何でも書けてしまう。
# そこで Ruby 3.4 標準の構文解析器 Prism で「構文木」にしてから、
#   - 使ってよいノード (文字列・シンボル・ブロック・if など) だけか
#   - 呼んでよいメソッド (DSL の命令と state の操作) だけか
# を確かめ、通ったものだけを評価する。定数 (File, Kernel, Adventure ...) は一切書けない。
require "prism"
require_relative "../adventure"

module Adventure
  module Script
    Problem = Data.define(:line, :message) do
      def to_s = line ? "#{line} 行目: #{message}" : message
    end

    class Invalid < StandardError
      attr_reader :problems

      def initialize(problems)
        @problems = problems
        super(problems.map(&:to_s).join("\n"))
      end
    end

    MAX_SIZE = 60_000

    ALLOWED_NODES = %i[
      ProgramNode StatementsNode CallNode ArgumentsNode BlockNode BlockParametersNode ParametersNode
      RequiredParameterNode LocalVariableReadNode StringNode InterpolatedStringNode SymbolNode IntegerNode
      ArrayNode HashNode KeywordHashNode AssocNode TrueNode FalseNode NilNode
      IfNode UnlessNode ElseNode AndNode OrNode NextNode ParenthesesNode LambdaNode
    ].to_set.freeze

    # レシーバなしで呼べる DSL の命令
    DSL_METHODS = %i[
      game intro start item room npc recipe on_use goal
      name desc exits_to items npcs dark! lock
      aliases line trade answer leaves_when
    ].to_set.freeze

    # state.flag?(:x) のように、何かに対して呼べるメソッド (読み取りと、フラグ・持ち物の操作だけ)
    RECEIVER_METHODS = %i[
      room flags inventory turns flag? has? include? any? empty? size
      << delete == != ! > < >= <=
    ].to_set.freeze

    # 組み込みのシナリオと同じ id は使わせない
    RESERVED_IDS = %i[castle village mendou].freeze

    module_function

    # 問題点の一覧を返す (空なら OK)
    def check(source)
      return [Problem.new(line: nil, message: "長すぎます (#{MAX_SIZE} 文字まで)")] if source.size > MAX_SIZE

      result = Prism.parse(source)
      unless result.success?
        return result.errors.map { Problem.new(line: _1.location.start_line, message: "文法エラー: #{_1.message}") }
      end

      problems = []
      walk(result.value, problems)
      top = result.value.statements.body
      unless top.size == 1 && top.first.is_a?(Prism::CallNode) && top.first.name == :game
        problems << Problem.new(line: 1, message: "ファイルの中身は game \"タイトル\", id: :xxx do ... end ひとつだけにしてください")
      end
      problems
    end

    # 検査を通ったら評価して World を返す (登録はしない)
    def build(source)
      problems = check(source)
      raise Invalid, problems if problems.any?

      sandbox = Sandbox.new
      sandbox.instance_eval(source, "(scenario)", 1)
      world = sandbox.world or raise Invalid, [Problem.new(line: nil, message: "game が定義されていません")]
      if RESERVED_IDS.include?(world.id)
        raise Invalid, [Problem.new(line: 1, message: "id :#{world.id} は組み込みのシナリオと同じです。別の id にしてください")]
      end
      world
    rescue Invalid
      raise
    rescue StandardError => e # 引数の間違い・未定義の部屋など、評価してはじめて分かる誤り
      line = e.backtrace_locations&.find { _1.path == "(scenario)" }&.lineno
      raise Invalid, [Problem.new(line:, message: "#{e.class}: #{e.message}")]
    end

    # games/custom/*.adv をまとめて読み込んで登録する。壊れたファイルは飛ばして警告だけ出す。
    def load_dir(dir)
      Dir[File.join(dir, "*.adv")].sort.filter_map do |path|
        world = build(File.read(path, encoding: "UTF-8"))
        Adventure.registry[world.id] = world
      rescue Invalid => e
        warn "#{File.basename(path)} を読み込めませんでした:\n#{e.message}"
        nil
      end
    end

    def walk(node, problems)
      type = node.class.name.split("::").last.to_sym # Prism::CallNode → :CallNode
      line = node.location.start_line
      unless ALLOWED_NODES.include?(type)
        problems << Problem.new(line:, message: "#{describe(node)} は使えません")
        return
      end

      if node.is_a?(Prism::CallNode)
        allowed = node.receiver ? RECEIVER_METHODS : DSL_METHODS
        problems << Problem.new(line:, message: "メソッド #{node.name} は使えません") unless allowed.include?(node.name)
        if node.block && !node.block.is_a?(Prism::BlockNode)
          problems << Problem.new(line:, message: "&ブロック渡しは使えません")
          return
        end
      end
      node.compact_child_nodes.each { walk(_1, problems) }
    end

    def describe(node)
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode then "定数 #{node.slice}"
      when Prism::XStringNode, Prism::InterpolatedXStringNode then "コマンド実行 (`...`)"
      when Prism::EmbeddedStatementsNode then "文字列への式の埋め込み \#{...}"
      when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode then "変数への代入"
      else node.type.to_s.delete_suffix("_node").tr("_", " ")
      end
    end

    # DSL の入口。game だけを持つ空っぽのオブジェクトの上で評価する
    class Sandbox
      attr_reader :world

      def game(title, id:, &block)
        raise ArgumentError, "game は 1 つだけです" if @world

        @world = World.new(id.to_sym, title.to_s).tap { _1.instance_eval(&block) }.validate!
      end
    end
  end
end
