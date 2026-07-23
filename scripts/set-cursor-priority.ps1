#Requires -Version 5.1
<#
.SYNOPSIS
    Cursor IDE 프로세스의 CPU 우선순위를 지속적으로 '높음(High)'으로 유지합니다.

.DESCRIPTION
    Windows 작업 스케줄러가 로그인 시 이 스크립트를 백그라운드로 실행합니다.
    지정된 간격마다 Cursor 관련 프로세스를 검색하고, 우선순위가 목표값이 아니면
    자동으로 다시 맞춥니다.

    적용 대상 (ProcessName 기준):
      - Cursor
      - Cursor Helper
      - Cursor Helper (Renderer) 등 'Cursor'로 시작하는 모든 프로세스

    적용하지 않는 것:
      - msedgewebview2.exe (다른 앱과 공유)
      - node.exe 등 범용 프로세스

    적응형 스캔 간격:
      - High인 Cursor 프로세스 < 임계값(기본 6), 또는
        모든 Cursor 중 하나라도 목표 우선순위가 아님(예: Normal)
        → 빠른 간격(기본 15초)
      - High인 Cursor ≥ 임계값 이고 전부 목표 우선순위 → 느린 간격(기본 15분)

.NOTES
    프로젝트: https://github.com/gjtuc/cursor_faster
    직접 실행 가능하지만, 보통 install.ps1 로 작업 스케줄러에 등록해 사용합니다.
#>

# =============================================================================
# 설정 (필요 시 이 블록만 수정)
# =============================================================================

# 목표 CPU 우선순위
# 가능한 값: Idle, BelowNormal, Normal, AboveNormal, High
# 기본값 'High' = 작업 관리자의 "높음"
$TargetPriority = 'High'

# 빠른 스캔 간격 (초) — High 개수 부족, 또는 아무 Cursor나 목표 우선순위가 아닐 때
$FastScanIntervalSeconds = 15

# 느린 스캔 간격 (초) — 동시 High인 Cursor ≥ 임계값이고 전부 목표일 때
$SlowScanIntervalSeconds = 900

# 느린 간격으로 전환하는 동시 High Cursor 개수 임계값
$SlowModeHighCountThreshold = 6

# 하위 호환: 예전 단일 간격 변수 (빠른 간격과 동일하게 유지)
$ScanIntervalSeconds = $FastScanIntervalSeconds

# 로그 파일 기록 여부
$EnableLogging = $true

# 로그 저장 폴더 (%LOCALAPPDATA%\cursor_faster\watcher.log)
$LogDirectory = Join-Path $env:LOCALAPPDATA 'cursor_faster'
$LogFilePath = Join-Path $LogDirectory 'watcher.log'

# 작업 스케줄러·다른 도구에서 쓰는 작업 이름 (install.ps1 과 동일)
$TaskName = 'CursorFaster-PriorityWatcher'

# =============================================================================
# 내부 상수
# =============================================================================

# System.Diagnostics.ProcessPriorityClass 열거형에 맞춘 허용 목록
# RealTime(실시간)은 시스템 전체 불안정 위험이 있어 의도적으로 제외
$AllowedPriorities = @('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High')

# =============================================================================
# 함수
# =============================================================================

function Write-WatcherLog {
    <#
    .SYNOPSIS
        타임스탬프가 붙은 한 줄을 로그 파일에 추가합니다.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if (-not $EnableLogging) {
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $LogDirectory)) {
            New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        }

        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = "[$timestamp] [$Level] $Message"
        Add-Content -LiteralPath $LogFilePath -Value $line -Encoding UTF8
    }
    catch {
        # 로그 실패는 감시 루프를 멈추지 않음
    }
}

function Test-TargetPriorityValid {
    <#
    .SYNOPSIS
        $TargetPriority 값이 .NET ProcessPriorityClass 에서 허용되는지 검사합니다.
    #>
    if ($TargetPriority -notin $AllowedPriorities) {
        throw "잘못된 TargetPriority: '$TargetPriority'. 허용: $($AllowedPriorities -join ', ')"
    }
}

function Get-CursorProcesses {
    <#
    .SYNOPSIS
        현재 실행 중인 Cursor 관련 프로세스를 모두 반환합니다.

    .DESCRIPTION
        ProcessName이 'Cursor'로 시작하는 프로세스만 선택합니다.
        창을 여러 개 열었을 때 나오는 모든 Cursor.exe / Helper 프로세스가 포함됩니다.
    #>
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'Cursor*' }
}

function Test-CursorAnyNotAtTarget {
    <#
    .SYNOPSIS
        Cursor 프로세스 중 하나라도 목표 우선순위가 아니면 $true.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.ProcessPriorityClass]$DesiredPriority,

        [Parameter(Mandatory = $false)]
        [System.Diagnostics.Process[]]$Processes
    )

    if (-not $Processes) {
        $Processes = @(Get-CursorProcesses)
    }

    foreach ($proc in $Processes) {
        try {
            $proc.Refresh()
            if ($proc.HasExited) {
                continue
            }
            if ($proc.PriorityClass -ne $DesiredPriority) {
                return $true
            }
        }
        catch {
            # 종료 직전 등이면 다음 프로세스로
            continue
        }
    }

    return $false
}

function Get-CursorHighCount {
    <#
    .SYNOPSIS
        현재 High(목표 우선순위)인 Cursor 프로세스 개수.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.ProcessPriorityClass]$DesiredPriority,

        [Parameter(Mandatory = $false)]
        [System.Diagnostics.Process[]]$Processes
    )

    if (-not $Processes) {
        $Processes = @(Get-CursorProcesses)
    }

    $count = 0
    foreach ($proc in $Processes) {
        try {
            $proc.Refresh()
            if ($proc.HasExited) {
                continue
            }
            if ($proc.PriorityClass -eq $DesiredPriority) {
                $count++
            }
        }
        catch {
            continue
        }
    }

    return $count
}

function Set-ProcessPriorityIfNeeded {
    <#
    .SYNOPSIS
        단일 프로세스의 PriorityClass를 목표값과 다를 때만 변경합니다.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [System.Diagnostics.ProcessPriorityClass]$DesiredPriority
    )

    if ($Process.PriorityClass -eq $DesiredPriority) {
        return $false
    }

    $oldPriority = $Process.PriorityClass
    $Process.PriorityClass = $DesiredPriority

    Write-WatcherLog -Message (
        "PID $($Process.Id) [$($Process.ProcessName)]: $oldPriority -> $DesiredPriority"
    )

    return $true
}

function Invoke-PriorityScan {
    <#
    .SYNOPSIS
        한 번 스캔하여 모든 Cursor 프로세스 우선순위를 맞춥니다.
    #>
    param(
        [System.Diagnostics.ProcessPriorityClass]$DesiredPriority
    )

    $processes = @(Get-CursorProcesses)
    if ($processes.Count -eq 0) {
        return @{
            ChangedCount = 0
            Processes    = @()
        }
    }

    $changedCount = 0

    foreach ($proc in $processes) {
        try {
            # 프로세스가 스캔 도중 종료될 수 있음
            $proc.Refresh()
            if ($proc.HasExited) {
                continue
            }

            if (Set-ProcessPriorityIfNeeded -Process $proc -DesiredPriority $DesiredPriority) {
                $changedCount++
            }
        }
        catch {
            Write-WatcherLog -Level 'WARN' -Message (
                "PID $($proc.Id) 우선순위 변경 실패: $($_.Exception.Message)"
            )
        }
    }

    return @{
        ChangedCount = $changedCount
        Processes    = $processes
    }
}

function Get-NextScanIntervalSeconds {
    <#
    .SYNOPSIS
        High 개수·전체 Cursor 우선순위 상태에 따라 다음 스캔 간격을 고릅니다.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.ProcessPriorityClass]$DesiredPriority,

        [Parameter(Mandatory = $false)]
        [System.Diagnostics.Process[]]$Processes,

        [Parameter(Mandatory = $true)]
        [bool]$PreviousSlowMode
    )

    $highCount = Get-CursorHighCount -DesiredPriority $DesiredPriority -Processes $Processes
    $anyNotAtTarget = Test-CursorAnyNotAtTarget -DesiredPriority $DesiredPriority -Processes $Processes

    if ($anyNotAtTarget) {
        return @{
            IntervalSeconds = $FastScanIntervalSeconds
            SlowMode        = $false
            HighCount       = $highCount
            AnyNotAtTarget  = $true
            Reason          = 'any_not_target'
        }
    }

    if ($highCount -ge $SlowModeHighCountThreshold) {
        return @{
            IntervalSeconds = $SlowScanIntervalSeconds
            SlowMode        = $true
            HighCount       = $highCount
            AnyNotAtTarget  = $false
            Reason          = 'high_count_threshold'
        }
    }

    return @{
        IntervalSeconds = $FastScanIntervalSeconds
        SlowMode        = $false
        HighCount       = $highCount
        AnyNotAtTarget  = $false
        Reason          = 'below_threshold'
    }
}

# =============================================================================
# 메인 루프
# =============================================================================

Test-TargetPriorityValid

# 문자열 설정값을 enum으로 변환 (예: 'High' -> [ProcessPriorityClass]::High)
$desiredPriority = [System.Diagnostics.ProcessPriorityClass]::Parse(
    [System.Diagnostics.ProcessPriorityClass],
    $TargetPriority,
    $true
)

$slowMode = $false

Write-WatcherLog -Message (
    "감시 시작 | 목표=$TargetPriority | 빠른=${FastScanIntervalSeconds}s | 느린=${SlowScanIntervalSeconds}s | High임계=$SlowModeHighCountThreshold | 작업=$TaskName | PID=$PID"
)

# 무한 루프: 작업 스케줄러가 중지할 때까지 실행
# (uninstall.ps1 또는 작업 스케줄러에서 "끝내기"로 종료)
while ($true) {
    $sleepSeconds = $FastScanIntervalSeconds

    try {
        $scanResult = Invoke-PriorityScan -DesiredPriority $desiredPriority

        if ($scanResult.ChangedCount -gt 0) {
            Write-WatcherLog -Message "$($scanResult.ChangedCount) 개 프로세스 우선순위를 $TargetPriority 로 변경"
        }

        $intervalInfo = Get-NextScanIntervalSeconds `
            -DesiredPriority $desiredPriority `
            -Processes $scanResult.Processes `
            -PreviousSlowMode $slowMode

        $sleepSeconds = [int]$intervalInfo.IntervalSeconds

        if ($intervalInfo.SlowMode -ne $slowMode) {
            if ($intervalInfo.SlowMode) {
                Write-WatcherLog -Message (
                    "느린 감시로 전환 | High=$($intervalInfo.HighCount) (>=$SlowModeHighCountThreshold) | 간격=${sleepSeconds}s"
                )
            }
            else {
                Write-WatcherLog -Message (
                    "빠른 감시로 복귀 | 이유=$($intervalInfo.Reason) | High=$($intervalInfo.HighCount) | 간격=${sleepSeconds}s"
                )
            }
            $slowMode = [bool]$intervalInfo.SlowMode
        }
    }
    catch {
        Write-WatcherLog -Level 'ERROR' -Message "스캔 오류: $($_.Exception.Message)"
        $sleepSeconds = $FastScanIntervalSeconds
        $slowMode = $false
    }

    Start-Sleep -Seconds $sleepSeconds
}
