local P = {}

local function print(obj, msg)
  obj.load("figure", "\148\119\140\105", 0, 1, 1)
  obj.alpha = 0.75
  obj.draw()
  obj.setfont("MS UI Gothic", 16, 0, "0xffffff", "0x000000")
  obj.load("text", "<s,,B>" .. msg)
  obj.draw()
  -- テキストのぼやけ防止
  obj.ox = obj.w % 2 == 1 and 0.5 or 0
  obj.oy = obj.h % 2 == 1 and 0.5 or 0
end

local function getpixeldata(obj, width, height)
  local maxw, maxh = obj.getinfo("image_max")
  if width > maxw then
    width = maxw
  end
  if height > maxh then
    height = maxh
  end
  obj.setoption("drawtarget", "tempbuffer", width, height)
  obj.load("tempbuffer")
  return obj.getpixeldata("work")
end

local function fileexists(filepath)
  local f = io.open(filepath, "rb")
  if f ~= nil then
    f:close()
    return true
  end
  return false
end

local PSDState = {}

-- スクリプトから呼び出す用
function PSDState.init(obj, o)
  local r = PSDState.new(
    (o.scene or 0)*1000+obj.layer,
    o.ptkf ~= "" and o.ptkf or nil,
    {
      layer = o.ptkl ~= "" and o.ptkl or nil,
      lipsync = o.lipsync ~= 0 and o.lipsync or nil,
      mpslider = o.mpslider ~= 0 and o.mpslider or nil,
    }
  )
  -- 何も出力しないと直後のアニメーション効果以外適用されないため
  -- それに対するワークアラウンド
  mes(" ")

  local subobj
  if o.mpslider ~= 0 then
    subobj = r.valueholder or P.emptysubobj
  elseif o.lipsync ~= 0 then
    subobj = r.talkstate ~= nil and r.talkstate.threshold ~= -1 and r.talkstate or P.emptysubobj
  else
    subobj = P.emptysubobj
  end
  return r, subobj
end

-- PSDオブジェクト
-- id - 固有識別番号
-- file - PSDファイルへのパス
-- opt - 追加の設定項目
-- opt には以下のようなオブジェクトを渡す
-- {
--   layer = "レイヤーの初期状態",
--   lipsync = 2,
--   mpslider = 3,
-- }
function PSDState.new(id, file, opt)
  local self = setmetatable({
    id = id,
    file = file,
    layer = {opt.layer or "L.0"},
    scale = 1,
    offsetx = 0,
    offsety = 0,
    valueholder = nil,
    talkstate = nil,
    talkstateindex = nil,
    rendered = false,
  }, {__index = PSDState})
  if opt.lipsync ~= nil then
    self.talkstate = P.talk:get(opt.lipsync)
    self.talkstateindex = opt.lipsync
  end
  if opt.mpslider ~= nil then
    self.valueholder = P.valueholder:get(opt.mpslider)
  end
  return self
end

function PSDState:addstate(layer, index)
  -- index が指定されていない場合は layer の内容を直接追加
  if index == nil then
    if layer ~= nil and layer ~= "" then
      table.insert(self.layer, layer)
    end
    return
  end

  -- index が指定されている場合は layer 内の項目のひとつを割り当てるが、
  -- もし valueholder が存在する場合は index を上書きする
  if self.valueholder ~= nil then
    index = self.valueholder:get(index, 0)
  end
  -- 値が範囲外でなければ割り当て
  if 0 < index and index <= #layer then
    table.insert(self.layer, layer[index])
  end
end

function PSDState:adjustcenter(obj)
  obj.ox = obj.w % 2 == 1 and 0.5 or 0
  obj.oy = obj.h % 2 == 1 and 0.5 or 0
end

function PSDState:render(obj)
  if self.rendered then
    error("already rendered")
  end
  if self.file == nil then
    error("no image")
  end
  self.rendered = true
  if #self.layer > 0 then
    local layer = {}
    for i, v in ipairs(self.layer) do
      local typ = type(v)
      if typ == "string" then
        table.insert(layer, v)
      elseif typ == "table" and type(v.getstate) == "function" then
        table.insert(layer, v:getstate(self, obj))
      end
    end
    self.layer = table.concat(layer, " ")
  end
  local PSDToolKitBridge = require("PSDToolKitBridge")
  local modified, width, height = PSDToolKitBridge.setprops(self.id, self.file, self)
  local cacheid = "cache:"..self.id.." "..self.file
  if not modified then
    if obj.copybuffer("obj", cacheid) then
      self:adjustcenter(obj)
      return
    end
    local data, w, h = getpixeldata(obj, width, height)
    if pcall(PSDToolKitBridge.getcache, cacheid, data, w * 4 * h) then
      obj.putpixeldata(data)
      obj.copybuffer(cacheid, "obj")
      self:adjustcenter(obj)
      return
    end
  end
  local data, w, h = getpixeldata(obj, width, height)
  PSDToolKitBridge.draw(self.id, self.file, data, w, h)
  PSDToolKitBridge.putcache(cacheid, data, w * 4 * h, false)
  obj.putpixeldata(data)
  obj.copybuffer(cacheid, "obj")
  self:adjustcenter(obj)
end

local Blinker = {}

-- 瞬きアニメーター
-- patterns - {'閉じ', 'ほぼ閉じ', '半開き', 'ほぼ開き', '開き'} のパターンが入った配列（ほぼ閉じ、半目、ほぼ開きは省略可）
-- interval - アニメーション間隔(秒)
-- speed - アニメーション速度
-- offset - アニメーション開始位置
function Blinker.new(patterns, interval, speed, offset)
  if #patterns > 3 then
    -- 3コマ以上あるなら先頭に「ほぼ開き」相当のものを挿入して
    -- 開き→ほぼ開き→閉じ→ほぼ閉じ→半目→ほぼ開き→開き　のように
    -- 閉じ始めるアニメーションの直後、閉じに移行するようにする
    table.insert(patterns, 1, patterns[#patterns-1])
  end
  return setmetatable({
    patterns = patterns,
    interval = interval,
    speed = speed,
    offset = offset
  }, {__index = Blinker})
end

function Blinker:getstate(psd, obj)
  if #self.patterns < 2 then
    error("目パチには少なくとも「開き」「閉じ」のパターン設定が必要です")
  end
  local interval = self.interval * obj.framerate + self.speed * #self.patterns*2;
  local basetime = obj.frame + interval + self.offset
  local blink = basetime % interval
  local blink2 = (basetime + self.speed*#self.patterns) % (interval * 5)
  for i, v in ipairs(self.patterns) do
    local l = self.speed*i
    local r = l + self.speed
    if (l <= blink and blink < r)or(l <= blink2 and blink2 < r) then
      return v
    end
  end
  return self.patterns[#self.patterns]
end

local LipSyncSimple = {}

-- 口パク（開閉のみ）
-- patterns - {'閉じ', 'ほぼ閉じ', '半開き', 'ほぼ開き', '開き'} のパターンが入った配列（ほぼ閉じ、半目、ほぼ開きは省略可）
-- speed - アニメーション速度
-- alwaysapply - 口パク準備のデータがなくても閉じを適用する
function LipSyncSimple.new(patterns, speed, alwaysapply)
  return setmetatable({
    patterns = patterns,
    speed = speed,
    alwaysapply = alwaysapply,
  }, {__index = LipSyncSimple})
end

LipSyncSimple.states = {}

function LipSyncSimple:getstate(psd, obj)
  if #self.patterns < 2 then
    error("口パクには少なくとも「開き」「閉じ」のパターン設定が必要です")
  end
  if psd.talkstateindex == nil then
    error("口パク準備があるレイヤー番号を指定してください")
  end
  local volume = 0
  if psd.talkstate ~= nil then
    volume = psd.talkstate.volume
  end

  local stat = LipSyncSimple.states[obj.layer] or {frame = obj.frame-1, n = -1, pat = 0}
  if stat.frame >= obj.frame or stat.frame + obj.framerate < obj.frame then
    -- 巻き戻っていたり、あまりに先に進んでいるようならアニメーションはリセットする
    -- プレビューでコマ飛びする場合は正しい挙動を示せないので、1秒の猶予を持たせる
    stat.n = -1
    stat.pat = 0
  end
  stat.n = stat.n + 1
  stat.frame = obj.frame
  if stat.n >= self.speed then
    if volume >= 1.0 then
      if stat.pat < #self.patterns - 1 then
        stat.pat = stat.pat + 1
        stat.n = 0
      end
    else
      if stat.pat > 0 then
        stat.pat = stat.pat - 1
        stat.n = 0
      end
    end
  end
  LipSyncSimple.states[obj.layer] = stat
  if psd.talkstate == nil and not self.alwaysapply then
    return ""
  end
  return self.patterns[stat.pat + 1]
end

local LipSyncLab = {}

-- 口パク（あいうえお）
-- patterns - {'a'='あ', 'e'='え', 'i'='い', 'o'='お','u'='う', 'N'='ん'}
-- mode - 子音の処理モード
-- alwaysapply - 口パク準備のデータがなくても閉じを適用する
function LipSyncLab.new(patterns, mode, alwaysapply)
  if patterns.A == nil then patterns.A = patterns.a end
  if patterns.E == nil then patterns.E = patterns.e end
  if patterns.I == nil then patterns.I = patterns.i end
  if patterns.O == nil then patterns.O = patterns.o end
  if patterns.U == nil then patterns.U = patterns.u end
  return setmetatable({
    patterns = patterns,
    mode = mode,
    alwaysapply = alwaysapply,
  }, {__index = LipSyncLab})
end

LipSyncLab.states = {}

function LipSyncLab:getstate(psd, obj)
  local pat = self.patterns
  if pat.a == nil or pat.e == nil or pat.i == nil or pat.o == nil or pat.u == nil or pat.N == nil then
    error("口パクには「あ」「い」「う」「え」「お」「ん」全てのパターン設定が必要です")
  end
  if psd.talkstateindex == nil then
    error("口パク準備があるレイヤー番号を指定してください")
  end
  local ts = psd.talkstate
  if ts == nil then
    -- データが見つからなかった場合は閉じ状態にする
    return self.alwaysapply and pat.N or ""
  end

  if ts.cur == "" then
    -- 音素情報がない時は音量に応じて「あ」の形を使う
    -- （lab ファイルを使わずに「口パク　あいうえお」を使っている場合の措置）
    if ts.volume >= 1.0 then
      return pat.a
    end
    return pat.N
  end

  if self.mode == 0 then
    -- 子音処理タイプ0 -> 全て「ん」
    if ts:curisvowel() ~= 0 then
      -- 母音は設定された形をそのまま使う
      return pat[ts.cur]
    end
    return pat.N
  elseif self.mode == 1 then
    -- 子音処理タイプ1 -> 口を閉じる子音以外は前の母音を引き継ぐ
    local stat = LipSyncLab.states[obj.layer] or {frame = obj.frame-1, p = "N"}
    if stat.frame >= obj.frame or stat.frame + obj.framerate < obj.frame then
      -- 巻き戻っていたり、あまりに先に進んでいるようならアニメーションはリセットする
      -- プレビューでコマ飛びする場合は正しい挙動を示せないので、1秒の猶予を持たせる
      stat.p = "N"
    end
    stat.frame = obj.frame
    if ts:curisvowel()  == 1 then
      -- 母音は設定された形をそのまま使う（無声化母音は除外）
      stat.p = ts.cur
    elseif ts.cur == "pau" or ts.cur == "N" or ts.cur == "cl" then
      -- pau / ん / 促音（っ）
      stat.p = "N"
    else
      -- それ以外の子音ではそのまま引き継ぐ
    end
    LipSyncLab.states[obj.layer] = stat
    return pat[stat.p]
  elseif self.mode == 2 then
    -- 子音処理タイプ2 -> 口を閉じる子音以外は前後の母音の形より小さいもので補間
    if ts:curisvowel() ~= 0 then
      -- 母音は設定された形をそのまま使う
      return pat[ts.cur]
    end
    if ts.cur == "pau" or ts.cur == "N" or ts.cur == "m" or ts.cur == "p" or ts.cur == "b" or ts.cur == "v" then
      -- pau / ん / 子音（ま・ぱ・ば・ヴ行）
      return pat.N
    end
    if ts.cur == "cl" then
      -- 促音（っ）
      if ts.progress < 0.5 then
        -- ひとつ前が母音で、かつ連続した場所に存在しているなら前半はその母音の形を引き継ぐ
        if ts:previsvowel() ~= 0 and ts.prev_end == ts.cur_start then
          return pat[ts.prev]
        end
        return pat.N
      else
        -- 後半は「う」の形で引き継ぐ
        return pat.u
      end
    end
    -- 処理されなかった全ての子音のデフォルト処理
    -- 隣接する前後の母音に依存して形を決定する
    if ts.progress < 0.5 then
      -- 前半は前の母音を引き継ぐ
      if ts:previsvowel() ~= 0 and ts.prev_end == ts.cur_start then
        -- 前の母音よりなるべく小さい開け方になるように
        if ts.prev == "a" or ts.prev == "A" then
          return pat.o
        elseif ts.prev == "i" or ts.prev == "I" then
          return pat.i
        else
          return pat.u
        end
      end
      return pat.N
    else
      -- 後半は後ろの母音を先行させる
      if ts:nextisvowel() ~= 0 and ts.next_start == ts.cur_end then
        -- 前の母音よりなるべく小さい開け方になるように
        if ts.next == "a" or ts.next == "A" then
          return pat.o
        elseif ts.next == "i" or ts.next == "I" then
          return pat.i
        else
          return pat.u
        end
      end
      return pat.N
    end
  end
  error("unexpected consonant processing mode")
end

local TalkState = {}

function TalkState.isvowel(p)
  if p == "a" or p == "e" or p == "i" or p == "o" or p == "u" then
    return 1
  end
  if p == "A" or p == "E" or p == "I" or p == "O" or p == "U" then
    return -1
  end
  return 0
end

function TalkState.new(frame, time, totalframe, totaltime)
  return setmetatable({
    used = false,
    frame = frame,
    time = time,
    totalframe = totalframe,
    totaltime = totaltime,
    volume = 0,
    threshold = -1,
    progress = 0,
    cur = "",
    cur_start = 0,
    cur_end = 0,
    prev = "",
    prev_start = 0,
    prev_end = 0,
    next = "",
    next_start = 0,
    next_end = 0
  }, {__index = TalkState})
end

function TalkState:curisvowel()
  return TalkState.isvowel(self.cur)
end

function TalkState:previsvowel()
  return TalkState.isvowel(self.prev)
end

function TalkState:nextisvowel()
  return TalkState.isvowel(self.next)
end

function TalkState:setvolume(buf, samplerate, locut, hicut, threshold)
  if threshold == 0 then
    self.volume = 0
    self.threshold = 1
    return
  end
  local buflen = #buf
  local hzstep = samplerate / 2 / 1024
  local v, d, hz = 0, 0, 0
  for i in ipairs(buf) do
    hz = math.pow(2, 10 * ((i - 1) / buflen)) * hzstep
    if locut < hz then
      if hz > hicut then
        break
      end
      v = v + buf[i]
      d = d + 1
    end
  end
  if d > 0 then
    v = v / d
  end
  self.volume = v / threshold
  self.threshold = threshold
end

function TalkState:setphoneme(labfile, time)
  time = time * 10000000
  local line
  local f = io.open(labfile, "r")
  if f == nil then
    error("file not found: " .. labfile)
  end
  for line in f:lines() do
    local st, ed, p = string.match(line, "(%d+) (%d+) (%a+)")
    if st == nil then
      return nil -- unexpected format
    end
    st = st + 0
    ed = ed + 0
    if st <= time then
      if time < ed then
        if self.cur == "" then
          self.progress = (time - st)/(ed - st)
          self.cur = p
          self.cur_start = st
          self.cur_end = ed
        end
      else
        self.prev = p
        self.prev_start = st
        self.prev_end = ed
      end
    else
      self.next = p
      self.next_start = st
      self.next_end = ed
      f:close()
      return
    end
  end
  f:close()
end

local TalkStates = {}

function TalkStates.new()
  return setmetatable({
    states = {}
  }, {__index = TalkStates})
end

function TalkStates:set(obj, srcfile, locut, hicut, threshold)
  local ext = srcfile:sub(-4):lower()
  if ext ~= ".wav" and ext ~= ".lab" then
    self.states[obj.layer] = t
    error("unsupported file: " .. srcfile)
  end

  local t = TalkState.new(obj.frame, obj.time, obj.totalframe, obj.totaltime)
  local wavfile = string.sub(srcfile, 1, #srcfile - 3) .. "wav"
  if ext == ".wav" or fileexists(wavfile) then
    local n, samplerate, buf = obj.getaudio(nil, wavfile, "spectrum", 32)
    t:setvolume(buf, samplerate, locut, hicut, threshold)
  end
  local labfile = string.sub(srcfile, 1, #srcfile - 3) .. "lab"
  if ext == ".lab" or fileexists(labfile) then
    t:setphoneme(labfile, obj.time)
  end
  self.states[obj.layer] = t
end

function TalkStates:setphoneme(obj, phonemestr)
  local t = TalkState.new(obj.frame, obj.time, obj.totalframe, obj.totaltime)
  t.progress = obj.time / obj.totaltime
  t.cur = phonemestr
  t.cur_start = 1
  t.cur_end = obj.totaltime + 1
  self.states[obj.layer] = t
end

function TalkStates:get(index)
  local ts = self.states[index]
  if ts == nil or ts.used then
    return nil
  end
  ts.used = true
  return ts
end

local SubtitleState = {}

function SubtitleState.new(text, frame, time, totalframe, totaltime, unescape)
  if unescape then
    text = text:gsub("([\128-\160\224-\255]\092)\092", "%1")
  end
  return setmetatable({
    used = false,
    text = text,
    frame = frame,
    time = time,
    totalframe = totalframe,
    totaltime = totaltime
  }, {__index = SubtitleState})
end

function SubtitleState:mes(obj)
  obj.mes(self.text)
end

local SubtitleStates = {}

function SubtitleStates.new()
  return setmetatable({
    states = {}
  }, {__index = SubtitleStates})
end

function SubtitleStates:set(text, obj, unescape)
  self.states[obj.layer] = SubtitleState.new(
    text,
    obj.frame,
    obj.time,
    obj.totalframe,
    obj.totaltime,
    unescape
  )
end

function SubtitleStates:get(index)
  return self.states[index]
end

function SubtitleStates:mes(index, obj)
  local s = self:get(index)
  if s == nil or s.used then
    return P.emptysubobj
  end
  s.used = true
  s:mes(obj)
  return s
end

local ValueHolder = {}

function ValueHolder.new(frame, time, totalframe, totaltime)
  return setmetatable({
    used = false,
    index = 1,
    values = {},
    frame = frame,
    time = time,
    totalframe = totalframe,
    totaltime = totaltime
  }, {__index = ValueHolder})
end

function ValueHolder:add(value)
  table.insert(self.values, value)
end

function ValueHolder:get(defvalue, unusedvalue)
  if (self.index < 1)or(self.index > #self.values) then
    return defvalue
  end
  local v = self.values[self.index]
  self.index = self.index + 1
  if v == unusedvalue then
    return defvalue
  end
  return v
end

local ValueHolderStates = {}

function ValueHolderStates.new()
  return setmetatable({
    states = {}
  }, {__index = ValueHolderStates})
end

function ValueHolderStates:set(index, values, obj)
  local vh = self.states[index]
  if vh == nil or vh.used or vh.frame ~= obj.frame then
    vh = ValueHolder.new(
      obj.frame,
      obj.time,
      obj.totalframe,
      obj.totaltime
    )
    self.states[index] = vh
  end
  for i in ipairs(values) do
    vh:add(values[i])
  end
end

function ValueHolderStates:get(index)
  local vh = self.states[index]
  if vh == nil or vh.used then
    return nil
  end
  vh.used = true
  return vh
end

P.talk = TalkStates.new()
P.subtitle = SubtitleStates.new()
P.valueholder = ValueHolderStates.new()

P.emptysubobj = {frame = 0, time = 0, totalframe = 1, totaltime = 1, notfound = true}

P.print = print
P.PSDState = PSDState
P.Blinker = Blinker
P.LipSyncSimple = LipSyncSimple
P.LipSyncLab = LipSyncLab
return P
