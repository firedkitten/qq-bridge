Option Explicit
' Create (or refresh) the desktop shortcut for the QQ Bot panel.
' Usage: cscript //nologo make-shortcut.vbs <target> <workdir> [destDir]
Dim fso, sh, target, workdir, dest, name, lnk, sc
If WScript.Arguments.Count < 2 Then
  WScript.Echo "[x] usage: make-shortcut.vbs <target> <workdir> [destDir]"
  WScript.Quit 8
End If

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

target = WScript.Arguments(0)
workdir = WScript.Arguments(1)
' QQ Bot + 管理面板 (built from code points so this file stays pure ASCII)
name = "QQ Bot " & ChrW(31649) & ChrW(29702) & ChrW(38754) & ChrW(26495)

If WScript.Arguments.Count >= 3 Then
  dest = WScript.Arguments(2)
Else
  dest = sh.SpecialFolders("Desktop")
End If
If dest = "" Then dest = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\Desktop"

If Not fso.FolderExists(dest) Then
  WScript.Echo "[x] desktop folder not found: " & dest
  WScript.Quit 2
End If

lnk = dest & "\" & name & ".lnk"
On Error Resume Next
Set sc = sh.CreateShortcut(lnk)
If Err.Number <> 0 Then
  WScript.Echo "[x] create error: " & Err.Description
  Err.Clear
  On Error GoTo 0
  WScript.Quit 1
End If
sc.TargetPath = target
sc.WorkingDirectory = workdir
sc.WindowStyle = 1
sc.IconLocation = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\shell32.dll,13"
sc.Description = name & " - SSH tunnel + web panel"
sc.Save
If Err.Number <> 0 Then
  WScript.Echo "[x] save error: " & Err.Description
  WScript.Echo "[x] target was: " & lnk
  Err.Clear
  On Error GoTo 0
  WScript.Quit 1
End If
On Error GoTo 0

If fso.FileExists(lnk) Then
  WScript.Echo "[v] shortcut ready: " & lnk
  WScript.Quit 0
End If

WScript.Echo "[x] failed to save: " & lnk
WScript.Quit 1
