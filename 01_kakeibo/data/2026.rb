# 家計簿ファイル。見た目は「書式」だが、中身は普通の Ruby コード。
# カテゴリ名をそのままメソッド名として書ける (food, fun, daily, transport ... 何でも可)。

budget food: 40_000, fun: 15_000, daily: 8_000

# 日程表で「費用」を入れた予定 (飲み会 4,000 円 など) を、支出として取り込む
from_schedule "../../04_miniweb/todos.json"

# 毎月の定期収支 (month で書いた全ての月に自動で入る)
every_month day: 1 do
  housing "家賃", 80_000
  utility "スマホ代", 3_200
end

every_month day: 25 do
  income "給料", 280_000, :salary
end

# 期間限定のサブスク
every_month day: 15, from: "2026-10", to: "2026-12" do
  fun "動画配信サービス", 990
end

month "2026-08" do
  day 3 do
    food "スーパー", 6_100
    daily "シャンプー", 1_200
  end
  day 12 do
    fun "夏祭り", 4_500
    transport "帰省の新幹線", 14_800
  end
  day 20 do
    food "外食", 2_800
  end
end

month "2026-09" do
  day 1 do
    food "スーパー", 4_280
    transport "Suica チャージ", 3_000
  end

  day 10 do
    fun "映画", 1_900
    food "ランチ", 1_100
  end

  day 25 do
    food "焼肉", 6_800
  end

  # 普通の Ruby なのでループも書ける: 平日のコーヒー代
  (2..30).each do |d|
    day(d) { food "コーヒー", 350 } unless Date.new(2026, 9, d).saturday? || Date.new(2026, 9, d).sunday?
  end
end

month "2026-10" do
  day 3 do
    daily "洗剤・ティッシュ", 1_580
    food "スーパー", 5_120
  end

  day 4 do
    fun "ゲーム", 8_980
    fun "ライブチケット", 9_500
  end

  day 5 do
    food "外食", 3_400
  end
end

# day ブロックの外でも on: で日付指定できる
expense "Ruby の本", 3_520, :books, on: "2026-10-01"
