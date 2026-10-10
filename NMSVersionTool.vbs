' Launches NMSVersionTool.ps1 without a console window.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "\NMSVersionTool.ps1"""
CreateObject("WScript.Shell").Run cmd, 0, False
