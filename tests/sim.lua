-- Melton6.lua を変更せずに読み込み、Windower とゲームの応答を模擬して、手順の動きを確かめる (Lua 5.1)
-- 使い方: lua5.1 sim.lua <Melton6.lua> <res フォルダー> [fuzz 回数]
local SRC, RESDIR, FUZZ = arg[1], arg[2], tonumber(arg[3])
local fails, total = 0, 0
local function check(c, m) total = total + 1; if not c then fails = fails + 1; io.write("NG: " .. m .. "\n") end end

local res_ja = assert(loadfile(RESDIR .. '/job_abilities.lua'))()
local res_sp = assert(loadfile(RESDIR .. '/spells.lua'))()
local JA_ID, SP_ID = {}, {}
for id, r in pairs(res_ja) do if type(r) == 'table' and r.ja then JA_ID[r.ja] = id end end
for id, r in pairs(res_sp) do if type(r) == 'table' and r.ja then SP_ID[r.ja] = id end end

local ME, TID = 1, 500
local SC_MSG = {['切断'] = 299, ['炸裂'] = 300, ['重力'] = 290}
local SC_OF_N = {[1] = false, [2] = '切断', [3] = '炸裂', [4] = '切断', [5] = '炸裂', [6] = '重力'}   -- 魔法の何発目か (使い直しの無い通常時)

-- 世界を作る。behave(kind, id, n) が応答を決める: nil = 応答しない / table = {delay=, ...}
local function run_world(opts)
    opts = opts or {}
    local T, queue, handlers, sent, chat = 0, {}, {}, {}, {}
    local buffs = opts.buffs or {}
    local target_id = TID
    local zone_events = {}
    local env
    env = {
        _addon = {}, pairs = pairs, ipairs = ipairs, tonumber = tonumber, tostring = tostring, type = type, pcall = pcall,
        string = string, table = table, math = math, setmetatable = setmetatable, rawget = rawget, select = select, error = error,
        os = {clock = function() return T end},
        require = function(n)
            if n == 'config' then return {load = function(d) local s = {} for k, v in pairs(d) do s[k] = v end for k, v in pairs(opts.settings or {}) do s[k] = v end return s end, save = function() end} end
            if n == 'resources' then return {job_abilities = res_ja, spells = res_sp} end
            error('no module ' .. n)
        end,
        windower = {
            to_shift_jis = function(s) return s end,
            register_event = function(ev, fn) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], fn) end,
            add_to_chat = function(c, t) chat[#chat + 1] = t end,
            send_command = function(c) sent[#sent + 1] = {t = T, cmd = c} end,
            ffxi = {
                get_player = function() return {id = ME, main_job = 'SCH', status = 1, buffs = buffs, vitals = {mp = 2000, max_mp = 2000}} end,
                get_mob_by_target = function() if opts.no_target then return nil end return {id = target_id, name = 'Mob', valid_target = true, hpp = 100, spawn_type = 16, distance = 100} end,
                get_spell_recasts = function() return {} end,
                get_ability_recasts = function() return {} end,
            },
        },
    }
    env._G = env
    local chunk = assert(loadfile(SRC)); setfenv(chunk, env); chunk()
    local function fire(ev, ...) for _, fn in ipairs(handlers[ev] or {}) do fn(...) end end
    local function after(d, fn) queue[#queue + 1] = {at = T + d, fn = fn} end
    local W = {sent = sent, chat = chat, fire = fire}
    local n_ja, n_ma = 0, 0
    local behave = opts.behave or function() return {} end
    W.set_target = function(id) target_id = id end
    -- 入力の送信を、応答に変える
    local orig_send = env.windower.send_command
    env.windower.send_command = function(c)
        orig_send(c)
        local kind, name = c:match('^input /(%a+) "([^"]+)"')
        if kind == 'ja' then
            local id = JA_ID[name]; n_ja = n_ja + 1
            local r = behave('ja', id, n_ja)
            if r then after(r.delay or 0.3, function()
                fire('action', {category = 6, actor_id = ME, param = id, targets = {{id = ME, actions = {{param = 0, message = 0}}}}})
            end) end
        elseif kind == 'ma' then
            local id = SP_ID[name]; n_ma = n_ma + 1
            local my_n = n_ma
            local r = behave('ma', id, n_ma)
            if r then
                local d0 = r.delay or 0.3
                if r.begin ~= false then after(d0, function()
                    fire('action', {category = 8, actor_id = ME, param = 24931, targets = {{id = target_id, actions = {{param = id}}}}})
                end) end
                local land = d0 + (r.cast or 1.5)
                if r.interrupt then after(land, function() fire('action', {category = 8, actor_id = ME, param = 28787, targets = {{id = target_id, actions = {{param = id}}}}}) end)
                elseif r.land ~= false then after(land, function()
                    local sc = r.sc
                    if sc == nil then sc = SC_OF_N[my_n] end
                    if sc == false then sc = nil end
                    local act = {category = 4, actor_id = ME, param = id, targets = {{id = target_id, actions = {{message = r.mb and 252 or 2, has_add_effect = sc ~= nil, add_effect_message = sc and SC_MSG[sc]}}}}}
                    fire('action', act)
                end) end
            end
        end
    end
    W.go = function() fire('addon command', 'go') end
    W.run_until = function(limit, on_frame)
        local dt = 0.05
        while T < limit do
            T = T + dt
            local due, rest = {}, {}
            for _, q in ipairs(queue) do if q.at <= T then due[#due + 1] = q else rest[#rest + 1] = q end end
            queue = rest
            table.sort(due, function(a, b) return a.at < b.at end)
            for _, q in ipairs(due) do q.fn() end
            fire('prerender')
            if on_frame then on_frame(T) end
        end
    end
    W.log_has = function(s) for _, c in ipairs(chat) do if c:find(s, 1, true) then return true end end return false end
    W.names = function() local o = {} for _, s in ipairs(sent) do o[#o + 1] = s.cmd:match('"([^"]+)"') end return o end
    return W
end

local function ok_behave(kind, id, n) return {} end

-- S1 正常: 17 回送る / MB 成功
do
    local W = run_world({behave = function(k, id) if k == 'ma' and id == 502 then return {mb = true, cast = 2} end return {} end})
    W.go(); W.run_until(90)
    if os.getenv('DBG') then for _, c in ipairs(W.chat) do print('  chat:', c) end for _, s2 in ipairs(W.sent) do print(string.format('  %.2f %s', s2.t, s2.cmd)) end end
    check(#W.sent == 17, "S1 正常: 入力は 17 回 (実際 " .. #W.sent .. ")")
    check(W.log_has('マジックバースト成功'), "S1 メルトンで MB 成功を表示する")
    local names = W.names()
    local want = {'連環計', '黒のグリモア', '震天動地の章', 'エアロ', '震天動地の章', 'ストーン', '震天動地の章', 'エアロ', '震天動地の章', '土門の計', '震天動地の章', '風門の計', '震天動地の章', '闇門の計', '大悟徹底', '気炎万丈の章', 'メルトン'}
    for i, w in ipairs(want) do check(names[i] == w, "S1 順序 " .. i .. ": 期待 " .. w .. " / 実際 " .. tostring(names[i])) end
    local before = #W.sent
    W.run_until(120)
    check(#W.sent == before, "S1 完了後は何も送らない")
end

-- S2 連環計・黒のグリモアが効果中なら飛ばす: 15 回
do
    local W = run_world({buffs = {377, 359}, behave = function(k, id) if k == 'ma' and id == 502 then return {mb = true} end return {} end})
    W.go(); W.run_until(90)
    check(#W.sent == 15, "S2 効果中は飛ばす: 15 回 (実際 " .. #W.sent .. ")")
end

-- S3 詠唱が中断されたら止まる
do
    local W = run_world({buffs = {377, 359}, behave = function(k, id, n) if k == 'ma' and n == 3 then return {interrupt = true} end return {} end})
    W.go(); W.run_until(90)
    local n_at_stop = #W.sent
    check(W.log_has('詠唱が中断'), "S3 中断を知らせる")
    check(n_at_stop == 2 * 3, "S3 中断した魔法のあとは送らない (実際 " .. n_at_stop .. ")")
end

-- S4 狙った連携が起きなければ止まる
do
    local W = run_world({buffs = {377, 359}, behave = function(k, id, n) if k == 'ma' and n == 2 then return {sc = false} end return {} end})
    W.go(); W.run_until(90)
    check(W.log_has('連携が起きませんでした'), "S4 連携が起きなければ止まる")
    check(#W.sent == 4, "S4 止まったあとは送らない (実際 " .. #W.sent .. ")")
end

-- S5 アビリティが実行されない → 1 回だけ使い直して止まる
do
    local W = run_world({buffs = {377, 359}, behave = function(k, id, n) if k == 'ja' and n <= 2 then return nil end return {} end})
    W.go(); W.run_until(60)
    check(#W.sent == 2, "S5 不発: 使い直しは 1 回で止まる (実際 " .. #W.sent .. ")")
    check(W.log_has('アビリティが実行されませんでした'), "S5 理由を表示する")
end

-- S6 大悟・気炎: 片方だけ不発なら続行 / 両方不発ならメルトンの前で止まる
do
    local W = run_world({buffs = {377, 359}, behave = function(k, id) if k == 'ja' and id == 244 then return nil end if k == 'ma' and id == 502 then return {mb = true} end return {} end})
    W.go(); W.run_until(90)
    check(W.log_has('マジックバースト成功'), "S6 片方だけ不発でもメルトンまで続く")
    local W2 = run_world({buffs = {377, 359}, behave = function(k, id) if k == 'ja' and (id == 244 or id == 221) then return nil end return {} end})
    W2.go(); W2.run_until(90)
    local names = W2.names()
    local kaustra = false
    for _, n in ipairs(names) do if n == 'メルトン' then kaustra = true end end
    check(not kaustra and W2.log_has('どちらも実行されませんでした'), "S6 両方不発ならメルトンを撃たずに止まる")
end

-- S7 ターゲットが変わったら止まる / エリア移動・ログアウト・戦闘不能で止まる
do
    local W = run_world({buffs = {377, 359}, behave = ok_behave})
    W.go()
    W.run_until(12, function(t) end)
    W.set_target(999)
    W.run_until(60)
    check(W.log_has('ターゲットが変わった'), "S7 ターゲットが変わったら止まる")
end
for _, ev in ipairs{{'zone change'}, {'logout'}, {'status change', 2}} do
    local W = run_world({buffs = {377, 359}, behave = ok_behave})
    W.go(); W.run_until(6)
    local n = #W.sent
    W.fire(ev[1], ev[2]); W.run_until(60)
    check(#W.sent == n, "S8 " .. ev[1] .. " のあとは送らない (止まる前 " .. n .. " / 後 " .. #W.sent .. ")")
end

-- S9 二重起動の拒否 / 手動停止
do
    local W = run_world({buffs = {377, 359}, behave = ok_behave})
    W.go(); W.run_until(2); local n = #W.sent
    W.go()
    check(W.log_has('実行中です'), "S9 実行中の再起動は断る")
    W.fire('addon command', 'stop'); W.run_until(60)
    check(#W.sent <= n + 1, "S9 //m6 stop のあとは送らない")
end

-- S10 設定の値: 不正な値で、入力が大量に送られない
do
    local W = run_world({buffs = {377, 359}, behave = function(k, id, n) if k == 'ja' then return nil end return {} end})
    W.fire('addon command', 'set', 'retries', '50')
    W.go(); W.run_until(400)
    check(#W.sent <= 4, "S10 retries=50 を設定しても、使い直しは少数 (実際 " .. #W.sent .. " 回送った)")
    local W2 = run_world({buffs = {377, 359}, behave = ok_behave})
    W2.fire('addon command', 'set', 'post', '-5')
    W2.fire('addon command', 'set', 'gap', '0')
    W2.go(); W2.run_until(5)
    check(#W2.sent <= 4, "S10 post=-5 / gap=0 でも、短時間に大量に送らない (5 秒で " .. #W2.sent .. " 回)")
end

-- S11 settings.xml を手で書き換えた極端な値も、読み込み時に範囲へ収める
do
    local W = run_world({buffs = {377, 359}, settings = {ja_retries = 99, post_land_sec = -3, ja_gap_sec = 0}, behave = function(k, id, n) if k == 'ja' then return nil end return {} end})
    W.go(); W.run_until(300)
    check(#W.sent <= 4, "S11 settings.xml の ja_retries=99 でも、使い直しは少数 (実際 " .. #W.sent .. ")")
end

-- ファジング: 応答の欠落・遅延・重複・不一致をランダムに起こして、不変条件を確かめる
if FUZZ then
    math.randomseed(777)
    local max_sent, hung = 0, 0
    for i = 1, FUZZ do
        local W
        W = run_world({buffs = (math.random() < 0.5) and {377, 359} or {}, behave = function(k, id, n)
            local r = math.random()
            if r < 0.08 then return nil end                                  -- 応答なし (不発)
            local out = {delay = math.random() * 2.5, cast = 0.5 + math.random() * 3}
            if k == 'ma' then
                if r < 0.12 then out.begin = false end                        -- 詠唱開始が届かない
                if r < 0.16 then out.interrupt = true end
                if r < 0.20 then out.land = false end
                if r < 0.25 then out.sc = false end                           -- 連携が起きない
                if r < 0.30 then out.sc = '光' end                            -- 想定外の連携名 (SC_MSG に無い)
                if id == 502 and math.random() < 0.7 then out.mb = true end
            end
            return out
        end})
        W.go()
        local stopped_at, n_at_stop
        W.run_until(200, function(t)
            if not stopped_at then
                -- 終了判定: run が nil になった (チャットに 中止/完了 が出た)
                if W.log_has('中止しました') or W.log_has('完了しました') or W.log_has('マジックバースト成功') or W.log_has('MB なし') or W.log_has('MB になりませんでした') then
                    stopped_at = t; n_at_stop = #W.sent
                end
            end
        end)
        if not stopped_at then hung = hung + 1 end
        if stopped_at then check(#W.sent == n_at_stop, "fuzz #" .. i .. ": 終わったあとに入力が送られた") end
        if #W.sent > max_sent then max_sent = #W.sent end
    end
    check(hung == 0, "fuzz: 200 秒以内に終わらないものがあった (" .. hung .. " 件)")
    check(max_sent <= 17 + 8, "fuzz: 入力の最大回数が上限を超えた (" .. max_sent .. ")")
    io.write(string.format("fuzz %d 回: 最大の入力回数 %d / 終わらない %d\n", FUZZ, max_sent, hung))
end

io.write(string.format("== %d 件中 %d 件失敗\n", total, fails))
os.exit(fails == 0 and 0 or 1)
