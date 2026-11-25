-- Melton6.lua を変更せずに読み込み、Windower とゲームの応答を模擬して、手順の動きを確かめる (Lua 5.1)
-- 使い方: lua5.1 sim.lua <Melton6.lua> <res フォルダー> [fuzz 回数]
local SRC, RESDIR, FUZZ = arg[1], arg[2], tonumber(arg[3])
local fails, total = 0, 0
local function check(c, m) total = total + 1; if not c then fails = fails + 1; io.write("NG: " .. m .. "\n") end end

local res_ja = assert(loadfile(RESDIR .. '/job_abilities.lua'))()
local res_sp = assert(loadfile(RESDIR .. '/spells.lua'))()
local res_bf = assert(loadfile(RESDIR .. '/buffs.lua'))()
local JA_ID, SP_ID = {}, {}
for id, r in pairs(res_ja) do if type(r) == 'table' and r.ja then JA_ID[r.ja] = id end end
for id, r in pairs(res_sp) do if type(r) == 'table' and r.ja then SP_ID[r.ja] = id end end

local ME, TID = 1, 500
local SC_MSG = {['切断'] = 299, ['炸裂'] = 300, ['重力'] = 290}
local SC_OF_N = {[1] = false, [2] = '切断', [3] = '炸裂', [4] = '切断', [5] = '炸裂', [6] = '重力'}   -- 魔法の何発目か (使い直しの無い通常時)

-- config の模擬 (libs/config.lua の動きに合わせる):
--   ・settings.xml の値は文字列。読むときに true/false → 真偽値、数字 → 数値 に変える (settings_table)
--   ・読み込み (load)・ログイン・ログアウトのたびに読み直し、同じ表に上書きする (merge)。そのあと register の関数を呼ぶ
--   ・merge は、元が数値で XML が数字でない文字列なら 16 進数として読む (abc → 2748)。読めなければ文字列のまま入れる
--   ・global のあとにキャラクター別 (名前の小文字) の値を重ねる。保存はキャラクター別に書く
--   ・ログインしていないと save は何もしない
local function xml_value(v)
    if type(v) == 'table' then local t = {} for k, x in pairs(v) do t[k] = xml_value(x) end return t end
    if type(v) ~= 'string' then return v end
    if v:lower() == 'true' then return true elseif v:lower() == 'false' then return false end
    local n = tonumber(v)
    if n ~= nil then return n end
    return v
end
local function xml_text(v)
    if type(v) == 'table' then local t = {} for k, x in pairs(v) do t[k] = xml_text(x) end return t end
    return tostring(v)
end
local function config_merge(t, m)
    for k, v in pairs(m or {}) do
        local old = rawget(t, k)
        if type(old) == 'table' and type(v) == 'table' then config_merge(old, v)
        elseif old ~= nil and type(old) ~= type(v) then
            if type(old) == 'number' and type(v) == 'string' then t[k] = tonumber(v) or tonumber(v, 16) or v
            elseif type(old) == 'string' and type(v) == 'table' and next(v) == nil then t[k] = ''
            else t[k] = v end
        else t[k] = v end
    end
end
local function deep_copy(v)
    if type(v) ~= 'table' then return v end
    local t = {} for k, x in pairs(v) do t[k] = deep_copy(x) end return t
end

-- 世界を作る。behave(kind, id, n) が応答を決める: nil = 応答しない / table = {delay=, ...}
local function run_world(opts)
    opts = opts or {}
    local T, queue, handlers, sent, chat = 0, {}, {}, {}, {}
    local buffs = opts.buffs or {}
    local target_id = TID
    local saved, saves = nil, 0
    local loaded
    local logged_in = not opts.logged_out
    local file = deep_copy(opts.xml or {})   -- settings.xml の中身 {global = {...}, me = {...}} (値は文字列)
    local refresh = {}
    local env
    local function reload()
        if not loaded then return end
        config_merge(loaded, xml_value(file.global))
        if logged_in then config_merge(loaded, xml_value(file.me)) end
        for _, fn in ipairs(refresh) do fn(loaded) end
    end
    env = {
        _addon = {}, pairs = pairs, ipairs = ipairs, tonumber = tonumber, tostring = tostring, type = type, pcall = pcall,
        string = string, table = table, math = math, setmetatable = setmetatable, rawget = rawget, select = select, error = error,
        os = {clock = function() return T end},
        require = function(n)
            if n == 'config' then
                for _, ev in ipairs{'load', 'login', 'logout'} do handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], reload) end
                return {
                    load = function(d)
                        local s = deep_copy(d)
                        for k, v in pairs(opts.settings or {}) do s[k] = deep_copy(v) end
                        loaded = s
                        config_merge(s, xml_value(file.global))
                        if logged_in then config_merge(s, xml_value(file.me)) end
                        return s
                    end,
                    save = function(value)
                        if not logged_in then return end
                        saved = value; saves = saves + 1
                        file.me = xml_text(value)
                    end,
                    register = function(_, fn) refresh[#refresh + 1] = fn end,
                }
            end
            if n == 'resources' then return {job_abilities = res_ja, spells = res_sp, buffs = res_bf} end
            error('no module ' .. n)
        end,
        windower = {
            to_shift_jis = function(s) return opts.encode and opts.encode(s) or s end,
            from_shift_jis = function(s) return opts.decode and opts.decode(s) or s end,
            convert_auto_trans = function(s) return opts.auto_translate and opts.auto_translate(s) or s end,
            register_event = function(ev, fn) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], fn) end,
            add_to_chat = function(c, t) chat[#chat + 1] = t end,
            send_command = function(c) sent[#sent + 1] = {t = T, cmd = c} end,
            ffxi = {
                get_party = function() if opts.solo then return {p0 = {name = "Me"}} end return {p0 = {name = "Me"}, p1 = {name = "Friend"}} end,
                get_player = function() return {id = ME, name = 'Me', main_job = 'SCH', status = 1, buffs = buffs, vitals = {mp = 2000, max_mp = 2000}} end,
                get_info = function() return {logged_in = logged_in} end,
                get_mob_by_target = function() if opts.no_target then return nil end return {id = target_id, name = 'Mob', valid_target = true, hpp = 100, spawn_type = 16, distance = 100} end,
                get_spell_recasts = function() return {} end,
                get_ability_recasts = function() return opts.recasts or {} end,
            },
        },
    }
    env._G = env
    local chunk = assert(loadfile(SRC)); setfenv(chunk, env); chunk()
    local function fire(ev, ...) for _, fn in ipairs(handlers[ev] or {}) do fn(...) end end
    fire('load')   -- Windower は読み込みの直後に load を起こす (config はここで settings.xml を読み直す)
    local function after(d, fn) queue[#queue + 1] = {at = T + d, fn = fn} end
    local W = {sent = sent, chat = chat, fire = fire}
    W.saved = function() return saved, saves end
    W.loaded = function() return loaded end
    W.file = function() return file end
    W.login = function() logged_in = true; fire('login') end
    W.logout = function() logged_in = false; fire('logout') end
    -- 自分以外 (actor) や別の魔法の action を、そのまま起こす
    W.inject = function(d, act) after(d, function() fire('action', act) end) end
    local n_ja, n_ma = 0, 0
    local behave = opts.behave or function() return {} end
    W.set_target = function(id) target_id = id end
    -- 入力の送信を、応答に変える
    local orig_send = env.windower.send_command
    env.windower.send_command = function(c)
        if c:match("^input /p ") and opts.say_error then error("party send failed") end
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

-- S1 正常: 16 回送る / MB 成功 (1.0.2 で大悟徹底を外した)
do
    local W = run_world({behave = function(k, id) if k == 'ma' and id == 502 then return {mb = true, cast = 2} end return {} end})
    W.go(); W.run_until(90)
    if os.getenv('DBG') then for _, c in ipairs(W.chat) do print('  chat:', c) end for _, s2 in ipairs(W.sent) do print(string.format('  %.2f %s', s2.t, s2.cmd)) end end
    check(#W.sent == 16, "S1 正常: 入力は 16 回 (実際 " .. #W.sent .. ")")
    check(W.log_has('マジックバースト成功'), "S1 メルトンで MB 成功を表示する")
    local names = W.names()
    local want = {'連環計', '黒のグリモア', '震天動地の章', 'エアロ', '震天動地の章', 'ストーン', '震天動地の章', 'エアロ', '震天動地の章', '土門の計', '震天動地の章', '風門の計', '震天動地の章', '闇門の計', '気炎万丈の章', 'メルトン'}
    for i, w in ipairs(want) do check(names[i] == w, "S1 順序 " .. i .. ": 期待 " .. w .. " / 実際 " .. tostring(names[i])) end
    local before = #W.sent
    W.run_until(120)
    check(#W.sent == before, "S1 完了後は何も送らない")
end

-- S12 最後の重力のあとは post_final_sec (3.0・魔法のあとの硬直) 待って気炎万丈の章: メルトンは受付 7 秒より前に着弾 (1.0.2)
do
    -- 実機に近い遅れ: アビの実行 0.6 秒・メルトンの詠唱 0.8 秒
    local W = run_world({buffs = {377, 359}, behave = function(k, id)
        if k == 'ja' then return {delay = 0.6} end
        if id == 502 then return {mb = true, cast = 0.8} end
        return {}
    end})
    W.go(); W.run_until(90)
    local t = {}
    for _, s2 in ipairs(W.sent) do local n = s2.cmd:match('"([^"]+)"'); t[n] = t[n] or {}; table.insert(t[n], s2.t) end
    local sc_land = t['闇門の計'][1] + 0.3 + 1.5     -- 闇門の計: 送信 → 詠唱開始 0.3 → 着弾 1.5 (sim の既定)
    local melton_land = t['メルトン'][1] + 0.3 + 0.8
    check(t['気炎万丈の章'][1] - sc_land >= 3.0, string.format("S12 重力の着弾から気炎万丈の章まで 3.0 秒以上 (実際 %.2f)", t['気炎万丈の章'][1] - sc_land))
    check(melton_land - sc_land < 7.0, string.format("S12 メルトンは重力から 7 秒以内に着弾 (実際 %.2f)", melton_land - sc_land))
    check(t['大悟徹底'] == nil, "S12 大悟徹底は使わない")
    check(W.log_has('受付 7.0秒'), "S12 結果に MB 受付 7.0 秒を出す")
    if os.getenv('DBG') then print(string.format('  S12 重力→メルトン着弾 %.2f 秒', melton_land - sc_land)) end
end

-- S2 連環計・黒のグリモアが効果中なら飛ばす: 14 回
do
    local W = run_world({buffs = {377, 359}, behave = function(k, id) if k == 'ma' and id == 502 then return {mb = true} end return {} end})
    W.go(); W.run_until(90)
    check(#W.sent == 14, "S2 効果中は飛ばす: 14 回 (実際 " .. #W.sent .. ")")
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

-- S6 気炎万丈の章が実行されなければ、使い直さずにメルトンの前で止まる
do
    local W = run_world({buffs = {377, 359}, behave = function(k, id) if k == 'ja' and id == 221 then return nil end return {} end})
    W.go(); W.run_until(90)
    local n_ebu, kaustra = 0, false
    for _, n in ipairs(W.names()) do if n == 'メルトン' then kaustra = true end if n == '気炎万丈の章' then n_ebu = n_ebu + 1 end end
    check(not kaustra and W.log_has('気炎万丈の章 が実行されませんでした'), "S6 気炎が不発ならメルトンを撃たずに止まる")
    check(n_ebu == 1, "S6 気炎万丈の章は使い直さない (実際 " .. n_ebu .. " 回)")
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
    check(#W.sent == n, "S9 //m6 stop のあとは送らない (止める前 " .. n .. " / 後 " .. #W.sent .. ")")
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

-- 強化の選択とセリフの保存・入力検査・送信を確かめる。

for _, mode in ipairs{"ebullience", "enlightenment", "both", "none"} do
    local W = run_world({settings = {boost = mode}, buffs = {377, 359}})
    W.go(); W.run_until(120)
    local suffix = {}
    for _, v in ipairs(W.sent) do
        local name = v.cmd:match('^input /ja "([^"]+)"')
        if name == res_ja[221].ja or name == res_ja[244].ja then suffix[#suffix + 1] = name end
    end
    local expected = mode == "both" and {res_ja[244].ja, res_ja[221].ja} or
        mode == "none" and {} or {res_ja[mode == "enlightenment" and 244 or 221].ja}
    check(table.concat(suffix, ",") == table.concat(expected, ","), "boost sequence: " .. mode)
    check(W.sent[#W.sent].cmd:find(res_sp[502].ja, 1, true), "final spell: " .. mode)
    W.fire('addon command', 'status')
    check(W.log_has('boost = ' .. mode), "status: " .. mode)
end
for _, mode in ipairs{"enlightenment", "both"} do
    local W = run_world({settings = {boost = mode}, buffs = {377, 359}, behave = function(k, id)
        if k == 'ja' and id == 244 then return nil end return {} end})
    W.go(); W.run_until(120)
    local n = 0
    for _, v in ipairs(W.sent) do
        check(not v.cmd:find(res_sp[502].ja, 1, true), "failed boost blocks final spell")
        check(not v.cmd:find(res_ja[221].ja, 1, true), "failed first boost blocks second")
        if v.cmd:find(res_ja[244].ja, 1, true) then n = n + 1 end
    end
    check(n == 1, "failed boost is not retried")
end
for _, mode in ipairs{"ebullience", "enlightenment", "both", "none"} do
    local W = run_world()
    W.fire('addon command', 'boost', mode)
    local saved, count = W.saved()
    check(saved and saved.boost == mode and count == 1, "boost saved: " .. mode)
    saved = saved or {}
    W.fire('addon command', 'boost', 'immanence')
    local _, after = W.saved()
    check(after == count and saved.boost == mode, "invalid boost preserves settings")
end
local function say_lines(W)
    local result = {}
    for _, v in ipairs(W.sent) do if v.cmd:match('^input /p ') then result[#result + 1] = v end end
    return result
end
do
    local W = run_world({buffs = {377, 359}})
    W.fire('addon command', 'say')
    local _, count = W.saved()
    check(count == 0, "listing does not save")
    for _, key in ipairs{'start','1','2','3','4','5','6','mb'} do
        W.fire('addon command', 'say', key, 'line-' .. key)
    end
    local saved; saved, count = W.saved()
    check(saved and count == 8 and saved.say.chain1 == 'line-1', "say settings saved")
    saved = saved or {say = {}}
    W.go(); W.run_until(120)
    local lines = say_lines(W)
    check(#lines == 8, "all eight say keys sent")
    local keys = {'start','1','2','3','4','5','6','mb'}
    for i, entry in ipairs(lines) do check(entry.cmd == 'input /p line-' .. keys[i], "say order " .. i) end
    check(lines[1] and lines[1].t == 0, "start say is immediate")
    local last = W.sent[#W.sent]
    check(lines[8] and lines[8].t == last.t, "mb say adds no wait")
    W.fire('addon command', 'say', 'start', 'off')
    check(saved.say.start == '', "off clears say")
end
do
    local W = run_world()
    W.fire('addon command', 'say', 'start', 'keep')
    local saved, before = W.saved()
    saved = saved or {say = {}}
    for _, text in ipairs{'/echo unsafe', '  /echo unsafe', 'hello;input /echo unsafe', 'line\nnext', 'line\rnext', 'line\tnext', string.char(0), string.char(127), string.rep('a', 101)} do
        local n = #W.chat
        W.fire('addon command', 'say', 'start', text)
        local _, count = W.saved()
        check(count == before and saved.say.start == 'keep', "unsafe say rejected")
        check(#W.chat == n + 1, "one refusal message")
    end
    W.fire('addon command', 'say', 'start', string.rep('a', 100))
    check(saved.say.start and #saved.say.start == 100, "100 byte say accepted")
end
for _, opts in ipairs{{solo = true}, {say_error = true}} do
    opts.settings = {say = {start = 'text', mb = 'text'}}
    opts.buffs = {377, 359}
    local W = run_world(opts)
    W.go(); W.run_until(120)
    check(#say_lines(W) == 0, "solo or send failure emits no party text")
    check(W.sent[#W.sent].cmd:find(res_sp[502].ja, 1, true), "say failure does not stop sequence")
end
for _, event in ipairs{'zone change','unload','logout'} do
    local W = run_world({settings = {say = {mb = 'not sent'}}})
    W.go(); W.run_until(3)
    local count = #W.sent
    W.fire(event); W.run_until(120)
    check(#W.sent == count, "cleanup stops all sends: " .. event)
end
do
    local W = run_world({settings = {boost = 'enlightenment'}, recasts = {[235] = 10}})
    W.go(); W.run_until(120)
    check(#W.sent == 0, "Enlightenment cooldown prevents starting")
end


do
    local W = run_world({buffs = {377, 359}})
    W.go(); W.run_until(120)
    check(#say_lines(W) == 0, "default say text is empty")
end
do
    local W = run_world({buffs = {377, 359}, settings = {say = {chain2 = 'unconfirmed'}},
        behave = function(k, id, n) if k == 'ma' and n == 2 then return {sc = false} end return {} end})
    W.go(); W.run_until(120)
    check(#say_lines(W) == 0, "no say for an unconfirmed skillchain")
end
do
    local W = run_world({settings = {say = {start = '/unsafe', mb = 'bad;command'}}})
    W.go(); W.run_until(120)
    check(#say_lines(W) == 0, "loaded unsafe say text is disabled")
end
do
    local W = run_world({encode = function(s) return string.rep('x', #s * 2) end})
    W.fire('addon command', 'say', 'start', string.rep('a', 50))
    local saved, count = W.saved()
    check(saved and #saved.say.start == 50 and count == 1, "encoded 100 bytes accepted")
    W.fire('addon command', 'say', 'start', string.rep('a', 51))
    local _, after = W.saved()
    check(after == count, "encoded 102 bytes rejected")
end


do
    local W = run_world({settings = {boost = 'both'}, buffs = {377, 359}, behave = function(k, id)
        if k == 'ja' and id == 221 then return nil end return {} end})
    W.go(); W.run_until(120)
    local n = 0
    for _, entry in ipairs(W.sent) do
        check(not entry.cmd:find(res_sp[502].ja, 1, true), "second failed boost blocks final spell")
        if entry.cmd:find(res_ja[221].ja, 1, true) then n = n + 1 end
    end
    check(n == 1, "second boost is not retried")
end
do
    local W = run_world({encode = function(s) if s == 'text' then error('conversion failed') end return s end})
    W.fire('addon command', 'say', 'start', 'text')
    local _, count = W.saved()
    check(count == 0, "encoding failure does not save")
end


do
    local utf8_a, sjis_a = "\227\129\130", "\130\160"
    local W = run_world({encode = function(s) return (s:gsub(utf8_a, sjis_a)) end})
    W.fire('addon command', 'say', 'start', string.rep(utf8_a, 50))
    local saved, before = W.saved()
    check(saved and saved.say.start == string.rep(utf8_a, 50), "UTF-8 text stored before conversion")
    W.fire('addon command', 'say', 'start', string.rep(utf8_a, 51))
    local _, after = W.saved()
    check(after == before, "multi-byte text rejected above 100 encoded bytes")
    W.go(); W.run_until(120)
    local lines = say_lines(W)
    check(lines[1] and lines[1].cmd == 'input /p ' .. string.rep(sjis_a, 50), "party text uses encoded bytes")
    local shown = false
    for _, line in ipairs(W.chat) do if line:find(sjis_a, 1, true) then shown = true end end
    check(shown, "say confirmation uses encoded bytes")
end


do
    local utf8_a, sjis_a = "\227\129\130", "\130\160"
    local W = run_world({decode = function(s) return (s:gsub(sjis_a, utf8_a)) end,
        auto_translate = function(s) return (s:gsub('TOKEN', sjis_a)) end,
        encode = function(s) return (s:gsub(utf8_a, sjis_a)) end})
    W.fire('addon command', 'say', 'start', string.rep(sjis_a, 50))
    local saved = W.saved()
    check(saved and saved.say.start == string.rep(utf8_a, 50), "Shift-JIS input stored as UTF-8")
    W.fire('addon command', 'say', 'mb', 'TOKEN')
    check(saved and saved.say.mb == utf8_a, "auto-translate expanded before decoding")
    W.go(); W.run_until(120)
    local lines = say_lines(W)
    check(lines[1] and lines[1].cmd == 'input /p ' .. string.rep(sjis_a, 50), "Shift-JIS input round trip")
end
do
    local W = run_world({decode = function() error('decode failed') end})
    W.fire('addon command', 'say', 'start', 'bad')
    local _, count = W.saved()
    check(count == 0 and #W.chat == 1, "decode error refused without saving")
end


do
    local W = run_world({settings = {say = {start = 123, mb = true, chain1 = 3.0,
        chain2 = false, chain3 = {}, chain4 = nil}}})
    local loaded = W.loaded()
    check(loaded.say.start == '123', "numeric say survives loading")
    check(loaded.say.mb == 'true', "true say survives loading")
    check(loaded.say.chain1 == '3', "integer say has no decimal suffix")
    check(loaded.say.chain2 == 'false', "false say survives loading")
    check(loaded.say.chain3 == '' and loaded.say.chain4 == '', "table and nil say load as empty")
    W.go(); W.run_until(120)
    local lines = say_lines(W)
    check(#lines == 4, "loaded numeric and boolean say are sent")
    check(lines[1] and lines[1].cmd == 'input /p 123', "loaded numeric say output")
end
for _, invalid in ipairs{0/0, math.huge, -math.huge, 'nan', 'inf', '-inf', 'abc'} do
    local W = run_world()
    W.fire('addon command', 'set', 'post', '4')
    local saved, count = W.saved()
    W.fire('addon command', 'set', 'post', invalid)
    local _, after = W.saved()
    check(after == count and saved.post_land_sec == 4, "non-finite or invalid set preserves value")
    check(W.log_has("有限の数字で指定してください"), "invalid set explains numeric input")
end
for _, invalid in ipairs{0/0, math.huge, -math.huge, 'nan', 'inf', '-inf'} do
    local W = run_world({settings = {post_land_sec = invalid}})
    check(W.loaded().post_land_sec == 3.0, "non-finite loaded setting uses default")
    local _, count = W.saved()
    check(count == 0, "invalid loaded setting does not save")
    check(#W.chat == 0, "invalid loaded setting is silent")
end

-- ---------------------------------------------------------------------------
-- 独立レビューの指摘への確認 (R + 指摘の番号)
-- ---------------------------------------------------------------------------
local function count_log(W, s) local n = 0 for _, c in ipairs(W.chat) do if c:find(s, 1, true) then n = n + 1 end end return n end
local function sent_name(W, name) for _, n in ipairs(W.names()) do if n == name then return true end end return false end

-- R1 settings.xml の範囲外・数字でない値は、読み直し (load・logout・login) のあとも範囲に収まる
do
    local W = run_world({buffs = {377, 359}, xml = {global = {ja_retries = '99', post_land_sec = '-3', ja_gap_sec = '0', land_timeout_sec = 'zz'}},
        behave = function(k) if k == 'ja' then return nil end return {} end})
    local s = W.loaded()
    check(s.ja_retries == 2 and s.post_land_sec == 0 and s.ja_gap_sec == 0.5,
        string.format("R1 load の読み直しのあとも範囲内 (retries %s / post %s / gap %s)", tostring(s.ja_retries), tostring(s.post_land_sec), tostring(s.ja_gap_sec)))
    check(s.land_timeout_sec == 12.0, "R1 数字でない文字列 (zz) は既定値に戻す (実際 " .. tostring(s.land_timeout_sec) .. ")")
    W.logout(); W.login()
    check(s.ja_retries == 2, "R1 ログアウト・ログインの読み直しのあとも範囲内 (実際 " .. tostring(s.ja_retries) .. ")")
    local ok = pcall(function() W.go(); W.run_until(300) end)
    check(ok and #W.sent == 3, "R1 ja_retries=99 でも使い直しは 2 回まで (実際 " .. #W.sent .. " 回送った)")
end
do
    -- config は、元が数値の項目に数字でない文字列が来ると 16 進数として読む (abc → 2748)。それでも範囲に収める
    local W = run_world({xml = {global = {ja_retries = 'abc', post_land_sec = 'abc'}}})
    local s = W.loaded()
    check(type(s.ja_retries) == 'number' and s.ja_retries >= 0 and s.ja_retries <= 2 and s.ja_retries % 1 == 0,
        "R1 ja_retries=abc は読み直しのあとも 0〜2 の整数 (実際 " .. tostring(s.ja_retries) .. ")")
    check(type(s.post_land_sec) == 'number' and s.post_land_sec >= 0 and s.post_land_sec <= 10,
        "R1 post_land_sec=abc は読み直しのあとも 0〜10 (実際 " .. tostring(s.post_land_sec) .. ")")
end
do
    -- キャラクター別の値も同じ。boost と use_tabula_rasa の型も直す
    local W = run_world({xml = {global = {ja_retries = '1'}, me = {ja_retries = '99', boost = 'bogus', use_tabula_rasa = 'yes'}}})
    local s = W.loaded()
    check(s.ja_retries == 2, "R1 キャラクター別の ja_retries=99 も範囲内 (実際 " .. tostring(s.ja_retries) .. ")")
    check(s.boost == 'ebullience', "R1 知らない boost は既定値 (実際 " .. tostring(s.boost) .. ")")
    check(s.use_tabula_rasa == true, "R1 真偽値でない use_tabula_rasa は既定値 (実際 " .. tostring(s.use_tabula_rasa) .. ")")
    local ok = pcall(W.fire, 'addon command', 'status')
    check(ok, "R1 status が落ちない")
end
do
    local W = run_world()
    W.fire('addon command', 'set', 'retries', '2'); W.fire('addon command', 'set', 'post', '4.5')
    W.logout(); W.login()
    check(W.loaded().ja_retries == 2 and W.loaded().post_land_sec == 4.5, "R1 保存した値は読み直しのあとも同じ")
end

-- R2 数字・真偽値だけのセリフは、保存して読み直したあとも文字列
do
    local W = run_world({buffs = {377, 359}})
    W.fire('addon command', 'say', 'start', '123')
    W.fire('addon command', 'say', 'mb', 'true')
    check(W.file().me and W.file().me.say.start == '123', "R2 settings.xml には 123 が書かれる")
    W.logout(); W.login()
    local s = W.loaded()
    check(type(s.say.start) == 'string' and s.say.start == '123', "R2 say start=123 は読み直しのあとも文字列 (実際 " .. type(s.say.start) .. ")")
    check(s.say.mb == 'true', "R2 say mb=true は読み直しのあとも文字列 (実際 " .. type(s.say.mb) .. ")")
    local ok = pcall(W.fire, 'addon command', 'say')
    check(ok and W.log_has('say mb = true'), "R2 //m6 say の一覧が落ちない")
    W.go(); W.run_until(120)
    local lines = say_lines(W)
    check(lines[1] and lines[1].cmd == 'input /p 123', "R2 読み直したセリフ 123 を送る")
    check(lines[#lines] and lines[#lines].cmd == 'input /p true', "R2 読み直したセリフ true を送る")
end
do
    -- 読み直しで入った危ないセリフも、検査で空にする
    local W = run_world({xml = {global = {say = {start = '/echo x', mb = 'a;b'}}}})
    check(W.loaded().say.start == '' and W.loaded().say.mb == '', "R2 読み直した危ないセリフは空にする")
    -- 数値にすると形が変わるもの (007 → 7) は戻せない。落ちずに文字列になることだけを確かめる
    local W2 = run_world({xml = {global = {say = {chain1 = '007'}}}})
    check(W2.loaded().say.chain1 == '7', "R2 007 は 7 になる (config の型変換・既知の制限)")
end

-- R3 開始前の確認: 黒のグリモアの再使用・行動を妨げる状態異常・連環計の残り時間の知らせ
do
    local W = run_world({buffs = {377}, recasts = {[232] = 30}})
    W.go(); W.run_until(30)
    check(#W.sent == 0 and W.log_has('黒のグリモアの再使用まで 30秒'), "R3 黒のグリモアの再使用中は始めない (送った " .. #W.sent .. ")")
    local W2 = run_world({buffs = {377, 359}, recasts = {[232] = 30}})
    W2.go(); W2.run_until(5)
    check(#W2.sent > 0, "R3 黒のグリモアの効果中なら、その再使用は見ない")
end
for _, b in ipairs{{6, '静寂'}, {29, '沈黙'}, {16, 'アムネジア'}, {2, '睡眠'}, {10, 'スタン'}, {7, '石化'}, {28, 'テラー'}, {14, '魅了'}} do
    local W = run_world({buffs = {377, 359, b[1]}})
    W.go(); W.run_until(30)
    check(#W.sent == 0 and W.log_has(b[2] .. ' のため行動できません'), "R3 " .. b[2] .. " 中は始めない (送った " .. #W.sent .. ")")
end
do
    local W = run_world({buffs = {377, 359}})
    W.go()
    check(W.log_has('残り時間は取れないため'), "R3 連環計の効果中から始めるときは、残りを確かめるよう知らせる")
    local W2 = run_world()
    W2.go()
    check(not W2.log_has('残り時間は取れないため'), "R3 連環計を使うところから始めるときは知らせない")
end

-- R4 MB 受付に最短の詠唱でも間に合わないなら、メルトン (と mb のセリフ) を送らない
do
    -- 重力の着弾 + 5.0 (postfinal) + 0.3 (気炎の実行) + 1.5 (gap) = 6.8 秒で送る。最短の詠唱 1.0 秒で 7.8 > 7.0
    local W = run_world({buffs = {377, 359}, settings = {post_final_sec = 5, ja_gap_sec = 1.5, say = {mb = 'mb-line'}}})
    W.go(); W.run_until(120)
    check(not sent_name(W, 'メルトン'), "R4 受付切れが確定していればメルトンを送らない")
    check(W.log_has('MB 受付に間に合わないため'), "R4 理由を知らせる")
    check(#say_lines(W) == 0, "R4 mb のセリフも送らない")
    -- 5.8 秒で送るなら、最短の詠唱 1.0 秒で 6.8 < 7.0: 送る
    local W2 = run_world({buffs = {377, 359}, settings = {post_final_sec = 5, ja_gap_sec = 0.5}})
    W2.go(); W2.run_until(120)
    check(sent_name(W2, 'メルトン'), "R4 最短の詠唱で間に合うなら送る")
end

-- R8 詠唱開始 (category 8) を取りこぼしても、自分の同じ魔法の着弾で進む
do
    local W = run_world({buffs = {377, 359}, behave = function(k, id) if k == 'ma' then return {begin = false, mb = id == 502} end return {} end})
    W.go(); W.run_until(120)
    check(#W.sent == 14 and W.log_has('マジックバースト成功'), "R8 詠唱開始が届かなくても、着弾で最後まで進む (送った " .. #W.sent .. ")")
end
-- 他人の action・別の魔法の着弾では進まない
for _, case in ipairs{'other_actor', 'other_spell', 'other_spell_no_begin'} do
    local W
    W = run_world({buffs = {377, 359}, behave = function(k, id, n)
        if k == 'ma' and n == 1 then
            if case == 'other_actor' then
                W.inject(0.3, {category = 8, actor_id = 77, param = 24931, targets = {{id = TID, actions = {{param = id}}}}})
                W.inject(1.0, {category = 4, actor_id = 77, param = id, targets = {{id = TID, actions = {{message = 2}}}}})
            else
                if case == 'other_spell' then
                    W.inject(0.3, {category = 8, actor_id = ME, param = 24931, targets = {{id = TID, actions = {{param = id}}}}})
                end
                W.inject(1.0, {category = 4, actor_id = ME, param = 159, targets = {{id = TID, actions = {{message = 2}}}}})
            end
            return nil
        end
        return {}
    end})
    W.go(); W.run_until(60)
    check(#W.sent == 2 and not sent_name(W, 'ストーン') and W.log_has('中止しました'), "R8 " .. case .. " では進まずに止まる (送った " .. #W.sent .. ")")
end

-- R9 ログイン前は保存されないことを知らせる
do
    local W = run_world({logged_out = true})
    W.fire('addon command', 'boost', 'none')
    W.fire('addon command', 'set', 'post', '4')
    W.fire('addon command', 'tabula')
    W.fire('addon command', 'say', 'start', 'x')
    local _, count = W.saved()
    check(count == 0, "R9 ログイン前は保存しない")
    check(count_log(W, '保存されません') == 4, "R9 4 つのコマンドそれぞれで、保存されないことを知らせる (実際 " .. count_log(W, '保存されません') .. ")")
    local W2 = run_world()
    W2.fire('addon command', 'boost', 'none')
    check(not W2.log_has('保存されません'), "R9 ログイン中は知らせない")
end

-- R10 retries は整数だけ / set の名前違いは理由を出す / ヘルプに全部の set がある
do
    local W = run_world()
    W.fire('addon command', 'set', 'retries', '1.5')
    local _, count = W.saved()
    check(W.loaded().ja_retries == 1 and count == 0 and W.log_has('整数で'), "R10 retries 1.5 は受け付けない")
    W.fire('addon command', 'set', 'retries', '2')
    check(W.loaded().ja_retries == 2, "R10 retries 2 は受け付ける")
    W.fire('addon command', 'set', 'retry', '1')
    check(W.log_has('設定の名前が違います: retry'), "R10 set の名前違いは理由を出す")
    W.fire('addon command')
    for _, k in ipairs{'post', 'postfinal', 'gap', 'jatimeout', 'boosttimeout', 'retries', 'casttimeout', 'landtimeout'} do
        check(W.log_has('//m6 set ' .. k .. ' '), "R10 ヘルプに set " .. k .. " がある")
    end
end

-- R6 制御文字 (0x00-0x1F・0x7F) はすべて断る。0x80 以上のバイト (Shift-JIS など) は断らない
do
    local W = run_world()
    for b = 0, 31 do
        W.fire('addon command', 'say', 'start', 'a' .. string.char(b) .. 'b')
    end
    W.fire('addon command', 'say', 'start', 'a' .. string.char(127) .. 'b')
    local _, count = W.saved()
    check(count == 0, "R6 制御文字を含むセリフは保存しない (保存 " .. count .. ")")
    W.fire('addon command', 'say', 'start', string.char(130, 160, 133, 64))
    local _, after = W.saved()
    check(after == 1, "R6 0x80 以上のバイトは断らない")
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
                if W.log_has('中止しました') or W.log_has('マジックバースト成功') or W.log_has('MB なし') or W.log_has('MB になりませんでした') then
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
