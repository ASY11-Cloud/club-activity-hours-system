# =====================================================================
# Markdown -> Word（使用说明文档.docx）生成器（纯 OOXML，不依赖 Word）
#
# 用法：powershell -ExecutionPolicy Bypass -File tools/md2docx.ps1 `
#          -Md docs/使用说明.md -Docx 使用说明文档.docx
#
# 为什么不用 Word COM：本机 Word 在非交互会话里会卡在隐藏对话框，
# 生成过程不可观测。这里直接按 OOXML 拼包（ZipArchive），秒级完成、可重复。
#
# 支持：#/##/### 标题、表格、代码块、引用、有序/无序列表、加粗、行内代码、链接、分隔线；
#       A4 页面、页脚居中页码、表头深蓝底白字、隔行浅底、代码块灰底。
# 注意：本文件必须保存为 UTF-8 with BOM（PowerShell 5.1 否则按 ANSI 解析）。
# =====================================================================
param(
  [Parameter(Mandatory = $true)][string]$Md,
  [Parameter(Mandatory = $true)][string]$Docx
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$mdPath = (Resolve-Path $Md).Path
$root = Split-Path -Parent (Split-Path -Parent $mdPath)
if (-not (Test-Path (Join-Path $root 'README.md'))) { $root = (Get-Location).Path }
$docxPath = Join-Path $root $Docx

function Esc([string]$s) {
  return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Runs([string]$text) {
  $sb = New-Object System.Text.StringBuilder
  $pattern = '(\*\*[^*]+\*\*|`[^`]+`)'
  $parts = [regex]::Split($text, $pattern)
  foreach ($p in $parts) {
    if ($p -eq '') { continue }
    if ($p -match '^\*\*([^*]+)\*\*$') {
      [void]$sb.Append('<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">' + (Esc $Matches[1]) + '</w:t></w:r>')
    } elseif ($p -match '^`([^`]+)`$') {
      [void]$sb.Append('<w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:shd w:val="clear" w:fill="F2F2F2"/></w:rPr><w:t xml:space="preserve">' + (Esc $Matches[1]) + '</w:t></w:r>')
    } else {
      # 统一带空 rPr，表头单元格才能通过字符串替换补上白色/加粗
      [void]$sb.Append('<w:r><w:rPr></w:rPr><w:t xml:space="preserve">' + (Esc $p) + '</w:t></w:r>')
    }
  }
  return $sb.ToString()
}

function Para([string]$style, [string]$runsXml, [string]$extraPr = '') {
  $pPr = '<w:pPr>'
  if ($style) { $pPr += '<w:pStyle w:val="' + $style + '"/>' }
  $pPr += $extraPr + '</w:pPr>'
  return '<w:p>' + $pPr + $runsXml + '</w:p>'
}

function Cell([string]$runsXml, [bool]$header) {
  $tcPr = '<w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="' + $(if ($header) { '1F3864' } else { 'FFFFFF' }) + '"/></w:tcPr>'
  if ($header) { $runsXml = $runsXml -replace '<w:rPr>', '<w:rPr><w:color w:val="FFFFFF"/><w:b/>' }
  return '<w:tc>' + $tcPr + (Para 'Normal' $runsXml '<w:spacing w:before="0" w:after="0"/>') + '</w:tc>'
}

$md = [IO.File]::ReadAllText($mdPath, [Text.Encoding]::UTF8)
$lines = $md -split "`r?`n"
$body = New-Object System.Text.StringBuilder
$inCode = $false
$i = 0

while ($i -lt $lines.Count) {
  $line = $lines[$i]
  $trim = $line.Trim()

  if ($trim -match '^```') {
    if ($inCode) { $inCode = $false; [void]$body.Append((Para 'Normal' '' '')) }
    else { $inCode = $true }
    $i++; continue
  }
  if ($inCode) {
    [void]$body.Append('<w:p><w:pPr><w:pStyle w:val="Code"/></w:pPr><w:r><w:t xml:space="preserve">' + (Esc $line) + '</w:t></w:r></w:p>')
    $i++; continue
  }

  if ($trim -eq '') { $i++; continue }

  # 表格
  if ($trim.StartsWith('|') -and ($i + 1) -lt $lines.Count -and $lines[$i + 1].Trim() -match '^\|[\s:\-\|]+\|$') {
    $headerCells = $trim.Trim('|') -split '(?<!\\)\|'
    [void]$body.Append('<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/><w:tblBorders>' +
      '<w:top w:val="single" w:sz="4" w:color="B4C6E7"/><w:left w:val="single" w:sz="4" w:color="B4C6E7"/>' +
      '<w:bottom w:val="single" w:sz="4" w:color="B4C6E7"/><w:right w:val="single" w:sz="4" w:color="B4C6E7"/>' +
      '<w:insideH w:val="single" w:sz="4" w:color="B4C6E7"/><w:insideV w:val="single" w:sz="4" w:color="B4C6E7"/>' +
      '</w:tblBorders><w:tblLayout w:type="autofit"/></w:tblPr><w:tblGrid>')
    $colW = [int](9000 / [Math]::Max(1, $headerCells.Count))
    foreach ($c in $headerCells) { [void]$body.Append('<w:gridCol w:w="' + $colW + '"/>') }
    [void]$body.Append('</w:tblGrid>')
    [void]$body.Append('<w:tr><w:trPr><w:tblHeader/></w:trPr>')
    foreach ($c in $headerCells) { [void]$body.Append((Cell (Runs $c.Trim().Replace('\|', '|')) $true)) }
    [void]$body.Append('</w:tr>')
    $i += 2
    $even = $false
    while ($i -lt $lines.Count -and $lines[$i].Trim().StartsWith('|')) {
      $cells = $lines[$i].Trim().Trim('|') -split '(?<!\\)\|'
      [void]$body.Append('<w:tr>')
      foreach ($c in $cells) {
        $runs = Runs $c.Trim().Replace('\|', '|')
        $fill = $(if ($even) { 'EDF2FA' } else { 'FFFFFF' })
        [void]$body.Append('<w:tc><w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="' + $fill + '"/></w:tcPr>' +
          (Para 'Normal' $runs '<w:spacing w:before="0" w:after="0"/>') + '</w:tc>')
      }
      [void]$body.Append('</w:tr>')
      $even = -not $even
      $i++
    }
    [void]$body.Append('</w:tbl>')
    [void]$body.Append((Para 'Normal' '' ''))
    continue
  }

  if ($trim -match '^(#{1,6})\s+(.*)$') {
    $level = [Math]::Min($Matches[1].Length, 3)
    [void]$body.Append((Para ('Heading' + $level) (Runs $Matches[2])))
    $i++; continue
  }

  if ($trim -match '^>\s?(.*)$') {
    [void]$body.Append((Para 'Quote' (Runs $Matches[1])))
    $i++; continue
  }

  if ($trim -match '^(-{3,}|\*{3,})$') {
    [void]$body.Append((Para 'Normal' '' '<w:pBdr><w:bottom w:val="single" w:sz="6" w:color="DDDDDD"/></w:pBdr>'))
    $i++; continue
  }

  if ($trim -match '^(?:[-*+])\s+(.*)$') {
    [void]$body.Append((Para 'Normal' (Runs ('• ' + $Matches[1])) '<w:ind w:left="420" w:hanging="210"/>'))
    $i++; continue
  }

  if ($trim -match '^(\d+)\.\s+(.*)$') {
    [void]$body.Append((Para 'Normal' (Runs ($Matches[1] + '. ' + $Matches[2])) '<w:ind w:left="420" w:hanging="210"/>'))
    $i++; continue
  }

  [void]$body.Append((Para 'Normal' (Runs $trim)))
  $i++
}

$sectPr = '<w:sectPr><w:footerReference w:type="default" r:id="rId1"/>' +
  '<w:pgSz w:w="11906" w:h="16838"/>' +
  '<w:pgMar w:top="1247" w:right="1134" w:bottom="1247" w:left="1134" w:header="851" w:footer="992" w:gutter="0"/>' +
  '</w:sectPr>'

$documentXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ' +
  'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
  '<w:body>' + $body.ToString() + $sectPr + '</w:body></w:document>'

$stylesXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
  '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Microsoft YaHei" w:eastAsia="Microsoft YaHei" w:hAnsi="Microsoft YaHei"/>' +
  '<w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr></w:rPrDefault>' +
  '<w:pPrDefault><w:pPr><w:spacing w:after="80" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>' +
  '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>' +
  '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>' +
  '<w:pPr><w:keepNext/><w:outlineLvl w:val="0"/><w:spacing w:before="360" w:after="200"/>' +
  '<w:pBdr><w:bottom w:val="single" w:sz="18" w:color="1F3864"/></w:pBdr></w:pPr>' +
  '<w:rPr><w:b/><w:color w:val="1F3864"/><w:sz w:val="40"/></w:rPr></w:style>' +
  '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>' +
  '<w:pPr><w:keepNext/><w:outlineLvl w:val="1"/><w:spacing w:before="300" w:after="160"/></w:pPr>' +
  '<w:rPr><w:b/><w:color w:val="1F3864"/><w:sz w:val="30"/></w:rPr></w:style>' +
  '<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/>' +
  '<w:pPr><w:keepNext/><w:outlineLvl w:val="2"/><w:spacing w:before="240" w:after="120"/></w:pPr>' +
  '<w:rPr><w:b/><w:color w:val="2F5597"/><w:sz w:val="25"/></w:rPr></w:style>' +
  '<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>' +
  '<w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F5F5F5"/><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>' +
  '<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:sz w:val="18"/></w:rPr></w:style>' +
  '<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/>' +
  '<w:pPr><w:ind w:left="240"/><w:pBdr><w:left w:val="single" w:sz="18" w:color="2F6BFF"/></w:pBdr></w:pPr>' +
  '<w:rPr><w:color w:val="444444"/></w:rPr></w:style>' +
  '</w:styles>'

$footerXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  '<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
  '<w:p><w:pPr><w:jc w:val="center"/><w:rPr><w:sz w:val="18"/></w:rPr></w:pPr>' +
  '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>' +
  '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>' +
  '</w:p></w:ftr>'

$contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
  '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
  '<Default Extension="xml" ContentType="application/xml"/>' +
  '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
  '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>' +
  '<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>' +
  '</Types>'

$rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
  '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
  '</Relationships>'

$docRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
  '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>' +
  '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
  '</Relationships>'

if (Test-Path $docxPath) { Remove-Item $docxPath -Force }
$fs = [IO.File]::Open($docxPath, [IO.FileMode]::CreateNew)
try {
  $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
  $enc = New-Object Text.UTF8Encoding($false)
  $items = [ordered]@{
    '[Content_Types].xml'         = $contentTypes
    '_rels/.rels'                 = $rels
    'word/document.xml'           = $documentXml
    'word/styles.xml'             = $stylesXml
    'word/footer1.xml'            = $footerXml
    'word/_rels/document.xml.rels' = $docRels
  }
  foreach ($k in $items.Keys) {
    $entry = $zip.CreateEntry($k, [IO.Compression.CompressionLevel]::Optimal)
    $st = $entry.Open()
    $bytes = $enc.GetBytes([string]$items[$k])
    $st.Write($bytes, 0, $bytes.Length)
    $st.Close()
  }
  $zip.Dispose()
} finally {
  $fs.Close()
}

$size = (Get-Item $docxPath).Length
Write-Output ("OK size=" + $size + " -> " + $docxPath)
