# Ruby Playground: 4 つのアプリを 1 つのサーバーで公開する
#   起動: ruby web/server.rb  →  http://127.0.0.1:3000
#
# URLMap でパスごとにアプリを振り分ける。どのアプリも call(env) を持つだけの Rack 方式なので、
# 「アプリ」「ミドルウェア」「URLMap」を自由に組み合わせられる。
require_relative "../04_miniweb/lib/miniweb"
require_relative "../04_miniweb/app"
require_relative "apps/portal"
require_relative "apps/kakeibo_web"
require_relative "apps/spec_web"
require_relative "apps/adventure_web"

not_found = ->(_env) { [404, { "content-type" => "text/plain; charset=utf-8" }, ["404 Not Found"]] }

PLAYGROUND = MiniWeb::URLMap.new(
  "/assets"    => MiniWeb::Middleware::Static.new(not_found, root: File.join(__dir__, "public")),
  "/kakeibo"   => KakeiboWeb,
  "/spec"      => SpecWeb,
  "/adventure" => AdventureWeb,
  "/todo"      => TodoApp,
  "/"          => Portal
)

if $PROGRAM_NAME == __FILE__
  MiniWeb.run!(MiniWeb::Middleware::Logger.new(PLAYGROUND), port: ENV.fetch("PORT", 3000).to_i)
end
