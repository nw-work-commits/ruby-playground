# オリジナルシナリオ「めんどう退治」
#
# 元ネタは N.W. のポートフォリオ。「めんどうな作業が、心底嫌い。だから消す方法ばかり考えてきた」という一文と、
# 渡ってきた現場 (専門学校の C 言語、メーカーの Excel VBA、組み込みの巨大ソース、工場、職人の波形、
# 月 10 万円のしくみを自作して 0 円にした話) を、一つの建物の各フロアにした。
#
# 解き方の骨組み:
#   教室で最初の一行を唱える → 3 つの現場で「読み解く力」「測る目」「現場の感覚」を得る
#   → 組み合わせて「しくみ」を作る → サーバー室で使って請求書の亡霊を消す → 最上階へ
require_relative "../lib/adventure"

Adventure.game "めんどう退治 ── しくみで消す者", id: :mendou do
  intro "気がつくと、見覚えのある教室にいた。専門学校の、あの教室だ。\n" \
        "どうやら、これまで渡ってきた現場が、ひとつの建物になっているらしい。\n" \
        "最上階の「まだ道具が届いていない場所」を目指そう。(ヘルプ で操作方法)"
  start :school

  # ---------------------------------------------------------------- アイテム
  item :textbook, "C言語の教科書",
       "最初のページに、誰もが最初に書く一行が載っている──『Hello, World』。後ろのほうには printf の章。",
       aliases: %w[教科書 本 textbook]
  item :old_pc, "古いPC", "黒い画面でカーソルが点滅している。扉と配線でつながっているようだ。", aliases: %w[PC パソコン], fixed: true
  item :vba_book, "Excel VBA の入門書", "付箋だらけ。『チェック欄の条件 → 必要な部品』と走り書きがある。", aliases: %w[入門書 VBA vba]
  item :board, "タスクボード",
       "やることが貼り出されている。\n ・読み解く(東)  ・測る(北の奥)  ・現場を知る(北)\n ・三つがそろったら、しくみを作る\n ・サーバー室の請求書をなんとかする",
       aliases: %w[ボード 掲示板 Redmine], fixed: true
  item :parts_list, "部品リスト", "仕様書から自動で選ばれた部品の一覧。工場で待っている人がいるはずだ。", aliases: %w[リスト 部品]
  item :source, "巨大なソースコード", "何十万行もある。だが、関数をひとつずつ追っていけば、必ずどこかにたどり着く。", aliases: %w[ソース コード], fixed: true
  item :memo, "読解メモ", "『人の書いたコードも、順に追えば必ず読める』と、自分の字で書いてある。", aliases: %w[メモ 読み解く力]
  item :machine, "手漕ぎの機械", "職人が叩くたび、ハンマーの高さが上下に波打っている。速さでも、強さでもなく──。", aliases: %w[機械 ハンマー], fixed: true
  item :waveform, "職人の波形", "職人の叩き方を、高さの変化として記録したもの。新人の波形と重ねれば、ズレが点数になる。", aliases: %w[波形 測る目]
  item :field_sense, "現場の感覚", "フォークリフトの油の匂いと、ラインが止まったときの焦り。体で覚えたものだ。", aliases: %w[感覚 現場]
  item :shikumi, "自作のしくみ", "読み解いて、測って、現場に合わせて作った。外のサービスに頼らずに動く。", aliases: %w[しくみ 仕組み]

  recipe :shikumi, from: %i[memo waveform field_sense],
                   message: "読み解く力、測る目、現場の感覚。三つを組み合わせて、ひとつのしくみを組み上げた。速さや機能は欲張らない。まず、止まらないことを優先して。"

  # ---------------------------------------------------------------- 登場人物
  npc :designer, "設計担当" do
    aliases "設計", "担当"
    desc "机に仕様書の山。目の下にくまがある。"
    line "その部品リスト、工場の班長に届けてあげてください。きっと待ってます。", when: :parts_list
    line "手作業を機械に肩代わりさせるのって、気持ちいいですね。", when: :lesson_auto
    line "毎日、仕様書のチェック欄を見ながら、部品を手で選んでるんです。ミスも出るし、もう限界で……。"
    trade :vba_book, gives: :parts_list, sets: :lesson_auto,
                     message: "VBA……チェック欄を条件にして……ほんとだ、部品リストが一瞬で出てきた！ 現場はもう Excel を使ってるから、誰も新しく覚えなくていいですね。"
  end

  npc :foreman, "班長" do
    aliases "班長さん", "リーダー"
    desc "日焼けした腕に軍手。フォークリフトの横で腕を組んでいる。"
    line "工房の職人は気難しいが、悪い人じゃねえ。聞かれたことに、ちゃんと答えてやんな。", when: :factory_ok
    line "部品が分からなきゃ、ラインは一歩も動かせねえ。設計のほうで、なんとかならんもんかね。"
    trade :parts_list, gives: :field_sense, sets: :factory_ok,
                       message: "おお、これでラインが回る！ ……あんた、現場の大変さが分かってるな。こいつを持ってけ。奥の工房への扉も開けといた。"
  end

  npc :craftsman, "職人" do
    aliases "親方", "おやじ"
    desc "無口な老職人。手元の機械を、迷いなく叩き続けている。"
    line "わしの波形と、新人の波形を重ねてみい。言葉より、よっぽど伝わる。", when: :waveform
    line "わしの叩き方を教えてくれと言われるが、言葉にできん。何を測れば『同じ』と言えるんじゃろうな。分かったら、言うてみい。"
    answer %w[高さ ハンマーの高さ 高さの変化 height], gives: :waveform,
           message: "……高さ、か。そうじゃ。速さでも強さでもない、高さの変化じゃ。わしの波形を持っていけ。新人と並べれば、違いがその場で見える。"
  end

  npc :ghost, "請求書の亡霊" do
    aliases "亡霊", "請求書"
    desc "毎月届く請求書が、何枚も重なって人の形になっている。いちばん上には ¥100,000 の文字。"
    leaves_when :invoice_gone
    line "そ、それは……自作の、しくみ……？ や、やめろ……使うな……。", when: :shikumi
    line "毎月……十万円……払え……。外のサービスに頼るかぎり……わしは消えん……。"
  end

  # ---------------------------------------------------------------- 部屋
  room :school, "専門学校の教室" do
    desc "並んだ机と、ブラウン管のモニター。ここで初めて C 言語に触れた。北の扉には小さな画面がついている。"
    exits_to north: :hall
    items :textbook, :old_pc
    lock :north, password: "Hello, World", message: "扉の画面に『最初の一行を』と表示されている。何か言えば開きそうだ。",
                 unlocked: "『Hello, World』──扉が静かに開いた。すべては、ここから始まった。"
  end

  room :hall, "現場をつなぐ廊下" do
    desc "長い廊下。扉の札は、西が『設計室』、東が『組み込み』、北が『工場』。上への階段の先から、サーバーの低いうなりが聞こえる。南は教室。"
    exits_to south: :school, west: :maker, east: :embedded, north: :factory, up: :server
    items :board, :vba_book
  end

  room :maker, "メーカーの設計室" do
    desc "仕様書と図面の山。壁の時計の針だけが、やけに速く進んでいる。"
    exits_to east: :hall
    npcs :designer
  end

  room :embedded, "組み込みの迷宮" do
    desc "壁一面に、誰かが書いた巨大なソースコードが流れている。読めば読むほど面白い。机の上にメモが一枚。"
    exits_to west: :hall
    items :source, :memo
    dark!
  end

  room :factory, "工場のライン" do
    desc "止まったベルトコンベアと、エンジンの切れたフォークリフト。北の奥に工房の扉がある。"
    exits_to south: :hall, north: :workshop
    npcs :foreman
    lock :north, flag: :factory_ok, message: "工房の扉には『関係者以外立入禁止』の札。班長の許可がいりそうだ。"
  end

  room :workshop, "職人の工房" do
    desc "金属を叩くリズムが響く。職人が、手漕ぎの機械を黙々と叩いている。"
    exits_to south: :factory
    items :machine
    npcs :craftsman
  end

  room :server, "サーバー室" do
    desc "低くうなるサーバーラック。10 本のコンテナが静かに動いている。上へ続く階段がある。"
    exits_to down: :hall, up: :frontier
    npcs :ghost
    lock :up, flag: :invoice_gone, message: "請求書の亡霊が、階段の前に立ちふさがっている。『払え……』"
  end

  room :frontier, "まだ道具が届いていない場所" do
    desc "見渡すかぎりの手作業。紙の伝票、手打ちの表、毎日くり返される同じ入力。だが、もう怖くはない。"
    exits_to down: :server
  end

  # ---------------------------------------------------------------- 使ったとき
  on_use :textbook do |state|
    next "教科書をめくった。……懐かしい。" if state.flag?(:light)

    state.flags << :light
    "printf の章を開いた。分からなければ、値を出してみればいい。闇の中に、変数の値が浮かび上がりはじめた。"
  end

  on_use :shikumi do |state|
    if state.room == :server && !state.flag?(:invoice_gone)
      state.flags << :invoice_gone
      "しくみを動かした。外のサービスへの依存を断つ。\n¥100,000 …… ¥10,000 …… ¥0。\n請求書の亡霊は、音もなく消えた。以来、毎月の請求書は来ていない。"
    else
      "しくみは静かに動いている。止まる気配はない。"
    end
  end

  goal "めんどうな作業が、心底嫌いだ。だから、また一つ消しにいく。\n── あなたは「しくみで消す者」になった。" do |state|
    state.room == :frontier
  end
end
