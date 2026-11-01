#Requires -Version 5.1
<#
.SYNOPSIS
  Scrape course data from tsinghua.app (courseX) for a given semester.

.DESCRIPTION
  Phase 1: enumerate course IDs via the site's search endpoint (?s=...&q=...)
           using letters, digits and common Chinese characters until the
           site's stated course count is reached.
  Phase 2: fetch every course detail page, parse fields, append to JSONL
           (resumable: already-fetched IDs are skipped on re-run).
  Phase 3: export courses.csv (one row per course) and schedule.csv
           (one row per course x time slot) with UTF-8 BOM.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scrape.ps1
#>
[CmdletBinding()]
param(
  [string]$Semester = '2026-2027-1',          # search param value
  [string]$SemesterLabel = '2026-2027 学年秋季学期',
  [int]$ExpectedCount = 0,                     # 0 = auto-detect from site
  [int]$Throttle = 8,                          # concurrent detail fetches
  [string]$OutDir = (Join-Path $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }) 'data')
)

$ErrorActionPreference = 'Stop'
$BaseUrl = 'https://tsinghua.app'
$Headers = @{ 'User-Agent' = 'courseX-personal-archiver/1.0 (student course lookup)' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$IdsFile   = Join-Path $OutDir "ids_$Semester.txt"
$JsonlFile = Join-Path $OutDir "courses_$Semester.jsonl"
$WarnFile  = Join-Path $OutDir "warnings_$Semester.log"

function Invoke-Get {
  param([string]$Url, [int]$Retries = 4)
  for ($i = 1; $i -le $Retries; $i++) {
    try {
      return Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers $Headers -TimeoutSec 60
    } catch {
      if ($i -eq $Retries) { throw }
      Start-Sleep -Milliseconds (500 * $i)
    }
  }
}

# ---------------- Phase 1: enumerate course IDs ----------------
function Get-CourseIds {
  $idSet = [System.Collections.Generic.HashSet[string]]::new()
  if ($script:Target -le 0) {
    try {
      $probe = Invoke-Get -Url "$BaseUrl/courses?s=$Semester&q=$([uri]::EscapeDataString('a'))"
      $text = ($probe.Content -replace '<!-- -->', '') -replace '<[^>]+>', ' '
      $m = [regex]::Match($text, '课程\s*(\d+)\s*门')
      if ($m.Success) { $script:Target = [int]$m.Groups[1].Value; Write-Host "[enum] site reports $($script:Target) courses" }
    } catch { Write-Warning "[enum] target detection failed: $($_.Exception.Message)" }
  }
  if (Test-Path $IdsFile) {
    Get-Content $IdsFile | Where-Object { $_ -match '\S' } | ForEach-Object { [void]$idSet.Add($_.Trim()) }
    Write-Host "[enum] loaded $($idSet.Count) ids from cache $IdsFile"
    if ($script:Target -gt 0 -and $idSet.Count -ge $script:Target) { return $idSet }
  }

  # query list: a-z, 0-9, then common Chinese chars (course names + surnames)
  $cn = '学论理工程计术础文验济法史析统育语化物生医经管政心社艺数电机能环建水航软网智信控光微热力' +
        '量原分子基因植动地海天气遥测绘图馆博硕本科实习训练设制造运输通汽车船飞火箭卫星导弹雷达' +
        '声呐纤半超高低温压强弱直交混合静平衡稳定波振场流粒辐射散折反透镜薄膜晶非金陶瓷玻璃塑料' +
        '橡胶维涂腐蚀焊接铸锻切削磨钻铣钳装配调试修养检安全质量标准规范序算言据库操作系编译件人' +
        '器深度神络像处音识别自然大云区块链联虚拟实现增移互嵌入式单片可逻阵模路号态线磁兼容拖' +
        '动仪表传感执行床性精快成打印激束等离爆炸钎容锅炉轮燃内蒸涡喷活塞轴缩泵阀换冷调暖给排' +
        '污垃圾焚烧发配用继保绝缘过防接缆架空变站开关断互避池阳风核质潮汐氢储节减碳绿色循环持' +
        '续展态境护治影响评价监划伦教筑观与会治史哲学设计建筑景观规划马克思义克思主义想德修养' +
        '王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董潘袁蔡蒋余于杜' +
        '叶程魏苏吕丁任卢姚沈钟姜崔谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎' +
        '贺顾毛郝龚邵万钱严覃武戴莫孔向汤体育音乐美术舞蹈戏剧影视书法绘画雕塑摄影心理教育' +
        '语言文学历史哲学宗教社会学政治经济法律管理新闻传播图书情报档案数学物理化学生物地理地质' +
        '天文气象海洋环境生态能源材料机械电气电子信息通信计算机软件网络自动化土木水利建筑交通' +
        '航空航天兵器核科学农业林业畜牧兽医水产食品轻工纺织矿业冶金石油天然气煤炭电力电子通信'
  $queries = @()
  $queries += [char[]]'abcdefghijklmnopqrstuvwxyz' | ForEach-Object { [string]$_ }
  $queries += [char[]]'0123456789' | ForEach-Object { [string]$_ }
  $seen = @{}
  foreach ($ch in [char[]]$cn) { $s = [string]$ch; if (-not $seen.ContainsKey($s)) { $seen[$s] = $true; $queries += $s } }

  $targetReached = $false
  foreach ($q in $queries) {
    $url = "$BaseUrl/courses?s=$Semester&q=$([uri]::EscapeDataString($q))"
    try {
      $r = Invoke-Get -Url $url
    } catch {
      Write-Warning "[enum] query '$q' failed: $($_.Exception.Message)"
      continue
    }
    if ($script:Target -le 0) {
      $text = ($r.Content -replace '<!-- -->', '') -replace '<[^>]+>', ' '
      $m = [regex]::Match($text, '课程\s*(\d+)\s*门')
      if ($m.Success) { $script:Target = [int]$m.Groups[1].Value; Write-Host "[enum] site reports $($script:Target) courses" }
    }
    $before = $idSet.Count
    foreach ($m in [regex]::Matches($r.Content, "/courses/($Semester\d+)")) { [void]$idSet.Add($m.Groups[1].Value) }
    $added = $idSet.Count - $before
    Write-Host ("[enum] q='{0}' +{1} (total {2}/{3})" -f $q, $added, $idSet.Count, $(if ($script:Target) { $script:Target } else { '?' }))
    if ($script:Target -gt 0 -and $idSet.Count -ge $script:Target) { $targetReached = $true; break }
    Start-Sleep -Milliseconds 200
  }
  $idSet | Sort-Object | Set-Content -Path $IdsFile -Encoding UTF8
  if (-not $targetReached -and $script:Target -gt 0) {
    Write-Warning "[enum] only found $($idSet.Count)/$($script:Target) ids; coverage incomplete"
  }
  return $idSet
}

# ---------------- Phase 2: fetch + parse details ----------------
$FetchAndParse = {
  param($Id, $BaseUrl, $Headers, $SemesterLabel)
  $url = "$BaseUrl/courses/$Id"
  $html = $null
  for ($i = 1; $i -le 4; $i++) {
    try { $html = (Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $Headers -TimeoutSec 60).Content; break }
    catch { if ($i -eq 4) { return [pscustomobject]@{ id = $Id; error = $_.Exception.Message } }; Start-Sleep -Milliseconds (500 * $i) }
  }
  $clean = $html -replace '<!-- -->', ''
  $mi = $clean.IndexOf('<main'); $mj = $clean.IndexOf('</main>')
  if ($mi -lt 0 -or $mj -lt 0) { return [pscustomobject]@{ id = $Id; error = 'no <main>' } }
  $main = $clean.Substring($mi, $mj - $mi)
  $tags = [regex]::Matches($main, '<(p|h1|h2|li)[^>]*>(.*?)</\1>', 'Singleline')
  $sem = ''; $num = ''; $cn = ''; $en = ''; $teachers = @(); $slots = @()
  $pCount = 0; $seenH1 = $false
  foreach ($t in $tags) {
    $tag = $t.Groups[1].Value; $val = [System.Net.WebUtility]::HtmlDecode(($t.Groups[2].Value -replace '<[^>]+>', '')).Trim()
    if ($tag -eq 'p') {
      if (-not $seenH1) { $pCount++; if ($pCount -eq 1) { $sem = $val } elseif ($pCount -eq 2) { $num = $val } }
      elseif (-not $en) { $en = $val }
    } elseif ($tag -eq 'h1') { $cn = $val; $seenH1 = $true }
    elseif ($tag -eq 'h2') { if ($val) { $teachers += $val } }
    elseif ($tag -eq 'li') { if ($val) { $slots += $val } }
  }
  $parsed = @()
  foreach ($s in $slots) {
    $m = [regex]::Match($s, '^(星期[一二三四五六日])\s*第\s*([\d\-]+)\s*节\s*(\([^)]*\))?\s*(.*)$')
    if ($m.Success) {
      $parsed += [pscustomobject]@{ raw = $s; weekday = $m.Groups[1].Value; period = $m.Groups[2].Value; weeks = $m.Groups[3].Value; location = $m.Groups[4].Value.Trim() }
    } else {
      $parsed += [pscustomobject]@{ raw = $s; weekday = ''; period = ''; weeks = ''; location = '' }
    }
  }
  [pscustomobject]@{
    id = $Id; semester = $sem; course_number = $num; name_cn = $cn; name_en = $en
    teachers = ($teachers -join '、'); slots = $parsed; url = $url; error = $null
  }
}

function Fetch-Details {
  param([string[]]$Ids)
  $done = [System.Collections.Generic.HashSet[string]]::new()
  if (Test-Path $JsonlFile) {
    Get-Content $JsonlFile | ForEach-Object {
      if ($_ -match '"id"\s*:\s*"([^"]+)"') { [void]$done.Add($Matches[1]) }
    }
  }
  $todo = $Ids | Where-Object { -not $done.Contains($_) }
  Write-Host "[fetch] total=$($Ids.Count) done=$($done.Count) todo=$($todo.Count)"
  if ($todo.Count -eq 0) { return }

  $pool = [runspacefactory]::CreateRunspacePool(1, $Throttle)
  $pool.Open()
  $writer = [System.IO.StreamWriter]::new($JsonlFile, $true, [System.Text.Encoding]::UTF8)
  $warn = [System.IO.StreamWriter]::new($WarnFile, $true, [System.Text.Encoding]::UTF8)
  $batchSize = $Throttle * 4
  $fetched = 0
  try {
    for ($b = 0; $b -lt $todo.Count; $b += $batchSize) {
      $batch = $todo[$b..([Math]::Min($b + $batchSize - 1, $todo.Count - 1))]
      $jobs = @()
      foreach ($id in $batch) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($FetchAndParse).AddArgument($id).AddArgument($BaseUrl).AddArgument($Headers).AddArgument($SemesterLabel)
        $jobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Id = $id }
      }
      foreach ($j in $jobs) {
        $res = $j.PS.EndInvoke($j.Handle)
        $j.PS.Dispose()
        if ($res -and $res.Count -gt 0) {
          $obj = $res[0]
          if ($obj.error) { $warn.WriteLine("$($obj.id)`t$($obj.error)"); $warn.Flush() }
          else { $writer.WriteLine(($obj | ConvertTo-Json -Compress -Depth 5)); $writer.Flush(); $fetched++ }
        }
      }
      Write-Host ("[fetch] progress {0}/{1}" -f [Math]::Min($b + $batchSize, $todo.Count), $todo.Count)
      Start-Sleep -Milliseconds 300
    }
  } finally {
    $writer.Close(); $warn.Close(); $pool.Close(); $pool.Dispose()
  }
  Write-Host "[fetch] newly fetched: $fetched"
}

# ---------------- Phase 3: export CSV ----------------
function ConvertFrom-SlotRaw {
  param([string]$s)
  # standard: 星期二第6节(全周)大礼堂 / 星期第0节(全周)北大三教505 (weekday TBD)
  $m = [regex]::Match($s, '^星期([一二三四五六日]?)\s*第\s*([\d\-]+)\s*节\s*(\([^)]*\))?\s*(.*)$')
  if ($m.Success) {
    $wd = ''; if ($m.Groups[1].Value) { $wd = '星期' + $m.Groups[1].Value }
    return [pscustomobject]@{ raw = $s; weekday = $wd; period = $m.Groups[2].Value; weeks = $m.Groups[3].Value; location = $m.Groups[4].Value.Trim() }
  }
  # English (PKU cross-listed): Section 6 of Thur (Week 7), 六教6C300 / Section 0  (Week all ), 北大二教107
  $m2 = [regex]::Match($s, '^Section\s+([\d\-]+)\s*(?:of\s+([A-Za-z]+))?\s*\(([^)]*)\)\s*,?\s*(.*)$')
  if ($m2.Success) {
    $dayMap = @{ Mon = '星期一'; Tue = '星期二'; Tues = '星期二'; Wed = '星期三'; Thur = '星期四'; Thu = '星期四'; Fri = '星期五'; Sat = '星期六'; Sun = '星期日' }
    $wd = ''; $d = $m2.Groups[2].Value; if ($d -and $dayMap.ContainsKey($d)) { $wd = $dayMap[$d] }
    $wk = $m2.Groups[3].Value.Trim() -replace 'Week\s*all', '全周' -replace 'Week\s*([\d\-,]+)', '$1周'
    return [pscustomobject]@{ raw = $s; weekday = $wd; period = $m2.Groups[1].Value; weeks = "($wk)"; location = $m2.Groups[4].Value.Trim() }
  }
  return [pscustomobject]@{ raw = $s; weekday = ''; period = ''; weeks = ''; location = '' }
}

function Export-CourseCsv {
  $courses = Get-Content $JsonlFile | ForEach-Object { $_ | ConvertFrom-Json }
  Write-Host "[export] loaded $($courses.Count) courses from JSONL"

  $courseRows = foreach ($c in $courses) {
    [pscustomobject]@{
      semester      = $c.semester
      course_id     = $c.id
      course_number = $c.course_number
      name_cn       = $c.name_cn
      name_en       = $c.name_en
      teachers      = $c.teachers
      slot_count    = @($c.slots).Count
      slots_raw     = (@($c.slots) | ForEach-Object { $_.raw }) -join ' | '
      url           = $c.url
    }
  }
  $schedRows = foreach ($c in $courses) {
    foreach ($s in @($c.slots)) {
      $p = ConvertFrom-SlotRaw $s.raw
      [pscustomobject]@{
        semester      = $c.semester
        course_id     = $c.id
        course_number = $c.course_number
        name_cn       = $c.name_cn
        name_en       = $c.name_en
        teachers      = $c.teachers
        weekday       = $p.weekday
        period        = $p.period
        weeks         = $p.weeks
        location      = $p.location
        slot_raw      = $p.raw
        url           = $c.url
      }
    }
  }
  $courseRows | Export-Csv -Path (Join-Path $OutDir "courses_$Semester.csv") -NoTypeInformation -Encoding UTF8
  $schedRows  | Export-Csv -Path (Join-Path $OutDir "schedule_$Semester.csv") -NoTypeInformation -Encoding UTF8
  Write-Host "[export] wrote courses_$Semester.csv ($($courseRows.Count) rows), schedule_$Semester.csv ($($schedRows.Count) rows)"
}

# ---------------- main ----------------
$script:Target = $ExpectedCount
$ids = Get-CourseIds
Write-Host "[main] enumerated $($ids.Count) course ids"
Fetch-Details -Ids ($ids | Sort-Object)
Export-CourseCsv
Write-Host "[main] done. Data in $OutDir"
