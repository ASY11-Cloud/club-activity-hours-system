# =====================================================================
# 社团账号 + 换届闭环验收 (v5.0)
#
# 覆盖:
#   1) 社团账号登录(club 类型), 下发 role/club_id/club_name
#   2) 社团信息: 现任社长 / 成员数 / 统计口径
#   3) 换届: 密码错误 403 / 期望值冲突 409 / 成功 / 幂等
#   4) 历任社长: 在任唯一、旧任已结束、操作人留痕
#   5) 换届后账号与密码不变(用同一账号重新登录成功)
#   6) 并发换届: 同一 expect_leader 并发提交恰一次成功, 在任记录仍唯一
#   7) 成员管理: 岗位口径 / 社长不可移除 / 移除后在册数减一且幂等
#   8) 通知公告: 发布 / 成员可见 / 置顶 / 已读 / 撤回后成员不可见
#   9) 社团维度统计: 与 /api/club/info 同口径, 覆盖内部/公开/外社团参与
#  10) 审计: /api/log/list 里能查到换届记录
#  11) 节流: 连续错密码后 429(放最后, 不影响前面的恢复动作)
#
# 注意: 本脚本会真实换届两次(测试社长 -> 恢复原社长), 历史记录会保留,
#       这正是"换届可追溯"的预期行为; 演示库如需纯净, 请先备份。
#
# 用法: powershell -ExecutionPolicy Bypass -File server\verify_club.ps1
# =====================================================================
param(
  # 节流用例会锁住 clubleader|<ip>|1 达 60 秒, 使脚本无法连续重跑, 默认关闭。
  # 首次验收需要覆盖时: -WithThrottle
  [switch]$WithThrottle
)
$ErrorActionPreference = 'Stop'
$Base = 'http://127.0.0.1:8000'
$Mysql = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe'
$script:pass = 0
$script:fail = 0

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
  $json = $obj | ConvertTo-Json -Depth 6
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
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

Write-Host "=== 社团账号与换届验收 (v5.0) ===" -ForegroundColor Cyan

# ---------- 1. 健康检查 ----------
$h = Get-Api '/api/health' ''
Assert-True ($h.code -eq 0) '服务健康检查' ($h | ConvertTo-Json -Compress)
Assert-True ($h.data.version -eq '5.0') '版本号为 5.0' ('actual=' + $h.data.version)

# ---------- 2. 社团账号登录 ----------
$login = Post-Json '/api/login' @{ type = 'club'; account = 'club'; secret = 'club123' } ''
Assert-True ($login.code -eq 0) '社团账号登录成功' ($login.msg)
$token = $login.data.token
Assert-True ($login.data.role -eq 'admin') '对外 role 仍为 admin(兼容旧判断)' $login.data.role
Assert-True ($login.data.club_id -eq 1) '下发 club_id=1' ([string]$login.data.club_id)
Assert-True ($login.data.club_name -ne '') '下发 club_name' $login.data.club_name
Assert-True ($login.data.account_type -eq 'club') '下发 account_type=club' $login.data.account_type

# ---------- 3. 社团信息 ----------
$info = Get-Api '/api/club/info' $token
Assert-True ($info.code -eq 0) '读取社团信息' $info.msg
$oldLeader = $info.data.leader_name
$oldStu = $info.data.leader_stu_no
$oldMembers = $info.data.member_count
Assert-True ($oldLeader -ne '') '存在现任社长' $oldLeader
Assert-True ($info.data.member_count -ge 1) '成员数 >= 1' ([string]$info.data.member_count)

$leaders0 = Get-Api '/api/club/leaders?page=1&size=50' $token
Assert-True ($leaders0.code -eq 0) '读取历任社长' $leaders0.msg

# ---------- 4. 换届失败分支 ----------
$bad = Post-Json '/api/club/leader' @{
  new_name = '测试社长'; new_stu_no = '2099002'; confirm_pwd = 'wrong-password'
  reason = '验收脚本'; expect_leader = $oldLeader
} $token
Assert-True ($bad.code -eq 403) '密码错误 -> 403' $bad.msg

$conflict = Post-Json '/api/club/leader' @{
  new_name = '测试社长'; new_stu_no = '2099002'; confirm_pwd = 'club123'
  reason = '验收脚本'; expect_leader = '不存在的社长'
} $token
Assert-True ($conflict.code -eq 409) 'expect_leader 冲突 -> 409' $conflict.msg

$noName = Post-Json '/api/club/leader' @{
  new_name = ''; confirm_pwd = 'club123'
} $token
Assert-True ($noName.code -eq 400) '空姓名 -> 400' $noName.msg

# ---------- 5. 换届成功 ----------
$ok = Post-Json '/api/club/leader' @{
  new_name = '测试社长'; new_stu_no = '2099002'; confirm_pwd = 'club123'
  reason = '验收脚本: 验证换届'; expect_leader = $oldLeader
} $token
Assert-True ($ok.code -eq 0) '换届成功' $ok.msg
Assert-True ($ok.data.leader_name -eq '测试社长') '返回新社长' $ok.data.leader_name

$info2 = Get-Api '/api/club/info' $token
Assert-True ($info2.data.leader_name -eq '测试社长') '社团信息已更新' $info2.data.leader_name
Assert-True ($info2.data.leader_stu_no -eq '2099002') '新社长学号已更新' $info2.data.leader_stu_no
Assert-True ($info2.data.member_count -eq ($oldMembers + 1)) '新社长自动纳入成员' `
  ([string]$info2.data.member_count + ' vs ' + [string]($oldMembers + 1))

$leaders1 = Get-Api '/api/club/leaders?page=1&size=50' $token
$current = @($leaders1.data.list | Where-Object { $_.is_current -eq $true })
Assert-True ($current.Count -eq 1) '在任记录唯一' ([string]$current.Count)
Assert-True ($current[0].leader_name -eq '测试社长') '在任记录为新社长' $current[0].leader_name
$oldRec = @($leaders1.data.list | Where-Object { $_.leader_name -eq $oldLeader -and $_.end_at -ne '' })
Assert-True ($oldRec.Count -ge 1) '上一任已写入结束时间' ([string]$oldRec.Count)
Assert-True ($current[0].operator -ne '') '操作人已留痕' $current[0].operator

# ---------- 6. 账号与密码不变 ----------
$relogin = Post-Json '/api/login' @{ type = 'club'; account = 'club'; secret = 'club123' } ''
Assert-True ($relogin.code -eq 0) '换届后同一账号密码仍可登录' $relogin.msg
Assert-True ($relogin.data.club_id -eq 1) 'club_id 未变' ([string]$relogin.data.club_id)

# ---------- 7. 恢复原社长 ----------
$restore = Post-Json '/api/club/leader' @{
  new_name = $oldLeader; new_stu_no = $oldStu; confirm_pwd = 'club123'
  reason = '验收脚本: 恢复原社长'; expect_leader = '测试社长'
} $token
Assert-True ($restore.code -eq 0) '恢复原社长成功' $restore.msg
$leaders2 = Get-Api '/api/club/leaders?page=1&size=50' $token
$cur2 = @($leaders2.data.list | Where-Object { $_.is_current -eq $true })
Assert-True ($cur2.Count -eq 1 -and $cur2[0].leader_name -eq $oldLeader) '恢复后在任记录正确' $cur2[0].leader_name

# 清理测试社长在 club_member 中的在册记录(学号 2099002 不是真实学生)
$clean = Post-Json '/api/club/member/remove' @{ stu_no = '2099002' } $token
Assert-True ($clean.code -eq 0) '清理测试社长的成员记录' $clean.msg

# ---------- 7.5 并发换届: 同一 expect_leader 只许成功一次 ----------
# 两个后台 Job 同时携带同一个 expect_leader 提交, 期望: 行锁串行化 + 乐观比对 => 恰一次成功,
# 且 club_leader_history 里不会出现两条 end_at IS NULL 的在任记录。
$concNameA = '并发甲'
$concNameB = '并发乙'
$concScript = {
  param($ApiBase, $Bearer, $NewName, $NewStu, $Expect)
  $hdrs = @{ 'Authorization' = ('Bearer ' + $Bearer) }
  $payload = @{
    new_name = $NewName; new_stu_no = $NewStu; confirm_pwd = 'club123'
    reason = '并发验收'; expect_leader = $Expect
  } | ConvertTo-Json -Depth 6
  $body = [System.Text.Encoding]::UTF8.GetBytes($payload)
  try {
    $r = Invoke-RestMethod -Uri ($ApiBase + '/api/club/leader') -Method Post -Headers $hdrs `
      -ContentType 'application/json; charset=utf-8' -Body $body
    return ('code=' + [string]$r.code + ' name=' + [string]$r.data.leader_name)
  } catch {
    return ('http=' + [string][int]$_.Exception.Response.StatusCode)
  }
}
$cj1 = Start-Job -ScriptBlock $concScript -ArgumentList $Base, $token, $concNameA, '2099901', $oldLeader
$cj2 = Start-Job -ScriptBlock $concScript -ArgumentList $Base, $token, $concNameB, '2099902', $oldLeader
Wait-Job $cj1, $cj2 -Timeout 60 | Out-Null
$resA = (@(Receive-Job $cj1) -join ' ')
$resB = (@(Receive-Job $cj2) -join ' ')
Remove-Job $cj1, $cj2 -Force
Write-Host ("  并发返回: " + $resA + " | " + $resB) -ForegroundColor DarkGray
$okCount = 0
if ($resA -like 'code=0*') { $okCount++ }
if ($resB -like 'code=0*') { $okCount++ }
Assert-True ($okCount -eq 1) '并发换届恰好成功一次' ($resA + ' | ' + $resB)

$leaders3 = Get-Api '/api/club/leaders?page=1&size=50' $token
$cur3 = @($leaders3.data.list | Where-Object { $_.is_current -eq $true })
Assert-True ($cur3.Count -eq 1) '并发后在任记录仍唯一' ([string]$cur3.Count)
$winName = $cur3[0].leader_name
Assert-True ($winName -eq $concNameA -or $winName -eq $concNameB) '胜出者为两次提交之一' $winName
$fakeStu = if ($winName -eq $concNameA) { '2099901' } else { '2099902' }

$restore2 = Post-Json '/api/club/leader' @{
  new_name = $oldLeader; new_stu_no = $oldStu; confirm_pwd = 'club123'
  reason = '验收脚本: 并发测试后恢复'; expect_leader = $winName
} $token
Assert-True ($restore2.code -eq 0) '并发测试后恢复原社长' $restore2.msg

# ---------- 7.6 成员管理: 岗位口径 / 移除保留学时 ----------
$mem = Get-Api '/api/club/members?page=1&size=100' $token
Assert-True ($mem.code -eq 0) '读取社团成员列表' $mem.msg
Assert-True ($mem.data.leader_count -eq 1) '岗位计数: 社长唯一' ([string]$mem.data.leader_count)
$leaderRows = @($mem.data.list | Where-Object { $_.role -eq 'leader' })
Assert-True ($leaderRows.Count -eq 1 -and $leaderRows[0].stu_no -eq $oldStu) '社长岗位与 leader_stu_no 一致' `
  ($leaderRows[0].stu_no + ' vs ' + $oldStu)
$memByRole = Get-Api '/api/club/members?role=leader&size=100' $token
Assert-True ($memByRole.data.total -eq 1) '岗位筛选只返回社长' ([string]$memByRole.data.total)

$rmLeader = Post-Json '/api/club/member/remove' @{ stu_no = $oldStu } $token
Assert-True ($rmLeader.code -eq 400) '现任社长不可直接移除 -> 400' $rmLeader.msg

$beforeRemove = (Get-Api '/api/club/info' $token).data.member_count
$rmFake = Post-Json '/api/club/member/remove' @{ stu_no = $fakeStu } $token
Assert-True ($rmFake.code -eq 0) '移除普通成员成功' $rmFake.msg
$afterRemove = (Get-Api '/api/club/info' $token).data.member_count
Assert-True ($afterRemove -eq ($beforeRemove - 1)) '移除后在册成员数减一' `
  ([string]$beforeRemove + ' -> ' + [string]$afterRemove)
$againRemove = Post-Json '/api/club/member/remove' @{ stu_no = $fakeStu } $token
Assert-True ($againRemove.code -eq 0) '重复移除幂等(不报错)' $againRemove.msg

# ---------- 7.7 通知公告: 发布 / 成员可见 / 已读 / 撤回 ----------
$stuAnn = Post-Json '/api/login' @{ type = 'student'; account = '2023005'; secret = '123456' } ''
Assert-True ($stuAnn.code -eq 0) '社团成员学生可登录(公告用例)' $stuAnn.msg
$annToken = $stuAnn.data.token
$annTitle = '[验收]社团公告'
$annAdd = Post-Json '/api/announcement/add' @{
  title = $annTitle; content = '验收正文: 社团账号发布的公告'; top_flag = 1
} $token
Assert-True ($annAdd.code -eq 0) '社团账号发布置顶公告' $annAdd.msg
$annId = $annAdd.data.id

$stuList = Get-Api '/api/announcement/list?page=1&size=20' $annToken
$seen = @($stuList.data.list | Where-Object { $_.id -eq $annId })
Assert-True ($seen.Count -eq 1) '本社团成员可见公告' ([string]$seen.Count)
Assert-True ($seen[0].top_flag -eq 1) '公告置顶标记正确' ([string]$seen[0].top_flag)
Assert-True ($seen[0].is_read -eq $false) '新公告初始为未读' ([string]$seen[0].is_read)
$unreadBefore = [int]$stuList.data.unread_count

$markRead = Post-Json '/api/announcement/read' @{ ann_id = $annId } $annToken
Assert-True ($markRead.code -eq 0) '成员标记已读' $markRead.msg
$stuList2 = Get-Api '/api/announcement/list?page=1&size=20' $annToken
$seen2 = @($stuList2.data.list | Where-Object { $_.id -eq $annId })
Assert-True ($seen2[0].is_read -eq $true) '已读状态回显' ([string]$seen2[0].is_read)
Assert-True ([int]$stuList2.data.unread_count -eq ($unreadBefore - 1)) '未读计数减一' `
  ([string]$unreadBefore + ' -> ' + [string]$stuList2.data.unread_count)

$retract = Post-Json '/api/announcement/status' @{ ann_id = $annId; status = 0 } $token
Assert-True ($retract.code -eq 0) '撤回公告' $retract.msg
$stuList3 = Get-Api '/api/announcement/list?page=1&size=20' $annToken
$seen3 = @($stuList3.data.list | Where-Object { $_.id -eq $annId })
Assert-True ($seen3.Count -eq 0) '已撤回公告对成员不可见' ([string]$seen3.Count)
$admList = Get-Api '/api/announcement/list?page=1&size=50' $token
$seen4 = @($admList.data.list | Where-Object { $_.id -eq $annId })
Assert-True ($seen4.Count -eq 1 -and $seen4[0].status -eq 0) '社团管理员仍可见已撤回公告' `
  ([string]$seen4.Count)

# ---------- 7.8 社团维度统计 ----------
$stats = Get-Api '/api/stats/club' $token
Assert-True ($stats.code -eq 0) '读取社团维度统计' $stats.msg
Assert-True ($stats.data.club_id -eq 1) '统计按 Token 的 club_id 收敛' ([string]$stats.data.club_id)
$infoStat = Get-Api '/api/club/info' $token
Assert-True ($stats.data.member_count -eq $infoStat.data.member_count) '成员数与社团信息一致' `
  ([string]$stats.data.member_count + ' vs ' + [string]$infoStat.data.member_count)
Assert-True ($stats.data.activity_count -eq $infoStat.data.activity_count) '活动数与社团信息一致' `
  ([string]$stats.data.activity_count + ' vs ' + [string]$infoStat.data.activity_count)
Assert-True (([int]$stats.data.internal_count + [int]$stats.data.public_count) -le [int]$stats.data.activity_count) `
  '内部+公开活动数不超过活动总数' ([string]$stats.data.internal_count + '+' + [string]$stats.data.public_count)
Assert-True ([int]$stats.data.passed_count -le [int]$stats.data.signup_count) '通过数不超过报名总数' `
  ([string]$stats.data.passed_count + '/' + [string]$stats.data.signup_count)
Assert-True ([double]$stats.data.pass_rate -ge 0 -and [double]$stats.data.pass_rate -le 100) '通过率在 0-100 之间' `
  ([string]$stats.data.pass_rate)
Assert-True ([int]$stats.data.outsider_count -ge 0) '外社团参与人数指标可用' ([string]$stats.data.outsider_count)

# ---------- 8. 审计留痕 ----------
$adm = Post-Json '/api/login' @{ type = 'admin'; account = 'admin'; secret = 'admin123' } ''
$logs = Get-Api '/api/logs?size=50' $adm.data.token
$hit = @()
if ($logs.code -eq 0) {
  $arr = @()
  if ($logs.data.logs -ne $null) { $arr = @($logs.data.logs) }
  elseif ($logs.data.list -ne $null) { $arr = @($logs.data.list) }
  $hit = @($arr | Where-Object { $_.detail -like '*社团换届*' })
}
Assert-True ($hit.Count -ge 1) '操作日志可查到换届记录' ([string]$hit.Count)

# ---------- 9. 清理公告与假成员(历史记录刻意保留, 这是"换届留痕"的预期) ----------
if (Test-Path $Mysql) {
  $cleanSql = "DELETE r FROM announcement_read r JOIN announcement a ON r.ann_id=a.id WHERE a.title LIKE '[验收]%'; " +
  "DELETE FROM announcement WHERE title LIKE '[验收]%'; " +
  "DELETE FROM club_member WHERE stu_no IN ('2099002','2099901','2099902');"
  $oldPref = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $Mysql -uroot -p123456 club_system -e $cleanSql 2>&1 | Out-Null
  $ErrorActionPreference = $oldPref
  Write-Host "  已清理(公告 / 测试社长成员记录)" -ForegroundColor DarkGray
} else {
  Write-Host "  未找到 mysql.exe, 验收公告与假成员记录保留, 请手工清理" -ForegroundColor Yellow
}

# ---------- 10. 节流(可选, 放最后) ----------
if ($WithThrottle) {
  for ($i = 0; $i -lt 5; $i++) {
    Post-Json '/api/club/leader' @{
      new_name = '节流测试'; confirm_pwd = 'bad-pwd-' + [string]$i; expect_leader = $oldLeader
    } $token | Out-Null
  }
  $blocked = Post-Json '/api/club/leader' @{
    new_name = '节流测试'; confirm_pwd = 'club123'; expect_leader = $oldLeader
  } $token
  Assert-True ($blocked.code -eq 429) '连续错密码后节流 -> 429' $blocked.msg
  Write-Host "  提示: 节流已触发, 60 秒内本机无法再换届" -ForegroundColor Yellow
} else {
  Write-Host "  [SKIP] 节流用例(需要时加 -WithThrottle)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host ("结果: PASS=" + $script:pass + "  FAIL=" + $script:fail) -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 }
