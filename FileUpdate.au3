#Region ;**** Directives created by AutoIt3Wrapper_GUI ****
#AutoIt3Wrapper_UseX64=y
#AutoIt3Wrapper_UseUpx=n
#AutoIt3Wrapper_Icon=database.ico
#AutoIt3Wrapper_Res_Description=Updater
#AutoIt3Wrapper_Res_CompanyName=Fabricio Zambroni
#AutoIt3Wrapper_Res_LegalCopyright=Copyright © 2026 Fabricio Zambroni
#AutoIt3Wrapper_Res_Fileversion=1.1.1.1
#AutoIt3Wrapper_Res_ProductVersion=1.1.1.1
#AutoIt3Wrapper_Res_ProductName=FirebirdGDB_to_SQLServer_Importer Updater
#AutoIt3Wrapper_Res_File_Add=E:\GitHub\Toolbox\splash.jpg
#EndRegion ;**** Directives created by AutoIt3Wrapper_GUI ****
#cs ----------------------------------------------------------------------------

	 AutoIt Version: 3.3.18.0
	 Author:         myName

	 Script Function:
		Template AutoIt script.

#ce ----------------------------------------------------------------------------

$sFilePath = @ScriptDir & "\version.txt"
$sExecPath = @ScriptDir & "\FirebirdGDB_to_SQLServer_Importer.exe"
Local $hFileOpen = FileOpen($sFilePath, 10)
If $hFileOpen <> -1 Then
	; Write data to the file using the handle returned by FileOpen.
	FileWrite($hFileOpen, FileGetVersion($sExecPath))
EndIf
