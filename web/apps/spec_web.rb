# MiniSpec を Web から実行する。テストは別プロセスで走らせ (このサーバーの状態を汚さないため)、
# -f json の出力を受け取ってツリー表示する。
require "open3"
require "rbconfig"
require "json"
require_relative "playground_app"

class SpecWeb < PlaygroundApp
  ROOT = File.expand_path("../..", __dir__)

  Node = Struct.new(:name, :children, :examples) do
    def self.root = new(nil, {}, [])
    def child(name) = children[name] ||= Node.new(name, {}, [])
  end

  helpers do
    # ["Stack", "要素が入っているとき"] のような経路から木を組み立てる
    def build_tree(examples)
      examples.each_with_object(Node.root) do |ex, root|
        ex["path"].reduce(root) { |node, name| node.child(name) }.examples << ex
      end
    end

    def node_status(node)
      statuses = node.examples.map { _1["status"] } + node.children.values.map { node_status(_1) }
      %w[error failed].any? { statuses.include?(_1) } ? "failed" : "passed"
    end

    MARKS = { "passed" => "✓", "failed" => "✗", "error" => "✗", "pending" => "…" }.freeze

    def render_node(node)
      html = +"<ul>"
      node.examples.each do |ex|
        html << %(<li class="ex #{ex['status']}"><span class="mark">#{MARKS[ex['status']]}</span><span>)
        html << %(<span class="desc">#{h ex['description']}</span> <span class="loc">#{h ex['location']}</span>)
        html << %(<span class="err">#{h ex['error']}</span>) if ex["error"]
        html << "</span></li>"
      end
      node.children.each_value do |child|
        html << %(<li><div class="group">#{h child.name}</div>#{render_node(child)}</li>)
      end
      html << "</ul>"
    end
  end

  get "/" do
    @title = "テスト"
    @filter = params["e"].to_s.strip
    run_specs if params.key?("run")
    erb :"spec/index"
  end

  private

  def run_specs
    command = [RbConfig.ruby, File.join(ROOT, "run_specs.rb"), "-f", "json"]
    command += ["-e", @filter] unless @filter.empty?
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
    @wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    json_line = stdout.force_encoding(Encoding::UTF_8).lines.reverse.find { _1.start_with?("{") }
    @report = JSON.parse(json_line) if json_line
    @run_error = stderr.force_encoding(Encoding::UTF_8) unless @report
    @exit_status = status.exitstatus
  rescue JSON::ParserError => e
    @run_error = e.message
  end
end
