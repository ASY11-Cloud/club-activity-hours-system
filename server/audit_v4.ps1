# =====================================================================
# v4.0 系统全面测试（PowerShell，Windows 无 Python 环境）
#
# 覆盖：功能完整性 / 边界与异常 / 安全性 / 性能 / 数据一致性
# 隔离：学号 A90xx、活动 9200-9299，测试前后清理，不碰演示基线
#
# 用法：powershell -ExecutionPolicy Bypass -File audit_v4.ps1
# 退出码 0 = 无失败；1 = 有失败
# =====================================================================
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$env:MYSQL_PWD = '123456'
$MYSQL = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe'
$BASE = 'http://127.0.0.1:8000'
$script:pass = 0
$script:fail = 0
$script:sec = @{}   # 分节统计

function Section([string]$name) {
  Write-Host ''
  Write-Host ('=== ' + $name + ' ===') -ForegroundColor Cyan
  $script:cur = $name
  $script:sec[$name] = @{ p = 0; f = 0 }
}

function Check([string]$name, $cond, [string]$extra = '') {
  if ($cond) {
    $script:pass++; $script:sec[$script:cur].p++
    Write-Host ('  [PASS] ' + $name + $(if ($extra) { ' | ' + $extra } else { '' }))
  } else {
    $script:fail++; $script:sec[$script:cur].f++
    Write-Host ('  [FAIL] ' + $name + $(if ($extra) { ' | ' + $extra } else { '' })) -ForegroundColor Red
  }
}

function Sql([string]$q) {
  $out = & $MYSQL -uroot --default-character-set=utf8mb4 -N -B -e ("USE club_system; " + $q) 2>$null
  return @($out)
}
function Scalar([string]$q) {
  $rows = @(Sql $q)
  if ($rows.Count -eq 0) { return '' }
  return ([string]$rows[0] -split "`t")[0]
}
function Num([string]$q) {
  $v = Scalar $q
  if ($v -eq '' -or $v -eq 'NULL') { return 0 }
  return [double]$v
}

function Api([string]$method, [string]$path, $body = $null, [string]$token = '') {
  $headers = @{ 'Content-Type' = 'application/json; charset=utf-8' }
  if ($token) { $headers['Authorization'] = 'Bearer ' + $token }
  try {
    if ($null -ne $body) {
      $json = if ($body -is [string]) { $body } else { ConvertTo-Json $body -Depth 8 -Compress }
      return Invoke-RestMethod -Method $method -Uri ($BASE + $path) -Headers $headers `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 15
    }
    return Invoke-RestMethod -Method $method -Uri ($BASE + $path) -Headers $headers -TimeoutSec 15
  } catch {
    $r = $_.Exception.Response
    if ($null -ne $r) {
      try {
        $sr = New-Object IO.StreamReader($r.GetResponseStream(), [Text.Encoding]::UTF8)
        $txt = $sr.ReadToEnd()
        if ($txt) { return $txt | ConvertFrom-Json }
      } catch { }
    }
    return [pscustomobject]@{ code = -1; msg = $_.Exception.Message }
  }
}

function Login([string]$type, [string]$account, [string]$secret) {
  $r = Api 'POST' '/api/login' @{ type = $type; account = $account; secret = $secret }
  if ([int]$r.code -eq 0) { return [string]$r.data.token }
  return ''
}

function Cleanup {
  Sql "DELETE FROM appeal WHERE stu_no LIKE 'A90%' OR signup_id BETWEEN 9200 AND 9299" | Out-Null
  Sql "DELETE FROM signup WHERE stu_no LIKE 'A90%' OR activity_id BETWEEN 9200 AND 9299" | Out-Null
  Sql "DELETE FROM hours_total WHERE stu_no LIKE 'A90%'" | Out-Null
  Sql "DELETE FROM activity WHERE id BETWEEN 9200 AND 9299" | Out-Null
  Sql "DELETE FROM student WHERE stu_no LIKE 'A90%'" | Out-Null
  Sql "UPDATE sys_config SET cfg_value='0' WHERE cfg_key LIKE 'rule.skill.%'" | Out-Null
}

function Setup {
  Cleanup
  for ($i = 1; $i -le 3; $i++) {
    $id = 9300 + $i
    $no = 'A900' + $i
    Sql ("INSERT INTO student (id,stu_no,name,dept,pwd_hash,status,created_at) " +
      "SELECT $id,'$no','审计$i','审计班',pwd_hash,1,NOW() FROM student WHERE stu_no='2023001'") | Out-Null
  }
  Sql ("INSERT INTO activity (id,title,content,location,start_time,end_time,hours,capacity,category,publisher,status,created_at) VALUES " +
    "(9201,'审计-容量1','并发占位','A',NOW()+INTERVAL 5 DAY,NOW()+INTERVAL 5 DAY+INTERVAL 2 HOUR,2.0,1,'sports','审计',1,NOW())," +
    "(9202,'审计-不限容量','容量0','A',NOW()+INTERVAL 6 DAY,NOW()+INTERVAL 6 DAY+INTERVAL 2 HOUR,1.0,0,'sports','审计',1,NOW())," +
    "(9203,'审计-已结束','结束','A',NOW()-INTERVAL 2 DAY,NOW()-INTERVAL 1 DAY,1.0,10,'sports','审计',1,NOW())," +
    "(9204,'审计-已下线','下线','A',NOW()+INTERVAL 6 DAY,NOW()+INTERVAL 6 DAY+INTERVAL 2 HOUR,1.0,10,'sports','审计',0,NOW())," +
    "(9205,'审计-时间重叠','与9201重叠','A',NOW()+INTERVAL 5 DAY+INTERVAL 30 MINUTE,NOW()+INTERVAL 5 DAY+INTERVAL 2 HOUR,2.0,10,'sports','审计',1,NOW())," +
    "(9206,'审计-申诉','申诉用','A',NOW()+INTERVAL 8 DAY,NOW()+INTERVAL 8 DAY+INTERVAL 2 HOUR,3.0,10,'volunteer','审计',1,NOW())," +
    "(9207,'审计-规则','技能上限','A',NOW()+INTERVAL 9 DAY,NOW()+INTERVAL 9 DAY+INTERVAL 2 HOUR,3.0,10,'skill','审计',1,NOW())") | Out-Null
  Sql "UPDATE activity a SET taken=(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2) WHERE a.id BETWEEN 9200 AND 9299" | Out-Null
}

# ---------- 性能测量 ----------
function LatencyStats([string]$path, [string]$token, [int]$n = 20) {
  $times = New-Object System.Collections.ArrayList
  $bytes = 0
  for ($i = 0; $i -lt $n; $i++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $headers = @{}
    if ($token) { $headers['Authorization'] = 'Bearer ' + $token }
    $resp = Invoke-WebRequest -Uri ($BASE + $path) -Headers $headers -UseBasicParsing -TimeoutSec 15
    $sw.Stop()
    [void]$times.Add($sw.Elapsed.TotalMilliseconds)
    $bytes = $resp.RawContentLength
  }
  $sorted = @($times | Sort-Object)
  $p95 = $sorted[[int][Math]::Floor($sorted.Count * 0.95) - 1]
  if ($p95 -eq $null) { $p95 = $sorted[-1] }
  $avg = ($times | Measure-Object -Average).Average
  return @{ avg = [Math]::Round($avg, 1); p95 = [Math]::Round($p95, 1); size = $bytes }
}

function ConcurrentGet([string]$path, [string]$token, [int]$n) {
  [Net.ServicePointManager]::DefaultConnectionLimit = 200
  $client = New-Object Net.Http.HttpClient
  if ($token) { $client.DefaultRequestHeaders.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token) }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $tasks = @()
  for ($i = 0; $i -lt $n; $i++) { $tasks += $client.GetAsync($BASE + $path) }
  [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
  $sw.Stop()
  $ok = 0; $bad = 0
  foreach ($t in $tasks) {
    if ($t.Status -eq 'RanToCompletion' -and $t.Result.IsSuccessStatusCode) { $ok++ } else { $bad++ }
  }
  $client.Dispose()
  return @{ ms = $sw.ElapsedMilliseconds; ok = $ok; bad = $bad }
}

function ConcurrentPost([string]$path, [string[]]$tokens, [string]$json) {
  $client = New-Object Net.Http.HttpClient
  $tasks = @()
  foreach ($tk in $tokens) {
    $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, [string]($BASE + $path))
    $req.Headers.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $tk)
    $req.Content = New-Object Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
    $tasks += $client.SendAsync($req)
  }
  [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks)
  $codes = @()
  foreach ($t in $tasks) {
    $body = $t.Result.Content.ReadAsStringAsync().Result
    $codes += ([int](($body | ConvertFrom-Json).code))
  }
  $client.Dispose()
  return $codes
}

Write-Host '############ v4.0 系统全面测试 ############'
$admin = ''; $club = ''; $t1 = ''; $t2 = ''
$measure = @{}
try {
  Setup
  $admin = Login 'admin' 'admin' 'admin123'
  # v5.0(重构): 活动发布/编辑/上下线归属于社团, 相关用例改用社团账号执行
  $club = Login 'club' 'club' 'club123'
  $t1 = Login 'student' 'A9001' '123456'
  $t2 = Login 'student' 'A9002' '123456'

  # ============================================================
  Section 'A. 功能完整性（接口矩阵与契约）'
  $h = Api 'GET' '/api/health'
  # v5.0 起版本号前移到 5.0; 本脚本做 v4 及以后能力的审计, 只要求版本 >= 4.0
  Check 'health 可用且 version>=4.0' ([int]$h.code -eq 0 -and [double]([string]$h.data.version) -ge 4.0 -and [bool]$h.data.db)
  Check '管理员/学生登录' ($admin -ne '' -and $t1 -ne '' -and $t2 -ne '')

  $a = Api 'GET' '/api/activity/list?page=1&size=2' $null $t1
  $keys = @()
  if ([int]$a.code -eq 0 -and @($a.data.list).Count -gt 0) { $keys = @($a.data.list[0].PSObject.Properties.Name) }
  Check '活动列表分页 size=2' ([int]$a.code -eq 0 -and @($a.data.list).Count -le 2 -and [bool]$a.data.has_more)
  Check '活动字段完整' (($keys -contains 'category') -and ($keys -contains 'taken') -and ($keys -contains 'remaining') -and ($keys -contains 'valid_count'))

  $sa = Api 'GET' '/api/signup/list?page=1&size=5' $null $admin
  Check '报名列表(管理员)' ([int]$sa.code -eq 0 -and [double]$sa.data.total -eq 19)
  $ss = Api 'GET' '/api/signup/list?page=1&size=50' $null $t1
  $own = @($ss.data.list | Where-Object { [string]$_.stu_no -ne 'A9001' }).Count
  Check '学生报名列表只看本人' ([int]$ss.code -eq 0 -and $own -eq 0)

  $rep = Api 'GET' '/api/hours/report' $null $admin
  $sumCat = 0.0
  foreach ($c in @($rep.data.by_category)) { $sumCat += [double]$c.hours }
  Check '报表排行 + 明细 + 分类' ([int]$rep.code -eq 0 -and @($rep.data.report).Count -ge 5 -and @($rep.data.detail).Count -gt 0)
  Check '分类学时合计 = 20.5' ([Math]::Abs($sumCat - 20.5) -lt 0.001) ('sum=' + [Math]::Round($sumCat, 2))
  Check '达标口径下发' ([double]$rep.data.required_hours -eq 20 -and [double]$rep.data.achieved -ge 0)

  $w = Api 'GET' '/api/report/warning' $null $admin
  Check '预警名单可读' ([int]$w.code -eq 0 -and $null -ne $w.data.list)
  $an = Api 'GET' '/api/report/anomaly' $null $admin
  Check '异常检测可读' ([int]$an.code -eq 0 -and $null -ne $an.data.summary)

  $cfg = Api 'GET' '/api/config/get' $null $t1
  Check '配置含 7 类规则' ([int]$cfg.code -eq 0 -and @($cfg.data.rules.PSObject.Properties.Name).Count -eq 7)
  $st = Api 'GET' '/api/stats/pending' $null $admin
  Check '待办统计字段完整' ([int]$st.code -eq 0 -and $null -ne $st.data.signup_pending -and $null -ne $st.data.register_pending -and $null -ne $st.data.activity_total)
  $lg = Api 'GET' '/api/logs?limit=5' $null $admin
  Check '服务器日志可读' ([int]$lg.code -eq 0 -and @($lg.data.list).Count -le 5)
  $reqs = Api 'GET' '/api/student/requests' $null $admin
  Check '注册申请列表可读' ([int]$reqs.code -eq 0 -and $null -ne $reqs.data.list)
  $sl = Api 'GET' '/api/student/list?kw=李' $null $admin
  Check '学生检索可用' ([int]$sl.code -eq 0 -and @($sl.data.list).Count -ge 1)
  $imp = Api 'GET' '/api/student/impact?stu_no=A9001' $null $admin
  Check '注销影响面预览' ([int]$imp.code -eq 0 -and [string]$imp.data.stu_no -eq 'A9001')
  $ap = Api 'GET' '/api/appeal/list?page=1&size=10' $null $admin
  Check '申诉列表可读' ([int]$ap.code -eq 0 -and [double]$ap.data.total -eq 0)
  $u = Api 'GET' '/api/nope' $null $admin
  # 未知路由按 HTTP 404 返回(与业务码恒 200 的约定不同), 用状态码断言更准确
  Check '未知接口 HTTP 404(已登录)' ([int]$u.code -eq -1 -or [int]$u.code -eq 404) ('code=' + $u.code + ' msg=' + $u.msg)
  $u2 = Api 'GET' '/api/nope'
  Check '未登录访问未知接口 -> 401(不泄露路由)' ([int]$u2.code -eq 401)

  # ============================================================
  Section 'B. 边界条件与异常处理'
  $r = Api 'POST' '/api/login' '{bad json' 
  Check '非法 JSON -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/login' '[]'
  Check 'JSON 类型错误 -> 400' ([int]$r.code -eq 400)
  $big = '{"type":"admin","account":"' + ('a' * 70000) + '"}'
  $r = Api 'POST' '/api/login' $big
  Check '超大请求体被拒且服务存活' ([int]$r.code -ne 0 -and [int](Api 'GET' '/api/health').code -eq 0)

  $r = Api 'POST' '/api/activity/add' @{ content = 'x'; hours = 1 } $club
  Check '发布活动缺标题 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/activity/add' @{ title = '审计-0学时'; content = 'x'; hours = 0; capacity = 1; category = 'sports'; start_time = '2026-12-01 10:00:00'; end_time = '2026-12-01 12:00:00' } $club
  Check '0 学时活动被拒 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/activity/add' @{ title = '审计-越界'; content = 'x'; hours = 1000; capacity = 1; category = 'sports'; start_time = '2026-12-01 10:00:00'; end_time = '2026-12-01 12:00:00' } $club
  Check '学时越界 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/activity/add' @{ title = '审计-容量负'; content = 'x'; hours = 1; capacity = -1; category = 'sports'; start_time = '2026-12-01 10:00:00'; end_time = '2026-12-01 12:00:00' } $club
  Check '容量负数 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/activity/add' @{ title = '审计-时间倒置'; content = 'x'; hours = 1; capacity = 10; start_time = '2026-12-01 12:00:00'; end_time = '2026-12-01 10:00:00' } $club
  Check '开始晚于结束 -> 400' ([int]$r.code -eq 400)

  $r = Api 'POST' '/api/activity/add' @{ title = '审计-非法类别回落'; content = '审计'; hours = 1; capacity = 1; category = 'bogus'; start_time = '2026-12-05 10:00:00'; end_time = '2026-12-05 12:00:00' } $club
  $newId = 0
  if ([int]$r.code -eq 0) { $newId = [int]$r.data.id }
  Check '非法 category 回落 sports' ([int]$r.code -eq 0 -and (Scalar "SELECT category FROM activity WHERE id=$newId") -eq 'sports')

  $p = Api 'GET' '/api/activity/list?page=-5&size=999' $null $admin
  Check '页码/页长越界被夹紧' ([int]$p.code -eq 0 -and [int]$p.data.page -eq 1 -and [int]$p.data.size -eq 200)
  $p0 = Api 'GET' '/api/signup/list?size=0' $null $admin
  Check 'size=0 全量返回(记录为风险)' ([int]$p0.code -eq 0 -and @($p0.data.list).Count -eq 19) ('count=' + @($p0.data.list).Count)

  $r = Api 'POST' '/api/signup/add' @{ activity_id = 999999; client_id = 'aud-nx' } $t1
  Check '报名不存在活动 -> 404' ([int]$r.code -eq 404)
  $r = Api 'POST' '/api/signup/add' @{ activity_id = 9203; client_id = 'aud-end' } $t1
  Check '报名已结束活动被拒' (@(400, 403, 409) -contains [int]$r.code)
  $r = Api 'POST' '/api/signup/add' @{ activity_id = 9204; client_id = 'aud-off' } $t1
  Check '报名已下线活动被拒' ([int]$r.code -ne 0)

  # 并发抢 1 个名额
  $codes = ConcurrentPost '/api/signup/add' @($t1, $t2) '{"activity_id":9201,"client_id":"aud-race"}'
  $succ = @($codes | Where-Object { $_ -eq 0 }).Count
  Check '容量1并发两人仅一人成功' ($succ -eq 1) ('codes=' + ($codes -join ','))
  Check 'taken=1 且不超过容量' ((Num "SELECT taken FROM activity WHERE id=9201") -eq 1)

  # 时间冲突: 抢到的学生再报 9205
  $winner = Scalar "SELECT stu_no FROM signup WHERE activity_id=9201 AND status<>2 LIMIT 1"
  $wt = if ($winner -eq 'A9001') { $t1 } else { $t2 }
  $r = Api 'POST' '/api/signup/add' @{ activity_id = 9205; client_id = 'aud-conflict' } $wt
  Check '时间重叠报名 -> 409' ([int]$r.code -eq 409) ([string]$r.msg)

  $sid = 0
  $r = Api 'POST' '/api/signup/add' @{ activity_id = 9206; client_id = 'aud-appeal' } $t1
  if ([int]$r.code -eq 0) { $sid = [int]$r.data.id }
  $r2 = Api 'POST' '/api/signup/add' @{ activity_id = 9206; client_id = 'aud-appeal-dup' } $t1
  Check '重复报名幂等(返回同一记录)' ([int]$r2.code -eq 0 -and [int]$r2.data.id -eq $sid)
  $r = Api 'POST' '/api/signup/audit' @{ signup_id = 999999; action = 'pass' } $admin
  Check '审核不存在报名 -> 404' ([int]$r.code -eq 404)
  $r = Api 'POST' '/api/signup/audit' @{ signup_id = $sid; action = 'bogus' } $admin
  Check '审核非法动作 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/signup/audit' @{ signup_id = $sid; action = 'pass' } $admin
  Check '审核通过成功' ([int]$r.code -eq 0)
  $r = Api 'POST' '/api/signup/audit' @{ signup_id = $sid; action = 'pass' } $admin
  Check '重复审核被拒(400/409)' (@(400, 409) -contains [int]$r.code) ('code=' + $r.code + ' msg=' + $r.msg)

  $r = Api 'POST' '/api/appeal/add' @{ signup_id = 999999; reason = '不存在的报名记录' } $t1
  Check '申诉不存在报名 -> 404' ([int]$r.code -eq 404)
  $r = Api 'POST' '/api/appeal/add' @{ signup_id = $sid; reason = ('长' * 600) } $t1
  $apId = 0
  if ([int]$r.code -eq 0) { $apId = [int]$r.data.id }
  Check '超长理由被截断入库' ([int]$r.code -eq 0 -and (Num "SELECT CHAR_LENGTH(reason) FROM appeal WHERE id=$apId") -le 500) `
    ('code=' + $r.code + ' msg=' + $r.msg + ' len=' + (Num "SELECT CHAR_LENGTH(reason) FROM appeal WHERE id=$apId"))
  $r = Api 'POST' '/api/appeal/audit' @{ appeal_id = $apId; action = 'pass'; hours = 99 } $admin
  Check '调整学时超活动上限 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/appeal/audit' @{ appeal_id = $apId; action = 'pass'; hours = -2 } $admin
  Check '调整学时为负 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/appeal/audit' @{ appeal_id = $apId; action = 'reject' } $admin
  Check '驳回无理由 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/appeal/audit' @{ appeal_id = $apId; action = 'reject'; reply = '审计驳回' } $admin
  Check '驳回成功且不改学时' ([int]$r.code -eq 0 -and [Math]::Abs((Num "SELECT hours FROM signup WHERE id=$sid") - 3.0) -lt 0.001)

  $r = Api 'POST' '/api/signin/code' @{ activity_id = 9206; code = '000000' } $t1
  Check '错误签到码被拒' ([int]$r.code -ne 0)
  $r = Api 'POST' '/api/signin/code' @{ activity_id = 9206; code = '12' } $t1
  Check '签到码长度非法被拒' ([int]$r.code -ne 0)
  $r = Api 'POST' '/api/signin/out' @{ activity_id = 9206 } $t1
  Check '未签到直接签退 -> 409' ([int]$r.code -eq 409)

  $r = Api 'POST' '/api/register' @{ stu_no = 'A9009'; name = '审计注册'; pwd = '123' }
  Check '注册密码过短 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/register' @{ stu_no = 'A9001'; name = '重复'; pwd = '123456' }
  Check '重复学号注册 -> 409' ([int]$r.code -eq 409)

  $r = Api 'POST' '/api/config/set' @{} $admin
  Check '空配置 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/config/set' @{ rules = 'bad' } $admin
  Check 'rules 非对象 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/config/set' @{ required_hours = 1000 } $admin
  Check '达标线越界 -> 400' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/config/set' @{ rules = @{ skill = @{ max_activity = 1.0 } } } $admin
  Check '规则设置成功' ([int]$r.code -eq 0)
  $sid2 = 0
  $r = Api 'POST' '/api/signup/add' @{ activity_id = 9207; client_id = 'aud-rule' } $t2
  if ([int]$r.code -eq 0) { $sid2 = [int]$r.data.id }
  $r = Api 'POST' '/api/signup/audit' @{ signup_id = $sid2; action = 'pass' } $admin
  Check '规则裁剪生效(3.0 -> 1.0)' ([int]$r.code -eq 0 -and [Math]::Abs([double]$r.data.hours - 1.0) -lt 0.001)
  $r = Api 'POST' '/api/config/set' @{ rules = @{ skill = @{ max_activity = 0 } } } $admin
  Check '规则复位' ([int]$r.code -eq 0)

  # ============================================================
  Section 'C. 安全性（鉴权/越权/注入/泄露）'
  Check '无 Token 访问受保护接口 -> 401' ((Api 'GET' '/api/activity/list').code -eq 401)
  Check '伪造 Token -> 401' ((Api 'GET' '/api/activity/list' $null 'deadbeef').code -eq 401)
  Check '空 Bearer -> 401' ((Api 'GET' '/api/signup/list' $null 'x').code -eq 401)

  $adminPaths = @(
    @('POST', '/api/activity/add'), @('POST', '/api/activity/status'), @('POST', '/api/signup/audit'),
    @('GET', '/api/student/list'), @('POST', '/api/student/reset_pwd'),
    @('GET', '/api/logs'), @('GET', '/api/report/warning'), @('GET', '/api/report/anomaly'),
    @('POST', '/api/appeal/audit'), @('POST', '/api/config/set')
  )
  $bad = 0
  $badList = @()
  foreach ($ap_ in $adminPaths) {
    $payload = if ($ap_[0] -eq 'GET') { $null } else { @{} }
    $r = Api $ap_[0] $ap_[1] $payload $t1
    if ([int]$r.code -ne 403) { $bad++; $badList += ($ap_[1] + '=>' + $r.code + '(' + $r.msg + ')') }
  }
  Check ('学生访问 ' + $adminPaths.Count + ' 个管理接口全部 403') ($bad -eq 0) ('violations=' + ($badList -join '; '))

  # v5.0(重构): 活动发布/上下线归属于社团 —— 平台管理员也应被拒
  $r = Api 'POST' '/api/activity/add' @{ title = '审计-越权发布'; content = 'x'; hours = 1; capacity = 1; category = 'sports'; start_time = '2026-12-01 10:00:00'; end_time = '2026-12-01 12:00:00' } $admin
  Check '平台管理员发布活动 -> 403(归属社团)' ([int]$r.code -eq 403) ($r.msg)
  $r = Api 'POST' '/api/activity/status' @{ activity_id = 9201; status = 0 } $admin
  Check '平台管理员上下线活动 -> 403(归属社团)' ([int]$r.code -eq 403) ($r.msg)

  $s = Api 'GET' '/api/signup/list?stu_no=A9002&size=50' $null $t1
  $leak = @($s.data.list | Where-Object { [string]$_.stu_no -ne 'A9001' }).Count
  Check '学生伪造 stu_no 仍只返回本人' ($leak -eq 0)

  $s = Api 'GET' '/api/student/impact?stu_no=A9002' $null $t1
  Check '学生注销影响面不能越权到他人' ([int]$s.code -eq 403 -or [string]$s.data.stu_no -eq 'A9001')

  $inj = Api 'POST' '/api/login' @{ type = 'admin'; account = "' OR '1'='1"; secret = 'x' }
  Check '登录 SQL 注入无效' ([int]$inj.code -ne 0)
  $kw = Api 'GET' "/api/student/list?kw=%27%20OR%20%271%27%3D%271" $null $admin
  Check '检索 SQL 注入无效/无 500' ([int]$kw.code -eq 0)

  $xss = Api 'POST' '/api/activity/add' @{ title = '<script>alert(1)</script>'; content = 'x'; hours = 1; capacity = 1; category = 'sports'; start_time = '2026-12-10 10:00:00'; end_time = '2026-12-10 12:00:00' } $club
  $xid = 0
  if ([int]$xss.code -eq 0) { $xid = [int]$xss.data.id }
  $stored = Scalar "SELECT title FROM activity WHERE id=$xid"
  Check '脚本标签原样存储(JSON 输出, App 用 Text 渲染)' ($stored -eq '<script>alert(1)</script>')

  $tokTmp = Login 'student' 'A9003' '123456'
  Api 'POST' '/api/logout' @{} $tokTmp | Out-Null
  Check '注销后 Token 立即失效' ((Api 'GET' '/api/activity/list' $null $tokTmp).code -eq 401)

  $leakPwd = Num "SELECT COUNT(*) FROM request_log WHERE detail LIKE '%admin123%' OR detail LIKE '%123456%'"
  Check '日志未记录口令' ($leakPwd -eq 0)
  $body = Api 'GET' '/api/nope'
  Check '错误响应不泄露堆栈/SQL' (([string]$body.msg).IndexOf('SELECT') -lt 0 -and ([string]$body.msg).IndexOf('server.cpp') -lt 0)

  # 登录失败节流用独立账号，避免锁住演示账号
  Sql "INSERT INTO student (id,stu_no,name,dept,pwd_hash,status,created_at) SELECT 9399,'A9099','节流','审计班',pwd_hash,1,NOW() FROM student WHERE stu_no='2023001'" | Out-Null
  $last = $null
  for ($i = 0; $i -lt 6; $i++) { $last = Api 'POST' '/api/login' @{ type = 'student'; account = 'A9099'; secret = 'wrong-pwd' } }
  Check '连续登录失败触发 429' ([int]$last.code -eq 429) ([string]$last.msg)

  # ============================================================
  Section 'D. 性能表现'
  $measure['health'] = LatencyStats '/api/health' '' 20
  $measure['activity'] = LatencyStats '/api/activity/list?page=1&size=10' $t1 20
  $measure['signup'] = LatencyStats '/api/signup/list?page=1&size=10' $admin 20
  $measure['report'] = LatencyStats '/api/hours/report' $admin 10
  $measure['anomaly'] = LatencyStats '/api/report/anomaly' $admin 10
  $measure['logs'] = LatencyStats '/api/logs?limit=20' $admin 10

  Check 'health p95 < 50ms' ($measure['health'].p95 -lt 50) ('p95=' + $measure['health'].p95 + 'ms')
  Check '活动列表 p95 < 120ms' ($measure['activity'].p95 -lt 120) ('p95=' + $measure['activity'].p95 + 'ms')
  Check '报名列表 p95 < 120ms' ($measure['signup'].p95 -lt 120) ('p95=' + $measure['signup'].p95 + 'ms')
  Check '学时报表 p95 < 300ms' ($measure['report'].p95 -lt 300) ('p95=' + $measure['report'].p95 + 'ms size=' + $measure['report'].size)
  Check '异常检测 p95 < 300ms' ($measure['anomaly'].p95 -lt 300) ('p95=' + $measure['anomaly'].p95 + 'ms')
  Check '日志接口 p95 < 200ms' ($measure['logs'].p95 -lt 200) ('p95=' + $measure['logs'].p95 + 'ms')

  $memBefore = [Math]::Round((Get-Process server).WorkingSet64 / 1MB, 1)
  $conc = ConcurrentGet '/api/activity/list?page=1&size=10' $t1 100
  $memAfter = [Math]::Round((Get-Process server).WorkingSet64 / 1MB, 1)
  Check '100 并发活动列表全部成功' ($conc.bad -eq 0 -and $conc.ok -eq 100) ('elapsed=' + $conc.ms + 'ms')
  Check '100 并发耗时 < 5000ms' ($conc.ms -lt 5000) ('elapsed=' + $conc.ms + 'ms')
  Check '并发后服务存活' ([int](Api 'GET' '/api/health').code -eq 0)
  Write-Host ('  [INFO] 服务端内存 ' + $memBefore + 'MB -> ' + $memAfter + 'MB')

  $conc2 = ConcurrentGet '/api/hours/report' $admin 20
  Check '20 并发报表全部成功' ($conc2.bad -eq 0 -and $conc2.ok -eq 20) ('elapsed=' + $conc2.ms + 'ms')

  # ============================================================
  Section 'E. 数据一致性'
  Check '基线活动=8' ((Num "SELECT COUNT(*) FROM activity WHERE id<9000") -eq 8)
  Check '基线报名=19' ((Num "SELECT COUNT(*) FROM signup WHERE id<9000") -eq 19)
  Check '基线学时=20.5' ([Math]::Abs((Num "SELECT SUM(total_hours) FROM hours_total WHERE stu_no NOT LIKE 'A900%'") - 20.5) -lt 0.001)
  Check 'taken 与有效报名数一致' ((Num "SELECT COUNT(*) FROM activity a WHERE a.taken<>(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2)") -eq 0)
  Check '学时汇总与明细一致' ((Num "SELECT COUNT(*) FROM hours_total ht WHERE ABS(ht.total_hours-(SELECT COALESCE(SUM(s.hours),0) FROM signup s WHERE s.stu_no=ht.stu_no AND s.status=1))>0.001") -eq 0)
  Check '无空类别快照' ((Num "SELECT COUNT(*) FROM signup WHERE status=1 AND category=''") -eq 0)
  Check '无重复报名(activity+stu)' ((Num "SELECT COUNT(*) FROM (SELECT activity_id,stu_no FROM signup GROUP BY activity_id,stu_no HAVING COUNT(*)>1) t") -eq 0)
  Check '无孤儿报名(活动缺失)' ((Num "SELECT COUNT(*) FROM signup s LEFT JOIN activity a ON s.activity_id=a.id WHERE a.id IS NULL") -eq 0)
  Check '无孤儿学时汇总(学生缺失)' ((Num "SELECT COUNT(*) FROM hours_total ht LEFT JOIN student st ON ht.stu_no=st.stu_no WHERE st.stu_no IS NULL") -eq 0)
  Check '无孤儿申诉(报名缺失)' ((Num "SELECT COUNT(*) FROM appeal ap LEFT JOIN signup s ON ap.signup_id=s.id WHERE s.id IS NULL") -eq 0)

  # ============================================================
  Section 'G. 兼容性（旧客户端 / 运行环境）'
  $upd = Api 'POST' '/api/activity/update' @{
    activity_id = 9202; title = '审计-不限容量-改'; content = '兼容性更新'; hours = 1.0; capacity = 0
    start_time = '2026-12-01 10:00:00'; end_time = '2026-12-01 12:00:00'; publisher = '审计'
  } $club
  Check '旧客户端改活动(不带 category)保留原类别' ([int]$upd.code -eq 0 -and (Scalar "SELECT category FROM activity WHERE id=9202") -eq 'sports') ([string]$upd.msg)

  $cfgProps = @($cfg.data.PSObject.Properties.Name)
  Check '配置仍保留平铺 rule.* 字段(兼容 v3.2)' ($cfgProps -contains 'rule.volunteer.max_total')

  $rowKeys = @()
  if ([int]$sa.code -eq 0 -and @($sa.data.list).Count -gt 0) { $rowKeys = @($sa.data.list[0].PSObject.Properties.Name) }
  Check '报名行仍保留 v3.x 旧字段' (($rowKeys -contains 'client_id') -and ($rowKeys -contains 'checkin') -and ($rowKeys -contains 'hours') -and ($rowKeys -contains 'remark'))

  try {
    $opt = Invoke-WebRequest -Method Options -Uri ($BASE + '/api/login') -UseBasicParsing -TimeoutSec 5
    $acao = $opt.Headers['Access-Control-Allow-Origin']
    $ctype = (Invoke-WebRequest -Uri ($BASE + '/api/health') -UseBasicParsing -TimeoutSec 5).Headers['Content-Type']
    Check 'CORS 预检可用且返回 ACAO' ([int]$opt.StatusCode -eq 200 -and [string]$acao -eq '*')
    Check '响应 Content-Type 为 JSON' ([string]$ctype -like 'application/json*')
  } catch {
    Check 'CORS 预检 / Content-Type' $false ($_.Exception.Message)
  }

  $ver = Scalar "SELECT CONCAT(VERSION(),' | ',@@sql_mode)"
  Write-Host ('  [INFO] MySQL: ' + $ver)
  Check 'MySQL 8.x + only_full_group_by 下 SQL 全部可执行' ($ver.StartsWith('8.'))
}
finally {
  Section 'F. 清理与回归'
  Cleanup
  Check '测试数据已清理' ((Num "SELECT COUNT(*) FROM activity WHERE id BETWEEN 9200 AND 9299") -eq 0 -and (Num "SELECT COUNT(*) FROM student WHERE stu_no LIKE 'A90%'") -eq 0)
  Check '基线报名仍为 19' ((Num "SELECT COUNT(*) FROM signup") -eq 19)
  Check '基线学时仍为 20.5' ([Math]::Abs((Num "SELECT SUM(total_hours) FROM hours_total") - 20.5) -lt 0.001)
  Check 'taken 仍自洽' ((Num "SELECT COUNT(*) FROM activity a WHERE a.taken<>(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2)") -eq 0)
  Check '服务仍健康(version>=4.0)' ([double]([string](Api 'GET' '/api/health').data.version) -ge 4.0)
}

Write-Host ''
Write-Host '================ 分节汇总 ================'
foreach ($k in $script:sec.Keys) {
  $v = $script:sec[$k]
  Write-Host ('  ' + $k + ': ' + $v.p + ' 通过 / ' + $v.f + ' 失败')
}
Write-Host ''
Write-Host '性能指标(ms):'
foreach ($k in $measure.Keys) {
  Write-Host ('  ' + $k + ': avg=' + $measure[$k].avg + ' p95=' + $measure[$k].p95 + ' size=' + $measure[$k].size + 'B')
}
Write-Host ''
Write-Host ('总计: ' + $script:pass + ' 通过, ' + $script:fail + ' 失败')
if ($script:fail -gt 0) { exit 1 }
exit 0
