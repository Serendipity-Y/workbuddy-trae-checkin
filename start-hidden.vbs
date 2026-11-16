' Launch the check-in service hidden (used by the logon scheduled task).
Dim fso, sh, dir
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = dir
sh.Run "cmd.exe /c """ & dir & "\service.cmd""", 0, False