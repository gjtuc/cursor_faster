#Requires -Version 5.1
<#
.SYNOPSIS
    cursor_faster 작업 스케줄러 등록 및 (선택) 로그 파일을 제거합니다.

.PARAMETER TaskName
    제거할 작업 스케줄러 이름. 기본: CursorFaster-PriorityWatcher

.PARAMETER KeepLogs
    지정하면 watcher.log 및 로그 폴더를 남깁니다.

.EXAMPLE
    .\uninstall.ps1

.EXAMPLE
    .\uninstall.ps1 -KeepLogs
#>

[CmdletBinding()]
param(
    [string]$TaskName = 'CursorFaster-PriorityWatcher',

    [switch]$KeepLogs
)

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' cursor_faster 제거' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''

# -----------------------------------------------------------------------------
# 1) 예약 작업 중지 및 삭제
# -----------------------------------------------------------------------------

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($task) {
    try {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    catch {
        # 이미 중지된 경우 무시
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "작업 스케줄러 제거 완료: $TaskName" -ForegroundColor Green
}
else {
    Write-Host "등록된 작업이 없습니다: $TaskName" -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# 2) 백그라운드 감시 PowerShell 종료
#    (작업 스케줄러가 띄운 set-cursor-priority.ps1 프로세스)
# -----------------------------------------------------------------------------

$watcherProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        (
            $_.Name -eq 'powershell.exe' -and
            $_.CommandLine -like '*set-cursor-priority.ps1*'
        ) -or (
            ($_.Name -eq 'wscript.exe' -or $_.Name -eq 'cscript.exe') -and
            $_.CommandLine -like '*run-watcher-hidden.vbs*'
        )
    }

if ($watcherProcesses) {
    foreach ($proc in $watcherProcesses) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Host "감시 프로세스 종료: PID $($proc.ProcessId) ($($proc.Name))" -ForegroundColor Green
        }
        catch {
            Write-Host "감시 프로세스 종료 실패 PID $($proc.ProcessId): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
else {
    Write-Host '실행 중인 감시 프로세스가 없습니다.' -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# 3) 로그 폴더 (선택 삭제)
# -----------------------------------------------------------------------------

$logDirectory = Join-Path $env:LOCALAPPDATA 'cursor_faster'

if (-not $KeepLogs -and (Test-Path -LiteralPath $logDirectory)) {
    try {
        Remove-Item -LiteralPath $logDirectory -Recurse -Force
        Write-Host "로그 폴더 삭제: $logDirectory" -ForegroundColor Green
    }
    catch {
        Write-Host "로그 폴더 삭제 실패: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
elseif ($KeepLogs) {
    Write-Host "로그 유지: $logDirectory" -ForegroundColor Gray
}

Write-Host ''
Write-Host '제거 완료. Cursor 우선순위는 더 이상 자동으로 변경되지 않습니다.' -ForegroundColor Cyan
Write-Host '이미 High로 올라간 프로세스는 Cursor를 재시작하면 Normal로 돌아갑니다.' -ForegroundColor Gray
Write-Host ''
