# ブラウザ版の「つなぎ」。
#
# サーバー版は TCPServer で受けたリクエストから env を組み立てて PLAYGROUND.call(env) を呼ぶ
# (04_miniweb/lib/miniweb.rb の Server#handle)。ブラウザ版は、JS から受け取ったリクエストで
# 同じ形の env を組み立てて、同じ PLAYGROUND.call(env) を呼ぶ。アプリ側のコードは一切変えない。
#
# ブラウザで動かない所 (別プロセスでのテスト実行) だけ、下で差し替えている。
require_relative "wasm_env"
require "js"
require "json"
require "stringio"
require "uri"
require_relative "../web/server" # PLAYGROUND が定義される。サーバーの起動はしない ($PROGRAM_NAME が違うため)

module BrowserBridge
  # req は JS のオブジェクト { method, path, query, contentType, body, cookie }
  def self.handle(req)
    body = req[:body].to_s.dup.force_encoding(Encoding::UTF_8)
    content_type = req[:contentType].to_s
    cookie = req[:cookie].to_s

    env = {
      "REQUEST_METHOD" => req[:method].to_s,
      "PATH_INFO" => URI.decode_uri_component(req[:path].to_s), # Server#handle と同じく "+" は空白にしない
      "QUERY_STRING" => req[:query].to_s,
      "CONTENT_TYPE" => content_type.empty? ? nil : content_type,
      "rack.input" => StringIO.new(body)
    }
    env["HTTP_COOKIE"] = cookie unless cookie.empty?

    status, headers, res_body = PLAYGROUND.call(env)
    payload = res_body.join
    if text?(headers["content-type"])
      JSON.generate(status:, headers:, body: payload.dup.force_encoding(Encoding::UTF_8).scrub)
    else # 画像などは文字列にすると壊れるので、Base64 で JS に渡す
      JSON.generate(status:, headers:, body: [payload].pack("m0"), base64: true)
    end
  rescue Exception => e # rubocop:disable Lint/RescueException -- 原因を画面に出すため、何でも受ける
    JSON.generate(status: 500, headers: { "content-type" => "text/plain; charset=utf-8" },
                  body: "#{e.class}: #{e.message}\n\n#{Array(e.backtrace).first(20).join("\n")}")
  end

  def self.text?(type)
    type.nil? || type.empty? || type.match?(%r{\Atext/|\Aapplication/(json|javascript|xml)|svg})
  end
end

# テストの実行: サーバー版は Open3 で別プロセスの ruby を起動して run_specs.rb を走らせる。
# ブラウザでは別プロセスを起こせないので、JS 側が「もう 1 つ別の Ruby VM」を起こして
# テストを走らせ (browser/spec_runner.rb)、その結果 (JSON) をここで受け取る。
# 「このサーバーの状態を汚さない」という元の狙いは、別の VM で走らせることでそのまま守られる。
class SpecWeb
  private

  def run_specs
    result = JS.global[:rubyPlayground][:specResult]
    json = result[:json].to_s
    @wall = result[:wall].to_s.to_f
    @report = JSON.parse(json) unless json.empty?
    @run_error = result[:error].to_s unless @report
  rescue JSON::ParserError => e
    @run_error = e.message
  end
end
