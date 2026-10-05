# サンプルゲーム「星降る村」 — NPC との会話と交換がカギになるシナリオ
require_relative "../lib/adventure"

Adventure.game "星降る村", id: :village do
  intro "山あいの小さな村。昨夜、村を守る「守り星」が砕けて北の森に落ちたという。\n" \
        "村人の話を聞き、星のかけらを広場に持ち帰ろう。(ヘルプ で操作方法)"
  start :square

  item :coin,    "銅貨",         "古びた銅貨。何か一つくらいは買えそうだ。", aliases: %w[コイン お金 coin]
  item :bread,   "焼きたてパン", "香ばしい匂いがする。お腹を空かせた人なら喜びそうだ。", aliases: %w[パン bread]
  item :lantern, "ランタン",     "村長から借りたランタン。使えば明かりが灯る。", aliases: %w[lantern 灯り]
  item :star,    "星のかけら",   "手のひらで青白く瞬いている。ほんのり温かい。", aliases: %w[かけら 星 star]

  npc :elder, "村長" do
    aliases "長老", "elder"
    desc "白いひげの老人。心配そうに北の空を見上げている。"
    line "おお…それこそ守り星のかけら！ 本当にありがとう、旅の方。", when: :star
    line "北のつり橋を越えた先が星の森じゃ。門番のやつ、朝から何も食べとらんと騒いでおったが…", when: :quest
    line "守り星が砕けてしまったのじゃ。北の森に落ちたかけらを探してきてくれんか。森は暗い、このランタンを持っていきなされ。",
         sets: :quest, gives: :lantern
  end

  npc :baker, "パン屋のおかみ" do
    aliases "おかみ", "パン屋", "baker"
    desc "粉まみれのエプロンをつけた陽気な女性。"
    line "毎度あり！ 門番さんによろしくね。", when: :bread
    line "いらっしゃい！ 焼きたてのパンは銅貨 1 枚だよ。"
    trade :coin, gives: :bread, message: "はいよ、焼きたてだよ！"
  end

  npc :guard, "門番" do
    aliases "番兵", "guard"
    desc "大柄な門番。お腹がぐうぐう鳴っている。"
    line "腹がふくれたら元気が出た。森へ行くなら気をつけてな。", when: :guard_ok
    line "ここから先は星の森だ。だが腹が減って…何か食わせてくれたら通してやってもいいぞ。"
    trade :bread, sets: :guard_ok, message: "うまい！ 恩に着る。よし、通っていいぞ。"
  end

  room :square, "村の広場" do
    desc "石畳の広場。北につり橋へ続く道、東にパン屋、西に古井戸がある。"
    exits_to north: :bridge, east: :bakery, west: :well
    npcs :elder
  end

  room :well, "古井戸" do
    desc "苔むした古井戸。縁の石の隙間に何かが光っている。"
    exits_to east: :square
    items :coin
  end

  room :bakery, "パン屋" do
    desc "パンの焼ける香りでいっぱいの店。棚にずらりとパンが並ぶ。"
    exits_to west: :square
    npcs :baker
  end

  room :bridge, "つり橋" do
    desc "谷にかかる古いつり橋。向こう岸は深い森だ。"
    exits_to south: :square, north: :forest
    npcs :guard
    lock :north, flag: :guard_ok, message: "門番が腕を組んで通せんぼしている。"
  end

  room :forest, "星の森" do
    desc "背の高い木々に囲まれた森。足元の草むらで何かが青白く光っている。"
    exits_to south: :bridge
    items :star
    dark!
  end

  on_use :lantern do |state|
    next "ランタンはもう灯っている。" if state.flag?(:light)

    state.flags << :light
    "ランタンに火を入れた。やわらかな光が広がる。"
  end

  goal "🌟 守り星のかけらが戻り、村の空に再び星が輝いた！" do |state|
    state.room == :square && state.has?(:star)
  end
end
