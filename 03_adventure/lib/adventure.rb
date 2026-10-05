# Adventure - DSL で書けるテキストアドベンチャーエンジン
#
# 使っている Ruby の仕組み:
#   - DSL (instance_eval) でゲームの世界を宣言的に書く
#   - パターンマッチ (case/in) でコマンドを解釈する。Data は deconstruct_keys に対応している
#   - Marshal でゲーム状態をそのままバイナリ保存 (セーブ/ロード)
#   - 「世界の定義 (Proc を含む)」と「状態 (純粋なデータ)」を分けることで Marshal 可能にしている

require "set"

module Adventure
  Item    = Data.define(:id, :name, :desc, :aliases, :fixed)
  Lock    = Data.define(:item, :password, :flag, :locked_msg, :unlock_msg)
  Command = Data.define(:verb, :target)
  Line    = Data.define(:text, :condition, :sets, :gives)
  Trade   = Data.define(:wants, :gives, :sets, :message)
  Answer  = Data.define(:words, :sets, :gives, :message)
  Recipe  = Data.define(:result, :from, :message)

  # 合言葉や答えの表記ゆれを吸収する: 「Ｈｅｌｌｏ， ｗｏｒｌｄ！」も "helloworld" になる
  def self.normalize(text) = text.to_s.unicode_normalize(:nfkc).downcase.gsub(/[\s、。,.!?「」『』"'・ー-]/, "")

  # 登場人物。会話は「条件付きのセリフ」を上から順に試し、どれも当てはまらなければ条件なしのセリフを話す。
  class Npc
    attr_reader :id, :lines, :trades, :answers

    def initialize(id, name)
      @id = id
      @name = name
      @desc = ""
      @aliases = []
      @lines = []
      @trades = {}
      @answers = []
    end

    # 問いかけへの答え: answer "高さ", gives: :waveform, message: "..." — 「高さと言う」で正解
    def answer(words, sets: nil, gives: nil, message:)
      @answers << Answer.new(words: Array(words).map { Adventure.normalize(_1) }, sets:, gives:, message:)
    end

    def answer_for(said) = answers.find { _1.words.include?(Adventure.normalize(said)) }

    # leaves_when :invoice_gone — そのフラグが立ったら姿を消す
    def leaves_when(flag) = @leave_flag = flag
    def present?(state) = !(@leave_flag && state.flag?(@leave_flag))

    # --- NPC の DSL ---
    def name(value = nil) = value ? @name = value : @name
    def desc(value = nil) = value ? @desc = value : @desc
    def aliases(*names) = names.empty? ? @aliases : @aliases.concat(names)

    # line "やあ", when: :quest (フラグ名) または when: ->(state) { ... }
    # sets: 話したあとに立てるフラグ / gives: 渡すアイテム (一度だけ)
    def line(text, when: nil, sets: nil, gives: nil)
      @lines << Line.new(text:, condition: binding.local_variable_get(:when), sets:, gives:)
    end

    # trade :coin, gives: :bread, message: "..." — 「銅貨を渡す」でパンと交換
    def trade(wants, gives: nil, sets: nil, message:)
      @trades[wants] = Trade.new(wants:, gives:, sets:, message:)
    end

    def line_for(state)
      conditional, fallback = lines.partition(&:condition)
      conditional.find { met?(_1.condition, state) } || fallback.first
    end

    def names = [name, id.to_s, *aliases]

    private

    def met?(condition, state)
      case condition
      in Symbol then state.flag?(condition) || state.has?(condition)
      in Proc then condition.call(state)
      end
    end
  end

  class Room
    attr_reader :id, :exits, :locks, :initial_items, :npc_ids

    def initialize(id, name)
      @id = id
      @name = name
      @desc = ""
      @exits = {}
      @locks = {}
      @initial_items = []
      @npc_ids = []
      @dark = false
    end

    # --- 部屋の DSL (room ブロックの中で使う) ---
    def name(value = nil) = value ? @name = value : @name
    def desc(value = nil) = value ? @desc = value : @desc
    def exits_to(**dirs) = @exits.merge!(dirs)
    def items(*ids) = @initial_items.concat(ids)
    def npcs(*ids) = @npc_ids.concat(ids)
    def dark! = @dark = true
    def dark? = @dark

    # with: アイテムを使うと開く / password: 言うと開く / flag: そのフラグが立てば開く
    def lock(dir, with: nil, password: nil, flag: nil, message:, unlocked: "")
      @locks[dir] = Lock.new(item: with, password:, flag:, locked_msg: message, unlock_msg: unlocked)
    end
  end

  # セーブ対象になる「状態」。Proc を持たないので Marshal.dump できる。
  State = Struct.new(:room, :inventory, :room_items, :unlocked, :flags, :turns) do
    def has?(item) = inventory.include?(item)
    def flag?(name) = flags.include?(name)
  end

  # ゲーム世界の定義 (DSL のトップレベル)
  class World
    attr_reader :id, :title, :rooms, :items, :npcs, :start_room, :intro_text, :goal_text, :goal_cond, :use_hooks

    def initialize(id, title)
      @id = id
      @title = title
      @rooms = {}
      @items = {}
      @npcs = {}
      @use_hooks = {}
      @recipes = {}
      @intro_text = ""
      @goal_text = ""
      @goal_cond = ->(_state) { false }
    end

    attr_reader :recipes

    def npc(id, name = id.to_s, &block)
      (@npcs[id] = Npc.new(id, name)).instance_eval(&block)
    end

    def intro(text) = @intro_text = text
    def start(room) = @start_room = room

    # fixed: true は持ち運べない置物 (調べることはできる)
    def item(id, name, desc = "", aliases: [], fixed: false)
      @items[id] = Item.new(id:, name:, desc:, aliases:, fixed:)
    end

    # 材料をそろえて「作る」: recipe :shikumi, from: %i[memo waveform], message: "..."
    def recipe(result, from:, message:)
      @recipes[result] = Recipe.new(result:, from:, message:)
    end

    def room(id, name = id.to_s, &block)
      (@rooms[id] = Room.new(id, name)).instance_eval(&block)
    end

    # use :lamp do |state| ... ; "メッセージ" end
    def on_use(item, &block) = @use_hooks[item] = block

    def goal(text, &cond)
      @goal_text = text
      @goal_cond = cond
    end

    def new_state
      State.new(
        room: start_room,
        inventory: [],
        room_items: rooms.transform_values { _1.initial_items.dup },
        unlocked: Set.new,
        flags: Set.new,
        turns: 0
      )
    end

    def validate!
      rooms.each_value do |room|
        room.exits.each do |dir, dest|
          raise ArgumentError, "#{room.id}: #{dir} の行き先 #{dest} が存在しません" unless rooms.key?(dest)
        end
        unknown = room.initial_items - items.keys
        raise ArgumentError, "#{room.id}: 未定義のアイテム #{unknown}" if unknown.any?
        unknown = room.npc_ids - npcs.keys
        raise ArgumentError, "#{room.id}: 未定義の NPC #{unknown}" if unknown.any?
      end
      npcs.each_value do |npc|
        given = npc.lines.filter_map(&:gives) + npc.answers.filter_map(&:gives) +
                npc.trades.values.flat_map { [_1.wants, _1.gives].compact }
        unknown = given - items.keys
        raise ArgumentError, "#{npc.id}: 未定義のアイテム #{unknown}" if unknown.any?
      end
      recipes.each_value do |recipe|
        unknown = [recipe.result, *recipe.from] - items.keys
        raise ArgumentError, "recipe #{recipe.result}: 未定義のアイテム #{unknown}" if unknown.any?
      end
      unknown = use_hooks.keys - items.keys
      raise ArgumentError, "on_use: 未定義のアイテム #{unknown}" if unknown.any?
      raise ArgumentError, "start が未定義です" unless rooms.key?(start_room)
      self
    end
  end

  # 定義したゲームはここに登録される (bin/play のメニューに出る)
  def self.registry = @registry ||= {}

  def self.game(title, id: title, &block)
    World.new(id.to_sym, title).tap { _1.instance_eval(&block) }.validate!.tap { registry[_1.id] = _1 }
  end

  # ------------------------------------------------------------------ Parser
  module Parser
    DIRECTIONS = {
      north: %w[北 きた n north], south: %w[南 みなみ s south],
      east: %w[東 ひがし e east], west: %w[西 にし w west],
      up: %w[上 うえ u up], down: %w[下 した d down]
    }.flat_map { |dir, words| words.map { [_1, dir] } }.to_h.freeze

    VERBS = {
      go: %w[行く いく go], look: %w[見る みる look l], take: %w[取る とる 拾う take get],
      drop: %w[置く おく drop], use: %w[使う つかう use], examine: %w[調べる しらべる examine x],
      say: %w[言う いう say], inventory: %w[持ち物 もちもの inventory inv i],
      talk: %w[話す はなす 話しかける talk], give: %w[渡す わたす あげる give],
      build: %w[作る つくる 組む 組み立てる build make],
      save: %w[セーブ save], load: %w[ロード load], help: %w[ヘルプ help h ?],
      quit: %w[終了 やめる quit q exit]
    }.flat_map { |verb, words| words.map { [_1, verb] } }.to_h.freeze

    module_function

    # "取る 鍵" / "鍵を取る" / "take key" / "北" のどれでも Command にする
    # 動詞は最後の助詞の後ろ: 「門番にパンを渡す」→ 動詞「渡す」、対象「門番にパン」
    def parse(line)
      words =
        case line.strip
        in /\A(.+)(?:を|に|と)(\S+?)\z/ then [$2, $1]  # 「鍵を使う」「北に行く」「ルビーと言う」
        in String => s then s.split(/[\s　]+/, 2)
        end

      case words
      in [] then nil
      in [w] if DIRECTIONS.key?(w.downcase) then Command.new(verb: :go, target: DIRECTIONS[w.downcase])
      in [w, *rest] if VERBS.key?(w.downcase)
        verb = VERBS[w.downcase]
        target = rest.first
        target = DIRECTIONS.fetch(target.downcase, target) if verb == :go && target
        Command.new(verb:, target:)
      in [w, *] then Command.new(verb: :unknown, target: w)
      end
    end
  end

  # ------------------------------------------------------------------ Engine
  class Engine
    DIR_LABELS = { north: "北", south: "南", east: "東", west: "西", up: "上", down: "下" }.freeze

    attr_reader :state

    # state: を渡すと続きから (Web 版はリクエストごとに Engine を作り直す)
    def initialize(world, input: $stdin, output: $stdout, save_path: "adventure.sav", state: nil)
      @world = world
      @in = input
      @out = output
      @save_path = save_path
      @state = state || world.new_state
    end

    def run
      intro
      loop do
        @out.print "\n> "
        line = @in.gets or break
        command = Parser.parse(line) or next
        break if execute(command) == :quit
        break if check_goal
      end
    end

    def intro
      say "=== #{@world.title} ===", @world.intro_text, ""
      look
    end

    def cleared? = @world.goal_cond.call(state)

    # クリアしていればメッセージを出して true
    def check_goal
      return false unless cleared?

      say "", @world.goal_text, "(#{state.turns} ターンでクリア)"
      true
    end

    def room_name = room.name
    def exits = room.exits.keys.map { DIR_LABELS[_1] }
    def inventory_names = state.inventory.filter_map { @world.items[_1]&.name }
    def npc_names = visible? ? here_npcs.map(&:name) : []

    def execute(command)
      state.turns += 1
      case command
      in { verb: :go, target: Symbol => dir } then go(dir)
      in { verb: :go } then say "どちらへ? (北/南/東/西/上/下)"
      in { verb: :look } then look
      in { verb: :inventory } then inventory
      in { verb: :take | :drop | :use | :examine, target: nil } then say "何を?"
      in { verb: :take, target: } then take(target)
      in { verb: :drop, target: } then drop(target)
      in { verb: :use, target: } then use(target)
      in { verb: :examine, target: } then examine(target)
      in { verb: :say, target: String => words } then speak(words)
      in { verb: :talk, target: } then talk(target)
      in { verb: :give, target: nil } then say "何を渡す?"
      in { verb: :give, target: } then give(target)
      in { verb: :build, target: } then build(target)
      in { verb: :save } then save
      in { verb: :load } then load
      in { verb: :help } then help
      in { verb: :quit } then say("またね!") && :quit
      in { verb: :unknown, target: } then say "「#{target}」は分からない。(ヘルプ で使い方)"
      else say "うまくいかないようだ。"
      end
    end

    private

    def room = @world.rooms.fetch(state.room)
    def here_items = state.room_items[state.room]
    def visible? = !room.dark? || state.flag?(:light)
    def here_npcs = room.npc_ids.map { @world.npcs[_1] }.select { _1.present?(state) }

    def locked?(dir)
      lock = room.locks[dir] or return false
      !(state.unlocked.include?([room.id, dir]) || (lock.flag && state.flag?(lock.flag)))
    end

    def go(dir)
      dest = room.exits[dir] or return say("#{DIR_LABELS[dir]}には進めない。")
      return say(room.locks[dir].locked_msg) if locked?(dir)

      state.room = dest
      look
    end

    def look
      return say("【#{room.name}】", "真っ暗で何も見えない。明かりが必要だ。") unless visible?

      say "【#{room.name}】", room.desc
      names = here_items.map { @world.items[_1].name }
      say "ここには #{names.join('、')} がある。" if names.any?
      here_npcs.each { say "#{_1.name} がいる。" }
      say "出口: #{room.exits.keys.map { DIR_LABELS[_1] }.join(' ')}"
    end

    def talk(text)
      return say("誰と話す? (#{here_npcs.map(&:name).join('、')})") if text.nil? && here_npcs.size > 1

      npc = find_npc(text) or return say(text ? "「#{text}」はここにいない。" : "ここには誰もいない。")
      line = npc.line_for(state) or return say("#{npc.name} は何も言わない。")
      say "#{npc.name}「#{line.text}」"
      state.flags << line.sets if line.sets
      if line.gives && !state.flag?(:"given_#{npc.id}_#{line.gives}")
        state.flags << :"given_#{npc.id}_#{line.gives}"
        receive(line.gives)
      end
    end

    # 「パンを渡す」「門番にパンを渡す」「パンを門番に渡す」「give bread」
    def give(text)
      parts = text.split(/[をに]/).reject(&:empty?)
      item_text = parts.find { find_item(_1, state.inventory) } or return say("「#{parts.join}」は持っていない。")
      item = find_item(item_text, state.inventory)
      recipient = (parts - [item_text]).first
      npc = recipient ? find_npc(recipient) : here_npcs.find { _1.trades.key?(item.id) } || here_npcs.first
      return say("渡す相手がいない。") unless npc

      trade = npc.trades[item.id] or return say("#{npc.name} は #{item.name} を受け取らなかった。")
      state.inventory.delete(item.id)
      say "#{item.name} を #{npc.name} に渡した。", "#{npc.name}「#{trade.message}」"
      state.flags << trade.sets if trade.sets
      receive(trade.gives) if trade.gives
    end

    # 「しくみを作る」。名前を省略したら、作れるものを作る
    def build(text)
      recipes = @world.recipes.values
      return say("ここでは何も作れないようだ。") if recipes.empty?

      recipe = text ? recipes.find { |r| item_matches?(@world.items[r.result], text) } : recipes.find { craftable?(_1) }
      recipe ||= recipes.first unless text
      return say("「#{text}」の作り方は分からない。") unless recipe

      result = @world.items[recipe.result]
      return say("#{result.name} はもう持っている。") if state.has?(recipe.result)

      missing = recipe.from.count { !state.has?(_1) }
      return say("#{result.name} を作るには、材料があと #{missing} つ足りない。") unless missing.zero?

      recipe.from.each { state.inventory.delete(_1) }
      state.inventory << recipe.result
      say recipe.message, "#{result.name} ができた！"
    end

    def craftable?(recipe) = !state.has?(recipe.result) && recipe.from.all? { state.has?(_1) }

    def receive(item_id)
      state.inventory << item_id
      say "#{@world.items[item_id].name} を受け取った。"
    end

    # 名前の指定がなければ、その部屋にいる唯一の NPC
    def find_npc(text)
      return here_npcs.first if text.nil? && here_npcs.size == 1

      here_npcs.find { |npc| npc.names.any? { _1 == text || (text && _1.include?(text)) } }
    end

    def take(text)
      return say("暗くて手探りでは見つからない。") unless visible?

      item = find_item(text, here_items) or return say("「#{text}」はここにない。")
      return say("#{item.name} は持ち運べない。(調べることはできる)") if item.fixed

      here_items.delete(item.id)
      state.inventory << item.id
      say "#{item.name} を手に入れた。"
    end

    def drop(text)
      item = find_item(text, state.inventory) or return say("「#{text}」は持っていない。")
      state.inventory.delete(item.id)
      here_items << item.id
      say "#{item.name} を置いた。"
    end

    def use(text)
      item = find_item(text, state.inventory) or return say("「#{text}」は持っていない。")
      dir, lock = room.locks.find { |d, l| l.item == item.id && locked?(d) }
      if lock
        state.unlocked << [room.id, dir]
        say lock.unlock_msg
      elsif (hook = @world.use_hooks[item.id])
        say hook.call(state)
      else
        say "ここで #{item.name} を使っても何も起こらない。"
      end
    end

    def speak(words)
      # まずこの部屋の NPC の問いかけに答えたかどうか
      here_npcs.each do |npc|
        answer = npc.answer_for(words) or next
        key = :"answered_#{npc.id}_#{answer.words.first}"
        return say("#{npc.name}「その答えは、もう聞いた。」") if state.flag?(key)

        state.flags << key
        say "#{npc.name}「#{answer.message}」"
        state.flags << answer.sets if answer.sets
        receive(answer.gives) if answer.gives
        return true
      end

      dir, lock = room.locks.find { |d, l| l.password && Adventure.normalize(l.password) == Adventure.normalize(words) && locked?(d) }
      return say("「#{words}」…声が響いただけだった。") unless lock

      state.unlocked << [room.id, dir]
      say lock.unlock_msg
    end

    def examine(text)
      pool = state.inventory + (visible? ? here_items : [])
      target = find_item(text, pool) || (find_npc(text) if visible?) or return say("「#{text}」は見当たらない。")
      say target.desc.empty? ? "特に変わったところはない。" : target.desc
    end

    def inventory
      names = state.inventory.filter_map { @world.items[_1]&.name }
      say names.empty? ? "何も持っていない。" : "持ち物: #{names.join('、')}"
    end

    def save
      File.binwrite(@save_path, Marshal.dump(state))
      say "セーブしました (#{@save_path})"
    end

    def load
      return say("セーブデータがありません。") unless File.exist?(@save_path)

      @state = Marshal.load(File.binread(@save_path)) # 自分で作ったファイルだけを読む前提
      say "ロードしました。"
      look
    end

    def help
      say <<~HELP
        移動: 北 / 南 / 東 / 西 / 上 / 下  (n s e w u d でも可)
        見る / 持ち物 / 取る X / 置く X / 使う X / 調べる X / 言う X
        話す X / 渡す X  (「村長と話す」「門番にパンを渡す」)
        作る X  (材料がそろったら「しくみを作る」)
        「鍵を使う」のような日本語の語順でも OK
        セーブ / ロード / 終了
      HELP
    end

    def find_item(text, ids) = ids.map { @world.items[_1] }.find { item_matches?(_1, text) }

    def item_matches?(item, text) = [item.name, item.id.to_s, *item.aliases].any? { _1 == text || _1.include?(text) }

    def say(*lines) = lines.each { @out.puts(_1) }.then { true }
  end
end
