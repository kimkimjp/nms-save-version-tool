' Creates a desktop shortcut "NMS Save Version Tool" that launches NMSVersionTool.vbs in this folder.
Option Explicit

Dim fso, sh, dir, desktop, icon, steamPath, exe, lnk

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)

If Not fso.FileExists(dir & "\NMSVersionTool.vbs") Then
    MsgBox "NMSVersionTool.vbs was not found in this folder:" & vbCrLf & dir, vbExclamation, "NMS Save Version Tool"
    WScript.Quit 1
End If

desktop = sh.SpecialFolders("Desktop")

' Icon: NMS.exe of the Steam install if found, otherwise a generic shell32 icon.
icon = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\shell32.dll,43"
steamPath = ""
On Error Resume Next
steamPath = sh.RegRead("HKCU\Software\Valve\Steam\SteamPath")
Err.Clear
On Error GoTo 0
If steamPath <> "" Then
    ' The game may live in another Steam library, so check every "path" listed in libraryfolders.vdf too.
    Dim libs, vdf, re, m, lib
    steamPath = Replace(steamPath, "/", "\")
    libs = Array(steamPath)
    vdf = steamPath & "\steamapps\libraryfolders.vdf"
    If fso.FileExists(vdf) Then
        Set re = New RegExp
        re.Pattern = """path""\s+""([^""]+)"""
        re.Global = True
        For Each m In re.Execute(fso.OpenTextFile(vdf, 1).ReadAll)
            ReDim Preserve libs(UBound(libs) + 1)
            libs(UBound(libs)) = Replace(m.SubMatches(0), "\\", "\")
        Next
    End If
    For Each lib In libs
        exe = lib & "\steamapps\common\No Man's Sky\Binaries\NMS.exe"
        If fso.FileExists(exe) Then
            icon = exe & ",0"
            Exit For
        End If
    Next
End If

On Error Resume Next
Set lnk = sh.CreateShortcut(desktop & "\NMS Save Version Tool.lnk")
lnk.TargetPath = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\wscript.exe"
lnk.Arguments = """" & dir & "\NMSVersionTool.vbs"""
lnk.WorkingDirectory = dir
lnk.IconLocation = icon
lnk.Description = "NMS Save Version Tool"
lnk.Save
If Err.Number <> 0 Then
    MsgBox "Could not create the shortcut:" & vbCrLf & Err.Description, vbExclamation, "NMS Save Version Tool"
    WScript.Quit 1
End If
On Error GoTo 0

MsgBox "Shortcut created on your desktop: NMS Save Version Tool", vbInformation, "NMS Save Version Tool"
