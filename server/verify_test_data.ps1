# =====================================================================
# v3.2 测试数据 / 数据一致性核验（PowerShell 版，本机无 Python 时使用）
#
# 分阶段执行（restart 必须在 seed 与 api 之间，用于验证启动对账）：
#   mysql ... < testdata_seed.sql
#   powershell -File verify_test_data.ps1 -Stage seed
#   stop_server.bat ; start server.exe
#   powershell -File verify_test_data.ps1 -Stage api
#   mysql ... < testdata_clean.sql
#   powershell -File verify_test_data.ps1 -Stage baseline
#
# 退出码 0 = 全绿，1 = 有失败项
# =====================================================================
param(
  [ValidateSet('schema', 'seed', 'api', 'baseline', 'all')]
  [string]$Stage = 'all'
)

$ErrorActionPreference = 'Stop'
$env:MYSQL_PWD = '123456'   # 避免命令行明文口令触发 mysql 警告（警告走 stderr 会被 Stop 当成错误）
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
  # 注意: Sql 只返回一行时 PowerShell 会把它当字符串(而不是 1 元素数组),
  # 直接 $rows[0] 取到的是首字符。必须先用 @() 包一层再转 [string]。
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
      $bytes = [Text.Encoding]::UTF8.GetBytes($json)
      return Invoke-RestMethod -Method $method -Uri $uri -Headers $headers -Body $bytes -TimeoutSec 10
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

function Has($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  return ($obj.PSObject.Properties.Name -contains $name)
}

function Login([string]$type, [string]$account, [string]$secret) {
  $r = Api 'POST' '/api/login' @{ type = $type; account = $account; secret = $secret }
  if ([int]$r.code -eq 0) { return [string]$r.data.token }
  return ''
}

# ---------------------------------------------------------------------
function StageSchema {
  Write-Host '---- 1. 结构核验（字段 / 类型 / 索引 / 字符集） ----'
  foreach ($c in @('category', 'taken')) {
    $n = Num ("SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='club_system' AND table_name='activity' AND column_name='" + $c + "'")
    Check ("activity." + $c + " 存在") ($n -eq 1)
  }
  foreach ($c in @('category', 'signout_at', 'checked_at')) {
    $n = Num ("SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='club_system' AND table_name='signup' AND column_name='" + $c + "'")
    Check ("signup." + $c + " 存在") ($n -eq 1)
  }
  Check 'activity.category 默认 sports' ((Scalar "SELECT COLUMN_DEFAULT FROM information_schema.columns WHERE table_schema='club_system' AND table_name='activity' AND column_name='category'") -eq 'sports')
  Check 'activity.taken 非空且默认 0' ((Scalar "SELECT CONCAT(IS_NULLABLE,'/',COLUMN_DEFAULT) FROM information_schema.columns WHERE table_schema='club_system' AND table_name='activity' AND column_name='taken'") -eq 'NO/0')
  Check 'signup.signout_at 可空' ((Scalar "SELECT IS_NULLABLE FROM information_schema.columns WHERE table_schema='club_system' AND table_name='signup' AND column_name='signout_at'") -eq 'YES')
  Check 'signup 唯一键 uk_act_stu 存在' ((Num "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='club_system' AND table_name='signup' AND index_name='uk_act_stu'") -gt 0)
  Check 'signup.client_id 唯一键 uk_client 存在' ((Num "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='club_system' AND table_name='signup' AND index_name='uk_client'") -gt 0)
  Check '库字符集 utf8mb4' ((Scalar "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='club_system'") -eq 'utf8mb4')
}

function StageSeed {
  Write-Host '---- 2. 测试数据落库（重启前） ----'
  Check '测试活动 10 个' ((Num "SELECT COUNT(*) FROM activity WHERE id BETWEEN 9000 AND 9999") -eq 10)
  Check '测试学生 8 个' ((Num "SELECT COUNT(*) FROM student WHERE stu_no LIKE 'T9%'") -eq 8)
  Check '测试报名 10 条' ((Num "SELECT COUNT(*) FROM signup WHERE client_id LIKE 'tdata-%'") -eq 10)
  Check '测试学时合计 13.0' ([Math]::Abs((Num "SELECT COALESCE(SUM(total_hours),0) FROM hours_total WHERE stu_no LIKE 'T9%'") - 13.0) -lt 0.001)
  Check '基线活动仍 8 个' ((Num "SELECT COUNT(*) FROM activity WHERE id < 9000") -eq 8)
  Check '基线报名仍 19 条' ((Num "SELECT COUNT(*) FROM signup WHERE id < 9000") -eq 19)
  Check '基线学时仍 20.5' ([Math]::Abs((Num "SELECT COALESCE(SUM(total_hours),0) FROM hours_total WHERE stu_no NOT LIKE 'T9%'") - 20.5) -lt 0.001)
  Check '老数据存在空类别快照（2 条）' ((Num "SELECT COUNT(*) FROM signup WHERE category=''") -eq 2)
  $drift = Num "SELECT COUNT(*) FROM activity a WHERE a.id BETWEEN 9000 AND 9999 AND a.taken<>(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2)"
  Check 'taken 人为漂移已入库（7 个活动）' ($drift -eq 7) ("drift=" + $drift)
  $hr = Num "SELECT COUNT(*) FROM hours_total ht WHERE ABS(ht.total_hours - (SELECT COALESCE(SUM(s.hours),0) FROM signup s WHERE s.stu_no=ht.stu_no AND s.status=1)) > 0.001"
  Check '学时汇总与明细一致（含测试数据）' ($hr -eq 0) ("mismatch=" + $hr)
}

function StageApi {
  Write-Host '---- 3. 重启后对账 + 接口业务核验 ----'
  $h = Api 'GET' '/api/health'
  Check '服务在线且 version=3.2' ([int]$h.code -eq 0 -and [string]$h.data.version -eq '3.2') ("ver=" + $h.data.version)

  $drift = Num "SELECT COUNT(*) FROM activity a WHERE a.taken<>(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2)"
  Check '启动对账后全库 taken 与真实报名数一致' ($drift -eq 0) ("drift=" + $drift)
  Check 'taken 无负数' ((Num "SELECT COUNT(*) FROM activity WHERE taken<0") -eq 0)
  Check '老数据类别快照已回填（0 条为空）' ((Num "SELECT COUNT(*) FROM signup WHERE category=''") -eq 0)
  Check '快照回填值 = 活动类别' ((Num "SELECT COUNT(*) FROM signup s JOIN activity a ON s.activity_id=a.id WHERE s.category<>a.category AND s.id BETWEEN 9000 AND 9999") -eq 0)

  $admin = Login 'admin' 'admin' 'admin123'
  Check '管理员登录' ($admin -ne '')

  # 活动列表字段映射
  $r = Api 'GET' '/api/activity/list?page=1&size=200&all=1' $null $admin
  Check '管理员活动列表可读' ([int]$r.code -eq 0)
  $acts = @($r.data.list)
  Check '列表包含 10 个测试活动' ((@($acts | Where-Object { [int]$_.id -ge 9000 }).Count) -eq 10)
  $a9007 = @($acts | Where-Object { [int]$_.id -eq 9007 })[0]
  Check '列表下发 category' ((Has $a9007 'category') -and ([string]$a9007.category -eq 'skill'))
  Check '列表下发 taken' ((Has $a9007 'taken') -and ([int]$a9007.taken -eq 1))
  Check '特殊字符标题未被转义破坏' ((Has $a9007 'title') -and ([string]$a9007.title).Contains('🚀'))
  $a9002 = @($acts | Where-Object { [int]$_.id -eq 9002 })[0]
  Check '满员活动 remaining=0' ([int]$a9002.remaining -eq 0)
  $a9001 = @($acts | Where-Object { [int]$_.id -eq 9001 })[0]
  Check '不限容量活动 remaining=-1' ([int]$a9001.remaining -eq -1)
  Check '已下线活动仍可被管理员看到' ((@($acts | Where-Object { [int]$_.id -eq 9005 }).Count) -eq 1)

  $rv = Api 'GET' '/api/activity/list?page=1&size=200&category=volunteer' $null $admin
  Check '按类别筛选 volunteer 命中 2 个' ([int]$rv.data.total -eq 2) ("total=" + $rv.data.total)

  # 报名列表字段
  $rs = Api 'GET' '/api/signup/list?page=1&size=50&activity_id=9003' $null $admin
  Check '按活动筛选报名返回 2 条' ([int]$rs.code -eq 0 -and @($rs.data.list).Count -eq 2)
  $row = @($rs.data.list)[0]
  Check '报名行含 category/checkin_at/signout_at' ((Has $row 'category') -and (Has $row 'checkin_at') -and (Has $row 'signout_at'))
  Check '回填后的类别与活动一致' ([string]$row.category -eq 'practice')

  # 报表
  $rr = Api 'GET' '/api/hours/report' $null $admin
  Check '报表分类汇总存在' ([int]$rr.code -eq 0 -and $null -ne $rr.data.by_category)
  $catSum = 0.0
  foreach ($c in @($rr.data.by_category)) { $catSum += [double]$c.hours }
  Check '分类汇总合计 = 33.5（20.5 基线 + 13 测试）' ([Math]::Abs($catSum - 33.5) -lt 0.05) ("sum=" + $catSum)
  Check '明细行含 category 字段' ((@($rr.data.detail).Count -gt 0) -and (Has @($rr.data.detail)[0] 'category'))

  # 预警
  $rw = Api 'GET' '/api/report/warning' $null $admin
  Check '预警接口可读' ([int]$rw.code -eq 0)
  $w = @($rw.data.list | Where-Object { [string]$_.stu_no -eq 'T9007' })
  Check '预警名单包含学时临界学生' ($w.Count -eq 1)
  if ($w.Count -eq 1) { Check '缺口学时 = 17.0' ([Math]::Abs([double]$w[0].gap - 17.0) -lt 0.001) ("gap=" + $w[0].gap) }

  # 学生侧业务
  $t1 = Login 'student' 'T9001' '123456'
  Check '测试学生 T9001 可登录（密码哈希复用有效）' ($t1 -ne '')
  $r = Api 'POST' '/api/signup/add' @{ client_id = 'tdata-api-conflict'; activity_id = 9010 } $t1
  Check '时间重叠报名被拒 409' ([int]$r.code -eq 409 -and ([string]$r.msg).Contains('冲突')) ([string]$r.msg)

  $t6 = Login 'student' 'T9006' '123456'
  Check '测试学生 T9006 可登录' ($t6 -ne '')
  $r = Api 'POST' '/api/signup/add' @{ client_id = 'tdata-api-full'; activity_id = 9002 } $t6
  Check '满员活动报名被拒 403' ([int]$r.code -eq 403) ([string]$r.msg)
  $r = Api 'POST' '/api/signup/add' @{ client_id = 'tdata-api-offline'; activity_id = 9005 } $t6
  Check '已下线活动报名被拒 400' ([int]$r.code -eq 400 -and ([string]$r.msg).Contains('未开放')) ([string]$r.msg)
  $r = Api 'POST' '/api/signup/add' @{ client_id = 'tdata-api-ended'; activity_id = 9004 } $t6
  Check '已结束活动报名被拒 400' ([int]$r.code -eq 400 -and ([string]$r.msg).Contains('结束')) ([string]$r.msg)

  $before = Num "SELECT taken FROM activity WHERE id=9003"
  $r = Api 'POST' '/api/signup/add' @{ client_id = 'tdata-api-notime'; activity_id = 9003 } $t6
  Check '无时间窗活动可正常报名' ([int]$r.code -eq 0) ([string]$r.msg)
  $after = Num "SELECT taken FROM activity WHERE id=9003"
  Check '报名占位 taken+1' ($after -eq ($before + 1)) ("before=$before after=$after")
  $r2 = Api 'POST' '/api/signup/add' @{ client_id = 'tdata-api-notime'; activity_id = 9003 } $t6
  Check '重复报名幂等不重复占位' ([int]$r2.code -eq 0 -and (Num "SELECT taken FROM activity WHERE id=9003") -eq $after)

  # 签到码 / 签退
  $r = Api 'GET' '/api/activity/signin_code?activity_id=9001' $null $admin
  $code = ''
  if ([int]$r.code -eq 0) { $code = [string]$r.data.code }
  Check '管理员获取 6 位签到码' ([int]$r.code -eq 0 -and $code.Length -eq 6 -and $code -match '^\d{6}$')
  Check '签到码剩余秒数在 (0,60]' ([int]$r.code -eq 0 -and [int]$r.data.expire_in -gt 0 -and [int]$r.data.expire_in -le 60)
  $bad = '000000'
  if ($code -eq '000000') { $bad = '111111' }
  $r = Api 'POST' '/api/signin/code' @{ activity_id = 9001; code = $bad } $t6
  Check '错误签到码被拒 403' ([int]$r.code -eq 403) ([string]$r.msg)
  $r = Api 'POST' '/api/signin/code' @{ activity_id = 9001; code = $code } $t6
  Check '正确签到码签到成功' ([int]$r.code -eq 0 -and [int]$r.data.checkin -eq 1) ([string]$r.msg)
  Check '0 学时活动签到后学时仍为 0' ([Math]::Abs((Num "SELECT hours FROM signup WHERE activity_id=9001 AND stu_no='T9006'")) -lt 0.001)
  $r = Api 'POST' '/api/signin/out' @{ activity_id = 9001 } $t6
  Check '0 学时活动签退不凭空发 0.5 学时' ([int]$r.code -eq 0 -and [Math]::Abs([double]$r.data.hours) -lt 0.001) ("hours=" + $r.data.hours)
  $r = Api 'POST' '/api/signin/out' @{ activity_id = 9001 } $t6
  Check '重复签退被拒 409' ([int]$r.code -eq 409) ([string]$r.msg)
  $r = Api 'POST' '/api/signin/out' @{ activity_id = 9008 } $t6
  Check '未报名签退返回 404' ([int]$r.code -eq 404) ([string]$r.msg)

  # 0.5 学时步进: 9007 计划 2h/4.5 学时, 人为把签到时间前移 50 分钟 =>
  # raw = 4.5 * 50/120 = 1.875, 按 0.5 步进应为 2.0(若仍用 0.1 步进会是 1.9)
  Sql "UPDATE signup SET checked_at=NOW()-INTERVAL 50 MINUTE, signout_at=NULL WHERE activity_id=9007 AND stu_no='T9004'" | Out-Null
  $t4 = Login 'student' 'T9004' '123456'
  $r = Api 'POST' '/api/signin/out' @{ activity_id = 9007 } $t4
  Check '签退学时按 0.5 步进取整（1.875 -> 2.0）' ([int]$r.code -eq 0 -and [Math]::Abs([double]$r.data.hours - 2.0) -lt 0.001) ("hours=" + $r.data.hours + " minutes=" + $r.data.minutes)
  Check '签退写回 signout_at' ((Num "SELECT COUNT(*) FROM signup WHERE activity_id=9007 AND stu_no='T9004' AND signout_at IS NOT NULL") -eq 1)

  # 类别上限（真实链路：报名 -> 审核 -> 裁剪）
  Sql "UPDATE sys_config SET cfg_value='2' WHERE cfg_key='rule.skill.max_activity'" | Out-Null
  $r = Api 'POST' '/api/signup/add' @{ client_id = 'tdata-api-rule'; activity_id = 9007 } $t6
  Check '特殊字符活动报名成功' ([int]$r.code -eq 0) ([string]$r.msg)
  $sid = Num "SELECT id FROM signup WHERE activity_id=9007 AND stu_no='T9006'"
  $r = Api 'POST' '/api/signup/audit' @{ signup_id = [int]$sid; action = 'pass'; remark = '测试单活动上限' } $admin
  $hrs = 0.0; $capped = $false
  if ([int]$r.code -eq 0) { $hrs = [double]$r.data.hours; $capped = [bool]$r.data.hours_capped }
  Check '审核按单活动上限裁剪到 2.0' ([int]$r.code -eq 0 -and [Math]::Abs($hrs - 2.0) -lt 0.001 -and $capped) ("hours=$hrs capped=$capped")
  Sql "UPDATE sys_config SET cfg_value='0' WHERE cfg_key='rule.skill.max_activity'" | Out-Null
  Check '规则复位为 0' ((Num "SELECT cfg_value FROM sys_config WHERE cfg_key='rule.skill.max_activity'") -eq 0)

  # 汇总仍与明细一致（经过上面所有写操作）
  $hr = Num "SELECT COUNT(*) FROM hours_total ht WHERE ABS(ht.total_hours - (SELECT COALESCE(SUM(s.hours),0) FROM signup s WHERE s.stu_no=ht.stu_no AND s.status=1)) > 0.001"
  Check '写操作后学时汇总仍与明细一致' ($hr -eq 0) ("mismatch=" + $hr)
  $drift = Num "SELECT COUNT(*) FROM activity a WHERE a.taken<>(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2)"
  Check '写操作后 taken 仍与真实报名数一致' ($drift -eq 0) ("drift=" + $drift)
}

function StageBaseline {
  Write-Host '---- 4. 清理后基线复核 ----'
  Check '测试学生已清理' ((Num "SELECT COUNT(*) FROM student WHERE stu_no LIKE 'T9%'") -eq 0)
  Check '测试活动已清理' ((Num "SELECT COUNT(*) FROM activity WHERE id BETWEEN 9000 AND 9999") -eq 0)
  Check '测试报名已清理' ((Num "SELECT COUNT(*) FROM signup WHERE client_id LIKE 'tdata-%' OR id BETWEEN 9000 AND 9999") -eq 0)
  Check '测试学时已清理' ((Num "SELECT COUNT(*) FROM hours_total WHERE stu_no LIKE 'T9%'") -eq 0)
  Check '基线活动 = 8' ((Num "SELECT COUNT(*) FROM activity") -eq 8)
  Check '基线报名 = 19' ((Num "SELECT COUNT(*) FROM signup") -eq 19)
  Check '基线学生 = 10' ((Num "SELECT COUNT(*) FROM student") -eq 10)
  Check '基线学时合计 = 20.5' ([Math]::Abs((Num "SELECT COALESCE(SUM(total_hours),0) FROM hours_total") - 20.5) -lt 0.001)
  Check '待审注册 = 3' ((Num "SELECT COUNT(*) FROM student WHERE status=0") -eq 3)
  Check 'taken 与真实报名数一致' ((Num "SELECT COUNT(*) FROM activity a WHERE a.taken<>(SELECT COUNT(*) FROM signup s WHERE s.activity_id=a.id AND s.status<>2)") -eq 0)
  Check '报名类别快照无空值' ((Num "SELECT COUNT(*) FROM signup WHERE category=''") -eq 0)

  $admin = Login 'admin' 'admin' 'admin123'
  $r = Api 'GET' '/api/hours/report' $null $admin
  $top = @($r.data.report)[0]
  Check '报告榜首 = 李铭 5.5' ([string]$top.name -eq '李铭' -and [Math]::Abs([double]$top.total_hours - 5.5) -lt 0.001)
  Check '报告人数 = 5' (@($r.data.report).Count -eq 5)
  $s = 0.0
  foreach ($c in @($r.data.by_category)) { $s += [double]$c.hours }
  Check '分类汇总合计回到 20.5' ([Math]::Abs($s - 20.5) -lt 0.05) ("sum=" + $s)
}

Write-Host ("== verify_test_data stage=" + $Stage + " ==")
if ($Stage -eq 'schema' -or $Stage -eq 'all') { StageSchema }
if ($Stage -eq 'seed' -or $Stage -eq 'all') { StageSeed }
if ($Stage -eq 'api' -or $Stage -eq 'all') { StageApi }
if ($Stage -eq 'baseline' -or $Stage -eq 'all') { StageBaseline }

Write-Host ''
Write-Host ("结果: " + $script:pass + " 通过, " + $script:fail + " 失败")
if ($script:fail -gt 0) { exit 1 }
exit 0
