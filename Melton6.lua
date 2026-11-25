-- =============================================================================
-- Melton6.lua : 学者の震天動地の章による 6 連携 → メルトン (MB) をマクロ 1 回で実行するアドオン
-- =============================================================================
-- 【使い方】 ゲーム内マクロに 1 行 `/console m6 go` を入れて、敵をターゲットして押す。
--
-- 【流れ】 (連環計・黒のグリモアは効果中なら飛ばす)
--   連環計 → 黒のグリモア
--   → 震天 エアロ(炸裂) → 震天 ストーン(切断)=切断 → 震天 エアロ=炸裂
--   → 震天 土門の計=切断 → 震天 風門の計=炸裂 → 震天 闇門の計(収縮)=重力
--   → 気炎万丈の章 → メルトン (重力に闇で MB)
--
-- 【進め方】 固定の待ち時間ではなく、アクションパケットで実行を確かめてから次へ進む。
--   アビリティ : 実行のパケット (category 6) を確かめてから ja_gap_sec (1 秒) 待って次へ。
--                気炎万丈の章は MB 受付に間に合わせるため使い直さない。実行されなければメルトンの前で止める
--                使い直した手順のもう一方の応答は、遅れて届いても後の手順に数えない
--   魔法       : 詠唱開始 (category 8) と着弾 (category 4) を確かめる。着弾は開始時の敵へのものだけ受ける。2 段目以降は狙った連携が
--                起きたか (追加効果メッセージ) も確かめ、着弾から post_land_sec 待って次へ。
--                最後の重力のあとは post_final_sec (3 秒) 待って気炎万丈の章へ。魔法の着弾のあと約 2.5〜3.5 秒は
--                硬直でアビリティを使えない (0.5 秒では「アビリティは使えなかった」で弾かれた)。
--   MB 受付   : 連携の窓は 1 段ごとに 1 秒縮み (10 - 段数)、計略魔法で〆ると +2 秒。
--                6 連 (連携 5 回目の重力) は 10 - 5 + 2 = 7 秒。1.0.1 までは大悟徹底 → 気炎万丈の章 → メルトンで
--                着弾が重力から 7.2〜7.5 秒になり MB を逃していた。大悟徹底を外し、約 5.7 秒で着弾させる
--                (2026-10-29 のゲーム内のログ・ユーザー判断)。
--                メルトンを送る時点で、最短の詠唱時間でも受付に間に合わないときは、送らずに止める。
--   失敗 (詠唱中断・連携が起きない・時間切れ・ターゲットが変わった・エリア移動など) したら、その場で止める。
--
-- 【注意: 自動キャストアドオン】 マクロ 1 回の操作で、アビリティと魔法の入力 (最大 16 回) を自動で送る。
--   1 回押せば 1 回だけ実行し、繰り返しはしない。失敗したらその場で止まる。
--   外部ツールの利用は FFXI の利用規約で認められていないため、使用は自己責任で。
--   放置・無人での使用や、改変して自動戦闘・連打に使うことはしないこと。
--
-- 【文字コード】 チャット出力・入力コマンドは Shift-JIS (windower.to_shift_jis)
-- =============================================================================

_addon.name     = "Melton6"
_addon.author   = "hikaruoshino"
_addon.version  = "1.1.1"
_addon.commands = {"m6", "melton6"}

local config = require("config")
local res    = require("resources")

-- -----------------------------------------------------------------------------
-- 設定 (data/settings.xml)
-- -----------------------------------------------------------------------------
local defaults = {
    post_land_sec          = 3.0,   -- 魔法の着弾から、次のアビリティを使うまでの秒数
    post_final_sec         = 3.0,   -- 最後の重力の着弾から、気炎万丈の章を使うまでの秒数 (魔法のあとの硬直が解けるまで)
    ja_gap_sec             = 1.0,   -- アビリティの実行から、次の行動までの秒数 (<wait 1> 相当)
    ja_timeout_sec         = 2.5,   -- アビリティを使ってから、実行を確認できるまで待つ秒数
    boost_timeout_sec      = 1.5,   -- 強化 (気炎万丈の章・大悟徹底) の待ち秒数 (MB 受付に間に合わせるため短く)
    ja_retries             = 1,     -- アビリティが実行されなかったときに、もう一度使う回数
    cast_start_timeout_sec = 2.5,   -- 魔法を使ってから、詠唱開始を確認できるまで待つ秒数
    land_timeout_sec       = 12.0,  -- 詠唱開始から、着弾を確認できるまで待つ秒数
    boost = "ebullience",
    say = {start = "", mb = "", chain1 = "", chain2 = "", chain3 = "", chain4 = "", chain5 = "", chain6 = ""},
    use_tabula_rasa        = true,  -- 連環計が切れていたら自動で使う (false なら止める)
}
local settings = config.load(defaults)

-- 設定の値の範囲 (最小, 最大)。範囲外 (0 や負の数、極端に大きい値) だと、入力が連打されたり、いつまでも止まらなかったりするため
-- config は読み込み・ログイン・ログアウトのたびに settings.xml を読み直し、XML の値で上書きする。
-- そのたびに sanitize_settings (下) で範囲と型を直す (config.register)。開始時と status の表示前にも直す
local LIMITS = {
    post_land_sec = {0, 10}, post_final_sec = {0, 5}, ja_gap_sec = {0.5, 5}, ja_timeout_sec = {0.5, 10}, boost_timeout_sec = {0.5, 5},
    ja_retries = {0, 2}, cast_start_timeout_sec = {1, 10}, land_timeout_sec = {3, 30},
}

-- MB 受付の秒数: 連携の窓 (10 - 段数・最短 4 秒。OmniChain・ChainGuide と同じ値) + 計略魔法で〆た分の 2 秒
-- chain_count は「何連目の魔法か」(6 連なら 6)。連携の段数はその 1 つ少ない数 (6 連目の重力は 5 回目の連携)
local SC_WINDOW_BASE_SEC, SC_WINDOW_MIN_SEC, IMMANENCE_BONUS_SEC = 10.0, 4.0, 2.0
local function mb_window_sec(chain_count)
    return math.max(SC_WINDOW_MIN_SEC, SC_WINDOW_BASE_SEC - (chain_count - 1)) + IMMANENCE_BONUS_SEC
end
local function finite_number(value)
    local n = tonumber(value)
    if n and n == n and math.abs(n) ~= math.huge then return n end
    return nil
end

local function clamp_setting(key, value)
    local lim = LIMITS[key]
    local n = finite_number(value)
    if not lim or not n then return defaults[key] end
    if n < lim[1] then n = lim[1] elseif n > lim[2] then n = lim[2] end
    if key == "ja_retries" then n = math.floor(n) end
    return n
end
local BOOST_MODES = {ebullience = true, enlightenment = true, both = true, none = true}

-- -----------------------------------------------------------------------------
-- 定数 (番号は Windower の res の値)
-- -----------------------------------------------------------------------------
local JA = {TABULA_RASA = 210, DARK_ARTS = 212, EBULLIENCE = 221, ENLIGHTENMENT = 244, IMMANENCE = 317}
local SPELL = {AERO = 154, STONE = 159, GEOHELIX = 278, ANEMOHELIX = 280, NOCTOHELIX = 284, KAUSTRA = 502}
local BUFF = {DARK_ARTS = 359, ADDENDUM_BLACK = 402, TABULA_RASA = 377}
local RECAST = {TABULA_RASA = 0, DARK_ARTS = 232, ENLIGHTENMENT = 235}   -- アビリティのリキャスト番号
-- 開始を断る状態異常 (res/buffs.lua): 睡眠 2・19 / 静寂 6 / 沈黙 29 / アムネジア 16 / 石化 7 / スタン 10 / テラー 28 / 魅了 14・17
local BLOCKING_BUFFS = {2, 19, 6, 29, 16, 7, 10, 28, 14, 17}
-- 詠唱時間の短縮の上限は 80%。res の詠唱時間 × 0.2 を最短の詠唱時間とみなす (これより速く着弾することはない)
local MIN_CAST_RATIO = 0.2

local CAST_BEGIN, CAST_INTERRUPT = 24931, 28787         -- category 8 の param
-- 「Magic Burst!」のメッセージ番号 (res/action_messages.lua で "Magic Burst" を含むもの全部)。
-- 252 (ダメージ) だけだと、メルトンの MB が別の番号で届いたときに「MB にならなかった」と誤判定する
local MSG_MAGIC_BURST = {}
for _, id in ipairs({252, 265, 268, 269, 271, 272, 274, 275, 379, 650, 747, 748, 749, 750, 751, 752, 753, 754, 755, 803, 804}) do
    MSG_MAGIC_BURST[id] = true
end
local MAX_DISTANCE = 21                                 -- 魔法が届く距離の目安 (ヤルム)

-- 連携の追加効果メッセージ ID → 連携名 (288-301 / 385-398 は同じ並び。MBReadyTimer・OmniChain と同じ表)
local SKILLCHAIN_MESSAGES = {}
do
    local order = {"光", "闇", "重力", "分解", "湾曲", "核熱", "収縮", "溶解", "硬化", "振動", "貫通", "切断", "炸裂", "衝撃"}
    for i, name in ipairs(order) do
        SKILLCHAIN_MESSAGES[287 + i] = name
        SKILLCHAIN_MESSAGES[384 + i] = name
    end
end

-- -----------------------------------------------------------------------------
-- ヘルパー
-- -----------------------------------------------------------------------------
local function chat(msg, color)
    windower.add_to_chat(color or 207, windower.to_shift_jis("[Melton6] " .. tostring(msg)))
end

local function ja_name(id) return res.job_abilities[id] and res.job_abilities[id].ja or tostring(id) end
local function spell_name(id) return res.spells[id] and res.spells[id].ja or tostring(id) end

local function send_input(line)
    windower.send_command(windower.to_shift_jis("input " .. line))
end

local SAY_MAX_BYTES = 100
-- start は開始直後、mb はメルトンの入力直前。送信のための待ちは足さない。
local SAY_KEYS = {"start", "1", "2", "3", "4", "5", "6", "mb"}
local function say_key(key)
    if key == "start" or key == "mb" then return key end
    if key and key:match("^[1-6]$") then return "chain" .. key end
end

local function validate_say(text)
    if type(text) ~= "string" then return nil, "セリフは文字列で指定してください" end
    -- 制御文字はバイトの範囲で指定する (0x00-0x1F・0x7F。%c はロケールで範囲が変わるため使わない)
    if text:find("[%z\1-\31\127]") or text:find(";", 1, true) then
        return nil, "セリフに制御文字や半角 ; は使えません"
    end
    text = text:match("^%s*(.-)%s*$")
    if text:sub(1, 1) == "/" then return nil, "セリフを / で始めることはできません" end
    local ok, encoded = pcall(windower.to_shift_jis, text)
    if not ok or type(encoded) ~= "string" then return nil, "セリフの文字コードを変換できません" end
    if #encoded > SAY_MAX_BYTES then return nil, "セリフは Shift-JIS 換算で100バイト以内にしてください" end
    return text, nil, encoded
end

-- 設定の範囲と型を直す。config が settings.xml を読み直すたびに呼ぶ (config.register)
local function sanitize_settings()
    for key in pairs(LIMITS) do settings[key] = clamp_setting(key, settings[key]) end
    if not BOOST_MODES[settings.boost] then settings.boost = defaults.boost end
    if type(settings.use_tabula_rasa) ~= "boolean" then settings.use_tabula_rasa = defaults.use_tabula_rasa end
    if type(settings.say) ~= "table" then settings.say = {} end
    for _, key in ipairs(SAY_KEYS) do
        local internal = say_key(key)
        -- config が XML の数字・真偽値を型変換するため、検証前にセリフへ戻す。
        -- 007 や 1e5 のように、数値にすると形が変わるものは元に戻せない (7・1e+05 になる)
        local value = settings.say[internal]
        if type(value) == "number" then
            value = string.format("%.14g", value)
        elseif type(value) == "boolean" then
            value = tostring(value)
        elseif type(value) ~= "string" then
            value = ""
        end
        settings.say[internal] = validate_say(value) or ""
    end
end
sanitize_settings()
config.register(settings, sanitize_settings)

-- 保存する。ログイン前は config.save が何もしないため、保存されないことを知らせる
local function save_settings()
    local info = windower.ffxi.get_info()
    if not (info and info.logged_in) then
        chat("ログイン前のため、設定は保存されません (ログインすると settings.xml の値に戻ります)", 167)
        return false
    end
    config.save(settings)
    return true
end

local function party_say(key)
    local text = settings.say[say_key(key)]
    if not text or text == "" then return end
    pcall(function()
        local party = windower.ffxi.get_party() or {}
        local joined = false
        for i = 1, 5 do if party["p" .. i] then joined = true; break end end
        if not joined then return end
        local valid, _, encoded = validate_say(text)
        if valid and valid ~= "" then windower.send_command("input /p " .. encoded) end
    end)
end

local function boost_warning()
    if settings.boost == "both" or settings.boost == "enlightenment" then
        chat("大悟徹底を使うと MB 受付に間に合わない可能性があります。ゲーム内で自分で確かめてください", 167)
    end
end

local function has_buff(player, id)
    for _, b in ipairs(player and player.buffs or {}) do
        if b == id then return true end
    end
    return false
end

-- -----------------------------------------------------------------------------
-- 手順
-- -----------------------------------------------------------------------------
-- kind = "ja" / "ma"。skip_if が true を返したら飛ばす。expect_sc はその魔法の着弾で起きるはずの連携
local function build_steps()
    local steps = {
        {kind = "ja", id = JA.TABULA_RASA, target = "<me>",
         skip_if = function(p) return has_buff(p, BUFF.TABULA_RASA) end},
        {kind = "ja", id = JA.DARK_ARTS, target = "<me>",
         skip_if = function(p) return has_buff(p, BUFF.DARK_ARTS) or has_buff(p, BUFF.ADDENDUM_BLACK) end},
    }
    local chain = {
        {SPELL.AERO,       nil},
        {SPELL.STONE,      "切断"},
        {SPELL.AERO,       "炸裂"},
        {SPELL.GEOHELIX,   "切断"},
        {SPELL.ANEMOHELIX, "炸裂"},
        {SPELL.NOCTOHELIX, "重力"},
    }
    for i, c in ipairs(chain) do
        table.insert(steps, {kind = "ja", id = JA.IMMANENCE, target = "<me>"})
        table.insert(steps, {kind = "ma", id = c[1], target = "<t>", expect_sc = c[2], chain_no = i})
    end
    -- 気炎万丈の章は威力上げ (boost)。MB 受付に間に合わせるため、使い直しはしない
    if settings.boost == "enlightenment" or settings.boost == "both" then
        table.insert(steps, {kind = "ja", id = JA.ENLIGHTENMENT, target = "<me>", boost = true})
    end
    if settings.boost == "ebullience" or settings.boost == "both" then
        table.insert(steps, {kind = "ja", id = JA.EBULLIENCE, target = "<me>", boost = true})
    end
    table.insert(steps, {kind = "ma", id = SPELL.KAUSTRA, target = "<t>", final = true})
    return steps
end

-- -----------------------------------------------------------------------------
-- 開始前の確認 (何も実行しないうちに、足りないものを全部知らせる)
-- -----------------------------------------------------------------------------
local function precheck()
    local problems = {}
    local player = windower.ffxi.get_player()
    if not player then return {"キャラクター情報を取得できません"}, nil, nil end

    if player.main_job ~= "SCH" then
        table.insert(problems, "メインジョブが学者ではありません")
    end
    if player.status ~= 0 and player.status ~= 1 then   -- 0: 通常 / 1: 戦闘
        table.insert(problems, "行動できない状態です")
    end
    local blocking = {}
    for _, id in ipairs(BLOCKING_BUFFS) do
        local name = res.buffs[id] and res.buffs[id].ja or tostring(id)
        if has_buff(player, id) and not blocking[name] then
            blocking[name] = true
            table.insert(problems, name .. " のため行動できません")
        end
    end

    local target = windower.ffxi.get_mob_by_target("t")
    if not target or not target.valid_target or target.hpp == 0 or target.spawn_type ~= 16 then
        table.insert(problems, "敵をターゲットしてください")
    elseif target.distance and math.sqrt(target.distance) > MAX_DISTANCE then
        table.insert(problems, string.format("敵が遠すぎます (%.1f)", math.sqrt(target.distance)))
    end

    -- 計略魔法とメルトンの再詠唱 (途中で使えずに止まると、連環計が無駄になるため先に確かめる)
    local spell_recasts = windower.ffxi.get_spell_recasts() or {}
    for _, id in ipairs({SPELL.AERO, SPELL.STONE, SPELL.GEOHELIX, SPELL.ANEMOHELIX, SPELL.NOCTOHELIX, SPELL.KAUSTRA}) do
        local r = (spell_recasts[id] or 0) / 60
        if r > 0 then table.insert(problems, string.format("%s の再詠唱まで %.0f秒", spell_name(id), r)) end
    end
    local ja_recasts = windower.ffxi.get_ability_recasts() or {}
    if (settings.boost == "enlightenment" or settings.boost == "both") and (ja_recasts[RECAST.ENLIGHTENMENT] or 0) > 0 then
        table.insert(problems, "大悟徹底の再使用待ちです")
    end
    -- 黒のグリモアは効果中なら使わない (手順で飛ばす)。使うときだけ再使用を確かめる
    if not (has_buff(player, BUFF.DARK_ARTS) or has_buff(player, BUFF.ADDENDUM_BLACK)) and (ja_recasts[RECAST.DARK_ARTS] or 0) > 0 then
        table.insert(problems, string.format("黒のグリモアの再使用まで %d秒", math.ceil(ja_recasts[RECAST.DARK_ARTS])))
    end
    if not has_buff(player, BUFF.TABULA_RASA) then
        if not settings.use_tabula_rasa then
            table.insert(problems, "連環計の効果中ではありません (メルトンは連環計の効果中のみ詠唱できます)")
        elseif (ja_recasts[RECAST.TABULA_RASA] or 0) > 0 then
            table.insert(problems, string.format("連環計の再使用まで %d分", math.ceil(ja_recasts[RECAST.TABULA_RASA] / 60)))
        end
    end

    -- MP: 6 つの魔法 + メルトン (最大MPの20%)
    local need = math.ceil((player.vitals.max_mp or 0) * 0.2)
    for _, id in ipairs({SPELL.AERO, SPELL.STONE, SPELL.AERO, SPELL.GEOHELIX, SPELL.ANEMOHELIX, SPELL.NOCTOHELIX}) do
        need = need + (res.spells[id].mp_cost or 0)
    end
    if (player.vitals.mp or 0) < need then
        table.insert(problems, string.format("MP が足りません (%d / 必要 %d)", player.vitals.mp or 0, need))
    end

    return problems, player, target
end

-- -----------------------------------------------------------------------------
-- 実行状態
-- -----------------------------------------------------------------------------
local run = nil   -- 実行中の情報 (止まっていれば nil)
local player_id = nil

-- 表示より先に run を nil にする (表示が例外を出しても、実行状態を残さないため)
local function stop(reason, color)
    local r = run
    if not r then return end
    run = nil
    local step = r.steps[r.index]
    local where = step and string.format(" (%d/%d: %s)", r.index, #r.steps,
        step.kind == "ja" and ja_name(step.id) or spell_name(step.id)) or ""
    chat("中止しました: " .. reason .. where, color or 167)
end

local function finish(msg)
    run = nil
    chat(msg, 158)
end

-- 次の手順へ進む。wait 秒後に送る
local function advance(now, wait)
    run.index = run.index + 1
    run.phase = "wait"
    run.next_at = now + wait
end

-- 応答を待たなくなった /ja の送信 (再送で 2 回以上送った手順の残り・応答の来ないまま飛ばした手順) を記録する。
-- 最後の送信の期限 (until_at) までに届いた同じアビリティの実行は、その送信への遅れた応答とみなし、後の手順に数えない
local function mark_stale(id, count, until_at, now)
    if not id or type(count) ~= "number" or count < 1 or type(until_at) ~= "number" or until_at < now then return end
    if type(run.ja_stale) ~= "table" then run.ja_stale = {} end
    local old = run.ja_stale[id]
    if old and old.until_at >= now then
        old.count = old.count + count
        if until_at > old.until_at then old.until_at = until_at end
    else
        run.ja_stale[id] = {count = count, until_at = until_at}
    end
end

-- 遅れた応答なら 1 つ消費して true を返す (期限切れの記録は捨てる)
local function consume_stale(id, now)
    local stale = type(run.ja_stale) == "table" and run.ja_stale[id]
    if not stale then return false end
    if now > stale.until_at or stale.count < 1 then
        run.ja_stale[id] = nil
        return false
    end
    stale.count = stale.count - 1
    if stale.count < 1 then run.ja_stale[id] = nil end
    return true
end

-- 今の手順を送る
local function send_step(now)
    local step = run.steps[run.index]
    if step.skip_if and step.skip_if(windower.ffxi.get_player()) then
        -- 再送の経路 (ja_sent の期限切れ) から来ても、次の手順を wait から新しく始める。
        -- 送ったまま応答の来ていない分は、遅れて届いても後の手順に数えない
        if run.phase == "ja_sent" then mark_stale(step.id, run.tries, run.deadline, now) end
        run.index = run.index + 1
        run.phase = "wait"
        run.tries = 0
        run.next_at = now
        return
    end

    -- ターゲットが変わった・倒れたら止める (別の敵に連携を撃たないため)。
    -- アビリティ (<me>) の手順でも同じ: 開始時の敵への連携の途中のため
    local t = windower.ffxi.get_mob_by_target("t")
    if not t or t.id ~= run.target_id or t.hpp == 0 then
        stop("ターゲットが変わったか、倒れました")
        return
    end

    if step.final then
        for _, required in ipairs(run.steps) do
            if required.boost and not run.boosted[required.id] then
                stop(ja_name(required.id) .. " が実行されませんでした")
                return
            end
        end
    end

    if step.kind == "ma" then
        if step.final then
            -- 最短の詠唱時間でも MB 受付に間に合わないなら、メルトンを送らずに止める
            local min_cast = (res.spells[step.id] and res.spells[step.id].cast_time or 0) * MIN_CAST_RATIO
            if run.mb_deadline and now + min_cast > run.mb_deadline then
                stop(string.format("MB 受付に間に合わないため、メルトンを送りません (受付の残り %.1f秒 / 最短の詠唱 %.1f秒)",
                    run.mb_deadline - now, min_cast))
                return
            end
            party_say("mb")
        end
        send_input(string.format('/ma "%s" %s', spell_name(step.id), step.target))
        run.phase = "ma_sent"
        run.deadline = now + settings.cast_start_timeout_sec
    else
        send_input(string.format('/ja "%s" %s', ja_name(step.id), step.target))
        run.phase = "ja_sent"
        -- 気炎万丈の章は待ちを短く: 不発ならすぐに止める (使い直す時間は MB 受付に残っていない)
        run.deadline = now + (step.boost and settings.boost_timeout_sec or settings.ja_timeout_sec)
        run.tries = (run.tries or 0) + 1
    end
end

local function tick(now)
    if not run then return end
    if run.phase == "wait" then
        if now >= run.next_at then
            send_step(now)
        end
    elseif now > run.deadline then
        if run.phase == "ja_sent" then
            local step = run.steps[run.index]
            if step.boost then
                -- 気炎万丈の章は使い直さない (MB 受付に間に合わないため)。メルトンの前で止める
                stop(ja_name(step.id) .. " が実行されませんでした")
            elseif run.tries <= settings.ja_retries then
                send_step(now)   -- 不発 (待ち時間不足など) のときは、もう一度だけ使う
            else
                stop("アビリティが実行されませんでした")
            end
        elseif run.phase == "ma_sent" then
            stop("詠唱が始まりませんでした (射程外・MP不足・詠唱できない状態など)")
        elseif run.phase == "casting" then
            stop("着弾を確認できませんでした")
        end
    end
end

windower.register_event("prerender", function()
    if not run then return end
    local ok, err = pcall(tick, os.clock())
    if not ok then
        run = nil
        chat("エラーのため中止しました: " .. tostring(err), 167)
    end
end)

-- 着弾した魔法で起きた連携の名前 (起きていなければ nil)
local function skillchain_of(act)
    for _, target in ipairs(act.targets or {}) do
        local a = target.actions and target.actions[1]
        if a and a.has_add_effect and SKILLCHAIN_MESSAGES[a.add_effect_message] then
            return SKILLCHAIN_MESSAGES[a.add_effect_message]
        end
    end
    return nil
end

local function is_magic_burst(act)
    for _, target in ipairs(act.targets or {}) do
        local a = target.actions and target.actions[1]
        if a and MSG_MAGIC_BURST[a.message] then return true end
    end
    return false
end

-- 原因を調べるための記録: 着弾で届いたメッセージ番号 (例 "2" や "2+追加163")
local function messages_of(act)
    local list = {}
    for _, target in ipairs(act.targets or {}) do
        local a = target.actions and target.actions[1]
        if a then
            local s = tostring(a.message)
            if a.has_add_effect then s = s .. "+追加" .. tostring(a.add_effect_message) end
            table.insert(list, s)
        end
    end
    return table.concat(list, ",")
end

local function on_action(act)
    if act.actor_id ~= player_id then return end
    local now = os.clock()
    local step = run.steps[run.index]
    if not step then return end

    if act.category == 6 then
        -- アビリティの実行。強化は、待っている間 (boost_timeout_sec 以内) に届いたときだけ実行として数える。
        -- それより遅れて届いたときは、すでに止まっている。
        -- 再送した手順のもう一方の応答 (遅れて届いた古い応答) は、ここで消費して後の手順へ進めない
        if consume_stale(act.param, now) then return end
        if run.phase == "ja_sent" and step.kind == "ja" and act.param == step.id then
            if step.boost then run.boosted[act.param] = true end
            -- この手順で送った回数のうち、1 回は今の応答。残りは期限まで古い応答として扱う
            mark_stale(step.id, (run.tries or 0) - 1, run.deadline, now)
            run.tries = 0
            advance(now, settings.ja_gap_sec)
        end

    elseif act.category == 8 then
        local first = type(act.targets) == "table" and act.targets[1]
        local a = type(first) == "table" and first.actions and first.actions[1]
        if act.param == CAST_INTERRUPT and (run.phase == "ma_sent" or run.phase == "casting") then
            stop("詠唱が中断されました")
        elseif act.param == CAST_BEGIN and run.phase == "ma_sent" and first.id == run.target_id and a and a.param == step.id then
            run.phase = "casting"
            run.deadline = now + settings.land_timeout_sec
        end

    elseif act.category == 4 then
        -- 詠唱開始 (category 8) を取りこぼしても、自分の同じ魔法の着弾なら受ける (ma_sent のままでも進む)
        if (run.phase ~= "casting" and run.phase ~= "ma_sent") or step.kind ~= "ma" or act.param ~= step.id then return end
        -- 開始時の敵への着弾だけを受ける (別の敵への手動の詠唱の着弾を、この手順の着弾と取り違えないため)
        local first = type(act.targets) == "table" and act.targets[1]
        if type(first) ~= "table" or first.id == nil or first.id ~= run.target_id then return end
        local sc = skillchain_of(act)

        if step.final then
            local late = run.mb_deadline and now > run.mb_deadline
            local used = {}
            if run.boosted[JA.EBULLIENCE] then table.insert(used, "気炎") end
            if run.boosted[JA.ENLIGHTENMENT] then table.insert(used, "大悟") end
            local boosts = #used > 0 and table.concat(used, "・") or "強化なし"
            -- 闇門の計 (重力) の着弾からメルトン着弾までの秒数
            local since_sc = run.sc_landed_at and string.format("%.2f秒", now - run.sc_landed_at) or "?"
            local window = string.format("受付 %.1f秒", mb_window_sec(run.chain_count))
            if is_magic_burst(act) then
                finish(string.format("メルトンでマジックバースト成功！ (%d連携 / %s / 重力から %s / %s / %s)", run.chain_count, boosts, since_sc, window, run.target_name))
            else
                finish((late and "メルトンが MB 受付に間に合いませんでした (MB なし)" or "メルトンは着弾しましたが MB になりませんでした")
                    .. string.format(" (%s / 重力から %s / %s / メッセージ %s / %s)", boosts, since_sc, window, messages_of(act), run.target_name))
            end
            return
        end

        if step.expect_sc then
            if sc ~= step.expect_sc then
                stop(string.format("連携が起きませんでした (狙い: %s / 結果: %s)", step.expect_sc, sc or "なし"))
                return
            end
            run.chain_count = step.chain_no
            party_say(tostring(step.chain_no))
            chat(string.format("%d連目: %s", step.chain_no, sc))
            if sc == "重力" then
                -- 最後の連携: 硬直が解けるまで post_final_sec 待って気炎万丈の章へ
                run.sc_landed_at = now
                run.mb_deadline = now + mb_window_sec(run.chain_count)
                advance(now, settings.post_final_sec)
                return
            end
        end
        -- 1 は起点の着弾確認直後、2～6 は期待した連携の成立確認直後に送る。
        if step.chain_no == 1 then party_say("1") end
        advance(now, settings.post_land_sec)
    end
end

windower.register_event("action", function(act)
    if not run then return end
    local ok, err = pcall(on_action, act)
    if not ok then
        run = nil
        chat("エラーのため中止しました: " .. tostring(err), 167)
    end
end)

-- -----------------------------------------------------------------------------
-- 開始・クリーンアップ
-- -----------------------------------------------------------------------------
-- 連環計の残り時間はアドオンから取れないため、効果中から始めるときは利用者に確かめてもらう
local function tabula_notice(player)
    if has_buff(player, BUFF.TABULA_RASA) then
        chat("連環計の効果中から始めます。残り時間は取れないため、自分で確かめてください", 167)
    end
end

local function start()
    if run then
        chat("実行中です。止めるときは //m6 stop", 167)
        return
    end
    sanitize_settings()
    local problems, player, target = precheck()
    if #problems > 0 then
        chat("開始できません:", 167)
        for _, p in ipairs(problems) do chat("・" .. p, 167) end
        return
    end
    tabula_notice(player)
    boost_warning()
    player_id = player.id
    run = {
        steps = build_steps(),
        index = 1,
        phase = "wait",
        next_at = os.clock(),
        target_id = target.id,
        target_name = target.name or "?",   -- 結果の表示に出す (どの敵で MB になったか・ならなかったかを後で確かめられるように)
        chain_count = 0,
        tries = 0,
        ja_stale = {},  -- [アビリティの番号] = {count = 古い応答の数, until_at = 受け付ける期限} (mark_stale)
        boosted = {},   -- [気炎万丈の章の番号] = 実行された
    }
    chat("開始します → " .. (target.name or "?"))
    party_say("start")
end

windower.register_event("zone change", function() stop("エリアを移動しました") end)
windower.register_event("job change", function() stop("ジョブが変更されました") end)
windower.register_event("status change", function(new)
    if run and (new == 2 or new == 3) then stop("戦闘不能になりました") end   -- 2: 戦闘不能 / 3: 戦闘不能 (戦闘中)
end)
windower.register_event("logout", function() stop("ログアウトしました") end)
windower.register_event("unload", function() run = nil end)

-- -----------------------------------------------------------------------------
-- コマンド (//m6 または //melton6)
-- -----------------------------------------------------------------------------
local SETTABLE = {
    post = "post_land_sec", postfinal = "post_final_sec", gap = "ja_gap_sec", jatimeout = "ja_timeout_sec", boosttimeout = "boost_timeout_sec",
    retries = "ja_retries", casttimeout = "cast_start_timeout_sec", landtimeout = "land_timeout_sec",
}

windower.register_event("addon command", function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower() or "help"

    if cmd == "go" or cmd == "start" then
        start()

    elseif cmd == "stop" then
        if run then stop("手動で止めました", 207) else chat("実行していません") end

    elseif cmd == "check" then
        sanitize_settings()
        local problems, player = precheck()
        if #problems == 0 then
            chat("すぐに開始できます")
            tabula_notice(player)
        else
            for _, p in ipairs(problems) do chat("・" .. p, 167) end
        end

    elseif cmd == "boost" then
        local mode = (args[1] or ""):lower()
        if not BOOST_MODES[mode] then
            chat("//m6 boost <ebullience|enlightenment|both|none>", 167)
            return
        end
        settings.boost = mode
        save_settings()
        chat("boost = " .. mode)
        boost_warning()

    elseif cmd == "say" then
        if not args[1] then
            for _, key in ipairs(SAY_KEYS) do
                local value = settings.say[say_key(key)]
                chat("say " .. key .. " = " .. (type(value) == "string" and value or ""))
            end
            return
        end
        local key = say_key(args[1]:lower())
        if not key or not args[2] then
            chat("//m6 say <start|1-6|mb> <text|off>", 167)
            return
        end
        local ok, text = pcall(function()
            return windower.from_shift_jis(windower.convert_auto_trans(table.concat(args, " ", 2)))
        end)
        if not ok or type(text) ~= "string" then
            chat("セリフの文字コードを変換できません", 167)
            return
        end
        if text:lower() == "off" then text = "" end
        local valid, reason = validate_say(text)
        if not valid then chat(reason, 167); return end
        settings.say[key] = valid
        save_settings()
        chat("say " .. args[1] .. " = " .. valid)

    elseif cmd == "tabula" then
        settings.use_tabula_rasa = not settings.use_tabula_rasa
        save_settings()
        chat("連環計が切れていたら自動で使う: " .. (settings.use_tabula_rasa and "ON" or "OFF"))

    elseif cmd == "set" then
        local name = (args[1] or ""):lower()
        local key = SETTABLE[name]
        if not key then
            chat("設定の名前が違います: " .. name .. " (post|postfinal|gap|jatimeout|boosttimeout|retries|casttimeout|landtimeout)", 167)
            return
        end
        local want = finite_number(args[2])
        if not want then
            chat("有限の数字で指定してください", 167)
            return
        end
        if key == "ja_retries" and want ~= math.floor(want) then
            chat("retries は整数で指定してください", 167)
            return
        end
        settings[key] = clamp_setting(key, want)
        save_settings()
        if settings[key] ~= want then
            chat(string.format("%s は範囲 %s〜%s に収めました", key, tostring(LIMITS[key][1]), tostring(LIMITS[key][2])), 167)
        end
        chat(string.format("%s = %s", key, tostring(settings[key])))

    elseif cmd == "status" then
        sanitize_settings()
        chat("boost = " .. settings.boost)
        chat(string.format("着弾→次 %.1f秒 (重力のあと %.1f秒) / アビ後 %.1f秒 / アビ確認 %.1f秒×再試行%d (気炎 %.1f秒) / 詠唱開始確認 %.1f秒 / 着弾確認 %.1f秒 / 連環計自動 %s",
            settings.post_land_sec, settings.post_final_sec, settings.ja_gap_sec, settings.ja_timeout_sec, settings.ja_retries, settings.boost_timeout_sec,
            settings.cast_start_timeout_sec, settings.land_timeout_sec, settings.use_tabula_rasa and "ON" or "OFF"))
        if run then chat(string.format("実行中: %d/%d", run.index, #run.steps)) end

    else
        chat("//m6 boost <ebullience|enlightenment|both|none>")
        chat("//m6 say <start|1-6|mb> <text|off>")
        chat("//m6 go      : 6連メルトンを開始 (ゲーム内マクロは /console m6 go)")
        chat("//m6 stop    : 途中で止める")
        chat("//m6 check   : 開始できるか確認だけする (何も実行しない)")
        chat("//m6 status  : 設定の表示")
        chat("//m6 set post <秒> : 魔法の着弾から次のアビリティまで (初期 3.0・0〜10)")
        chat("//m6 set postfinal <秒> : 最後の重力の着弾から気炎万丈の章まで (初期 3.0・0〜5。硬直のため短くしすぎない)")
        chat("//m6 set gap <秒>  : アビリティの後の待ち (初期 1.0・0.5〜5)")
        chat("//m6 set jatimeout <秒> : アビリティの実行を待つ秒数 (初期 2.5・0.5〜10)")
        chat("//m6 set boosttimeout <秒> : 強化 (気炎万丈の章・大悟徹底) の実行を待つ秒数 (初期 1.5・0.5〜5)")
        chat("//m6 set retries <回> : アビリティが実行されなかったときに使い直す回数 (初期 1・0〜2)")
        chat("//m6 set casttimeout <秒> : 詠唱開始を待つ秒数 (初期 2.5・1〜10)")
        chat("//m6 set landtimeout <秒> : 詠唱開始から着弾を待つ秒数 (初期 12.0・3〜30)")
        chat("//m6 tabula  : 連環計が切れていたら自動で使うか (ON/OFF)")
    end
end)
