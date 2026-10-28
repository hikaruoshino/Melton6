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
--   魔法       : 詠唱開始 (category 8) と着弾 (category 4) を確かめる。2 段目以降は狙った連携が
--                起きたか (追加効果メッセージ) も確かめ、着弾から post_land_sec 待って次へ。
--                最後の重力のあとは post_final_sec (3 秒) 待って気炎万丈の章へ。魔法の着弾のあと約 2.5〜3.5 秒は
--                硬直でアビリティを使えない (0.5 秒では「アビリティは使えなかった」で弾かれた)。
--   MB 受付   : 連携の窓は 1 段ごとに 1 秒縮み (10 - 段数)、計略魔法で〆ると +2 秒。
--                6 連 (連携 5 回目の重力) は 10 - 5 + 2 = 7 秒。1.0.1 までは大悟徹底 → 気炎万丈の章 → メルトンで
--                着弾が重力から 7.2〜7.5 秒になり MB を逃していた。大悟徹底を外し、約 5.7 秒で着弾させる
--                (2026-10-29 のゲーム内のログ・ユーザー判断)。
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
_addon.version  = "1.0.2"
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
    boost_timeout_sec      = 1.5,   -- 気炎万丈の章だけの待ち秒数 (MB 受付に間に合わせるため短く)
    ja_retries             = 1,     -- アビリティが実行されなかったときに、もう一度使う回数
    cast_start_timeout_sec = 2.5,   -- 魔法を使ってから、詠唱開始を確認できるまで待つ秒数
    land_timeout_sec       = 12.0,  -- 詠唱開始から、着弾を確認できるまで待つ秒数
    use_tabula_rasa        = true,  -- 連環計が切れていたら自動で使う (false なら止める)
}
local settings = config.load(defaults)

-- 設定の値の範囲 (最小, 最大)。範囲外 (0 や負の数、極端に大きい値) だと、入力が連打されたり、いつまでも止まらなかったりするため
-- settings.xml を手で書き換えた場合も、読み込み時にこの範囲に収める
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
local function clamp_setting(key, value)
    local lim = LIMITS[key]
    local n = tonumber(value)
    if not lim or not n then return defaults[key] end
    if n < lim[1] then n = lim[1] elseif n > lim[2] then n = lim[2] end
    if key == "ja_retries" then n = math.floor(n) end
    return n
end
for key in pairs(LIMITS) do settings[key] = clamp_setting(key, settings[key]) end

-- -----------------------------------------------------------------------------
-- 定数 (番号は Windower の res の値)
-- -----------------------------------------------------------------------------
local JA = {TABULA_RASA = 210, DARK_ARTS = 212, EBULLIENCE = 221, IMMANENCE = 317}
local SPELL = {AERO = 154, STONE = 159, GEOHELIX = 278, ANEMOHELIX = 280, NOCTOHELIX = 284, KAUSTRA = 502}
local BUFF = {DARK_ARTS = 359, ADDENDUM_BLACK = 402, TABULA_RASA = 377}
local RECAST = {TABULA_RASA = 0}   -- アビリティのリキャスト番号

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
    table.insert(steps, {kind = "ja", id = JA.EBULLIENCE, target = "<me>", boost = true})
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

local function stop(reason, color)
    if not run then return end
    local step = run.steps[run.index]
    local where = step and string.format(" (%d/%d: %s)", run.index, #run.steps,
        step.kind == "ja" and ja_name(step.id) or spell_name(step.id)) or ""
    chat("中止しました: " .. reason .. where, color or 167)
    run = nil
end

local function finish(msg)
    chat(msg, 158)
    run = nil
end

-- 次の手順へ進む。wait 秒後に送る
local function advance(now, wait)
    run.index = run.index + 1
    run.phase = "wait"
    run.next_at = now + wait
end

-- 今の手順を送る
local function send_step(now)
    local step = run.steps[run.index]
    if step.skip_if and step.skip_if(windower.ffxi.get_player()) then
        run.index = run.index + 1
        run.next_at = now
        return
    end

    if step.final and not run.boosted[JA.EBULLIENCE] then
        stop("気炎万丈の章が実行されませんでした")
        return
    end

    if step.kind == "ma" then
        -- ターゲットが変わった・倒れたら止める (別の敵に連携を撃たないため)
        local t = windower.ffxi.get_mob_by_target("t")
        if not t or t.id ~= run.target_id or t.hpp == 0 then
            stop("ターゲットが変わったか、倒れました")
            return
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
        if run.index > #run.steps then
            finish("完了しました")
        elseif now >= run.next_at then
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
        -- 気炎万丈の章は、ラグで遅れて届いても実行されたものとして数える
        if act.param == JA.EBULLIENCE then
            run.boosted[act.param] = true
        end
        -- アビリティの実行
        if run.phase == "ja_sent" and step.kind == "ja" and act.param == step.id then
            run.tries = 0
            advance(now, settings.ja_gap_sec)
        end

    elseif act.category == 8 then
        local a = act.targets and act.targets[1] and act.targets[1].actions and act.targets[1].actions[1]
        if act.param == CAST_INTERRUPT and (run.phase == "ma_sent" or run.phase == "casting") then
            stop("詠唱が中断されました")
        elseif act.param == CAST_BEGIN and run.phase == "ma_sent" and a and a.param == step.id then
            run.phase = "casting"
            run.deadline = now + settings.land_timeout_sec
        end

    elseif act.category == 4 then
        if run.phase ~= "casting" or act.param ~= step.id then return end
        local sc = skillchain_of(act)

        if step.final then
            local late = run.mb_deadline and now > run.mb_deadline
            local used = {}
            if run.boosted[JA.EBULLIENCE] then table.insert(used, "気炎") end
            local boosts = table.concat(used, "・")
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
            chat(string.format("%d連目: %s", step.chain_no, sc))
            if sc == "重力" then
                -- 最後の連携: 硬直が解けるまで post_final_sec 待って気炎万丈の章へ
                run.sc_landed_at = now
                run.mb_deadline = now + mb_window_sec(run.chain_count)
                advance(now, settings.post_final_sec)
                return
            end
        end
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
local function start()
    if run then
        chat("実行中です。止めるときは //m6 stop", 167)
        return
    end
    local problems, player, target = precheck()
    if #problems > 0 then
        chat("開始できません:", 167)
        for _, p in ipairs(problems) do chat("・" .. p, 167) end
        return
    end
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
        boosted = {},   -- [気炎万丈の章の番号] = 実行された
    }
    chat("開始します → " .. (target.name or "?"))
end

windower.register_event("zone change", function() stop("エリアを移動しました") end)
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
        local problems = precheck()
        if #problems == 0 then
            chat("すぐに開始できます")
        else
            for _, p in ipairs(problems) do chat("・" .. p, 167) end
        end

    elseif cmd == "tabula" then
        settings.use_tabula_rasa = not settings.use_tabula_rasa
        config.save(settings)
        chat("連環計が切れていたら自動で使う: " .. (settings.use_tabula_rasa and "ON" or "OFF"))

    elseif cmd == "set" and SETTABLE[(args[1] or ""):lower()] and tonumber(args[2]) then
        local key = SETTABLE[args[1]:lower()]
        local want = tonumber(args[2])
        settings[key] = clamp_setting(key, want)
        config.save(settings)
        if settings[key] ~= want then
            chat(string.format("%s は範囲 %s〜%s に収めました", key, tostring(LIMITS[key][1]), tostring(LIMITS[key][2])), 167)
        end
        chat(string.format("%s = %s", key, tostring(settings[key])))

    elseif cmd == "status" then
        chat(string.format("着弾→次 %.1f秒 (重力のあと %.1f秒) / アビ後 %.1f秒 / アビ確認 %.1f秒×再試行%d (気炎 %.1f秒) / 詠唱開始確認 %.1f秒 / 着弾確認 %.1f秒 / 連環計自動 %s",
            settings.post_land_sec, settings.post_final_sec, settings.ja_gap_sec, settings.ja_timeout_sec, settings.ja_retries, settings.boost_timeout_sec,
            settings.cast_start_timeout_sec, settings.land_timeout_sec, settings.use_tabula_rasa and "ON" or "OFF"))
        if run then chat(string.format("実行中: %d/%d", run.index, #run.steps)) end

    else
        chat("//m6 go      : 6連メルトンを開始 (ゲーム内マクロは /console m6 go)")
        chat("//m6 stop    : 途中で止める")
        chat("//m6 check   : 開始できるか確認だけする (何も実行しない)")
        chat("//m6 status  : 設定の表示")
        chat("//m6 set post <秒> : 魔法の着弾から次のアビリティまで (初期 3.0)")
        chat("//m6 set postfinal <秒> : 最後の重力の着弾から気炎万丈の章まで (初期 3.0。硬直のため短くしすぎない)")
        chat("//m6 set gap <秒>  : アビリティの後の待ち (初期 1.0)")
        chat("//m6 tabula  : 連環計が切れていたら自動で使うか (ON/OFF)")
    end
end)
