' cursor_faster — set-cursor-priority.ps1 을 콘솔 창 없이 실행
' 작업 스케줄러가 이 VBS를 호출합니다. (0 = 숨김)
Option Explicit

Dim WshShell, fso, scriptDir, ps1, cmd

Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\set-cursor-priority.ps1"

If Not fso.FileExists(ps1) Then
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
' 0 = 창 숨김, True = 감시 스크립트가 끝날 때까지 대기 (작업 스케줄러가 Running 유지)
WshShell.Run cmd, 0, True
