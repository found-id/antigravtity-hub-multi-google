Dim WshShell
Set WshShell = CreateObject("WScript.Shell")
Dim user, pass
user = WScript.Arguments(0)
pass = WScript.Arguments(1)

WshShell.Run "runas /savecred /user:" & user & " ""cmd.exe /c exit""", 1, False
WScript.Sleep 600
WshShell.SendKeys pass & "{ENTER}"
WScript.Sleep 500
