#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_UseX64=y
#AutoIt3Wrapper_UseUpx=n
#AutoIt3Wrapper_Icon=database.ico
#AutoIt3Wrapper_Res_Description=Updater
#AutoIt3Wrapper_Res_CompanyName=Fabricio Zambroni
#AutoIt3Wrapper_Res_LegalCopyright=Copyright © 2026 Fabricio Zambroni
#AutoIt3Wrapper_Res_Fileversion=1.1.1.4
#AutoIt3Wrapper_Res_ProductVersion=1.1.1.1
#AutoIt3Wrapper_Res_ProductName=Updater
#AutoIt3Wrapper_Res_File_Add=E:\GitHub\FirebirdGDB_to_SQLServer_Importer\splash.jpg
#EndRegion ;**** Directives created by AutoIt3Wrapper_GUI ****
#pragma compile(inputboxres, true)

Opt("TrayIconHide", 1)
Opt("TrayAutoPause", 0)
#include <WindowsStylesConstants.au3>
#include <StaticConstants.au3>

;####################################################
;####################################################
Global $AppName = "FirebirdGDB_to_SQLServer_Importer"
;####################################################
;####################################################

Global $g_sUpdaterLogFile = ""
Global $g_sUpdaterLogBaseDir = @ScriptDir

Func _UpdaterVerboseModeEnabled()
	Return (IniRead($g_sUpdaterLogBaseDir & "\settings.ini", "Logging", "VerboseMode", "0") = "1")
EndFunc

Func _UpdaterVerboseLog($sMsg)
	; Replacement-safe verbose log. It only writes when [Logging] VerboseMode=1.
	If Not _UpdaterVerboseModeEnabled() Then Return

	Local $sLogDir = $g_sUpdaterLogBaseDir & "\log_Updater"
	If Not FileExists($sLogDir) Then DirCreate($sLogDir)
	If $g_sUpdaterLogFile = "" Then $g_sUpdaterLogFile = $sLogDir & "\log_" & @YEAR & @MON & @MDAY & "_" & @HOUR & @MIN & @SEC & ".txt"

	Local $sTimestamp = "[" & @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC & "]"
	Local $hFile = FileOpen($g_sUpdaterLogFile, 1)
	If $hFile <> -1 Then
		FileWriteLine($hFile, $sTimestamp & " [VERBOSE] " & StringReplace(StringReplace(String($sMsg), @CRLF, " "), @LF, " "))
		FileClose($hFile)
	EndIf
EndFunc



$sSplashPath = @ScriptDir & "\splash.jpg"
FileInstall("splash.jpg", $sSplashPath, 1)
Sleep(1000)

$Path = @ScriptDir
$g_sUpdaterLogBaseDir = $Path
_UpdaterVerboseLog("Updater started. Application path: " & $Path)
;~ $Path = "E:\Z_Apps\Toolbox"
;~ MsgBox(262144,"",$Path & "\" & $AppName & ".tmp")
;~ _splash()
;~ Sleep(5000)

If Not FileExists($Path & "\" & $AppName & ".tmp") Then
	_UpdaterVerboseLog("Update aborted: staged file not found: " & $Path & "\" & $AppName & ".tmp")
	FileDelete($sSplashPath)
	Exit
Else
	_UpdaterVerboseLog("Staged file found. Starting replacement.")
	_splash()
	Sleep(3000)
	If FileMove($Path & "\" & $AppName & ".tmp",$Path & "\" & $AppName & ".exe",9) Then
		_UpdaterVerboseLog("Replacement completed: " & $Path & "\" & $AppName & ".exe")
	Else
		_UpdaterVerboseLog("Replacement failed. Source=" & $Path & "\" & $AppName & ".tmp" & " | Target=" & $Path & "\" & $AppName & ".exe")
		FileDelete($sSplashPath)
		Exit
	EndIf
	Sleep(2000)
	_UpdaterVerboseLog("Restarting application: " & $Path & "\" & $AppName & ".exe")
	Run('"' & $Path & "\" & $AppName & ".exe" & '"')

EndIf
FileDelete($sSplashPath)
Exit

Func _splash()

	$splashWin_X = 640
	$splashWin_Y = 360

	Global $Form_Splash = GUICreate("", $splashWin_X, $splashWin_Y, -1, -1, $WS_POPUP, BitOR($WS_EX_TOPMOST, $WS_EX_TOOLWINDOW, $WS_EX_LAYERED))


	Global $Pic_Splash = GUICtrlCreatePic($sSplashPath, 5, 5, 630, 350)

	Global $Label_Percentage = GUICtrlCreateLabel("Updating " & $AppName & " . . . Please wait", 5, 330, 630, 25, $SS_CENTER)
	GUICtrlSetFont($Label_Percentage, 17)
	GUICtrlSetColor($Label_Percentage, 0xFF0000)

	GUISetState(@SW_SHOW, $Form_Splash)
	_UpdaterVerboseLog("Splash screen displayed.")


EndFunc   ;==>_splash
