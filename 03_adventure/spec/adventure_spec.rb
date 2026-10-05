require_relative "../../02_minispec/lib/minispec"
require_relative "../games/castle"
require_relative "../games/village"
require_relative "../games/mendou"
require_relative "../lib/adventure/script"
require "stringio"
require "tmpdir"

module PlayHelper
  def play(*commands, game: :castle, save_path: File.join(Dir.tmpdir, "adventure_spec.sav"))
    world = Adventure.registry.fetch(game)
    engine = Adventure::Engine.new(world, input: StringIO.new(commands.join("\n")), output:, save_path:)
    engine.run
    engine
  end
end

describe Adventure::Parser do
  def parse(s) = Adventure::Parser.parse(s)

  it "方角だけで移動コマンドになる" do
    expect(parse("北")).to eq Adventure::Command.new(verb: :go, target: :north)
    expect(parse("n")).to eq Adventure::Command.new(verb: :go, target: :north)
  end

  it "英語・日本語の語順どちらも解釈できる" do
    expect(parse("取る 鍵")).to eq Adventure::Command.new(verb: :take, target: "鍵")
    expect(parse("鍵を取る")).to eq Adventure::Command.new(verb: :take, target: "鍵")
    expect(parse("take key")).to eq Adventure::Command.new(verb: :take, target: "key")
    expect(parse("ルビーと言う")).to eq Adventure::Command.new(verb: :say, target: "ルビー")
  end

  it "助詞が複数あっても最後の動詞を取り出す" do
    expect(parse("門番にパンを渡す")).to eq Adventure::Command.new(verb: :give, target: "門番にパン")
    expect(parse("村長と話す")).to eq Adventure::Command.new(verb: :talk, target: "村長")
    expect(parse("話す")).to eq Adventure::Command.new(verb: :talk, target: nil)
  end

  it "知らない単語は unknown" do
    expect(parse("踊る").verb).to eq :unknown
    expect(parse("   ")).to be_nil
  end
end

describe Adventure::Engine do
  include PlayHelper
  let(:output) { StringIO.new }

  it "鍵がないと書庫に入れない" do
    engine = play("北", "北", "東")
    expect(engine.state.room).to eq :hall
    expect(output.string).to include("鍵がかかっている")
  end

  it "暗い部屋では明かりがないとアイテムを取れない" do
    engine = play("北", "西", "鍵を取る", "東", "北", "鍵を使う", "東", "取る 古文書")
    expect(engine.state.room).to eq :library
    expect(engine.state.has?(:note)).to eq false
    expect(output.string).to include("真っ暗")
  end

  it "最短手順でクリアできる" do
    engine = play(*%w[北 ランプを取る ランプを使う 西 鍵を取る 東 北 鍵を使う 東 古文書を調べる 西 ルビーと言う 下 王冠を取る 上 南 南])
    expect(output.string).to include("伝説の冒険者", "17 ターンでクリア")
    expect(engine.state.has?(:crown)).to eq true
  end

  it "Marshal でセーブ/ロードできる" do
    path = File.join(Dir.tmpdir, "adventure_spec_#{rand(1 << 32)}.sav")
    engine = play("北", "ランプを取る", "セーブ", "南", "ロード", save_path: path)
    expect(engine.state.room).to eq :courtyard
    expect(engine.state.has?(:lamp)).to eq true
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  it "存在しない部屋への出口は定義時にエラー" do
    expect { Adventure.game("broken") { start :a; room(:a) { exits_to north: :nowhere } } }
      .to raise_error(ArgumentError, /nowhere/)
  end
end

describe "NPC" do
  include PlayHelper
  let(:output) { StringIO.new }

  it "状況によってセリフが変わる" do
    play("北", "話す", "西", "鍵を取る", "東", "亡霊と話す")
    expect(output.string).to include("西の物置に置き忘れた", "灯りなしでは何も読めぬ")
  end

  it "調べると NPC の説明が出る" do
    play("北", "亡霊を調べる")
    expect(output.string).to include("半透明の鎧姿")
  end

  it "when: はキーワードだが binding 経由で受け取れる" do
    npc = Adventure::Npc.new(:x, "X")
    npc.line "a", when: :flag
    expect(npc.lines.first.condition).to eq :flag
  end

  describe "星降る村" do
    it "会話でアイテムをもらえるのは一度だけ" do
      engine = play("話す", "話す", game: :village)
      expect(engine.state.inventory).to eq [:lantern]
      expect(engine.state.flag?(:quest)).to eq true
    end

    it "交換 (銅貨 → パン) と、相手の指定" do
      engine = play("西", "銅貨を取る", "東", "東", "パン屋のおかみに銅貨を渡す", game: :village)
      expect(engine.state.inventory).to eq [:bread]
      expect(output.string).to include("焼きたてだよ")
    end

    it "欲しがっていない物は受け取らない" do
      play("話す", "北", "ランタンを渡す", game: :village)
      expect(output.string).to include("門番 は ランタン を受け取らなかった")
    end

    it "フラグで開く通路: 門番にパンを渡すまで森へ行けない" do
      engine = play("北", "北", game: :village)
      expect(engine.state.room).to eq :bridge
      expect(output.string).to include("通せんぼ")
    end

    it "最短手順でクリアできる" do
      steps = %w[話す 西 銅貨を取る 東 東 銅貨を渡す 西 北 パンを門番に渡す 北 ランタンを使う かけらを取る 南 南]
      engine = play(*steps, game: :village)
      expect(output.string).to include("再び星が輝いた", "14 ターンでクリア")
      expect(engine.state.has?(:star)).to eq true
    end
  end

  it "未定義の NPC を部屋に置くと定義時にエラー" do
    expect { Adventure.game("broken2") { start :a; room(:a) { npcs :nobody } } }
      .to raise_error(ArgumentError, /nobody/)
  end
end

describe "めんどう退治 (ポートフォリオ由来のシナリオ)" do
  include PlayHelper
  let(:output) { StringIO.new }

  SOLUTION = %w[教科書を取る Hello,Worldと言う 北 入門書を取る 西 入門書を渡す 東 東 教科書を使う メモを取る 西 北
                部品リストを渡す 北 高さと言う 南 南 しくみを作る 上 しくみを使う 上].freeze

  it "最短手順でクリアできる" do
    engine = play(*SOLUTION, game: :mendou)
    expect(output.string).to include("しくみで消す者", "#{SOLUTION.size} ターンでクリア")
    expect(engine.state.room).to eq :frontier
  end

  it "合言葉は全角・大文字小文字・句読点の違いを吸収する" do
    engine = play("ＨＥＬＬＯ　ＷＯＲＬＤ！と言う", "北", game: :mendou)
    expect(engine.state.room).to eq :hall
  end

  it "置物は持ち運べないが、調べられる" do
    engine = play("古いPCを取る", "古いPCを調べる", game: :mendou)
    expect(output.string).to include("古いPC は持ち運べない", "カーソルが点滅")
    expect(engine.state.inventory).to eq []
  end

  it "材料が足りないと、足りない数だけ教えてくれる" do
    play("教科書を取る", "しくみを作る", game: :mendou)
    expect(output.string).to include("材料があと 3 つ足りない")
  end

  it "職人の問いかけには、違う答えでは何も起きず、正解で波形をもらえる (二度はもらえない)" do
    world = Adventure.registry.fetch(:mendou)
    state = world.new_state.tap { _1.room = :workshop }
    engine = Adventure::Engine.new(world, input: StringIO.new("速さと言う\nたかさと言う\n高さと言う\n高さと言う\n"), output:, state:)
    engine.run
    expect(engine.state.inventory).to eq [:waveform]
    expect(output.string).to include("声が響いただけ", "もう聞いた")
  end

  it "請求書の亡霊は、しくみを使うと姿を消す (leaves_when)" do
    world = Adventure.registry.fetch(:mendou)
    state = world.new_state.tap { _1.room = :server; _1.inventory << :shikumi }
    engine = Adventure::Engine.new(world, input: StringIO.new("しくみを使う\n見る\n"), output:, state:)
    engine.run
    expect(output.string).to include("¥0")
    expect(output.string.split("¥0").last).not_to include("請求書の亡霊 がいる")
  end
end

describe Adventure::Script do
  def problems(source) = Adventure::Script.check(source).map(&:to_s)

  it "DSL だけのシナリオは通る" do
    world = Adventure::Script.build(<<~RUBY)
      game "t", id: :t do
        start :a
        item :lamp, "ランプ"
        room(:a) { items :lamp }
        on_use(:lamp) { |s| s.flags << :light; "灯った" }
        goal("ok") { |s| s.flag?(:light) && !s.has?(:x) }
      end
    RUBY
    expect(world.id).to eq :t
    expect(Adventure.registry).not_to include(:t) # build は登録しない
  end

  it "定数・system・バッククォート・代入・式の埋め込みは行番号つきで拒否する" do
    found = problems(<<~'RUBY')
      game "x", id: :x do
        File.delete("a")
        system("calc")
        `dir`
        a = 1
        "#{1 + 1}"
      end
    RUBY
    expect(found).to include("2 行目: 定数 File は使えません", "3 行目: メソッド system は使えません",
                             "4 行目: コマンド実行 (`...`) は使えません", "5 行目: 変数への代入 は使えません",
                             "6 行目: 文字列への式の埋め込み \#{...} は使えません")
  end

  it "state 経由でも危ないメソッドは呼べない" do
    expect(problems(%(game "x", id: :x do\n on_use(:a) { |s| s.send(:exit) }\nend))).to include("2 行目: メソッド send は使えません")
    expect(problems(%(game "x", id: :x do\n on_use(:a) { |s| s.instance_eval("1") }\nend))).to include("2 行目: メソッド instance_eval は使えません")
  end

  it "game 以外を書くとエラー" do
    expect(problems(%(start :a))).to include("1 行目: ファイルの中身は game \"タイトル\", id: :xxx do ... end ひとつだけにしてください")
  end

  it "評価して初めて分かる誤りも、行番号つきで返す" do
    error = (Adventure::Script.build(%(game "x", id: :x do\n start :a\n room(:a) { exits_to north: :nowhere }\nend)) rescue $!)
    expect(error).to be_a(Adventure::Script::Invalid)
    expect(error.message).to include("nowhere")
  end

  it "組み込みと同じ id は使えない" do
    expect { Adventure::Script.build(%(game "x", id: :castle do\n start :a\n room(:a) {}\nend)) }
      .to raise_error(Adventure::Script::Invalid, /組み込み/)
  end
end
