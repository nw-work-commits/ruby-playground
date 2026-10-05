# MiniWeb - Sinatra 風のミニ Web フレームワーク (標準ライブラリのみ)
#
# 使っている Ruby の仕組み:
#   - クラスマクロ: get "/" do ... end は「クラスメソッドの呼び出し」。define_method で get/post/... を一括定義
#   - inherited フック不要の「クラスごとのインスタンス変数」でルート表を分離
#   - instance_exec: ルートのブロックをリクエストごとの新しいインスタンス上で実行する
#   - catch / throw: halt や redirect で処理を一気に脱出する (例外ではない大域脱出)
#   - ERB + binding: テンプレートからメソッドやインスタンス変数がそのまま見える。yield でレイアウトに埋め込む
#   - Rack 方式: アプリは call(env) → [status, headers, body] を返すだけのオブジェクト。
#     ミドルウェアは同じインターフェースで「包む」だけなので inject で積み重ねられる
#   - TCPServer + Thread: HTTP サーバーを自前で実装
#   - OpenSSL::HMAC: Cookie セッションの改ざん防止署名

require "socket"
require "uri"
require "erb"
require "json"
require "stringio"
require "openssl"

module MiniWeb
  Route = Data.define(:pattern, :block)

  # ------------------------------------------------------------------ Request
  class Request
    attr_reader :env

    def initialize(env) = @env = env

    def request_method = env["REQUEST_METHOD"]
    def path = env["PATH_INFO"]
    def query = decode(env["QUERY_STRING"])

    def form
      return {} unless env["CONTENT_TYPE"].to_s.start_with?("application/x-www-form-urlencoded")

      @form ||= decode(body)
    end

    # 不正な UTF-8 バイト列は scrub で置換する (strip などで例外にならないように)
    def body = env["rack.input"].read.tap { env["rack.input"].rewind }.dup.force_encoding(Encoding::UTF_8).scrub

    def params = query.merge(form)

    # application/json のリクエストボディ (壊れていれば nil)。
    # キーはシンボルにする → case/in のハッシュパターンでそのまま分解できる
    def json
      return nil unless env["CONTENT_TYPE"].to_s.start_with?("application/json")

      JSON.parse(body, symbolize_names: true)
    rescue JSON::ParserError
      nil
    end

    private

    def decode(str) = str.to_s.empty? ? {} : URI.decode_www_form(str).to_h.transform_values(&:scrub)
  end

  # ------------------------------------------------------------------ Base
  class Base
    class << self
      def routes = @routes ||= Hash.new { |h, verb| h[verb] = [] }
      def middlewares = @middlewares ||= []
      # 設定は親クラスから引き継ぐ (コピーなので子で set しても親は変わらない)
      def settings
        @settings ||= superclass.respond_to?(:settings) ? superclass.settings.dup : { views: File.join(Dir.pwd, "views") }
      end

      %w[GET POST PUT PATCH DELETE].each do |verb|
        define_method(verb.downcase) do |path, &block|
          routes[verb] << Route.new(pattern: compile(path), block:)
        end
      end

      def set(key, value) = settings[key] = value
      def use(middleware, *args, **opts) = middlewares << [middleware, args, opts]
      def helpers(&block) = class_eval(&block)

      # "/todos/:id" → /\A\/todos\/(?<id>[^\/]+)\z/
      def compile(path)
        source = path.split(%r{(:\w+)}).map { _1.start_with?(":") ? "(?<#{_1[1..]}>[^/]+)" : Regexp.escape(_1) }.join
        Regexp.new("\\A#{source}\\z")
      end

      # Rack インターフェース: ミドルウェアで包んだアプリを呼ぶ
      def call(env) = app.call(env)

      def app
        @app ||= middlewares.reverse.inject(->(env) { new.dispatch(env) }) do |inner, (klass, args, opts)|
          klass.new(inner, *args, **opts)
        end
      end

      def run!(port: 4567, host: "127.0.0.1") = MiniWeb.run!(self, port:, host:)
    end

    attr_reader :request, :headers, :params

    def dispatch(env)
      @request = Request.new(env)
      @headers = { "content-type" => "text/html; charset=utf-8" }
      status, body = catch(:halt) do
        route, match = find_route
        halt 404, not_found_page unless route
        @params = request.params.merge(match.named_captures)
        [200, instance_exec(*match.captures, &route.block)]
      end
      [status, headers, [body.to_s]]
    rescue StandardError => e
      [500, { "content-type" => "text/plain; charset=utf-8" }, ["500 Internal Server Error\n\n#{e.full_message(highlight: false)}"]]
    end

    # --- ルートの中で使えるヘルパー ---
    def halt(status, body = "") = throw(:halt, [status, body])

    # "/" で始まるパスはマウント先 (SCRIPT_NAME) を前に付ける
    def redirect(location, status = 303)
      headers["location"] = location.start_with?("/") ? url(location) : location
      halt status
    end

    # URLMap で "/todo" にマウントされていれば url("/todos") → "/todo/todos"
    def url(path) = "#{request.env['SCRIPT_NAME']}#{path}"

    def json(object)
      headers["content-type"] = "application/json"
      JSON.generate(object)
    end

    def h(text) = ERB::Util.html_escape(text)

    def session
      request.env.fetch("miniweb.session") { raise "use MiniWeb::Middleware::Session が必要です" }
    end

    # flash[:notice] = "保存しました" → 次のリクエストで一度だけ読める
    def flash = @flash ||= Flash.new(session)

    def erb(name, layout: :layout)
      content = render_template(name)
      layout && File.exist?(template_path(layout)) ? render_template(layout) { content } : content
    end

    private

    def find_route
      verb = request.request_method == "HEAD" ? "GET" : request.request_method
      routes = self.class.routes[verb]
      routes.each do |route|
        match = route.pattern.match(request.path)
        return [route, match] if match
      end
      nil
    end

    # binding はこのメソッドのローカル文脈。ブロックを渡すとテンプレート内の yield がそれを呼ぶ
    def render_template(name)
      ERB.new(File.read(template_path(name), encoding: "UTF-8"), trim_mode: "-").result(binding)
    end

    def template_path(name) = File.join(self.class.settings[:views], "#{name}.erb")

    def not_found_page = "<h1>404 Not Found</h1><p>#{h request.path}</p>"
  end

  # セッションに「次のリクエスト用」の値を置き、読んだら消える
  class Flash
    KEY = "_flash"

    def initialize(session)
      @session = session
      @now = session.delete(KEY) || {}
    end

    def [](key) = @now[key.to_s]
    # セッターは endless def (def x = ...) では書けない
    def []=(key, value)
      (@session[KEY] ||= {})[key.to_s] = value
    end
    def any? = @now.any?
  end

  # ------------------------------------------------------------------ Middleware
  module Middleware
    # セッションを Cookie に保存する。中身は JSON → Base64、改ざん防止に HMAC-SHA256 の署名を付ける。
    #   Cookie の値:  <base64(json)>--<署名>
    #   同じサーバーに複数アプリを載せるときは key: で Cookie 名を分ける
    class Session
      def initialize(app, secret:, key: "miniweb.session")
        raise ArgumentError, "secret は 32 文字以上にしてください" if secret.to_s.size < 32

        @app = app
        @secret = secret
        @key = key
      end

      def call(env)
        session = load(env["HTTP_COOKIE"])
        before = JSON.generate(session)
        env["miniweb.session"] = session
        status, headers, body = @app.call(env)
        if JSON.generate(session) != before
          path = env["SCRIPT_NAME"].to_s.empty? ? "/" : env["SCRIPT_NAME"]
          headers = headers.merge("set-cookie" => "#{@key}=#{dump(session)}; Path=#{path}; HttpOnly; SameSite=Lax")
        end
        [status, headers, body]
      end

      private

      def load(cookie_header)
        value = cookies(cookie_header)[@key] or return {}
        data, signature = value.split("--", 2)
        return {} unless signature && OpenSSL.secure_compare(sign(data), signature)

        JSON.parse(data.tr("-_", "+/").unpack1("m0").force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError, ArgumentError
        {}
      end

      def dump(session)
        data = [JSON.generate(session)].pack("m0").tr("+/", "-_")
        "#{data}--#{sign(data)}"
      end

      def sign(data) = OpenSSL::HMAC.hexdigest("SHA256", @secret, data)

      def cookies(header)
        header.to_s.split(/;\s*/).filter_map { _1.split("=", 2) if _1.include?("=") }.to_h
      end
    end

    # public/ 以下のファイルをそのまま返す。見つからなければアプリへ渡す。
    class Static
      TYPES = {
        ".css" => "text/css; charset=utf-8", ".js" => "text/javascript; charset=utf-8",
        ".svg" => "image/svg+xml", ".png" => "image/png", ".ico" => "image/x-icon",
        ".html" => "text/html; charset=utf-8", ".txt" => "text/plain; charset=utf-8"
      }.freeze

      def initialize(app, root:)
        @app = app
        @root = File.expand_path(root)
      end

      def call(env)
        return @app.call(env) unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

        path = File.expand_path(File.join(@root, env["PATH_INFO"]))
        # "../" でルートの外に出るパスは無視する (ディレクトリトラバーサル対策)
        return @app.call(env) unless path.start_with?("#{@root}/") && File.file?(path)

        headers = { "content-type" => TYPES.fetch(File.extname(path), "application/octet-stream"),
                    "cache-control" => "public, max-age=60" }
        [200, headers, [File.binread(path)]]
      end
    end

    # HTML フォームは GET/POST しか送れないので、_method=delete などで上書きする
    class MethodOverride
      def initialize(app) = @app = app

      def call(env)
        if env["REQUEST_METHOD"] == "POST"
          override = Request.new(env).form["_method"].to_s.upcase
          env["REQUEST_METHOD"] = override if %w[PUT PATCH DELETE].include?(override)
        end
        @app.call(env)
      end
    end

    class Logger
      def initialize(app, out = $stdout)
        @app = app
        @out = out
      end

      def call(env)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @app.call(env).tap do |status, _, _|
          ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
          @out.puts format("%s %-6s %-24s %d  %.1fms", Time.now.strftime("%H:%M:%S"), env["REQUEST_METHOD"], env["PATH_INFO"], status, ms)
        end
      end
    end
  end

  # ------------------------------------------------------------------ URLMap
  # 複数のアプリを 1 つのサーバーに載せる (Rack::URLMap と同じ考え方)。
  #   URLMap.new("/todo" => TodoApp, "/" => Portal)
  # "/todo/todos" へのリクエストは SCRIPT_NAME="/todo", PATH_INFO="/todos" として TodoApp に渡る。
  class URLMap
    def initialize(map)
      @map = map.sort_by { |prefix, _| -prefix.size } # 長いものから試す
    end

    def call(env)
      path = env["PATH_INFO"]
      prefix, app = @map.find { |p, _| p == "/" || path == p || path.start_with?("#{p}/") }
      return [404, { "content-type" => "text/plain; charset=utf-8" }, ["404 Not Found"]] unless app

      mounted = prefix == "/" ? "" : prefix
      rest = path.delete_prefix(mounted)
      app.call(env.merge("SCRIPT_NAME" => "#{env['SCRIPT_NAME']}#{mounted}", "PATH_INFO" => rest.empty? ? "/" : rest))
    end
  end

  def self.run!(app, port: 4567, host: "127.0.0.1") = Server.new(app, host:, port:).start

  # ------------------------------------------------------------------ Server
  class Server
    REASONS = {
      200 => "OK", 201 => "Created", 303 => "See Other", 400 => "Bad Request", 403 => "Forbidden",
      404 => "Not Found", 422 => "Unprocessable Content", 500 => "Internal Server Error"
    }.freeze

    def initialize(app, host:, port:)
      @app = app
      @host = host
      @port = port
    end

    def start
      $stdout.sync = true # パイプ経由でもログをすぐ出す
      server = TCPServer.new(@host, @port)
      puts "MiniWeb listening on http://#{@host}:#{@port}  (Ctrl+C で終了)"
      loop { Thread.new(server.accept) { handle(_1) } }
    rescue Interrupt
      puts "\nbye"
    ensure
      server&.close
    end

    private

    def handle(socket)
      request_line = socket.gets or return
      method, target, = request_line.split
      path, query = target.split("?", 2)

      headers = {}
      while (line = socket.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip
      end
      body = (socket.read(headers["content-length"].to_i) || "").force_encoding(Encoding::UTF_8)

      env = {
        "REQUEST_METHOD" => method,
        "PATH_INFO" => URI.decode_uri_component(path), # パスの "+" は空白にしない
        "QUERY_STRING" => query.to_s,
        "CONTENT_TYPE" => headers["content-type"],
        "rack.input" => StringIO.new(body)
      }
      headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }

      status, res_headers, res_body = @app.call(env)
      payload = res_body.join.b
      length = payload.bytesize
      payload = "" if method == "HEAD"
      socket.write "HTTP/1.1 #{status} #{REASONS.fetch(status, 'Unknown')}\r\n"
      res_headers.merge("content-length" => length, "connection" => "close")
                 .each { |k, v| socket.write "#{k}: #{v}\r\n" }
      socket.write "\r\n", payload
    rescue StandardError => e
      warn "#{e.class}: #{e.message}"
    ensure
      socket.close
    end
  end
end
