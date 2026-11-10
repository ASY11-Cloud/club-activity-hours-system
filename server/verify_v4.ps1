# =====================================================================
# v4.0 验收脚本（PowerShell，无 Python 环境可用）
#
# 覆盖：学时申诉闭环 / 七大类规则读写 / 签到异常检测 / 权限矩阵 / 基线复原
# 数据隔离：学号 V90xx、id 9100-9199；执行前后都清理，不碰演示基线
#
# 用法：powershell -ExecutionPolicy Bypass -File verify_v4.ps1
# 退出码 0 = 全绿；1 = 有失败
# =====================================================================
$ErrorActionPreference = 'Stop'

# 本脚本断言依赖中文比对, 必须按 UTF-8 解码子进程输出(控制台默认 GBK 会把 mysql 的 utf8 输出读成乱码)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:MYSQL_PWD = '123456'
$MYSQL = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe'
$BASE = 'http://127.0.0.1:8000'
$script:pass = 0
$script:fail = 0

function Check([string]$name, $cond, [string]$extra = '') {
  if ($cond) {
    $script:pass++
    Write-Host ('  [PASS] ' + $name + $(if ($extra) { ' ' + $extra } else { '' }))
  } else {
    $script:fail++
    Write-Host ('  [FAIL] ' + $name + $(if ($extra) { ' ' + $extra } else { '' })) -ForegroundColor Red
  }
}

function Sql([string]$q) {
  $out = & $MYSQL -uroot --default-character-set=utf8mb4 -N -B -e ("USE club_system; " + $q) 2>$null
  return @($out)
}

function Scalar([string]$q) {
  $rows = @(Sql $q)
  if ($rows.Count -eq 0) { return '' }
  $line = [string]$rows[0]
  if ($line -eq '') { return '' }
  return ($line -split "`t")[0]
}

function Num([string]$q) {
  $v = Scalar $q
  if ($v -eq '' -or $v -eq 'NULL') { return 0 }
  return [double]$v
}

function Api([string]$method, [string]$path, $body = $null, [string]$token = '') {
  $headers = @{ 'Content-Type' = 'application/json; charset=utf-8' }
  if ($token) { $headers['Authorization'] = 'Bearer ' + $token }
  $uri = $BASE + $path
  try {
    if ($null -ne $body) {
      $json = ConvertTo-Json $body -Depth 6 -Compress
      return Invoke-RestMethod -Method $method -Uri $uri -Headers $headers `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 10
    }
    return Invoke-RestMethod -Method $method -Uri $uri -Headers $headers -TimeoutSec 10
  } catch {
    $resp = $_.Exception.Response
    if ($resp -ne $null) {
      try {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
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

function CleanupTestData {
  Sql "DELETE FROM appeal WHERE stu_no LIKE 'V90%' OR signup_id BETWEEN 9100 AND 9199" | Out-Null
  Sql "DELETE FROM signup WHERE stu_no LIKE 'V90%' OR id BETWEEN 9100 AND 9199" | Out-Null
  Sql "DELETE FROM hours_total WHERE stu_no LIKE 'V90%'" | Out-Null
  Sql "DELETE FROM activity WHERE id BETWEEN 9100 AND 9199" | Out-Null
  Sql "DELETE FROM student WHERE stu_no LIKE 'V90%'" | Out-Null
  Sql "UPDATE sys_config SET cfg_value='0' WHERE cfg_key IN ('rule.skill.max_activity','rule.skill.max_total')" | Out-Null
}

function SetupTestData {
  CleanupTestData

  # 学生 V9001..V9007: 复用 2023001 的口令哈希(初始密码 123456)
  for ($i = 1; $i -le 7; $i++) {
    $id = 9100 + $i
    $no = 'V900' + $i
    Sql ("INSERT INTO student (id,stu_no,name,dept,pwd_hash,status,created_at) " +
      "SELECT $id,'$no','V4测试$i','V4班',pwd_hash,1,NOW() FROM student WHERE stu_no='2023001'") | Out-Null
  }

  Sql ("INSERT INTO activity (id,title,content,location,start_time,end_time,hours,capacity,category,publisher,status,created_at) VALUES " +
    "(9101,'V4-申诉用活动','申诉闭环用例','V4场地',NOW()+INTERVAL 5 DAY,NOW()+INTERVAL 5 DAY+INTERVAL 2 HOUR,3.0,10,'volunteer','测试',1,NOW())," +
    "(9102,'V4-批量签到活动','10 分钟内 5 人签到','V4场地',NOW()+INTERVAL 6 DAY,NOW()+INTERVAL 6 DAY+INTERVAL 2 HOUR,1.0,10,'sports','测试',1,NOW())," +
    "(9103,'V4-未签退活动','30 小时前签到未签退','V4场地',NOW()-INTERVAL 2 DAY,NOW()-INTERVAL 1 DAY,2.0,10,'thought','测试',1,NOW())," +
    "(9104,'V4-学时超限活动','认定学时大于活动学时','V4场地',NOW()+INTERVAL 7 DAY,NOW()+INTERVAL 7 DAY+INTERVAL 2 HOUR,4.0,10,'sports','测试',1,NOW())," +
    "(9105,'V4-规则裁剪活动','技能类单活动上限','V4场地',NOW()+INTERVAL 8 DAY,NOW()+INTERVAL 8 DAY+INTERVAL 2 HOUR,3.0,10,'skill','测试',1,NOW())") | Out-Null

  # 批量签到用例的时间必须落在同一个 10 分钟窗口内(服务端按 UNIX_TIMESTAMP/600 分桶)。
  # 原来用 NOW()-INTERVAL 1..5 MINUTE, 当运行时刻靠近 :00/:10/:20... 边界时会被切成两桶,
  # 只剩 4 条命中, 用例随机失败。这里统一对齐到当前窗口起点再 +1..+5 分钟, 保证同桶。
  $burstBase = "DATE_ADD(FROM_UNIXTIME(FLOOR(UNIX_TIMESTAMP(NOW())/600)*600),INTERVAL "
  Sql ("INSERT INTO signup (id,client_id,activity_id,stu_no,name,status,category,checkin,checked_at,signout_at,hours,created_at,audited_at) VALUES " +
    "(9101,'v4-appeal',9101,'V9001','V4测试1',1,'volunteer',0,NULL,NULL,3.0,NOW()-INTERVAL 1 DAY,NOW()-INTERVAL 1 DAY)," +
    "(9102,'v4-burst-1',9102,'V9002','V4测试2',1,'sports',1," + $burstBase + "1 MINUTE),NULL,1.0,NOW()-INTERVAL 1 DAY,NOW()-INTERVAL 1 DAY)," +
    "(9103,'v4-burst-2',9102,'V9003','V4测试3',1,'sports',1," + $burstBase + "2 MINUTE),NULL,1.0,NOW()-INTERVAL 1 DAY,NOW()-INTERVAL 1 DAY)," +
    "(9104,'v4-burst-3',9102,'V9004','V4测试4',1,'sports',1," + $burstBase + "3 MINUTE),NULL,1.0,NOW()-INTERVAL 1 DAY,NOW()-INTERVAL 1 DAY)," +
    "(9105,'v4-burst-4',9102,'V9005','V4测试5',1,'sports',1," + $burstBase + "4 MINUTE),NULL,1.0,NOW()-INTERVAL 1 DAY,NOW()-INTERVAL 1 DAY)," +
    "(9106,'v4-burst-5',9102,'V9006','V4测试6',1,'sports',1," + $burstBase + "5 MINUTE),NULL,1.0,NOW()-INTERVAL 1 DAY,NOW()-INTERVAL 1 DAY)," +
    "(9107,'v4-notout',9103,'V9007','V4测试7',1,'thought',1,NOW()-INTERVAL 30 HOUR,NULL,2.0,NOW()-INTERVAL 2 DAY,NOW()-INTERVAL 2 DAY)," +
    "(9108,'v4-exceed',9104,'V9001','V4测试1',1,'sports',0,NULL,NULL,5.0,NOW()-INTERVAL 1 DAY,NOW()-INTERVAL 1 DAY)," +
    "(9109,'v4-rule',9105,'V9002','V4测试2',0,'skill',0,NULL,NULL,0.0,NOW()-INTERVAL 1 HOUR,NULL)") | Out-Null

  Sql ("INSERT INTO hours_total (stu_no,name,total_hours,sign_count) VALUES " +
    "('V9001','V4测试1',8.0,2),('V9002','V4测试2',1.0,1),('V9003','V4测试3',1.0,1)," +
    "('V9004','V4测试4',1.0,1),('V9005','V4测试5',1.0,1),('V9006','V4测试6',1.0,1),('V9007','V4测试7',2.0,1)") | Out-Null

  # taken 对账由服务启动负责; 这里手工补齐, 避免"测试期 taken 漂移"干扰断言
  Sql "UPDATE activity a SET taken=(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2) WHERE a.id BETWEEN 9100 AND 9199" | Out-Null
}

Write-Host '== v4.0 验收 =='
$admin = ''
$stu1 = ''
try {
  SetupTestData
  Write-Host '---- 1. 登录与权限矩阵 ----'
  $admin = Login 'admin' 'admin' 'admin123'
  $stu1 = Login 'student' 'V9001' '123456'
  Check '管理员登录' ($admin -ne '')
  Check '测试学生 V9001 登录' ($stu1 -ne '')
  $r = Api 'POST' '/api/appeal/add' @{ signup_id = 9101; reason = '测试管理员不能发起申诉' } $admin
  Check '管理员不能发起申诉(403)' ([int]$r.code -eq 403)
  $r = Api 'POST' '/api/appeal/audit' @{ appeal_id = 1; action = 'pass' } $stu1
  Check '学生不能处理申诉(403)' ([int]$r.code -eq 403)
  $r = Api 'GET' '/api/report/anomaly' $null $stu1
  Check '学生不能查看异常(403)' ([int]$r.code -eq 403)
  $r = Api 'POST' '/api/config/set' @{ rules = @{ skill = @{ max_activity = 1 } } } $stu1
  Check '学生不能改规则(403)' ([int]$r.code -eq 403)

  Write-Host '---- 2. 学时申诉闭环 ----'
  $r = Api 'POST' '/api/appeal/add' @{ signup_id = 9102; reason = '这不是我的报名记录' } $stu1
  Check '不能申诉他人报名(403)' ([int]$r.code -eq 403)
  $r = Api 'POST' '/api/appeal/add' @{ signup_id = 9101; reason = '短' } $stu1
  Check '理由过短被拒(400)' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/appeal/add' @{ signup_id = 9101; reason = '签到场次被少算, 申请按 2 小时折算' } $stu1
  Check '本人已通过报名可发起申诉' ([int]$r.code -eq 0) ([string]$r.msg)
  $apId = 0
  if ([int]$r.code -eq 0) { $apId = [int]$r.data.id }
  $r = Api 'POST' '/api/appeal/add' @{ signup_id = 9101; reason = '重复提交同一条申诉' } $stu1
  Check '同一报名重复申诉被拒(409)' ([int]$r.code -eq 409) ([string]$r.msg)

  $lst = Api 'GET' '/api/appeal/list?status=0&page=1&size=50' $null $admin
  Check '管理员待处理列表含该申诉' ([int]$lst.code -eq 0 -and @($lst.data.list | Where-Object { [int]$_.id -eq $apId }).Count -eq 1)

  $r = Api 'POST' '/api/appeal/audit' @{ appeal_id = $apId; action = 'pass'; reply = '核对签到记录后调整'; hours = 2.0 } $admin
  Check '管理员通过并调整到 2.0 学时' ([int]$r.code -eq 0 -and [Math]::Abs([double]$r.data.hours_after - 2.0) -lt 0.001) ([string]$r.msg)
  Check '报名明细学时已更新为 2.0' ([Math]::Abs((Num "SELECT hours FROM signup WHERE id=9101") - 2.0) -lt 0.001)
  Check '学时汇总按明细重算为 7.0' ([Math]::Abs((Num "SELECT total_hours FROM hours_total WHERE stu_no='V9001'") - 7.0) -lt 0.001)
  $r = Api 'POST' '/api/appeal/audit' @{ appeal_id = $apId; action = 'reject'; reply = '重复处理' } $admin
  Check '重复处理同一申诉被拒(409)' ([int]$r.code -eq 409) ([string]$r.msg)

  $r = Api 'POST' '/api/appeal/add' @{ signup_id = 9108; reason = '这条学时比活动还高, 申请核对' } $stu1
  $ap2 = 0
  if ([int]$r.code -eq 0) { $ap2 = [int]$r.data.id }
  Check '第二条申诉可提交' ([int]$r.code -eq 0)
  $r = Api 'POST' '/api/appeal/audit' @{ appeal_id = $ap2; action = 'reject'; reply = '' } $admin
  Check '驳回未填理由被拒(400)' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/appeal/audit' @{ appeal_id = $ap2; action = 'reject'; reply = '学时由活动学时上限决定' } $admin
  Check '驳回申诉成功' ([int]$r.code -eq 0)
  Check '驳回不改认定学时' ([Math]::Abs((Num "SELECT hours FROM signup WHERE id=9108") - 5.0) -lt 0.001)
  Check '驳回记录保留原因' ((Scalar "SELECT reply FROM appeal WHERE id=$ap2").IndexOf('上限') -ge 0)

  Write-Host '---- 3. 七大类规则读写 ----'
  $c = Api 'GET' '/api/config/get' $null $admin
  Check '配置下发结构化 rules' ([int]$c.code -eq 0 -and $null -ne $c.data.rules)
  $cats = @($c.data.rules.PSObject.Properties.Name)
  Check 'rules 覆盖七大类' ($cats.Count -eq 7)
  $r = Api 'POST' '/api/config/set' @{ rules = @{ bogus = @{ max_total = 1 } } } $admin
  Check '未知类别被拒(400)' ([int]$r.code -eq 400) ([string]$r.msg)
  $r = Api 'POST' '/api/config/set' @{ rules = @{ skill = @{ max_activity = -1 } } } $admin
  Check '负数规则被拒(400)' ([int]$r.code -eq 400)
  $r = Api 'POST' '/api/config/set' @{ rules = @{ skill = @{ max_activity = 1.5; max_total = 0 } } } $admin
  Check '设置 skill 单活动上限 1.5' ([int]$r.code -eq 0)
  $c = Api 'GET' '/api/config/get' $null $admin
  Check '读取到 1.5' ([Math]::Abs([double]$c.data.rules.skill.max_activity - 1.5) -lt 0.001)

  $r = Api 'POST' '/api/signup/audit' @{ signup_id = 9109; action = 'pass'; remark = '规则裁剪用例' } $admin
  Check '审核按上限裁剪到 1.5' ([int]$r.code -eq 0 -and [Math]::Abs([double]$r.data.hours - 1.5) -lt 0.001 -and [bool]$r.data.hours_capped) ([string]$r.msg)
  $r = Api 'POST' '/api/config/set' @{ rules = @{ skill = @{ max_activity = 0; max_total = 0 } } } $admin
  Check '规则复位 0' ([int]$r.code -eq 0)

  Write-Host '---- 4. 签到异常检测 ----'
  $a = Api 'GET' '/api/report/anomaly' $null $admin
  Check '异常接口可读' ([int]$a.code -eq 0)
  $burst = @($a.data.burst | Where-Object { [int]$_.activity_id -eq 9102 })
  Check '批量签到命中(9102)' ($burst.Count -ge 1)
  if ($burst.Count -ge 1) { Check '批量签到人数 >= 5' ([int]$burst[0].count -ge 5) ('count=' + $burst[0].count) }
  $no = @($a.data.not_signed_out | Where-Object { [int]$_.signup_id -eq 9107 })
  Check '长期未签退命中(9107)' ($no.Count -ge 1)
  $ex = @($a.data.hours_exceed | Where-Object { [int]$_.signup_id -eq 9108 })
  Check '学时超限命中(9108)' ($ex.Count -ge 1)

  Check '学时汇总仍与明细一致' ((Num "SELECT COUNT(*) FROM hours_total ht WHERE ABS(ht.total_hours-(SELECT COALESCE(SUM(s.hours),0) FROM signup s WHERE s.stu_no=ht.stu_no AND s.status=1))>0.001") -eq 0)
  Check 'taken 仍与真实报名数一致' ((Num "SELECT COUNT(*) FROM activity a WHERE a.id BETWEEN 9100 AND 9199 AND a.taken<>(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2)") -eq 0)
}
finally {
  Write-Host '---- 5. 清理与基线复核 ----'
  CleanupTestData
  Check '测试学生已清理' ((Num "SELECT COUNT(*) FROM student WHERE stu_no LIKE 'V90%'") -eq 0)
  Check '测试活动已清理' ((Num "SELECT COUNT(*) FROM activity WHERE id BETWEEN 9100 AND 9199") -eq 0)
  Check '测试申诉已清理' ((Num "SELECT COUNT(*) FROM appeal WHERE stu_no LIKE 'V90%'") -eq 0)
  Check '基线活动 = 8' ((Num "SELECT COUNT(*) FROM activity") -eq 8)
  Check '基线报名 = 19' ((Num "SELECT COUNT(*) FROM signup") -eq 19)
  Check '基线学时 = 20.5' ([Math]::Abs((Num "SELECT COALESCE(SUM(total_hours),0) FROM hours_total") - 20.5) -lt 0.001)
  Check 'taken 与真实报名数一致' ((Num "SELECT COUNT(*) FROM activity a WHERE a.taken<>(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2)") -eq 0)
  Check '申诉表已清空' ((Num "SELECT COUNT(*) FROM appeal") -eq 0)
  Check 'skill 规则复位 0' ((Num "SELECT cfg_value FROM sys_config WHERE cfg_key='rule.skill.max_activity'") -eq 0)
  $h = Api 'GET' '/api/health'
  # v5.0 起版本号前移到 5.0; 本脚本是 v4 能力回归, 只要求"版本 >= 4.0"这层语义仍成立
  $ver = [double]([string]$h.data.version)
  Check 'health version >= 4.0' ($ver -ge 4.0) ([string]$h.data.version)
}

Write-Host ''
Write-Host ("结果: " + $script:pass + " 通过, " + $script:fail + " 失败")
if ($script:fail -gt 0) { exit 1 }
exit 0

