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

# 프로세스 스캔 간격 (초)
# - 너무 짧으면(예: 1초) 불필요한 CPU 사용 증가
# - 너무 길면(예: 60초) Cursor 실행 직후 잠깐 Normal일 수 있음
$ScanIntervalSeconds = 15

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

    $processes = Get-CursorProcesses
    if (-not $processes) {
        return 0
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

    return $changedCount
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

Write-WatcherLog -Message (
    "감시 시작 | 목표=$TargetPriority | 간격=${ScanIntervalSeconds}s | 작업=$TaskName | PID=$PID"
)

# 무한 루프: 작업 스케줄러가 중지할 때까지 실행
# (uninstall.ps1 또는 작업 스케줄러에서 "끝내기"로 종료)
while ($true) {
    try {
        $changed = Invoke-PriorityScan -DesiredPriority $desiredPriority

        if ($changed -gt 0) {
            Write-WatcherLog -Message "$changed 개 프로세스 우선순위를 $TargetPriority 로 변경"
        }
    }
    catch {
        Write-WatcherLog -Level 'ERROR' -Message "스캔 오류: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $ScanIntervalSeconds
}
