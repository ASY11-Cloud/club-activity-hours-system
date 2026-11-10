# =====================================================================
# 活动参与范围验收 (v5.0)
#
# 覆盖:
#   1) 内部活动对非本社团学生完全不可见
#   2) 非本社团学生直接请求报名 -> 403
#   3) 非本社团学生用转发来的签到码 -> 403, 且不产生报名/学时(核心堵漏点)
#   4) 非本社团学生刷卡 -> 403(无登录态链: 卡号 -> 学生 -> 社团成员)
#   5) 公开活动: 非本社团学生可正常报名, 报名快照 club_id 归活动所属社团
#   6) 公开活动满员 -> 403
#   7) 跨社团时间冲突仍按全局校验 -> 409
#   8) 活动改为"仅本社团"后, 存量外社团报名保留
#
# 会创建 1 个测试学生(2099001) 与 4 个测试活动, 结束时用 mysql 清理。
# 用法: powershell -ExecutionPolicy Bypass -File server\verify_scope.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'

# 本脚本断言依赖中文比对, 必须按 UTF-8 解码子进程输出(控制台默认 GBK 会把 mysql 的 utf8 输出读成乱码)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Base = 'http://127.0.0.1:8000'
$Mysql = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe'
$script:pass = 0
$script:fail = 0
$script:actIds = @()

function Assert-True($cond, $name, $detail) {
  if ($cond) {
    $script:pass++
    Write-Host ("  [PASS] " + $name) -ForegroundColor Green
  } else {
    $script:fail++
    $msg = "  [FAIL] " + $name
    if ($detail -ne $null -and $detail -ne '') { $msg += "  -> " + $detail }
    Write-Host $msg -ForegroundColor Red
  }
}

function Post-Json($path, $obj, $token) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 6))
  $headers = @{}
  if ($token -ne '' -and $token -ne $null) { $headers['Authorization'] = 'Bearer ' + $token }
  return Invoke-RestMethod -Uri ($Base + $path) -Method Post -Headers $headers `
    -ContentType 'application/json; charset=utf-8' -Body $bytes
}

function Get-Api($path, $token) {
  $headers = @{}
  if ($token -ne '' -and $token -ne $null) { $headers['Authorization'] = 'Bearer ' + $token }
  return Invoke-RestMethod -Uri ($Base + $path) -Headers $headers
}

function Fmt-Time($offsetDays, $hour) {
  $d = (Get-Date).AddDays($offsetDays)
  return $d.ToString('yyyy-MM-dd') + ' ' + $hour + ':00'
}

Write-Host "=== 活动参与范围验收 (v5.0) ===" -ForegroundColor Cyan

# ---------- 准备账号 ----------
$club = Post-Json '/api/login' @{ type = 'club'; account = 'club'; secret = 'club123' } ''
$ct = $club.data.token
$adm = Post-Json '/api/login' @{ type = 'admin'; account = 'admin'; secret = 'admin123' } ''
$at = $adm.data.token

# 测试学生: 注册 -> 管理员审批通过; 刻意不加入任何社团
$stuNo = '2099001'
$reg = Post-Json '/api/register' @{
  stu_no = $stuNo; name = '范围测试'; dept = '测试学院'; pwd = '123456'
} ''
if ($reg.code -ne 0) {
  # 上次残留: 先允许脚本继续, 后面直接登录
  Write-Host ("  [INFO] 注册返回: " + $reg.msg + " (可能是上次残留)") -ForegroundColor Yellow
} else {
  # 审批接口按 student_id 操作: 先从待审列表取 id
  $pend = Get-Api '/api/student/list?group=pending&size=100' $at
  $sid = -1
  foreach ($item in @($pend.data.list)) {
    if ($item.stu_no -eq $stuNo) { $sid = $item.id }
  }
  if ($sid -gt 0) {
    $ap = Post-Json '/api/student/audit' @{ student_id = $sid; action = 'pass'; card_no = 'ZZSCOPE1' } $at
    if ($ap.code -ne 0) { Write-Host ("  [INFO] 审批返回: " + $ap.msg) -ForegroundColor Yellow }
  } else {
    Write-Host "  [INFO] 待审列表里没找到测试学生" -ForegroundColor Yellow
  }
}
$stu = Post-Json '/api/login' @{ type = 'student'; account = $stuNo; secret = '123456' } ''
Assert-True ($stu.code -eq 0) '测试学生可登录(已通过审核)' $stu.msg
$st = $stu.data.token

# ---------- 内部活动 ----------
$t1 = Fmt-Time 10 '19'
$e1 = Fmt-Time 10 '21'
$inner = Post-Json '/api/activity/add' @{
  title = '[验收]内部活动'; content = '范围测试'; location = 'A-101';
  start_time = $t1; end_time = $e1; hours = 1.5; capacity = 10;
  category = 'skill'; join_scope = 'club'
} $ct
Assert-True ($inner.code -eq 0) '社团发布内部活动' $inner.msg
$innerId = $inner.data.id
if ($innerId -ne $null) { $script:actIds += $innerId }

$list = Get-Api '/api/activity/list?size=0' $st
$hit = @($list.data.list | Where-Object { $_.id -eq $innerId })
Assert-True ($hit.Count -eq 0) '非本社团学生看不到内部活动' ([string]$hit.Count)

$signupBlocked = Post-Json '/api/signup/add' @{
  client_id = 'scope-' + [guid]::NewGuid().ToString('N'); activity_id = $innerId
} $st
Assert-True ($signupBlocked.code -eq 403) '非本社团学生报名内部活动 -> 403' $signupBlocked.msg

# 签到码绕过(最关键): 必须在建报名之前被拦住
$code = Get-Api ('/api/activity/signin_code?activity_id=' + [string]$innerId) $ct
Assert-True ($code.code -eq 0) '社团管理员可取内部活动签到码' $code.msg
$byCode = Post-Json '/api/signin/code' @{ activity_id = $innerId; code = $code.data.code } $st
Assert-True ($byCode.code -eq 403) '非本社团学生输码签到 -> 403' $byCode.msg

$mySign = Get-Api ('/api/signup/list?activity_id=' + [string]$innerId) $st
Assert-True ($mySign.data.total -eq 0) '输码被拒后没有产生报名行' ([string]$mySign.data.total)

$repBefore = Get-Api '/api/hours/report' $st
$hoursBefore = [double]$repBefore.data.total_hours

# 刷卡(卡号 -> 学生 -> 社团成员)链路
$rf = Post-Json '/api/signin' @{ card_no = 'ZZSCOPE1'; activity_id = $innerId } ''
Assert-True ($rf.code -eq 403) '非本社团成员刷卡 -> 403' $rf.msg
$repAfter = Get-Api '/api/hours/report' $st
Assert-True ([double]$repAfter.data.total_hours -eq $hoursBefore) '被拒签到不增加学时' `
  ([string]$hoursBefore + ' -> ' + [string]$repAfter.data.total_hours)

# ---------- 公开活动 ----------
$t2 = Fmt-Time 11 '19'
$e2 = Fmt-Time 11 '21'
$open = Post-Json '/api/activity/add' @{
  title = '[验收]公开活动'; content = '范围测试'; location = 'B-201';
  start_time = $t2; end_time = $e2; hours = 1; capacity = 2;
  category = 'skill'; join_scope = 'all'
} $ct
Assert-True ($open.code -eq 0) '社团发布公开活动' $open.msg
$openId = $open.data.id
if ($openId -ne $null) { $script:actIds += $openId }

$list2 = Get-Api '/api/activity/list?size=0' $st
$hit2 = @($list2.data.list | Where-Object { $_.id -eq $openId })
Assert-True ($hit2.Count -eq 1) '公开活动对非本社团学生可见' ([string]$hit2.Count)

$joinOpen = Post-Json '/api/signup/add' @{
  client_id = 'scope-' + [guid]::NewGuid().ToString('N'); activity_id = $openId
} $st
Assert-True ($joinOpen.code -eq 0) '非本社团学生可报名公开活动' $joinOpen.msg

# 满员: capacity=2, 再让 2 人报名, 第 3 人应 403
$s2 = Post-Json '/api/login' @{ type = 'student'; account = '2023004'; secret = '123456' } ''
if ($s2.code -eq 0) {
  $s2t = $s2.data.token
  Post-Json '/api/signup/add' @{
    client_id = 'scope-' + [guid]::NewGuid().ToString('N'); activity_id = $openId
  } $s2t | Out-Null
  $s3 = Post-Json '/api/login' @{ type = 'student'; account = '2023006'; secret = '123456' } ''
  $full = Post-Json '/api/signup/add' @{
    client_id = 'scope-' + [guid]::NewGuid().ToString('N'); activity_id = $openId
  } $s3.data.token
  Assert-True ($full.code -eq 403) '公开活动满员 -> 403' $full.msg
} else {
  Assert-True $false '2023004 登录失败, 跳过满员用例' $s2.msg
}

# ---------- 跨社团时间冲突(与公开活动同段) ----------
$conflictAct = Post-Json '/api/activity/add' @{
  title = '[验收]冲突活动'; content = '范围测试'; location = 'C-301';
  start_time = $t2; end_time = $e2; hours = 1; capacity = 10;
  category = 'skill'; join_scope = 'all'
} $ct
if ($conflictAct.code -eq 0) {
  $conflictId = $conflictAct.data.id
  if ($conflictId -ne $null) { $script:actIds += $conflictId }
  $clash = Post-Json '/api/signup/add' @{
    client_id = 'scope-' + [guid]::NewGuid().ToString('N'); activity_id = $conflictId
  } $st
  Assert-True ($clash.code -eq 409) '跨社团同时间段报名 -> 409(全局冲突校验)' $clash.msg
} else {
  Assert-True $false '创建冲突活动失败' $conflictAct.msg
}

# ---------- 改为仅本社团: 存量报名保留 ----------
$edit = Post-Json '/api/activity/update' @{
  activity_id = $openId; title = '[验收]公开活动'; content = '范围测试'; location = 'B-201';
  start_time = $t2; end_time = $e2; hours = 1; capacity = 2;
  category = 'skill'; join_scope = 'club'
} $ct
Assert-True ($edit.code -eq 0) '公开活动改为仅本社团' $edit.msg
Assert-True ($edit.data.outsider_count -ge 1) '返回已报名的外社团人数' ([string]$edit.data.outsider_count)

$kept = Get-Api ('/api/signup/list?activity_id=' + [string]$openId) $st
Assert-True ($kept.data.total -ge 1) '改范围后存量外社团报名保留' ([string]$kept.data.total)

# ---------- 清理 ----------
Write-Host "  清理测试数据..." -ForegroundColor DarkGray
if (Test-Path $Mysql) {
  $idList = ($script:actIds | ForEach-Object { [string]$_ }) -join ','
  $sql = "DELETE FROM signup WHERE activity_id IN (" + $idList + "); " +
  "DELETE FROM hours_total WHERE stu_no='" + $stuNo + "'; " +
  "DELETE FROM club_member WHERE stu_no='" + $stuNo + "'; " +
  "DELETE FROM student WHERE stu_no='" + $stuNo + "'; " +
  "DELETE FROM activity WHERE id IN (" + $idList + "); " +
  "UPDATE activity a SET a.taken=(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2);"
  # mysql 会把密码告警写到 stderr; 临时放宽 Stop 语义, 避免把告警当成失败
  $oldPref = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $Mysql -uroot -p123456 club_system -e $sql 2>&1 | Out-Null
  $ErrorActionPreference = $oldPref
  Write-Host "  已清理(测试活动 / 测试学生 / 其报名与学时)" -ForegroundColor DarkGray
} else {
  Write-Host "  未找到 mysql.exe, 测试数据保留, 请手工清理" -ForegroundColor Yellow
}

Write-Host ""
Write-Host ("结果: PASS=" + $script:pass + "  FAIL=" + $script:fail) -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 }

