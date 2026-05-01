#cs ----------------------------------------------------------------------------
    Firebird GDB -> SQL Server Importer (AutoIt)
    ------------------------------------------------
    English-only UI
    - Reads Firebird .gdb via Firebird ODBC driver
    - Imports selected tables into SQL Server using ODBC connection string
    - Automatically creates target tables (basic CREATE TABLE)
    - Always clears destination table before loading (TRUNCATE, fallback DELETE)
    - UI is disabled during import (Abort remains enabled)
    - Settings are saved to Settings.ini and auto-loaded at startup
    - Detailed logging + auto-scroll + error counter

    Requirements:
      - AutoIt3
      - Firebird ODBC driver installed (driver name may vary)
      - SQL Server reachable and accessible via ODBC driver "{SQL Server}" (or adjust to your driver)
#ce ----------------------------------------------------------------------------

#include <GUIConstantsEx.au3>
#include <WindowsConstants.au3>
#include <ScrollBarConstants.au3>
#include <EditConstants.au3>
#include <GuiEdit.au3>
#include <StaticConstants.au3>
#include <ButtonConstants.au3>
#include <ListViewConstants.au3>
#include <GuiListView.au3>
#include <Array.au3>
#include <Date.au3>

Opt("MustDeclareVars", 1)

; -----------------------------
; Globals
; -----------------------------
Global $g_oFbConn = 0
Global $g_oSqlConn = 0
Global $g_sLogFile = ""
Global $g_iBatchSize = 500

Global $g_bAbort = False
Global $g_sCurrentSql = ""
Global $g_iErrorCount = 0
Global $g_iMaxErrors = 50

Global $g_oComErr = ObjEvent("AutoIt.Error", "_ComErrHandler")
Global $g_sIniPath = @ScriptDir & "\Settings.ini"

; -----------------------------
; GUI
; -----------------------------
Global $hGUI = GUICreate("Firebird GDB -> SQL Server Importer", 980, 700)

; Source (Firebird)
GUICtrlCreateGroup("Source (Firebird)", 10, 10, 960, 160)
Global $lblGdb = GUICtrlCreateLabel("GDB file path:", 25, 40, 110, 20)
Global $inpGdb = GUICtrlCreateInput("", 140, 36, 650, 24)
Global $btnBrowseGdb = GUICtrlCreateButton("Browse...", 800, 35, 150, 26)

Global $lblFbServer = GUICtrlCreateLabel("Firebird server:", 25, 75, 110, 20)
Global $inpFbServer = GUICtrlCreateInput("localhost", 140, 71, 220, 24)

Global $lblFbPort = GUICtrlCreateLabel("Port:", 380, 75, 40, 20)
Global $inpFbPort = GUICtrlCreateInput("3050", 420, 71, 80, 24)

Global $lblFbUser = GUICtrlCreateLabel("User:", 520, 75, 40, 20)
Global $inpFbUser = GUICtrlCreateInput("SYSDBA", 565, 71, 120, 24)

Global $lblFbPass = GUICtrlCreateLabel("Password:", 700, 75, 65, 20)
Global $inpFbPass = GUICtrlCreateInput("masterkey", 770, 71, 180, 24, $ES_PASSWORD)

Global $btnTestFb = GUICtrlCreateButton("Test Firebird Connection", 25, 110, 220, 30)
Global $btnLoadTables = GUICtrlCreateButton("Load Table List", 260, 110, 160, 30)

; Target (SQL Server)
GUICtrlCreateGroup("Target (SQL Server)", 10, 180, 960, 180)

Global $lblSqlServer = GUICtrlCreateLabel("SQL Server:", 25, 210, 110, 20)
Global $inpSqlServer = GUICtrlCreateInput("", 140, 206, 240, 24)

Global $lblSqlDb = GUICtrlCreateLabel("Database:", 400, 210, 70, 20)
Global $inpSqlDb = GUICtrlCreateInput("", 470, 206, 200, 24)

Global $lblAuth = GUICtrlCreateLabel("Authentication:", 690, 210, 90, 20)
Global $cmbAuth = GUICtrlCreateCombo("Windows Authentication", 785, 206, 165, 24)
GUICtrlSetData($cmbAuth, "SQL Server Authentication")

Global $lblSqlUser = GUICtrlCreateLabel("User:", 25, 245, 110, 20)
Global $inpSqlUser = GUICtrlCreateInput("", 140, 241, 240, 24)
GUICtrlSetState($inpSqlUser, $GUI_DISABLE)

Global $lblSqlPass = GUICtrlCreateLabel("Password:", 400, 245, 70, 20)
Global $inpSqlPass = GUICtrlCreateInput("", 470, 241, 200, 24, $ES_PASSWORD)
GUICtrlSetState($inpSqlPass, $GUI_DISABLE)

Global $lblSchema = GUICtrlCreateLabel("Target schema:", 690, 245, 90, 20)
Global $inpSchema = GUICtrlCreateInput("dbo", 785, 241, 165, 24)

Global $lblConnStr = GUICtrlCreateLabel("Connection string:", 25, 280, 110, 20)
Global $inpConnStr = GUICtrlCreateInput("", 140, 276, 810, 24, $ES_READONLY)

Global $btnTestSql = GUICtrlCreateButton("Test SQL Server Connection", 25, 310, 220, 30)
Global $chkDropRecreate = GUICtrlCreateCheckbox("Drop & recreate tables (dangerous)", 260, 316, 260, 22)
Global $chkTruncate = GUICtrlCreateCheckbox("Truncate before load (if exists)", 540, 316, 240, 22)

; Table selection
GUICtrlCreateGroup("Tables to Import", 10, 350, 470, 250)
Global $lvTables = GUICtrlCreateListView("Import|Table", 25, 380, 440, 205, BitOR($LVS_REPORT, $LVS_SHOWSELALWAYS))
_GUICtrlListView_SetExtendedListViewStyle($lvTables, BitOR($LVS_EX_CHECKBOXES, $LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES))
_GUICtrlListView_SetColumnWidth($lvTables, 0, 60)
_GUICtrlListView_SetColumnWidth($lvTables, 1, 350)

; Run + Log
GUICtrlCreateGroup("Run", 490, 350, 480, 250)
Global $btnRun = GUICtrlCreateButton("Run Import", 510, 380, 150, 34)
Global $lblBatch = GUICtrlCreateLabel("Batch size:", 680, 389, 70, 18)
Global $inpBatch = GUICtrlCreateInput("500", 755, 385, 80, 24)
Global $btnAbort = GUICtrlCreateButton("Abort", 850, 385, 100, 24)
GUICtrlSetState($btnAbort, $GUI_DISABLE)

Global $btnChooseLog = GUICtrlCreateButton("Choose Log File...", 510, 425, 150, 28)
Global $lblLogFile = GUICtrlCreateLabel("(no log file selected; will log to temp)", 670, 430, 285, 30)

Global $txtLog = GUICtrlCreateEdit("", 510, 460, 440, 125, BitOR($ES_READONLY, $ES_MULTILINE, $WS_VSCROLL))
GUICtrlSetFont($txtLog, 9, 400, 0, "Consolas")

; Bottom aligned buttons (user suggestions)
Global $btnSelectAll = GUICtrlCreateButton("Select All", 25, 610, 150, 34)
Global $btnClearAll = GUICtrlCreateButton("Clear All", 185, 610, 150, 34)
Global $btnClearLog = GUICtrlCreateButton("Clear Log", 660, 610, 150, 34)
Global $btnExit = GUICtrlCreateButton("Exit", 820, 610, 150, 34)

; Footer
Global $lblStatus = GUICtrlCreateLabel("Status: Ready", 10, 660, 760, 22)
Global $lblErrCount = GUICtrlCreateLabel("Errors: 0 / 50", 780, 660, 190, 22)

GUISetState(@SW_SHOW, $hGUI)

; Load persisted settings
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

        Case $btnChooseLog
            Local $sLog = FileSaveDialog("Select log file", @ScriptDir, "Log files (*.log)|Text files (*.txt)|All (*.*)", 18, "import.log")
            If Not @error And $sLog <> "" Then
                $g_sLogFile = $sLog
                GUICtrlSetData($lblLogFile, $g_sLogFile)
                _SaveSettings()
            EndIf

        Case $btnClearLog
            _ClearLog()

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

        Case $chkDropRecreate, $chkTruncate
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
EndFunc

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
EndFunc

Func _SetUiEnabled($bEnabled)
    Local $iState = $GUI_ENABLE
    If Not $bEnabled Then $iState = $GUI_DISABLE

    ; Disable/enable everything
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
    GUICtrlSetState($chkDropRecreate, $iState)
    GUICtrlSetState($chkTruncate, $iState)

    GUICtrlSetState($lvTables, $iState)
    GUICtrlSetState($btnSelectAll, $iState)
    GUICtrlSetState($btnClearAll, $iState)

    GUICtrlSetState($btnRun, $iState)
    GUICtrlSetState($inpBatch, $iState)
    GUICtrlSetState($btnChooseLog, $iState)
    GUICtrlSetState($btnClearLog, $iState)
    GUICtrlSetState($btnExit, $iState)

    ; Abort only available during run
    If $bEnabled Then
        GUICtrlSetState($btnAbort, $GUI_DISABLE)
    Else
        GUICtrlSetState($btnAbort, $GUI_ENABLE)
    EndIf

    ; Keep log enabled
    GUICtrlSetState($txtLog, $GUI_ENABLE)

    If $bEnabled Then _OnSqlAuthChange()
EndFunc

Func _ClearLog()
    GUICtrlSetData($txtLog, "")
EndFunc

Func _RequestAbort()
    $g_bAbort = True
    _Log("ABORT requested by user. Stopping as soon as possible...")
    _Status("Status: Abort requested...")
EndFunc

Func _ProcessGuiDuringRun()
    Local $msg = GUIGetMsg()
    If $msg = $btnAbort Then
        _RequestAbort()
    ElseIf $msg = $GUI_EVENT_CLOSE Then
        _RequestAbort()
    EndIf
EndFunc

; -----------------------------
; Settings
; -----------------------------
Func _LoadSettings()
    ; Firebird
    GUICtrlSetData($inpGdb, IniRead($g_sIniPath, "Firebird", "GdbPath", ""))
    GUICtrlSetData($inpFbServer, IniRead($g_sIniPath, "Firebird", "Server", "localhost"))
    GUICtrlSetData($inpFbPort, IniRead($g_sIniPath, "Firebird", "Port", "3050"))
    GUICtrlSetData($inpFbUser, IniRead($g_sIniPath, "Firebird", "User", "SYSDBA"))
    GUICtrlSetData($inpFbPass, IniRead($g_sIniPath, "Firebird", "Password", "masterkey"))

    ; SQL Server
    GUICtrlSetData($inpSqlServer, IniRead($g_sIniPath, "SQLServer", "Server", ""))
    GUICtrlSetData($inpSqlDb, IniRead($g_sIniPath, "SQLServer", "Database", ""))
    GUICtrlSetData($inpSchema, IniRead($g_sIniPath, "SQLServer", "Schema", "dbo"))
    GUICtrlSetData($cmbAuth, IniRead($g_sIniPath, "SQLServer", "Authentication", "Windows Authentication"))
    GUICtrlSetData($inpSqlUser, IniRead($g_sIniPath, "SQLServer", "User", ""))
    GUICtrlSetData($inpSqlPass, IniRead($g_sIniPath, "SQLServer", "Password", ""))

    ; Options
    Local $bDrop = IniRead($g_sIniPath, "Options", "DropRecreate", "0")
    Local $bTrunc = IniRead($g_sIniPath, "Options", "Truncate", "0")
    If $bDrop = "1" Then GUICtrlSetState($chkDropRecreate, $GUI_CHECKED)
    If $bTrunc = "1" Then GUICtrlSetState($chkTruncate, $GUI_CHECKED)

    GUICtrlSetData($inpBatch, IniRead($g_sIniPath, "Options", "BatchSize", "500"))
    $g_iMaxErrors = Int(IniRead($g_sIniPath, "Options", "MaxErrors", "50"))
    If $g_iMaxErrors < 1 Then $g_iMaxErrors = 50

    $g_sLogFile = IniRead($g_sIniPath, "Options", "LogFile", "")
    If $g_sLogFile <> "" Then GUICtrlSetData($lblLogFile, $g_sLogFile)

    _OnSqlAuthChange()
    _BuildSqlConnStr()
    _UpdateErrorCount()
EndFunc

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

    IniWrite($g_sIniPath, "Options", "DropRecreate", _IIf(GUICtrlRead($chkDropRecreate) = $GUI_CHECKED, "1", "0"))
    IniWrite($g_sIniPath, "Options", "Truncate", _IIf(GUICtrlRead($chkTruncate) = $GUI_CHECKED, "1", "0"))
    IniWrite($g_sIniPath, "Options", "BatchSize", GUICtrlRead($inpBatch))
    IniWrite($g_sIniPath, "Options", "LogFile", $g_sLogFile)
    IniWrite($g_sIniPath, "Options", "MaxErrors", $g_iMaxErrors)
EndFunc

Func _IIf($bCond, $vTrue, $vFalse)
    If $bCond Then Return $vTrue
    Return $vFalse
EndFunc

; -----------------------------
; Status + logging
; -----------------------------
Func _UpdateErrorCount()
    GUICtrlSetData($lblErrCount, "Errors: " & $g_iErrorCount & " / " & $g_iMaxErrors)
EndFunc

Func _Status($s)
    GUICtrlSetData($lblStatus, $s)
EndFunc

Func _NowStamp()
    Return @YEAR & "-" & StringRight("0" & @MON, 2) & "-" & StringRight("0" & @MDAY, 2) & " " & _
           StringRight("0" & @HOUR, 2) & ":" & StringRight("0" & @MIN, 2) & ":" & StringRight("0" & @SEC, 2)
EndFunc

Func _Log($s)
    Local $line = _NowStamp() & "  " & $s & @CRLF
    GUICtrlSetData($txtLog, GUICtrlRead($txtLog) & $line)

    ; Auto-scroll to last line
    _GUICtrlEdit_SetSel($txtLog, -1, -1)
    _GUICtrlEdit_Scroll($txtLog, $SB_SCROLLCARET)

    If $g_sLogFile <> "" Then FileWrite($g_sLogFile, $line)
EndFunc

Func _ComErrHandler($oError)
    $g_iErrorCount += 1
    _UpdateErrorCount()

    Local $msg = "COM ERROR #" & $g_iErrorCount & ": " & $oError.windescription & _
                 " | Number: " & Hex($oError.number) & _
                 " | Source: " & $oError.source & _
                 " | ScriptLine: " & $oError.scriptline
    _Log($msg)

    If $g_sCurrentSql <> "" Then _Log("Last SQL: " & _Shorten($g_sCurrentSql, 800))
    If IsObj($g_oSqlConn) Then _DumpAdoErrors($g_oSqlConn)

    If $g_iErrorCount >= $g_iMaxErrors Then
        $g_bAbort = True
        _Log("MaxErrors reached (" & $g_iMaxErrors & "). Auto-aborting...")
        _Status("Status: Auto-abort due to too many errors.")
    EndIf
EndFunc

Func _DumpAdoErrors($oConn)
    If Not IsObj($oConn) Then Return
    If Not IsObj($oConn.Errors) Then Return
    If $oConn.Errors.Count = 0 Then Return

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

            _Log("ADO Error: " & $e.Number & " | " & $e.Description & " | SQLState: " & $sqlState & " | NativeError: " & $native)
        EndIf
    Next

    $oConn.Errors.Clear()
EndFunc

Func _Shorten($sText, $iMax)
    If StringLen($sText) <= $iMax Then Return $sText
    Return StringLeft($sText, $iMax) & " ...[truncated]"
EndFunc

Func _IsNull($v)
    Return (VarGetType($v) = "Null")
EndFunc

; -----------------------------
; SQL auth helpers
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
EndFunc

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
EndFunc

; -----------------------------
; Connections
; -----------------------------
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

    ; Adjust driver name if needed in your environment
    Local $sConn = "Driver={Firebird/InterBase(r) driver};" & _
                   "Dbname=" & $sServer & "/" & $sPort & ":" & $sGdb & ";" & _
                   "Uid=" & $sUser & ";Pwd=" & $sPass & ";"

    $g_oFbConn = ObjCreate("ADODB.Connection")
    $g_oFbConn.ConnectionTimeout = 15
    $g_oFbConn.CommandTimeout = 0
    $g_oFbConn.Open($sConn)

    If @error Or Not IsObj($g_oFbConn) Then
        _Log("ERROR: Firebird connection failed. Check driver name, server, port, credentials.")
        $g_oFbConn = 0
        Return False
    EndIf
    Return True
EndFunc

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
    $g_oSqlConn.Open($sConn)

    If @error Or Not IsObj($g_oSqlConn) Then
        _Log("ERROR: SQL Server connection failed. Check ODBC driver, server, DB, and authentication.")
        $g_oSqlConn = 0
        Return False
    EndIf
    Return True
EndFunc

; -----------------------------
; Firebird metadata + SQL DDL
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
EndFunc

Func _ListFirebirdTables()
    Local $sSQL = "SELECT TRIM(rdb$relation_name) AS table_name " & _
                  "FROM rdb$relations " & _
                  "WHERE rdb$system_flag = 0 AND rdb$view_blr IS NULL " & _
                  "ORDER BY 1"
    Local $rs = $g_oFbConn.Execute($sSQL)
    If @error Or Not IsObj($rs) Then Return SetError(1, 0, 0)

    Local $a[0]
    While Not $rs.EOF
        ReDim $a[UBound($a) + 1]
        $a[UBound($a) - 1] = $rs.Fields("table_name").Value
        $rs.MoveNext()
    WEnd
    Return $a
EndFunc

; Returns 2D array: [][0]=ColName, [][1]=SqlType, [][2]=NULL/NOT NULL
Func _GetFirebirdColumns($sTable)
    Local $sSQL = "SELECT " & _
        "TRIM(rf.rdb$field_name) AS field_name, " & _
        "f.rdb$field_type AS field_type, " & _
        "f.rdb$field_sub_type AS sub_type, " & _
        "f.rdb$field_length AS field_length, " & _
        "f.rdb$field_precision AS field_precision, " & _
        "f.rdb$field_scale AS field_scale, " & _
        "rf.rdb$null_flag AS null_flag " & _
        "FROM rdb$relation_fields rf " & _
        "JOIN rdb$fields f ON rf.rdb$field_source = f.rdb$field_name " & _
        "WHERE rf.rdb$relation_name = '" & StringUpper($sTable) & "' " & _
        "ORDER BY rf.rdb$field_position"

    Local $rs = $g_oFbConn.Execute($sSQL)
    If @error Or Not IsObj($rs) Then Return SetError(1, 0, 0)

    Local $aCols[0][3]
    While Not $rs.EOF
        Local $name = $rs.Fields("field_name").Value
        Local $t = $rs.Fields("field_type").Value
        Local $sub = $rs.Fields("sub_type").Value
        Local $len = $rs.Fields("field_length").Value
        Local $prec = $rs.Fields("field_precision").Value
        Local $scale = $rs.Fields("field_scale").Value
        Local $nullFlag = $rs.Fields("null_flag").Value

        Local $sqlType = _MapFbTypeToSql($t, $sub, $len, $prec, $scale)

        ; SQL Server destination is intentionally nullable to allow faithful data extraction.
        ; Ortems/Firebird legacy data may contain NULL/empty values even for business-critical fields.
        Local $nullable = "NULL"
        Local $r = UBound($aCols)
        ReDim $aCols[$r + 1][3]
        $aCols[$r][0] = $name
        $aCols[$r][1] = $sqlType
        $aCols[$r][2] = $nullable

        $rs.MoveNext()
    WEnd
    Return $aCols
EndFunc

Func _MapFbTypeToSql($fieldType, $subType, $len, $prec, $scale)
    Switch $fieldType
        Case 7
            Return "SMALLINT"
        Case 8
            Return "INT"
        Case 10
            Return "REAL"
        Case 11, 27
            Return "FLOAT"
        Case 12
            Return "DATE"
        Case 13
            Return "TIME(0)"
        Case 14
            If $len < 1 Then $len = 1
            Return "CHAR(" & $len & ")"
        Case 37
            If $len < 1 Then $len = 1
            If $len > 8000 Then Return "VARCHAR(MAX)"
            Return "VARCHAR(" & $len & ")"
        Case 35
            Return "DATETIME2(3)"
        Case 261
            Return "VARBINARY(MAX)"
        Case 16
            Local $p = $prec
            If _IsNull($p) Or $p = 0 Then $p = 18
            Local $s = 0
            If Not _IsNull($scale) Then $s = Abs($scale)
            If ($subType = 1 Or $subType = 2) Then
                Return "DECIMAL(" & $p & "," & $s & ")"
            Else
                Return "BIGINT"
            EndIf
        Case Else
            If $len > 0 And $len <= 8000 Then Return "VARCHAR(" & $len & ")"
            Return "VARCHAR(MAX)"
    EndSwitch
EndFunc

Func _EnsureSqlTable($sTable, $sSchema, ByRef $aCols, $bDropRecreate)
    Local $sFull = "[" & $sSchema & "].[" & $sTable & "]"

    If $bDropRecreate Then
        _SqlExec("IF OBJECT_ID(N'" & $sSchema & "." & $sTable & "', N'U') IS NOT NULL DROP TABLE " & $sFull & ";")
    EndIf

    Local $sCreate = "IF OBJECT_ID(N'" & $sSchema & "." & $sTable & "', N'U') IS NULL BEGIN CREATE TABLE " & $sFull & " ("
    For $i = 0 To UBound($aCols) - 1
        If $i > 0 Then $sCreate &= ","
        $sCreate &= "[" & $aCols[$i][0] & "] " & $aCols[$i][1] & " " & $aCols[$i][2]
    Next
    $sCreate &= "); END;"

    Return _SqlExec($sCreate)
EndFunc


Func _MakeSqlTableColumnsNullable($sTable, $sSchema, ByRef $aCols)
    ; Existing target tables may have been created by an older version with NOT NULL columns.
    ; Normalize them to NULL so Firebird data can be loaded without rejecting valid NULL values.
    Local $sFull = "[" & $sSchema & "].[" & $sTable & "]"

    For $i = 0 To UBound($aCols) - 1
        Local $sCol = $aCols[$i][0]
        Local $sType = $aCols[$i][1]

        Local $sSql = "IF OBJECT_ID(N'" & $sSchema & "." & $sTable & "', N'U') IS NOT NULL " & _
                      "ALTER TABLE " & $sFull & " ALTER COLUMN [" & $sCol & "] " & $sType & " NULL;"
        $g_sCurrentSql = $sSql
        $g_oSqlConn.Execute($sSql)

        If @error Then
            ; Do not abort import for this warning. It usually means the column is already compatible
            ; or manually constrained. The actual INSERT will still report a precise failure if needed.
            _Log("WARNING: Could not alter column to nullable: " & $sSchema & "." & $sTable & "." & $sCol)
            If IsObj($g_oSqlConn) Then _DumpAdoErrors($g_oSqlConn)
        EndIf
    Next
EndFunc

Func _TryTruncate($sSchema, $sTable)
    Local $sFull = "[" & $sSchema & "].[" & $sTable & "]"
    _Log("Clearing destination table: " & $sFull & " (TRUNCATE, fallback DELETE)")

    If _SqlExec("TRUNCATE TABLE " & $sFull & ";") Then Return
    _SqlExec("DELETE FROM " & $sFull & ";")
EndFunc

Func _SqlExec($sSql)
    $g_sCurrentSql = $sSql
    $g_oSqlConn.Execute($sSql)
    If @error Then
        $g_iErrorCount += 1
        _UpdateErrorCount()
        _Log("SQL ERROR: " & $sSql)
        If IsObj($g_oSqlConn) Then _DumpAdoErrors($g_oSqlConn)
        Return False
    EndIf
    Return True
EndFunc

Func _FbIdent($sName)
    Return $sName
EndFunc

; -----------------------------
; Import
; -----------------------------
Func _RunImport()
    $g_bAbort = False
    $g_iErrorCount = 0
    _UpdateErrorCount()

    _SetUiEnabled(False)
    _Status("Status: Starting import...")
    _SaveSettings()

    $g_iBatchSize = Int(GUICtrlRead($inpBatch))
    If $g_iBatchSize < 1 Then $g_iBatchSize = 500

    If $g_sLogFile = "" Then
        $g_sLogFile = @TempDir & "\gdb_to_sql_import_" & @YEAR & @MON & @MDAY & "_" & @HOUR & @MIN & @SEC & ".log"
        GUICtrlSetData($lblLogFile, $g_sLogFile)
    EndIf

    Local $sGdb = GUICtrlRead($inpGdb)
    If $sGdb = "" Or Not FileExists($sGdb) Then
        _Log("ERROR: Please select a valid .gdb file.")
        _Status("Status: Missing source file.")
        _SetUiEnabled(True)
        Return
    EndIf

    If Not _OpenFirebird() Then
        _Log("ERROR: Firebird connection failed.")
        _Status("Status: Firebird connection failed.")
        _SetUiEnabled(True)
        Return
    EndIf

    _BuildSqlConnStr()
    If Not _OpenSqlServer() Then
        _Log("ERROR: SQL Server connection failed.")
        _Status("Status: SQL Server connection failed.")
        _SetUiEnabled(True)
        Return
    EndIf

    Local $bDrop = (GUICtrlRead($chkDropRecreate) = $GUI_CHECKED)
    Local $bTruncate = (GUICtrlRead($chkTruncate) = $GUI_CHECKED) ; kept for settings compatibility (destination is always cleared anyway)
    Local $sSchema = GUICtrlRead($inpSchema)
    If $sSchema = "" Then $sSchema = "dbo"

    Local $aTables = _GetCheckedTables()
    If UBound($aTables) = 0 Then
        _Log("ERROR: No tables selected.")
        _Status("Status: No tables selected.")
        _SetUiEnabled(True)
        Return
    EndIf

    _Log("=== Import started ===")
    _Log("Source GDB: " & $sGdb)
    _Log("Target SQL Server: " & GUICtrlRead($inpSqlServer) & " | DB: " & GUICtrlRead($inpSqlDb) & " | Auth: " & GUICtrlRead($cmbAuth) & " | Schema: " & $sSchema)
    _Log("Tables selected: " & UBound($aTables))
    _Log("Options: DropRecreate=" & $bDrop & " | Truncate=" & $bTruncate & " | BatchSize=" & $g_iBatchSize)

    Local $iOk = 0, $iFail = 0
    For $i = 0 To UBound($aTables) - 1
        _ProcessGuiDuringRun()
        If $g_bAbort Then ExitLoop

        Local $t = $aTables[$i]
        _Status("Status: Importing " & $t & " (" & ($i + 1) & "/" & UBound($aTables) & ")...")
        If _ImportTable($t, $sSchema, $bDrop, True) Then
            $iOk += 1
        Else
            $iFail += 1
        EndIf
    Next

    _Log("=== Import finished ===")
    If $g_bAbort Then
        _Log("Process ABORTED by user.")
        _Status("Status: Aborted. Success=" & $iOk & " Failed=" & $iFail)
    Else
        _Log("Success: " & $iOk & " | Failed: " & $iFail)
        _Status("Status: Done. Success=" & $iOk & " Failed=" & $iFail)
    EndIf

    _SetUiEnabled(True)
EndFunc

Func _ImportTable($sTable, $sSchema, $bDropRecreate, $bTruncate)
    ; IMPORTANT: This function uses literal INSERTs (NO ADODB.Command parameters).
    Local $aCols = _GetFirebirdColumns($sTable)
    If @error Or UBound($aCols) = 0 Then
        _Log("ERROR: Unable to read metadata for table: " & $sTable)
        Return False
    EndIf

    If Not _EnsureSqlTable($sTable, $sSchema, $aCols, $bDropRecreate) Then
        _Log("ERROR: Failed to create/ensure table in SQL Server: " & $sSchema & "." & $sTable)
        Return False
    EndIf

    ; Normalize schema from previous versions: make all destination columns nullable.
    _MakeSqlTableColumnsNullable($sTable, $sSchema, $aCols)
    _Log("Schema normalized for nullable import: " & $sSchema & "." & $sTable)

    ; Always clear destination
    _TryTruncate($sSchema, $sTable)

    Local $rs = $g_oFbConn.Execute("SELECT * FROM " & _FbIdent($sTable))
    If @error Or Not IsObj($rs) Then
        _Log("ERROR: Failed to read data from Firebird table: " & $sTable)
        Return False
    EndIf

    Local $sColList = ""
    For $i = 0 To UBound($aCols) - 1
        If $i > 0 Then $sColList &= ","
        $sColList &= "[" & $aCols[$i][0] & "]"
    Next

    $g_oSqlConn.BeginTrans()

    Local $iRow = 0, $iCommit = 0
    While Not $rs.EOF
        _ProcessGuiDuringRun()
        If $g_bAbort Then
            $g_oSqlConn.RollbackTrans()
            _Log("ABORTED table: " & $sTable & " (rolled back current transaction)")
            Return False
        EndIf

        Local $sValues = ""
        For $c = 0 To UBound($aCols) - 1
            If $c > 0 Then $sValues &= ","
            Local $v = $rs.Fields($aCols[$c][0]).Value
            $sValues &= _SqlLiteral($v, $aCols[$c][1])
        Next

        Local $sInsert = "INSERT INTO [" & $sSchema & "].[" & $sTable & "] (" & $sColList & ") VALUES (" & $sValues & ")"
        $g_sCurrentSql = $sInsert
        $g_oSqlConn.Execute($sInsert)
        If @error Then
            $g_iErrorCount += 1
            _UpdateErrorCount()
            _Log("SQL EXECUTE FAILED (insert). Table=" & $sTable & " Row=" & $iRow)
            If IsObj($g_oSqlConn) Then _DumpAdoErrors($g_oSqlConn)
            $g_oSqlConn.RollbackTrans()
            Return False
        EndIf

        $iRow += 1
        $iCommit += 1

        If $iCommit >= $g_iBatchSize Then
            $g_oSqlConn.CommitTrans()
            $g_oSqlConn.BeginTrans()
            $iCommit = 0
        EndIf

        $rs.MoveNext()
    WEnd

    $g_oSqlConn.CommitTrans()

    _Log("Imported table: " & $sTable & " | Rows: " & $iRow)
    Return True
EndFunc

; -----------------------------
; SQL literal helpers (handles BLOB, dates, etc.)
; -----------------------------
Func _SqlLiteral($v, $sSqlType)
    Local $t = StringUpper($sSqlType)
    Local $vt = VarGetType($v)

    If _IsNull($v) Or IsObj($v) Then
        If StringInStr($t, "VARBINARY") Or StringInStr($t, "BINARY") Then Return "0x"
        If StringInStr($t, "CHAR") Or StringInStr($t, "TEXT") Or StringInStr($t, "VARCHAR") Or StringInStr($t, "NCHAR") Or StringInStr($t, "NVARCHAR") Then Return "N''"
        Return "NULL"
    EndIf

    If StringInStr($t, "VARBINARY") Or StringInStr($t, "BINARY") Then
        If $vt = "Binary" Then Return "0x" & Hex($v)
        If IsArray($v) Then
            Local $hex = _BytesArrayToHex($v)
            If $hex <> "" Then Return "0x" & $hex
        EndIf
        Local $b = Binary($v)
        If @error = 0 And VarGetType($b) = "Binary" Then Return "0x" & Hex($b)
        Return "0x"
    EndIf

    If StringInStr($t, "INT") Or StringInStr($t, "DECIMAL") Or StringInStr($t, "NUMERIC") Or _
       StringInStr($t, "REAL") Or StringInStr($t, "FLOAT") Or StringInStr($t, "MONEY") Then
        Local $sv = StringStripWS(String($v), 3)
        If $sv = "" Then Return "NULL"
        $sv = StringReplace($sv, ",", ".")
        Return $sv
    EndIf

    If StringInStr($t, "DATE") Or StringInStr($t, "TIME") Then
        Local $iso = _ToIsoDateTime($v)
        If $iso = "" Then Return "NULL"
        Return "'" & $iso & "'"
    EndIf

    Local $sVal = String($v)
    Return "N'" & StringReplace($sVal, "'", "''") & "'"
EndFunc

Func _BytesArrayToHex(ByRef $a)
    If Not IsArray($a) Then Return ""
    Local $hex = ""
    For $i = 0 To UBound($a) - 1
        If IsNumber($a[$i]) Then $hex &= Hex(Int($a[$i]), 2)
    Next
    Return $hex
EndFunc

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

    Local $m = StringRegExp($s, "^(\d{1,2})/(\d{1,2})/(\d{4})(.*)$", 1)
    If IsArray($m) Then
        Local $p1 = Int($m[0]), $p2 = Int($m[1]), $Y = Int($m[2])
        Local $rest = StringStripWS($m[3], 3)
        Local $D = $p1, $M = $p2
        If $p1 <= 12 And $p2 > 12 Then
            $M = $p1
            $D = $p2
        EndIf
        Local $hh = 0, $nn = 0, $ss = 0
        Local $tm = StringRegExp($rest, "(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?", 1)
        If IsArray($tm) Then
            $hh = Int($tm[0])
            $nn = Int($tm[1])
            If UBound($tm) >= 3 And $tm[2] <> "" Then $ss = Int($tm[2])
        EndIf
        Return StringFormat("%04d-%02d-%02d %02d:%02d:%02d", $Y, $M, $D, $hh, $nn, $ss)
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
EndFunc

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
EndFunc
