# =====================================================================
# 入社/退社与社团注册验收 (v5.0 重构)
#
# 覆盖:
#   A) 社团注册: 正常提交 / 重复账号 409 / 重复社团名 409 / 缺字段 400
#   B) 平台管理员审核: 待审列表 / 通过(分配编号) / 驳回需理由 / 停用与恢复 / 重复审核 409
#   C) 登录三态: 待审核 403 / 已驳回 403 / 通过后可登录 + pending_request_count
#   D) 申请加入: 提交 / 重复申请 409 / 不存在社团 404
#   E) 社团审批: 列表含 other_clubs 参考信息 / 同意入册 / 并发审批恰一次 / 驳回需理由
#   F) 可见性联动: 加入前内部活动不可见, 审批通过后可见
#   G) 退出与复入: 申请退出 / 审批前仍可见 / 同意后不可见且学时保留 / 再次申请可复入
#   H) 边界: 社长不可退出本社团 / 跨社团审批 403 / 学生不可调审批接口
#
# 命名空间: 社团账号 vmtest1..3, 学生 2099301/2099302, 活动 id 动态收集。
# 自建自清理; 不修改演示基线(计算机协会/篮球协会/茶艺社不动)。
# 用法: powershell -ExecutionPolicy Bypass -File server\verify_membership.ps1
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

function TryCode($path, $obj, $token) {
  try {
    $r = Post-Json $path $obj $token
    return ('code=' + $r.code + ' msg=' + $r.msg)
  } catch {
    return ('http=' + [int]$_.Exception.Response.StatusCode)
  }
}

function Get-Api($path, $token) {
  $headers = @{}
  if ($token -ne '' -and $token -ne $null) { $headers['Authorization'] = 'Bearer ' + $token }
  return Invoke-RestMethod -Uri ($Base + $path) -Headers $headers
}

function Fmt-Time($offsetDays, $hour) {
  $d = (Get-Date).AddDays($offsetDays)
  return $d.ToString('yyyy-MM-dd') + ' ' + $hour + ':00:00'
}

Write-Host "=== 入社/退社与社团注册验收 (v5.0 重构) ===" -ForegroundColor Cyan

# ---------- 准备: 平台管理员 + 两个测试学生(注册并审批通过) ----------
$adm = Post-Json '/api/login' @{ type = 'admin'; account = 'admin'; secret = 'admin123' } ''
$at = $adm.data.token
Assert-True ($adm.code -eq 0) '平台管理员登录' $adm.msg

function New-Student($stuNo, $name) {
  $reg = Post-Json '/api/register' @{ stu_no = $stuNo; name = $name; dept = '验收学院'; pwd = '123456' } ''
  if ($reg.code -ne 0) { Write-Host ("  [INFO] " + $stuNo + " 注册返回: " + $reg.msg + " (可能是上次残留)") -ForegroundColor Yellow }
  $pend = Get-Api '/api/student/list?group=pending&size=100' $at
  $sid = -1
  foreach ($item in @($pend.data.list)) { if ($item.stu_no -eq $stuNo) { $sid = $item.id } }
  if ($sid -gt 0) { Post-Json '/api/student/audit' @{ student_id = $sid; action = 'pass' } $at | Out-Null }
  return (Post-Json '/api/login' @{ type = 'student'; account = $stuNo; secret = '123456' } '')
}

$s1 = New-Student '2099301' '入社测试甲'
Assert-True ($s1.code -eq 0) '测试学生甲(2099301)可登录' $s1.msg
$st1 = $s1.data.token
$s2 = New-Student '2099302' '入社测试乙'
Assert-True ($s2.code -eq 0) '测试学生乙(2099302)可登录' $s2.msg
$st2 = $s2.data.token

# ---------- A. 社团注册 ----------
Write-Host "-- A. 社团注册 --" -ForegroundColor Cyan
$badReg = TryCode '/api/club/register' @{ club_name = '缺账号社团'; pwd = 'vm123456' } ''
Assert-True ($badReg -like '*400*') '缺登录账号 -> 400' $badReg
$reg1 = Post-Json '/api/club/register' @{
  account = 'vmtest1'; club_name = '[验收]文学社'; pwd = 'vm123456'; dept = '文学院';
  intro = '验收用社团'; leader_name = '测试社长甲'; leader_stu_no = '2099301'
} ''
Assert-True ($reg1.code -eq 0) '社团注册提交成功' $reg1.msg
Post-Json '/api/club/register' @{
  account = 'vmtest2'; club_name = '[验收]棋社'; pwd = 'vm123456'; leader_name = '测试社长乙'
} '' | Out-Null
Post-Json '/api/club/register' @{
  account = 'vmtest3'; club_name = '[验收]摄影社'; pwd = 'vm123456'; leader_name = '测试社长丙'
} '' | Out-Null
$dupAcc = TryCode '/api/club/register' @{ account = 'vmtest1'; club_name = '[验收]另一社团'; pwd = 'vm123456' } ''
Assert-True ($dupAcc -like '*409*') '重复登录账号 -> 409' $dupAcc
$dupName = TryCode '/api/club/register' @{ account = 'vmtest9'; club_name = '[验收]文学社'; pwd = 'vm123456' } ''
Assert-True ($dupName -like '*409*') '重复社团名 -> 409' $dupName

# ---------- B. 平台管理员审核 ----------
Write-Host "-- B. 平台管理员审核 --" -ForegroundColor Cyan
$clubs = Get-Api '/api/admin/clubs?status=0&size=50' $at
Assert-True ($clubs.code -eq 0) '管理员查看待审社团列表' $clubs.msg
$ids = @{}
foreach ($c in @($clubs.data.list)) { $ids[$c.account] = [int]$c.club_id }
Assert-True ($ids.ContainsKey('vmtest1') -and $ids.ContainsKey('vmtest2') -and $ids.ContainsKey('vmtest3')) '三个待审社团均在列表中' (($ids.Keys -join ','))
$c1id = $ids['vmtest1']; $c2id = $ids['vmtest2']; $c3id = $ids['vmtest3']

$rejNoReason = TryCode '/api/admin/club/audit' @{ club_id = $c2id; action = 'reject' } $at
Assert-True ($rejNoReason -like '*400*') '驳回缺理由 -> 400' $rejNoReason
$rej = Post-Json '/api/admin/club/audit' @{ club_id = $c2id; action = 'reject'; reason = '验收驳回' } $at
Assert-True ($rej.code -eq 0 -and [int]$rej.data.status -eq 2) '驳回社团注册 -> status=2' $rej.msg
$apr = Post-Json '/api/admin/club/audit' @{ club_id = $c1id; action = 'approve' } $at
Assert-True ($apr.code -eq 0 -and [int]$apr.data.status -eq 1) '通过社团注册 -> status=1(独立编号已分配)' $apr.msg
$apr2 = TryCode '/api/admin/club/audit' @{ club_id = $c1id; action = 'approve' } $at
Assert-True ($apr2 -like '*409*') '重复审核 -> 409' $apr2
$auditedAt = Get-Api ('/api/admin/clubs?kw=vmtest1') $at
Assert-True ($auditedAt.data.list[0].audited_at -ne '') '审核时间已留痕' ([string]$auditedAt.data.list[0].audited_at)

# 停用/恢复链路: 必须先通过审核(1), 再停用(3), 再恢复(1)
$apr3 = Post-Json '/api/admin/club/audit' @{ club_id = $c3id; action = 'approve' } $at
Assert-True ($apr3.code -eq 0) '摄影社先通过审核(status=1)' $apr3.msg
$dis = Post-Json '/api/admin/club/audit' @{ club_id = $c3id; action = 'disable'; reason = '验收停用' } $at
Assert-True ($dis.code -eq 0) '对正常社团执行停用 -> status=3' $dis.msg
$en = Post-Json '/api/admin/club/audit' @{ club_id = $c3id; action = 'enable' } $at
Assert-True ($en.code -eq 0 -and [int]$en.data.status -eq 1) '恢复社团 -> status=1' $en.msg

# ---------- C. 登录三态 ----------
Write-Host "-- C. 登录三态 --" -ForegroundColor Cyan
# 停用登录用例: B 节已把 vmtest3 恢复为 1, 这里先再停用再测, 测完恢复
$dis2 = Post-Json '/api/admin/club/audit' @{ club_id = $c3id; action = 'disable'; reason = '验收停用-登录态' } $at
Assert-True ($dis2.code -eq 0) '再次停用摄影社' $dis2.msg
$pendLogin = TryCode '/api/login' @{ type = 'club'; account = 'vmtest3'; secret = 'vm123456' } ''
Assert-True ($pendLogin -like '*403*') '停用社团登录 -> 403' $pendLogin
$en2 = Post-Json '/api/admin/club/audit' @{ club_id = $c3id; action = 'enable' } $at
Assert-True ($en2.code -eq 0) '恢复摄影社(还原)' $en2.msg
$rejLogin = TryCode '/api/login' @{ type = 'club'; account = 'vmtest2'; secret = 'vm123456' } ''
Assert-True ($rejLogin -like '*403*') '已驳回社团登录 -> 403' $rejLogin
$cl = Post-Json '/api/login' @{ type = 'club'; account = 'vmtest1'; secret = 'vm123456' } ''
Assert-True ($cl.code -eq 0) '审核通过的社团可登录' $cl.msg
$ct = $cl.data.token
Assert-True ($null -ne $cl.data.pending_request_count) '登录下发 pending_request_count' ''

# ---------- D. 申请加入 ----------
Write-Host "-- D. 申请加入 --" -ForegroundColor Cyan
$j1 = Post-Json '/api/club/join' @{ club_id = $c1id; reason = '热爱文学' } $st1
Assert-True ($j1.code -eq 0) '学生甲申请加入文学社' $j1.msg
$j2 = TryCode '/api/club/join' @{ club_id = $c1id } $st1
Assert-True ($j2 -like '*409*') '重复申请 -> 409' $j2
$j3 = TryCode '/api/club/join' @{ club_id = 999999 } $st1
Assert-True ($j3 -like '*404*') '加入不存在的社团 -> 404' $j3
$sq = Get-Api '/api/club/square' $st1
$mine = @($sq.data.list | Where-Object { $_.club_id -eq $c1id })[0]
Assert-True ([int]$mine.my_status -eq 2) '广场显示申请审核中(my_status=2)' ([string]$mine.my_status)

# ---------- E. 社团审批 ----------
Write-Host "-- E. 社团审批 --" -ForegroundColor Cyan
# 学生乙先加入计算机协会(id=1), 供审批页 other_clubs 参考信息用例
$jPre = Post-Json '/api/club/join' @{ club_id = 1; reason = '先加入已有社团' } $st2
Assert-True ($jPre.code -eq 0) '学生乙申请加入计算机协会' $jPre.msg
$c1tok = (Post-Json '/api/login' @{ type = 'club'; account = 'club'; secret = 'club123' } '').data.token
$reqs1 = Get-Api '/api/club/requests' $c1tok
$rPre = @($reqs1.data.list | Where-Object { $_.stu_no -eq '2099302' })[0]
Assert-True ($null -ne $rPre) '待审列表包含学生乙的申请' ''
$apPre = Post-Json '/api/club/request/audit' @{ request_id = $rPre.id; approve = 1 } $c1tok
Assert-True ($apPre.code -eq 0) '计算机协会同意学生乙加入' $apPre.msg

$jB = Post-Json '/api/club/join' @{ club_id = $c1id; reason = '也想加入文学社' } $st2
Assert-True ($jB.code -eq 0) '学生乙申请加入文学社' $jB.msg
$reqs = Get-Api '/api/club/requests' $ct
$rB = @($reqs.data.list | Where-Object { $_.stu_no -eq '2099302' })[0]
Assert-True ($null -ne $rB) '文学社待审列表包含学生乙' ''
Assert-True ($rB.other_clubs -like '*计算机协会*') '审批页显示申请人已加入社团(other_clubs)' ([string]$rB.other_clubs)
$noReason = TryCode '/api/club/request/audit' @{ request_id = $rB.id; approve = 0 } $ct
Assert-True ($noReason -like '*400*') '驳回缺理由 -> 400' $noReason

# 学生甲的申请(D 节提交)作为并发审批对象
$reqsA = Get-Api '/api/club/requests' $ct
$rA = @($reqsA.data.list | Where-Object { $_.stu_no -eq '2099301' -and $_.status -eq 0 })[0]
Assert-True ($null -ne $rA) '文学社待审列表包含学生甲的申请' ''
$concScript = {
  param($ApiBase, $Bearer, $ReqId)
  $headers = @{ 'Authorization' = ('Bearer ' + $Bearer) }
  $body = [System.Text.Encoding]::UTF8.GetBytes(('{"request_id":' + $ReqId + ',"approve":1}'))
  try {
    $r = Invoke-RestMethod -Uri ($ApiBase + '/api/club/request/audit') -Method Post -Headers $headers `
      -ContentType 'application/json; charset=utf-8' -Body $body
    return ('code=' + $r.code)
  } catch { return ('http=' + [int]$_.Exception.Response.StatusCode) }
}
$cj1 = Start-Job -ScriptBlock $concScript -ArgumentList $Base, $ct, $rA.id
$cj2 = Start-Job -ScriptBlock $concScript -ArgumentList $Base, $ct, $rA.id
Wait-Job $cj1, $cj2 -Timeout 60 | Out-Null
$resA = (@(Receive-Job $cj1) -join ' ')
$resB = (@(Receive-Job $cj2) -join ' ')
Remove-Job $cj1, $cj2 -Force
$okCnt = 0
if ($resA -like 'code=0*') { $okCnt++ }
if ($resB -like 'code=0*') { $okCnt++ }
Assert-True ($okCnt -eq 1) '并发审批恰好成功一次' ($resA + ' | ' + $resB)
$memRow = Get-Api '/api/club/members?kw=2099301' $ct
Assert-True (([int]$memRow.data.total -eq 1) -and ($memRow.data.list[0].status -eq 1)) '审批通过后学生甲在册' ([string]$memRow.data.total)
$again = TryCode '/api/club/request/audit' @{ request_id = $rA.id; approve = 1 } $ct
Assert-True ($again -like '*409*') '重复审批同一申请 -> 409' $again
$cross = TryCode '/api/club/request/audit' @{ request_id = $rPre.id; approve = 1 } $ct
Assert-True ($cross -like '*403*') '跨社团审批他社申请 -> 403' $cross
$apB = Post-Json '/api/club/request/audit' @{ request_id = $rB.id; approve = 1 } $ct
Assert-True ($apB.code -eq 0) '文学社同意学生乙加入' $apB.msg

# ---------- F. 可见性联动 ----------
Write-Host "-- F. 可见性联动 --" -ForegroundColor Cyan
$tIn = Fmt-Time 14 '19'
$eIn = Fmt-Time 14 '21'
$innerAct = Post-Json '/api/activity/add' @{
  title = '[验收]文学社内部活动'; content = '联动测试'; location = 'D-401';
  start_time = $tIn; end_time = $eIn; hours = 1; capacity = 10;
  category = 'social'; join_scope = 'club'
} $ct
Assert-True ($innerAct.code -eq 0) '文学社发布内部活动' $innerAct.msg
if ($innerAct.data.id -ne $null) { $script:actIds += [int]$innerAct.data.id }
$visible = Get-Api '/api/activity/list?size=0' $st1
$hit = @($visible.data.list | Where-Object { $_.id -eq [int]$innerAct.data.id })
Assert-True ($hit.Count -eq 1) '入社审批通过后可看到内部活动' ([string]$hit.Count)
$sq1 = Get-Api '/api/club/square' $st1
$mine1 = @($sq1.data.list | Where-Object { $_.club_id -eq $c1id })[0]
Assert-True ([int]$mine1.my_status -eq 1) '广场显示在册(my_status=1)' ([string]$mine1.my_status)

# ---------- G. 退出与复入 ----------
Write-Host "-- G. 退出与复入 --" -ForegroundColor Cyan
$lv = Post-Json '/api/club/leave' @{ club_id = $c1id; reason = '学业繁忙' } $st1
Assert-True ($lv.code -eq 0) '学生甲申请退出文学社' $lv.msg
$sq2 = Get-Api '/api/club/square' $st1
$mine2 = @($sq2.data.list | Where-Object { $_.club_id -eq $c1id })[0]
Assert-True ([int]$mine2.my_status -eq 5) '退出审核中仍显示成员态(my_status=5)' ([string]$mine2.my_status)
$vis2 = Get-Api '/api/activity/list?size=0' $st1
$hit2 = @($vis2.data.list | Where-Object { $_.id -eq [int]$innerAct.data.id })
Assert-True ($hit2.Count -eq 1) '退出审批期间内部活动仍可见(仍是成员)' ([string]$hit2.Count)
$reqs2 = Get-Api '/api/club/requests' $ct
$rLv = @($reqs2.data.list | Where-Object { $_.stu_no -eq '2099301' -and $_.type -eq 2 })[0]
Assert-True ($null -ne $rLv) '待审列表出现退出申请(type=2)' ''
$lvOk = Post-Json '/api/club/request/audit' @{ request_id = $rLv.id; approve = 1 } $ct
Assert-True ($lvOk.code -eq 0) '社团同意退出' $lvOk.msg
$vis3 = Get-Api '/api/activity/list?size=0' $st1
$hit3 = @($vis3.data.list | Where-Object { $_.id -eq [int]$innerAct.data.id })
Assert-True ($hit3.Count -eq 0) '退出后内部活动不可见' ([string]$hit3.Count)
$mem2 = Get-Api '/api/club/members?kw=2099301' $ct
Assert-True (([int]$mem2.data.total -eq 1) -and ($mem2.data.list[0].status -eq 0)) '退出后在册状态=0(历史保留)' ([string]$mem2.data.total)
$re = Post-Json '/api/club/join' @{ club_id = $c1id; reason = '重新申请' } $st1
Assert-True ($re.code -eq 0) '退出后可重新申请加入' $re.msg
$reqs3 = Get-Api '/api/club/requests' $ct
$rRe = @($reqs3.data.list | Where-Object { $_.stu_no -eq '2099301' -and $_.type -eq 1 -and $_.status -eq 0 })[0]
$reOk = Post-Json '/api/club/request/audit' @{ request_id = $rRe.id; approve = 1 } $ct
Assert-True ($reOk.code -eq 0) '复入审批通过' $reOk.msg
$mem3 = Get-Api '/api/club/members?kw=2099301' $ct
Assert-True ($mem3.data.list[0].status -eq 1) '复入后重新在册' ([string]$mem3.data.list[0].status)

# ---------- H. 边界 ----------
Write-Host "-- H. 边界 --" -ForegroundColor Cyan
$ldr = Post-Json '/api/login' @{ type = 'student'; account = '2023001'; secret = '123456' } ''
$lout = TryCode '/api/club/leave' @{ club_id = 1 } $ldr.data.token
Assert-True ($lout -like '*400*') '社长不可退出本社团 -> 400' $lout
$stuAudit = TryCode '/api/club/request/audit' @{ request_id = $rRe.id; approve = 1 } $st1
Assert-True ($stuAudit -like '*403*') '学生不可调用审批接口 -> 403' $stuAudit
$admJoin = TryCode '/api/club/join' @{ club_id = $c1id } $at
Assert-True ($admJoin -like '*403*') '平台管理员不可申请加入社团 -> 403' $admJoin

# ---------- 清理 ----------
Write-Host "  清理测试数据..." -ForegroundColor DarkGray
if (Test-Path $Mysql) {
  $idList = ($script:actIds | ForEach-Object { [string]$_ }) -join ','
  if ($idList -eq '') { $idList = '0' }
  $sql = "DELETE r FROM club_member_request r JOIN club c ON r.club_id=c.id WHERE c.account LIKE 'vmtest%'; " +
  "DELETE FROM club_member WHERE club_id IN (SELECT id FROM club WHERE account LIKE 'vmtest%'); " +
  "DELETE FROM club_leader_history WHERE club_id IN (SELECT id FROM club WHERE account LIKE 'vmtest%'); " +
  "DELETE FROM club_member_request WHERE stu_no IN ('2099301','2099302'); " +
  "DELETE FROM club_member WHERE stu_no IN ('2099301','2099302'); " +
  "DELETE FROM hours_total WHERE stu_no IN ('2099301','2099302'); " +
  "DELETE FROM signup WHERE stu_no IN ('2099301','2099302') OR activity_id IN (" + $idList + "); " +
  "DELETE FROM student WHERE stu_no IN ('2099301','2099302'); " +
  "DELETE FROM activity WHERE id IN (" + $idList + "); " +
  "DELETE FROM club WHERE account LIKE 'vmtest%'; " +
  "UPDATE activity a SET a.taken=(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2);"
  $oldPref = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $Mysql -uroot -p123456 club_system -e $sql 2>&1 | Out-Null
  $ErrorActionPreference = $oldPref
  Write-Host "  已清理(测试社团/学生/申请/活动; 计算机协会与茶艺社待审数据保留)" -ForegroundColor DarkGray
} else {
  Write-Host "  未找到 mysql.exe, 测试数据保留, 请手工清理" -ForegroundColor Yellow
}

Write-Host ""
Write-Host ("结果: PASS=" + $script:pass + "  FAIL=" + $script:fail) -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 }

