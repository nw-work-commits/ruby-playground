# TODO と予定の保存先。リクエストは Thread ごとに処理されるので Mutex で排他制御する。
#
# 1 件のデータは「やること」にも「予定」にもなる:
#   - 日付だけ           → 期限つきの TODO
#   - 日付 + 開始時刻     → 予定 (週表示のタイムラインに出る)
#   - repeat を指定       → 毎日 / 平日 / 毎週 / 毎月 くり返す予定
#   - cost を指定         → 家計簿の DSL から from_schedule で取り込める
require "json"
require "date"

class TodoStore
  REPEATS = {
    "none" => "なし", "daily" => "毎日", "weekdays" => "平日", "weekly" => "毎週", "monthly" => "毎月"
  }.freeze
  WDAYS = %w[日 月 火 水 木 金 土].freeze

  Todo = Struct.new(:id, :title, :done, :created_at, :due, :start, :finish, :repeat, :until, :cost, :category,
                    keyword_init: true) do
    def to_h = super.transform_keys(&:to_s)
    def due_date = due && Date.iso8601(due)
    def until_date = self[:until] && Date.iso8601(self[:until])
    def repeating? = !repeat.nil? && repeat != "none"
    def timed? = !start.nil?

    def overdue?(today = Date.today) = !done && !repeating? && due_date && due_date < today
    def due_today?(today = Date.today) = !done && due_date == today

    # "09:30" → 570 (分)。終了が無ければ 1 時間の予定とみなす
    def start_min = minutes(start)
    def end_min = finish ? minutes(finish) : start_min + 60

    def occurs_on?(date)
      return false unless due_date && date >= due_date
      return false if until_date && date > until_date

      case repeat
      when nil, "none" then date == due_date
      when "daily"     then true
      when "weekdays"  then date.wday.between?(1, 5)
      when "weekly"    then date.wday == due_date.wday
      when "monthly"   then date.day == due_date.day
      end
    end

    def occurrences(range) = range.select { occurs_on?(_1) }

    def time_label = timed? ? [start, finish].compact.join("–") : nil

    def repeat_label
      case repeat
      when "weekly" then "毎週#{WDAYS[due_date.wday]}曜"
      when "monthly" then "毎月#{due_date.day}日"
      else REPEATS[repeat] if repeating?
      end
    end

    private

    def minutes(hhmm)
      h, m = hhmm.split(":").map(&:to_i)
      h * 60 + m
    end
  end

  # その日の予定のうち、時間が重なっている組を返す: [[a, b], ...]
  def self.conflicts(todos, date)
    events = todos.select { _1.timed? && _1.occurs_on?(date) }.sort_by(&:start_min)
    events.combination(2).select { |a, b| a.start_min < b.end_min && b.start_min < a.end_min }
  end

  def initialize(path)
    @path = path
    @lock = Mutex.new
    @todos = path && File.exist?(path) ? JSON.parse(File.read(path)).map { Todo.new(**_1.transform_keys(&:to_sym)) } : []
  end

  def all = @lock.synchronize { @todos.map(&:dup) }
  def find(id) = all.find { _1.id == id.to_i }

  # due は "YYYY-MM-DD"、start / finish は "HH:MM"、いずれも省略可
  def add(title, due: nil, **attrs)
    write do
      next_id = (@todos.map(&:id).max || 0) + 1
      Todo.new(id: next_id, title:, done: false, created_at: Time.now.strftime("%Y-%m-%d %H:%M"), due:, **attrs)
          .tap { @todos << _1 }.dup
    end
  end

  def toggle(id) = write { @todos.find { _1.id == id.to_i }&.tap { _1.done = !_1.done } }
  def delete(id) = write { @todos.reject! { _1.id == id.to_i } }
  def clear_done = write { @todos.reject!(&:done) }

  private

  def write
    @lock.synchronize do
      result = yield
      File.write(@path, JSON.pretty_generate(@todos.map(&:to_h))) if @path
      result
    end
  end
end
