Set WshShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
WshShell.CurrentDirectory = scriptDir
psScript = """" & scriptDir & "\AntigravityProfileManager.ps1"""
cmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File " & psScript
WshShell.Run cmd, 0, False
