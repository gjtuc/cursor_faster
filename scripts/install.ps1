#Requires -Version 5.1
<#
.SYNOPSIS
    cursor_faster 감시 스크립트를 Windows 작업 스케줄러에 등록합니다.

.DESCRIPTION
    사용자 로그온 시 set-cursor-priority.ps1 이 백그라운드로 실행되도록 설정합니다.
    재부팅 후에도 Cursor 프로세스 우선순위가 자동으로 '높음'으로 유지됩니다.

.PARAMETER ScriptPath
    set-cursor-priority.ps1 의 전체 경로.
    생략 시 이 install.ps1 과 같은 폴더의 set-cursor-priority.ps1 을 사용합니다.

.PARAMETER TaskName
    작업 스케줄러에 등록할 작업 이름. 기본: CursorFaster-PriorityWatcher

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -ScriptPath "D:\tools\cursor_faster\scripts\set-cursor-priority.ps1"

.NOTES
    관리자 권한 없이 일반 사용자 계정으로 실행하는 것을 권장합니다.
    (Cursor와 동일한 사용자 세션에서 프로세스 우선순위를 바꿔야 하기 때문)
#>

[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'set-cursor-priority.ps1'),

    [string]$TaskName = 'CursorFaster-PriorityWatcher'
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# 사전 검사
# -----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "감시 스크립트를 찾을 수 없습니다: $ScriptPath"
}

$resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
$quotedScript = "`"$resolvedScript`""

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' cursor_faster 설치' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host " 작업 이름 : $TaskName"
Write-Host " 스크립트  : $resolvedScript"
Write-Host " 우선순위  : High (높음)"
Write-Host " 트리거    : 사용자 로그온 시"
Write-Host ''

# -----------------------------------------------------------------------------
# 기존 작업이 있으면 제거 후 재등록
# -----------------------------------------------------------------------------

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "기존 작업 '$TaskName' 을(를) 제거하고 다시 등록합니다..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# -----------------------------------------------------------------------------
# 작업 스케줄러 액션 / 트리거 / 설정
# -----------------------------------------------------------------------------

# -WindowStyle Hidden : 로그인 시 PowerShell 창이 뜨지 않음
# -ExecutionPolicy Bypass : 스크립트 실행 정책 우회 (작업 스케줄러 인수로만 적용)
$argumentList = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $quotedScript"

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $argumentList

# 현재 사용자 로그온 시 1회 실행 (감시 스크립트가 무한 루프로 계속 동작)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)  # 시간 제한 없음 (상시 감시)

# LogonType Interactive: 사용자 데스크톱 세션에서 Cursor 프로세스에 접근
$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

# -----------------------------------------------------------------------------
# 등록
# -----------------------------------------------------------------------------

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'cursor_faster: Cursor IDE CPU 우선순위를 High로 유지합니다. https://github.com/gjtuc/cursor_faster' `
    | Out-Null

Write-Host "작업 스케줄러 등록 완료: $TaskName" -ForegroundColor Green

# -----------------------------------------------------------------------------
# 즉시 시작 (재로그인 없이 바로 적용)
# -----------------------------------------------------------------------------

try {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host '감시 작업을 지금 시작했습니다.' -ForegroundColor Green
}
catch {
    Write-Host '감시 작업 즉시 시작 실패 (재로그인 후 자동 시작됩니다):' -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}

Write-Host ''
Write-Host '확인 방법:' -ForegroundColor Cyan
Write-Host '  1. Cursor 실행'
Write-Host '  2. 작업 관리자 -> 자세히 -> Cursor.exe 우클릭 -> 우선 순위 설정 -> 높음'
Write-Host ''
Write-Host '로그 위치:' -ForegroundColor Cyan
Write-Host "  $env:LOCALAPPDATA\cursor_faster\watcher.log"
Write-Host ''
Write-Host '제거:' -ForegroundColor Cyan
Write-Host "  .\uninstall.ps1"
Write-Host ''
