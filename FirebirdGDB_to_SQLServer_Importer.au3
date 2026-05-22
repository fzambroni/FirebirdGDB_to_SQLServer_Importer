#NoTrayIcon
#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_Icon=database.ico
#AutoIt3Wrapper_UseUpx=n
#AutoIt3Wrapper_UseX64=y
#AutoIt3Wrapper_Res_Description=Firebird GDB to SQLServer Importer
#AutoIt3Wrapper_Res_Fileversion=1.1.3.9
#AutoIt3Wrapper_Res_ProductName=Firebird GDB to SQLServer Importer
#AutoIt3Wrapper_Res_ProductVersion=1.1.1.1
#AutoIt3Wrapper_Res_CompanyName=Fabricio Zambroni
#AutoIt3Wrapper_Res_LegalCopyright=Copyright © 2026 Fabricio Zambroni
#AutoIt3Wrapper_Res_File_Add=E:\GitHub\FirebirdGDB_to_SQLServer_Importer\Updater.exe
#AutoIt3Wrapper_Res_File_Add=E:\GitHub\FirebirdGDB_to_SQLServer_Importer\Help.html
#AutoIt3Wrapper_Res_File_Add=E:\GitHub\FirebirdGDB_to_SQLServer_Importer\splash.jpg
#AutoIt3Wrapper_Run_After=E:\GitHub\FirebirdGDB_to_SQLServer_Importer\FileUpdate.exe
#EndRegion ;**** Directives created by AutoIt3Wrapper_GUI ****


#cs ----------------------------------------------------------------------------
    Firebird GDB -> SQL Server Importer (AutoIt)
    ------------------------------------------------
    English-only UI

    Purpose:
      - Reads Firebird .gdb through the Firebird ODBC driver
      - Inserts data into an existing SQL Server schema
      - Does NOT create or change the target database structure
      - Supports append mode with duplicate primary-key skipping
      - Preserves explicit values for SQL Server IDENTITY columns when source data provides them
      - Temporarily disables target table triggers during clear/load when requested
      - Temporarily disables SQL Server table constraints/triggers during clear only, then restores the intended load trigger mode
      - Skips selected Firebird tables that do not exist in the target SQL Server schema
      - Orders selected tables using SQL Server foreign-key dependencies
      - Creates one log file per run under .\log\import_YYYYMMDD_HHMMSS.log
      - Exports selected Firebird GDB tables to SQL Server-compatible .sql text files under .\Export\GDB_SQL_Export_YYYYMMDD_HHMMSS
      - Exported scripts include table metadata, SQL data types for each source column, CREATE TABLE statements, and INSERT statements
      - Shows an import/export progress bar and a final result message box for success, warning/failure, or abort
      - Adds Verbose mode for detailed debug logging of SQL/Firebird commands, import row decisions, and execution returns
      - Avoids invalid DEFAULT usage in duplicate-check WHERE clauses and row INSERTs
      - Treats true duplicate SQL Server rows as non-fatal, but verifies the parent row exists before skipping
      - Quarantines known Ortems startup-invalid rows/tables detected from PL_0451 and PL_0445 screenshots
      - Adds row snapshots and post-import PL_0170 WO/header-phase integrity cleanup to make Ortems startup issues traceable in the log
      - Applies deterministic NOT NULL fallbacks for mandatory target fields when Ortems-safe mode is active
      - Applies Ortems semantic table dependencies before import: routings before phases, WO headers before WO phases, and WO phases before details
      - Applies final SQL Server FK topological ordering after Ortems semantic ordering, so semantic grouping cannot break physical FK dependencies
      - Preflights Firebird WO header/phase correspondence and skips complete orphan WO chains before loading target data
      - Repairs mandatory Ortems WO version effectivity dates (E_OF_VER.VER_EFFET_DEBUT) from the WO chain before inserting rows
      - Repairs Ortems export date-format parameters that SQL Server defaults can leave as invalid text values, preventing PL_0439 on startup

    Notes:
      - The SQL Server schema must already exist.
      - This importer intentionally uses target SQL Server metadata for literal conversion.
        That prevents issues such as Firebird BLOB data being inserted as VARBINARY into
        SQL Server NTEXT/NVARCHAR columns.
#ce ----------------------------------------------------------------------------

#NoTrayIcon
#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <ScrollBarConstants.au3>
#include <EditConstants.au3>
#include <GuiEdit.au3>
#include <StaticConstants.au3>
#include <ButtonConstants.au3>
#include <ProgressConstants.au3>
#include <ListViewConstants.au3>
#include <GuiListView.au3>
#include <Array.au3>
#include <Date.au3>
#include <StructureConstants.au3>
#include <TabConstants.au3>
#include <GuiTab.au3>
#include <File.au3>
#include <String.au3>
#include <WindowsStylesConstants.au3>
#include <InetConstants.au3>
#include "Updater_lib2.au3"




Opt("MustDeclareVars", 1)


Global $GitHubAppName = "FirebirdGDB_to_SQLServer_Importer"

;Splash Screen
Global $splashWin_X = 640
Global $splashWin_Y = 360
Global $WinPos_X = -1
Global $WinPos_Y = -1
Global $Label_Percentage = "30%"
Global $Progress_Splash = "0"
Global $sSplashPath = @ScriptDir & "\splash.jpg"
FileInstall("splash.jpg", $sSplashPath, 1)
_splash("on")
Sleep(200)
GUICtrlSetData($Label_Percentage, "30%")
GUICtrlSetData($Progress_Splash, 30)
Sleep(300)


; Skip automatic update checks when running the .au3 directly from SciTE/dev mode.
If Not StringInStr(StringLower(@ScriptName), ".au3") Then
    _CheckGitHubUpdate()
EndIf


Global $g_oFbConn = 0
Global $g_oSqlConn = 0
Global $g_sLogFile = ""
Global $g_iBatchSize = 500
Global $g_bVerboseMode = False
Global $g_iVerboseSqlMaxChars = 20000

Global $g_bAbort = False
Global $g_sCurrentSql = ""
Global $g_iErrorCount = 0
Global $g_iMaxErrors = 50
Global $g_iSkippedDuplicates = 0
Global $g_iSkippedRows = 0
Global $g_iSkippedTables = 0
Global $g_iInsertedRows = 0
Global $g_iWarningCount = 0
Global $g_iQuarantinedRows = 0
Global $g_bOrtemsStartupSanitizer = True
Global $g_aOrtemsSourceOrphanWOs[0]
Global $g_aOrtemsSourceOrphanWOs2[0]
Global $g_iOrtemsSourceOrphanRowsSkipped = 0
Global $g_iOrtemsEffectivityFixups = 0
Global $g_iOrtemsExportDateFormatFixups = 0
Global $g_sOrtemsDefaultExportDateFormat = "0"
Global $g_dOrtemsWoStartCache = 0
Global $g_iProgressLastPercent = -1
Global $g_iProgressLastUpdateTick = 0

Global $g_bInSqlExec = False
Global $g_bComError = False
Global $g_sLastComError = ""
Global $g_sLastAdoErrorText = "" ; concatenated ADO error descriptions from the last SQL execution
Global $g_bLastSqlExecFailed = False

Global $g_oComErr = ObjEvent("AutoIt.Error", "_ComErrHandler")
Global $g_sIniPath = @ScriptDir & "\Settings.ini"

; Common loop counters. Declared globally to keep Opt("MustDeclareVars", 1) happy in all AutoIt versions.
Global $i = 0, $c = 0




; -----------------------------
; GUI
; -----------------------------
Global $hGUI = GUICreate("Firebird GDB -> SQL Server Importer", 1040, 760, -1,-1)

GUICtrlSetData($Label_Percentage, "60%")
GUICtrlSetData($Progress_Splash, 60)
Sleep(500)
GUICtrlCreateGroup("Source (Firebird)", 10, 10, 1020, 160)
Global $lblGdb = GUICtrlCreateLabel("GDB file path:", 25, 40, 110, 20)
Global $inpGdb = GUICtrlCreateInput("", 140, 36, 700, 24)
Global $btnBrowseGdb = GUICtrlCreateButton("Browse...", 855, 35, 150, 26)

Global $lblFbServer = GUICtrlCreateLabel("Firebird server:", 25, 75, 110, 20)
Global $inpFbServer = GUICtrlCreateInput("localhost", 140, 71, 220, 24)

Global $lblFbPort = GUICtrlCreateLabel("Port:", 380, 75, 40, 20)
Global $inpFbPort = GUICtrlCreateInput("3050", 420, 71, 80, 24)

Global $lblFbUser = GUICtrlCreateLabel("User:", 520, 75, 40, 20)
Global $inpFbUser = GUICtrlCreateInput("SYSDBA", 565, 71, 120, 24)

Global $lblFbPass = GUICtrlCreateLabel("Password:", 700, 75, 65, 20)
Global $inpFbPass = GUICtrlCreateInput("masterkey", 770, 71, 235, 24, $ES_PASSWORD)

Global $btnTestFb = GUICtrlCreateButton("Test Firebird Connection", 25, 110, 220, 30)
Global $btnLoadTables = GUICtrlCreateButton("1 - Load Table List", 260, 110, 160, 30)
GUICtrlSetBkColor($btnLoadTables, 0x009900)
GUICtrlSetColor($btnLoadTables, 0xFFFFFF)
GUICtrlSetFont($btnLoadTables, 10, 800)

GUICtrlCreateGroup("Target (SQL Server)", 10, 180, 1020, 210)

Global $lblSqlServer = GUICtrlCreateLabel("SQL Server:", 25, 210, 110, 20)
Global $inpSqlServer = GUICtrlCreateInput("", 140, 206, 260, 24)

Global $lblSqlDb = GUICtrlCreateLabel("Database:", 420, 210, 70, 20)
Global $inpSqlDb = GUICtrlCreateInput("", 490, 206, 210, 24)

Global $lblAuth = GUICtrlCreateLabel("Authentication:", 720, 210, 90, 20)
Global $cmbAuth = GUICtrlCreateCombo("Windows Authentication", 815, 206, 190, 24)
GUICtrlSetData($cmbAuth, "SQL Server Authentication")

Global $lblSqlUser = GUICtrlCreateLabel("User:", 25, 245, 110, 20)
Global $inpSqlUser = GUICtrlCreateInput("", 140, 241, 260, 24)
GUICtrlSetState($inpSqlUser, $GUI_DISABLE)

Global $lblSqlPass = GUICtrlCreateLabel("Password:", 420, 245, 70, 20)
Global $inpSqlPass = GUICtrlCreateInput("", 490, 241, 210, 24, $ES_PASSWORD)
GUICtrlSetState($inpSqlPass, $GUI_DISABLE)

Global $lblSchema = GUICtrlCreateLabel("Target schema:", 720, 245, 90, 20)
Global $inpSchema = GUICtrlCreateInput("dbo", 815, 241, 190, 24)

Global $lblConnStr = GUICtrlCreateLabel("Connection string:", 25, 280, 110, 20)
Global $inpConnStr = GUICtrlCreateInput("", 140, 276, 865, 24, $ES_READONLY)

Global $btnTestSql = GUICtrlCreateButton("Test SQL Server Connection", 25, 315, 220, 30)

; Import options
Global $chkClearBeforeLoad = GUICtrlCreateCheckbox("Clear selected tables before load", 260, 318, 230, 22)
Global $chkSkipDuplicatePK = GUICtrlCreateCheckbox("Skip duplicate PK rows in append mode", 500, 318, 250, 22)
Global $chkOrderByFK = GUICtrlCreateCheckbox("Order tables by SQL Server FK dependencies", 760, 318, 260, 22)
Global $chkEmptyStringAsNull = GUICtrlCreateCheckbox("Convert empty strings to NULL when target column is nullable", 260, 345, 380, 22)
Global $chkFallbackNotNull = GUICtrlCreateCheckbox("Use safe fallback/default for NULL values in NOT NULL columns", 650, 345, 370, 22)
Global $chkDisableTriggers = GUICtrlCreateCheckbox("Temporarily disable target table triggers during clear/load", 260, 368, 430, 18)

; Table selection
GUICtrlCreateGroup("Tables to Import", 10, 395, 510, 265)
Global $lvTables = GUICtrlCreateListView("Import|Table", 25, 415, 480, 220, BitOR($LVS_REPORT, $LVS_SHOWSELALWAYS))
_GUICtrlListView_SetExtendedListViewStyle($lvTables, BitOR($LVS_EX_CHECKBOXES, $LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))
_GUICtrlListView_SetColumnWidth($lvTables, 0, 60)
_GUICtrlListView_SetColumnWidth($lvTables, 1, 380)


; Run + Log
GUICtrlCreateGroup("Run", 530, 395, 500, 265)
Global $btnRun = GUICtrlCreateButton("3 - Run Import", 550, 415, 150, 34)
GUICtrlSetBkColor($btnRun, 0xFF3333)
GUICtrlSetColor($btnRun, 0xFFFFFF)
GUICtrlSetFont($btnRun, 10, 800)

Global $lblBatch = GUICtrlCreateLabel("Log Batch:", 720, 424, 70, 18)
Global $inpBatch = GUICtrlCreateInput("500", 795, 420, 80, 24)
Global $btnAbort = GUICtrlCreateButton("Abort", 900, 420, 100, 24)
GUICtrlSetState($btnAbort, $GUI_DISABLE)

Global $lblProgress = GUICtrlCreateLabel("Progress: 0%", 550, 458, 460, 18)
Global $prgImport = GUICtrlCreateProgress(550, 478, 455, 18);, $PBS_MARQUEE)
GUICtrlSetData($prgImport, 0)

Global $lblLogFileTitle = GUICtrlCreateLabel("Current log file:", 550, 503, 100, 18) ;, $SS_GRAYFRAME)
Global $chkVerboseMode = GUICtrlCreateCheckbox("Verbose mode", 720, 501, 140, 22)
GUICtrlSetTip($chkVerboseMode, "Write detailed SQL commands, Firebird queries, return status, and row-level import decisions to the log file.")
Global $lblLogFile = GUICtrlCreateLabel("(a new .\log\import_YYYYMMDD_HHMMSS.log file will be created for each run)", 550, 522, 455, 18) ;, $SS_GRAYFRAME)

GUICtrlSetData($Label_Percentage, "90%")
GUICtrlSetData($Progress_Splash, 90)
Sleep(1000)
Global $txtLog = GUICtrlCreateEdit("", 550, 545, 455, 90, BitOR($ES_READONLY, $ES_MULTILINE, $WS_VSCROLL))
GUICtrlSetFont($txtLog, 9, 400, 0, "Consolas")

GUICtrlCreateLabel("Developed by Fabricio Zambroni - Version: " & FileGetVersion(@ScriptFullPath), 550, 640, 250, 15)
GUICtrlSetColor(-1, 0x0000FF)
; Bottom buttons
Global $btnSelectAll = GUICtrlCreateButton("2 - Select All", 25, 665, 150, 34)
GUICtrlSetBkColor($btnSelectAll, 0xFF8000)
GUICtrlSetColor($btnSelectAll, 0xFFFFFF)
GUICtrlSetFont($btnSelectAll, 10, 800)

Global $btnClearAll = GUICtrlCreateButton("Clear All", 185, 665, 150, 34)
Global $btnExportSql = GUICtrlCreateButton("Export SQL Scripts", 350, 665, 170, 34)
GUICtrlSetBkColor($btnExportSql, 0x0066CC)
GUICtrlSetColor($btnExportSql, 0xFFFFFF)
GUICtrlSetFont($btnExportSql, 10, 800)
Global $btnHelp = GUICtrlCreateButton("?", 600, 665, 35, 34)
GUICtrlSetBkColor($btnHelp, 0xA0A0A0)
GUICtrlSetColor($btnHelp, 0xFFFFFF)
GUICtrlSetFont($btnHelp, 11, 700)
Global $btnClearLog = GUICtrlCreateButton("Clear Log", 700, 665, 150, 34)
Global $btnExit = GUICtrlCreateButton("Exit", 880, 665, 150, 34)

; Footer
Global $lblStatus = GUICtrlCreateLabel("Status: Ready", 10, 720, 700, 22)
Global $lblErrCount = GUICtrlCreateLabel("Errors: 0 / 50 | Warnings: 0", 720, 720, 310, 22)
GUICtrlSetData($Label_Percentage, "100%")
GUICtrlSetData($Progress_Splash, 100)
Sleep(500)
_splash("off")
GUISetState(@SW_SHOW, $hGUI)

_LoadSettings()

; -----------------------------
; Main loop
; -----------------------------
While 1
	Switch GUIGetMsg()
		Case $GUI_EVENT_CLOSE, $btnExit
			_SaveSettings()
			_Cleanup()
			Exit

		Case $cmbAuth
			_OnSqlAuthChange()
			_SaveSettings()

		Case $btnBrowseGdb
			Local $s = FileOpenDialog("Select Firebird GDB database file", @ScriptDir, "Firebird Database (*.gdb)|All (*.*)", 1)
			If Not @error And $s <> "" Then
				GUICtrlSetData($inpGdb, $s)
				_SaveSettings()
			EndIf

		Case $btnClearLog
			_ClearLog()

		Case $btnHelp
			_OpenHelp()

		Case $btnTestFb
			_SaveSettings()
			_Status("Status: Testing Firebird connection...")
			If _OpenFirebird() Then
				_Log("Firebird connection OK.")
				_Status("Status: Firebird connection OK.")
			Else
				_Status("Status: Firebird connection FAILED.")
			EndIf

		Case $btnTestSql
			_SaveSettings()
			_BuildSqlConnStr()
			_Status("Status: Testing SQL Server connection...")
			If _OpenSqlServer() Then
				_Log("SQL Server connection OK.")
				_Status("Status: SQL Server connection OK.")
			Else
				_Status("Status: SQL Server connection FAILED.")
			EndIf

		Case $btnLoadTables
			_SaveSettings()
			_Status("Status: Loading Firebird tables...")
			If Not _OpenFirebird() Then
				_Status("Status: Cannot load tables. Firebird connection failed.")
				ContinueLoop
			EndIf
			_LoadTableList()
			_Status("Status: Table list loaded.")

		Case $btnSelectAll
			_SetAllChecks(True)

		Case $btnClearAll
			_SetAllChecks(False)

		Case $btnExportSql
			_RunExportSqlScripts()

		Case $chkClearBeforeLoad, $chkSkipDuplicatePK, $chkOrderByFK, $chkEmptyStringAsNull, $chkFallbackNotNull, $chkDisableTriggers, $chkVerboseMode
			_SaveSettings()

		Case $btnAbort
			_RequestAbort()

		Case $btnRun
			_RunImport()
	EndSwitch
WEnd

; -----------------------------
; UI helpers
; -----------------------------
Func _SetAllChecks($bOn)
	Local $count = _GUICtrlListView_GetItemCount($lvTables)
	For $i = 0 To $count - 1
		_GUICtrlListView_SetItemChecked($lvTables, $i, $bOn)
	Next
EndFunc   ;==>_SetAllChecks

Func _GetCheckedTables()
	Local $count = _GUICtrlListView_GetItemCount($lvTables)
	Local $a[0]
	For $i = 0 To $count - 1
		If _GUICtrlListView_GetItemChecked($lvTables, $i) Then
			Local $name = _GUICtrlListView_GetItemText($lvTables, $i, 1)
			ReDim $a[UBound($a) + 1]
			$a[UBound($a) - 1] = $name
		EndIf
	Next
	Return $a
EndFunc   ;==>_GetCheckedTables

Func _SetUiEnabled($bEnabled)
	Local $iState = $GUI_ENABLE
	If Not $bEnabled Then $iState = $GUI_DISABLE

	GUICtrlSetState($inpGdb, $iState)
	GUICtrlSetState($btnBrowseGdb, $iState)
	GUICtrlSetState($inpFbServer, $iState)
	GUICtrlSetState($inpFbPort, $iState)
	GUICtrlSetState($inpFbUser, $iState)
	GUICtrlSetState($inpFbPass, $iState)
	GUICtrlSetState($btnTestFb, $iState)
	GUICtrlSetState($btnLoadTables, $iState)

	GUICtrlSetState($inpSqlServer, $iState)
	GUICtrlSetState($inpSqlDb, $iState)
	GUICtrlSetState($cmbAuth, $iState)
	GUICtrlSetState($inpSqlUser, $iState)
	GUICtrlSetState($inpSqlPass, $iState)
	GUICtrlSetState($inpSchema, $iState)
	GUICtrlSetState($btnTestSql, $iState)

	GUICtrlSetState($chkClearBeforeLoad, $iState)
	GUICtrlSetState($chkSkipDuplicatePK, $iState)
	GUICtrlSetState($chkOrderByFK, $iState)
	GUICtrlSetState($chkEmptyStringAsNull, $iState)
	GUICtrlSetState($chkFallbackNotNull, $iState)
	GUICtrlSetState($chkDisableTriggers, $iState)
	GUICtrlSetState($chkVerboseMode, $iState)

	GUICtrlSetState($lvTables, $iState)
	GUICtrlSetState($btnSelectAll, $iState)
	GUICtrlSetState($btnClearAll, $iState)
	GUICtrlSetState($btnExportSql, $iState)
	GUICtrlSetState($btnRun, $iState)
	GUICtrlSetState($inpBatch, $iState)
	GUICtrlSetState($btnHelp, $iState)
	GUICtrlSetState($btnClearLog, $iState)
	GUICtrlSetState($btnExit, $iState)

	If $bEnabled Then
		GUICtrlSetState($btnAbort, $GUI_DISABLE)
		_OnSqlAuthChange()
	Else
		GUICtrlSetState($btnAbort, $GUI_ENABLE)
	EndIf

	GUICtrlSetState($txtLog, $GUI_ENABLE)
EndFunc   ;==>_SetUiEnabled

Func _ClearLog()
	GUICtrlSetData($txtLog, "")
EndFunc   ;==>_ClearLog

Func _OpenHelp()


;~ Global $sSplshHelpFile =  ; Splash File
;~ Global $sHelpFile =  ; Help File

	FileInstall("splash.jpg", @ScriptDir & "\splash.jpg", 1)
	FileInstall("Help.html", @ScriptDir & "\Help.html", 1)






;~     Local $sHelpFile = @TempDir & "\Help.html"

	If Not FileExists(@ScriptDir & "\Help.html") Then
		MsgBox(262144 + 48, "Help not found", "The Help file was not found." & @CRLF & @CRLF & "Please make sure Help.html exists in the Windows temporary folder and try again.", 0, $hGUI)
		_Status("Status: Help file not found.")
		Return
	EndIf

	ShellExecute(@ScriptDir & "\Help.html")
	If @error Then
		MsgBox(262144 + 16, "Help error", "The Help file was found, but Windows could not open it.", 0, $hGUI)
		_Status("Status: Could not open Help file.")
	Else
		_Status("Status: Help opened.")
	EndIf
EndFunc   ;==>_OpenHelp

Func _RequestAbort()
	$g_bAbort = True
	_Log("ABORT requested by user. Stopping as soon as possible...")
	_Status("Status: Abort requested...")
EndFunc   ;==>_RequestAbort

Func _ProcessGuiDuringRun()
	Local $msg = GUIGetMsg()
	If $msg = $btnAbort Then
		_RequestAbort()
	ElseIf $msg = $GUI_EVENT_CLOSE Then
		_RequestAbort()
	EndIf
EndFunc   ;==>_ProcessGuiDuringRun

; -----------------------------
; Settings
; -----------------------------
Func _LoadSettings()
	GUICtrlSetData($inpGdb, IniRead($g_sIniPath, "Firebird", "GdbPath", ""))
	GUICtrlSetData($inpFbServer, IniRead($g_sIniPath, "Firebird", "Server", "localhost"))
	GUICtrlSetData($inpFbPort, IniRead($g_sIniPath, "Firebird", "Port", "3050"))
	GUICtrlSetData($inpFbUser, IniRead($g_sIniPath, "Firebird", "User", "SYSDBA"))
	GUICtrlSetData($inpFbPass, IniRead($g_sIniPath, "Firebird", "Password", "masterkey"))

	GUICtrlSetData($inpSqlServer, IniRead($g_sIniPath, "SQLServer", "Server", ""))
	GUICtrlSetData($inpSqlDb, IniRead($g_sIniPath, "SQLServer", "Database", ""))
	GUICtrlSetData($inpSchema, IniRead($g_sIniPath, "SQLServer", "Schema", "dbo"))
	GUICtrlSetData($cmbAuth, IniRead($g_sIniPath, "SQLServer", "Authentication", "Windows Authentication"))
	GUICtrlSetData($inpSqlUser, IniRead($g_sIniPath, "SQLServer", "User", ""))
	GUICtrlSetData($inpSqlPass, IniRead($g_sIniPath, "SQLServer", "Password", ""))

	If IniRead($g_sIniPath, "Options", "ClearBeforeLoad", "0") = "1" Then GUICtrlSetState($chkClearBeforeLoad, $GUI_CHECKED)
	If IniRead($g_sIniPath, "Options", "SkipDuplicatePK", "1") = "1" Then GUICtrlSetState($chkSkipDuplicatePK, $GUI_CHECKED)
	If IniRead($g_sIniPath, "Options", "OrderByFK", "1") = "1" Then GUICtrlSetState($chkOrderByFK, $GUI_CHECKED)
	If IniRead($g_sIniPath, "Options", "EmptyStringAsNull", "1") = "1" Then GUICtrlSetState($chkEmptyStringAsNull, $GUI_CHECKED)
	If IniRead($g_sIniPath, "Options", "FallbackNotNull", "0") = "1" Then GUICtrlSetState($chkFallbackNotNull, $GUI_CHECKED)
	If IniRead($g_sIniPath, "Options", "DisableTriggers", "0") = "1" Then GUICtrlSetState($chkDisableTriggers, $GUI_CHECKED)
	If IniRead($g_sIniPath, "Options", "VerboseMode", "0") = "1" Then
		GUICtrlSetState($chkVerboseMode, $GUI_CHECKED)
		$g_bVerboseMode = True
	Else
		GUICtrlSetState($chkVerboseMode, $GUI_UNCHECKED)
		$g_bVerboseMode = False
	EndIf
	$g_bOrtemsStartupSanitizer = (IniRead($g_sIniPath, "Options", "OrtemsStartupSanitizer", "1") = "1")

	GUICtrlSetData($inpBatch, IniRead($g_sIniPath, "Options", "BatchSize", "500"))
	$g_iMaxErrors = Int(IniRead($g_sIniPath, "Options", "MaxErrors", "50"))
	If $g_iMaxErrors < 1 Then $g_iMaxErrors = 50

	_OnSqlAuthChange()
	_BuildSqlConnStr()
	_UpdateCounters()
EndFunc   ;==>_LoadSettings

Func _SaveSettings()
	IniWrite($g_sIniPath, "Firebird", "GdbPath", GUICtrlRead($inpGdb))
	IniWrite($g_sIniPath, "Firebird", "Server", GUICtrlRead($inpFbServer))
	IniWrite($g_sIniPath, "Firebird", "Port", GUICtrlRead($inpFbPort))
	IniWrite($g_sIniPath, "Firebird", "User", GUICtrlRead($inpFbUser))
	IniWrite($g_sIniPath, "Firebird", "Password", GUICtrlRead($inpFbPass))

	IniWrite($g_sIniPath, "SQLServer", "Server", GUICtrlRead($inpSqlServer))
	IniWrite($g_sIniPath, "SQLServer", "Database", GUICtrlRead($inpSqlDb))
	IniWrite($g_sIniPath, "SQLServer", "Schema", GUICtrlRead($inpSchema))
	IniWrite($g_sIniPath, "SQLServer", "Authentication", GUICtrlRead($cmbAuth))
	IniWrite($g_sIniPath, "SQLServer", "User", GUICtrlRead($inpSqlUser))
	IniWrite($g_sIniPath, "SQLServer", "Password", GUICtrlRead($inpSqlPass))

	IniWrite($g_sIniPath, "Options", "ClearBeforeLoad", _IIf(GUICtrlRead($chkClearBeforeLoad) = $GUI_CHECKED, "1", "0"))
	IniWrite($g_sIniPath, "Options", "SkipDuplicatePK", _IIf(GUICtrlRead($chkSkipDuplicatePK) = $GUI_CHECKED, "1", "0"))
	IniWrite($g_sIniPath, "Options", "OrderByFK", _IIf(GUICtrlRead($chkOrderByFK) = $GUI_CHECKED, "1", "0"))
	IniWrite($g_sIniPath, "Options", "EmptyStringAsNull", _IIf(GUICtrlRead($chkEmptyStringAsNull) = $GUI_CHECKED, "1", "0"))
	IniWrite($g_sIniPath, "Options", "FallbackNotNull", _IIf(GUICtrlRead($chkFallbackNotNull) = $GUI_CHECKED, "1", "0"))
	IniWrite($g_sIniPath, "Options", "DisableTriggers", _IIf(GUICtrlRead($chkDisableTriggers) = $GUI_CHECKED, "1", "0"))
	$g_bVerboseMode = (GUICtrlRead($chkVerboseMode) = $GUI_CHECKED)
	IniWrite($g_sIniPath, "Options", "VerboseMode", _IIf($g_bVerboseMode, "1", "0"))
	IniWrite($g_sIniPath, "Options", "OrtemsStartupSanitizer", _IIf($g_bOrtemsStartupSanitizer, "1", "0"))
	IniWrite($g_sIniPath, "Options", "BatchSize", GUICtrlRead($inpBatch))
	IniWrite($g_sIniPath, "Options", "MaxErrors", $g_iMaxErrors)
EndFunc   ;==>_SaveSettings

Func _IIf($bCond, $vTrue, $vFalse)
	If $bCond Then Return $vTrue
	Return $vFalse
EndFunc   ;==>_IIf

; -----------------------------
; Status + logging
; -----------------------------
Func _UpdateCounters()
	GUICtrlSetData($lblErrCount, "Errors: " & $g_iErrorCount & " / " & $g_iMaxErrors & " | Warnings: " & $g_iWarningCount)
EndFunc   ;==>_UpdateCounters

Func _Status($s)
	GUICtrlSetData($lblStatus, $s)
EndFunc   ;==>_Status

Func _ProgressReset($sText = "Progress: 0%")
	$g_iProgressLastPercent = -1
	$g_iProgressLastUpdateTick = TimerInit()
	GUICtrlSetData($prgImport, 0)
	GUICtrlSetData($lblProgress, $sText)
EndFunc   ;==>_ProgressReset

Func _ProgressSet($iPercent, $sText = "")
	If $iPercent < 0 Then $iPercent = 0
	If $iPercent > 100 Then $iPercent = 100

	If $iPercent <> $g_iProgressLastPercent Then
		GUICtrlSetData($prgImport, $iPercent)
		$g_iProgressLastPercent = $iPercent
	EndIf

	If $sText <> "" Then GUICtrlSetData($lblProgress, $sText)
	$g_iProgressLastUpdateTick = TimerInit()
EndFunc   ;==>_ProgressSet

Func _ProgressTableStart($iTableIndex, $iTotalTables, $sTable, $iTotalRows)
	If $iTotalTables < 1 Then Return

	Local $iPercent = Int(($iTableIndex * 100) / $iTotalTables)
	Local $sRows = "unknown rows"
	If $iTotalRows >= 0 Then $sRows = $iTotalRows & " rows"

	_ProgressSet($iPercent, "Progress: " & $iPercent & "% | " & $sTable & " (" & ($iTableIndex + 1) & "/" & $iTotalTables & ", " & $sRows & ")")
EndFunc   ;==>_ProgressTableStart

Func _ProgressTableRows($sTable, $iRowsRead, $iInserted, $iSkipped, $iTableIndex, $iTotalTables, $iTotalRows)
	If $iTableIndex < 0 Or $iTotalTables < 1 Then Return

	Local $iPercent = Int(($iTableIndex * 100) / $iTotalTables)
	If $iTotalRows > 0 Then
		$iPercent = Int((($iTableIndex + ($iRowsRead / $iTotalRows)) * 100) / $iTotalTables)
		Local $iTableDonePercent = Int((($iTableIndex + 1) * 100) / $iTotalTables)
		If $iPercent > $iTableDonePercent Then $iPercent = $iTableDonePercent
	EndIf

	Local $sRows = String($iRowsRead)
	If $iTotalRows > 0 Then $sRows &= "/" & $iTotalRows

	_ProgressSet($iPercent, "Progress: " & $iPercent & "% | " & $sTable & " | Rows read: " & $sRows & " | Inserted: " & $iInserted & " | Skipped: " & $iSkipped)
EndFunc   ;==>_ProgressTableRows

Func _ProgressTableDone($iTableIndex, $iTotalTables, $sTable)
	If $iTotalTables < 1 Then Return

	Local $iPercent = Int((($iTableIndex + 1) * 100) / $iTotalTables)
	_ProgressSet($iPercent, "Progress: " & $iPercent & "% | Completed " & $sTable & " (" & ($iTableIndex + 1) & "/" & $iTotalTables & ")")
EndFunc   ;==>_ProgressTableDone

Func _ShowImportResult($sTitle, $sMessage, $iIcon)
	MsgBox($iIcon, $sTitle, $sMessage, 0, $hGUI)
EndFunc   ;==>_ShowImportResult

Func _NowStamp()
	Return @YEAR & "-" & StringRight("0" & @MON, 2) & "-" & StringRight("0" & @MDAY, 2) & " " & _
			StringRight("0" & @HOUR, 2) & ":" & StringRight("0" & @MIN, 2) & ":" & StringRight("0" & @SEC, 2)
EndFunc   ;==>_NowStamp

Func _FileStamp()
	Return @YEAR & @MON & @MDAY & "_" & @HOUR & @MIN & @SEC
EndFunc   ;==>_FileStamp

Func _StartRunLog()
	Local $sLogDir = @ScriptDir & "\log"
	If Not FileExists($sLogDir) Then DirCreate($sLogDir)
	$g_sLogFile = $sLogDir & "\import_" & _FileStamp() & ".log"
	GUICtrlSetData($lblLogFile, $g_sLogFile)
EndFunc   ;==>_StartRunLog

Func _StartExportLog()
	Local $sLogDir = @ScriptDir & "\log"
	If Not FileExists($sLogDir) Then DirCreate($sLogDir)
	$g_sLogFile = $sLogDir & "\export_" & _FileStamp() & ".log"
	GUICtrlSetData($lblLogFile, $g_sLogFile)
EndFunc   ;==>_StartExportLog

Func _Log($s)
	Local $line = _NowStamp() & "  " & $s & @CRLF
	GUICtrlSetData($txtLog, GUICtrlRead($txtLog) & $line)
	_GUICtrlEdit_SetSel($txtLog, -1, -1)
	_GUICtrlEdit_Scroll($txtLog, $SB_SCROLLCARET)
	If $g_sLogFile <> "" Then FileWrite($g_sLogFile, $line)
EndFunc   ;==>_Log

Func _IsVerboseMode()
	Return $g_bVerboseMode
EndFunc   ;==>_IsVerboseMode

Func _Verbose($s)
	If Not _IsVerboseMode() Then Return
	Local $line = _NowStamp() & "  VERBOSE: " & $s & @CRLF
	; Keep high-volume debug output in the file log only. Updating the GUI edit control
	; for every SQL/row can make large imports unusably slow.
	If $g_sLogFile <> "" Then
		FileWrite($g_sLogFile, $line)
	Else
		_Log("VERBOSE: " & $s)
	EndIf
EndFunc   ;==>_Verbose

Func _VerboseBlock($sTitle, $sBody)
	If Not _IsVerboseMode() Then Return
	Local $sText = _Shorten(String($sBody), $g_iVerboseSqlMaxChars)
	If $g_sLogFile <> "" Then
		FileWrite($g_sLogFile, _NowStamp() & "  VERBOSE: " & $sTitle & @CRLF & $sText & @CRLF)
		If StringLen(String($sBody)) > $g_iVerboseSqlMaxChars Then FileWrite($g_sLogFile, _NowStamp() & "  VERBOSE: " & $sTitle & " was truncated at " & $g_iVerboseSqlMaxChars & " characters." & @CRLF)
	Else
		_Log("VERBOSE: " & $sTitle & " | " & _Shorten($sText, 1000))
	EndIf
EndFunc   ;==>_VerboseBlock

Func _VerboseSql($sContext, $sSql)
	_VerboseBlock("SQL COMMAND [" & $sContext & "]", $sSql)
EndFunc   ;==>_VerboseSql

Func _VerboseAdoResult($sContext, $sStatus, $iDurationMs, $sNativeErrors = "", $sExtra = "")
	If Not _IsVerboseMode() Then Return
	Local $sMsg = "ADO RETURN [" & $sContext & "] Status=" & $sStatus & " | DurationMs=" & $iDurationMs
	If $sNativeErrors <> "" Then $sMsg &= " | NativeErrors=" & $sNativeErrors
	If $sExtra <> "" Then $sMsg &= " | " & $sExtra
	_Verbose($sMsg)
EndFunc   ;==>_VerboseAdoResult

Func _VerboseRecordsetInfo($sContext, $rs)
	If Not _IsVerboseMode() Then Return
	If Not IsObj($rs) Then
		_Verbose("RECORDSET [" & $sContext & "]: no recordset object returned")
		Return
	EndIf

	Local $sInfo = "RECORDSET [" & $sContext & "]: object returned"
	Local $iFields = -1
	$iFields = $rs.Fields.Count
	If Not @error Then $sInfo &= " | Fields=" & $iFields
	Local $bEof = $rs.EOF
	If Not @error Then $sInfo &= " | EOF=" & $bEof
	_Verbose($sInfo)
EndFunc   ;==>_VerboseRecordsetInfo

Func _MaskSensitiveConnectionText($sText)
	Local $sMasked = String($sText)
	$sMasked = StringRegExpReplace($sMasked, "(?i)(Pwd|Password)=([^;]*)", "$1=***")
	$sMasked = StringRegExpReplace($sMasked, "(?i)(UID|User ID)=([^;]*)", "$1=***")
	Return $sMasked
EndFunc   ;==>_MaskSensitiveConnectionText

Func _Warn($s)
	$g_iWarningCount += 1
	_UpdateCounters()
	_Log("WARNING: " & $s)
EndFunc   ;==>_Warn

Func _ForceOrtemsSafeRuntimeOptions()
	If Not $g_bOrtemsStartupSanitizer Then Return

	; Full Ortems database moves must copy the source rows as-is. SQL Server/Ortems
	; business triggers can create side effects during a bulk reload, such as duplicate
	; helper rows that make parent tables like B_GAMM fail to load. Keep FK/CHECK
	; constraints active, but disable table triggers during the load and re-enable them
	; at the end. The clear step has its own temporary constraint/trigger handling.
	If GUICtrlRead($chkDisableTriggers) <> $GUI_CHECKED Then
		GUICtrlSetState($chkDisableTriggers, $GUI_CHECKED)
		_Warn("Ortems-safe mode: target table triggers will be disabled during the bulk load to avoid trigger side effects; SQL Server FK/CHECK constraints remain active.")
	EndIf

	; The SQL Server schema contains mandatory date/numeric/text fields that Firebird can
	; expose as NULL/blank. Without deterministic fallbacks, SQL Server rejects the row and
	; the import loses entire Ortems records. Keep the fallback enabled, but still quarantine
	; the known startup-invalid Ortems rows separately.
	If GUICtrlRead($chkFallbackNotNull) <> $GUI_CHECKED Then
		GUICtrlSetState($chkFallbackNotNull, $GUI_CHECKED)
		_Warn("Ortems-safe mode: safe fallback/default for NOT NULL target columns was turned ON to satisfy SQL Server/Ortems table constraints.")
	EndIf
EndFunc   ;==>_ForceOrtemsSafeRuntimeOptions

Func _ComErrHandler($oError)
	Local $msg = "COM ERROR: " & $oError.windescription & _
			" | Number: " & Hex($oError.number) & _
			" | Source: " & $oError.source & _
			" | ScriptLine: " & $oError.scriptline

	If $g_bInSqlExec Then
		$g_bComError = True
		$g_sLastComError = $msg
		Return
	EndIf

	$g_iErrorCount += 1
	_UpdateCounters()
	_Log($msg)
	If $g_sCurrentSql <> "" Then _Log("Last SQL: " & _Shorten($g_sCurrentSql, 1000))
	If IsObj($g_oSqlConn) Then _DumpAdoErrors($g_oSqlConn)

	If $g_iErrorCount >= $g_iMaxErrors Then
		$g_bAbort = True
		_Log("MaxErrors reached (" & $g_iMaxErrors & "). Auto-aborting...")
		_Status("Status: Auto-abort due to too many errors.")
	EndIf
EndFunc   ;==>_ComErrHandler

Func _GetAdoNativeErrors($oConn)
	If Not IsObj($oConn) Then Return ""
	If Not IsObj($oConn.Errors) Then Return ""
	If $oConn.Errors.Count = 0 Then Return ""

	Local $sNativeList = ""
	For $i = 0 To $oConn.Errors.Count - 1
		Local $e = $oConn.Errors.Item($i)
		If IsObj($e) Then
			Local $native = ""
			Local $tmp = $e.NativeError
			If Not @error Then $native = $tmp
			If $native <> "" Then $sNativeList &= $native & "|"
		EndIf
	Next
	Return $sNativeList
EndFunc   ;==>_GetAdoNativeErrors

Func _ClearAdoErrors($oConn)
	If IsObj($oConn) And IsObj($oConn.Errors) Then $oConn.Errors.Clear()
EndFunc   ;==>_ClearAdoErrors

Func _DumpAdoErrors($oConn)
	If Not IsObj($oConn) Then Return ""
	If Not IsObj($oConn.Errors) Then Return ""
	If $oConn.Errors.Count = 0 Then Return ""

	Local $sNativeList = ""
	$g_sLastAdoErrorText = ""
	For $i = 0 To $oConn.Errors.Count - 1
		Local $e = $oConn.Errors.Item($i)
		If IsObj($e) Then
			Local $sqlState = ""
			Local $native = ""
			Local $tmp = ""

			$tmp = $e.SQLState
			If Not @error Then $sqlState = $tmp
			$tmp = $e.NativeError
			If Not @error Then $native = $tmp
			If $native <> "" Then $sNativeList &= $native & "|"

			$g_sLastAdoErrorText &= String($e.Description) & @CRLF
			_Log("ADO Error: " & $e.Number & " | " & $e.Description & " | SQLState: " & $sqlState & " | NativeError: " & $native)
		EndIf
	Next

	$oConn.Errors.Clear()
	Return $sNativeList
EndFunc   ;==>_DumpAdoErrors

Func _Shorten($sText, $iMax)
	If StringLen($sText) <= $iMax Then Return $sText
	Return StringLeft($sText, $iMax) & " ...[truncated]"
EndFunc   ;==>_Shorten

Func _IsNull($v)
	Return (VarGetType($v) = "Null")
EndFunc   ;==>_IsNull

; -----------------------------
; Connection helpers
; -----------------------------
Func _OnSqlAuthChange()
	Local $sAuth = GUICtrlRead($cmbAuth)
	If $sAuth = "SQL Server Authentication" Then
		GUICtrlSetState($inpSqlUser, $GUI_ENABLE)
		GUICtrlSetState($inpSqlPass, $GUI_ENABLE)
	Else
		GUICtrlSetState($inpSqlUser, $GUI_DISABLE)
		GUICtrlSetState($inpSqlPass, $GUI_DISABLE)
	EndIf
EndFunc   ;==>_OnSqlAuthChange

Func _BuildSqlConnStr()
	Local $sServer = GUICtrlRead($inpSqlServer)
	Local $sDb = GUICtrlRead($inpSqlDb)
	Local $sAuth = GUICtrlRead($cmbAuth)
	Local $sConn = ""
	If $sServer <> "" And $sDb <> "" Then
		If $sAuth = "Windows Authentication" Then
			$sConn = "Driver={SQL Server};Server=" & $sServer & ";Database=" & $sDb & ";Trusted_Connection=yes;"
		Else
			$sConn = "Driver={SQL Server};Server=" & $sServer & ";Database=" & $sDb & ";UID=" & GUICtrlRead($inpSqlUser) & ";PWD=" & GUICtrlRead($inpSqlPass) & ";"
		EndIf
	EndIf
	GUICtrlSetData($inpConnStr, $sConn)
	Return $sConn
EndFunc   ;==>_BuildSqlConnStr

Func _OpenFirebird()
	If IsObj($g_oFbConn) Then Return True

	Local $sGdb = GUICtrlRead($inpGdb)
	Local $sServer = GUICtrlRead($inpFbServer)
	Local $sPort = GUICtrlRead($inpFbPort)
	Local $sUser = GUICtrlRead($inpFbUser)
	Local $sPass = GUICtrlRead($inpFbPass)

	If $sGdb = "" Or Not FileExists($sGdb) Then
		_Log("ERROR: Invalid GDB file path.")
		Return False
	EndIf
	If $sServer = "" Then $sServer = "localhost"
	If $sPort = "" Then $sPort = "3050"

	Local $sConn = "Driver={Firebird/InterBase(r) driver};" & _
			"Dbname=" & $sServer & "/" & $sPort & ":" & $sGdb & ";" & _
			"Uid=" & $sUser & ";Pwd=" & $sPass & ";"

	$g_oFbConn = ObjCreate("ADODB.Connection")
	$g_oFbConn.ConnectionTimeout = 15
	$g_oFbConn.CommandTimeout = 0
	_Verbose("Opening Firebird connection: " & _MaskSensitiveConnectionText($sConn))
	$g_oFbConn.Open($sConn)

	If @error Or Not IsObj($g_oFbConn) Then
		_Log("ERROR: Firebird connection failed. Check driver name, server, port, credentials.")
		$g_oFbConn = 0
		Return False
	EndIf
	Return True
EndFunc   ;==>_OpenFirebird

Func _OpenSqlServer()
	If IsObj($g_oSqlConn) Then Return True

	Local $sServer = GUICtrlRead($inpSqlServer)
	Local $sDb = GUICtrlRead($inpSqlDb)
	Local $sAuth = GUICtrlRead($cmbAuth)

	If $sServer = "" Or $sDb = "" Then
		_Log("ERROR: Please fill SQL Server and Database.")
		Return False
	EndIf
	If $sAuth = "SQL Server Authentication" And GUICtrlRead($inpSqlUser) = "" Then
		_Log("ERROR: Please fill SQL User (SQL Server Authentication).")
		Return False
	EndIf

	Local $sConn = _BuildSqlConnStr()
	If $sConn = "" Then
		_Log("ERROR: Could not build SQL Server connection string.")
		Return False
	EndIf

	$g_oSqlConn = ObjCreate("ADODB.Connection")
	$g_oSqlConn.ConnectionTimeout = 15
	$g_oSqlConn.CommandTimeout = 0
	_Verbose("Opening SQL Server connection: " & _MaskSensitiveConnectionText($sConn))
	$g_oSqlConn.Open($sConn)

	If @error Or Not IsObj($g_oSqlConn) Then
		_Log("ERROR: SQL Server connection failed. Check ODBC driver, server, DB, and authentication.")
		$g_oSqlConn = 0
		Return False
	EndIf
	Return True
EndFunc   ;==>_OpenSqlServer

; -----------------------------
; Metadata
; -----------------------------
Func _LoadTableList()
	_GUICtrlListView_DeleteAllItems($lvTables)

	Local $aTables = _ListFirebirdTables()
	If @error Or UBound($aTables) = 0 Then
		_Log("No user tables found (or query failed).")
		Return
	EndIf

	For $i = 0 To UBound($aTables) - 1
		Local $idx = _GUICtrlListView_AddItem($lvTables, "", $i)
		_GUICtrlListView_AddSubItem($lvTables, $idx, $aTables[$i], 1)
		_GUICtrlListView_SetItemChecked($lvTables, $idx, False)
	Next

	_Log("Loaded " & UBound($aTables) & " tables from Firebird.")
EndFunc   ;==>_LoadTableList

Func _ListFirebirdTables()
	Local $sSql = "SELECT TRIM(rdb$relation_name) AS table_name " & _
			"FROM rdb$relations " & _
			"WHERE rdb$system_flag = 0 AND rdb$view_blr IS NULL " & _
			"ORDER BY 1"
	Local $rs = _FbQuery($sSql, "metadata/list")
	If @error Or Not IsObj($rs) Then Return SetError(1, 0, 0)

	Local $a[0]
	While Not $rs.EOF
		ReDim $a[UBound($a) + 1]
		$a[UBound($a) - 1] = $rs.Fields("table_name").Value
		$rs.MoveNext()
	WEnd
	Return $a
EndFunc   ;==>_ListFirebirdTables

Func _GetFirebirdColumns($sTable)
	Local $sSql = "SELECT " & _
			"TRIM(rf.rdb$field_name) AS field_name, " & _
			"f.rdb$field_type AS field_type, " & _
			"f.rdb$field_sub_type AS sub_type, " & _
			"f.rdb$field_length AS field_length, " & _
			"f.rdb$field_precision AS field_precision, " & _
			"f.rdb$field_scale AS field_scale " & _
			"FROM rdb$relation_fields rf " & _
			"JOIN rdb$fields f ON rf.rdb$field_source = f.rdb$field_name " & _
			"WHERE rf.rdb$relation_name = '" & StringUpper($sTable) & "' " & _
			"ORDER BY rf.rdb$field_position"

	Local $rs = _FbQuery($sSql, "metadata/list")
	If @error Or Not IsObj($rs) Then Return SetError(1, 0, 0)

	Local $aCols[0][3]
	While Not $rs.EOF
		Local $name = $rs.Fields("field_name").Value
		Local $t = $rs.Fields("field_type").Value
		Local $sub = $rs.Fields("sub_type").Value
		Local $len = $rs.Fields("field_length").Value
		Local $prec = $rs.Fields("field_precision").Value
		Local $scale = $rs.Fields("field_scale").Value

		Local $r = UBound($aCols)
		ReDim $aCols[$r + 1][3]
		$aCols[$r][0] = $name
		$aCols[$r][1] = _MapFbTypeToSql($t, $sub, $len, $prec, $scale)
		$aCols[$r][2] = $sub

		$rs.MoveNext()
	WEnd
	Return $aCols
EndFunc   ;==>_GetFirebirdColumns

Func _MapFbTypeToSql($fieldType, $subType, $len, $prec, $scale)
	Switch $fieldType
		Case 7
			Return "smallint"
		Case 8
			Return "int"
		Case 10
			Return "real"
		Case 11, 27
			Return "float"
		Case 12
			Return "date"
		Case 13
			Return "time"
		Case 14
			Return "char"
		Case 37
			Return "varchar"
		Case 35
			Return "datetime2"
		Case 261
			If $subType = 1 Then Return "nvarchar(max)"
			Return "varbinary(max)"
		Case 16
			If ($subType = 1 Or $subType = 2) Then Return "decimal"
			Return "bigint"
		Case Else
			Return "varchar"
	EndSwitch
EndFunc   ;==>_MapFbTypeToSql

Func _TargetTableExists($sSchema, $sTable)
	; The Firebird source may contain temporary/internal tables that are not present
	; in the pre-created SQL Server schema. Treat those as skipped tables, not fatal errors.
	Local $sSql = "SELECT TOP 1 1 AS ExistsFlag " & _
			"FROM sys.tables t " & _
			"JOIN sys.schemas s ON t.schema_id = s.schema_id " & _
			"WHERE s.name = " & _SqlQuote($sSchema) & " AND t.name = " & _SqlQuote($sTable)

	Local $rs = _SqlQuery($sSql)
	If @error Or Not IsObj($rs) Then Return False
	If $rs.EOF Then Return False
	Return True
EndFunc   ;==>_TargetTableExists

Func _TargetColumnExists($sSchema, $sTable, $sColumn)
	Local $sSql = "SELECT TOP 1 1 AS ExistsFlag " & _
			"FROM INFORMATION_SCHEMA.COLUMNS " & _
			"WHERE TABLE_SCHEMA = " & _SqlQuote($sSchema) & _
			" AND TABLE_NAME = " & _SqlQuote($sTable) & _
			" AND COLUMN_NAME = " & _SqlQuote($sColumn)

	Local $rs = _SqlQuery($sSql, False)
	If @error Or Not IsObj($rs) Then Return False
	If $rs.EOF Then Return False
	Return True
EndFunc   ;==>_TargetColumnExists

Func _FindTargetColumn($sSchema, $sTable, ByRef $aCandidates)
	For $i = 0 To UBound($aCandidates) - 1
		If _TargetColumnExists($sSchema, $sTable, $aCandidates[$i]) Then Return $aCandidates[$i]
	Next
	Return ""
EndFunc   ;==>_FindTargetColumn

Func _GetTargetColumnInfo($sSchema, $sTable)
	Local $d = ObjCreate("Scripting.Dictionary")
	Local $sSql = "SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, IS_NULLABLE, COLUMN_DEFAULT " & _
			"FROM INFORMATION_SCHEMA.COLUMNS " & _
			"WHERE TABLE_SCHEMA = " & _SqlQuote($sSchema) & " AND TABLE_NAME = " & _SqlQuote($sTable) & _
			" ORDER BY ORDINAL_POSITION"

	Local $rs = _SqlQuery($sSql)
	If @error Or Not IsObj($rs) Then Return SetError(1, 0, 0)

	While Not $rs.EOF
		Local $sName = String($rs.Fields("COLUMN_NAME").Value)
		Local $sType = _BuildSqlServerTypeFromRs($rs)
		Local $bNullable = (StringUpper(String($rs.Fields("IS_NULLABLE").Value)) = "YES")
		Local $sDefault = ""
		If Not _IsNull($rs.Fields("COLUMN_DEFAULT").Value) Then $sDefault = String($rs.Fields("COLUMN_DEFAULT").Value)

		Local $info = ObjCreate("Scripting.Dictionary")
		$info.Add("name", $sName)
		$info.Add("type", $sType)
		$info.Add("nullable", $bNullable)
		$info.Add("default", $sDefault)
		$info.Add("is_pk", False)
		$info.Add("is_identity", False)

		$d.Add(StringUpper($sName), $info)
		$rs.MoveNext()
	WEnd

	Local $aPk = _GetPrimaryKeyColumns($sSchema, $sTable)
	For $i = 0 To UBound($aPk) - 1
		Local $k = StringUpper($aPk[$i])
		If $d.Exists($k) Then $d.Item($k).Item("is_pk") = True
	Next

	Local $aIdentity = _GetIdentityColumns($sSchema, $sTable)
	For $i = 0 To UBound($aIdentity) - 1
		Local $kId = StringUpper($aIdentity[$i])
		If $d.Exists($kId) Then $d.Item($kId).Item("is_identity") = True
	Next

	Return $d
EndFunc   ;==>_GetTargetColumnInfo

Func _BuildSqlServerTypeFromRs($rs)
	Local $dataType = StringLower(String($rs.Fields("DATA_TYPE").Value))
	Local $charLen = $rs.Fields("CHARACTER_MAXIMUM_LENGTH").Value
	Local $prec = $rs.Fields("NUMERIC_PRECISION").Value
	Local $scale = $rs.Fields("NUMERIC_SCALE").Value

	Switch $dataType
		Case "varchar", "char", "nvarchar", "nchar", "binary", "varbinary"
			If _IsNull($charLen) Then Return $dataType
			If Int($charLen) = -1 Then Return $dataType & "(max)"
			Return $dataType & "(" & Int($charLen) & ")"
		Case "decimal", "numeric"
			If _IsNull($prec) Then Return $dataType
			If _IsNull($scale) Then $scale = 0
			Return $dataType & "(" & Int($prec) & "," & Int($scale) & ")"
		Case "datetime2", "time", "datetimeoffset"
			If Not _IsNull($scale) Then Return $dataType & "(" & Int($scale) & ")"
			Return $dataType
		Case Else
			Return $dataType
	EndSwitch
EndFunc   ;==>_BuildSqlServerTypeFromRs

Func _GetPrimaryKeyColumns($sSchema, $sTable)
	Local $a[0]
	Local $sSql = "SELECT c.name AS column_name " & _
			"FROM sys.key_constraints kc " & _
			"JOIN sys.tables t ON kc.parent_object_id = t.object_id " & _
			"JOIN sys.schemas s ON t.schema_id = s.schema_id " & _
			"JOIN sys.index_columns ic ON kc.parent_object_id = ic.object_id AND kc.unique_index_id = ic.index_id " & _
			"JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id " & _
			"WHERE kc.type = 'PK' AND s.name = " & _SqlQuote($sSchema) & " AND t.name = " & _SqlQuote($sTable) & _
			" ORDER BY ic.key_ordinal"

	Local $rs = _SqlQuery($sSql)
	If @error Or Not IsObj($rs) Then Return $a

	While Not $rs.EOF
		ReDim $a[UBound($a) + 1]
		$a[UBound($a) - 1] = String($rs.Fields("column_name").Value)
		$rs.MoveNext()
	WEnd
	Return $a
EndFunc   ;==>_GetPrimaryKeyColumns

Func _GetIdentityColumns($sSchema, $sTable)
	Local $a[0]
	Local $sSql = "SELECT c.name AS column_name " & _
			"FROM sys.columns c " & _
			"JOIN sys.tables t ON c.object_id = t.object_id " & _
			"JOIN sys.schemas s ON t.schema_id = s.schema_id " & _
			"WHERE c.is_identity = 1 AND s.name = " & _SqlQuote($sSchema) & " AND t.name = " & _SqlQuote($sTable) & _
			" ORDER BY c.column_id"

	Local $rs = _SqlQuery($sSql)
	If @error Or Not IsObj($rs) Then Return $a

	While Not $rs.EOF
		ReDim $a[UBound($a) + 1]
		$a[UBound($a) - 1] = String($rs.Fields("column_name").Value)
		$rs.MoveNext()
	WEnd
	Return $a
EndFunc   ;==>_GetIdentityColumns

Func _GetImportColumns($sTable, ByRef $aFbCols, ByRef $dTarget)
	; [][0]=ColumnName, [][1]=TargetType, [][2]=Nullable, [][3]=Default, [][4]=IsPK, [][5]=IsIdentity, [][6]=ExistsInSource
	Local $a[0][7]
	For $i = 0 To UBound($aFbCols) - 1
		Local $sCol = $aFbCols[$i][0]
		Local $k = StringUpper($sCol)
		If Not $dTarget.Exists($k) Then
			_Warn("Source column not found in target schema. It will be skipped: " & $sTable & "." & $sCol)
			ContinueLoop
		EndIf

		Local $info = $dTarget.Item($k)
		Local $r = UBound($a)
		ReDim $a[$r + 1][7]
		$a[$r][0] = $sCol
		$a[$r][1] = $info.Item("type")
		$a[$r][2] = $info.Item("nullable")
		$a[$r][3] = $info.Item("default")
		$a[$r][4] = $info.Item("is_pk")
		$a[$r][5] = $info.Item("is_identity")
		$a[$r][6] = True
	Next

	_AppendOrtemsMandatoryTargetOnlyColumns($sTable, $a, $dTarget)
	Return $a
EndFunc   ;==>_GetImportColumns


Func _AppendOrtemsMandatoryTargetOnlyColumns($sTable, ByRef $aCols, ByRef $dTarget)
	If Not $g_bOrtemsStartupSanitizer Then Return

	Local $sTableU = _NormalizeTableName($sTable)
	If $sTableU <> "E_OF_VER" And $sTableU <> "E_OF_VER2" Then Return

	Local $aEffectivityCols[2] = ["VER_EFFET_DEBUT", "VER_EFFET_DEBUT2"]
	For $i = 0 To UBound($aEffectivityCols) - 1
		_AppendTargetOnlyColumnIfPresent($aCols, $dTarget, $aEffectivityCols[$i], $sTable)
	Next
EndFunc   ;==>_AppendOrtemsMandatoryTargetOnlyColumns

Func _AppendTargetOnlyColumnIfPresent(ByRef $aCols, ByRef $dTarget, $sCol, $sTable)
	Local $k = StringUpper($sCol)
	If Not $dTarget.Exists($k) Then Return False
	If _ImportColumnExists($aCols, $sCol) Then Return False

	Local $info = $dTarget.Item($k)
	Local $r = UBound($aCols)
	ReDim $aCols[$r + 1][7]
	$aCols[$r][0] = $info.Item("name")
	$aCols[$r][1] = $info.Item("type")
	$aCols[$r][2] = $info.Item("nullable")
	$aCols[$r][3] = $info.Item("default")
	$aCols[$r][4] = $info.Item("is_pk")
	$aCols[$r][5] = $info.Item("is_identity")
	$aCols[$r][6] = False
	_Warn("Ortems semantic import: target-only mandatory column added to INSERT list: " & $sTable & "." & $info.Item("name") & ". The value will be resolved from the WO/version effectivity chain.")
	Return True
EndFunc   ;==>_AppendTargetOnlyColumnIfPresent

Func _ImportColumnExists(ByRef $aCols, $sCol)
	For $i = 0 To UBound($aCols) - 1
		If StringUpper(String($aCols[$i][0])) = StringUpper(String($sCol)) Then Return True
	Next
	Return False
EndFunc   ;==>_ImportColumnExists

Func _ImportColumnHasSource(ByRef $aCols, $iIndex)
	If UBound($aCols, 2) < 7 Then Return True
	Return $aCols[$iIndex][6]
EndFunc   ;==>_ImportColumnHasSource

Func _GetImportColumnValue($rs, ByRef $aCols, $iIndex)
	If Not _ImportColumnHasSource($aCols, $iIndex) Then Return ""
	Return $rs.Fields($aCols[$iIndex][0]).Value
EndFunc   ;==>_GetImportColumnValue

Func _GetImportColumnValueByName($rs, ByRef $aCols, $sCol)
	For $i = 0 To UBound($aCols) - 1
		If StringUpper(String($aCols[$i][0])) = StringUpper(String($sCol)) Then
			If Not _ImportColumnHasSource($aCols, $i) Then Return ""
			Return $rs.Fields($aCols[$i][0]).Value
		EndIf
	Next
	Return ""
EndFunc   ;==>_GetImportColumnValueByName

; -----------------------------
; Ortems relational repair helpers
; -----------------------------
Func _BuildInsertSqlFromValueMap($sSchema, $sTable, ByRef $dTarget, ByRef $dValues)
	Local $sColList = ""
	Local $sValues = ""
	Local $iIncluded = 0

	; Include all non-identity columns. For missing values, rely on the same NOT NULL
	; deterministic fallback logic as the main importer (_NullReplacement).
	For $EachKey In $dTarget.Keys
		Local $info = $dTarget.Item($EachKey)
		If $info.Item("is_identity") Then ContinueLoop

		Local $sCol = $info.Item("name")
		Local $k = StringUpper($sCol)
		Local $v = Null
		If $dValues.Exists($k) Then $v = $dValues.Item($k)

		Local $lit = _SqlLiteralForColumn($v, $info.Item("type"), $info.Item("nullable"), $info.Item("default"))
		If $lit = "DEFAULT" Then ContinueLoop

		If $iIncluded > 0 Then
			$sColList &= ","
			$sValues &= ","
		EndIf
		$sColList &= "[" & $sCol & "]"
		$sValues &= $lit
		$iIncluded += 1
	Next

	If $iIncluded = 0 Then Return "INSERT INTO [" & $sSchema & "].[" & $sTable & "] DEFAULT VALUES"
	Return "INSERT INTO [" & $sSchema & "].[" & $sTable & "] (" & $sColList & ") VALUES (" & $sValues & ")"
EndFunc   ;==>_BuildInsertSqlFromValueMap

Func _EnsureOrtemsParent_B_VER_ART($sSchema, $rs)
	; Fix for FK2_E_OF_VER: E_OF_VER -> B_VER_ART
	Local $dTarget = _GetTargetColumnInfo($sSchema, "B_VER_ART")
	If @error Or Not IsObj($dTarget) Then Return False

	Local $aPk = _GetPrimaryKeyColumns($sSchema, "B_VER_ART")
	If UBound($aPk) = 0 Then Return False

	Local $dVals = ObjCreate("Scripting.Dictionary")
	; Try to populate all PK columns from the current E_OF_VER row (same names in Ortems schemas).
	For $i = 0 To UBound($aPk) - 1
		Local $pk = StringUpper(String($aPk[$i]))
		If Not _RecordsetHasField($rs, $aPk[$i]) Then Return False
		$dVals.Add($pk, $rs.Fields($aPk[$i]).Value)
	Next

	; Check if the parent already exists.
	Local $sWhere = ""
	For $i = 0 To UBound($aPk) - 1
		Local $pkName = String($aPk[$i])
		Local $k = StringUpper($pkName)
		Local $info = $dTarget.Item($k)
		Local $v = $dVals.Item($k)
		Local $lit = _SqlLiteralForColumn($v, $info.Item("type"), $info.Item("nullable"), $info.Item("default"))
		If $sWhere <> "" Then $sWhere &= " AND "
		If $lit = "NULL" Then
			$sWhere &= "[" & $pkName & "] IS NULL"
		Else
			$sWhere &= "[" & $pkName & "] = " & $lit
		EndIf
	Next

	If $sWhere <> "" And _RowExistsByPk($sSchema, "B_VER_ART", $sWhere) Then Return True

	; Insert a minimal parent row using deterministic fallbacks for other mandatory columns.
	Local $sIns = _BuildInsertSqlFromValueMap($sSchema, "B_VER_ART", $dTarget, $dVals)
	_Warn("Ortems relational repair: inserting missing parent row into B_VER_ART to satisfy FK2_E_OF_VER. WHERE=" & $sWhere)
	Local $native = _SqlExec($sIns, False, True, False)
	If @error Or $g_bLastSqlExecFailed Then
		_Log("ERROR: Ortems relational repair failed to insert B_VER_ART parent row. NativeErrors=" & $native)
		Return False
	EndIf
	Return True
EndFunc   ;==>_EnsureOrtemsParent_B_VER_ART

Func _RecordsetHasField($rs, $sField)
	If Not IsObj($rs) Then Return False
	Local $tmp = $rs.Fields($sField).Value
	If @error Then Return False
	Return True
EndFunc   ;==>_RecordsetHasField

Func _FbQuery($sSql, $sContext = "Firebird query", $bCountError = False)
	$g_sCurrentSql = $sSql
	$g_bComError = False
	$g_sLastComError = ""
	$g_sLastAdoErrorText = ""
	If IsObj($g_oFbConn) And IsObj($g_oFbConn.Errors) Then $g_oFbConn.Errors.Clear()

	_VerboseSql("FIREBIRD " & $sContext, $sSql)
	Local $hTimer = TimerInit()

	$g_bInSqlExec = True
	Local $rs = $g_oFbConn.Execute($sSql)
	Local $iAutoItError = @error
	$g_bInSqlExec = False

	Local $iDurationMs = Int(TimerDiff($hTimer))
	If $iAutoItError Or $g_bComError Or (IsObj($g_oFbConn) And IsObj($g_oFbConn.Errors) And $g_oFbConn.Errors.Count > 0) Then
		If $bCountError Then
			$g_iErrorCount += 1
			_UpdateCounters()
		EndIf
		Local $sExtra = "AutoItError=" & $iAutoItError & " | ComError=" & $g_bComError
		If $g_sLastComError <> "" Then $sExtra &= " | " & $g_sLastComError
		_VerboseAdoResult("FIREBIRD " & $sContext, "FAILED", $iDurationMs, "", $sExtra)
		If $g_sLastComError <> "" Then _Log($g_sLastComError)
		If $g_sCurrentSql <> "" Then _Log("Last Firebird SQL: " & _Shorten($g_sCurrentSql, 1000))
		If IsObj($g_oFbConn) Then _DumpAdoErrors($g_oFbConn)
		Return SetError(1, 0, 0)
	EndIf

	_VerboseAdoResult("FIREBIRD " & $sContext, "OK", $iDurationMs)
	_VerboseRecordsetInfo("FIREBIRD " & $sContext, $rs)
	Return SetError(0, 0, $rs)
EndFunc   ;==>_FbQuery

Func _SqlQuery($sSql, $bCountError = True)
	$g_sCurrentSql = $sSql
	$g_bComError = False
	$g_sLastComError = ""
	$g_sLastAdoErrorText = ""
	If IsObj($g_oSqlConn) And IsObj($g_oSqlConn.Errors) Then $g_oSqlConn.Errors.Clear()

	_VerboseSql("SQL SERVER QUERY", $sSql)
	Local $hTimer = TimerInit()

	$g_bInSqlExec = True
	Local $rs = $g_oSqlConn.Execute($sSql)
	Local $iAutoItError = @error
	$g_bInSqlExec = False

	Local $iDurationMs = Int(TimerDiff($hTimer))
	If $iAutoItError Or $g_bComError Or (IsObj($g_oSqlConn) And IsObj($g_oSqlConn.Errors) And $g_oSqlConn.Errors.Count > 0) Then
		If $bCountError Then
			$g_iErrorCount += 1
			_UpdateCounters()
		EndIf
		Local $sExtra = "AutoItError=" & $iAutoItError & " | ComError=" & $g_bComError
		If $g_sLastComError <> "" Then $sExtra &= " | " & $g_sLastComError
		_VerboseAdoResult("SQL SERVER QUERY", "FAILED", $iDurationMs, "", $sExtra)
		If $g_sLastComError <> "" Then _Log($g_sLastComError)
		If $g_sCurrentSql <> "" Then _Log("Last SQL: " & _Shorten($g_sCurrentSql, 1000))
		If IsObj($g_oSqlConn) Then _DumpAdoErrors($g_oSqlConn)

		If $g_iErrorCount >= $g_iMaxErrors Then
			$g_bAbort = True
			_Log("MaxErrors reached (" & $g_iMaxErrors & "). Auto-aborting...")
			_Status("Status: Auto-abort due to too many errors.")
		EndIf

		Return SetError(1, 0, 0)
	EndIf

	_VerboseAdoResult("SQL SERVER QUERY", "OK", $iDurationMs)
	_VerboseRecordsetInfo("SQL SERVER QUERY", $rs)
	Return SetError(0, 0, $rs)
EndFunc   ;==>_SqlQuery

Func _SqlExec($sSql, $bCountError = True, $bLogError = True, $bIgnoreDuplicateAsError = False)
	$g_sCurrentSql = $sSql
	$g_bComError = False
	$g_sLastComError = ""
	$g_sLastAdoErrorText = ""
	$g_bLastSqlExecFailed = False
	If IsObj($g_oSqlConn) And IsObj($g_oSqlConn.Errors) Then $g_oSqlConn.Errors.Clear()

	_VerboseSql("SQL SERVER EXECUTE", $sSql)
	Local $hTimer = TimerInit()

	$g_bInSqlExec = True
	$g_oSqlConn.Execute($sSql)
	Local $iAutoItError = @error
	$g_bInSqlExec = False

	Local $iDurationMs = Int(TimerDiff($hTimer))
	If $iAutoItError Or $g_bComError Or (IsObj($g_oSqlConn) And IsObj($g_oSqlConn.Errors) And $g_oSqlConn.Errors.Count > 0) Then
		Local $native = _GetAdoNativeErrors($g_oSqlConn)
		Local $bDuplicateKey = (StringInStr($native, "2627|") Or StringInStr($native, "2601|"))
		Local $bNonFatalDuplicate = ($bIgnoreDuplicateAsError And $bDuplicateKey)
		Local $sVerboseStatus = "FAILED"
		If $bNonFatalDuplicate Then $sVerboseStatus = "DUPLICATE_NON_FATAL"

		If Not $bNonFatalDuplicate Then
			If $bCountError Then
				$g_iErrorCount += 1
				_UpdateCounters()
			EndIf
			If $bLogError Then
				If $g_sLastComError <> "" Then _Log($g_sLastComError)
				If $g_sCurrentSql <> "" Then _Log("Last SQL: " & _Shorten($g_sCurrentSql, 1000))
				$native = _DumpAdoErrors($g_oSqlConn)
			Else
				_ClearAdoErrors($g_oSqlConn)
			EndIf

			If $g_iErrorCount >= $g_iMaxErrors Then
				$g_bAbort = True
				_Log("MaxErrors reached (" & $g_iMaxErrors & "). Auto-aborting...")
				_Status("Status: Auto-abort due to too many errors.")
			EndIf
		Else
			; Duplicate-key rows intentionally skipped by the importer must not increment
			; the global error counter or trigger MaxErrors auto-abort.
			_ClearAdoErrors($g_oSqlConn)
		EndIf

		Local $sExtra = "AutoItError=" & $iAutoItError & " | ComError=" & $g_bComError & " | CountError=" & $bCountError & " | LogError=" & $bLogError & " | IgnoreDuplicate=" & $bIgnoreDuplicateAsError & " | DuplicateKey=" & $bDuplicateKey
		If $g_sLastComError <> "" Then $sExtra &= " | " & $g_sLastComError
		If $g_sLastAdoErrorText <> "" Then $sExtra &= " | ADOText=" & _Shorten(StringReplace(StringReplace($g_sLastAdoErrorText, @CRLF, " | "), @LF, " | "), 5000)
		_VerboseAdoResult("SQL SERVER EXECUTE", $sVerboseStatus, $iDurationMs, $native, $sExtra)

		$g_bLastSqlExecFailed = True
		Return SetError(1, 0, $native)
	EndIf

	_VerboseAdoResult("SQL SERVER EXECUTE", "OK", $iDurationMs)
	$g_bLastSqlExecFailed = False
	Return SetError(0, 0, "")
EndFunc   ;==>_SqlExec

; -----------------------------
; Table ordering / clearing
; -----------------------------
Func _OrderTablesByForeignKeys(ByRef $aTables, $sSchema, $bForce = False)
	If UBound($aTables) = 0 Then Return $aTables
	If (Not $bForce) And GUICtrlRead($chkOrderByFK) <> $GUI_CHECKED Then Return $aTables

	Local $selected = ObjCreate("Scripting.Dictionary")
	Local $depCount = ObjCreate("Scripting.Dictionary")
	Local $children = ObjCreate("Scripting.Dictionary")
	Local $processed = ObjCreate("Scripting.Dictionary")

	For $i = 0 To UBound($aTables) - 1
		Local $k = StringUpper($aTables[$i])
		If Not $selected.Exists($k) Then $selected.Add($k, $aTables[$i])
		If Not $depCount.Exists($k) Then $depCount.Add($k, 0)
		If Not $children.Exists($k) Then $children.Add($k, "")
	Next

	Local $sSql = "SELECT child.name AS child_table, parent.name AS parent_table " & _
			"FROM sys.foreign_keys fk " & _
			"JOIN sys.tables child ON fk.parent_object_id = child.object_id " & _
			"JOIN sys.schemas child_schema ON child.schema_id = child_schema.schema_id " & _
			"JOIN sys.tables parent ON fk.referenced_object_id = parent.object_id " & _
			"JOIN sys.schemas parent_schema ON parent.schema_id = parent_schema.schema_id " & _
			"WHERE child_schema.name = " & _SqlQuote($sSchema) & " AND parent_schema.name = " & _SqlQuote($sSchema)

	Local $rs = _SqlQuery($sSql)
	If @error Or Not IsObj($rs) Then
		_Warn("Could not read SQL Server foreign keys. Keeping selected table order.")
		Return $aTables
	EndIf

	While Not $rs.EOF
		Local $child = StringUpper(String($rs.Fields("child_table").Value))
		Local $parent = StringUpper(String($rs.Fields("parent_table").Value))

		If $child <> $parent And $selected.Exists($child) And $selected.Exists($parent) Then
			_DictSet($depCount, $child, Int($depCount.Item($child)) + 1)
			_DictSet($children, $parent, String($children.Item($parent)) & $child & "|")
		EndIf

		$rs.MoveNext()
	WEnd

	Local $aOut[0]
	While UBound($aOut) < UBound($aTables)
		Local $bProgress = False

		For $i = 0 To UBound($aTables) - 1
			Local $k2 = StringUpper($aTables[$i])
			If $processed.Exists($k2) Then ContinueLoop
			If Int($depCount.Item($k2)) <> 0 Then ContinueLoop

			_Append1D($aOut, $aTables[$i])
			$processed.Add($k2, True)
			$bProgress = True

			Local $sChildList = String($children.Item($k2))
			If $sChildList <> "" Then
				Local $aChild = StringSplit($sChildList, "|", 2)
				For $c = 0 To UBound($aChild) - 1
					If $aChild[$c] = "" Then ContinueLoop
					If $depCount.Exists($aChild[$c]) Then _DictSet($depCount, $aChild[$c], Int($depCount.Item($aChild[$c])) - 1)
				Next
			EndIf
		Next

		If Not $bProgress Then
			_Warn("Circular or unresolved FK dependency detected. Remaining tables will keep the selected order.")
			For $i = 0 To UBound($aTables) - 1
				Local $k3 = StringUpper($aTables[$i])
				If Not $processed.Exists($k3) Then
					_Append1D($aOut, $aTables[$i])
					$processed.Add($k3, True)
				EndIf
			Next
		EndIf
	WEnd

	_Log("Table order adjusted using SQL Server foreign keys.")
	Return $aOut
EndFunc   ;==>_OrderTablesByForeignKeys

Func _ClearSelectedTables(ByRef $aOrderedTables, $sSchema)
	_Log("Clear before load is ON. Purging selected tables before import.")
	_Log("Clear step: SQL Server constraints and table triggers will be disabled only for the purge, then re-enabled before loading data.")

	Local $bAllOk = True

	If Not _SetConstraintsForTables($aOrderedTables, $sSchema, False) Then $bAllOk = False
	If Not _SetTriggersForTables($aOrderedTables, $sSchema, False, True) Then $bAllOk = False

	For $i = UBound($aOrderedTables) - 1 To 0 Step -1
		_ProcessGuiDuringRun()
		If $g_bAbort Then
			$bAllOk = False
			ExitLoop
		EndIf

		Local $sTable = $aOrderedTables[$i]
		Local $sFull = "[" & $sSchema & "].[" & $sTable & "]"
		If Not _TargetTableExists($sSchema, $sTable) Then
			_Warn("Target table does not exist. Skipping clear: " & $sFull)
			ContinueLoop
		EndIf

		_Status("Status: Clearing " & $sTable & "...")
		_Log("Clearing destination table: " & $sFull)
		Local $sNative = _SqlExec("DELETE FROM " & $sFull & ";")
		If @error Or $g_bLastSqlExecFailed Then
			_Warn("Delete failed for " & $sFull & ". Retrying once after table-level trigger/constraint bypass was requested for the clear step.")
			$sNative = _SqlExec("DELETE FROM " & $sFull & ";")
			If @error Or $g_bLastSqlExecFailed Then
				_Log("ERROR: Failed to clear destination table: " & $sFull)
				$bAllOk = False
			EndIf
		EndIf
	Next

	If Not _SetTriggersForTables($aOrderedTables, $sSchema, True, True) Then $bAllOk = False
	If Not _SetConstraintsForTables($aOrderedTables, $sSchema, True) Then $bAllOk = False

	Return $bAllOk
EndFunc   ;==>_ClearSelectedTables

Func _DictSet(ByRef $d, $key, $value)
	If $d.Exists($key) Then
		$d.Remove($key)
	EndIf
	$d.Add($key, $value)
EndFunc   ;==>_DictSet

Func _Append1D(ByRef $a, $v)
	ReDim $a[UBound($a) + 1]
	$a[UBound($a) - 1] = $v
EndFunc   ;==>_Append1D

Func _SetTableTriggers($sSchema, $sTable, $bEnable)
	; Some target schemas contain business triggers that reject direct DELETE/INSERT operations.
	; This only disables table-level DML triggers, not FK/CHECK constraints.
	Local $sAction = "DISABLE"
	If $bEnable Then $sAction = "ENABLE"

	If Not _TargetTableExists($sSchema, $sTable) Then
		; Missing target tables are skipped elsewhere. Do not turn that into COM noise here.
		Return SetError(0, 0, True)
	EndIf

	Local $sSql = $sAction & " TRIGGER ALL ON [" & $sSchema & "].[" & $sTable & "];"
	Local $native = _SqlExec($sSql, False)
	If @error Or $g_bLastSqlExecFailed Then
		If $bEnable Then
			_Warn("Could not re-enable triggers on [" & $sSchema & "].[" & $sTable & "]. Please check this table manually in SQL Server.")
		Else
			_Warn("Could not disable triggers on [" & $sSchema & "].[" & $sTable & "]. The table may still fail if a trigger blocks direct operations.")
		EndIf
		Return SetError(1, 0, False)
	EndIf

	Return SetError(0, 0, True)
EndFunc   ;==>_SetTableTriggers

Func _SetTriggersForTables(ByRef $aTables, $sSchema, $bEnable, $bForce = False)
	If Not $bForce And GUICtrlRead($chkDisableTriggers) <> $GUI_CHECKED Then Return True

	Local $sVerb = "Disabling"
	If $bEnable Then $sVerb = "Re-enabling"
	_Log($sVerb & " target table triggers for selected tables.")

	Local $bAllOk = True
	For $i = 0 To UBound($aTables) - 1
		_ProcessGuiDuringRun()
		Local $sTable = $aTables[$i]
		If _SetTableTriggers($sSchema, $sTable, $bEnable) Then
			; Keep the log readable: do not emit one success line per table.
		Else
			$bAllOk = False
		EndIf
	Next

	If $bAllOk Then
		If $bEnable Then
			_Log("Target table triggers re-enabled.")
		Else
			_Log("Target table triggers disabled.")
		EndIf
	EndIf

	Return $bAllOk
EndFunc   ;==>_SetTriggersForTables

Func _SetTableConstraints($sSchema, $sTable, $bEnable)
	; Used for the clear step only. Re-enabling with CHECK CONSTRAINT ALL enforces
	; constraints for new DML without doing a full trust rebuild on partially selected
	; Ortems schemas.
	If Not _TargetTableExists($sSchema, $sTable) Then Return SetError(0, 0, True)

	Local $sAction = "NOCHECK CONSTRAINT ALL"
	If $bEnable Then $sAction = "CHECK CONSTRAINT ALL"

	Local $sSql = "ALTER TABLE [" & $sSchema & "].[" & $sTable & "] " & $sAction & ";"
	Local $native = _SqlExec($sSql, False)
	If @error Or $g_bLastSqlExecFailed Then
		If $bEnable Then
			_Warn("Could not re-enable constraints on [" & $sSchema & "].[" & $sTable & "]. Please check this table manually in SQL Server.")
		Else
			_Warn("Could not disable constraints on [" & $sSchema & "].[" & $sTable & "]. Clear may still be blocked by FK/CHECK constraints.")
		EndIf
		Return SetError(1, 0, False)
	EndIf

	Return SetError(0, 0, True)
EndFunc   ;==>_SetTableConstraints

Func _SetConstraintsForTables(ByRef $aTables, $sSchema, $bEnable)
	Local $sVerb = "Disabling"
	If $bEnable Then $sVerb = "Re-enabling"
	_Log($sVerb & " SQL Server constraints for selected tables.")

	Local $bAllOk = True
	For $i = 0 To UBound($aTables) - 1
		_ProcessGuiDuringRun()
		Local $sTable = $aTables[$i]
		If _SetTableConstraints($sSchema, $sTable, $bEnable) Then
			; Keep the log readable: do not emit one success line per table.
		Else
			$bAllOk = False
		EndIf
	Next

	If $bAllOk Then
		If $bEnable Then
			_Log("SQL Server constraints re-enabled.")
		Else
			_Log("SQL Server constraints disabled for clear step.")
		EndIf
	EndIf

	Return $bAllOk
EndFunc   ;==>_SetConstraintsForTables

; -----------------------------
; Firebird GDB SQL script export
; -----------------------------
Func _RunExportSqlScripts()
	$g_bAbort = False
	$g_iErrorCount = 0
	$g_iWarningCount = 0
	$g_iSkippedRows = 0
	$g_iSkippedTables = 0
	_UpdateCounters()
	_ProgressReset("Progress: 0% | Ready to export")

	_SetUiEnabled(False)
	_Status("Status: Starting GDB SQL export...")
	_ProgressSet(0, "Progress: 0% | Preparing export...")
	_SaveSettings()
	_StartExportLog()
	_Log("Verbose mode: " & _IIf($g_bVerboseMode, "ON - detailed debug data will be written to this log file only.", "OFF"))

	Local $sGdb = GUICtrlRead($inpGdb)
	If $sGdb = "" Or Not FileExists($sGdb) Then
		_Log("ERROR: Please select a valid .gdb file before exporting.")
		_Status("Status: Missing source file.")
		_ProgressSet(0, "Progress: 0% | Export failed before start")
		_SetUiEnabled(True)
		_ShowImportResult("Export failed", "Export could not start because the selected Firebird .gdb file is missing or invalid." & @CRLF & @CRLF & "Log file:" & @CRLF & $g_sLogFile, 262144 + 16)
		Return
	EndIf

	If Not _OpenFirebird() Then
		_Log("ERROR: Firebird connection failed. Export stopped.")
		_Status("Status: Firebird connection failed.")
		_ProgressSet(0, "Progress: 0% | Export failed before start")
		_SetUiEnabled(True)
		_ShowImportResult("Export failed", "Export could not start because the Firebird connection failed." & @CRLF & @CRLF & "Log file:" & @CRLF & $g_sLogFile, 262144 + 16)
		Return
	EndIf

	Local $sSchema = GUICtrlRead($inpSchema)
	If $sSchema = "" Then $sSchema = "dbo"

	Local $aTables = _GetCheckedTables()
	If UBound($aTables) = 0 Then
		$aTables = _ListFirebirdTables()
		If @error Or UBound($aTables) = 0 Then
			_Log("ERROR: No Firebird user tables found for export.")
			_Status("Status: No source tables found.")
			_ProgressSet(0, "Progress: 0% | Export failed")
			_SetUiEnabled(True)
			_ShowImportResult("Export failed", "No Firebird user tables were found in the selected GDB file." & @CRLF & @CRLF & "Log file:" & @CRLF & $g_sLogFile, 262144 + 16)
			Return
		EndIf
		_Warn("No tables were checked in the list. Exporting all Firebird user tables instead.")
	EndIf

	Local $sBaseExportDir = @ScriptDir & "\Export"
	If Not FileExists($sBaseExportDir) Then DirCreate($sBaseExportDir)
	Global $sGdb_Name_Splited = StringSplit($sGdb, "\")
	Global $sGdb_Name = $sGdb_Name_Splited[$sGdb_Name_Splited[0]]
	$sGdb_Name = StringReplace($sGdb_Name, ".gdb", "")
	Local $sExportDir = $sBaseExportDir & "\" & $sGdb_Name & "_" & _FileStamp()
	If Not DirCreate($sExportDir) Then
		_Log("ERROR: Could not create export folder: " & $sExportDir)
		_Status("Status: Could not create export folder.")
		_ProgressSet(0, "Progress: 0% | Export failed")
		_SetUiEnabled(True)
		_ShowImportResult("Export failed", "The export folder could not be created:" & @CRLF & $sExportDir & @CRLF & @CRLF & "Log file:" & @CRLF & $g_sLogFile, 262144 + 16)
		Return
	EndIf

	Local $sMasterPath = $sExportDir & "\00_RUN_ALL.sql"
	Local $hMaster = FileOpen($sMasterPath, 2 + 8 + 128)
	If $hMaster = -1 Then
		_Log("ERROR: Could not create master export script: " & $sMasterPath)
		_Status("Status: Could not create master SQL script.")
		_ProgressSet(0, "Progress: 0% | Export failed")
		_SetUiEnabled(True)
		_ShowImportResult("Export failed", "The master SQL file could not be created:" & @CRLF & $sMasterPath & @CRLF & @CRLF & "Log file:" & @CRLF & $g_sLogFile, 262144 + 16)
		Return
	EndIf

	FileWriteLine($hMaster, "-- Firebird GDB SQL export master script")
	FileWriteLine($hMaster, "-- Generated at: " & _NowStamp())
	FileWriteLine($hMaster, "-- Source GDB: " & $sGdb)
	FileWriteLine($hMaster, "-- Target dialect: SQL Server T-SQL")
	FileWriteLine($hMaster, "-- Run this file with SQLCMD mode enabled, or execute each table .sql file individually.")
	FileWriteLine($hMaster, "")

	_Log("=== GDB SQL export started ===")
	_Log("Source GDB: " & $sGdb)
	_Log("Export folder: " & $sExportDir)
	_Log("Generated SQL dialect: SQL Server T-SQL")
	_Log("Tables selected/exported: " & UBound($aTables))

	Local $iOk = 0, $iFail = 0, $iTotalRows = 0
	For $i = 0 To UBound($aTables) - 1
		_ProcessGuiDuringRun()
		If $g_bAbort Then ExitLoop

		Local $sTable = $aTables[$i]
		Local $sFileName = StringFormat("%03d_%s.sql", $i + 1, _SafeFileName($sTable))
		Local $sTablePath = $sExportDir & "\" & $sFileName

		_Status("Status: Exporting " & $sTable & " (" & ($i + 1) & "/" & UBound($aTables) & ")...")
		_ProgressSet(Int(($i / UBound($aTables)) * 100), "Progress: " & Int(($i / UBound($aTables)) * 100) & "% | Exporting " & $sTable)

		Local $iRowsExported = _ExportFirebirdTableToSqlScript($sTable, $sSchema, $sTablePath, $i, UBound($aTables))
		If @error Then
			$iFail += 1
			$g_iSkippedTables += 1
		Else
			$iOk += 1
			$iTotalRows += $iRowsExported
			FileWriteLine($hMaster, ":r .\" & $sFileName)
		EndIf
	Next

	FileClose($hMaster)

	Local $sFinalTitle = "Export completed"
	Local $iFinalIcon = 64
	Local $sFinalMessage = ""

	If $g_bAbort Then
		_Log("GDB SQL export ABORTED by user.")
		_Status("Status: Export aborted.")
		_ProgressSet($g_iProgressLastPercent, "Progress: aborted | Review the log file")
		$sFinalTitle = "Export aborted"
		$iFinalIcon = 48
		$sFinalMessage = "The export was aborted before completion." & @CRLF & @CRLF
	Else
		_Log("=== GDB SQL export finished ===")
		_Log("Success tables: " & $iOk & " | Failed tables: " & $iFail & " | Rows exported: " & $iTotalRows & " | Errors: " & $g_iErrorCount & " | Warnings: " & $g_iWarningCount)
		If $iFail = 0 And $g_iErrorCount = 0 Then
			_ProgressSet(100, "Progress: 100% | Export completed successfully")
			_Status("Status: Export completed. Tables=" & $iOk & " Rows=" & $iTotalRows)
			$sFinalMessage = "Export completed successfully." & @CRLF & @CRLF
		Else
			_ProgressSet(100, "Progress: 100% | Export completed with issues")
			_Status("Status: Export completed with issues. Success=" & $iOk & " Failed=" & $iFail)
			$sFinalTitle = "Export completed with issues"
			$iFinalIcon = 48
			$sFinalMessage = "Export completed, but some tables reported issues. Review the log before using the scripts." & @CRLF & @CRLF
		EndIf
	EndIf

	$sFinalMessage &= "Tables exported: " & $iOk & @CRLF & _
			"Tables failed: " & $iFail & @CRLF & _
			"Rows exported: " & $iTotalRows & @CRLF & _
			"Export folder:" & @CRLF & $sExportDir & @CRLF & @CRLF & _
			"Master script:" & @CRLF & $sMasterPath & @CRLF & @CRLF & _
			"Log file:" & @CRLF & $g_sLogFile

	_SetUiEnabled(True)
	_ShowImportResult($sFinalTitle, $sFinalMessage, $iFinalIcon)
EndFunc   ;==>_RunExportSqlScripts

Func _ExportFirebirdTableToSqlScript($sTable, $sSchema, $sPath, $iTableIndex, $iTotalTables)
	Local $aCols = _GetFirebirdColumnsForSqlExport($sTable)
	If @error Or UBound($aCols) = 0 Then
		_Log("ERROR: Unable to read Firebird metadata for export table: " & $sTable)
		Return SetError(1, 0, 0)
	EndIf

	Local $hFile = FileOpen($sPath, 2 + 8 + 128)
	If $hFile = -1 Then
		_Log("ERROR: Could not create table export file: " & $sPath)
		Return SetError(1, 0, 0)
	EndIf

	Local $iEstimatedRows = _GetFirebirdRowCount($sTable)

	FileWriteLine($hFile, "-- Firebird GDB table export")
	FileWriteLine($hFile, "-- Generated at: " & _NowStamp())
	FileWriteLine($hFile, "-- Source table: " & $sTable)
	FileWriteLine($hFile, "-- Target dialect: SQL Server T-SQL")
	FileWriteLine($hFile, "-- Estimated source rows: " & $iEstimatedRows)
	FileWriteLine($hFile, "--")
	FileWriteLine($hFile, "-- Column metadata:")
	For $c = 0 To UBound($aCols) - 1
		FileWriteLine($hFile, "--   " & $aCols[$c][0] & " | Firebird=" & $aCols[$c][2] & " | SQL=" & $aCols[$c][1] & " | Nullable=" & _IIf($aCols[$c][7], "YES", "NO") & " | field_type=" & $aCols[$c][3] & " | sub_type=" & $aCols[$c][4] & " | length=" & $aCols[$c][5] & " | precision=" & $aCols[$c][6] & " | scale=" & $aCols[$c][8])
	Next
	FileWriteLine($hFile, "")
	FileWriteLine($hFile, "SET NOCOUNT ON;")
	FileWriteLine($hFile, "GO")
	FileWriteLine($hFile, "")
	FileWriteLine($hFile, "IF SCHEMA_ID(N'" & StringReplace($sSchema, "'", "''") & "') IS NULL EXEC(N'CREATE SCHEMA " & _SqlIdent($sSchema) & "');")
	FileWriteLine($hFile, "GO")
	FileWriteLine($hFile, "")
	FileWriteLine($hFile, "IF OBJECT_ID(N'" & StringReplace($sSchema & "." & $sTable, "'", "''") & "', N'U') IS NULL")
	FileWriteLine($hFile, "BEGIN")
	FileWriteLine($hFile, "    CREATE TABLE " & _SqlIdent($sSchema) & "." & _SqlIdent($sTable) & " (")

	For $c = 0 To UBound($aCols) - 1
		Local $sComma = ","
		If $c = UBound($aCols) - 1 Then $sComma = ""
		Local $sNullability = " NULL"
		If Not $aCols[$c][7] Then $sNullability = " NOT NULL"
		FileWriteLine($hFile, "        " & _SqlIdent($aCols[$c][0]) & " " & $aCols[$c][1] & $sNullability & $sComma)
	Next

	FileWriteLine($hFile, "    );")
	FileWriteLine($hFile, "END")
	FileWriteLine($hFile, "GO")
	FileWriteLine($hFile, "")
	FileWriteLine($hFile, "PRINT N'Loading table " & StringReplace($sTable, "'", "''") & "';")
	FileWriteLine($hFile, "")

	Local $rs = _FbQuery("SELECT * FROM " & _FbIdent($sTable), "table data " & $sTable)
	If @error Or Not IsObj($rs) Then
		FileWriteLine($hFile, "-- ERROR: Failed to read data from Firebird table during export.")
		FileClose($hFile)
		_Log("ERROR: Failed to read data from Firebird table during export: " & $sTable)
		Return SetError(1, 0, 0)
	EndIf

	Local $sColList = _BuildExportSqlColumnList($aCols)
	Local $iRows = 0
	While Not $rs.EOF
		_ProcessGuiDuringRun()
		If $g_bAbort Then
			FileWriteLine($hFile, "")
			FileWriteLine($hFile, "-- Export aborted by user before this table was completed.")
			FileClose($hFile)
			Return SetError(1, 0, $iRows)
		EndIf

		Local $sValues = ""
		For $c = 0 To UBound($aCols) - 1
			If $c > 0 Then $sValues &= ","
			$sValues &= _SqlExportLiteral($rs.Fields($aCols[$c][0]).Value, $aCols[$c][1])
		Next

		Local $sExportInsert = "INSERT INTO " & _SqlIdent($sSchema) & "." & _SqlIdent($sTable) & " (" & $sColList & ") VALUES (" & $sValues & ");"
		FileWriteLine($hFile, $sExportInsert)
		_VerboseSql("EXPORT SCRIPT ROW " & $sTable & " #" & ($iRows + 1), $sExportInsert)
		$iRows += 1

		If Mod($iRows, 500) = 0 Then
			FileWriteLine($hFile, "GO")
			Local $iBasePercent = Int(($iTableIndex / $iTotalTables) * 100)
			If $iEstimatedRows > 0 Then
				Local $iNextPercent = Int(((($iTableIndex + ($iRows / $iEstimatedRows)) / $iTotalTables) * 100))
				If $iNextPercent < $iBasePercent Then $iNextPercent = $iBasePercent
				If $iNextPercent > 99 Then $iNextPercent = 99
				_ProgressSet($iNextPercent, "Progress: " & $iNextPercent & "% | Exporting " & $sTable & " | Rows: " & $iRows)
			Else
				_ProgressSet($iBasePercent, "Progress: " & $iBasePercent & "% | Exporting " & $sTable & " | Rows: " & $iRows)
			EndIf
		EndIf

		$rs.MoveNext()
	WEnd

	If $iRows > 0 Then FileWriteLine($hFile, "GO")
	FileWriteLine($hFile, "")
	FileWriteLine($hFile, "-- End of table " & $sTable & ". Rows exported: " & $iRows)
	FileClose($hFile)

	_Log("Exported table: " & $sTable & " | Rows: " & $iRows & " | File: " & $sPath)
	Return SetError(0, 0, $iRows)
EndFunc   ;==>_ExportFirebirdTableToSqlScript

Func _GetFirebirdColumnsForSqlExport($sTable)
	; [][0]=ColumnName, [][1]=SqlServerType, [][2]=FirebirdTypeName, [][3]=RawFieldType, [][4]=SubType, [][5]=Length, [][6]=Precision, [][7]=Nullable, [][8]=Scale
	Local $sSql = "SELECT " & _
			"TRIM(rf.rdb$field_name) AS field_name, " & _
			"f.rdb$field_type AS field_type, " & _
			"COALESCE(f.rdb$field_sub_type, 0) AS sub_type, " & _
			"COALESCE(f.rdb$field_length, 0) AS field_length, " & _
			"COALESCE(f.rdb$field_precision, 0) AS field_precision, " & _
			"COALESCE(f.rdb$field_scale, 0) AS field_scale, " & _
			"COALESCE(rf.rdb$null_flag, f.rdb$null_flag, 0) AS null_flag " & _
			"FROM rdb$relation_fields rf " & _
			"JOIN rdb$fields f ON rf.rdb$field_source = f.rdb$field_name " & _
			"WHERE rf.rdb$relation_name = '" & StringUpper(StringReplace($sTable, "'", "''")) & "' " & _
			"ORDER BY rf.rdb$field_position"

	Local $rs = _FbQuery($sSql, "metadata/list")
	If @error Or Not IsObj($rs) Then Return SetError(1, 0, 0)

	Local $aCols[0][9]
	While Not $rs.EOF
		Local $sName = String($rs.Fields("field_name").Value)
		Local $iFieldType = Int($rs.Fields("field_type").Value)
		Local $iSubType = Int($rs.Fields("sub_type").Value)
		Local $iLength = Int($rs.Fields("field_length").Value)
		Local $iPrecision = Int($rs.Fields("field_precision").Value)
		Local $iScale = Int($rs.Fields("field_scale").Value)
		Local $iNullFlag = Int($rs.Fields("null_flag").Value)

		Local $r = UBound($aCols)
		ReDim $aCols[$r + 1][9]
		$aCols[$r][0] = $sName
		$aCols[$r][1] = _MapFbTypeToSqlForExport($iFieldType, $iSubType, $iLength, $iPrecision, $iScale)
		$aCols[$r][2] = _FirebirdTypeName($iFieldType, $iSubType)
		$aCols[$r][3] = $iFieldType
		$aCols[$r][4] = $iSubType
		$aCols[$r][5] = $iLength
		$aCols[$r][6] = $iPrecision
		$aCols[$r][7] = ($iNullFlag <> 1)
		$aCols[$r][8] = $iScale

		$rs.MoveNext()
	WEnd

	Return SetError(0, 0, $aCols)
EndFunc   ;==>_GetFirebirdColumnsForSqlExport

Func _BuildExportSqlColumnList(ByRef $aCols)
	Local $s = ""
	For $i = 0 To UBound($aCols) - 1
		If $i > 0 Then $s &= ","
		$s &= _SqlIdent($aCols[$i][0])
	Next
	Return $s
EndFunc   ;==>_BuildExportSqlColumnList

Func _MapFbTypeToSqlForExport($fieldType, $subType, $len, $prec, $scale)
	Local $iType = Int($fieldType)
	Local $iSub = Int($subType)

	Switch $iType
		Case 7
			If _FbIsExactNumeric($iSub) Then Return _FbDecimalType($prec, $scale, 5)
			Return "smallint"
		Case 8
			If _FbIsExactNumeric($iSub) Then Return _FbDecimalType($prec, $scale, 10)
			Return "int"
		Case 10
			Return "real"
		Case 11, 27
			Return "float"
		Case 12
			Return "date"
		Case 13
			Return "time(0)"
		Case 14
			Return _SqlTextTypeWithLength("char", $len)
		Case 37
			Return _SqlTextTypeWithLength("varchar", $len)
		Case 35
			Return "datetime2(0)"
		Case 261
			If $iSub = 1 Then Return "nvarchar(max)"
			Return "varbinary(max)"
		Case 16
			If _FbIsExactNumeric($iSub) Then Return _FbDecimalType($prec, $scale, 18)
			Return "bigint"
		Case Else
			Return "nvarchar(max)"
	EndSwitch
EndFunc   ;==>_MapFbTypeToSqlForExport

Func _SqlTextTypeWithLength($sBaseType, $len)
	Local $iLen = Int($len)
	If $iLen < 1 Then $iLen = 1
	If $iLen > 8000 Then Return "varchar(max)"
	Return $sBaseType & "(" & $iLen & ")"
EndFunc   ;==>_SqlTextTypeWithLength

Func _FbIsExactNumeric($subType)
	Local $iSub = Int($subType)
	Return ($iSub = 1 Or $iSub = 2)
EndFunc   ;==>_FbIsExactNumeric

Func _FbDecimalType($prec, $scale, $iDefaultPrecision)
	Local $iPrecision = Int($prec)
	Local $iScale = Abs(Int($scale))

	If $iPrecision < 1 Then $iPrecision = Int($iDefaultPrecision)
	If $iPrecision < 1 Then $iPrecision = 18
	If $iScale < 0 Then $iScale = 0
	If $iScale > 38 Then $iScale = 38
	If $iPrecision < ($iScale + 1) Then $iPrecision = $iScale + 1
	If $iPrecision > 38 Then $iPrecision = 38
	If $iScale > $iPrecision Then $iScale = $iPrecision

	Return "decimal(" & $iPrecision & "," & $iScale & ")"
EndFunc   ;==>_FbDecimalType

Func _FirebirdTypeName($fieldType, $subType)
	Local $iType = Int($fieldType)
	Local $iSub = Int($subType)

	Switch $iType
		Case 7
			If _FbIsExactNumeric($iSub) Then Return "SMALLINT NUMERIC/DECIMAL"
			Return "SMALLINT"
		Case 8
			If _FbIsExactNumeric($iSub) Then Return "INTEGER NUMERIC/DECIMAL"
			Return "INTEGER"
		Case 10
			Return "FLOAT"
		Case 11
			Return "D_FLOAT"
		Case 12
			Return "DATE"
		Case 13
			Return "TIME"
		Case 14
			Return "CHAR"
		Case 16
			If _FbIsExactNumeric($iSub) Then Return "BIGINT NUMERIC/DECIMAL"
			Return "BIGINT"
		Case 27
			Return "DOUBLE PRECISION"
		Case 35
			Return "TIMESTAMP"
		Case 37
			Return "VARCHAR"
		Case 261
			If $iSub = 1 Then Return "BLOB SUB_TYPE TEXT"
			Return "BLOB SUB_TYPE BINARY"
		Case Else
			Return "UNKNOWN"
	EndSwitch
EndFunc   ;==>_FirebirdTypeName

Func _SqlExportLiteral($v, $sSqlType)
	Local $t = StringLower($sSqlType)

	If _IsNull($v) Then Return "NULL"

	If IsObj($v) Then
		If _IsBinaryType($t) Then Return _SqlBinaryLiteral($v)
		Return _SqlTextLiteral(_BinaryToTextSafe($v))
	EndIf

	Local $vt = VarGetType($v)
	If _IsBinaryType($t) Then Return _SqlBinaryLiteral($v)

	If _IsDateTimeType($t) Then
		Local $iso = _ToIsoDateTime($v)
		If $iso = "" Then Return "NULL"
		If StringLeft($t, 4) = "date" And Not StringInStr($t, "datetime") Then Return "'" & StringLeft($iso, 10) & "'"
		If StringLeft($t, 4) = "time" Then Return "'" & StringMid($iso, 12, 8) & "'"
		Return "'" & $iso & "'"
	EndIf

	If _IsNumericType($t) Then
		Local $sv = StringStripWS(String($v), 3)
		If $sv = "" Then Return "NULL"
		$sv = StringReplace($sv, ",", ".")
		Return $sv
	EndIf

	If StringInStr($t, "bit") Then
		Local $bv = StringLower(StringStripWS(String($v), 3))
		If $bv = "" Then Return "NULL"
		If $bv = "true" Then Return "1"
		If $bv = "false" Then Return "0"
		Return String(Int($bv))
	EndIf

	If $vt = "Binary" Then Return _SqlTextLiteral(_BinaryToTextSafe($v))
	Return _SqlTextLiteral(String($v))
EndFunc   ;==>_SqlExportLiteral

Func _SqlIdent($sName)
	Return "[" & StringReplace(String($sName), "]", "]]") & "]"
EndFunc   ;==>_SqlIdent

Func _SafeFileName($sName)
	Local $s = String($sName)
	$s = StringRegExpReplace($s, '[\\/:*?"<>|]', "_")
	$s = StringStripWS($s, 3)
	If $s = "" Then $s = "table"
	Return $s
EndFunc   ;==>_SafeFileName

; -----------------------------
; Import
; -----------------------------
Func _RunImport()
	$g_bAbort = False
	$g_iErrorCount = 0
	$g_iWarningCount = 0
	$g_iSkippedDuplicates = 0
	$g_iSkippedRows = 0
	$g_iSkippedTables = 0
	$g_iInsertedRows = 0
	$g_iQuarantinedRows = 0
	$g_iOrtemsSourceOrphanRowsSkipped = 0
	$g_iOrtemsEffectivityFixups = 0
	$g_iOrtemsExportDateFormatFixups = 0
	$g_dOrtemsWoStartCache = ObjCreate("Scripting.Dictionary")
	ReDim $g_aOrtemsSourceOrphanWOs[0]
	ReDim $g_aOrtemsSourceOrphanWOs2[0]
	_UpdateCounters()
	_ProgressReset("Progress: 0% | Ready to start")

	_SetUiEnabled(False)
	_Status("Status: Starting import...")
	_ProgressSet(0, "Progress: 0% | Preparing import...")
	_SaveSettings()
	_StartRunLog()
	_Log("Verbose mode: " & _IIf($g_bVerboseMode, "ON - detailed debug data will be written to this log file only.", "OFF"))
	_ForceOrtemsSafeRuntimeOptions()

	$g_iBatchSize = Int(GUICtrlRead($inpBatch))
	If $g_iBatchSize < 1 Then $g_iBatchSize = 500

	Local $sGdb = GUICtrlRead($inpGdb)
	If $sGdb = "" Or Not FileExists($sGdb) Then
		_Log("ERROR: Please select a valid .gdb file.")
		_Status("Status: Missing source file.")
		_ProgressSet(0, "Progress: 0% | Import failed before start")
		_SetUiEnabled(True)
		_ShowImportResult("Import failed", "Import could not start because the selected Firebird .gdb file is missing or invalid." & @CRLF & @CRLF & "Log file: " & $g_sLogFile, 262144 + 16)
		Return
	EndIf

	If Not _OpenFirebird() Then
		_Log("ERROR: Firebird connection failed.")
		_Status("Status: Firebird connection failed.")
		_ProgressSet(0, "Progress: 0% | Import failed before start")
		_SetUiEnabled(True)
		_ShowImportResult("Import failed", "Import could not start because the Firebird connection failed." & @CRLF & @CRLF & "Log file: " & $g_sLogFile, 262144 + 16)
		Return
	EndIf

	_BuildSqlConnStr()
	If Not _OpenSqlServer() Then
		_Log("ERROR: SQL Server connection failed.")
		_Status("Status: SQL Server connection failed.")
		_ProgressSet(0, "Progress: 0% | Import failed before start")
		_SetUiEnabled(True)
		_ShowImportResult("Import failed", "Import could not start because the SQL Server connection failed." & @CRLF & @CRLF & "Log file: " & $g_sLogFile, 262144 + 16)
		Return
	EndIf

	Local $sSchema = GUICtrlRead($inpSchema)
	If $sSchema = "" Then $sSchema = "dbo"

	Local $aTables = _GetCheckedTables()
	If UBound($aTables) = 0 Then
		_Log("ERROR: No tables selected.")
		_Status("Status: No tables selected.")
		_ProgressSet(0, "Progress: 0% | Import failed before start")
		_SetUiEnabled(True)
		_ShowImportResult("Import failed", "Import could not start because no source tables were selected." & @CRLF & @CRLF & "Log file: " & $g_sLogFile, 262144 + 16)
		Return
	EndIf

	If $g_bOrtemsStartupSanitizer Then _PrepareOrtemsRelationalImport($aTables, $sSchema)

	_Log("=== Import started ===")
	_Log("Source GDB: " & $sGdb)
	_Log("Target SQL Server: " & GUICtrlRead($inpSqlServer) & " | DB: " & GUICtrlRead($inpSqlDb) & " | Auth: " & GUICtrlRead($cmbAuth) & " | Schema: " & $sSchema)
	_Log("Tables selected: " & UBound($aTables))
	_Log("Options: ExistingSchemaOnly=True | ClearBeforeLoad=" & (GUICtrlRead($chkClearBeforeLoad) = $GUI_CHECKED) & _
			" | SkipDuplicatePK=" & (GUICtrlRead($chkSkipDuplicatePK) = $GUI_CHECKED) & _
			" | OrderByFK=" & (GUICtrlRead($chkOrderByFK) = $GUI_CHECKED) & _
			" | EmptyStringAsNull=" & (GUICtrlRead($chkEmptyStringAsNull) = $GUI_CHECKED) & _
			" | FallbackNotNull=" & (GUICtrlRead($chkFallbackNotNull) = $GUI_CHECKED) & _
			" | DisableTriggers=" & (GUICtrlRead($chkDisableTriggers) = $GUI_CHECKED) & _
			" | OrtemsStartupSanitizer=" & $g_bOrtemsStartupSanitizer & _
			" | VerboseMode=" & $g_bVerboseMode & _
			" | BatchSize=" & $g_iBatchSize)
	If $g_bOrtemsStartupSanitizer Then _Log("Ortems startup sanitizer enabled for PL_0451/B_STOC, PL_0445/B_DT, PL_0170 E_OF/B_BT, PL_0439 export date-format parameters, and Ortems semantic dependency checks.")

	; Order must be semantic first, FK-safe last. The previous sequence applied
	; Ortems semantic ranking after SQL FK sorting, which could move physical parent
	; tables (for example ENCOURS) after dependent configuration tables such as
	; BUSINESS_CONFIG. That produced FK1_BUSINESS_CONFIG errors and aborted the load.
	Local $aOrdered = $aTables
	If $g_bOrtemsStartupSanitizer Then $aOrdered = _ApplyOrtemsSemanticOrder($aOrdered)
	$aOrdered = _OrderTablesByForeignKeys($aOrdered, $sSchema, $g_bOrtemsStartupSanitizer)
	If $g_bOrtemsStartupSanitizer Then _Log("Final import order is SQL-FK-safe after Ortems semantic ordering.")
	Local $bTriggersManaged = (GUICtrlRead($chkDisableTriggers) = $GUI_CHECKED)

	If GUICtrlRead($chkClearBeforeLoad) = $GUI_CHECKED Then
		_ProgressSet(0, "Progress: 0% | Clearing selected tables...")
		If Not _ClearSelectedTables($aOrdered, $sSchema) Then
			_Log("ERROR: Clear before load failed. Import stopped.")
			If $bTriggersManaged Then _SetTriggersForTables($aOrdered, $sSchema, True)
			_Status("Status: Failed while clearing selected tables.")
			_ProgressSet(0, "Progress: 0% | Import failed during table clear")
			_SetUiEnabled(True)
			_ShowImportResult("Import failed", "Import stopped while clearing the selected SQL Server tables." & @CRLF & @CRLF & "Review the log file for details:" & @CRLF & $g_sLogFile, 262144 + 16)
			Return
		EndIf
	EndIf

	; _ClearSelectedTables temporarily re-enables triggers after the purge. If the user
	; requested trigger management for the load, disable them again only after the clear
	; step has finished. This prevents Ortems business triggers from creating duplicate
	; side effects while the full source dataset is being copied.
	If $bTriggersManaged Then _SetTriggersForTables($aOrdered, $sSchema, False)

	Local $iOk = 0, $iFail = 0
	For $i = 0 To UBound($aOrdered) - 1
		_ProcessGuiDuringRun()
		If $g_bAbort Then ExitLoop

		Local $t = $aOrdered[$i]
		Local $iTableRows = _GetFirebirdRowCount($t)
		_Status("Status: Importing " & $t & " (" & ($i + 1) & "/" & UBound($aOrdered) & ")...")
		_ProgressTableStart($i, UBound($aOrdered), $t, $iTableRows)
		If _ImportTable($t, $sSchema, $i, UBound($aOrdered), $iTableRows) Then
			$iOk += 1
		Else
			$iFail += 1
		EndIf
		_ProgressTableDone($i, UBound($aOrdered), $t)

		If $g_bAbort Then ExitLoop
	Next

	If $g_bOrtemsStartupSanitizer Then
		If $g_bAbort Then
			_Warn("Ortems startup sanitizer cleanup skipped because the import was aborted. Do not open Ortems with a partial target database; rerun the import after correcting the logged errors.")
		Else
			_ApplyOrtemsStartupSanitizerCleanup($sSchema, $aOrdered)
		EndIf
	EndIf

	If $bTriggersManaged Then _SetTriggersForTables($aOrdered, $sSchema, True)

	_Log("=== Import finished ===")
	Local $sFinalTitle = "Import completed"
	Local $sFinalMessage = ""
	Local $iFinalIcon = 64

	If $g_bAbort Then
		_Log("Process ABORTED.")
		_Status("Status: Aborted. Success=" & $iOk & " Failed=" & $iFail)
		_ProgressSet($g_iProgressLastPercent, "Progress: aborted | Review the log file")
		$sFinalTitle = "Import aborted"
		$iFinalIcon = 48
		$sFinalMessage = "The import was aborted before completion. Do not open Ortems with a partial target database." & @CRLF & @CRLF
	Else
		_Log("Success tables: " & $iOk & " | Failed tables: " & $iFail & " | Errors: " & $g_iErrorCount & " | Warnings: " & $g_iWarningCount)
		_Log("Inserted rows: " & $g_iInsertedRows & " | Skipped duplicate rows: " & $g_iSkippedDuplicates & " | Source orphan WO rows skipped: " & $g_iOrtemsSourceOrphanRowsSkipped & " | Ortems effectivity date fixups: " & $g_iOrtemsEffectivityFixups & " | Ortems export date-format fixups: " & $g_iOrtemsExportDateFormatFixups & " | Quarantined rows: " & $g_iQuarantinedRows & " | Other skipped rows: " & $g_iSkippedRows & " | Skipped tables: " & $g_iSkippedTables)
		_Status("Status: Done. Success=" & $iOk & " Failed=" & $iFail & " Errors=" & $g_iErrorCount & " Warnings=" & $g_iWarningCount)

		If $iFail = 0 And $g_iErrorCount = 0 Then
			_ProgressSet(100, "Progress: 100% | Import completed successfully")
			$sFinalMessage = "Import completed successfully." & @CRLF & @CRLF
		Else
			_ProgressSet(100, "Progress: 100% | Import completed with errors or warnings")
			$sFinalTitle = "Import completed with issues"
			$iFinalIcon = 48
			$sFinalMessage = "Import completed, but some tables or rows reported issues. Review the log before opening Ortems." & @CRLF & @CRLF
		EndIf
	EndIf

	$sFinalMessage &= "Tables succeeded: " & $iOk & @CRLF & _
			"Tables failed: " & $iFail & @CRLF & _
			"Errors: " & $g_iErrorCount & @CRLF & _
			"Warnings: " & $g_iWarningCount & @CRLF & _
			"Inserted rows: " & $g_iInsertedRows & @CRLF & _
			"Skipped rows: " & ($g_iSkippedDuplicates + $g_iSkippedRows) & @CRLF & @CRLF & _
			"Log file:" & @CRLF & $g_sLogFile

	_SetUiEnabled(True)
	_ShowImportResult($sFinalTitle, $sFinalMessage, $iFinalIcon)
EndFunc   ;==>_RunImport

Func _TableNeedsIdentityInsert(ByRef $aCols)
	For $i = 0 To UBound($aCols) - 1
		If $aCols[$i][5] Then Return True
	Next
	Return False
EndFunc   ;==>_TableNeedsIdentityInsert

Func _SetIdentityInsert($sSchema, $sTable, $bOn)
	Local $sMode = "OFF"
	If $bOn Then $sMode = "ON"

	Local $sSql = "SET IDENTITY_INSERT [" & $sSchema & "].[" & $sTable & "] " & $sMode & ";"
	Local $native = _SqlExec($sSql, $bOn)
	If @error Or $g_bLastSqlExecFailed Then
		If $bOn Then
			_Log("ERROR: Could not enable IDENTITY_INSERT for [" & $sSchema & "].[" & $sTable & "].")
		Else
			_Warn("Could not disable IDENTITY_INSERT for [" & $sSchema & "].[" & $sTable & "]. Please close/reopen the SQL connection if SQL Server reports it is still ON.")
		EndIf
		Return SetError(1, 0, $native)
	EndIf

	If $bOn Then
		_Log("IDENTITY_INSERT enabled for [" & $sSchema & "].[" & $sTable & "] to preserve source identity values.")
	Else
		_Log("IDENTITY_INSERT disabled for [" & $sSchema & "].[" & $sTable & "].")
	EndIf
	Return SetError(0, 0, "")
EndFunc   ;==>_SetIdentityInsert

Func _GetFirebirdRowCount($sTable)
	Local $rsCount = _FbQuery("SELECT COUNT(*) FROM " & _FbIdent($sTable), "row count " & $sTable)
	If @error Or Not IsObj($rsCount) Then
		_Warn("Could not estimate source row count for table " & $sTable & ". Progress will use table-level progress only.")
		Return -1
	EndIf
	If $rsCount.EOF Then Return -1

	Local $vCount = $rsCount.Fields(0).Value
	If _IsNull($vCount) Then Return -1
	Return Int($vCount)
EndFunc   ;==>_GetFirebirdRowCount

Func _ImportTable($sTable, $sSchema, $iTableIndex = -1, $iTotalTables = 0, $iTotalRows = -1)
	Local $aFbCols = _GetFirebirdColumns($sTable)
	If @error Or UBound($aFbCols) = 0 Then
		_Log("ERROR: Unable to read Firebird metadata for table: " & $sTable)
		Return False
	EndIf

	If Not _TargetTableExists($sSchema, $sTable) Then
		_Warn("Target table does not exist. Skipping import for source table: [" & $sSchema & "].[" & $sTable & "]")
		$g_iSkippedTables += 1
		Return True
	EndIf

	If _IsOrtemsStartupUnsafeWholeTable($sTable) Then
		_Warn("Ortems startup sanitizer: skipping table " & $sTable & " because copied WIP detail rows from this table are known to trigger PL_0445 when recalled by Ortems.")
		$g_iSkippedTables += 1
		Return True
	EndIf

	Local $dTarget = _GetTargetColumnInfo($sSchema, $sTable)
	If @error Or Not IsObj($dTarget) Then
		_Log("ERROR: Target table does not exist or metadata could not be read: [" & $sSchema & "].[" & $sTable & "]")
		Return False
	EndIf
	If $dTarget.Count = 0 Then
		_Log("ERROR: Target table has no readable columns: [" & $sSchema & "].[" & $sTable & "]")
		Return False
	EndIf

	Local $aCols = _GetImportColumns($sTable, $aFbCols, $dTarget)
	If UBound($aCols) = 0 Then
		_Log("ERROR: No matching columns between source and target for table: " & $sTable)
		Return False
	EndIf

	If GUICtrlRead($chkClearBeforeLoad) <> $GUI_CHECKED Then
		_Log("Append mode: target table will not be cleared before load: [" & $sSchema & "].[" & $sTable & "]")
	EndIf

	Local $rs = _FbQuery("SELECT * FROM " & _FbIdent($sTable), "table data " & $sTable)
	If @error Or Not IsObj($rs) Then
		_Log("ERROR: Failed to read data from Firebird table: " & $sTable)
		Return False
	EndIf

	Local $bIdentityInsertOn = _TableNeedsIdentityInsert($aCols)
	If $bIdentityInsertOn Then
		If @error Then
			_Log("ERROR: Could not inspect identity columns for table: " & $sTable)
			Return False
		EndIf

		Local $nativeIdentity = _SetIdentityInsert($sSchema, $sTable, True)
		If @error Or $g_bLastSqlExecFailed Then Return False
	EndIf

	Local $iRow = 0, $iInserted = 0, $iSkippedDup = 0, $iSkippedOther = 0, $iQuarantined = 0, $iSourceOrphanSkipped = 0
	While Not $rs.EOF
		_ProcessGuiDuringRun()
		If $g_bAbort Then
			If $bIdentityInsertOn Then _SetIdentityInsert($sSchema, $sTable, False)
			_Log("ABORTED table: " & $sTable)
			Return False
		EndIf

		If _ShouldSkipOrtemsSourceOrphanRow($sTable, $rs, $aCols) Then
			_Verbose("IMPORT ROW RESULT: Table=" & $sTable & " | Row=" & $iRow & " | Result=SKIPPED_SOURCE_ORPHAN_WO | Snapshot=" & _BuildRowDebugText($rs, $aCols, 2000))
			$g_iOrtemsSourceOrphanRowsSkipped += 1
			$g_iSkippedRows += 1
			$iSourceOrphanSkipped += 1
			$iRow += 1
			If Mod($iRow, $g_iBatchSize) = 0 Then _ProgressTableRows($sTable, $iRow, $iInserted, ($iSkippedDup + $iSkippedOther + $iQuarantined + $iSourceOrphanSkipped), $iTableIndex, $iTotalTables, $iTotalRows)
			$rs.MoveNext()
			ContinueLoop
		EndIf

		If _ShouldQuarantineOrtemsStartupRow($sTable, $rs, $aCols) Then
			_Verbose("IMPORT ROW RESULT: Table=" & $sTable & " | Row=" & $iRow & " | Result=QUARANTINED_BY_ORTEMS_STARTUP_SANITIZER | Snapshot=" & _BuildRowDebugText($rs, $aCols, 2000))
			$iQuarantined += 1
			$g_iQuarantinedRows += 1
			$g_iSkippedRows += 1
			$iRow += 1
			If Mod($iRow, $g_iBatchSize) = 0 Then _ProgressTableRows($sTable, $iRow, $iInserted, ($iSkippedDup + $iSkippedOther + $iQuarantined + $iSourceOrphanSkipped), $iTableIndex, $iTotalTables, $iTotalRows)
			$rs.MoveNext()
			ContinueLoop
		EndIf

		Local $sPkWhere = _BuildPkWhere($sTable, $rs, $aCols)
		If GUICtrlRead($chkSkipDuplicatePK) = $GUI_CHECKED And $sPkWhere <> "" Then
			If _RowExistsByPk($sSchema, $sTable, $sPkWhere) Then
				_Verbose("IMPORT ROW RESULT: Table=" & $sTable & " | Row=" & $iRow & " | Result=SKIPPED_DUPLICATE_PRECHECK | PKWhere=" & $sPkWhere)
				$iSkippedDup += 1
				$g_iSkippedDuplicates += 1
				$iRow += 1
				If Mod($iRow, $g_iBatchSize) = 0 Then _ProgressTableRows($sTable, $iRow, $iInserted, ($iSkippedDup + $iSkippedOther + $iQuarantined + $iSourceOrphanSkipped), $iTableIndex, $iTotalTables, $iTotalRows)
				$rs.MoveNext()
				ContinueLoop
			EndIf
		EndIf

		Local $sInsert = _BuildInsertSql($sSchema, $sTable, $rs, $aCols)
		Local $bSkipDup = (GUICtrlRead($chkSkipDuplicatePK) = $GUI_CHECKED)
		Local $native = _SqlExec($sInsert, True, True, $bSkipDup)

		If @error Or $g_bLastSqlExecFailed Then
			; Ortems: auto-repair known relational gaps before classifying the row as failed.
			If StringInStr($native, "547|") Then
				; FK2_E_OF_VER: E_OF_VER rows referencing a missing B_VER_ART version header.
				If (StringUpper($sTable) = "E_OF_VER" Or StringUpper($sTable) = "E_OF_VER2") And StringInStr($g_sLastAdoErrorText, "FK2_E_OF_VER") Then
					If _EnsureOrtemsParent_B_VER_ART($sSchema, $rs) Then
						; Retry the original insert once after creating the parent row.
						$native = _SqlExec($sInsert, False, True, $bSkipDup)
						If Not (@error Or $g_bLastSqlExecFailed) Then
							_Verbose("IMPORT ROW RESULT: Table=" & $sTable & " | Row=" & $iRow & " | Result=INSERTED_AFTER_RELATIONAL_REPAIR")
							$iInserted += 1
							$g_iInsertedRows += 1
							$iRow += 1
							If Mod($iRow, $g_iBatchSize) = 0 Then
								_Status("Status: Importing " & $sTable & " | Rows read: " & $iRow & " | Inserted: " & $iInserted & " | Skipped: " & ($iSkippedDup + $iSkippedOther))
								_ProgressTableRows($sTable, $iRow, $iInserted, ($iSkippedDup + $iSkippedOther + $iQuarantined + $iSourceOrphanSkipped), $iTableIndex, $iTotalTables, $iTotalRows)
								_ProcessGuiDuringRun()
							EndIf
							$rs.MoveNext()
							ContinueLoop
						EndIf
					EndIf
				EndIf
			EndIf
			If StringInStr($native, "2627|") Or StringInStr($native, "2601|") Then
				; A duplicate error can be raised by a trigger on another table, not by
				; the row currently being inserted. Only treat it as a harmless duplicate
				; when the target row can be found by the same PK values. Otherwise it is
				; a real load failure and must not be silently skipped, because child
				; tables would later fail with FK errors.
				Local $bConfirmedDuplicate = False
				If $bSkipDup And $sPkWhere <> "" Then $bConfirmedDuplicate = _RowExistsByPk($sSchema, $sTable, $sPkWhere)

				If $bSkipDup And $bConfirmedDuplicate Then
					_Verbose("IMPORT ROW RESULT: Table=" & $sTable & " | Row=" & $iRow & " | Result=SKIPPED_DUPLICATE_AFTER_SQL_ERROR | PKWhere=" & $sPkWhere & " | NativeErrors=" & $native)
					$iSkippedDup += 1
					$g_iSkippedDuplicates += 1
					_Log("Skipped confirmed duplicate row after SQL Server PK/unique constraint. Table=" & $sTable & " Row=" & $iRow)
				Else
					; _SqlExec intentionally does not count duplicate-key errors when
					; duplicate skipping is enabled. If we cannot confirm the row exists,
					; put the error back into the global counter here.
					If $bSkipDup Then
						$g_iErrorCount += 1
						_UpdateCounters()
						If $g_iErrorCount >= $g_iMaxErrors Then
							$g_bAbort = True
							_Log("MaxErrors reached (" & $g_iMaxErrors & "). Auto-aborting...")
							_Status("Status: Auto-abort due to too many errors.")
						EndIf
					EndIf
					_Verbose("IMPORT ROW RESULT: Table=" & $sTable & " | Row=" & $iRow & " | Result=FAILED_DUPLICATE_NOT_CONFIRMED | NativeErrors=" & $native & " | Snapshot=" & _BuildRowDebugText($rs, $aCols, 2000))
					_Log("SQL EXECUTE FAILED (duplicate was not confirmed on target row). Table=" & $sTable & " Row=" & $iRow)
					_Log("Source row snapshot: " & _BuildRowDebugText($rs, $aCols, 2000))
					$iSkippedOther += 1
					$g_iSkippedRows += 1
				EndIf
			Else
				_Verbose("IMPORT ROW RESULT: Table=" & $sTable & " | Row=" & $iRow & " | Result=FAILED_INSERT | NativeErrors=" & $native & " | Snapshot=" & _BuildRowDebugText($rs, $aCols, 2000))
				_Log("SQL EXECUTE FAILED (insert). Table=" & $sTable & " Row=" & $iRow)
				_Log("Source row snapshot: " & _BuildRowDebugText($rs, $aCols, 2000))
				$iSkippedOther += 1
				$g_iSkippedRows += 1
			EndIf

			If $g_iErrorCount >= $g_iMaxErrors Then
				If $bIdentityInsertOn Then _SetIdentityInsert($sSchema, $sTable, False)
				Return False
			EndIf
		Else
			_Verbose("IMPORT ROW RESULT: Table=" & $sTable & " | Row=" & $iRow & " | Result=INSERTED")
			$iInserted += 1
			$g_iInsertedRows += 1
		EndIf

		$iRow += 1
		If Mod($iRow, $g_iBatchSize) = 0 Then
			_Status("Status: Importing " & $sTable & " | Rows read: " & $iRow & " | Inserted: " & $iInserted & " | Skipped: " & ($iSkippedDup + $iSkippedOther))
			_ProgressTableRows($sTable, $iRow, $iInserted, ($iSkippedDup + $iSkippedOther + $iQuarantined + $iSourceOrphanSkipped), $iTableIndex, $iTotalTables, $iTotalRows)
			_ProcessGuiDuringRun()
		EndIf

		$rs.MoveNext()
	WEnd

	_ProgressTableRows($sTable, $iRow, $iInserted, ($iSkippedDup + $iSkippedOther + $iQuarantined + $iSourceOrphanSkipped), $iTableIndex, $iTotalTables, $iTotalRows)

	If $bIdentityInsertOn Then _SetIdentityInsert($sSchema, $sTable, False)

	_Log("Imported table: " & $sTable & " | Rows read: " & $iRow & " | Inserted: " & $iInserted & " | Skipped duplicates: " & $iSkippedDup & " | Source orphan WO skipped: " & $iSourceOrphanSkipped & " | Quarantined: " & $iQuarantined & " | Other skipped: " & $iSkippedOther)
	Return ($iSkippedOther = 0)
EndFunc   ;==>_ImportTable

Func _BuildInsertSql($sSchema, $sTable, $rs, ByRef $aCols)
	; SQL Server accepts DEFAULT in some INSERT forms, but using DEFAULT inside dynamic
	; value lists can behave inconsistently through older ODBC/OLE DB paths. For columns
	; that should receive their SQL Server default, omit the column from this row instead.
	Local $sColList = ""
	Local $sValues = ""
	Local $iIncluded = 0

	For $c = 0 To UBound($aCols) - 1
		Local $v = _GetImportColumnValue($rs, $aCols, $c)
		Local $lit = _SqlLiteralForColumn($v, $aCols[$c][1], $aCols[$c][2], $aCols[$c][3])
		$lit = _OrtemsOverrideImportLiteral($sTable, $rs, $aCols, $aCols[$c][0], $aCols[$c][1], $aCols[$c][2], $aCols[$c][3], $lit, True)

		If $lit = "DEFAULT" Then ContinueLoop

		If $iIncluded > 0 Then
			$sColList &= ","
			$sValues &= ","
		EndIf
		$sColList &= "[" & $aCols[$c][0] & "]"
		$sValues &= $lit
		$iIncluded += 1
	Next

	If $iIncluded = 0 Then Return "INSERT INTO [" & $sSchema & "].[" & $sTable & "] DEFAULT VALUES"
	Return "INSERT INTO [" & $sSchema & "].[" & $sTable & "] (" & $sColList & ") VALUES (" & $sValues & ")"
EndFunc   ;==>_BuildInsertSql

Func _BuildPkWhere($sTable, $rs, ByRef $aCols)
	; Duplicate pre-check must use the exact same value that the INSERT will send.
	; This matters for NOT NULL PK date/time columns where an empty Firebird value is
	; converted to the safe fallback '1900-01-01'. If we compare the raw source value
	; as NULL, the pre-check misses the row and SQL Server raises PK violation later.
	Local $sWhere = ""
	Local $iPkCols = 0

	For $i = 0 To UBound($aCols) - 1
		If Not $aCols[$i][4] Then ContinueLoop
		$iPkCols += 1

		Local $v = _GetImportColumnValue($rs, $aCols, $i)
		Local $lit = _SqlLiteralForColumn($v, $aCols[$i][1], $aCols[$i][2], $aCols[$i][3])
		$lit = _OrtemsOverrideImportLiteral($sTable, $rs, $aCols, $aCols[$i][0], $aCols[$i][1], $aCols[$i][2], $aCols[$i][3], $lit, False)

		; DEFAULT cannot be used inside WHERE. In that uncommon case, skip the
		; pre-check and let the INSERT duplicate handler classify it as a skipped row.
		If $lit = "DEFAULT" Then Return ""

		If $lit = "NULL" Then
			If $sWhere <> "" Then $sWhere &= " AND "
			$sWhere &= "[" & $aCols[$i][0] & "] IS NULL"
		Else
			If $sWhere <> "" Then $sWhere &= " AND "
			$sWhere &= "[" & $aCols[$i][0] & "] = " & $lit
		EndIf
	Next

	If $iPkCols = 0 Then Return ""
	Return $sWhere
EndFunc   ;==>_BuildPkWhere


Func _OrtemsOverrideImportLiteral($sTable, $rs, ByRef $aCols, $sCol, $sTargetType, $bNullable, $sDefault, $sCurrentLit, $bLog)
	If Not $g_bOrtemsStartupSanitizer Then Return $sCurrentLit

	Local $sTableU = _NormalizeTableName($sTable)
	If $sTableU <> "E_OF_VER" And $sTableU <> "E_OF_VER2" Then Return $sCurrentLit

	Local $sColU = StringUpper(String($sCol))
	If StringInStr($sColU, "VER_EFFET_DEBUT") = 0 Then Return $sCurrentLit

	; Always resolve the mandatory WO version effectivity start date explicitly.
	; Do not allow this column to be omitted as DEFAULT or inserted as NULL, because SQL
	; Server rejects the row and Ortems may then start with a broken E_OF/E_OF_VER/B_BT chain.
	If $sCurrentLit <> "NULL" And $sCurrentLit <> "DEFAULT" Then Return $sCurrentLit

	Local $sIso = _ResolveOrtemsWoVersionEffectivityStart($sTableU, $rs, $aCols)
	If $sIso = "" Then
		; Last-resort low date. This keeps the WO version effective from the beginning of
		; the planning horizon while making the data issue visible in the import log.
		$sIso = "1900-01-01 00:00:00"
		If $bLog Then _Warn("Ortems effectivity fix: " & $sTable & "." & $sCol & " was NULL/blank and no source WO date was found. Applied safe low-date fallback " & $sIso & ". Review the source data.")
	Else
		If $bLog Then _Log("Ortems effectivity fix: " & $sTable & "." & $sCol & " was resolved to " & $sIso & ".")
	EndIf

	If $bLog Then $g_iOrtemsEffectivityFixups += 1
	Return "'" & $sIso & "'"
EndFunc   ;==>_OrtemsOverrideImportLiteral

Func _ResolveOrtemsWoVersionEffectivityStart($sTableU, $rs, ByRef $aCols)
	; 1) Try other date/effectivity columns already present in the E_OF_VER row.
	Local $aLocalDates[14] = ["VER_EFFET_DEBUT", "VER_EFFET_DEBUT2", "EFFET_DEBUT", "EFFET_DEBUT2", "DATE_DEBUT", "DATE_DEBUT2", "VER_DATE_DEBUT", "VER_DATE_DEBUT2", "OF_DATE_DEBUT", "OF_DATE_DEBUT2", "OF_DEBUT", "OF_DEBUT2", "DEBUT", "DEBUT2"]
	Local $sIso = _FirstIsoDateFromImportColumns($rs, $aCols, $aLocalDates)
	If $sIso <> "" Then Return $sIso

	; 2) Try the parent WO header in Firebird. E_OF_VER normally belongs to E_OF, so the
	; best repair is to inherit the WO start/release/creation date instead of injecting a
	; blind technical date.
	Local $bScenario = ($sTableU = "E_OF_VER2")
	Local $aWoCols[14] = ["E_NOF", "E_NOF2", "NOF", "NOF2", "OF_NOF", "OF_NOF2", "WO_ID", "WO_ID2", "WOID", "WOID2", "ID_OF", "ID_OF2", "NOF_OF", "NOF_OF2"]
	Local $sWo = _FirstTextFromImportColumns($rs, $aCols, $aWoCols)
	If $sWo <> "" Then
		$sIso = _GetFirebirdWoEffectiveStartDate($sWo, $bScenario)
		If $sIso <> "" Then Return $sIso
	EndIf

	; 3) If the row carries version-level date fields under less common names, catch them
	; here before using the low-date fallback.
	Local $aMoreDates[12] = ["DATE_LANCEMENT", "DATE_LANCEMENT2", "OF_DATE_LANCEMENT", "OF_DATE_LANCEMENT2", "DATE_CREATION", "DATE_CREATION2", "OF_DATE_CREATION", "OF_DATE_CREATION2", "CREATION_DATE", "CREATION_DATE2", "START_DATE", "START_DATE2"]
	Return _FirstIsoDateFromImportColumns($rs, $aCols, $aMoreDates)
EndFunc   ;==>_ResolveOrtemsWoVersionEffectivityStart

Func _FirstIsoDateFromImportColumns($rs, ByRef $aCols, ByRef $aCandidates)
	For $i = 0 To UBound($aCandidates) - 1
		Local $v = _GetImportColumnValueByName($rs, $aCols, $aCandidates[$i])
		If _IsNull($v) Or IsObj($v) Then ContinueLoop
		Local $sIso = _ToIsoDateTime($v)
		If $sIso <> "" Then Return $sIso
	Next
	Return ""
EndFunc   ;==>_FirstIsoDateFromImportColumns

Func _FirstTextFromImportColumns($rs, ByRef $aCols, ByRef $aCandidates)
	For $i = 0 To UBound($aCandidates) - 1
		Local $v = _GetImportColumnValueByName($rs, $aCols, $aCandidates[$i])
		If _IsNull($v) Or IsObj($v) Then ContinueLoop
		Local $s = StringStripWS(String($v), 3)
		If $s <> "" Then Return $s
	Next
	Return ""
EndFunc   ;==>_FirstTextFromImportColumns

Func _GetFirebirdWoEffectiveStartDate($sWo, $bScenario)
	Local $sWoClean = StringStripWS(String($sWo), 3)
	If $sWoClean = "" Then Return ""

	If Not IsObj($g_dOrtemsWoStartCache) Then $g_dOrtemsWoStartCache = ObjCreate("Scripting.Dictionary")
	Local $sCacheKey = _IIf($bScenario, "2|", "1|") & StringUpper($sWoClean)
	If $g_dOrtemsWoStartCache.Exists($sCacheKey) Then Return $g_dOrtemsWoStartCache.Item($sCacheKey)

	Local $sTable = _IIf($bScenario, "E_OF2", "E_OF")
	Local $sResolved = ""

	If _FirebirdTableExists($sTable) Then
		Local $aKeyCols[8]
		If $bScenario Then
			$aKeyCols[0] = "E_NOF2"
			$aKeyCols[1] = "E_NOF"
			$aKeyCols[2] = "NOF2"
			$aKeyCols[3] = "OF_NOF2"
			$aKeyCols[4] = "WO_ID2"
			$aKeyCols[5] = "WOID2"
			$aKeyCols[6] = "ID_OF2"
			$aKeyCols[7] = "NOF_OF2"
		Else
			$aKeyCols[0] = "E_NOF"
			$aKeyCols[1] = "NOF"
			$aKeyCols[2] = "OF_NOF"
			$aKeyCols[3] = "WO_ID"
			$aKeyCols[4] = "WOID"
			$aKeyCols[5] = "ID_OF"
			$aKeyCols[6] = "NOF_OF"
			$aKeyCols[7] = "E_WO"
		EndIf

		Local $sKeyCol = _FindFirebirdColumn($sTable, $aKeyCols)
		If $sKeyCol <> "" Then
			Local $aDateCols[18]
			If $bScenario Then
				$aDateCols[0] = "OF_DATE_DEBUT2"
				$aDateCols[1] = "OF_DEBUT2"
				$aDateCols[2] = "DATE_DEBUT2"
				$aDateCols[3] = "DATE_LANCEMENT2"
				$aDateCols[4] = "OF_DATE_LANCEMENT2"
				$aDateCols[5] = "DATE_CREATION2"
				$aDateCols[6] = "OF_DATE_CREATION2"
				$aDateCols[7] = "EFFET_DEBUT2"
				$aDateCols[8] = "START_DATE2"
				$aDateCols[9] = "OF_DATE_DEBUT"
				$aDateCols[10] = "OF_DEBUT"
				$aDateCols[11] = "DATE_DEBUT"
				$aDateCols[12] = "DATE_LANCEMENT"
				$aDateCols[13] = "OF_DATE_LANCEMENT"
				$aDateCols[14] = "DATE_CREATION"
				$aDateCols[15] = "OF_DATE_CREATION"
				$aDateCols[16] = "EFFET_DEBUT"
				$aDateCols[17] = "START_DATE"
			Else
				$aDateCols[0] = "OF_DATE_DEBUT"
				$aDateCols[1] = "OF_DEBUT"
				$aDateCols[2] = "DATE_DEBUT"
				$aDateCols[3] = "DATE_LANCEMENT"
				$aDateCols[4] = "OF_DATE_LANCEMENT"
				$aDateCols[5] = "DATE_CREATION"
				$aDateCols[6] = "OF_DATE_CREATION"
				$aDateCols[7] = "EFFET_DEBUT"
				$aDateCols[8] = "START_DATE"
				$aDateCols[9] = "OF_DATE_DEBUT2"
				$aDateCols[10] = "OF_DEBUT2"
				$aDateCols[11] = "DATE_DEBUT2"
				$aDateCols[12] = "DATE_LANCEMENT2"
				$aDateCols[13] = "OF_DATE_LANCEMENT2"
				$aDateCols[14] = "DATE_CREATION2"
				$aDateCols[15] = "OF_DATE_CREATION2"
				$aDateCols[16] = "EFFET_DEBUT2"
				$aDateCols[17] = "START_DATE2"
			EndIf

			For $i = 0 To UBound($aDateCols) - 1
				Local $sDateCol = $aDateCols[$i]
				If Not _FirebirdColumnExists($sTable, $sDateCol) Then ContinueLoop

				Local $sSql = "SELECT FIRST 1 CAST(" & $sDateCol & " AS VARCHAR(50)) AS START_DATE " & _
						"FROM " & $sTable & " WHERE " & $sDateCol & " IS NOT NULL " & _
						"AND TRIM(CAST(" & $sKeyCol & " AS VARCHAR(255))) = '" & StringReplace($sWoClean, "'", "''") & "' " & _
						"ORDER BY " & $sDateCol
				Local $rsDate = _FbQuery($sSql, "Ortems WO effective start date")
				If Not @error And IsObj($rsDate) And Not $rsDate.EOF Then
					$sResolved = _ToIsoDateTime($rsDate.Fields("START_DATE").Value)
					If $sResolved <> "" Then ExitLoop
				EndIf
			Next
		EndIf
	EndIf

	$g_dOrtemsWoStartCache.Add($sCacheKey, $sResolved)
	Return $sResolved
EndFunc   ;==>_GetFirebirdWoEffectiveStartDate

Func _FindFirebirdColumn($sTable, ByRef $aCandidates)
	For $i = 0 To UBound($aCandidates) - 1
		If _FirebirdColumnExists($sTable, $aCandidates[$i]) Then Return $aCandidates[$i]
	Next
	Return ""
EndFunc   ;==>_FindFirebirdColumn

Func _RowExistsByPk($sSchema, $sTable, $sWhere)
	Local $sSql = "SELECT TOP 1 1 AS RowExists FROM [" & $sSchema & "].[" & $sTable & "] WHERE " & $sWhere
	Local $rs = _SqlQuery($sSql)
	If @error Or Not IsObj($rs) Then Return False
	If $rs.EOF Then Return False
	Return True
EndFunc   ;==>_RowExistsByPk

Func _FbIdent($sName)
	Return $sName
EndFunc   ;==>_FbIdent


; -----------------------------
; Ortems relational dependency preflight
; -----------------------------
Func _PrepareOrtemsRelationalImport(ByRef $aTables, $sSchema)
	_Log("Preparing Ortems relational import checks before table load.")
	_ExpandOrtemsRequiredTables($aTables, $sSchema)
	_ExpandSqlForeignKeyParentTables($aTables, $sSchema)
	_BuildOrtemsSourceOrphanLists()
EndFunc   ;==>_PrepareOrtemsRelationalImport

Func _ExpandSqlForeignKeyParentTables(ByRef $aTables, $sSchema)
	; If a dependent table is selected, import its SQL Server FK parent tables too.
	; This protects partial selections and also documents physical dependencies that
	; Ortems may not expose through the semantic table names alone.
	Local $sSql = "SELECT DISTINCT child.name AS child_table, parent.name AS parent_table " & _
			"FROM sys.foreign_keys fk " & _
			"JOIN sys.tables child ON fk.parent_object_id = child.object_id " & _
			"JOIN sys.schemas child_schema ON child.schema_id = child_schema.schema_id " & _
			"JOIN sys.tables parent ON fk.referenced_object_id = parent.object_id " & _
			"JOIN sys.schemas parent_schema ON parent.schema_id = parent_schema.schema_id " & _
			"WHERE child_schema.name = " & _SqlQuote($sSchema) & " AND parent_schema.name = " & _SqlQuote($sSchema)

	Local $rs = _SqlQuery($sSql)
	If @error Or Not IsObj($rs) Then
		_Warn("SQL FK dependency preflight: could not read target foreign keys. Continuing with selected tables only.")
		Return
	EndIf

	; Connection.Execute may return a forward-only cursor, so cache the dependency
	; pairs instead of relying on Recordset.MoveFirst for multiple passes.
	Local $sPairs = ""
	While Not $rs.EOF
		Local $sChild = String($rs.Fields("child_table").Value)
		Local $sParent = String($rs.Fields("parent_table").Value)
		If StringUpper($sChild) <> StringUpper($sParent) Then $sPairs &= $sChild & Chr(30) & $sParent & Chr(31)
		$rs.MoveNext()
	WEnd

	If $sPairs = "" Then Return

	Local $aPairs = StringSplit($sPairs, Chr(31), 2)
	Local $iTotalAdded = 0
	Local $iPass = 0
	Local $bAdded = True

	While $bAdded And $iPass < 25
		$bAdded = False
		$iPass += 1

		For $i = 0 To UBound($aPairs) - 1
			If $aPairs[$i] = "" Then ContinueLoop
			Local $aOne = StringSplit($aPairs[$i], Chr(30), 2)
			If UBound($aOne) < 2 Then ContinueLoop

			Local $sChild2 = $aOne[0]
			Local $sParent2 = $aOne[1]

			If _ArrayHasTable($aTables, $sChild2) And Not _ArrayHasTable($aTables, $sParent2) Then
				If _EnsureTableSelectedIfAvailable($aTables, $sSchema, $sParent2, "SQL FK parent required by selected table " & $sChild2) Then
					$iTotalAdded += 1
					$bAdded = True
				EndIf
			EndIf
		Next
	WEnd

	If $iPass >= 25 Then _Warn("SQL FK dependency preflight: stopped after 25 passes. Check for unusual FK recursion if more parent tables were expected.")
	If $iTotalAdded > 0 Then _Warn("SQL FK dependency preflight added " & $iTotalAdded & " parent table(s) required by selected FK child tables.")
EndFunc   ;==>_ExpandSqlForeignKeyParentTables

Func _ExpandOrtemsRequiredTables(ByRef $aTables, $sSchema)
	Local $iBefore = UBound($aTables)

	; Routing correspondence: B_GAMM is the routing/header table. B_PHAS and B_PREC
	; are routing phase/precedence details. Loading details without the routing header
	; causes FK failures and later WO phase inconsistencies.
	If _ArrayHasAnyTable($aTables, "B_PHAS|B_PREC|B_PREC_ETAP|B_PHM|B_PHMA") Then
		_EnsureTableSelectedIfAvailable($aTables, $sSchema, "B_GAMM", "required before routing phases/precedences")
	EndIf

	If _ArrayHasAnyTable($aTables, "B_PREC|B_PREC_ETAP") Then
		_EnsureTableSelectedIfAvailable($aTables, $sSchema, "B_PHAS", "required before routing precedences")
	EndIf

	; Current-plan WO correspondence. E_OF is the WO header; B_BT is the WO phase
	; table. BT_* and execution E_* tables hang from that chain.
	If _ArrayHasAnyTable($aTables, "E_OF|E_OF_VER|E_OF_TYPV|E_OF_E_OF|OF_TYPV|B_BT|BT_ART|BT_PARM|BT_PARMC|BT_LIMI|BT_QUAL|BT_QUAL_RS|BT_SER|BT_BT|E_COP|E_CPP|E_OPERAT|E_RSV_RES|E_REG|E_SER|E_NOME|E_ALIM_STOC|E_WO_DEPENDENCY") Then
		_EnsureTableSelectedIfAvailable($aTables, $sSchema, "E_OF", "required as current WO header")
		_EnsureTableSelectedIfAvailable($aTables, $sSchema, "B_BT", "required as current WO phase table for E_OF")
	EndIf

	; Scenario/simulation WO correspondence.
	If _ArrayHasAnyTable($aTables, "E_OF2|E_OF_VER2|E_OF_TYPV2|E_OF_E_OF2|B_BT2|BT_ART2|BT_PARM2|BT_PARMC2|BT_LIMI2|BT_QUAL2|BT_QUAL_RS2|BT_SER2|BT_BT2|E_COP2|E_CPP2|E_OPERAT2|E_RSV_RES2|E_REG2|E_SER2|E_NOME2|E_ALIM_STOC2|E_WO_DEPENDENCY2") Then
		_EnsureTableSelectedIfAvailable($aTables, $sSchema, "E_OF2", "required as scenario WO header")
		_EnsureTableSelectedIfAvailable($aTables, $sSchema, "B_BT2", "required as scenario WO phase table for E_OF2")
	EndIf

	If UBound($aTables) > $iBefore Then
		_Warn("Ortems dependency preflight added " & (UBound($aTables) - $iBefore) & " required related table(s) to the import selection.")
	EndIf
EndFunc   ;==>_ExpandOrtemsRequiredTables

Func _EnsureTableSelectedIfAvailable(ByRef $aTables, $sSchema, $sTable, $sReason)
	If _ArrayHasTable($aTables, $sTable) Then Return True

	If Not _FirebirdTableExists($sTable) Then
		_Warn("Ortems dependency preflight: source table " & $sTable & " was expected but does not exist in Firebird; reason: " & $sReason & ".")
		Return False
	EndIf

	If Not _TargetTableExists($sSchema, $sTable) Then
		_Warn("Ortems dependency preflight: target table " & $sTable & " was expected but does not exist in SQL Server; reason: " & $sReason & ".")
		Return False
	EndIf

	_Append1D($aTables, $sTable)
	_Warn("Ortems dependency preflight: auto-selected table " & $sTable & " because it is " & $sReason & ".")
	Return True
EndFunc   ;==>_EnsureTableSelectedIfAvailable

Func _ArrayHasAnyTable(ByRef $aTables, $sPipeList)
	Local $a = StringSplit($sPipeList, "|", 2)
	For $i = 0 To UBound($a) - 1
		If _ArrayHasTable($aTables, $a[$i]) Then Return True
	Next
	Return False
EndFunc   ;==>_ArrayHasAnyTable

Func _ArrayHasTable(ByRef $aTables, $sTable)
	Local $sNeed = StringUpper(StringStripWS($sTable, 3))
	For $i = 0 To UBound($aTables) - 1
		If StringUpper(StringStripWS($aTables[$i], 3)) = $sNeed Then Return True
	Next
	Return False
EndFunc   ;==>_ArrayHasTable

Func _FirebirdTableExists($sTable)
	Local $sSql = "SELECT 1 AS X FROM rdb$relations WHERE rdb$system_flag = 0 AND rdb$view_blr IS NULL AND rdb$relation_name = '" & StringUpper(StringReplace($sTable, "'", "''")) & "'"
	Local $rs = _FbQuery($sSql, "metadata/list")
	If @error Or Not IsObj($rs) Then Return False
	If $rs.EOF Then Return False
	Return True
EndFunc   ;==>_FirebirdTableExists

Func _FirebirdColumnExists($sTable, $sColumn)
	Local $aCols = _GetFirebirdColumns($sTable)
	If @error Then Return False
	For $i = 0 To UBound($aCols) - 1
		If StringUpper(String($aCols[$i][0])) = StringUpper($sColumn) Then Return True
	Next
	Return False
EndFunc   ;==>_FirebirdColumnExists

Func _BuildOrtemsSourceOrphanLists()
	ReDim $g_aOrtemsSourceOrphanWOs[0]
	ReDim $g_aOrtemsSourceOrphanWOs2[0]

	If _FirebirdTableExists("E_OF") And _FirebirdTableExists("B_BT") And _FirebirdColumnExists("E_OF", "E_NOF") And _FirebirdColumnExists("B_BT", "E_NOF") Then
		Local $sPhaseCol = ""
		If _FirebirdColumnExists("B_BT", "BT_NOPHASE") Then $sPhaseCol = "BT_NOPHASE"
		$g_aOrtemsSourceOrphanWOs = _GetFirebirdOrphanWoIds("E_OF", "E_NOF", "B_BT", "E_NOF", $sPhaseCol)
		If UBound($g_aOrtemsSourceOrphanWOs) > 0 Then
			_Warn("Ortems preflight: Firebird contains " & UBound($g_aOrtemsSourceOrphanWOs) & " current WO header(s) in E_OF with no valid phase in B_BT. These WO chains will be skipped during import to prevent PL_0170.")
			For $i = 0 To UBound($g_aOrtemsSourceOrphanWOs) - 1
				_Warn("Ortems preflight orphan current WO: " & $g_aOrtemsSourceOrphanWOs[$i])
			Next
		Else
			_Log("Ortems preflight: E_OF/B_BT source correspondence OK.")
		EndIf
	Else
		_Warn("Ortems preflight: E_OF/B_BT source correspondence could not be fully validated because one table or key column is missing.")
	EndIf

	If _FirebirdTableExists("E_OF2") And _FirebirdTableExists("B_BT2") And _FirebirdColumnExists("E_OF2", "E_NOF2") And _FirebirdColumnExists("B_BT2", "E_NOF2") Then
		Local $sPhaseCol2 = ""
		If _FirebirdColumnExists("B_BT2", "BT_NOPHASE2") Then $sPhaseCol2 = "BT_NOPHASE2"
		$g_aOrtemsSourceOrphanWOs2 = _GetFirebirdOrphanWoIds("E_OF2", "E_NOF2", "B_BT2", "E_NOF2", $sPhaseCol2)
		If UBound($g_aOrtemsSourceOrphanWOs2) > 0 Then
			_Warn("Ortems preflight: Firebird contains " & UBound($g_aOrtemsSourceOrphanWOs2) & " scenario WO header(s) in E_OF2 with no valid phase in B_BT2. These WO chains will be skipped during import to prevent PL_0170.")
			For $i = 0 To UBound($g_aOrtemsSourceOrphanWOs2) - 1
				_Warn("Ortems preflight orphan scenario WO: " & $g_aOrtemsSourceOrphanWOs2[$i])
			Next
		Else
			_Log("Ortems preflight: E_OF2/B_BT2 source correspondence OK.")
		EndIf
	Else
		_Log("Ortems preflight: E_OF2/B_BT2 source correspondence was not applicable or could not be fully validated.")
	EndIf
EndFunc   ;==>_BuildOrtemsSourceOrphanLists

Func _GetFirebirdOrphanWoIds($sHeaderTable, $sHeaderCol, $sPhaseTable, $sPhaseCol, $sPhaseNoCol)
	Local $a[0]
	Local $sPhaseFilter = ""
	If $sPhaseNoCol <> "" Then
		$sPhaseFilter = " AND p." & $sPhaseNoCol & " IS NOT NULL AND TRIM(CAST(p." & $sPhaseNoCol & " AS VARCHAR(255))) <> '' "
	EndIf

	Local $sSql = "SELECT DISTINCT CAST(h." & $sHeaderCol & " AS VARCHAR(255)) AS WO_ID " & _
			"FROM " & $sHeaderTable & " h " & _
			"WHERE h." & $sHeaderCol & " IS NOT NULL " & _
			"AND TRIM(CAST(h." & $sHeaderCol & " AS VARCHAR(255))) <> '' " & _
			"AND NOT EXISTS (SELECT 1 FROM " & $sPhaseTable & " p WHERE p." & $sPhaseCol & " IS NOT NULL " & _
			"AND TRIM(CAST(p." & $sPhaseCol & " AS VARCHAR(255))) = TRIM(CAST(h." & $sHeaderCol & " AS VARCHAR(255)))" & $sPhaseFilter & ") " & _
			"ORDER BY 1"

	Local $rs = _FbQuery($sSql, "metadata/list")
	If @error Or Not IsObj($rs) Then
		_Warn("Ortems preflight: failed to validate source WO header/phase correspondence with SQL: " & _Shorten($sSql, 600))
		Return $a
	EndIf

	While Not $rs.EOF
		_AppendUniqueText($a, StringStripWS(String($rs.Fields("WO_ID").Value), 3))
		$rs.MoveNext()
	WEnd
	Return $a
EndFunc   ;==>_GetFirebirdOrphanWoIds

Func _ShouldSkipOrtemsSourceOrphanRow($sTable, $rs, ByRef $aCols)
	If Not $g_bOrtemsStartupSanitizer Then Return False

	Local $sTableU = _NormalizeTableName($sTable)

	If UBound($g_aOrtemsSourceOrphanWOs) > 0 Then
		Local $aCurrentCols[8] = ["E_NOF", "NOF", "BT_NOF", "OF_NOF", "WO_ID", "WOID", "ID_OF", "E_WO"]
		Local $sCol = _FindImportColumnName($aCols, $aCurrentCols)
		If $sCol <> "" Then
			Local $sWo = StringStripWS(String($rs.Fields($sCol).Value), 3)
			If _ArrayContainsTextCI($g_aOrtemsSourceOrphanWOs, $sWo) Then
				_Warn("Ortems preflight skip: table " & $sTable & " row belongs to orphan current WO " & $sWo & " and was not imported.")
				Return True
			EndIf
		EndIf
	EndIf

	If UBound($g_aOrtemsSourceOrphanWOs2) > 0 Then
		Local $aScenarioCols[8] = ["E_NOF2", "NOF2", "BT_NOF2", "OF_NOF2", "WO_ID2", "WOID2", "ID_OF2", "E_WO2"]
		Local $sCol2 = _FindImportColumnName($aCols, $aScenarioCols)
		If $sCol2 <> "" Then
			Local $sWo2 = StringStripWS(String($rs.Fields($sCol2).Value), 3)
			If _ArrayContainsTextCI($g_aOrtemsSourceOrphanWOs2, $sWo2) Then
				_Warn("Ortems preflight skip: table " & $sTable & " row belongs to orphan scenario WO " & $sWo2 & " and was not imported.")
				Return True
			EndIf
		EndIf
	EndIf

	Return False
EndFunc   ;==>_ShouldSkipOrtemsSourceOrphanRow

Func _FindImportColumnName(ByRef $aCols, ByRef $aCandidates)
	For $c = 0 To UBound($aCandidates) - 1
		For $i = 0 To UBound($aCols) - 1
			If StringUpper(String($aCols[$i][0])) = StringUpper(String($aCandidates[$c])) Then Return String($aCols[$i][0])
		Next
	Next
	Return ""
EndFunc   ;==>_FindImportColumnName

Func _ArrayContainsTextCI(ByRef $aVals, $sVal)
	Local $s = StringUpper(StringStripWS(String($sVal), 3))
	If $s = "" Then Return False
	For $i = 0 To UBound($aVals) - 1
		If StringUpper(StringStripWS(String($aVals[$i]), 3)) = $s Then Return True
	Next
	Return False
EndFunc   ;==>_ArrayContainsTextCI

Func _ApplyOrtemsSemanticOrder(ByRef $aTables)
	If UBound($aTables) = 0 Then Return $aTables

	Local $aOut[UBound($aTables)]
	For $i = 0 To UBound($aTables) - 1
		$aOut[$i] = $aTables[$i]
	Next

	Local $n = UBound($aOut)
	For $i = 0 To $n - 2
		For $c = $i + 1 To $n - 1
			If _GetOrtemsSemanticRank($aOut[$c]) < _GetOrtemsSemanticRank($aOut[$i]) Then
				Local $tmp = $aOut[$i]
				$aOut[$i] = $aOut[$c]
				$aOut[$c] = $tmp
			EndIf
		Next
	Next

	_Log("Table order adjusted using Ortems semantic dependencies. SQL FK ordering will be applied afterwards to preserve parent-before-child constraints.")
	Return $aOut
EndFunc   ;==>_ApplyOrtemsSemanticOrder

Func _GetOrtemsSemanticRank($sTable)
	Local $t = _NormalizeTableName($sTable)

	Switch $t
		Case "ENCOURS"
			Return 10
		Case "VERSION", "SYS_LOCK", "SYS_TRACEUSER", "USER_TRACE", "REPORT_TYPES", "REPORTS", "REPORT_PARAMS", "REPORT_QUERIES", "REPORTS_TEMPLATES"
			Return 12
		Case "BUSINESS_CONFIG"
			Return 15
		Case "B_GAMM", "B_BIBL_GAMM", "B_MACRO_GAMM"
			Return 40
		Case "B_PHAS", "B_PHMA", "B_PHM"
			Return 45
		Case "B_PREC", "B_PREC_ETAP", "B_PREN", "B_PREN2"
			Return 48
		Case "E_OF", "E_OF_TYPV", "E_OF_VER", "E_OF_E_OF", "OF_TYPV"
			Return 60
		Case "E_OF2", "E_OF_TYPV2", "E_OF_VER2", "E_OF_E_OF2"
			Return 61
		Case "B_BT"
			Return 70
		Case "B_BT2"
			Return 71
		Case "BT_ART", "BT_PARM", "BT_PARMC", "BT_LIMI", "BT_QUAL", "BT_QUAL_RS", "BT_SER", "BT_BT"
			Return 80
		Case "BT_ART2", "BT_PARM2", "BT_PARMC2", "BT_LIMI2", "BT_QUAL2", "BT_QUAL_RS2", "BT_SER2", "BT_BT2"
			Return 81
		Case "E_COP", "E_CPP", "E_OPERAT", "E_RSV_RES", "E_REG", "E_SER", "E_NOME", "E_ALIM_STOC", "E_WO_DEPENDENCY", "B_WO_DEPENDENCY"
			Return 90
		Case "E_COP2", "E_CPP2", "E_OPERAT2", "E_RSV_RES2", "E_REG2", "E_SER2", "E_NOME2", "E_ALIM_STOC2", "E_WO_DEPENDENCY2"
			Return 91
	EndSwitch

	If StringLeft($t, 2) = "B_" Then Return 30
	If StringLeft($t, 2) = "P_" Then Return 30
	If StringLeft($t, 2) = "I_" Then Return 30
	If StringLeft($t, 4) = "BT_" Then Return 85
	If StringLeft($t, 2) = "E_" Then Return 95

	Return 50
EndFunc   ;==>_GetOrtemsSemanticRank


; -----------------------------
; Ortems startup sanitizer / diagnostics
; -----------------------------
Func _NormalizeTableName($sTable)
	Return StringUpper(StringStripWS(String($sTable), 3))
EndFunc   ;==>_NormalizeTableName

Func _IsOrtemsStartupUnsafeWholeTable($sTable)
	If Not $g_bOrtemsStartupSanitizer Then Return False

	; B_DT is reported by Ortems as the failing WIP detail table (PL_0445).
	; In practice this behaves like runtime/WIP detail data. Copying it directly from
	; Firebird into SQL Server can make Ortems fail while recalling WIP, even when
	; SQL Server constraints accept the rows.
	If _NormalizeTableName($sTable) = "B_DT" Then Return True

	Return False
EndFunc   ;==>_IsOrtemsStartupUnsafeWholeTable

Func _ShouldQuarantineOrtemsStartupRow($sTable, $rs, ByRef $aCols)
	If Not $g_bOrtemsStartupSanitizer Then Return False

	Local $sTableU = _NormalizeTableName($sTable)
	Local $sRowText = _BuildRowSearchText($rs, $aCols)

	; PL_0451: Error reading B_STOC / Invalid inventory movement data.
	; The Ortems dialogs identified FORGED RING and PACKAGING as the bad movement details.
	If $sTableU = "B_STOC" Then
		If StringInStr($sRowText, "FORGED RING") Or StringInStr($sRowText, "PACKAGING") Then
			_Warn("Ortems startup sanitizer: quarantined B_STOC row that matches PL_0451 invalid inventory movement detail. Row=" & _BuildRowDebugText($rs, $aCols, 1200))
			Return True
		EndIf
	EndIf

	; PL_0170 is not handled by blind text-token quarantine. A WO header can be
	; valid only if its phases exist. Skipping random rows that contain the WO number
	; can create the exact E_OF/B_BT inconsistency that makes Ortems close at startup.
	; The PL_0170 guard runs after the load and removes only complete orphan WO chains
	; detected through E_OF -> B_BT and E_OF2 -> B_BT2 relationships.

	Return False
EndFunc   ;==>_ShouldQuarantineOrtemsStartupRow

Func _BuildRowSearchText($rs, ByRef $aCols)
	Local $s = ""
	For $i = 0 To UBound($aCols) - 1
		Local $v = ""
		If IsObj($rs) Then
			Local $raw = _GetImportColumnValue($rs, $aCols, $i)
			If _IsNull($raw) Then
				$v = ""
			ElseIf IsObj($raw) Then
				$v = "<OBJECT>"
			ElseIf VarGetType($raw) = "Binary" Then
				$v = _BinaryToTextSafe($raw)
			Else
				$v = String($raw)
			EndIf
		EndIf
		$s &= "|" & StringUpper($v)
	Next
	Return $s
EndFunc   ;==>_BuildRowSearchText

Func _BuildRowDebugText($rs, ByRef $aCols, $iMax)
	Local $s = ""
	For $i = 0 To UBound($aCols) - 1
		Local $sCol = $aCols[$i][0]
		Local $sVal = ""
		Local $raw = _GetImportColumnValue($rs, $aCols, $i)

		If _IsNull($raw) Then
			$sVal = "<NULL>"
		ElseIf IsObj($raw) Then
			$sVal = "<OBJECT/BLOB>"
		ElseIf VarGetType($raw) = "Binary" Then
			$sVal = "<BINARY> " & _Shorten(_BinaryToTextSafe($raw), 120)
		Else
			$sVal = _Shorten(String($raw), 160)
		EndIf

		If $s <> "" Then $s &= " | "
		$s &= $sCol & "=" & $sVal
		If StringLen($s) >= $iMax Then Return _Shorten($s, $iMax)
	Next
	Return _Shorten($s, $iMax)
EndFunc   ;==>_BuildRowDebugText

Func _ApplyOrtemsStartupSanitizerCleanup($sSchema, ByRef $aTables)
	If Not $g_bOrtemsStartupSanitizer Then Return True

	_Log("Running Ortems startup sanitizer cleanup on target data.")

	Local $bOk = True

	; PL_0451 cleanup: remove the specific invalid B_STOC movement rows already identified by Ortems.
	Local $aStockTokens[2]
	$aStockTokens[0] = "FORGED RING"
	$aStockTokens[1] = "PACKAGING"
	If _TargetTableExists($sSchema, "B_STOC") Then
		If Not _DeleteRowsContainingAnyText($sSchema, "B_STOC", $aStockTokens, "PL_0451 invalid B_STOC inventory movement") Then $bOk = False
	EndIf

	; PL_0445 cleanup: B_DT caused WIP recall failure. Keep target free of copied B_DT rows.
	If _TargetTableExists($sSchema, "B_DT") Then
		_Log("Ortems startup sanitizer cleanup: clearing [" & $sSchema & "].[B_DT] to avoid PL_0445 WIP recall errors.")
		Local $nativeBDt = _SqlExec("DELETE FROM [" & $sSchema & "].[B_DT];", False, True)
		If @error Or $g_bLastSqlExecFailed Then
			_Warn("Could not clear [" & $sSchema & "].[B_DT]. PL_0445 may still appear when Ortems recalls WIP.")
			$bOk = False
		EndIf
	EndIf

	; PL_0170 cleanup: Ortems closes when a WO header exists without any WO phase.
	; Validate and quarantine complete orphan WO chains using key columns, not blind text
	; matching. This avoids removing unrelated configuration rows that merely contain
	; the WO number inside saved views, layouts, blobs, or comments.
	If Not _FixOrtemsOrphanWOs($sSchema, $aTables) Then $bOk = False

	; PL_0439 cleanup: Ortems fails on startup when an export/date-format
	; parameter contains an invalid text value. SQL Server can populate DEFAULT
	; from a column default even when the Firebird source row had a blank value.
	; The Ortems export date-format value is parsed as a numeric code, not as
	; a textual pattern such as yyyy-MM-dd.
	If Not _FixOrtemsExportDateFormatDefaults($sSchema, $aTables) Then $bOk = False

	If $bOk Then
		_Log("Ortems startup sanitizer cleanup completed.")
	Else
		_Warn("Ortems startup sanitizer cleanup completed with warnings. Review the log before opening Ortems.")
	EndIf

	Return $bOk
EndFunc   ;==>_ApplyOrtemsStartupSanitizerCleanup


Func _FixOrtemsExportDateFormatDefaults($sSchema, ByRef $aTables)
	; Keep this tied to Ortems-safe mode, but make the PL_0439 scan much broader than
	; the previous version. The earlier guard only repaired rows that explicitly looked
	; like date-format parameters. In some Ortems databases the export parameter row only
	; carries a generic value column with an invalid text value, so the application
	; still failed on startup with: Invalid date format: DEFAULT. A previous repair
	; attempted to write yyyy-MM-dd, but Ortems parses this parameter as an integer
	; date-format code, which produced: 'yyyy' is not a valid integer value.
	If Not $g_bOrtemsStartupSanitizer Then Return True

	Local $aCandidateTables = _BuildOrtemsExportParameterTableList($sSchema, $aTables)
	If UBound($aCandidateTables) = 0 Then Return True

	_Log("Ortems PL_0439 guard: scanning all target text columns for invalid export date-format values DEFAULT/yyyy-MM-dd. Ortems expects a numeric date-format code here.")

	Local $bOk = True
	Local $iExactDefaultOccurrences = 0
	Local $iDiagnosticsLogged = 0
	Local $iMaxDiagnostics = 60

	For $i = 0 To UBound($aCandidateTables) - 1
		Local $sTable = $aCandidateTables[$i]
		If Not _TargetTableExists($sSchema, $sTable) Then ContinueLoop

		Local $aTextCols = _GetTargetTextColumns($sSchema, $sTable)
		If UBound($aTextCols) = 0 Then ContinueLoop

		Local $sRowTextExpr = _BuildTargetTextExpression($aTextCols)
		For $c = 0 To UBound($aTextCols) - 1
			Local $sCol = $aTextCols[$c]
			Local $sInvalidDateFormatValue = _BuildOrtemsPL0439BadValuePredicate($sCol)

			Local $sCountAnySql = "SELECT COUNT(1) AS CNT FROM [" & $sSchema & "].[" & $sTable & "] WHERE " & $sInvalidDateFormatValue
			Local $rsAny = _SqlQuery($sCountAnySql, False)
			If @error Or Not IsObj($rsAny) Then
				_Warn("Ortems PL_0439 guard: could not inspect [" & $sSchema & "].[" & $sTable & "].[" & $sCol & "] for invalid PL_0439 date-format text values.")
				$bOk = False
				ContinueLoop
			EndIf
			If $rsAny.EOF Then ContinueLoop

			Local $iAnyMatches = Int($rsAny.Fields("CNT").Value)
			If $iAnyMatches <= 0 Then ContinueLoop

			$iExactDefaultOccurrences += $iAnyMatches
			If $iDiagnosticsLogged < $iMaxDiagnostics Then
				_Log("Ortems PL_0439 diagnostic: found " & $iAnyMatches & " invalid PL_0439 date-format text value(s) in [" & $sSchema & "].[" & $sTable & "].[" & $sCol & "].")
				_LogOrtemsDefaultSamples($sSchema, $sTable, $sCol, $sInvalidDateFormatValue, $sRowTextExpr)
				$iDiagnosticsLogged += 1
			EndIf

			Local $sScope = _BuildOrtemsPL0439RepairPredicate($sTable, $sCol, $sRowTextExpr)
			If $sScope = "" Then ContinueLoop

			Local $sWhere = $sInvalidDateFormatValue & " AND (" & $sScope & ")"
			Local $sCountSql = "SELECT COUNT(1) AS CNT FROM [" & $sSchema & "].[" & $sTable & "] WHERE " & $sWhere
			Local $rsCount = _SqlQuery($sCountSql, False)
			If @error Or Not IsObj($rsCount) Then
				_Warn("Ortems PL_0439 guard: could not validate repair scope for [" & $sSchema & "].[" & $sTable & "].[" & $sCol & "].")
				$bOk = False
				ContinueLoop
			EndIf
			If $rsCount.EOF Then ContinueLoop

			Local $iMatches = Int($rsCount.Fields("CNT").Value)
			If $iMatches <= 0 Then ContinueLoop

			Local $sRepairValue = _GetOrtemsPL0439RepairValue($sTable, $sCol)
			Local $sUpdateSql = "UPDATE [" & $sSchema & "].[" & $sTable & "] SET [" & $sCol & "] = N'" & StringReplace($sRepairValue, "'", "''") & "' WHERE " & $sWhere
			_Log("Ortems PL_0439 guard: repairing " & $iMatches & " invalid export/date-format value(s) in [" & $sSchema & "].[" & $sTable & "].[" & $sCol & "] to numeric code " & $sRepairValue & ".")

			Local $native = _SqlExec($sUpdateSql, False, True)
			If @error Or $g_bLastSqlExecFailed Then
				_Warn("Ortems PL_0439 guard: failed to repair invalid export/date-format values in [" & $sSchema & "].[" & $sTable & "].[" & $sCol & "].")
				$bOk = False
			Else
				$g_iOrtemsExportDateFormatFixups += $iMatches
			EndIf
		Next
	Next

	If $iExactDefaultOccurrences > 0 Then
		_Log("Ortems PL_0439 diagnostic: total invalid PL_0439 date-format text values found in target schema: " & $iExactDefaultOccurrences & ".")
	Else
		_Log("Ortems PL_0439 diagnostic: no invalid PL_0439 date-format text values found in scanned target text columns.")
	EndIf

	If $g_iOrtemsExportDateFormatFixups > 0 Then
		_Log("Ortems PL_0439 guard: repaired " & $g_iOrtemsExportDateFormatFixups & " invalid export/date-format value(s).")
	ElseIf $iExactDefaultOccurrences > 0 Then
		_Warn("Ortems PL_0439 guard: invalid PL_0439 date-format text values were found, but none matched the automatic repair rules. Send this log so the exact table/column can be mapped safely.")
	EndIf

	Return $bOk
EndFunc   ;==>_FixOrtemsExportDateFormatDefaults

Func _BuildOrtemsExportParameterTableList($sSchema, ByRef $aSelectedTables)
	Local $aOut[0]

	; Start with selected tables because those are the ones most likely to have been
	; modified during this run.
	For $i = 0 To UBound($aSelectedTables) - 1
		_AppendUniqueText($aOut, $aSelectedTables[$i])
	Next

	; Add every SQL Server table containing text columns. PL_0439 only exposes the bad
	; value, not the table name. A broad post-import scan gives us both a repair attempt
	; and a useful diagnostic trail in the log.
	Local $sSql = "SELECT DISTINCT t.name AS TABLE_NAME " & _
			"FROM sys.tables t " & _
			"JOIN sys.schemas s ON t.schema_id = s.schema_id " & _
			"JOIN sys.columns c ON t.object_id = c.object_id " & _
			"JOIN sys.types ty ON c.user_type_id = ty.user_type_id " & _
			"WHERE s.name = " & _SqlQuote($sSchema) & _
			" AND ty.name IN ('char','nchar','varchar','nvarchar','text','ntext','uniqueidentifier') " & _
			"ORDER BY t.name"

	Local $rs = _SqlQuery($sSql, False)
	If @error Or Not IsObj($rs) Then Return $aOut

	While Not $rs.EOF
		_AppendUniqueText($aOut, String($rs.Fields("TABLE_NAME").Value))
		$rs.MoveNext()
	WEnd

	Return $aOut
EndFunc   ;==>_BuildOrtemsExportParameterTableList


Func _BuildOrtemsDateFormatRowPredicate($sTable, $sCol, $sRowTextExpr)
	; SQL predicate used by the PL_0439 guard to identify rows that are likely
	; storing date-format/date-mask export parameters. The table/column arguments
	; are intentionally kept in the signature for diagnostics/future tuning.
	Local $sUpperRow = "UPPER(" & $sRowTextExpr & ")"

	Local $sPredicate = ""
	$sPredicate &= "(" & $sUpperRow & " LIKE N'%DATE%' AND (" & _
			$sUpperRow & " LIKE N'%FORMAT%' OR " & _
			$sUpperRow & " LIKE N'%FMT%' OR " & _
			$sUpperRow & " LIKE N'%MASK%' OR " & _
			$sUpperRow & " LIKE N'%PATTERN%'))"

	$sPredicate &= " OR (" & $sUpperRow & " LIKE N'%DAT%' AND (" & _
			$sUpperRow & " LIKE N'%FORMAT%' OR " & _
			$sUpperRow & " LIKE N'%FMT%' OR " & _
			$sUpperRow & " LIKE N'%MASK%'))"

	$sPredicate &= " OR " & $sUpperRow & " LIKE N'%DATE_FORMAT%'"
	$sPredicate &= " OR " & $sUpperRow & " LIKE N'%FORMAT_DATE%'"
	$sPredicate &= " OR " & $sUpperRow & " LIKE N'%DATE-FORMAT%'"
	$sPredicate &= " OR " & $sUpperRow & " LIKE N'%FORMAT-DATE%'"
	$sPredicate &= " OR " & $sUpperRow & " LIKE N'%DATE MASK%'"
	$sPredicate &= " OR " & $sUpperRow & " LIKE N'%DATE_MASK%'"
	$sPredicate &= " OR " & $sUpperRow & " LIKE N'%MASK_DATE%'"
	$sPredicate &= " OR " & $sUpperRow & " LIKE N'%DATEFMT%'"
	$sPredicate &= " OR " & $sUpperRow & " LIKE N'%FMTDATE%'"

	Return "(" & $sPredicate & ")"
EndFunc   ;==>_BuildOrtemsDateFormatRowPredicate

Func _BuildOrtemsPL0439RepairPredicate($sTable, $sCol, $sRowTextExpr)
	Local $sTableU = StringUpper(String($sTable))
	Local $sColU = StringUpper(String($sCol))
	Local $sUpperRow = "UPPER(" & $sRowTextExpr & ")"

	Local $bTableExportRelated = _OrtemsNameContainsAny($sTableU, "EXP|EXPORT")
	Local $bTableParamRelated = _OrtemsNameContainsAny($sTableU, "PARAM|PARM|PREF|OPTION|SETTING|CONFIG|CFG|USER|UTIL|ETAT|REPORT")
	Local $bColumnDateFormat = _OrtemsNameLooksDateFormat($sColU)
	Local $bColumnGenericValue = _OrtemsNameLooksGenericParameterValueColumn($sColU)
	Local $bColumnFormatRelated = _OrtemsNameContainsAny($sColU, "FORMAT|FMT|MASK|PATTERN")

	Local $sRowLooksDateFormat = _BuildOrtemsDateFormatRowPredicate($sTable, $sCol, $sRowTextExpr)
	Local $sRowMentionsExport = "(" & $sUpperRow & " LIKE N'%EXPORT%' OR " & $sUpperRow & " LIKE N'%EXP_%' OR " & $sUpperRow & " LIKE N'%EXP-%')"

	; Strong evidence: the column itself is a date-format/date-mask field.
	If $bColumnDateFormat Then Return "1=1"

	; Practical PL_0439 fix: in export tables, generic parameter/value columns that
	; contain exactly DEFAULT are likely the values Ortems is trying to parse as export
	; parameters. This is intentionally broader than the previous fix.
	If $bTableExportRelated And ($bColumnGenericValue Or $bColumnFormatRelated) Then Return "1=1"

	; Configuration/parameter tables: repair only when the row text points to date format
	; or export configuration.
	If $bTableParamRelated And ($bColumnGenericValue Or $bColumnFormatRelated) Then
		Return "(" & $sRowLooksDateFormat & " OR " & $sRowMentionsExport & ")"
	EndIf

	; Last safe path: if any row clearly says date format/date mask, repair that row only.
	Return $sRowLooksDateFormat
EndFunc   ;==>_BuildOrtemsPL0439RepairPredicate

Func _BuildOrtemsPL0439BadValuePredicate($sCol)
	; Match both the original bad value (DEFAULT) and the previous textual repair
	; value (yyyy-MM-dd). Ortems parses the affected export date-format parameter
	; as an integer code, so both text values can still trigger PL_0439.
	Local $sVal = "UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(4000), [" & $sCol & "]))))"
	Return "(" & $sVal & " = N'DEFAULT' OR " & $sVal & " = N'YYYY-MM-DD')"
EndFunc   ;==>_BuildOrtemsPL0439BadValuePredicate

Func _GetOrtemsPL0439RepairValue($sTable, $sCol)
	; Ortems export parameters store this date-format setting as a numeric code.
	; Code 0 lets Ortems use the default/system date format instead of trying to
	; parse a textual mask. This prevents both observed PL_0439 variants:
	;   Invalid date format: DEFAULT
	;   'yyyy' is not a valid integer value
	Return $g_sOrtemsDefaultExportDateFormat
EndFunc   ;==>_GetOrtemsPL0439RepairValue

Func _LogOrtemsDefaultSamples($sSchema, $sTable, $sCol, $sExactDefault, $sRowTextExpr)
	Local $sSql = "SELECT TOP 3 LEFT(REPLACE(REPLACE(CONVERT(NVARCHAR(MAX), " & $sRowTextExpr & "), CHAR(13), N' '), CHAR(10), N' '), 500) AS ROW_TEXT " & _
			"FROM [" & $sSchema & "].[" & $sTable & "] WHERE " & $sExactDefault
	Local $rs = _SqlQuery($sSql, False)
	If @error Or Not IsObj($rs) Then Return

	Local $iSample = 0
	While Not $rs.EOF And $iSample < 3
		Local $sText = ""
		If Not _IsNull($rs.Fields("ROW_TEXT").Value) Then $sText = String($rs.Fields("ROW_TEXT").Value)
		If $sText <> "" Then _Log("Ortems PL_0439 diagnostic sample [" & $sTable & "].[" & $sCol & "]: " & _Shorten($sText, 500))
		$iSample += 1
		$rs.MoveNext()
	WEnd
EndFunc   ;==>_LogOrtemsDefaultSamples

Func _OrtemsNameLooksGenericParameterValueColumn($sNameU)
	If $sNameU = "VALUE" Then Return True
	If $sNameU = "VALEUR" Then Return True
	If $sNameU = "VAL" Then Return True
	If $sNameU = "V" Then Return True
	If $sNameU = "PARAM_VALUE" Then Return True
	If $sNameU = "PARAMVALUE" Then Return True
	If $sNameU = "PARAM_VAL" Then Return True
	If $sNameU = "PARAMVAL" Then Return True
	If $sNameU = "DEFAULT_VALUE" Then Return True
	If $sNameU = "DEFAULTVALUE" Then Return True
	If StringInStr($sNameU, "VALUE") > 0 Then Return True
	If StringInStr($sNameU, "VALEUR") > 0 Then Return True
	If StringInStr($sNameU, "PARAM") > 0 And StringInStr($sNameU, "VAL") > 0 Then Return True
	Return False
EndFunc   ;==>_OrtemsNameLooksGenericParameterValueColumn

Func _OrtemsNameLooksDateFormat($sNameU)
	If StringInStr($sNameU, "DATE_FORMAT") > 0 Then Return True
	If StringInStr($sNameU, "FORMAT_DATE") > 0 Then Return True
	If StringInStr($sNameU, "DATEFMT") > 0 Then Return True
	If StringInStr($sNameU, "FMTDATE") > 0 Then Return True
	If StringInStr($sNameU, "DATE_FMT") > 0 Then Return True
	If StringInStr($sNameU, "FMT_DATE") > 0 Then Return True
	If StringInStr($sNameU, "DATE_MASK") > 0 Then Return True
	If StringInStr($sNameU, "MASK_DATE") > 0 Then Return True
	If StringInStr($sNameU, "DAT_FORMAT") > 0 Then Return True
	If StringInStr($sNameU, "FORMAT_DAT") > 0 Then Return True
	If StringInStr($sNameU, "DATE") > 0 And StringInStr($sNameU, "FORMAT") > 0 Then Return True
	If StringInStr($sNameU, "DATE") > 0 And StringInStr($sNameU, "FMT") > 0 Then Return True
	If StringInStr($sNameU, "DATE") > 0 And StringInStr($sNameU, "MASK") > 0 Then Return True
	If StringInStr($sNameU, "DAT") > 0 And StringInStr($sNameU, "FORMAT") > 0 Then Return True
	Return False
EndFunc   ;==>_OrtemsNameLooksDateFormat

Func _OrtemsNameContainsAny($sNameU, $sPipeList)
	Local $aTokens = StringSplit($sPipeList, "|", 2)
	For $i = 0 To UBound($aTokens) - 1
		If $aTokens[$i] = "" Then ContinueLoop
		If StringInStr($sNameU, $aTokens[$i]) > 0 Then Return True
	Next
	Return False
EndFunc   ;==>_OrtemsNameContainsAny


Func _FixOrtemsOrphanWOs($sSchema, ByRef $aTables)
	Local $aAllOrphans[0]
	Local $bOk = True

	; Validate current-plan WO headers/phases.
	Local $aEOfCols[4] = ["E_NOF", "NOF", "WO_ID", "ID_OF"]
	Local $aBBtCols[5] = ["E_NOF", "NOF", "BT_NOF", "WO_ID", "ID_OF"]
	Local $aBBtPhaseNoCols[5] = ["BT_NOPHASE", "NOPHASE", "NO_PHASE", "PHASE", "PHASE_ID"]
	If _TargetTableExists($sSchema, "E_OF") And _TargetTableExists($sSchema, "B_BT") Then
		Local $sHeaderCol = _FindTargetColumn($sSchema, "E_OF", $aEOfCols)
		Local $sPhaseCol = _FindTargetColumn($sSchema, "B_BT", $aBBtCols)
		Local $sPhaseNoCol = _FindTargetColumn($sSchema, "B_BT", $aBBtPhaseNoCols)
		If $sHeaderCol <> "" And $sPhaseCol <> "" Then
			Local $aOrphans = _GetOrphanWoIds($sSchema, "E_OF", $sHeaderCol, "B_BT", $sPhaseCol, $sPhaseNoCol)
			If UBound($aOrphans) > 0 Then
				_Warn("Ortems PL_0170 guard: found " & UBound($aOrphans) & " WO header(s) in E_OF without any valid phase in B_BT. These complete WO chains will be quarantined from the target database.")
				For $i = 0 To UBound($aOrphans) - 1
					_Warn("Ortems PL_0170 guard: orphan WO detected: " & $aOrphans[$i])
					_AppendUniqueText($aAllOrphans, $aOrphans[$i])
				Next
			EndIf
		Else
			_Warn("Ortems PL_0170 guard: could not validate E_OF/B_BT because expected WO key columns were not found.")
			$bOk = False
		EndIf
	EndIf

	; Validate scenario/simulation WO headers/phases when the paired tables exist.
	Local $aEOf2Cols[4] = ["E_NOF2", "E_NOF", "NOF2", "WO_ID"]
	Local $aBBt2Cols[5] = ["E_NOF2", "E_NOF", "NOF2", "BT_NOF2", "WO_ID"]
	Local $aBBt2PhaseNoCols[5] = ["BT_NOPHASE2", "BT_NOPHASE", "NOPHASE2", "NO_PHASE2", "PHASE_ID2"]
	If _TargetTableExists($sSchema, "E_OF2") And _TargetTableExists($sSchema, "B_BT2") Then
		Local $sHeaderCol2 = _FindTargetColumn($sSchema, "E_OF2", $aEOf2Cols)
		Local $sPhaseCol2 = _FindTargetColumn($sSchema, "B_BT2", $aBBt2Cols)
		Local $sPhaseNoCol2 = _FindTargetColumn($sSchema, "B_BT2", $aBBt2PhaseNoCols)
		If $sHeaderCol2 <> "" And $sPhaseCol2 <> "" Then
			Local $aOrphans2 = _GetOrphanWoIds($sSchema, "E_OF2", $sHeaderCol2, "B_BT2", $sPhaseCol2, $sPhaseNoCol2)
			If UBound($aOrphans2) > 0 Then
				_Warn("Ortems PL_0170 guard: found " & UBound($aOrphans2) & " WO header(s) in E_OF2 without any valid phase in B_BT2. These complete WO chains will be quarantined from the target database.")
				For $i = 0 To UBound($aOrphans2) - 1
					_Warn("Ortems PL_0170 guard: orphan scenario WO detected: " & $aOrphans2[$i])
					_AppendUniqueText($aAllOrphans, $aOrphans2[$i])
				Next
			EndIf
		Else
			_Warn("Ortems PL_0170 guard: could not validate E_OF2/B_BT2 because expected WO key columns were not found.")
			$bOk = False
		EndIf
	EndIf

	If UBound($aAllOrphans) = 0 Then
		_Log("Ortems PL_0170 guard: no WO headers without phases were found.")
		Return $bOk
	EndIf

	_Warn("Ortems PL_0170 guard: quarantining " & UBound($aAllOrphans) & " orphan WO ID(s) from WO-related tables. This prevents Ortems from closing on startup, but the source data should be corrected.")

	; FK order across Ortems WO detail tables is not trivial. Disable constraints only
	; for this targeted cleanup, then re-enable them immediately after the orphan rows
	; are removed. Triggers are already managed by the bulk-load option, but disabling
	; them here makes the cleanup deterministic even when this function is reused.
	Local $bConstraintsDisabled = _SetConstraintsForTables($aTables, $sSchema, False)
	If Not $bConstraintsDisabled Then
		_Warn("Ortems PL_0170 guard: could not disable constraints for orphan WO cleanup. Cleanup will still be attempted but may fail on child/parent order.")
		$bOk = False
	EndIf

	Local $bTriggersDisabled = _SetTriggersForTables($aTables, $sSchema, False)
	If Not $bTriggersDisabled Then
		_Warn("Ortems PL_0170 guard: could not disable triggers for orphan WO cleanup. Cleanup will still be attempted.")
		$bOk = False
	EndIf

	If Not _DeleteRowsByWoIds($sSchema, $aTables, $aAllOrphans) Then $bOk = False

	If Not _SetTriggersForTables($aTables, $sSchema, True) Then $bOk = False
	If Not _SetConstraintsForTables($aTables, $sSchema, True) Then $bOk = False

	Return $bOk
EndFunc   ;==>_FixOrtemsOrphanWOs

Func _GetOrphanWoIds($sSchema, $sHeaderTable, $sHeaderCol, $sPhaseTable, $sPhaseCol, $sPhaseNoCol)
	Local $a[0]
	Local $sPhaseFilter = ""
	If $sPhaseNoCol <> "" Then
		$sPhaseFilter = " AND p.[" & $sPhaseNoCol & "] IS NOT NULL AND LTRIM(RTRIM(CONVERT(NVARCHAR(255), p.[" & $sPhaseNoCol & "]))) <> N'' "
	EndIf

	Local $sHeaderExpr = "LTRIM(RTRIM(CONVERT(NVARCHAR(255), h.[" & $sHeaderCol & "])))"
	Local $sPhaseExpr = "LTRIM(RTRIM(CONVERT(NVARCHAR(255), p.[" & $sPhaseCol & "])))"

	Local $sSql = "SELECT DISTINCT " & $sHeaderExpr & " AS WO_ID " & _
			"FROM [" & $sSchema & "].[" & $sHeaderTable & "] h " & _
			"WHERE h.[" & $sHeaderCol & "] IS NOT NULL " & _
			"AND " & $sHeaderExpr & " <> N'' " & _
			"AND NOT EXISTS (SELECT 1 FROM [" & $sSchema & "].[" & $sPhaseTable & "] p WHERE p.[" & $sPhaseCol & "] IS NOT NULL " & _
			"AND " & $sPhaseExpr & " = " & $sHeaderExpr & $sPhaseFilter & ") " & _
			"ORDER BY " & $sHeaderExpr

	Local $rs = _SqlQuery($sSql, False)
	If @error Or Not IsObj($rs) Then Return $a

	While Not $rs.EOF
		Local $sWo = StringStripWS(String($rs.Fields("WO_ID").Value), 3)
		_AppendUniqueText($a, $sWo)
		$rs.MoveNext()
	WEnd
	Return $a
EndFunc   ;==>_GetOrphanWoIds

Func _AppendUniqueText(ByRef $a, $sVal)
	Local $s = String($sVal)
	If $s = "" Then Return

	For $i = 0 To UBound($a) - 1
		If StringUpper($a[$i]) = StringUpper($s) Then Return
	Next

	ReDim $a[UBound($a) + 1]
	$a[UBound($a) - 1] = $s
EndFunc   ;==>_AppendUniqueText

Func _DeleteRowsByWoIds($sSchema, ByRef $aTables, ByRef $aWoIds)
	If UBound($aWoIds) = 0 Then Return True

	Local $aWoCols[20] = ["E_NOF", "E_NOF2", "NOF", "NOF2", "BT_NOF", "BT_NOF2", "OF_NOF", "OF_NOF2", "WO_ID", "WO_ID2", "WOID", "WOID2", "ID_OF", "ID_OF2", "E_WO", "E_WO2", "NOF_OF", "NOF_OF2", "ORDER_NO", "ORDER_NO2"]
	Local $sInList = _BuildUnicodeInList($aWoIds)
	If $sInList = "" Then Return True

	Local $aCleanupTables = _BuildWoCleanupTableList($sSchema, $aTables, $aWoCols)
	Local $bOk = True

	For $i = 0 To UBound($aCleanupTables) - 1
		Local $sTable = $aCleanupTables[$i]
		If Not _TargetTableExists($sSchema, $sTable) Then ContinueLoop

		For $c = 0 To UBound($aWoCols) - 1
			Local $sCol = $aWoCols[$c]
			If Not _TargetColumnExists($sSchema, $sTable, $sCol) Then ContinueLoop

			Local $sSql = "DELETE FROM [" & $sSchema & "].[" & $sTable & "] WHERE LTRIM(RTRIM(CONVERT(NVARCHAR(255), [" & $sCol & "]))) IN (" & $sInList & ");"
			_Log("Ortems PL_0170 guard cleanup: deleting orphan WO-related rows from [" & $sSchema & "].[" & $sTable & "] using column [" & $sCol & "].")
			Local $native = _SqlExec($sSql, False, True)
			If @error Or $g_bLastSqlExecFailed Then
				_Warn("Ortems PL_0170 guard cleanup failed for [" & $sSchema & "].[" & $sTable & "] column [" & $sCol & "].")
				$bOk = False
			EndIf
		Next
	Next

	Return $bOk
EndFunc   ;==>_DeleteRowsByWoIds

Func _BuildWoCleanupTableList($sSchema, ByRef $aSelectedTables, ByRef $aWoCols)
	Local $aOut[0]

	For $i = 0 To UBound($aSelectedTables) - 1
		_AppendUniqueText($aOut, $aSelectedTables[$i])
	Next

	Local $sColList = ""
	For $i = 0 To UBound($aWoCols) - 1
		If $sColList <> "" Then $sColList &= ","
		$sColList &= _SqlQuote($aWoCols[$i])
	Next

	Local $sSql = "SELECT DISTINCT TABLE_NAME FROM INFORMATION_SCHEMA.COLUMNS " & _
			"WHERE TABLE_SCHEMA = " & _SqlQuote($sSchema) & " AND COLUMN_NAME IN (" & $sColList & ") ORDER BY TABLE_NAME"
	Local $rs = _SqlQuery($sSql, False)
	If @error Or Not IsObj($rs) Then Return $aOut

	While Not $rs.EOF
		_AppendUniqueText($aOut, String($rs.Fields("TABLE_NAME").Value))
		$rs.MoveNext()
	WEnd

	Return $aOut
EndFunc   ;==>_BuildWoCleanupTableList

Func _BuildUnicodeInList(ByRef $aVals)
	Local $s = ""
	For $i = 0 To UBound($aVals) - 1
		Local $sVal = StringStripWS(String($aVals[$i]), 3)
		If $sVal = "" Then ContinueLoop
		If $s <> "" Then $s &= ","
		$s &= "N'" & StringReplace($sVal, "'", "''") & "'"
	Next
	Return $s
EndFunc   ;==>_BuildUnicodeInList

Func _GetTargetTextColumns($sSchema, $sTable)
	Local $a[0]
	Local $sSql = "SELECT COLUMN_NAME " & _
			"FROM INFORMATION_SCHEMA.COLUMNS " & _
			"WHERE TABLE_SCHEMA = " & _SqlQuote($sSchema) & " AND TABLE_NAME = " & _SqlQuote($sTable) & _
			" AND DATA_TYPE IN ('char','nchar','varchar','nvarchar','text','ntext','uniqueidentifier') " & _
			"ORDER BY ORDINAL_POSITION"

	Local $rs = _SqlQuery($sSql, False)
	If @error Or Not IsObj($rs) Then Return $a

	While Not $rs.EOF
		ReDim $a[UBound($a) + 1]
		$a[UBound($a) - 1] = String($rs.Fields("COLUMN_NAME").Value)
		$rs.MoveNext()
	WEnd
	Return $a
EndFunc   ;==>_GetTargetTextColumns

Func _BuildTargetTextExpression(ByRef $aTextCols)
	Local $sExpr = ""
	For $i = 0 To UBound($aTextCols) - 1
		Local $sPart = "COALESCE(CONVERT(NVARCHAR(MAX),[" & $aTextCols[$i] & "]),N'')"
		If $sExpr <> "" Then $sExpr &= " + N'|' + "
		$sExpr &= $sPart
	Next
	Return $sExpr
EndFunc   ;==>_BuildTargetTextExpression

Func _DeleteRowsContainingAnyText($sSchema, $sTable, ByRef $aTokens, $sReason)
	Local $aTextCols = _GetTargetTextColumns($sSchema, $sTable)
	If UBound($aTextCols) = 0 Then Return True

	Local $sExpr = _BuildTargetTextExpression($aTextCols)
	Local $sWhere = ""
	For $i = 0 To UBound($aTokens) - 1
		If $sWhere <> "" Then $sWhere &= " OR "
		$sWhere &= "(" & $sExpr & " LIKE N'%" & _SqlLikeToken($aTokens[$i]) & "%')"
	Next

	Local $sSql = "DELETE FROM [" & $sSchema & "].[" & $sTable & "] WHERE " & $sWhere & ";"
	_Log("Ortems startup sanitizer cleanup: deleting rows from [" & $sSchema & "].[" & $sTable & "] for " & $sReason & ".")
	Local $native = _SqlExec($sSql, False, True)
	If @error Or $g_bLastSqlExecFailed Then
		_Warn("Cleanup failed for [" & $sSchema & "].[" & $sTable & "] - " & $sReason)
		Return False
	EndIf
	Return True
EndFunc   ;==>_DeleteRowsContainingAnyText

Func _DeleteRowsContainingAllText($sSchema, $sTable, ByRef $aTokens, $sReason)
	Local $aTextCols = _GetTargetTextColumns($sSchema, $sTable)
	If UBound($aTextCols) = 0 Then Return True

	Local $sExpr = _BuildTargetTextExpression($aTextCols)
	Local $sWhere = ""
	For $i = 0 To UBound($aTokens) - 1
		If $sWhere <> "" Then $sWhere &= " AND "
		$sWhere &= "(" & $sExpr & " LIKE N'%" & _SqlLikeToken($aTokens[$i]) & "%')"
	Next

	Local $sSql = "DELETE FROM [" & $sSchema & "].[" & $sTable & "] WHERE " & $sWhere & ";"
	_Log("Ortems startup sanitizer cleanup: deleting rows from [" & $sSchema & "].[" & $sTable & "] for " & $sReason & ".")
	Local $native = _SqlExec($sSql, False, True)
	If @error Or $g_bLastSqlExecFailed Then
		_Warn("Cleanup failed for [" & $sSchema & "].[" & $sTable & "] - " & $sReason)
		Return False
	EndIf
	Return True
EndFunc   ;==>_DeleteRowsContainingAllText

Func _SqlLikeToken($sVal)
	Local $s = String($sVal)
	$s = StringReplace($s, "'", "''")
	$s = StringReplace($s, "[", "[[]")
	$s = StringReplace($s, "%", "[%]")
	$s = StringReplace($s, "_", "[_]")
	Return $s
EndFunc   ;==>_SqlLikeToken

; -----------------------------
; SQL literal helpers
; -----------------------------
Func _SqlPredicateLiteralForColumn($v, $sTargetType, $bNullable)
	; Predicate literals are used only in WHERE clauses. They must represent the source
	; value comparison and must never return DEFAULT.
	Local $t = StringLower($sTargetType)

	If _IsNull($v) Or IsObj($v) Then
		If IsObj($v) Then
			If _IsTextType($t) Then Return SetError(0, 0, _SqlTextLiteral(_BinaryToTextSafe($v)))
			If _IsBinaryType($t) Then Return SetError(0, 0, "0x")
		EndIf
		Return SetError(0, 0, "NULL")
	EndIf

	Local $vt = VarGetType($v)
	If _IsBinaryType($t) Then Return SetError(0, 0, _SqlBinaryLiteral($v))

	If _IsTextType($t) Then
		If $vt = "Binary" Then Return SetError(0, 0, _SqlTextLiteral(_BinaryToTextSafe($v)))
		Local $sVal = String($v)
		If StringStripWS($sVal, 3) = "" And GUICtrlRead($chkEmptyStringAsNull) = $GUI_CHECKED And $bNullable Then Return SetError(0, 0, "NULL")
		Return SetError(0, 0, _SqlTextLiteral($sVal))
	EndIf

	If _IsNumericType($t) Then
		Local $sv = StringStripWS(String($v), 3)
		If $sv = "" Then Return SetError(0, 0, "NULL")
		$sv = StringReplace($sv, ",", ".")
		Return SetError(0, 0, $sv)
	EndIf

	If _IsDateTimeType($t) Then
		Local $iso = _ToIsoDateTime($v)
		If $iso = "" Then Return SetError(0, 0, "NULL")
		Return SetError(0, 0, "'" & $iso & "'")
	EndIf

	If StringInStr($t, "bit") Then
		Local $bv = StringLower(StringStripWS(String($v), 3))
		If $bv = "" Then Return SetError(0, 0, "NULL")
		If $bv = "true" Then Return SetError(0, 0, "1")
		If $bv = "false" Then Return SetError(0, 0, "0")
		Return SetError(0, 0, String(Int($bv)))
	EndIf

	Local $sAny = String($v)
	If StringStripWS($sAny, 3) = "" And GUICtrlRead($chkEmptyStringAsNull) = $GUI_CHECKED And $bNullable Then Return SetError(0, 0, "NULL")
	Return SetError(0, 0, _SqlTextLiteral($sAny))
EndFunc   ;==>_SqlPredicateLiteralForColumn

Func _SqlLiteralForColumn($v, $sTargetType, $bNullable, $sDefault)
	Local $t = StringLower($sTargetType)

	If _IsNull($v) Or IsObj($v) Then
		If IsObj($v) Then
			If _IsTextType($t) Then Return _SqlTextLiteral(_BinaryToTextSafe($v))
			If _IsBinaryType($t) Then Return "0x"
		EndIf
		Return _NullReplacement($t, $bNullable, $sDefault)
	EndIf

	Local $vt = VarGetType($v)
	If _IsBinaryType($t) Then
		Return _SqlBinaryLiteral($v)
	EndIf

	If _IsTextType($t) Then
		If $vt = "Binary" Then Return _SqlTextLiteral(_BinaryToTextSafe($v))
		Local $sVal = String($v)
		If StringStripWS($sVal, 3) = "" Then
			If GUICtrlRead($chkEmptyStringAsNull) = $GUI_CHECKED And $bNullable Then Return "NULL"
			If GUICtrlRead($chkFallbackNotNull) = $GUI_CHECKED And Not $bNullable And $sDefault <> "" Then Return "DEFAULT"
		EndIf
		Return _SqlTextLiteral($sVal)
	EndIf

	If _IsNumericType($t) Then
		Local $sv = StringStripWS(String($v), 3)
		If $sv = "" Then Return _NullReplacement($t, $bNullable, $sDefault)
		$sv = StringReplace($sv, ",", ".")
		Return $sv
	EndIf

	If _IsDateTimeType($t) Then
		Local $iso = _ToIsoDateTime($v)
		If $iso = "" Then Return _NullReplacement($t, $bNullable, $sDefault)
		Return "'" & $iso & "'"
	EndIf

	If StringInStr($t, "bit") Then
		Local $bv = StringLower(StringStripWS(String($v), 3))
		If $bv = "" Then Return _NullReplacement($t, $bNullable, $sDefault)
		If $bv = "true" Then Return "1"
		If $bv = "false" Then Return "0"
		Return String(Int($bv))
	EndIf

	Local $sAny = String($v)
	If StringStripWS($sAny, 3) = "" Then
		If GUICtrlRead($chkEmptyStringAsNull) = $GUI_CHECKED And $bNullable Then Return "NULL"
		If GUICtrlRead($chkFallbackNotNull) = $GUI_CHECKED And Not $bNullable And $sDefault <> "" Then Return "DEFAULT"
	EndIf
	Return _SqlTextLiteral($sAny)
EndFunc   ;==>_SqlLiteralForColumn

Func _NullReplacement($t, $bNullable, $sDefault)
	If $bNullable Then Return "NULL"

	If GUICtrlRead($chkFallbackNotNull) <> $GUI_CHECKED Then Return "NULL"
	If $sDefault <> "" Then Return "DEFAULT"

	If _IsNumericType($t) Or StringInStr($t, "bit") Then Return "0"
	If _IsDateTimeType($t) Then
		If StringInStr($t, "time") And Not StringInStr($t, "datetime") Then Return "'00:00:00'"
		Return "'1900-01-01 00:00:00'"
	EndIf
	If _IsBinaryType($t) Then Return "0x"
	Return "N''"
EndFunc   ;==>_NullReplacement

Func _SqlTextLiteral($sVal)
	Return "N'" & StringReplace(String($sVal), "'", "''") & "'"
EndFunc   ;==>_SqlTextLiteral

Func _SqlQuote($sVal)
	Return "'" & StringReplace(String($sVal), "'", "''") & "'"
EndFunc   ;==>_SqlQuote

Func _SqlBinaryLiteral($v)
	Local $vt = VarGetType($v)
	If $vt = "Binary" Then Return "0x" & Hex($v)
	If IsArray($v) Then
		Local $hex = _BytesArrayToHex($v)
		If $hex <> "" Then Return "0x" & $hex
	EndIf
	Local $b = Binary($v)
	If @error = 0 And VarGetType($b) = "Binary" Then Return "0x" & Hex($b)
	Return "0x"
EndFunc   ;==>_SqlBinaryLiteral

Func _BinaryToTextSafe($v)
	If VarGetType($v) = "Binary" Then
		Local $s = BinaryToString($v, 1)
		If @error = 0 Then Return $s
		$s = BinaryToString($v, 4)
		If @error = 0 Then Return $s
	EndIf

	; ADODB may expose long data as an object/stream-like value. If AutoIt cannot read it
	; directly, return an empty string instead of sending a binary literal to a text column.
	Return String($v)
EndFunc   ;==>_BinaryToTextSafe

Func _BytesArrayToHex(ByRef $a)
	If Not IsArray($a) Then Return ""
	Local $hex = ""
	For $i = 0 To UBound($a) - 1
		If IsNumber($a[$i]) Then $hex &= Hex(Int($a[$i]), 2)
	Next
	Return $hex
EndFunc   ;==>_BytesArrayToHex

Func _IsTextType($t)
	Return StringInStr($t, "char") Or StringInStr($t, "text") Or StringInStr($t, "xml") Or StringInStr($t, "uniqueidentifier")
EndFunc   ;==>_IsTextType

Func _IsBinaryType($t)
	Return StringInStr($t, "binary") Or StringInStr($t, "image") Or StringInStr($t, "rowversion") Or StringInStr($t, "timestamp")
EndFunc   ;==>_IsBinaryType

Func _IsNumericType($t)
	Return StringInStr($t, "int") Or StringInStr($t, "decimal") Or StringInStr($t, "numeric") Or _
			StringInStr($t, "real") Or StringInStr($t, "float") Or StringInStr($t, "money")
EndFunc   ;==>_IsNumericType

Func _IsDateTimeType($t)
	If StringInStr($t, "timestamp") Or StringInStr($t, "rowversion") Then Return False
	Return StringInStr($t, "date") Or StringInStr($t, "time")
EndFunc   ;==>_IsDateTimeType

Func _ToIsoDateTime($v)
	Local $vt = VarGetType($v)

	If $vt = "Date" Then
		Local $aDate[4], $aTime[4]
		_DateTimeSplit($v, $aDate, $aTime)
		If @error Then Return ""
		Return StringFormat("%04d-%02d-%02d %02d:%02d:%02d", _
				Int($aDate[1]), Int($aDate[2]), Int($aDate[3]), Int($aTime[1]), Int($aTime[2]), Int($aTime[3]))
	EndIf

	Local $s = StringStripWS(String($v), 3)
	If $s = "" Then Return ""
	If StringRegExp($s, "^\d{4}-\d{2}-\d{2}") Then Return $s

	; Ortems/Firebird common numeric timestamp formats: YYYYMMDD[HHMMSS]
	Local $m14 = StringRegExp($s, "^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$", 1)
	If IsArray($m14) Then
		Return StringFormat("%04d-%02d-%02d %02d:%02d:%02d", Int($m14[0]), Int($m14[1]), Int($m14[2]), Int($m14[3]), Int($m14[4]), Int($m14[5]))
	EndIf

	Local $m12 = StringRegExp($s, "^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})$", 1)
	If IsArray($m12) Then
		Return StringFormat("%04d-%02d-%02d %02d:%02d:%02d", Int($m12[0]), Int($m12[1]), Int($m12[2]), Int($m12[3]), Int($m12[4]), 0)
	EndIf

	Local $m8 = StringRegExp($s, "^(\d{4})(\d{2})(\d{2})$", 1)
	If IsArray($m8) Then
		Return StringFormat("%04d-%02d-%02d 00:00:00", Int($m8[0]), Int($m8[1]), Int($m8[2]))
	EndIf

	Local $m = StringRegExp($s, "^(\d{1,2})/(\d{1,2})/(\d{4})(.*)$", 1)
	If IsArray($m) Then
		Local $p1 = Int($m[0]), $p2 = Int($m[1]), $Y = Int($m[2])
		Local $rest = StringStripWS($m[3], 3)
		Local $d = $p1, $m = $p2
		If $p1 <= 12 And $p2 > 12 Then
			$m = $p1
			$d = $p2
		EndIf
		Local $hh = 0, $nn = 0, $ss = 0
		Local $tm = StringRegExp($rest, "(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?", 1)
		If IsArray($tm) Then
			$hh = Int($tm[0])
			$nn = Int($tm[1])
			If UBound($tm) >= 3 And $tm[2] <> "" Then $ss = Int($tm[2])
		EndIf
		Return StringFormat("%04d-%02d-%02d %02d:%02d:%02d", $Y, $m, $d, $hh, $nn, $ss)
	EndIf

	Local $md = StringRegExp($s, "^(\d{1,2})\.(\d{1,2})\.(\d{4})(.*)$", 1)
	If IsArray($md) Then
		Local $D2 = Int($md[0]), $M2 = Int($md[1]), $Y2 = Int($md[2])
		Local $rest2 = StringStripWS($md[3], 3)
		Local $hh2 = 0, $nn2 = 0, $ss2 = 0
		Local $tm2 = StringRegExp($rest2, "(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?", 1)
		If IsArray($tm2) Then
			$hh2 = Int($tm2[0])
			$nn2 = Int($tm2[1])
			If UBound($tm2) >= 3 And $tm2[2] <> "" Then $ss2 = Int($tm2[2])
		EndIf
		Return StringFormat("%04d-%02d-%02d %02d:%02d:%02d", $Y2, $M2, $D2, $hh2, $nn2, $ss2)
	EndIf

	Return ""
EndFunc   ;==>_ToIsoDateTime

; -----------------------------
; Cleanup
; -----------------------------
Func _Cleanup()
	If IsObj($g_oFbConn) Then
		$g_oFbConn.Close()
		$g_oFbConn = 0
	EndIf
	If IsObj($g_oSqlConn) Then
		$g_oSqlConn.Close()
		$g_oSqlConn = 0
	EndIf
EndFunc   ;==>_Cleanup

Func _splash($Mode = "on")

	If $Mode = "on" Then

		$splashWin_X = 640
		$splashWin_Y = 360

		If $WinPos_X = -1 And $WinPos_Y = -1 Then
			Global $Form_Splash = GUICreate("", $splashWin_X, $splashWin_Y, -1, -1, $WS_POPUP, BitOR($WS_EX_TOPMOST, $WS_EX_TOOLWINDOW, $WS_EX_LAYERED))
		Else
			Global $Form_Splash = GUICreate("", $splashWin_X, $splashWin_Y, $WinPos_X, $WinPos_Y, $WS_POPUP, BitOR($WS_EX_TOPMOST, $WS_EX_TOOLWINDOW, $WS_EX_LAYERED))
		EndIf

		Global $Pic_Splash = GUICtrlCreatePic($sSplashPath, 5, 5, 630, 350)

		Global $Progress_Splash = GUICtrlCreateProgress(104, 288, 430, 17)
		Global $Label_Percentage = GUICtrlCreateLabel("0%", 540, 290, 100, -1, $SS_SIMPLE)
		GUICtrlSetColor($Label_Percentage, 0xFFFFFF)
		GUICtrlSetBkColor($Label_Percentage, 0x5b90b2)
		Global $Label_version = GUICtrlCreateLabel(FileGetVersion(@ScriptFullPath), 560, 330, -1, -1, $SS_SIMPLE)
		GUICtrlSetColor($Label_version, 0xFFFFFF)
		GUICtrlSetBkColor($Label_version, 0x5b90b2)
;~ 		Global $Button_Close_Splash = GUICtrlCreateCheckbox("X", 605, 15, 20, 20, $BS_PUSHLIKE)
;~ 		GUICtrlDelete($Button_Close_Splash)
		GUISetState(@SW_SHOW, $Form_Splash)

		Return
	Else
		If $Mode = "off" Then
			GUIDelete($Form_Splash)
			GUISetState(@SW_SHOW, $hGUI)
			Return
		EndIf
	EndIf
EndFunc   ;==>_splash