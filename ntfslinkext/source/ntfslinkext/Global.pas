{-----------------------------------------------------------------------------
The contents of this file are subject to the GNU General Public License
Version 1.1 or later (the "License"); you may not use this file except in
compliance with the License. You may obtain a copy of the License at
http://www.gnu.org/copyleft/gpl.html

Software distributed under the License is distributed on an "AS IS" basis,
WITHOUT WARRANTY OF ANY KIND, either expressed or implied. See the License for
the specific language governing rights and limitations under the License.

The Initial Developer of the Original Code is Michael Elsd�rfer.
All Rights Reserved.

Development of the extended version has been moved from Novell Forge to
SourceForge by Sebastian Schuberth.

You may retrieve the latest extended version at the "NTFS Link Ext" project page
located at http://sourceforge.net/projects/ntfslinkext/

The original version can still be retrieved from the "NTFS Link" homepage
located at http://www.elsdoerfer.net/ntfslink/
-----------------------------------------------------------------------------}

unit Global;

interface

uses
  SysUtils, Windows, JclRegistry, Constants;

var
  // Handles to various glyphs used in shell menus; initialized at startup.
  GLYPH_HANDLE_STD: HBITMAP;
  GLYPH_HANDLE_JUNCTION: HBITMAP;
  GLYPH_HANDLE_HARDLINK: HBITMAP;
  GLYPH_HANDLE_LINKDEL: HBITMAP;
  GLYPH_HANDLE_EXPLORER: HBITMAP;

// WideString versions of the corresponding SysUtils functions.
function LastDelimiterW(const Delimiters, S: WideString): Integer;
function ExtractFileNameW(const FileName: WideString): WideString;
function ExtractFileDriveW(const FileName: WideString): WideString;

function DirectoryExistsW(const Name: WideString): Boolean;
function FileExistsW(const FileName: WideString): Boolean;
function CreateDirW(const Dir: WideString): Boolean;

// Will add a backslash to the end of the passed string, if not yet existing.
function CheckBackslash(AFileName: WideString): WideString;
// Exactly the opposite: removes the backslash, if it is there.
function RemoveBackslash(AFileName: WideString): WideString;

// Result depends on configuration - whether to add a "Link to" prefix or not.
function IsLinkPrefixTemplateDisabled: boolean;

// Return the name of the file/directory to create. This depends on the
// existing files/directories, i.e. if the user creates multiple links
// of the same file, we will enumerate them: Copy(1), Copy(2), etc.
function GetLinkFileName(Source, TargetDir: WideString; Directory: boolean;
  PrefixTemplate: WideString = LINK_PREFIX_TEMPLATE_DEFAULT): WideString;

// Creates certain registry entries to make sure the extension also works for
// non-Admin accounts with restricted rights.
procedure ApproveExtension(ClassIDStr, Description: WideString);

// Internal function used to create hardlinks.
procedure InternalCreateHardlink(Source, Destination: WideString);
// Calls the one above, but catches all exceptions and returns a boolean.
function InternalCreateHardlinkSafe(Source, Destination: WideString): boolean;

// Interal functions used to create junctions; the Base-function actually creates
// the junctions using a final directory name, the other one first generates
// the directory name based on a template and a base name (e.g. does the
// "Link (x) of ..."), and then calls InternalCreateJunctionBase().
function InternalCreateJunctionBase(LinkTarget, Junction: WideString): boolean;
function InternalCreateJunction(LinkTarget, Junction: WideString;
  TargetDirName: WideString = '';
  PrefixTemplate: WideString = LINK_PREFIX_TEMPLATE_DEFAULT): boolean;

// Wrapper around NtfsGetJunctionPointDestinationW(), passing the
// destination as the result, not as a var parameter; in addition, fix some
// issues with the result value of the JCL function, e.g. remove \\?\ prefix.
function GetJPDestination(Folder: WideString): WideString;

implementation

uses
  ShlObj, JclNTFS, JclWin32, GNUGetText, JunctionMonitor;

{$I JclNTFSUnicode.inc}

// ************************************************************************** //

function LastDelimiterW(const Delimiters, S: WideString): Integer;
var
  l, i: Integer;
begin
  Result := Length(S);
  l := Length(Delimiters);
  while Result > 0 do
  begin
    for i := 1 to l do
    begin
      if S[Result] = Delimiters[l] then
        Exit;
    end;
    Dec(Result);
  end;
end;

function ExtractFileNameW(const FileName: WideString): WideString;
var
  i: Integer;
begin
  i := LastDelimiter(PathDelim + DriveDelim, FileName);
  Result := Copy(FileName, i + 1, MaxInt);
end;

function ExtractFileDriveW(const FileName: WideString): WideString;
var
  i, j: Integer;
begin
  if (Length(FileName) >= 2) and (FileName[2] = DriveDelim) then
    Result := Copy(FileName, 1, 2)
  else if (Length(FileName) >= 2) and (FileName[1] = PathDelim) and
    (FileName[2] = PathDelim) then
  begin
    j := 0;
    i := 3;
    while (i < Length(FileName)) and (j < 2) do
    begin
      if FileName[i] = PathDelim then Inc(j);
      if j < 2 then Inc(i);
    end;
    if FileName[i] = PathDelim then Dec(i);
    Result := Copy(FileName, 1, i);
  end else Result := '';
end;

function DirectoryExistsW(const Name: WideString): Boolean;
var
  r: DWORD;
begin
  r := GetFileAttributesW(PWideChar(Name));
  Result := (R <> DWORD(-1)) and ((R and FILE_ATTRIBUTE_DIRECTORY) <> 0);
end;

function FileExistsW(const FileName: WideString): Boolean;
var
  Attr: Cardinal;
begin
  // FileGetSize is very slow, GetFileAttributes is much faster.
  Attr := GetFileAttributesW(PWideChar(Filename));
  Result := (Attr <> $FFFFFFFF) and (Attr and FILE_ATTRIBUTE_DIRECTORY = 0);
end;

function CreateDirW(const Dir: WideString): Boolean;
begin
  Result := CreateDirectoryW(PWideChar(Dir), nil);
end;

// ************************************************************************** //

function CheckBackslash(AFileName: WideString): WideString;
var
  l: Integer;
begin
  Result := AFileName;
  l := Length(AFileName);
  if (l > 0) and (AFileName[l] <> PathDelim) then
    Result := AFileName + PathDelim;
end;

function RemoveBackslash(AFileName: WideString): WideString;
var
  l: Integer;
begin
  Result := AFileName;
  l := Length(AFileName);
  if (l > 0) and (AFileName[l] = PathDelim) then
    Result := Copy(AFileName, 1, l - 1);
end;

// ************************************************************************** //

function IsLinkPrefixTemplateDisabled: boolean;
begin
  Result := RegReadBoolDef(HKEY_LOCAL_MACHINE, NTFSLINK_CONFIGURATION,
                          'CreateLinksSuppressPrefix', False);
end;

// ************************************************************************** //

function GetLinkFileName(Source, TargetDir: WideString; Directory: boolean;
  PrefixTemplate: WideString = LINK_PREFIX_TEMPLATE_DEFAULT): WideString;
var
  x: integer;
  SrcFile: WideString;
  LinkStr, NumStr: WideString;
begin
  // Get the filename part of the source path. If the source path is a drive,
  // then use the drive letter.
  SrcFile := ExtractFileNameW(RemoveBackslash(Source));
  if SrcFile = '' then SrcFile := 'Drive ' + ExtractFileDriveW(Source)[1];

  // Loop until we finally find a filename not yet in use.
  x := 0;
  repeat
    Inc(x);

    // If "Link to" prefix is disabled and this is the first link, then use our
    // "light" template (without a prefix). Otherwise, use the specified template.
    if (x = 1) and (IsLinkPrefixTemplateDisabled) then
      LinkStr := LINK_NO_PREFIX_TEMPLATE
    else
      LinkStr := _(PrefixTemplate);

    // The very first link does not get a number.
    if x > 1 then NumStr := ' (' + IntToStr(x) + ')' else NumStr := '';

    // Format the template and use the result as our filename. As the
    // translated template might be invalid, the Format() call might
    // fail. If this is the case, we catch the exception and use
    // the default template.
    try
      Result := CheckBackslash(TargetDir) + WideFormat(LinkStr, [NumStr, SrcFile]);
    except
      Result := CheckBackslash(TargetDir) + WideFormat(PrefixTemplate, [NumStr, SrcFile]);
    end;
  until ((Directory) and (not DirectoryExistsW(Result))) or
        ((not Directory) and (not FileExistsW(Result)));

  // Directories/Junctions require a trailing backslash.
  if Directory then
    Result := CheckBackslash(Result);
end;

// ************************************************************************** //

procedure ApproveExtension(ClassIDStr, Description: WideString);
begin
  if (Win32Platform = VER_PLATFORM_WIN32_NT) then
    RegWriteWideString(HKEY_LOCAL_MACHINE,
       'SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved',
       ClassIDStr, Description);
end;

// ************************************************************************** //

procedure InternalCreateHardlink(Source, Destination: WideString);
var
  NewFileName: WideString;
begin
  NewFileName := GetLinkFileName(Source, Destination, False);
  if not NtfsCreateHardLinkW(NewFileName, Source) then
    raise Exception.Create('NtfsCreateHardLinkW() failed.');

  SHChangeNotify(SHCNE_CREATE, SHCNF_PATHW, PWideChar(NewFileName), nil);
  SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, PWideChar(Source), nil);
end;

function InternalCreateHardlinkSafe(Source, Destination: WideString): boolean;
begin
  try
    InternalCreateHardlink(Source, Destination);
    Result := True;
  except
    Result := False;
  end;
end;

// ************************************************************************** //

function InternalCreateJunctionBase(LinkTarget, Junction: WideString): boolean;
begin
  // Create an empty directory first; note that we continue if the directory
  // already exists, because this is required when the ContextMenu hook wants
  // to make a junction based on an existing, empty folder.
  Result := CreateDirW(Junction) or DirectoryExistsW(Junction);

  // If successful, then try to create a junction.
  if Result then
  begin
    // Allow to easily override existing junction points with a new target
    // folder: If there is already a junction point, just delete it.
    if GetJPDestination(Junction) <> '' then
      NtfsDeleteJunctionPointW(Junction);

    // Create the junction.
    Result := NtfsCreateJunctionPointW(CheckBackslash(Junction), LinkTarget);

    if not Result then
      // If junction creation was unsuccessful, delete created directory.
      RemoveDir(Junction)
    else
      // Otherwise (junction successful created): store the information about the
      // new junction, so that we can later find out about how many junctions are
      // pointing to a certain directory.
      TrackJunctionCreate(Junction, LinkTarget);

    // Notify explorer of the change.
    SHChangeNotify(SHCNE_CREATE, SHCNF_PATHW, PWideChar(Junction), nil);
  end;
end;

function InternalCreateJunction(LinkTarget, Junction: WideString;
  TargetDirName: WideString = '';  // See inline comment.
  PrefixTemplate: WideString = LINK_PREFIX_TEMPLATE_DEFAULT): boolean;
var
  NewDir: WideString;
begin
  // Calculate name of directory to create.
  if TargetDirName <> '' then
    // The TargetFileName parameter was added, because this function is
    // called in two different situations. For one, from the DragDrop Hook,
    // were we simply have the source directory we want to link to, and the
    // target directory we want to create the junction in. The second situation
    // is the call from the CopyHook, were we need the directory to link to,
    // the directory were to create the junction, /and/ in addition the
    // filename to use as a template for the junction filename. In the first
    // case, this template filename is identical with the filename of the
    // directory to link to, in the second this is not the case. Therefore,
    // a new parameter, TargetFileName, was added, which will be used as a
    // template. In the second case, we can use "Junction" for that.
    NewDir := GetLinkFileName(TargetDirName, Junction, True, PrefixTemplate)
  else
    NewDir := GetLinkFileName(LinkTarget, Junction, True, PrefixTemplate);

  // Call the sibling function which creates the hardlink, but which takes
  // the final filename of the junction as a parameter.
  Result := InternalCreateJunctionBase(LinkTarget, NewDir);
end;

// ************************************************************************** //

function GetJPDestination(Folder: WideString): WideString;
var
  l: integer;
begin
  // Use JCL utility function to get the target folder.
  NtfsGetJunctionPointDestinationW(Folder, Result);

  // If a path was returned, make some corrections.
  l := Length(Result);  
  if (l > 0) then
  begin
    // Bug in JCL? There seems to be always a #0 appended.
    if (Result[l]) = #0 then
      Delete(Result, l, 1);
    Result := CheckBackslash(Result);
    // Remove the \\?\ if it exists.
    if Pos('\??\', Result) = 1 then
      Delete(Result, 1, 4);
  end;
end;

end.