# サンプルゲーム「古城の謎」 — 世界はすべて DSL で宣言する
require_relative "../lib/adventure"

Adventure.game "古城の謎", id: :castle do
  intro "霧の中に古い城がそびえている。伝説の「紅玉の王冠」がこの城のどこかに眠っているという。\n" \
        "王冠を手に入れて城門まで戻ってこよう。(ヘルプ で操作方法)"
  start :gate

  item :lamp,  "古いランプ", "油はまだ残っている。使えば火が灯りそうだ。", aliases: %w[ランプ lamp]
  item :key,   "錆びた鍵",   "東の扉の紋章と同じ模様が刻まれている。", aliases: %w[鍵 かぎ key]
  item :note,  "古文書",     "かすれた文字でこう書かれている──「地の底への扉は、宝石の名を唱えれば開く。その名は『ルビー』」",
                             aliases: %w[文書 本 note]
  item :crown, "紅玉の王冠", "真紅の宝石がはめ込まれた王冠。まばゆく輝いている。", aliases: %w[王冠 crown]

  room :gate, "城門" do
    desc "崩れかけた城門の前に立っている。北に中庭が見える。"
    exits_to north: :courtyard
  end

  npc :ghost, "騎士の亡霊" do
    aliases "亡霊", "騎士", "ghost"
    desc "半透明の鎧姿。どこか寂しげにこちらを見ている。"
    line "その王冠…ついに見つけたのだな。さあ、城門から外へ持ち出してくれ。", when: :crown
    line "書庫は闇に包まれている。灯りなしでは何も読めぬぞ。", when: :key
    line "わしはこの城を守っていた騎士だ。東の扉の鍵は、西の物置に置き忘れたままだ…", sets: :heard_ghost
  end

  room :courtyard, "中庭" do
    desc "雑草の生い茂る中庭。北に大広間、西に小さな物置小屋がある。"
    exits_to south: :gate, north: :hall, west: :shed
    items :lamp
    npcs :ghost
  end

  room :shed, "物置小屋" do
    desc "埃っぽい物置。壊れた樽や農具が散らばっている。"
    exits_to east: :courtyard
    items :key
  end

  room :hall, "大広間" do
    desc "天井の高い大広間。東に紋章の刻まれた扉、床の中央には円形の石板がある。"
    exits_to south: :courtyard, east: :library, down: :crypt
    lock :east, with: :key, message: "扉には鍵がかかっている。",
                unlocked: "鍵を差し込んで回すと、ガチャリと音を立てて扉が開いた。"
    lock :down, password: "ルビー", message: "石板は重く、びくともしない。何か仕掛けがありそうだ。",
                unlocked: "石板が低い音を立てて沈み、地下への階段が現れた！"
  end

  room :library, "書庫" do
    desc "本棚が並ぶ書庫。机の上に古文書が置かれている。"
    exits_to west: :hall
    items :note
    dark!
  end

  room :crypt, "地下墓所" do
    desc "ひんやりとした地下墓所。祭壇の上で何かが光っている。"
    exits_to up: :hall
    items :crown
    dark!
  end

  on_use :lamp do |state|
    if state.flag?(:light)
      "ランプはもう灯っている。"
    else
      state.flags << :light
      "ランプに火を灯した。周りが明るくなった。"
    end
  end

  goal "🎉 王冠を手に城を脱出した！ あなたは伝説の冒険者となった。" do |state|
    state.room == :gate && state.has?(:crown)
  end
end
