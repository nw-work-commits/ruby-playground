# テキストアドベンチャーの Web 版 + シナリオエディタ。
# コマンドを受け取るたびに Engine を「その時点の状態」で作り直し、1 コマンドだけ実行する。
# ゲームの状態はサーバーのメモリに置き、ブラウザのセッションには ID だけを持たせる。
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "playground_app"
require_relative "../../03_adventure/lib/adventure/script"
Dir[File.expand_path("../../03_adventure/games/*.rb", __dir__)].sort.each { require _1 }

class AdventureWeb < PlaygroundApp
  use MiniWeb::Middleware::Session, secret: SECRET, key: "adventure.session"

  GAMES_DIR = File.expand_path("../../03_adventure/games", __dir__)
  set :custom_dir, ENV.fetch("ADVENTURE_CUSTOM_DIR") { File.join(GAMES_DIR, "custom") }
  Adventure::Script.load_dir(settings[:custom_dir])

  # world は登録済みのゲームとは限らない (エディタの試し遊びは登録しない) ので、オブジェクトごと持つ
  Game = Struct.new(:world, :state, :log, :finished, :draft, keyword_init: true)
  GAMES = {}
  DRAFTS = {}
  LOCK = Mutex.new
  MAX_GAMES = 200
  MAX_LOG = 400

  BUILTIN_FILES = { castle: "castle.rb", village: "village.rb", mendou: "mendou.rb" }.freeze

  TEMPLATE = <<~'RUBY'
    # 自分だけのシナリオを書いてみよう。使えるのは DSL の命令だけです。
    game "はじめての冒険", id: :my_first do
      intro "小さな部屋で目を覚ました。外に出よう。"
      start :room

      item :key, "小さな鍵", "扉の鍵穴にぴったり合いそうだ。", aliases: %w[鍵]
      item :note, "メモ", "『合言葉はひらけごま』", fixed: true

      npc :cat, "ねこ" do
        line "にゃあ (鍵なら机の下だよ、と言っている気がする)"
      end

      room :room, "小さな部屋" do
        desc "机とベッドだけの部屋。北に扉、壁にメモが貼ってある。"
        exits_to north: :hall
        items :key, :note
        npcs :cat
        lock :north, with: :key, message: "扉には鍵がかかっている。", unlocked: "カチャリ。扉が開いた。"
      end

      room :hall, "廊下" do
        desc "まっすぐな廊下。北に大きな門がある。"
        exits_to south: :room, north: :outside
        lock :north, password: "ひらけごま", message: "門はびくともしない。", unlocked: "門がゆっくりと開いた！"
      end

      room :outside, "外" do
        desc "まぶしい日差し。自由だ。"
        exits_to south: :hall
      end

      goal "外に出られた！" do |state|
        state.room == :outside
      end
    end
  RUBY

  helpers do
    def current_game = LOCK.synchronize { GAMES[session["game"]] }
    def save_path = File.join(Dir.tmpdir, "adventure_web_#{session['game']}.sav")
    def custom_dir = self.class.settings[:custom_dir]

    def engine_for(game, output = StringIO.new)
      Adventure::Engine.new(game.world, input: StringIO.new, output:, state: game.state, save_path:)
    end

    def custom_ids = Dir[File.join(custom_dir, "*.adv")].map { File.basename(_1, ".adv").to_sym }

    # 組み込みのシナリオをエディタ用の DSL に直す (Adventure.game → game、require は消す)
    def editable_source(id)
      if custom_ids.include?(id)
        File.read(File.join(custom_dir, "#{id}.adv"), encoding: "UTF-8")
      elsif (file = BUILTIN_FILES[id])
        File.read(File.join(GAMES_DIR, file), encoding: "UTF-8")
            .gsub(/^require_relative .*\n/, "")
            .sub(/Adventure\.game (.+?), id: :(\w+)/) { "game #{$1}, id: :my_#{$2}" }
      end
    end
  end

  get "/" do
    @title = "アドベンチャー"
    @worlds = Adventure.registry.values
    @custom = custom_ids
    @game = current_game
    erb :"adventure/index"
  end

  post "/new" do
    world = Adventure.registry[params["world"].to_s.to_sym] or halt 404, "そのゲームはありません"
    start_game(world)
  end

  # いま遊んでいるゲームを最初から (エディタの試し遊びも含む)
  post "/restart" do
    game = current_game or redirect("/")
    start_game(game.world, draft: game.draft)
  end

  get "/play" do
    @game = current_game or redirect("/")
    @title = @game.world.title
    @engine = engine_for(@game)
    erb :"adventure/play"
  end

  post "/play" do
    game = current_game or redirect("/")
    text = params["command"].to_s.strip[0, 60]
    redirect "/play" if text.empty? || game.finished

    out = StringIO.new
    engine = engine_for(game, out)
    game.log << [:cmd, text]
    case Adventure::Parser.parse(text)
    in nil then nil
    in command
      result = engine.execute(command)
      game.state = engine.state # ロードすると state が丸ごと入れ替わる
      game.finished = true if result == :quit || engine.check_goal
    end
    game.log.concat(out.string.lines.map { [:out, _1.chomp] })
    game.log.shift while game.log.size > MAX_LOG
    redirect "/play#end"
  end

  # ---------------------------------------------------------------- エディタ
  get "/editor" do
    @title = "シナリオエディタ"
    @source = params["from"] ? editable_source(params["from"].to_s.to_sym) : LOCK.synchronize { DRAFTS[session["draft"]] }
    @source ||= TEMPLATE
    erb :"adventure/editor"
  end

  post "/editor" do
    @title = "シナリオエディタ"
    @source = params["source"].to_s.gsub("\r\n", "\n")
    begin
      world = Adventure::Script.build(@source)
    rescue Adventure::Script::Invalid => e
      @problems = e.problems
      next erb(:"adventure/editor")
    end

    case params["action"]
    when "play"
      # 下書きはサーバー側に置く (Cookie は 4KB までなので本文は入らない)
      draft_id = session["draft"] ||= SecureRandom.hex(16)
      LOCK.synchronize { DRAFTS[draft_id] = @source }
      start_game(world, draft: true)
    when "save"
      FileUtils.mkdir_p(custom_dir)
      File.write(File.join(custom_dir, "#{world.id}.adv"), @source)
      Adventure.registry[world.id] = world
      flash[:notice] = "「#{world.title}」を保存しました (games/custom/#{world.id}.adv)"
      redirect "/"
    else
      @checked = world
      erb :"adventure/editor"
    end
  end

  post "/editor/delete" do
    id = params["id"].to_s
    halt 400, "不正な id" unless id.match?(/\A\w+\z/) && custom_ids.include?(id.to_sym)
    File.delete(File.join(custom_dir, "#{id}.adv"))
    Adventure.registry.delete(id.to_sym)
    flash[:notice] = "#{id} を削除しました"
    redirect "/"
  end

  private

  def start_game(world, draft: false)
    id = SecureRandom.hex(16)
    out = StringIO.new
    engine = Adventure::Engine.new(world, input: StringIO.new, output: out)
    engine.intro
    game = Game.new(world:, state: engine.state, log: out.string.lines.map { [:out, _1.chomp] }, finished: false, draft:)
    LOCK.synchronize do
      GAMES.delete(GAMES.keys.first) while GAMES.size >= MAX_GAMES # 古いものから捨てる
      GAMES[id] = game
    end
    session["game"] = id
    redirect "/play"
  end
end
