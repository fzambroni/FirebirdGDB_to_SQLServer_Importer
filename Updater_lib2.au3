#include-once
; ----------------------------------------------------------------------------------------------------------------------
; Updater
; ----------------------------------------------------------------------------------------------------------------------

; COM error handler (catches $oConn.Execute failures instead of crashing)
Global $g_oComErr = ObjEvent("AutoIt.Error", "_ComErrorHandler")
Global $g_sLastComError = ""
Global $GitHubAppName

; ----------------------------------------------------------------------------------------------------------------------
; Updater - GitHub based
; ----------------------------------------------------------------------------------------------------------------------
; This updater no longer uses a shared network folder. It reads the latest version from GitHub version.txt,
; downloads the published Toolbox.exe only when a newer version is available, then lets Updater.exe replace the file.
Global Const $g_sGitHubDefaultRawBase = "https://raw.githubusercontent.com/fzambroni/" & $GitHubAppName & "/main"
Global $g_sGitHubRawBase = IniRead(@ScriptDir & "\settings.ini", "Update", "github_raw_base", $g_sGitHubDefaultRawBase)
If StringStripWS($g_sGitHubRawBase, 3) = "" Then $g_sGitHubRawBase = $g_sGitHubDefaultRawBase

; Keep settings.ini explicit and self-documenting. The old [Update] path entry is intentionally ignored.
IniWrite(@ScriptDir & "\settings.ini", "Update", "source", "github")
IniWrite(@ScriptDir & "\settings.ini", "Update", "github_raw_base", $g_sGitHubRawBase)



Func _ComErrorHandler()
    Local $oErr = $g_oComErr
    $g_sLastComError = "COM Error 0x" & Hex($oErr.number, 8) & ": " & $oErr.description
EndFunc

Func _CheckGitHubUpdate()
    Local $sCurrentVersion = FileGetVersion(@ScriptFullPath)
    If StringStripWS($sCurrentVersion, 3) = "" Then
;~         _LogConsoleReplacement("GitHub update check skipped: local file version could not be read.")
        Return
    EndIf

    Local $sAppName = _FileNameWithoutExtension(@ScriptName)
    Local $sRemoteVersionUrl = _JoinUrl($g_sGitHubRawBase, "version.txt")
    Local $sRemoteExeUrl = _JoinUrl($g_sGitHubRawBase, @ScriptName)
    Local $sRemoteVersionTmp = @ScriptDir & "\" & $sAppName & "_github_version.txt"
    Local $sRemoteExeTmp = @ScriptDir & "\" & $sAppName & "_github_latest.exe"
    Local $sLocalTmp = @ScriptDir & "\" & $sAppName & ".tmp"
    Local $sUpdaterFile = @ScriptDir & "\Updater.exe"

	FileDelete($sUpdaterFile)

;~     _LogConsoleReplacement("Checking for updates from GitHub version file: " & $sRemoteVersionUrl)

    Local $sRemoteVersion = _GetGitHubVersionFromTextFile($sRemoteVersionUrl, $sRemoteVersionTmp)
    If StringStripWS($sRemoteVersion, 3) = "" Then
;~         _LogConsoleReplacement("GitHub update check skipped: remote version.txt could not be read.")
        FileDelete($sRemoteVersionTmp)
        Return
    EndIf

;~     _LogConsoleReplacement("Local version: " & $sCurrentVersion & " | GitHub version: " & $sRemoteVersion)

    If _CompareVersions($sRemoteVersion, $sCurrentVersion) <= 0 Then
;~         _LogConsoleReplacement("No update required.")
        FileDelete($sRemoteVersionTmp)
        Return
    EndIf

;~     _LogConsoleReplacement("Newer GitHub version found. Downloading: " & $sRemoteExeUrl)

    If Not _DownloadFile($sRemoteExeUrl, $sRemoteExeTmp) Then
        FileDelete($sRemoteVersionTmp)
        Return
    EndIf

    ; Validate that the executable we are about to install matches the version announced in version.txt.
    ; This prevents installing an older exe when version.txt was updated before Toolbox.exe was published.
    Local $sDownloadedExeVersion = FileGetVersion($sRemoteExeTmp)
    If StringStripWS($sDownloadedExeVersion, 3) = "" Then
;~         _LogConsoleReplacement("Update aborted: downloaded executable version could not be read.")
        FileDelete($sRemoteVersionTmp)
        FileDelete($sRemoteExeTmp)
        Return
    EndIf

    If _CompareVersions($sDownloadedExeVersion, $sRemoteVersion) < 0 Then
;~         _LogConsoleReplacement("Update aborted: downloaded executable version is older than version.txt. Downloaded=" & $sDownloadedExeVersion & ", version.txt=" & $sRemoteVersion)
        FileDelete($sRemoteVersionTmp)
        FileDelete($sRemoteExeTmp)
        Return
    EndIf


    If _CompareVersions($sDownloadedExeVersion, $sCurrentVersion) <= 0 Then
;~         _LogConsoleReplacement("Update aborted: downloaded executable version is not newer. Downloaded=" & $sDownloadedExeVersion & ", Local=" & $sCurrentVersion)
        FileDelete($sRemoteVersionTmp)
        FileDelete($sRemoteExeTmp)
        Return
EndIf
;~ #ce

    FileDelete($sLocalTmp)
    If Not FileMove($sRemoteExeTmp, $sLocalTmp, 9) Then
;~         _LogConsoleReplacement("Update aborted: could not stage downloaded file at " & $sLocalTmp)
        FileDelete($sRemoteVersionTmp)
        FileDelete($sRemoteExeTmp)
        Return
    EndIf

;~     _LogConsoleReplacement("Update staged at: " & $sLocalTmp)
    FileInstall("Updater.exe", $sUpdaterFile, 1)
    Sleep(500)
    Run($sUpdaterFile & " '" & @ScriptDir & "'")
	_splash("off")
    Sleep(100)
    Exit
EndFunc

Func _GetGitHubVersionFromTextFile($sUrl, $sDestination)
    FileDelete($sDestination)
    If Not _DownloadFile($sUrl, $sDestination) Then Return ""

    Local $sContent = FileRead($sDestination)
    If @error Then Return ""

    $sContent = StringStripWS($sContent, 3)

    ; version.txt must contain only the version number, for example: 1.1.5.0
    Local $aMatch = StringRegExp($sContent, "^([0-9]+(?:\.[0-9]+){1,3})$", 1)
    If @error Or UBound($aMatch) = 0 Then
;~         _LogConsoleReplacement("Invalid version.txt content: " & $sContent)
        Return ""
    EndIf

    Return $aMatch[0]
EndFunc

Func _DownloadFile($sUrl, $sDestination)
    FileDelete($sDestination)
    Local $hDownload = InetGet($sUrl, $sDestination, $INET_FORCERELOAD, $INET_DOWNLOADWAIT)
    If @error Or $hDownload = 0 Or Not FileExists($sDestination) Or FileGetSize($sDestination) <= 0 Then
;~         _LogConsoleReplacement("Download failed: " & $sUrl)
        Return False
    EndIf
    Return True
EndFunc

Func _JoinUrl($sBase, $sFile)
    Local $sCleanBase = StringStripWS($sBase, 3)
    While StringRight($sCleanBase, 1) = "/"
        $sCleanBase = StringTrimRight($sCleanBase, 1)
    WEnd
    Return $sCleanBase & "/" & $sFile
EndFunc

Func _FileNameWithoutExtension($sFileName)
    Local $iDot = StringInStr($sFileName, ".", 0, -1)
    If $iDot <= 1 Then Return $sFileName
    Return StringLeft($sFileName, $iDot - 1)
EndFunc

Func _CompareVersions($sLeft, $sRight)
    Local $aLeft = StringSplit(StringStripWS($sLeft, 3), ".")
    Local $aRight = StringSplit(StringStripWS($sRight, 3), ".")
    Local $iMax = $aLeft[0]
    If $aRight[0] > $iMax Then $iMax = $aRight[0]

    For $i = 1 To $iMax
        Local $nLeft = 0
        Local $nRight = 0
        If $i <= $aLeft[0] Then $nLeft = Number($aLeft[$i])
        If $i <= $aRight[0] Then $nRight = Number($aRight[$i])

        If $nLeft > $nRight Then Return 1
        If $nLeft < $nRight Then Return -1
    Next

    Return 0
EndFunc
