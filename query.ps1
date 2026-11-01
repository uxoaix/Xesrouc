#Requires -Version 5.1
<#
.SYNOPSIS
  Query scraped courseX data by semester + class time + location.

.DESCRIPTION
  Reads schedule_*.csv produced by scrape.ps1 (one row per course x time slot)
  and filters by any combination of: semester, weekday, period, weeks,
  location keyword, and course/teacher keyword.

.PARAMETER Semester
  Semester filter, matches the semester column or the file suffix.
  Examples: '2026-2027-1', '2026-2027', '秋季'. Default: all semesters.

.PARAMETER Weekday
  Day of week: 一 二 三 四 五 六 日 (with or without 星期). Example: -Weekday 二

.PARAMETER Period
  Period number or range. Matches slots whose period range overlaps.
  Examples: -Period 3  -Period 3-4  -Period '第3节'

.PARAMETER Weeks
  Week-pattern keyword, e.g. 全周 / 前八周 / 后八周.

.PARAMETER Location
  Location keyword (substring match), e.g. 六教 / 明理楼 / 深圳.

.PARAMETER Keyword
  Course name (CN/EN), course number, or teacher keyword.

.PARAMETER Export
  Optional path to export the matching rows as CSV (UTF-8 BOM).

.EXAMPLE
  .\query.ps1 -Semester 2026-2027-1 -Weekday 二 -Period 6 -Location 六教
  .\query.ps1 -Weekday 五 -Period 3-4 -Keyword 数学
#>
[CmdletBinding()]
param(
  [string]$Semester = '',
  [string]$Weekday = '',
  [string]$Period = '',
  [string]$Weeks = '',
  [string]$Location = '',
  [string]$Keyword = '',
  [string]$Export = '',
  [string]$DataDir = (Join-Path $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }) 'data')
)

$ErrorActionPreference = 'Stop'

# ---- load schedule files ----
$files = Get-ChildItem -Path $DataDir -Filter 'schedule_*.csv'
if ($Semester) {
  $semFiles = $files | Where-Object { $_.BaseName -like "*$Semester*" }
  if ($semFiles) { $files = $semFiles }
}
if (-not $files) { Write-Error "No schedule_*.csv found in $DataDir. Run scrape.ps1 first."; exit 1 }

$rows = foreach ($f in $files) { Import-Csv -Path $f.FullName -Encoding UTF8 }
Write-Host ("[query] loaded {0} slot rows from {1} file(s)" -f $rows.Count, $files.Count)

# ---- normalize filters ----
function ConvertTo-PeriodRange {
  param([string]$s)
  $s = $s -replace '[第节课\s]', ''
  if ($s -match '^(\d+)\s*-\s*(\d+)$') { return @([int]$Matches[1], [int]$Matches[2]) }
  if ($s -match '^(\d+)$') { return @([int]$Matches[1], [int]$Matches[1]) }
  return $null
}

$wd = $Weekday -replace '星期', ''
$filterRange = $null
if ($Period) {
  $filterRange = ConvertTo-PeriodRange $Period
  if (-not $filterRange) { Write-Error "Unrecognized -Period '$Period'"; exit 1 }
}

# ---- filter ----
$matched = $rows | Where-Object {
  $ok = $true
  if ($Semester -and $_.semester -notlike "*$Semester*" -and $_.course_id -notlike "*$Semester*") { $ok = $false }
  if ($ok -and $wd -and $_.weekday -notlike "*$wd*") { $ok = $false }
  if ($ok -and $filterRange) {
    $slotRange = ConvertTo-PeriodRange $_.period
    if (-not $slotRange) { $ok = $false }
    elseif ($slotRange[1] -lt $filterRange[0] -or $filterRange[1] -lt $slotRange[0]) { $ok = $false }
  }
  if ($ok -and $Weeks -and $_.weeks -notlike "*$Weeks*") { $ok = $false }
  if ($ok -and $Location -and $_.location -notlike "*$Location*") { $ok = $false }
  if ($ok -and $Keyword) {
    $hay = ($_.name_cn, $_.name_en, $_.teachers, $_.course_number) -join ' '
    if ($hay -notlike "*$Keyword*") { $ok = $false }
  }
  $ok
}

# ---- group by course and display ----
$grouped = $matched | Group-Object course_id
Write-Host ("[query] {0} slot(s) matched, across {1} course(s)`n" -f $matched.Count, $grouped.Count)

$result = foreach ($g in $grouped) {
  $first = $g.Group[0]
  [pscustomobject]@{
    学期     = $first.semester
    课程序号 = $first.course_number
    课程名   = $first.name_cn
    英文名   = $first.name_en
    教师     = $first.teachers
    匹配时段 = ($g.Group | ForEach-Object { $_.slot_raw }) -join ' | '
    链接     = $first.url
  }
}
$result | Sort-Object 课程序号 | Format-List

if ($Export) {
  $matched | Export-Csv -Path $Export -NoTypeInformation -Encoding UTF8
  Write-Host "`n[query] exported $($matched.Count) rows to $Export"
}
