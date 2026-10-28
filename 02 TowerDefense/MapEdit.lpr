program MapEdit;

{ MapEdit - map editor for Brewhold Defense (Lazarus / Free Pascal + SDL3)

  Edits data\maps\<name>.json: road paths, entrances, tower plots, decorations, hero spawn, map colours,
  description and which waves file the map uses.
  The map is drawn with the same code as the game (mapcore.pas) and the same art (geometry.json).

  Tools (keys 1-4)
    Select ...... click anything to select it, drag to move
    Paths ....... drag control points / entrance skulls; click empty space to append a point to the
                  selected path (Shift = prepend), Ctrl+click on the road inserts a point there
    Plots ....... click empty space to add a tower plot, drag to move
    Decor ....... pick an object in the palette, click to place it, drag to move, [ / ] scale
  Mouse: RMB / MMB drag pans, wheel zooms.   Del deletes the selection.   Arrows nudge (Shift x10).
  Keys:  Ctrl+N new  Ctrl+O open  Ctrl+S save  Ctrl+Shift+S save as  Ctrl+Z / Ctrl+Y undo / redo
         Ctrl+D duplicate  Home fit view  G snap  F5 play-test the map in the game
  Command line: mapedit [map.json]   (default data\maps\brewhold.json)
  Test hook: mapedit --shot <file.bmp> [tool 1-4] renders a frame, saves a screenshot and quits. }

{$mode objfpc}{$H+}
{$APPTYPE GUI}

uses
  SDL3, SysUtils, Math, StrUtils, Classes, Process, gfx, geometry, gamedata, mapcore, ui;

const
  WIN_W = 1440;
  WIN_H = 900;
  TOP_H = 44;
  LEFT_W = 240;
  RIGHT_W = 330;
  STATUS_H = 24;
  CV_X = LEFT_W;
  CV_Y = TOP_H;
  CV_W = WIN_W - LEFT_W - RIGHT_W;
  CV_H = WIN_H - TOP_H - STATUS_H;
  ROW_H = 22;
  MAX_UNDO = 200;
  PLOT_MIN_ROAD = 64;     // closer than this and the tower overlaps the road
  PLOT_MAX_ROAD = 120;    // further than this and level-1 towers barely reach the road
  PLOT_SPACING = 96;
  TOWER_RANGE = 155;      // shown as a guide

  TOOL_SELECT = 0;
  TOOL_PATH = 1;
  TOOL_PLOT = 2;
  TOOL_DECOR = 3;
  ToolNames: array[0..3] of string = ('Select', 'Paths', 'Plots', 'Decor');

  PathColors: array[0..5] of TRGBA = (
    (r: 255; g: 150; b: 60; a: 255), (r: 80; g: 200; b: 255; a: 255), (r: 230; g: 90; b: 220; a: 255),
    (r: 140; g: 230; b: 90; a: 255), (r: 255; g: 230; b: 80; a: 255), (r: 255; g: 255; b: 255; a: 255));

type
  PRGBA = ^TRGBA;
  TSelKind = (skNone, skPoint, skEntrance, skPlot, skDecor, skHero);

  TPropKind = (pkNum, pkText, pkBool, pkColor, pkEnum, pkInfo);
  TPropRow = record
    Key, Caption: string;
    Kind: TPropKind;
  end;

  TUndoEntry = record
    Json: string;
    Kind: TSelKind;
    Path, Idx: Integer;
  end;

  TIssue = record
    Text: string;
    Kind: TSelKind;
    Path, Idx: Integer;
    X, Y: Single;
    Severe: Boolean;
  end;

  TDrag = (drNone, drItem, drPan, drScrub);

var
  Window: PSDL_Window;
  Renderer: PSDL_Renderer;
  Lib: TGeoLib;
  M: TMapDef;
  MapFile: string = '';
  Modified: Boolean = False;
  Paths: TPathArray;
  BgTex: PSDL_Texture = nil;
  RoadDirty: Boolean = True;

  Tool: Integer = TOOL_SELECT;
  SelKind: TSelKind = skNone;
  SelPath: Integer = -1;
  SelIdx: Integer = -1;
  ActivePath: Integer = 0;       // path that receives new points

  Palette: array of Integer;     // geometry indexes offered in the decor palette
  PalSel: Integer = 0;
  PalAll: Boolean = False;
  PalScroll: Integer = 0;
  PlaceScale: Single = 1;
  RandScale: Boolean = True;
  GeoBX0, GeoBY0, GeoBX1, GeoBY1: array of Single;   // per-geometry bounds for picking
  GeoPlotEmpty: Integer = -1;
  GeoTowerPreview: Integer = -1;

  ViewZoom: Single = 0.65;
  PanX: Single = 0;
  PanY: Single = 0;
  SnapOn: Boolean = False;
  ShowRanges: Boolean = False;
  ShowChecks: Boolean = True;
  PreviewMode: Boolean = False;
  AnimTime: Single = 0;

  Drag: TDrag = drNone;
  DragLastX, DragLastY, DragStartSX: Single;
  DragUndoPushed: Boolean;
  ScrubKey: string;
  ScrubStart: Single;
  ScrubMoved: Boolean;
  EditKey: string = '';
  EditBuf: string = '';

  UndoStack, RedoStack: array of TUndoEntry;
  Issues: array of TIssue;
  Rows: array of TPropRow;
  PropScroll: Integer = 0;
  IssueScroll: Integer = 0;
  StatusMsg: string = '';
  StatusTime: Single = 0;

  DlgLock: TRTLCriticalSection;
  DlgPath: string = '';
  DlgKind: Integer = 0;
  DlgReady: Boolean = False;
  JsonFilter: array[0..0] of TSDL_DialogFileFilter;

{ ======================================================================
  helpers
  ====================================================================== }

procedure Status(const s: string);
begin
  StatusMsg := s;
  StatusTime := 6;
end;

function Dist2(x1, y1, x2, y2: Single): Single; inline;
begin
  Result := Sqr(x2 - x1) + Sqr(y2 - y1);
end;

function RandF(a, b: Single): Single;
begin
  Result := a + Random * (b - a);
end;

function SnapV(v: Single): Single;
begin
  if SnapOn then Result := Round(v / 5) * 5 else Result := Round(v * 10) / 10;
end;

procedure MapToScreen(x, y: Single; out sx, sy: Single);
begin
  sx := CV_X + PanX + x * ViewZoom;
  sy := CV_Y + PanY + y * ViewZoom;
end;

procedure ScreenToMap(sx, sy: Single; out x, y: Single);
begin
  x := (sx - CV_X - PanX) / ViewZoom;
  y := (sy - CV_Y - PanY) / ViewZoom;
end;

function PointCount(p: Integer): Integer;
begin
  Result := Length(M.Paths[p].Ctrl) div 2;
end;

procedure MarkRoads;
begin
  RoadDirty := True;
  Modified := True;
end;

procedure ResolveDecor;
var
  i: Integer;
begin
  for i := 0 to High(M.Decor) do
    M.Decor[i].GeoIdx := Lib.Find(M.Decor[i].Geo);
end;

procedure ComputeGeoBounds;
var
  i, k: Integer;
  a, b, c, d: Single;
begin
  SetLength(GeoBX0, Lib.Count); SetLength(GeoBY0, Lib.Count);
  SetLength(GeoBX1, Lib.Count); SetLength(GeoBY1, Lib.Count);
  for i := 0 to Lib.Count - 1 do
  begin
    GeoBX0[i] := 1e9; GeoBY0[i] := 1e9; GeoBX1[i] := -1e9; GeoBY1[i] := -1e9;
    for k := 0 to High(Lib.Objects[i].Shapes) do
    begin
      if Lib.Objects[i].Shapes[k].Add then Continue;     // glows are bigger than the object
      ShapeBounds(Lib.Objects[i].Shapes[k], a, b, c, d);
      GeoBX0[i] := Min(GeoBX0[i], a); GeoBY0[i] := Min(GeoBY0[i], b);
      GeoBX1[i] := Max(GeoBX1[i], c); GeoBY1[i] := Max(GeoBY1[i], d);
    end;
    if GeoBX0[i] > GeoBX1[i] then
    begin
      GeoBX0[i] := -10; GeoBY0[i] := -10; GeoBX1[i] := 10; GeoBY1[i] := 10;
    end;
  end;
end;

procedure BuildPalette;
var
  i: Integer;
begin
  SetLength(Palette, 0);
  for i := 0 to Lib.Count - 1 do
    if PalAll or SameText(Lib.Objects[i].Category, 'decor') then
    begin
      SetLength(Palette, Length(Palette) + 1);
      Palette[High(Palette)] := i;
    end;
  PalSel := EnsureRange(PalSel, 0, Max(0, High(Palette)));
end;

{ ======================================================================
  undo
  ====================================================================== }

function Snapshot: TUndoEntry;
begin
  Result.Json := MapToJSON(M);
  Result.Kind := SelKind;
  Result.Path := SelPath;
  Result.Idx := SelIdx;
end;

procedure PushUndo;
begin
  if Length(UndoStack) >= MAX_UNDO then Delete(UndoStack, 0, 1);
  SetLength(UndoStack, Length(UndoStack) + 1);
  UndoStack[High(UndoStack)] := Snapshot;
  SetLength(RedoStack, 0);
  Modified := True;
end;

procedure Restore(const e: TUndoEntry);
var
  err: string;
  nm: TMapDef;
begin
  nm := Default(TMapDef);
  if not MapFromJSONText(e.Json, nm, err) then Exit;
  M := nm;
  ResolveDecor;
  SelKind := e.Kind;
  SelPath := e.Path;
  SelIdx := e.Idx;
  RoadDirty := True;
  Modified := True;
end;

procedure DoUndo;
begin
  if Length(UndoStack) = 0 then
  begin
    Status('Nothing to undo');
    Exit;
  end;
  SetLength(RedoStack, Length(RedoStack) + 1);
  RedoStack[High(RedoStack)] := Snapshot;
  Restore(UndoStack[High(UndoStack)]);
  SetLength(UndoStack, Length(UndoStack) - 1);
  Status('Undo');
end;

procedure DoRedo;
begin
  if Length(RedoStack) = 0 then
  begin
    Status('Nothing to redo');
    Exit;
  end;
  SetLength(UndoStack, Length(UndoStack) + 1);
  UndoStack[High(UndoStack)] := Snapshot;
  Restore(RedoStack[High(RedoStack)]);
  SetLength(RedoStack, Length(RedoStack) - 1);
  Status('Redo');
end;

{ ======================================================================
  files
  ====================================================================== }

function MapsDir: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'maps' + PathDelim;
end;

procedure UpdateTitle;
var
  t: string;
begin
  t := 'MapEdit - ';
  if MapFile <> '' then t := t + ExtractFileName(MapFile) else t := t + '(unsaved map)';
  t := t + '  [' + M.Name + ']';
  if Modified then t := t + ' *';
  SDL_SetWindowTitle(Window, PAnsiChar(t));
end;

procedure FitView;
begin
  ViewZoom := Min((CV_W - 40) / M.Width, (CV_H - 40) / M.Height);
  PanX := (CV_W - M.Width * ViewZoom) / 2;
  PanY := (CV_H - M.Height * ViewZoom) / 2;
end;

procedure ResetSelection;
begin
  SelKind := skNone;
  SelPath := -1;
  SelIdx := -1;
  ActivePath := 0;
  EditKey := '';
end;

function OpenMap(const fn: string): Boolean;
var
  err: string;
  nm: TMapDef;
begin
  nm := Default(TMapDef);
  Result := LoadMapFile(fn, nm, err);
  if not Result then
  begin
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Open failed', PAnsiChar(err), Window);
    Exit;
  end;
  M := nm;
  MapFile := fn;
  ResolveDecor;
  ResetSelection;
  SetLength(UndoStack, 0);
  SetLength(RedoStack, 0);
  Modified := False;
  RoadDirty := True;
  FitView;
  Status(Format('Opened %s: %d paths, %d plots, %d decorations',
    [ExtractFileName(fn), Length(M.Paths), Length(M.PlotX), Length(M.Decor)]));
end;

procedure NewMap;
begin
  M := NewMapDef('New Map');
  MapFile := '';
  ResetSelection;
  SetLength(UndoStack, 0);
  SetLength(RedoStack, 0);
  Modified := False;
  RoadDirty := True;
  FitView;
  Status('New map: one road from left to right. Add plots with the Plots tool, then Save as...');
end;

function SaveMap(const fn: string): Boolean;
begin
  Result := SaveMapFile(fn, M);
  if Result then
  begin
    MapFile := fn;
    Modified := False;
    Status('Saved ' + fn);
  end
  else
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Save failed', PAnsiChar('Could not write ' + fn), Window);
end;

procedure DialogCallback(userdata: Pointer; filelist: PPAnsiChar; filter: LongInt); cdecl;
begin
  EnterCriticalSection(DlgLock);
  try
    if (filelist <> nil) and (filelist^ <> nil) then
    begin
      DlgPath := string(filelist^);
      DlgKind := PtrInt(userdata);
      DlgReady := True;
    end;
  finally
    LeaveCriticalSection(DlgLock);
  end;
end;

procedure AskOpen;
begin
  SDL_ShowOpenFileDialog(@DialogCallback, Pointer(1), Window, @JsonFilter[0], 1, PAnsiChar(MapsDir), False);
end;

procedure AskSaveAs;
var
  def: string;
begin
  if MapFile <> '' then def := MapFile
  else def := MapsDir + LowerCase(StringReplace(M.Name, ' ', '_', [rfReplaceAll])) + '.json';
  SDL_ShowSaveFileDialog(@DialogCallback, Pointer(2), Window, @JsonFilter[0], 1, PAnsiChar(def));
end;

procedure DoSave;
begin
  if MapFile = '' then AskSaveAs else SaveMap(MapFile);
end;

function ConfirmDiscard: Boolean;
var
  btn: array[0..2] of TSDL_MessageBoxButtonData;
  data: TSDL_MessageBoxData;
  hit: LongInt;
begin
  Result := True;
  if not Modified then Exit;
  btn[0].flags := SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT; btn[0].buttonID := 0; btn[0].Text := 'Save';
  btn[1].flags := 0; btn[1].buttonID := 1; btn[1].Text := 'Discard';
  btn[2].flags := SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT; btn[2].buttonID := 2; btn[2].Text := 'Cancel';
  FillChar(data, SizeOf(data), 0);
  data.flags := SDL_MESSAGEBOX_WARNING;
  data.window := Window;
  data.title := 'Unsaved changes';
  data.message := 'The map has unsaved changes. Save first?';
  data.numbuttons := 3;
  data.Buttons := @btn[0];
  hit := 2;
  SDL_ShowMessageBox(@data, @hit);
  case hit of
    0:
      begin
        if MapFile = '' then
        begin
          AskSaveAs;
          Exit(False);
        end;
        Result := SaveMap(MapFile);
      end;
    1: Result := True;
  else
    Result := False;
  end;
end;

procedure HandleDialogResult;
var
  p: string;
  k: Integer;
begin
  EnterCriticalSection(DlgLock);
  try
    if not DlgReady then Exit;
    p := DlgPath;
    k := DlgKind;
    DlgReady := False;
  finally
    LeaveCriticalSection(DlgLock);
  end;
  if k = 1 then OpenMap(p)
  else if k = 2 then
  begin
    if ExtractFileExt(p) = '' then p := p + '.json';
    SaveMap(p);
  end;
end;

procedure PlayTest;
var
  pr: TProcess;
  exe, name: string;
begin
  if MapFile = '' then
  begin
    Status('Save the map into data\maps first (Save as...)');
    AskSaveAs;
    Exit;
  end;
  if not SameText(ExpandFileName(ExtractFilePath(MapFile)), ExpandFileName(MapsDir)) then
  begin
    Status('Play test needs the map saved in ' + MapsDir);
    Exit;
  end;
  if Modified and not SaveMap(MapFile) then Exit;
  exe := ExtractFilePath(ParamStr(0)) + 'towerdefense.exe';
  if not FileExists(exe) then
  begin
    Status('towerdefense.exe not found next to MapEdit');
    Exit;
  end;
  name := ChangeFileExt(ExtractFileName(MapFile), '');
  pr := TProcess.Create(nil);
  try
    pr.Executable := exe;
    pr.Parameters.Add('--map');
    pr.Parameters.Add(name);
    pr.CurrentDirectory := ExtractFilePath(exe);
    pr.Options := [];
    pr.Execute;
    Status('Started the game with map "' + name + '"');
  except
    on e: Exception do Status('Could not start the game: ' + e.Message);
  end;
  pr.Free;
end;

{ ======================================================================
  editing operations
  ====================================================================== }

procedure Select(k: TSelKind; p, i: Integer);
begin
  SelKind := k;
  SelPath := p;
  SelIdx := i;
  if (k in [skPoint, skEntrance]) and (p >= 0) then ActivePath := p;
  EditKey := '';
  PropScroll := 0;
end;

procedure HeroPos(out x, y: Single);
var
  dx, dy: Single;
begin
  x := M.HeroX;
  y := M.HeroY;
  if ((x = 0) and (y = 0)) and (Length(Paths) > 0) and (Paths[0].N > 1) then
    PathPos(Paths[0], Paths[0].Len * 0.72, x, y, dx, dy);
end;

procedure GetItemPos(k: TSelKind; p, i: Integer; out x, y: Single);
begin
  x := 0; y := 0;
  case k of
    skPoint: begin x := M.Paths[p].Ctrl[i * 2]; y := M.Paths[p].Ctrl[i * 2 + 1]; end;
    skEntrance: begin x := M.Paths[p].EntranceX; y := M.Paths[p].EntranceY; end;
    skHero: HeroPos(x, y);
    skPlot: begin x := M.PlotX[i]; y := M.PlotY[i]; end;
    skDecor: begin x := M.Decor[i].X; y := M.Decor[i].Y; end;
  end;
end;

procedure SetItemPos(k: TSelKind; p, i: Integer; x, y: Single);
begin
  case k of
    skPoint:
      begin
        M.Paths[p].Ctrl[i * 2] := x;
        M.Paths[p].Ctrl[i * 2 + 1] := y;
        RoadDirty := True;
      end;
    skEntrance: begin M.Paths[p].EntranceX := x; M.Paths[p].EntranceY := y; end;
    skHero: begin M.HeroX := Round(x); M.HeroY := Round(y); end;
    skPlot: begin M.PlotX[i] := x; M.PlotY[i] := y; end;
    skDecor: begin M.Decor[i].X := x; M.Decor[i].Y := y; end;
  end;
  Modified := True;
end;

function SelValid: Boolean;
begin
  case SelKind of
    skPoint: Result := (SelPath >= 0) and (SelPath <= High(M.Paths)) and (SelIdx >= 0) and (SelIdx < PointCount(SelPath));
    skEntrance: Result := (SelPath >= 0) and (SelPath <= High(M.Paths));
    skHero: Result := True;
    skPlot: Result := (SelIdx >= 0) and (SelIdx <= High(M.PlotX));
    skDecor: Result := (SelIdx >= 0) and (SelIdx <= High(M.Decor));
  else
    Result := False;
  end;
end;

procedure InsertPoint(p, after: Integer; x, y: Single);
var
  n, i: Integer;
begin
  n := PointCount(p);
  SetLength(M.Paths[p].Ctrl, (n + 1) * 2);
  for i := n - 1 downto after + 1 do
  begin
    M.Paths[p].Ctrl[(i + 1) * 2] := M.Paths[p].Ctrl[i * 2];
    M.Paths[p].Ctrl[(i + 1) * 2 + 1] := M.Paths[p].Ctrl[i * 2 + 1];
  end;
  M.Paths[p].Ctrl[(after + 1) * 2] := x;
  M.Paths[p].Ctrl[(after + 1) * 2 + 1] := y;
  MarkRoads;
  Select(skPoint, p, after + 1);
end;

procedure DeletePoint(p, idx: Integer);
var
  n, i: Integer;
begin
  n := PointCount(p);
  if n <= 2 then
  begin
    Status('A path needs at least 2 points (delete the whole path instead)');
    Exit;
  end;
  PushUndo;
  for i := idx to n - 2 do
  begin
    M.Paths[p].Ctrl[i * 2] := M.Paths[p].Ctrl[i * 2 + 2];
    M.Paths[p].Ctrl[i * 2 + 1] := M.Paths[p].Ctrl[i * 2 + 3];
  end;
  SetLength(M.Paths[p].Ctrl, (n - 1) * 2);
  MarkRoads;
  Select(skPoint, p, Min(idx, n - 2));
end;

procedure NewPath;
var
  n: Integer;
  ex, ey: Single;
begin
  PushUndo;
  n := Length(M.Paths);
  SetLength(M.Paths, n + 1);
  // a new road entering from the top, joining the middle of the map
  SetLength(M.Paths[n].Ctrl, 8);
  M.Paths[n].Ctrl[0] := M.Width * 0.4; M.Paths[n].Ctrl[1] := -70;
  M.Paths[n].Ctrl[2] := M.Width * 0.4; M.Paths[n].Ctrl[3] := 60;
  M.Paths[n].Ctrl[4] := M.Width * 0.5; M.Paths[n].Ctrl[5] := M.Height * 0.3;
  M.Paths[n].Ctrl[6] := M.Width + 70;  M.Paths[n].Ctrl[7] := M.Height * 0.5;
  ex := M.Width * 0.4; ey := 34;
  M.Paths[n].EntranceX := ex;
  M.Paths[n].EntranceY := ey;
  MarkRoads;
  Select(skPoint, n, 1);
  Status('New path added. Drag its points; share the last points with another path to merge roads.');
end;

procedure DeletePath(p: Integer);
var
  i: Integer;
begin
  if Length(M.Paths) <= 1 then
  begin
    Status('The map needs at least one path');
    Exit;
  end;
  PushUndo;
  for i := p to High(M.Paths) - 1 do M.Paths[i] := M.Paths[i + 1];
  SetLength(M.Paths, Length(M.Paths) - 1);
  MarkRoads;
  ResetSelection;
  Status(Format('Path %d deleted. Check waves.json: groups use path indexes.', [p]));
end;

procedure ReversePath(p: Integer);
var
  n, i: Integer;
  t: Single;
begin
  PushUndo;
  n := PointCount(p);
  for i := 0 to n div 2 - 1 do
  begin
    t := M.Paths[p].Ctrl[i * 2]; M.Paths[p].Ctrl[i * 2] := M.Paths[p].Ctrl[(n - 1 - i) * 2];
    M.Paths[p].Ctrl[(n - 1 - i) * 2] := t;
    t := M.Paths[p].Ctrl[i * 2 + 1]; M.Paths[p].Ctrl[i * 2 + 1] := M.Paths[p].Ctrl[(n - 1 - i) * 2 + 1];
    M.Paths[p].Ctrl[(n - 1 - i) * 2 + 1] := t;
  end;
  MarkRoads;
  Status('Path reversed: enemies now walk the other way');
end;

// put the entrance skull where the road enters the visible map
procedure AutoEntrance(p: Integer);
var
  i: Integer;
  x, y: Single;
begin
  if (p < 0) or (p >= Length(Paths)) or (Paths[p].N = 0) then Exit;
  PushUndo;
  for i := 0 to Paths[p].N - 1 do
  begin
    x := Paths[p].X[i];
    y := Paths[p].Y[i];
    if (x >= 34) and (x <= M.Width - 34) and (y >= 34) and (y <= M.Height - 34) then
    begin
      M.Paths[p].EntranceX := Round(x);
      M.Paths[p].EntranceY := Round(y);
      Break;
    end;
  end;
  Modified := True;
end;

procedure AddPlot(x, y: Single);
var
  n: Integer;
begin
  PushUndo;
  n := Length(M.PlotX);
  SetLength(M.PlotX, n + 1);
  SetLength(M.PlotY, n + 1);
  M.PlotX[n] := x;
  M.PlotY[n] := y;
  Select(skPlot, -1, n);
end;

procedure DeletePlot(i: Integer);
var
  k: Integer;
begin
  PushUndo;
  for k := i to High(M.PlotX) - 1 do
  begin
    M.PlotX[k] := M.PlotX[k + 1];
    M.PlotY[k] := M.PlotY[k + 1];
  end;
  SetLength(M.PlotX, Length(M.PlotX) - 1);
  SetLength(M.PlotY, Length(M.PlotY) - 1);
  ResetSelection;
end;

function PlotSpotOk(x, y: Single): Boolean;
var
  k: Integer;
  d: Single;
begin
  Result := False;
  if (x < 50) or (y < 90) or (x > M.Width - 50) or (y > M.Height - 40) then Exit;
  if M.Fortress and (x > M.Width - 100) then Exit;
  d := DistToPaths(Paths, x, y);
  if (d < 72) or (d > 92) then Exit;
  for k := 0 to High(M.PlotX) do
    if Dist2(x, y, M.PlotX[k], M.PlotY[k]) < Sqr(118) then Exit;
  Result := True;
end;

// fill free road-side spots with plots (same rule the original map generator used)
procedure AutoPlots;
var
  x, y, added, i, j: Integer;
  cand: array of TPoint;
  t: TPoint;
begin
  PushUndo;
  SetLength(cand, 0);
  y := 90;
  while y <= M.Height - 30 do
  begin
    x := 50;
    while x <= M.Width - 50 do
    begin
      SetLength(cand, Length(cand) + 1);
      cand[High(cand)].x := x;
      cand[High(cand)].y := y;
      Inc(x, 15);
    end;
    Inc(y, 15);
  end;
  for i := High(cand) downto 1 do
  begin
    j := Random(i + 1);
    t := cand[i]; cand[i] := cand[j]; cand[j] := t;
  end;
  added := 0;
  for i := 0 to High(cand) do
    if PlotSpotOk(cand[i].x, cand[i].y) then
    begin
      SetLength(M.PlotX, Length(M.PlotX) + 1);
      SetLength(M.PlotY, Length(M.PlotY) + 1);
      M.PlotX[High(M.PlotX)] := cand[i].x;
      M.PlotY[High(M.PlotY)] := cand[i].y;
      Inc(added);
    end;
  Status(Format('Auto-placed %d plots (top-left HUD area is kept free: move plots out of it if needed)', [added]));
end;

procedure AddDecor(g: Integer; x, y, s: Single);
var
  n: Integer;
begin
  if (g < 0) or (g >= Lib.Count) then Exit;
  n := Length(M.Decor);
  SetLength(M.Decor, n + 1);
  M.Decor[n].Geo := Lib.Objects[g].Name;
  M.Decor[n].GeoIdx := g;
  M.Decor[n].X := x;
  M.Decor[n].Y := y;
  M.Decor[n].S := s;
  Modified := True;
  Select(skDecor, -1, n);
end;

procedure DeleteDecor(i: Integer);
var
  k: Integer;
begin
  PushUndo;
  for k := i to High(M.Decor) - 1 do M.Decor[k] := M.Decor[k + 1];
  SetLength(M.Decor, Length(M.Decor) - 1);
  ResetSelection;
end;

function DecorScale: Single;
begin
  if RandScale then Result := Round(PlaceScale * RandF(0.8, 1.2) * 100) / 100 else Result := PlaceScale;
end;

procedure Scatter(count: Integer);
var
  tries, placed, k, g: Integer;
  x, y: Single;
  ok: Boolean;
begin
  if Length(Palette) = 0 then Exit;
  g := Palette[PalSel];
  PushUndo;
  placed := 0;
  for tries := 1 to count * 40 do
  begin
    if placed >= count then Break;
    x := RandF(20, M.Width - 20);
    y := RandF(20, M.Height - 20);
    if M.Fortress and (x > M.Width - 100) then Continue;
    if DistToPaths(Paths, x, y) < M.PathHalf + 22 then Continue;
    ok := True;
    for k := 0 to High(M.PlotX) do
      if Dist2(x, y, M.PlotX[k], M.PlotY[k]) < Sqr(55) then ok := False;
    for k := 0 to High(M.Decor) do
      if Dist2(x, y, M.Decor[k].X, M.Decor[k].Y) < Sqr(26) then ok := False;
    if not ok then Continue;
    AddDecor(g, Round(x), Round(y), DecorScale);
    Inc(placed);
  end;
  ResetSelection;
  Status(Format('Scattered %d x %s away from roads and plots', [placed, Lib.Objects[g].Name]));
end;

procedure DuplicateSel;
var
  x, y: Single;
begin
  if not SelValid then Exit;
  case SelKind of
    skPlot:
      begin
        GetItemPos(skPlot, -1, SelIdx, x, y);
        AddPlot(x + 30, y + 30);
      end;
    skDecor:
      begin
        PushUndo;
        AddDecor(M.Decor[SelIdx].GeoIdx, M.Decor[SelIdx].X + 20, M.Decor[SelIdx].Y + 10, M.Decor[SelIdx].S);
      end;
  end;
end;

procedure DeleteSel;
begin
  if not SelValid then Exit;
  case SelKind of
    skPoint: DeletePoint(SelPath, SelIdx);
    skPlot: DeletePlot(SelIdx);
    skDecor: DeleteDecor(SelIdx);
    skEntrance: Status('Entrances cannot be deleted (delete the path instead)');
    skHero:
      begin
        PushUndo;
        M.HeroX := 0;
        M.HeroY := 0;
        Status('Hero spawn is automatic again (72% along road 0)');
      end;
  end;
end;

{ ======================================================================
  validation
  ====================================================================== }

procedure AddIssue(const t: string; k: TSelKind; p, i: Integer; x, y: Single; severe: Boolean);
begin
  SetLength(Issues, Length(Issues) + 1);
  Issues[High(Issues)].Text := t;
  Issues[High(Issues)].Kind := k;
  Issues[High(Issues)].Path := p;
  Issues[High(Issues)].Idx := i;
  Issues[High(Issues)].X := x;
  Issues[High(Issues)].Y := y;
  Issues[High(Issues)].Severe := severe;
end;

function OnScreen(x, y, margin: Single): Boolean;
begin
  Result := (x > -margin) and (y > -margin) and (x < M.Width + margin) and (y < M.Height + margin);
end;

procedure Validate;
var
  i, k, n: Integer;
  d, x, y: Single;
begin
  SetLength(Issues, 0);
  if Length(M.PlotX) = 0 then AddIssue('No tower plots yet', skNone, -1, -1, 0, 0, True);
  if (M.WavesFile <> '') and not FileExists(ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + M.WavesFile) then
    AddIssue('Waves file "' + M.WavesFile + '" not found (create it in WaveEdit)', skNone, -1, -1, 0, 0, True);
  if (M.Music <> '') and not FileExists(ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'music' + PathDelim + M.Music) then
    AddIssue('Music "' + M.Music + '" not found in data\music (create it in MusicEdit)', skNone, -1, -1, 0, 0, True);
  for i := 0 to High(M.Paths) do
  begin
    n := PointCount(i);
    if n < 2 then Continue;
    x := M.Paths[i].Ctrl[0]; y := M.Paths[i].Ctrl[1];
    if OnScreen(x, y, -1) then
      AddIssue(Format('Path %d starts inside the map (enemies pop in)', [i]), skPoint, i, 0, x, y, False);
    x := M.Paths[i].Ctrl[(n - 1) * 2]; y := M.Paths[i].Ctrl[(n - 1) * 2 + 1];
    if OnScreen(x, y, -1) then
      AddIssue(Format('Path %d ends inside the map (no exit)', [i]), skPoint, i, n - 1, x, y, True);
    x := M.Paths[i].EntranceX; y := M.Paths[i].EntranceY;
    if not OnScreen(x, y, -20) then
      AddIssue(Format('Path %d entrance skull is off-screen', [i]), skEntrance, i, -1, x, y, True)
    else if DistToPaths(Paths, x, y) > M.PathHalf + 30 then
      AddIssue(Format('Path %d entrance is far from its road', [i]), skEntrance, i, -1, x, y, False);
  end;
  for i := 0 to High(M.PlotX) do
  begin
    d := DistToPaths(Paths, M.PlotX[i], M.PlotY[i]);
    if d < PLOT_MIN_ROAD then
      AddIssue(Format('Plot %d overlaps the road (%dpx)', [i, Round(d)]), skPlot, -1, i, M.PlotX[i], M.PlotY[i], True)
    else if d > PLOT_MAX_ROAD then
      AddIssue(Format('Plot %d is far from the road (%dpx)', [i, Round(d)]), skPlot, -1, i, M.PlotX[i], M.PlotY[i], False);
    for k := i + 1 to High(M.PlotX) do
      if Dist2(M.PlotX[i], M.PlotY[i], M.PlotX[k], M.PlotY[k]) < Sqr(PLOT_SPACING) then
        AddIssue(Format('Plots %d and %d overlap', [i, k]), skPlot, -1, k, M.PlotX[k], M.PlotY[k], True);
    if (M.PlotX[i] < 380) and (M.PlotY[i] < 90) then
      AddIssue(Format('Plot %d is under the HUD panel', [i]), skPlot, -1, i, M.PlotX[i], M.PlotY[i], False);
    if (M.PlotX[i] < 410) and (M.PlotY[i] > 610) then
      AddIssue(Format('Plot %d is under the spell / hero buttons', [i]), skPlot, -1, i, M.PlotX[i], M.PlotY[i], False);
  end;
  for i := 0 to High(M.Decor) do
  begin
    if M.Decor[i].GeoIdx < 0 then
      AddIssue(Format('Decor %d: unknown geometry "%s"', [i, M.Decor[i].Geo]), skDecor, -1, i,
        M.Decor[i].X, M.Decor[i].Y, True)
    else if DistToPaths(Paths, M.Decor[i].X, M.Decor[i].Y) < M.PathHalf - 4 then
      AddIssue(Format('Decor %d (%s) is on the road', [i, M.Decor[i].Geo]), skDecor, -1, i,
        M.Decor[i].X, M.Decor[i].Y, False);
    for k := 0 to High(M.PlotX) do
      if Dist2(M.Decor[i].X, M.Decor[i].Y, M.PlotX[k], M.PlotY[k]) < Sqr(36) then
        AddIssue(Format('Decor %d covers plot %d', [i, k]), skDecor, -1, i, M.Decor[i].X, M.Decor[i].Y, False);
  end;
end;

{ ======================================================================
  properties
  ====================================================================== }

procedure AddRow(const key, caption: string; kind: TPropKind);
begin
  SetLength(Rows, Length(Rows) + 1);
  Rows[High(Rows)].Key := key;
  Rows[High(Rows)].Caption := caption;
  Rows[High(Rows)].Kind := kind;
end;

procedure BuildRows;
begin
  SetLength(Rows, 0);
  if not SelValid then
  begin
    AddRow('name', 'map name', pkText);
    AddRow('desc', 'description', pkText);
    AddRow('waves', 'waves file', pkText);
    AddRow('music', 'music', pkText);
    AddRow('seed', 'ground seed', pkNum);
    AddRow('half', 'road half width', pkNum);
    AddRow('fortress', 'fortress gate', pkBool);
    AddRow('ground', 'ground', pkColor);
    AddRow('groundDark', 'ground dark', pkColor);
    AddRow('groundLight', 'ground light', pkColor);
    AddRow('roadBorder', 'road border', pkColor);
    AddRow('roadEdge', 'road edge', pkColor);
    AddRow('roadSand', 'road sand', pkColor);
    AddRow('roadLight', 'road highlight', pkColor);
    AddRow('', Format('%d paths, %d plots, %d decorations', [Length(M.Paths), Length(M.PlotX), Length(M.Decor)]), pkInfo);
    Exit;
  end;
  case SelKind of
    skPoint:
      begin
        AddRow('', Format('Path %d - point %d of %d', [SelPath, SelIdx, PointCount(SelPath)]), pkInfo);
        AddRow('x', 'x', pkNum);
        AddRow('y', 'y', pkNum);
        AddRow('ex', 'entrance x', pkNum);
        AddRow('ey', 'entrance y', pkNum);
        if SelPath <= High(Paths) then
          AddRow('', Format('road length %d px', [Round(Paths[SelPath].Len)]), pkInfo);
      end;
    skHero:
      begin
        AddRow('', 'Hero spawn point', pkInfo);
        AddRow('x', 'x', pkNum);
        AddRow('y', 'y', pkNum);
        if (M.HeroX = 0) and (M.HeroY = 0) then
          AddRow('', 'automatic: 72% along road 0 (drag to fix)', pkInfo)
        else
          AddRow('', 'fixed position (Delete = automatic again)', pkInfo);
      end;
    skEntrance:
      begin
        AddRow('', Format('Path %d - entrance (wave skull)', [SelPath]), pkInfo);
        AddRow('ex', 'x', pkNum);
        AddRow('ey', 'y', pkNum);
      end;
    skPlot:
      begin
        AddRow('', Format('Tower plot %d', [SelIdx]), pkInfo);
        AddRow('x', 'x', pkNum);
        AddRow('y', 'y', pkNum);
        AddRow('', Format('distance to road %d px', [Round(DistToPaths(Paths, M.PlotX[SelIdx], M.PlotY[SelIdx]))]), pkInfo);
      end;
    skDecor:
      begin
        AddRow('', Format('Decoration %d', [SelIdx]), pkInfo);
        AddRow('geo', 'geometry', pkEnum);
        AddRow('x', 'x', pkNum);
        AddRow('y', 'y', pkNum);
        AddRow('scale', 'scale', pkNum);
      end;
  end;
end;

function ColorRef(const key: string): PRGBA;
begin
  case key of
    'ground': Result := @M.Ground;
    'groundDark': Result := @M.GroundDark;
    'groundLight': Result := @M.GroundLight;
    'roadBorder': Result := @M.RoadBorder;
    'roadEdge': Result := @M.RoadEdge;
    'roadSand': Result := @M.RoadSand;
    'roadLight': Result := @M.RoadLight;
  else
    Result := nil;
  end;
end;

function GetNum(const key: string): Single;
var
  hx, hy: Single;
begin
  Result := 0;
  case key of
    'seed': Exit(M.Seed);
    'half': Exit(M.PathHalf);
  end;
  if not SelValid then Exit;
  case key of
    'x', 'y':
      begin
        case SelKind of
          skPoint: Result := M.Paths[SelPath].Ctrl[SelIdx * 2 + Ord(key = 'y')];
          skPlot: if key = 'x' then Result := M.PlotX[SelIdx] else Result := M.PlotY[SelIdx];
          skDecor: if key = 'x' then Result := M.Decor[SelIdx].X else Result := M.Decor[SelIdx].Y;
          skHero:
            begin
              HeroPos(hx, hy);
              if key = 'x' then Result := hx else Result := hy;
            end;
        end;
      end;
    'ex': Result := M.Paths[SelPath].EntranceX;
    'ey': Result := M.Paths[SelPath].EntranceY;
    'scale': Result := M.Decor[SelIdx].S;
  end;
end;

procedure SetNum(const key: string; v: Single);
begin
  case key of
    'seed':
      begin
        M.Seed := Max(0, Round(v));
        MarkRoads;
        Exit;
      end;
    'half':
      begin
        M.PathHalf := EnsureRange(v, 16, 80);
        MarkRoads;
        Exit;
      end;
  end;
  if not SelValid then Exit;
  case key of
    'x', 'y':
      case SelKind of
        skPoint:
          begin
            M.Paths[SelPath].Ctrl[SelIdx * 2 + Ord(key = 'y')] := v;
            MarkRoads;
          end;
        skPlot: if key = 'x' then M.PlotX[SelIdx] := v else M.PlotY[SelIdx] := v;
        skDecor: if key = 'x' then M.Decor[SelIdx].X := v else M.Decor[SelIdx].Y := v;
        skHero:
          begin
            if (M.HeroX = 0) and (M.HeroY = 0) then HeroPos(M.HeroX, M.HeroY);
            if key = 'x' then M.HeroX := v else M.HeroY := v;
          end;
      end;
    'ex': M.Paths[SelPath].EntranceX := v;
    'ey': M.Paths[SelPath].EntranceY := v;
    'scale': M.Decor[SelIdx].S := EnsureRange(v, 0.1, 5);
  end;
  Modified := True;
end;

function NumStep(const key: string): Single;
begin
  if key = 'scale' then Result := 0.05
  else Result := 1;
  if ModShift then Result := Result / 5
  else if ModCtrl then Result := Result * 10;
end;

function GetText(const key: string): string;
var
  c: PRGBA;
begin
  c := ColorRef(key);
  if c <> nil then Exit(ColorToStr(c^));
  case key of
    'name': Result := M.Name;
    'desc': Result := M.Desc;
    'waves': Result := M.WavesFile;
    'music': Result := M.Music;
    'fortress': Result := BoolToStr(M.Fortress, 'yes', 'no');
    'geo':
      if SelValid and (SelKind = skDecor) then Result := M.Decor[SelIdx].Geo else Result := '';
  else
    Result := FmtNum(GetNum(key));
  end;
end;

procedure CommitText(const key, value: string);
var
  c: PRGBA;
  v: Single;
  fs: TFormatSettings;
begin
  PushUndo;
  c := ColorRef(key);
  if c <> nil then
  begin
    c^ := ParseColor(value, c^);
    MarkRoads;
    Exit;
  end;
  if key = 'name' then
  begin
    M.Name := Trim(value);
    Exit;
  end;
  if key = 'desc' then
  begin
    M.Desc := Trim(value);
    Exit;
  end;
  if key = 'music' then
  begin
    M.Music := Trim(value);
    Exit;
  end;
  if key = 'waves' then
  begin
    M.WavesFile := Trim(value);
    if M.WavesFile = '' then M.WavesFile := 'waves.json';
    Exit;
  end;
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  if TryStrToFloat(StringReplace(Trim(value), ',', '.', []), v, fs) then SetNum(key, v)
  else Status('Not a number: ' + value);
end;

procedure CycleGeo(dir: Integer);
var
  i, cur: Integer;
begin
  if not (SelValid and (SelKind = skDecor)) or (Length(Palette) = 0) then Exit;
  cur := 0;
  for i := 0 to High(Palette) do
    if Palette[i] = M.Decor[SelIdx].GeoIdx then cur := i;
  cur := (cur + dir + Length(Palette)) mod Length(Palette);
  PushUndo;
  M.Decor[SelIdx].GeoIdx := Palette[cur];
  M.Decor[SelIdx].Geo := Lib.Objects[Palette[cur]].Name;
end;

procedure BeginEdit(const key: string);
begin
  EditKey := key;
  EditBuf := GetText(key);
  SDL_StartTextInput(Window);
end;

procedure EndEdit(commit: Boolean);
var
  k: string;
begin
  if EditKey = '' then Exit;
  k := EditKey;
  EditKey := '';
  SDL_StopTextInput(Window);
  if commit then CommitText(k, EditBuf);
end;

{ ======================================================================
  hit testing
  ====================================================================== }

function HitPoint(sx, sy: Single; out p, i: Integer): Boolean;
var
  a, b: Integer;
  x, y: Single;
begin
  Result := False;
  for a := High(M.Paths) downto 0 do
    for b := 0 to PointCount(a) - 1 do
    begin
      MapToScreen(M.Paths[a].Ctrl[b * 2], M.Paths[a].Ctrl[b * 2 + 1], x, y);
      if Dist2(sx, sy, x, y) <= Sqr(9) then
      begin
        p := a;
        i := b;
        Exit(True);
      end;
    end;
end;

function HitEntrance(sx, sy: Single; out p: Integer): Boolean;
var
  a: Integer;
  x, y: Single;
begin
  Result := False;
  for a := High(M.Paths) downto 0 do
  begin
    MapToScreen(M.Paths[a].EntranceX, M.Paths[a].EntranceY, x, y);
    if Dist2(sx, sy, x, y) <= Sqr(Max(10, 22 * ViewZoom)) then
    begin
      p := a;
      Exit(True);
    end;
  end;
end;

function HitPlot(mx_, my_: Single): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := High(M.PlotX) downto 0 do
    if Sqr((mx_ - M.PlotX[i]) / 36) + Sqr((my_ - M.PlotY[i]) / 22) <= 1 then Exit(i);
end;

function HitDecor(mx_, my_: Single): Integer;
var
  i, g: Integer;
  lx, ly, best: Single;
begin
  Result := -1;
  best := 1e9;
  for i := High(M.Decor) downto 0 do
  begin
    g := M.Decor[i].GeoIdx;
    if g < 0 then Continue;
    lx := (mx_ - M.Decor[i].X) / M.Decor[i].S;
    ly := (my_ - M.Decor[i].Y) / M.Decor[i].S;
    if (lx >= GeoBX0[g]) and (lx <= GeoBX1[g]) and (ly >= GeoBY0[g]) and (ly <= GeoBY1[g]) then
      // prefer the one drawn in front (largest y)
      if (Result < 0) or (M.Decor[i].Y > best) then
      begin
        Result := i;
        best := M.Decor[i].Y;
      end;
  end;
end;

// nearest control segment of path p to a map position (for inserting points)
function NearestSegment(p: Integer; x, y: Single): Integer;
var
  i, bi: Integer;
  d, bd: Single;
begin
  bi := 0;
  bd := 1e12;
  for i := 0 to Paths[p].N - 1 do
  begin
    d := Dist2(x, y, Paths[p].X[i], Paths[p].Y[i]);
    if d < bd then
    begin
      bd := d;
      bi := i;
    end;
  end;
  Result := EnsureRange(bi div 24, 0, PointCount(p) - 2);
  if bd > Sqr(M.PathHalf + 10) then Result := -1;
end;

{ ======================================================================
  drawing
  ====================================================================== }

procedure RebuildBackground;
begin
  BuildAllPaths(M, Paths);
  if BgTex <> nil then SDL_DestroyTexture(BgTex);
  SDL_SetRenderLogicalPresentation(Renderer, WIN_W, WIN_H, SDL_LOGICAL_PRESENTATION_DISABLED);
  BgTex := SDL_CreateTexture(Renderer, SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_TARGET, M.Width, M.Height);
  SDL_SetRenderTarget(Renderer, BgTex);
  SDL_SetRenderDrawColor(Renderer, 0, 0, 0, 255);
  SDL_RenderClear(Renderer);
  DrawMapBase(M, Paths);
  if M.Fortress then DrawFortress(M.Width, M.Height);
  DrawVignette(M.Width, M.Height);
  SDL_SetRenderTarget(Renderer, nil);
  SDL_SetRenderLogicalPresentation(Renderer, WIN_W, WIN_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
  RoadDirty := False;
end;

procedure DrawSkull(x, y, r: Single; const c: TRGBA);
begin
  FillCircle(x, y, r + 3, RGBA(60, 20, 20, 230));
  FillCircle(x, y, r - 2, RGBA(40, 16, 14));
  r := r - 4;
  FillCircle(x, y - r * 0.15, r * 0.75, c);
  FillRect(x - r * 0.4, y + r * 0.3, r * 0.8, r * 0.4, c);
  FillCircle(x - r * 0.3, y - r * 0.15, r * 0.22, RGBA(30, 20, 20));
  FillCircle(x + r * 0.3, y - r * 0.15, r * 0.22, RGBA(30, 20, 20));
end;

procedure DrawObjects;
var
  order: array of Integer;     // >=0 decor index, <0 plot -(i+1)
  ys: array of Single;
  n, i, j, t: Integer;
  ty: Single;
  sx, sy: Single;
  st: TAnimState;
begin
  n := Length(M.Decor) + Length(M.PlotX);
  SetLength(order, n);
  SetLength(ys, n);
  for i := 0 to High(M.Decor) do
  begin
    order[i] := i;
    ys[i] := M.Decor[i].Y;
  end;
  for i := 0 to High(M.PlotX) do
  begin
    order[Length(M.Decor) + i] := -(i + 1);
    ys[Length(M.Decor) + i] := M.PlotY[i];
  end;
  for i := 1 to n - 1 do
  begin
    t := order[i];
    ty := ys[i];
    j := i - 1;
    while (j >= 0) and (ys[j] > ty) do
    begin
      order[j + 1] := order[j];
      ys[j + 1] := ys[j];
      Dec(j);
    end;
    order[j + 1] := t;
    ys[j + 1] := ty;
  end;
  st := DefaultAnimState;
  st.Time := AnimTime;
  for i := 0 to n - 1 do
    if order[i] >= 0 then
    begin
      t := order[i];
      MapToScreen(M.Decor[t].X, M.Decor[t].Y, sx, sy);
      st.Seed := t * 1.7;
      if M.Decor[t].GeoIdx >= 0 then
        DrawGeo(Lib.Objects[M.Decor[t].GeoIdx], sx, sy, M.Decor[t].S * ViewZoom, st)
      else
        FillCircle(sx, sy, 8, RGBA(255, 0, 255, 160));
    end
    else
    begin
      t := -order[i] - 1;
      MapToScreen(M.PlotX[t], M.PlotY[t], sx, sy);
      if PreviewMode and (GeoTowerPreview >= 0) and (t mod 3 = 0) then
      begin
        DrawGeoIdx(Lib, Lib.Find('plot.built'), sx, sy, ViewZoom, st);
        DrawGeoIdx(Lib, GeoTowerPreview, sx, sy, ViewZoom, st);
      end
      else
        DrawGeoIdx(Lib, GeoPlotEmpty, sx, sy, ViewZoom, st);
    end;
end;

procedure DrawOverlays;
var
  p, i, n: Integer;
  x1, y1, x2, y2, ax, ay, dx, dy, d, sx, sy: Single;
  c: TRGBA;
  sel: Boolean;
begin
  // map border
  MapToScreen(0, 0, x1, y1);
  MapToScreen(M.Width, M.Height, x2, y2);
  Ring((x1 + x2) / 2, (y1 + y2) / 2, 1, 1, 0, C_LINE);
  FillRect(x1, y1 - 1, x2 - x1, 1, RGBA(255, 255, 255, 90));
  FillRect(x1, y2, x2 - x1, 1, RGBA(255, 255, 255, 90));
  FillRect(x1 - 1, y1, 1, y2 - y1, RGBA(255, 255, 255, 90));
  FillRect(x2, y1, 1, y2 - y1, RGBA(255, 255, 255, 90));
  // HUD zones of the game (plots there are hard to click)
  MapToScreen(12, 10, x1, y1);
  FillRect(x1, y1, 352 * ViewZoom, 48 * ViewZoom, RGBA(0, 0, 0, 70));
  MapToScreen(1112, 12, x1, y1);
  FillRect(x1, y1, 156 * ViewZoom, 48 * ViewZoom, RGBA(0, 0, 0, 70));
  MapToScreen(24, 628, x1, y1);
  FillRect(x1, y1, 380 * ViewZoom, 84 * ViewZoom, RGBA(0, 0, 0, 70));

  if ShowRanges then
    for i := 0 to High(M.PlotX) do
    begin
      MapToScreen(M.PlotX[i], M.PlotY[i], sx, sy);
      Ring(sx, sy, TOWER_RANGE * ViewZoom, TOWER_RANGE * 0.72 * ViewZoom, 1.5, RGBA(255, 255, 255, 70));
    end;

  for p := 0 to High(M.Paths) do
  begin
    if p > High(Paths) then Break;
    c := PathColors[p mod Length(PathColors)];
    sel := (p = ActivePath);
    if not sel then c := WithAlpha(c, 150);
    // curve
    for i := 1 to Paths[p].N - 1 do
    begin
      MapToScreen(Paths[p].X[i - 1], Paths[p].Y[i - 1], x1, y1);
      MapToScreen(Paths[p].X[i], Paths[p].Y[i], x2, y2);
      ThickLine(x1, y1, x2, y2, IfThen(sel, 2.5, 1.5), c);
    end;
    // direction arrows
    d := 80;
    while d < Paths[p].Len do
    begin
      PathPos(Paths[p], d, ax, ay, dx, dy);
      MapToScreen(ax, ay, sx, sy);
      FillTri(sx + dx * 8, sy + dy * 8, sx - dx * 5 - dy * 6, sy - dy * 5 + dx * 6,
        sx - dx * 5 + dy * 6, sy - dy * 5 - dx * 6, c);
      d := d + 160;
    end;
    // control polygon + points
    n := PointCount(p);
    for i := 0 to n - 1 do
    begin
      MapToScreen(M.Paths[p].Ctrl[i * 2], M.Paths[p].Ctrl[i * 2 + 1], sx, sy);
      if i > 0 then
      begin
        MapToScreen(M.Paths[p].Ctrl[i * 2 - 2], M.Paths[p].Ctrl[i * 2 - 1], x1, y1);
        ThickLine(x1, y1, sx, sy, 1, WithAlpha(c, 60));
      end;
      if (SelKind = skPoint) and (SelPath = p) and (SelIdx = i) then
      begin
        FillCircle(sx, sy, 9, RGBA(255, 255, 255));
        FillCircle(sx, sy, 6, c);
      end
      else
      begin
        FillCircle(sx, sy, 7, RGBA(20, 20, 20, 220));
        FillCircle(sx, sy, 5, c);
      end;
      if sel then DrawText(sx + 8, sy - 18, IntToStr(i), c, fnSmall, ALIGN_LEFT, True);
    end;
    // entrance
    MapToScreen(M.Paths[p].EntranceX, M.Paths[p].EntranceY, sx, sy);
    DrawSkull(sx, sy, Max(8, 22 * ViewZoom), RGBA(230, 210, 190));
    Ring(sx, sy, Max(8, 22 * ViewZoom) + 5, Max(8, 22 * ViewZoom) + 5, 2, c);
    DrawText(sx, sy + Max(8, 22 * ViewZoom) + 6, 'path ' + IntToStr(p), c, fnSmall, ALIGN_CENTER, True);
    if (SelKind = skEntrance) and (SelPath = p) then
      Ring(sx, sy, Max(8, 22 * ViewZoom) + 9, Max(8, 22 * ViewZoom) + 9, 3, RGBA(255, 255, 255));
  end;

  // hero spawn banner
  HeroPos(x1, y1);
  MapToScreen(x1, y1, sx, sy);
  FillEllipse(sx, sy, 10, 4, RGBA(0, 0, 0, 90));
  ThickLine(sx, sy, sx, sy - 34 * Max(0.6, ViewZoom), 2.5, RGBA(230, 220, 200));
  FillQuad(sx, sy - 34 * Max(0.6, ViewZoom), sx + 20, sy - 30 * Max(0.6, ViewZoom), sx + 20,
    sy - 18 * Max(0.6, ViewZoom), sx, sy - 22 * Max(0.6, ViewZoom), RGBA(60, 200, 120));
  DrawText(sx + 10, sy - 33 * Max(0.6, ViewZoom), 'H', RGBA(255, 255, 255), fnSmall, ALIGN_CENTER, False);
  if (M.HeroX = 0) and (M.HeroY = 0) then
    DrawText(sx, sy + 4, 'hero (auto)', RGBA(200, 255, 210), fnSmall, ALIGN_CENTER, True)
  else
    DrawText(sx, sy + 4, 'hero', RGBA(200, 255, 210), fnSmall, ALIGN_CENTER, True);
  if SelKind = skHero then Ring(sx, sy - 14, 22, 22, 3, RGBA(255, 255, 255));

  // plots: numbers + selection
  for i := 0 to High(M.PlotX) do
  begin
    MapToScreen(M.PlotX[i], M.PlotY[i], sx, sy);
    DrawText(sx, sy - 8, IntToStr(i), RGBA(255, 240, 200), fnSmall, ALIGN_CENTER, True);
    if (SelKind = skPlot) and (SelIdx = i) then
      Ring(sx, sy, 40 * ViewZoom, 25 * ViewZoom, 3, RGBA(255, 255, 255));
  end;
  if (SelKind = skDecor) and SelValid and (M.Decor[SelIdx].GeoIdx >= 0) then
  begin
    i := M.Decor[SelIdx].GeoIdx;
    MapToScreen(M.Decor[SelIdx].X + GeoBX0[i] * M.Decor[SelIdx].S, M.Decor[SelIdx].Y + GeoBY0[i] * M.Decor[SelIdx].S, x1, y1);
    MapToScreen(M.Decor[SelIdx].X + GeoBX1[i] * M.Decor[SelIdx].S, M.Decor[SelIdx].Y + GeoBY1[i] * M.Decor[SelIdx].S, x2, y2);
    FillRect(x1, y1, x2 - x1, 1, C_ACCENT); FillRect(x1, y2, x2 - x1, 1, C_ACCENT);
    FillRect(x1, y1, 1, y2 - y1, C_ACCENT); FillRect(x2, y1, 1, y2 - y1, C_ACCENT);
    MapToScreen(M.Decor[SelIdx].X, M.Decor[SelIdx].Y, sx, sy);
    FillCircle(sx, sy, 3, C_ACCENT);
  end;
  // validation markers
  if ShowChecks then
    for i := 0 to High(Issues) do
      if Issues[i].Kind <> skNone then
      begin
        MapToScreen(Issues[i].X, Issues[i].Y, sx, sy);
        if Issues[i].Severe then c := RGBA(255, 60, 50, 230) else c := RGBA(255, 200, 40, 230);
        Ring(sx, sy, 16, 16, 2.5, c);
        FillRect(sx + 12, sy - 22, 4, 9, c);
        FillRect(sx + 12, sy - 11, 4, 3, c);
      end;
end;

procedure DrawGhost;
var
  mx_, my_, sx, sy, d: Single;
  st: TAnimState;
  g: Integer;
begin
  if not Inside(CV_X, CV_Y, CV_W, CV_H) or (Drag <> drNone) then Exit;
  ScreenToMap(MX, MY, mx_, my_);
  mx_ := SnapV(mx_);
  my_ := SnapV(my_);
  MapToScreen(mx_, my_, sx, sy);
  st := DefaultAnimState;
  st.Time := AnimTime;
  case Tool of
    TOOL_PLOT:
      if (HitPlot(mx_, my_) < 0) then
      begin
        d := DistToPaths(Paths, mx_, my_);
        if (d < PLOT_MIN_ROAD) then
          Ring(sx, sy, 36 * ViewZoom, 22 * ViewZoom, 3, RGBA(255, 60, 50, 200))
        else
        begin
          DrawGeoIdx(Lib, GeoPlotEmpty, sx, sy, ViewZoom, st);
          Ring(sx, sy, TOWER_RANGE * ViewZoom, TOWER_RANGE * 0.72 * ViewZoom, 1.5, RGBA(255, 255, 255, 110));
        end;
        DrawText(sx, sy + 26 * ViewZoom, Format('%d px to road', [Round(d)]), RGBA(255, 255, 255), fnSmall,
          ALIGN_CENTER, True);
      end;
    TOOL_DECOR:
      if (Length(Palette) > 0) and (HitDecor(mx_, my_) < 0) then
      begin
        g := Palette[PalSel];
        DrawGeo(Lib.Objects[g], sx, sy, PlaceScale * ViewZoom, st);
        Ring(sx, sy, 6, 6, 1.5, RGBA(255, 255, 255, 200));
      end;
    TOOL_PATH:
      if (ActivePath >= 0) and (ActivePath <= High(M.Paths)) then
      begin
        if ModCtrl then
        begin
          if NearestSegment(ActivePath, mx_, my_) >= 0 then
            FillCircle(sx, sy, 6, RGBA(255, 255, 255, 220));
        end
        else
          FillCircle(sx, sy, 5, WithAlpha(PathColors[ActivePath mod Length(PathColors)], 200));
      end;
  end;
end;

procedure DrawCanvas;
var
  dst: TSDL_FRect;
  mx_, my_: Single;
begin
  SetClip(CV_X, CV_Y, CV_W, CV_H);
  FillRect(CV_X, CV_Y, CV_W, CV_H, RGBA(22, 22, 26));
  dst.x := CV_X + PanX;
  dst.y := CV_Y + PanY;
  dst.w := M.Width * ViewZoom;
  dst.h := M.Height * ViewZoom;
  SDL_RenderTexture(Renderer, BgTex, nil, @dst);
  DrawObjects;
  if not PreviewMode then
  begin
    DrawOverlays;
    DrawGhost;
  end;
  if Inside(CV_X, CV_Y, CV_W, CV_H) then
  begin
    ScreenToMap(MX, MY, mx_, my_);
    DrawText(CV_X + 8, CV_Y + 6, Format('x %d   y %d   |   %s tool', [Round(mx_), Round(my_), ToolNames[Tool]]),
      RGBA(255, 255, 255, 220), fnSmall, ALIGN_LEFT, True);
  end;
  NoClip;
end;

{ ======================================================================
  panels
  ====================================================================== }

procedure DrawToolbar;
var
  x: Single;

  function TB(w: Single; const caption: string; active: Boolean = False; enabled: Boolean = True): Boolean;
  begin
    Result := Button(x, 8, w, 28, caption, active, enabled);
    x := x + w + 4;
  end;

  procedure Gap;
  begin
    FillRect(x + 3, 10, 1, 24, C_LINE);
    x := x + 10;
  end;

begin
  FillRect(0, 0, WIN_W, TOP_H, C_PANEL);
  FillRect(0, TOP_H - 1, WIN_W, 1, C_LINE);
  x := 8;
  if TB(50, 'New') and ConfirmDiscard then NewMap;
  if TB(56, 'Open') and ConfirmDiscard then AskOpen;
  if TB(56, 'Save') then DoSave;
  if TB(70, 'Save as') then AskSaveAs;
  Gap;
  if TB(52, 'Undo', False, Length(UndoStack) > 0) then DoUndo;
  if TB(52, 'Redo', False, Length(RedoStack) > 0) then DoRedo;
  Gap;
  if TB(50, 'Snap', SnapOn) then SnapOn := not SnapOn;
  if TB(66, 'Ranges', ShowRanges) then ShowRanges := not ShowRanges;
  if TB(64, 'Checks', ShowChecks) then ShowChecks := not ShowChecks;
  if TB(70, 'Preview', PreviewMode) then PreviewMode := not PreviewMode;
  Gap;
  if TB(40, 'Fit') then FitView;
  if TB(28, '-') then ViewZoom := Max(0.2, ViewZoom / 1.25);
  if TB(28, '+') then ViewZoom := Min(6, ViewZoom * 1.25);
  Gap;
  if TB(110, 'Play test (F5)') then PlayTest;
  DrawText(WIN_W - 10, 13, Format('zoom %d%%', [Round(ViewZoom * 100)]), C_DIM, fnSmall, ALIGN_RIGHT, False);
end;

procedure DrawLeftPanel;
var
  i, cols, cell, n, row, col, visible: Integer;
  x, y, y0, cx, cy, sc: Single;
  st: TAnimState;
  g: Integer;
begin
  FillRect(0, TOP_H, LEFT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
  FillRect(LEFT_W - 1, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  DrawText(10, TOP_H + 6, 'TOOLS', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  for i := 0 to 3 do
    if Button(8 + (i mod 2) * 113, TOP_H + 28 + (i div 2) * 32, 109, 28,
      IntToStr(i + 1) + '  ' + ToolNames[i], Tool = i) then
    begin
      Tool := i;
      EndEdit(True);
    end;
  y := TOP_H + 100;
  case Tool of
    TOOL_SELECT:
      begin
        DrawText(10, y, 'Click any point, plot or decoration', C_DIM, fnSmall, ALIGN_LEFT, False);
        DrawText(10, y + 18, 'to select it; drag to move.', C_DIM, fnSmall, ALIGN_LEFT, False);
      end;
    TOOL_PATH:
      begin
        DrawText(10, y, Format('Active path: %d of %d', [ActivePath, Length(M.Paths)]), C_TEXT, fnSmall, ALIGN_LEFT, False);
        if Button(8, y + 22, 109, 26, 'New path') then NewPath;
        if Button(121, y + 22, 109, 26, 'Delete path', False, Length(M.Paths) > 1) then DeletePath(ActivePath);
        if Button(8, y + 52, 109, 26, 'Reverse') then ReversePath(ActivePath);
        if Button(121, y + 52, 109, 26, 'Auto entrance') then AutoEntrance(ActivePath);
        if Button(8, y + 82, 109, 26, '< Prev path') then
          ActivePath := (ActivePath + Length(M.Paths) - 1) mod Length(M.Paths);
        if Button(121, y + 82, 109, 26, 'Next path >') then ActivePath := (ActivePath + 1) mod Length(M.Paths);
        DrawText(10, y + 116, 'Click empty space: append point', C_DIM, fnSmall, ALIGN_LEFT, False);
        DrawText(10, y + 134, 'Shift+click: prepend point', C_DIM, fnSmall, ALIGN_LEFT, False);
        DrawText(10, y + 152, 'Ctrl+click on road: insert point', C_DIM, fnSmall, ALIGN_LEFT, False);
        DrawText(10, y + 170, 'Del: delete point', C_DIM, fnSmall, ALIGN_LEFT, False);
        DrawText(10, y + 196, 'Start and end roads off-screen.', C_DIM, fnSmall, ALIGN_LEFT, False);
        DrawText(10, y + 214, 'Roads ending on the same points', C_DIM, fnSmall, ALIGN_LEFT, False);
        DrawText(10, y + 232, 'merge into one.', C_DIM, fnSmall, ALIGN_LEFT, False);
      end;
    TOOL_PLOT:
      begin
        DrawText(10, y, Format('%d plots', [Length(M.PlotX)]), C_TEXT, fnSmall, ALIGN_LEFT, False);
        if Button(8, y + 22, 109, 26, 'Auto-place') then AutoPlots;
        if Button(121, y + 22, 109, 26, 'Clear all', False, Length(M.PlotX) > 0) then
        begin
          PushUndo;
          SetLength(M.PlotX, 0);
          SetLength(M.PlotY, 0);
          ResetSelection;
        end;
        DrawText(10, y + 58, 'Click empty space: add a plot', C_DIM, fnSmall, ALIGN_LEFT, False);
        DrawText(10, y + 76, Format('Good distance to the road: %d-%d px', [PLOT_MIN_ROAD, PLOT_MAX_ROAD]), C_DIM,
          fnSmall, ALIGN_LEFT, False);
        DrawText(10, y + 94, 'Ghost shows a level-1 tower range.', C_DIM, fnSmall, ALIGN_LEFT, False);
      end;
    TOOL_DECOR:
      begin
        if Button(8, y, 109, 24, 'Decor only', not PalAll) then
        begin
          PalAll := False;
          BuildPalette;
        end;
        if Button(121, y, 109, 24, 'All objects', PalAll) then
        begin
          PalAll := True;
          BuildPalette;
        end;
        DrawText(10, y + 32, 'scale ' + FmtNum(PlaceScale), C_TEXT, fnSmall, ALIGN_LEFT, False);
        if Button(90, y + 28, 30, 24, '-') then PlaceScale := Max(0.2, PlaceScale - 0.1);
        if Button(124, y + 28, 30, 24, '+') then PlaceScale := Min(4, PlaceScale + 0.1);
        if Button(158, y + 28, 72, 24, 'random', RandScale) then RandScale := not RandScale;
        if Button(8, y + 58, 222, 24, 'Scatter 10 of selected') then Scatter(10);
        // palette grid
        y0 := y + 92;
        cols := 3;
        cell := 74;
        visible := Trunc((WIN_H - STATUS_H - 8 - y0) / cell);
        if Inside(0, y0, LEFT_W, visible * cell) and (WheelY <> 0) then
        begin
          PalScroll := PalScroll - Round(WheelY);
          WheelY := 0;
        end;
        PalScroll := EnsureRange(PalScroll, 0, Max(0, (Length(Palette) + cols - 1) div cols - visible));
        SetClip(0, Round(y0), LEFT_W, visible * cell);
        st := DefaultAnimState;
        st.Time := AnimTime;
        n := 0;
        for i := PalScroll * cols to High(Palette) do
        begin
          row := n div cols;
          col := n mod cols;
          if row >= visible then Break;
          x := 8 + col * (cell + 2);
          y := y0 + row * cell;
          g := Palette[i];
          if i = PalSel then RoundRect(x, y, cell - 2, cell - 4, 4, C_SEL)
          else if Inside(x, y, cell - 2, cell - 4) then RoundRect(x, y, cell - 2, cell - 4, 4, C_PANEL2)
          else RoundRect(x, y, cell - 2, cell - 4, 4, RGBA(34, 36, 42));
          sc := Min(0.9, Min(56 / Max(1, GeoBX1[g] - GeoBX0[g]), 44 / Max(1, GeoBY1[g] - GeoBY0[g])));
          cx := x + cell / 2 - 1 - (GeoBX0[g] + GeoBX1[g]) / 2 * sc;
          cy := y + 30 - (GeoBY0[g] + GeoBY1[g]) / 2 * sc;
          DrawGeo(Lib.Objects[g], cx, cy, sc, st);
          DrawText(x + cell / 2 - 1, y + cell - 22, Copy(Lib.Objects[g].Name, Pos('.', Lib.Objects[g].Name) + 1, 12),
            C_TEXT, fnSmall, ALIGN_CENTER, True);
          if Inside(x, y, cell - 2, cell - 4) and LDown and not Consumed then
          begin
            Consumed := True;
            PalSel := i;
            if SelValid and (SelKind = skDecor) then
            begin
              PushUndo;
              M.Decor[SelIdx].GeoIdx := g;
              M.Decor[SelIdx].Geo := Lib.Objects[g].Name;
            end;
          end;
          Inc(n);
        end;
        NoClip;
      end;
  end;
end;

procedure DrawRightPanel;
var
  x0, i, n, visible: Integer;
  y, y0, vx: Single;
  r: TPropRow;
  txt: string;
  hover: Boolean;
  c: TRGBA;
  pc: PRGBA;
begin
  x0 := WIN_W - RIGHT_W;
  FillRect(x0, TOP_H, RIGHT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
  FillRect(x0, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  if SelValid then DrawText(x0 + 10, TOP_H + 6, 'SELECTION', C_ACCENT, fnSmall, ALIGN_LEFT, False)
  else DrawText(x0 + 10, TOP_H + 6, 'MAP PROPERTIES', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  BuildRows;
  y0 := TOP_H + 28;
  visible := 15;
  if Inside(x0, y0, RIGHT_W, visible * ROW_H) and (WheelY <> 0) and (Drag = drNone) then
  begin
    i := PropScroll + Trunc((MY - y0) / ROW_H);
    if (i >= 0) and (i <= High(Rows)) and (Rows[i].Kind = pkNum) and (MX >= x0 + 130) then
    begin
      PushUndo;
      SetNum(Rows[i].Key, GetNum(Rows[i].Key) + WheelY * NumStep(Rows[i].Key));
    end
    else
      PropScroll := PropScroll - Round(WheelY);
    WheelY := 0;
  end;
  PropScroll := EnsureRange(PropScroll, 0, Max(0, Length(Rows) - visible));
  n := 0;
  for i := PropScroll to High(Rows) do
  begin
    if n >= visible then Break;
    r := Rows[i];
    y := y0 + n * ROW_H;
    Inc(n);
    if r.Kind = pkInfo then
    begin
      DrawText(x0 + 10, y + 2, r.Caption, RGBA(200, 205, 215), fnSmall, ALIGN_LEFT, False);
      Continue;
    end;
    DrawText(x0 + 10, y + 2, r.Caption, C_DIM, fnSmall, ALIGN_LEFT, False);
    vx := x0 + 130;
    hover := Inside(vx, y, RIGHT_W - 140, ROW_H - 2);
    if EditKey = r.Key then
    begin
      FillRect(vx, y, RIGHT_W - 140, ROW_H - 2, RGBA(20, 22, 26));
      FillRect(vx, y + ROW_H - 3, RIGHT_W - 140, 1, C_ACCENT);
      txt := EditBuf;
      if Frac(SDL_GetTicks / 1000) < 0.5 then txt := txt + '|';
      DrawText(vx + 4, y + 2, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
      Continue;
    end;
    if hover then FillRect(vx, y, RIGHT_W - 140, ROW_H - 2, C_PANEL2);
    txt := GetText(r.Key);
    case r.Kind of
      pkColor:
        begin
          pc := ColorRef(r.Key);
          Swatch(vx + 2, y + 3, 30, 15, pc^);
          DrawText(vx + 38, y + 2, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
        end;
      pkBool:
        begin
          RoundRect(vx + 2, y + 3, 16, 15, 3, RGBA(25, 27, 32));
          if txt = 'yes' then FillRect(vx + 6, y + 7, 8, 7, C_ACCENT);
        end;
      pkEnum: DrawText(vx + 4, y + 2, '< ' + txt + ' >', RGBA(160, 210, 255), fnSmall, ALIGN_LEFT, False);
    else
      DrawText(vx + 4, y + 2, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
    end;
    if hover and (LDown or RDown) and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      case r.Kind of
        pkText, pkColor: if LDown then BeginEdit(r.Key);
        pkBool:
          begin
            PushUndo;
            M.Fortress := not M.Fortress;
            MarkRoads;
          end;
        pkEnum: if LDown then CycleGeo(1) else CycleGeo(-1);
        pkNum:
          if LDown then
          begin
            Drag := drScrub;
            ScrubKey := r.Key;
            ScrubStart := GetNum(r.Key);
            DragStartSX := MX;
            ScrubMoved := False;
            DragUndoPushed := False;
          end;
      end;
    end;
  end;

  // selection actions
  y := y0 + visible * ROW_H + 6;
  if SelValid then
  begin
    if Button(x0 + 8, y, 100, 26, 'Duplicate', False, SelKind in [skPlot, skDecor]) then DuplicateSel;
    if Button(x0 + 112, y, 100, 26, 'Delete', False, SelKind <> skEntrance) then DeleteSel;
    if Button(x0 + 216, y, 106, 26, 'Deselect') then ResetSelection;
  end
  else if Button(x0 + 8, y, 150, 26, 'New ground seed') then
  begin
    PushUndo;
    M.Seed := 1 + Random(9999);
    MarkRoads;
  end;

  // validation
  y := y + 40;
  FillRect(x0, y - 6, RIGHT_W, 1, C_LINE);
  if Length(Issues) = 0 then
    DrawText(x0 + 10, y, 'CHECKS: all good', RGBA(120, 220, 120), fnSmall, ALIGN_LEFT, False)
  else
    DrawText(x0 + 10, y, Format('CHECKS: %d issue(s) - click to select', [Length(Issues)]), C_ACCENT, fnSmall,
      ALIGN_LEFT, False);
  y0 := y + 22;
  visible := Trunc((WIN_H - STATUS_H - 6 - y0) / ROW_H);
  if Inside(x0, y0, RIGHT_W, visible * ROW_H) and (WheelY <> 0) then
  begin
    IssueScroll := IssueScroll - Round(WheelY) * 2;
    WheelY := 0;
  end;
  IssueScroll := EnsureRange(IssueScroll, 0, Max(0, Length(Issues) - visible));
  n := 0;
  SetClip(x0, Round(y0), RIGHT_W, visible * ROW_H);
  for i := IssueScroll to High(Issues) do
  begin
    if n >= visible then Break;
    y := y0 + n * ROW_H;
    Inc(n);
    if Inside(x0 + 4, y, RIGHT_W - 8, ROW_H - 2) then FillRect(x0 + 4, y, RIGHT_W - 8, ROW_H - 2, C_PANEL2);
    if Issues[i].Severe then c := RGBA(255, 90, 80) else c := RGBA(255, 200, 70);
    FillCircle(x0 + 14, y + 10, 4, c);
    DrawText(x0 + 24, y + 2, Issues[i].Text, C_TEXT, fnSmall, ALIGN_LEFT, False);
    if Inside(x0 + 4, y, RIGHT_W - 8, ROW_H - 2) and LDown and not Consumed and (Issues[i].Kind <> skNone) then
    begin
      Consumed := True;
      Select(Issues[i].Kind, Issues[i].Path, Issues[i].Idx);
      if Issues[i].Kind = skPlot then Tool := TOOL_PLOT
      else if Issues[i].Kind = skDecor then Tool := TOOL_DECOR
      else Tool := TOOL_PATH;
    end;
  end;
  NoClip;
end;

{ ======================================================================
  canvas input
  ====================================================================== }

procedure CanvasInput;
var
  mx_, my_, f, ox, oy, hx, hy, hsx, hsy: Single;
  p, i, seg, n: Integer;
  hit: Boolean;
begin
  if not Inside(CV_X, CV_Y, CV_W, CV_H) then Exit;
  if WheelY <> 0 then
  begin
    ScreenToMap(MX, MY, ox, oy);
    f := Power(1.15, WheelY);
    ViewZoom := EnsureRange(ViewZoom * f, 0.2, 6);
    PanX := MX - CV_X - ox * ViewZoom;
    PanY := MY - CV_Y - oy * ViewZoom;
    WheelY := 0;
  end;
  if (RDown or MDownBtn) and not Consumed then
  begin
    Consumed := True;
    Drag := drPan;
    DragLastX := MX;
    DragLastY := MY;
    Exit;
  end;
  if not LDown or Consumed then Exit;
  Consumed := True;
  EndEdit(True);
  ScreenToMap(MX, MY, mx_, my_);
  DragLastX := SnapV(mx_);
  DragLastY := SnapV(my_);
  DragUndoPushed := False;
  hit := False;

  // 1) pick existing items, most specific first
  if Tool in [TOOL_SELECT, TOOL_PATH] then
  begin
    if HitPoint(MX, MY, p, i) then
    begin
      Select(skPoint, p, i);
      hit := True;
    end
    else if HitEntrance(MX, MY, p) then
    begin
      Select(skEntrance, p, -1);
      hit := True;
    end;
  end;
  if not hit and (Tool = TOOL_SELECT) then
  begin
    HeroPos(hx, hy);
    MapToScreen(hx, hy - 14, hsx, hsy);
    if Dist2(MX, MY, hsx, hsy) <= Sqr(Max(12, 18 * ViewZoom)) then
    begin
      Select(skHero, -1, -1);
      hit := True;
    end;
  end;
  if not hit and (Tool in [TOOL_SELECT, TOOL_PLOT]) then
  begin
    i := HitPlot(mx_, my_);
    if i >= 0 then
    begin
      Select(skPlot, -1, i);
      hit := True;
    end;
  end;
  if not hit and (Tool in [TOOL_SELECT, TOOL_DECOR]) then
  begin
    i := HitDecor(mx_, my_);
    if i >= 0 then
    begin
      Select(skDecor, -1, i);
      hit := True;
    end;
  end;
  if hit then
  begin
    Drag := drItem;
    Exit;
  end;

  // 2) create something with the current tool
  case Tool of
    TOOL_SELECT: ResetSelection;
    TOOL_PATH:
      if (ActivePath >= 0) and (ActivePath <= High(M.Paths)) then
      begin
        PushUndo;
        n := PointCount(ActivePath);
        if ModCtrl then
        begin
          seg := NearestSegment(ActivePath, mx_, my_);
          if seg >= 0 then InsertPoint(ActivePath, seg, SnapV(mx_), SnapV(my_))
          else Status('Ctrl+click on the selected road to insert a point');
        end
        else if ModShift then
          InsertPoint(ActivePath, -1, SnapV(mx_), SnapV(my_))
        else
          InsertPoint(ActivePath, n - 1, SnapV(mx_), SnapV(my_));
        Drag := drItem;
        DragUndoPushed := True;
      end;
    TOOL_PLOT:
      begin
        AddPlot(SnapV(mx_), SnapV(my_));
        Drag := drItem;
        DragUndoPushed := True;
      end;
    TOOL_DECOR:
      if Length(Palette) > 0 then
      begin
        PushUndo;
        AddDecor(Palette[PalSel], SnapV(mx_), SnapV(my_), DecorScale);
        Drag := drItem;
        DragUndoPushed := True;
      end;
  end;
end;

procedure UpdateDrags;
var
  mx_, my_, x, y, v: Single;
begin
  case Drag of
    drPan:
      if RHeld or MHeld then
      begin
        PanX := PanX + (MX - DragLastX);
        PanY := PanY + (MY - DragLastY);
        DragLastX := MX;
        DragLastY := MY;
      end
      else Drag := drNone;
    drItem:
      if LHeld and SelValid then
      begin
        ScreenToMap(MX, MY, mx_, my_);
        mx_ := SnapV(mx_);
        my_ := SnapV(my_);
        if (mx_ <> DragLastX) or (my_ <> DragLastY) then
        begin
          if not DragUndoPushed then
          begin
            PushUndo;
            DragUndoPushed := True;
          end;
          GetItemPos(SelKind, SelPath, SelIdx, x, y);
          SetItemPos(SelKind, SelPath, SelIdx, x + (mx_ - DragLastX), y + (my_ - DragLastY));
          DragLastX := mx_;
          DragLastY := my_;
        end;
      end
      else Drag := drNone;
    drScrub:
      if LHeld then
      begin
        if Abs(MX - DragStartSX) > 3 then ScrubMoved := True;
        if ScrubMoved then
        begin
          if not DragUndoPushed then
          begin
            PushUndo;
            DragUndoPushed := True;
          end;
          v := ScrubStart + Round((MX - DragStartSX) / 3) * NumStep(ScrubKey);
          SetNum(ScrubKey, v);
        end;
      end
      else
      begin
        if not ScrubMoved then BeginEdit(ScrubKey);
        Drag := drNone;
      end;
  end;
end;

{ ======================================================================
  keyboard
  ====================================================================== }

procedure Nudge(dx, dy: Single);
var
  x, y: Single;
begin
  if not SelValid then Exit;
  PushUndo;
  GetItemPos(SelKind, SelPath, SelIdx, x, y);
  SetItemPos(SelKind, SelPath, SelIdx, x + dx, y + dy);
end;

procedure HandleKey(key: TSDL_Keycode);
var
  d: Single;
begin
  if EditKey <> '' then
  begin
    case key of
      SDLK_RETURN, SDLK_TAB: EndEdit(True);
      SDLK_ESCAPE: EndEdit(False);
      SDLK_BACKSPACE: if EditBuf <> '' then Delete(EditBuf, Length(EditBuf), 1);
    end;
    Exit;
  end;
  if ModCtrl then
  begin
    case key of
      SDLK_N: if ConfirmDiscard then NewMap;
      SDLK_O: if ConfirmDiscard then AskOpen;
      SDLK_S: if ModShift then AskSaveAs else DoSave;
      SDLK_Z: if ModShift then DoRedo else DoUndo;
      SDLK_Y: DoRedo;
      SDLK_D: DuplicateSel;
    end;
    Exit;
  end;
  if ModShift then d := 10 else d := 1;
  case key of
    SDLK_1: Tool := TOOL_SELECT;
    SDLK_2: Tool := TOOL_PATH;
    SDLK_3: Tool := TOOL_PLOT;
    SDLK_4: Tool := TOOL_DECOR;
    SDLK_DELETE, SDLK_BACKSPACE: DeleteSel;
    SDLK_ESCAPE: ResetSelection;
    SDLK_LEFT: Nudge(-d, 0);
    SDLK_RIGHT: Nudge(d, 0);
    SDLK_UP: Nudge(0, -d);
    SDLK_DOWN: Nudge(0, d);
    SDLK_LEFTBRACKET, SDLK_RIGHTBRACKET:
      if SelValid and (SelKind = skDecor) then
      begin
        PushUndo;
        if key = SDLK_LEFTBRACKET then M.Decor[SelIdx].S := Max(0.1, M.Decor[SelIdx].S - 0.05)
        else M.Decor[SelIdx].S := Min(5, M.Decor[SelIdx].S + 0.05);
      end
      else if key = SDLK_LEFTBRACKET then PlaceScale := Max(0.2, PlaceScale - 0.1)
      else PlaceScale := Min(4, PlaceScale + 0.1);
    SDLK_HOME: FitView;
    SDLK_G: SnapOn := not SnapOn;
    SDLK_F5: PlayTest;
  end;
end;

{ ======================================================================
  main
  ====================================================================== }

procedure SaveShot(const fn: string);
var
  surf: PSDL_Surface;
begin
  surf := SDL_RenderReadPixels(Renderer, nil);
  if surf <> nil then
  begin
    SDL_SaveBMP(surf, PAnsiChar(fn));
    SDL_DestroySurface(surf);
  end;
end;

var
  Event: TSDL_Event;
  Running: Boolean;
  Last, Now_: UInt64;
  Dt: Single;
  StartFile, ShotFile: string;
  ShotFrames, ArgI: Integer;
  err: string;

begin
  InitCriticalSection(DlgLock);
  Randomize;
  JsonFilter[0].Name := 'Map JSON';
  JsonFilter[0].pattern := 'json';

  if not SDL_Init(SDL_INIT_VIDEO) then Halt(1);
  if not SDL_CreateWindowAndRenderer('MapEdit', WIN_W, WIN_H, SDL_WINDOW_RESIZABLE, @Window, @Renderer) then
  begin
    SDL_Quit;
    Halt(1);
  end;
  SDL_SetWindowMinimumSize(Window, 960, 600);
  SDL_SetRenderVSync(Renderer, 1);
  SDL_SetRenderDrawBlendMode(Renderer, SDL_BLENDMODE_BLEND);
  SDL_SetRenderLogicalPresentation(Renderer, WIN_W, WIN_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
  GfxInit(Renderer);

  Lib := TGeoLib.Create;
  if not Lib.LoadFromFile(ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'geometry.json', err) then
  begin
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'MapEdit', PAnsiChar('Cannot load geometry: ' + err), Window);
    SDL_Quit;
    Halt(1);
  end;
  ComputeGeoBounds;
  BuildPalette;
  GeoPlotEmpty := Lib.Find('plot.empty');
  GeoTowerPreview := Lib.Find('tower.archer');

  ShotFile := '';
  if (ParamCount >= 1) and (Copy(ParamStr(1), 1, 2) <> '--') then StartFile := ParamStr(1)
  else StartFile := MapsDir + 'brewhold.json';
  if FileExists(StartFile) then OpenMap(StartFile) else NewMap;
  for ArgI := 1 to ParamCount - 1 do
    if ParamStr(ArgI) = '--shot' then
    begin
      ShotFile := ParamStr(ArgI + 1);
      if ArgI + 2 <= ParamCount then Tool := EnsureRange(StrToIntDef(ParamStr(ArgI + 2), 1) - 1, 0, 3);
      if Tool = TOOL_PATH then Select(skPoint, 1, 2);
      if Tool = TOOL_PLOT then Select(skPlot, -1, 3);
      if Tool = TOOL_DECOR then Select(skDecor, -1, 10);
    end;
  ShotFrames := 0;

  Last := SDL_GetTicks;
  Running := True;
  while Running do
  begin
    UIBeginFrame;
    while SDL_PollEvent(@Event) do
    begin
      SDL_ConvertEventToRenderCoordinates(Renderer, @Event);
      UIHandleEvent(Event);
      case Event._type of
        SDL_EVENT_QUIT:
          if ConfirmDiscard then Running := False;
        SDL_EVENT_TEXT_INPUT:
          if EditKey <> '' then EditBuf := EditBuf + string(Event.text.text);
        SDL_EVENT_KEY_DOWN:
          HandleKey(Event.key.key);
        SDL_EVENT_DROP_FILE:
          if (Event.drop.data <> nil) and ConfirmDiscard then OpenMap(string(Event.drop.data));
      end;
    end;
    UIUpdateMods;
    HandleDialogResult;
    Now_ := SDL_GetTicks;
    Dt := Min(0.05, (Now_ - Last) / 1000);
    Last := Now_;
    AnimTime := AnimTime + Dt;
    if StatusTime > 0 then StatusTime := StatusTime - Dt;

    UpdateDrags;
    if RoadDirty then RebuildBackground;
    Validate;

    SDL_SetRenderDrawColor(Renderer, C_BG.r, C_BG.g, C_BG.b, 255);
    SDL_RenderClear(Renderer);
    DrawToolbar;
    DrawLeftPanel;
    DrawRightPanel;
    CanvasInput;
    if RoadDirty then RebuildBackground;
    DrawCanvas;
    FillRect(0, WIN_H - STATUS_H, WIN_W, STATUS_H, C_PANEL);
    FillRect(0, WIN_H - STATUS_H, WIN_W, 1, C_LINE);
    if StatusTime > 0 then
      DrawText(10, WIN_H - STATUS_H + 3, StatusMsg, C_ACCENT, fnSmall, ALIGN_LEFT, False)
    else
      DrawText(10, WIN_H - STATUS_H + 3, '1-4 tools  |  drag to move  |  Del delete  |  RMB drag pan, wheel zoom  |  ' +
        'Ctrl+Z/Y undo/redo  |  Ctrl+S save  |  F5 play test', C_DIM, fnSmall, ALIGN_LEFT, False);
    if Modified then
      DrawText(WIN_W - 10, WIN_H - STATUS_H + 3, 'modified', RGBA(255, 150, 120), fnSmall, ALIGN_RIGHT, False);
    if ShotFile <> '' then
    begin
      Inc(ShotFrames);
      if ShotFrames = 30 then
      begin
        SaveShot(ShotFile);
        Running := False;
      end;
    end;
    SDL_RenderPresent(Renderer);
    UpdateTitle;
  end;

  if BgTex <> nil then SDL_DestroyTexture(BgTex);
  Lib.Free;
  GfxDone;
  DoneCriticalSection(DlgLock);
  SDL_DestroyRenderer(Renderer);
  SDL_DestroyWindow(Window);
  SDL_Quit;
end.
