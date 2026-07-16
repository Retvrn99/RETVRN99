' SPDX-License-Identifier: GPL-3.0-only
Option Explicit

Const ForReading = 1
Const ForWriting = 2
Const TristateFalse = 0

Dim fso
On Error Resume Next
Set fso = CreateObject("Scripting.FileSystemObject")
If Err.Number <> 0 Then Fail "FileSystemObject is unavailable"
On Error GoTo 0

If WScript.Arguments.Count <> 4 Then
    Fail "expected two INF path and section pairs"
End If

If Not PatchFile(WScript.Arguments(0), WScript.Arguments(1)) Then
    Fail "could not patch " & WScript.Arguments(0)
End If
If Not PatchFile(WScript.Arguments(2), WScript.Arguments(3)) Then
    Fail "could not patch " & WScript.Arguments(2)
End If

WScript.Quit 0

Sub Fail(message)
    WScript.Echo "PATCHINF: " & message
    WScript.Quit 1
End Sub

Function PatchFile(path, section)
    Dim tempPath, backupPath, original, patched, ok, attributes
    tempPath = path & ".R99TMP"
    backupPath = path & ".R99BAK"
    PatchFile = False

    If Not RecoverReplacement(path, section, tempPath, backupPath) Then Exit Function
    original = ReadAnsi(path, ok)
    If Not ok Then Exit Function
    patched = PatchText(original, section, ok)
    If Not ok Then Exit Function
    If Not VerifyText(patched, section) Then Exit Function

    If StrComp(original, patched, vbBinaryCompare) = 0 Then
        PatchFile = True
        Exit Function
    End If

    On Error Resume Next
    Err.Clear
    attributes = fso.GetFile(path).Attributes
    If Err.Number <> 0 Then
        On Error GoTo 0
        Exit Function
    End If
    If fso.FileExists(tempPath) Then fso.DeleteFile tempPath, True
    If fso.FileExists(backupPath) Then fso.DeleteFile backupPath, True
    Err.Clear
    WriteAnsi tempPath, patched
    If Err.Number <> 0 Or Not fso.FileExists(tempPath) Then
        Err.Clear
        If fso.FileExists(tempPath) Then fso.DeleteFile tempPath, True
        On Error GoTo 0
        Exit Function
    End If
    fso.MoveFile path, backupPath
    If Err.Number <> 0 Or Not fso.FileExists(backupPath) Then
        Err.Clear
        If fso.FileExists(tempPath) Then fso.DeleteFile tempPath, True
        On Error GoTo 0
        Exit Function
    End If
    fso.MoveFile tempPath, path
    If Err.Number <> 0 Or Not fso.FileExists(path) Then
        RestoreBackup path, tempPath, backupPath
        On Error GoTo 0
        Exit Function
    End If
    fso.GetFile(path).Attributes = attributes
    If Err.Number <> 0 Then
        RestoreBackup path, tempPath, backupPath
        On Error GoTo 0
        Exit Function
    End If
    On Error GoTo 0

    patched = ReadAnsi(path, ok)
    If Not ok Or Not VerifyText(patched, section) Then
        RestoreBackup path, tempPath, backupPath
        Exit Function
    End If

    On Error Resume Next
    Err.Clear
    fso.DeleteFile backupPath, True
    If Err.Number <> 0 Or fso.FileExists(backupPath) Then
        On Error GoTo 0
        Exit Function
    End If
    On Error GoTo 0
    PatchFile = True
End Function

Function RecoverReplacement(path, section, tempPath, backupPath)
    Dim candidate, ok, attributes
    RecoverReplacement = False
    On Error Resume Next
    Err.Clear
    If fso.FileExists(backupPath) Then
        attributes = fso.GetFile(backupPath).Attributes
        If fso.FileExists(path) Then
            candidate = ReadAnsi(path, ok)
            If ok And VerifyText(candidate, section) Then
                fso.GetFile(path).Attributes = attributes
                fso.DeleteFile backupPath, True
            Else
                fso.DeleteFile path, True
                fso.MoveFile backupPath, path
            End If
        Else
            fso.MoveFile backupPath, path
        End If
    End If
    If fso.FileExists(tempPath) Then fso.DeleteFile tempPath, True
    If Err.Number <> 0 Or Not fso.FileExists(path) Then
        On Error GoTo 0
        Exit Function
    End If
    On Error GoTo 0
    RecoverReplacement = True
End Function

Sub RestoreBackup(path, tempPath, backupPath)
    On Error Resume Next
    Err.Clear
    If fso.FileExists(path) Then fso.DeleteFile path, True
    If fso.FileExists(backupPath) Then fso.MoveFile backupPath, path
    If fso.FileExists(tempPath) Then fso.DeleteFile tempPath, True
    On Error GoTo 0
End Sub

Function ReadAnsi(path, ByRef ok)
    Dim stream
    ok = False
    ReadAnsi = ""
    On Error Resume Next
    Err.Clear
    Set stream = fso.OpenTextFile(path, ForReading, False, TristateFalse)
    If Err.Number <> 0 Then
        On Error GoTo 0
        Exit Function
    End If
    ReadAnsi = stream.ReadAll
    stream.Close
    If Err.Number <> 0 Then
        On Error GoTo 0
        Exit Function
    End If
    On Error GoTo 0
    ok = True
End Function

Sub WriteAnsi(path, text)
    Dim stream
    Set stream = fso.OpenTextFile(path, ForWriting, True, TristateFalse)
    stream.Write text
    stream.Close
End Sub

Function PatchText(text, section, ByRef ok)
    Dim active, suffix, eofAt, output, position, line, ending, name
    Dim inTarget, targetCount, sectionEol, fileEol, endedWithEol
    ok = False
    eofAt = InStr(1, text, Chr(26), vbBinaryCompare)
    If eofAt > 0 Then
        active = Left(text, eofAt - 1)
        suffix = Mid(text, eofAt)
    Else
        active = text
        suffix = ""
    End If

    fileEol = DetectEol(active)
    endedWithEol = EndsWithEol(active)
    output = ""
    position = 1
    inTarget = False
    targetCount = 0
    sectionEol = fileEol

    Do While NextLine(active, position, line, ending)
        name = SectionName(line)
        If name <> "" Then
            If inTarget Then AppendDma output, sectionEol, True
            inTarget = StrComp(name, section, vbTextCompare) = 0
            If inTarget Then
                targetCount = targetCount + 1
                If targetCount > 1 Then Exit Function
                If ending <> "" Then sectionEol = ending
            End If
            output = output & line & ending
        ElseIf Not inTarget Or DmaIndex(line) < 0 Then
            output = output & line & ending
        End If
    Loop

    If targetCount <> 1 Then Exit Function
    If inTarget Then AppendDma output, sectionEol, endedWithEol
    PatchText = output & suffix
    ok = True
End Function

Function VerifyText(text, section)
    Dim active, eofAt, position, line, ending, name, inTarget, targetCount
    Dim index, normalized, counts(3), expected
    VerifyText = False
    eofAt = InStr(1, text, Chr(26), vbBinaryCompare)
    If eofAt > 0 Then
        active = Left(text, eofAt - 1)
    Else
        active = text
    End If
    position = 1
    inTarget = False
    targetCount = 0

    Do While NextLine(active, position, line, ending)
        name = SectionName(line)
        If name <> "" Then
            inTarget = StrComp(name, section, vbTextCompare) = 0
            If inTarget Then targetCount = targetCount + 1
        ElseIf inTarget Then
            index = DmaIndex(line)
            If index >= 0 Then
                normalized = NormalizeInfLine(line)
                expected = "HKR,,IDEDMADRIVE" & CStr(index) & ",3,01"
                If StrComp(normalized, expected, vbBinaryCompare) <> 0 Then Exit Function
                counts(index) = counts(index) + 1
            End If
        End If
    Loop

    If targetCount <> 1 Then Exit Function
    For index = 0 To 3
        If counts(index) <> 1 Then Exit Function
    Next
    VerifyText = True
End Function

Sub AppendDma(ByRef output, eol, trailingEol)
    Dim index
    If Len(output) > 0 And Not EndsWithEol(output) Then output = output & eol
    For index = 0 To 3
        output = output & "HKR,,IDEDMADrive" & CStr(index) & ",3,01"
        If index < 3 Or trailingEol Then output = output & eol
    Next
End Sub

Function DmaIndex(ByVal line)
    Dim normalized, index, prefix
    normalized = NormalizeInfLine(line)
    prefix = "HKR,,IDEDMADRIVE"
    DmaIndex = -1
    For index = 0 To 3
        If Left(normalized, Len(prefix) + 2) = prefix & CStr(index) & "," Then
            DmaIndex = index
            Exit Function
        End If
    Next
End Function

Function NormalizeInfLine(ByVal line)
    Dim commentAt
    commentAt = InStr(1, line, ";", vbBinaryCompare)
    If commentAt > 0 Then line = Left(line, commentAt - 1)
    line = Replace(line, " ", "")
    line = Replace(line, vbTab, "")
    NormalizeInfLine = UCase(Trim(line))
End Function

Function SectionName(ByVal line)
    Dim trimmed
    trimmed = Trim(line)
    SectionName = ""
    If Len(trimmed) < 3 Then Exit Function
    If Left(trimmed, 1) <> "[" Or Right(trimmed, 1) <> "]" Then Exit Function
    SectionName = Trim(Mid(trimmed, 2, Len(trimmed) - 2))
End Function

Function DetectEol(text)
    Dim position, line, ending
    DetectEol = vbCrLf
    position = 1
    Do While NextLine(text, position, line, ending)
        If ending <> "" Then
            DetectEol = ending
            Exit Function
        End If
    Loop
End Function

Function EndsWithEol(text)
    Dim last
    EndsWithEol = False
    If Len(text) = 0 Then Exit Function
    last = Right(text, 1)
    EndsWithEol = last = vbCr Or last = vbLf
End Function

Function NextLine(text, ByRef position, ByRef line, ByRef ending)
    Dim start, current, character
    NextLine = False
    If position > Len(text) Then Exit Function
    start = position
    current = position
    Do While current <= Len(text)
        character = Mid(text, current, 1)
        If character = vbCr Or character = vbLf Then Exit Do
        current = current + 1
    Loop
    line = Mid(text, start, current - start)
    ending = ""
    If current <= Len(text) Then
        character = Mid(text, current, 1)
        ending = character
        current = current + 1
        If character = vbCr And current <= Len(text) Then
            If Mid(text, current, 1) = vbLf Then
                ending = vbCrLf
                current = current + 1
            End If
        End If
    End If
    position = current
    NextLine = True
End Function
