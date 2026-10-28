program GeoEdit;

{ GeoEdit - object geometry editor for Brewhold Defense (Lazarus / Free Pascal + SDL3)

  Opens, edits, saves and simulates data\geometry.json (format: see geometry.pas).

  Mouse (canvas)
    LMB on a shape ............ select / drag it          LMB on a handle .... reshape / move pivot
    RMB or MMB drag ........... pan view                  Wheel .............. zoom at cursor
  Properties panel
    Numbers: drag left/right to scrub (Shift = fine, Ctrl = coarse), click to type, wheel to step
    Enums: click = next, right-click = previous.  Booleans: click toggles.  Text/colour: click to type.
  Keys
    Ctrl+N new object   Ctrl+O open   Ctrl+S save   Ctrl+Shift+S save as
    Ctrl+Z undo   Ctrl+Y redo   Ctrl+C / Ctrl+V copy / paste shape   Ctrl+D duplicate shape
    Del delete shape   Arrows nudge (Shift x5)   PgUp/PgDn move layer   Tab next shape   H hide shape
    Space play/pause simulation   A attack (swing + fire)   1/2/3 tower level   Home fit view   G snap
  Drag & drop a .json file onto the window to open it.
  Test hook: geoedit --shot <file.bmp> <object> [shape] [export frames] renders, saves a screenshot, quits. }

{$mode objfpc}{$H+}
{$APPTYPE GUI}

uses
  SDL3, SDL3_image, SysUtils, Math, StrUtils, Classes, gfx, geometry, ui;

const
  WIN_W = 1440;
  WIN_H = 900;
  TOP_H = 44;
  LEFT_W = 230;
  RIGHT_W = 350;
  STATUS_H = 24;
  SIM_H = 74;
  CV_X = LEFT_W;
  CV_Y = TOP_H;
  CV_W = WIN_W - LEFT_W - RIGHT_W;
  CV_H = WIN_H - TOP_H - STATUS_H - SIM_H;
  ROW_H = 22;
  LAYER_H = 300;
  MAX_UNDO = 300;

type
  TPropKind = (pkNum, pkText, pkEnum, pkBool, pkColor, pkInfo);

  TPropRow = record
    Key, Caption: string;
    Kind: TPropKind;
  end;

  TUndoEntry = record
    Obj: Integer;
    Json: string;
    Sel: Integer;
  end;

  TDragMode = (drNone, drShape, drHandle, drPan, drScrub);

var
  Window: PSDL_Window;
  Renderer: PSDL_Renderer;
  Lib: TGeoLib;
  CurObj: Integer = -1;
  SelShape: Integer = -1;
  SelHandle: Integer = -1;
  Modified: Boolean = False;

  ViewZoom: Single = 4;
  PanX: Single = 0;
  PanY: Single = 60;
  SnapOn: Boolean = True;
  BgMode: Integer = 1;
  ShowGrid: Boolean = True;

  // simulation
  Playing: Boolean = True;
  SimTime: Single = 0;
  SimWalk: Single = 0;
  SimMoving: Boolean = True;
  SimFacing: Single = 1;
  SimLevel: Integer = 1;
  SimAimMouse: Boolean = True;
  SimAim: Single = 0;
  SimSwing: Single = 0;
  SimSinceFire: Single = 99;
  SimAuto: Boolean = False;
  SimAutoT: Single = 0;
  SimWalkPreview: Boolean = False;
  SimWalkX: Single = 0;
  SimWalkDir: Single = 1;
  SimSpeed: Single = 1;

  // editing state
  EditKey: string = '';
  EditBuf: string = '';
  Drag: TDragMode = drNone;
  DragStartX, DragStartY, DragLastLX, DragLastLY: Single;
  DragUndoPushed: Boolean;
  ScrubKey: string;
  ScrubStartVal: Single;
  ScrubMoved: Boolean;

  UndoStack, RedoStack: array of TUndoEntry;
  ClipShape: TShape;
  HasClip: Boolean = False;

  ObjScroll, LayerScroll, PropScroll: Integer;
  StatusMsg: string = '';
  StatusTime: Single = 0;

  // file dialogs (callback may run on another thread)
  DlgLock: TRTLCriticalSection;
  DlgPath: string = '';
  DlgKind: Integer = 0;     // 1 open, 2 save as, 3 pick image
  DlgReady: Boolean = False;

  Rows: array of TPropRow;

{ ======================================================================
  basic helpers
  ====================================================================== }

procedure Status(const s: string);
begin
  StatusMsg := s;
  StatusTime := 5;
end;

function HaveObj: Boolean;
begin
  Result := (CurObj >= 0) and (CurObj < Lib.Count);
end;

function HaveShape: Boolean;
begin
  Result := HaveObj and (SelShape >= 0) and (SelShape <= High(Lib.Objects[CurObj].Shapes));
end;

function Snap(v: Single): Single;
begin
  if SnapOn then Result := Round(v * 2) / 2      // half-unit grid
  else Result := Round(v * 100) / 100;
end;

function SimState: TAnimState;
begin
  Result := DefaultAnimState;
  Result.Time := SimTime;
  Result.Walk := SimWalk;
  Result.Moving := SimMoving;
  Result.Facing := SimFacing;
  Result.Aim := SimAim;
  Result.Swing := SimSwing;
  Result.SinceFire := SimSinceFire;
  Result.Level := SimLevel;
end;

// origin of the object on screen
procedure OriginXY(out ox, oy: Single);
begin
  ox := CV_X + CV_W / 2 + PanX;
  oy := CV_Y + CV_H / 2 + PanY;
  if SimWalkPreview then ox := ox + SimWalkX * ViewZoom;
end;

procedure ScreenToLocal(sx, sy: Single; out lx, ly: Single);
var
  ox, oy: Single;
begin
  OriginXY(ox, oy);
  lx := (sx - ox) / ViewZoom;
  ly := (sy - oy) / ViewZoom;
  if SimFacing < 0 then lx := -lx;
end;

procedure LocalToScreen(lx, ly: Single; out sx, sy: Single);
var
  ox, oy: Single;
begin
  OriginXY(ox, oy);
  if SimFacing < 0 then lx := -lx;
  sx := ox + lx * ViewZoom;
  sy := oy + ly * ViewZoom;
end;

{ ======================================================================
  undo / redo
  ====================================================================== }

function Snapshot: TUndoEntry;
begin
  Result.Obj := CurObj;
  Result.Sel := SelShape;
  if HaveObj then Result.Json := ObjectToJSON(Lib.Objects[CurObj], '')
  else Result.Json := '';
end;

procedure PushUndo;
begin
  if not HaveObj then Exit;
  if Length(UndoStack) >= MAX_UNDO then Delete(UndoStack, 0, 1);
  SetLength(UndoStack, Length(UndoStack) + 1);
  UndoStack[High(UndoStack)] := Snapshot;
  SetLength(RedoStack, 0);
  Modified := True;
end;

procedure RestoreEntry(const e: TUndoEntry);
var
  o: TGeoObject;
begin
  if (e.Obj < 0) or (e.Obj >= Lib.Count) then Exit;
  if not ObjectFromJSONText(e.Json, o) then Exit;
  Lib.Objects[e.Obj] := o;
  CurObj := e.Obj;
  SelShape := Min(e.Sel, High(o.Shapes));
  SelHandle := -1;
  Modified := True;
end;

procedure DoUndo;
var
  e: TUndoEntry;
begin
  if Length(UndoStack) = 0 then
  begin
    Status('Nothing to undo');
    Exit;
  end;
  e := UndoStack[High(UndoStack)];
  SetLength(UndoStack, Length(UndoStack) - 1);
  CurObj := e.Obj;
  SetLength(RedoStack, Length(RedoStack) + 1);
  RedoStack[High(RedoStack)] := Snapshot;
  RestoreEntry(e);
  Status('Undo');
end;

procedure DoRedo;
var
  e: TUndoEntry;
begin
  if Length(RedoStack) = 0 then
  begin
    Status('Nothing to redo');
    Exit;
  end;
  e := RedoStack[High(RedoStack)];
  SetLength(RedoStack, Length(RedoStack) - 1);
  CurObj := e.Obj;
  SetLength(UndoStack, Length(UndoStack) + 1);
  UndoStack[High(UndoStack)] := Snapshot;
  RestoreEntry(e);
  Status('Redo');
end;

procedure ClearHistory;
begin
  SetLength(UndoStack, 0);
  SetLength(RedoStack, 0);
end;

{ ======================================================================
  file operations
  ====================================================================== }

procedure UpdateTitle;
var
  t: string;
begin
  t := 'GeoEdit - ';
  if Lib.FileName <> '' then t := t + ExtractFileName(Lib.FileName) else t := t + '(untitled)';
  if Modified then t := t + ' *';
  SDL_SetWindowTitle(Window, PAnsiChar(t));
end;

procedure FitView;
var
  i: Integer;
  x0, y0, x1, y1, a, b, c, d, w, h: Single;
begin
  if not HaveObj or (Length(Lib.Objects[CurObj].Shapes) = 0) then
  begin
    ViewZoom := 4;
    PanX := 0;
    PanY := 60;
    Exit;
  end;
  x0 := 1e9; y0 := 1e9; x1 := -1e9; y1 := -1e9;
  for i := 0 to High(Lib.Objects[CurObj].Shapes) do
  begin
    ShapeBounds(Lib.Objects[CurObj].Shapes[i], a, b, c, d);
    x0 := Min(x0, a); y0 := Min(y0, b); x1 := Max(x1, c); y1 := Max(y1, d);
  end;
  w := Max(10, x1 - x0);
  h := Max(10, y1 - y0);
  ViewZoom := EnsureRange(Min(CV_W * 0.7 / w, CV_H * 0.7 / h), 0.5, 40);
  PanX := -(x0 + x1) / 2 * ViewZoom;
  PanY := -(y0 + y1) / 2 * ViewZoom;
  SimWalkX := 0;
end;

procedure SelectObject(i: Integer);
begin
  if Lib.Count = 0 then
  begin
    CurObj := -1;
    Exit;
  end;
  CurObj := EnsureRange(i, 0, Lib.Count - 1);
  SelShape := -1;
  SelHandle := -1;
  EditKey := '';
  FitView;
end;

function OpenFile(const fn: string): Boolean;
var
  err: string;
  nl: TGeoLib;
begin
  nl := TGeoLib.Create;
  Result := nl.LoadFromFile(fn, err);
  if not Result then
  begin
    nl.Free;
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Open failed', PAnsiChar(err), Window);
    Exit;
  end;
  Lib.Free;
  Lib := nl;
  Modified := False;
  ClearHistory;
  ObjScroll := 0;
  SelectObject(0);
  Status(Format('Opened %s  (%d objects)', [ExtractFileName(fn), Lib.Count]));
  UpdateTitle;
end;

function SaveFile(const fn: string): Boolean;
begin
  Result := Lib.SaveToFile(fn);
  if Result then
  begin
    Modified := False;
    ImageBaseDir := ExtractFilePath(ExpandFileName(fn));
    Status('Saved ' + fn);
  end
  else
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Save failed', PAnsiChar('Could not write ' + fn), Window);
  UpdateTitle;
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

var
  JsonFilter: array[0..0] of TSDL_DialogFileFilter;
  ImageFilter: array[0..0] of TSDL_DialogFileFilter;

procedure AskOpen;
begin
  SDL_ShowOpenFileDialog(@DialogCallback, Pointer(1), Window, @JsonFilter[0], 1,
    PAnsiChar(ExtractFilePath(Lib.FileName)), False);
end;

procedure AskSaveAs;
begin
  SDL_ShowSaveFileDialog(@DialogCallback, Pointer(2), Window, @JsonFilter[0], 1, PAnsiChar(Lib.FileName));
end;

procedure AskImage;
begin
  SDL_ShowOpenFileDialog(@DialogCallback, Pointer(3), Window, @ImageFilter[0], 1,
    PAnsiChar(ImageBaseDir), False);
end;

procedure DoSave;
begin
  if Lib.FileName = '' then AskSaveAs else SaveFile(Lib.FileName);
end;

procedure HandleDialogResult;
var
  p, rel: string;
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
  case k of
    1: OpenFile(p);
    2:
      begin
        if ExtractFileExt(p) = '' then p := p + '.json';
        SaveFile(p);
      end;
    3:
      if HaveShape then
      begin
        rel := ExtractRelativePath(ImageBaseDir, p);
        PushUndo;
        Lib.Objects[CurObj].Shapes[SelShape].Image := rel;
        Lib.Objects[CurObj].Shapes[SelShape].Tex := nil;
        Status('Image: ' + rel);
      end;
  end;
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
  data.message := 'The geometry file has unsaved changes. Save before closing?';
  data.numbuttons := 3;
  data.Buttons := @btn[0];
  hit := 2;
  SDL_ShowMessageBox(@data, @hit);
  case hit of
    0:
      begin
        if Lib.FileName = '' then Exit(False);
        Result := SaveFile(Lib.FileName);
      end;
    1: Result := True;
  else
    Result := False;
  end;
end;

{ ======================================================================
  object / shape operations
  ====================================================================== }

procedure NewObject;
var
  o: TGeoObject;
  n: Integer;
begin
  o := Default(TGeoObject);
  n := 1;
  while Lib.Find('new.object' + IntToStr(n)) >= 0 do Inc(n);
  o.Name := 'new.object' + IntToStr(n);
  o.Category := 'misc';
  SetLength(o.Shapes, 1);
  o.Shapes[0] := NewShape(stEllipse);
  o.Shapes[0].Name := 'shadow';
  o.Shapes[0].RX := 12;
  o.Shapes[0].RY := 5;
  o.Shapes[0].Color := RGBA(0, 0, 0, 80);
  SetLength(Lib.Objects, Lib.Count + 1);
  Lib.Objects[High(Lib.Objects)] := o;
  ClearHistory;
  Modified := True;
  SelectObject(High(Lib.Objects));
  Status('Created ' + o.Name);
end;

procedure DuplicateObject;
var
  o: TGeoObject;
begin
  if not HaveObj then Exit;
  o := CloneObject(Lib.Objects[CurObj]);
  o.Name := o.Name + '.copy';
  SetLength(Lib.Objects, Lib.Count + 1);
  Lib.Objects[High(Lib.Objects)] := o;
  ClearHistory;
  Modified := True;
  SelectObject(High(Lib.Objects));
  Status('Duplicated as ' + o.Name);
end;

procedure DeleteObject;
var
  i: Integer;
begin
  if not HaveObj then Exit;
  Status('Deleted object ' + Lib.Objects[CurObj].Name);
  for i := CurObj to Lib.Count - 2 do
    Lib.Objects[i] := Lib.Objects[i + 1];
  SetLength(Lib.Objects, Lib.Count - 1);
  ClearHistory;
  Modified := True;
  SelectObject(Min(CurObj, Lib.Count - 1));
end;

procedure AddShape(k: TShapeType);
var
  sh: TShape;
  n: Integer;
begin
  if not HaveObj then Exit;
  PushUndo;
  sh := NewShape(k);
  sh.Name := ShapeTypeNames[k];
  if k = stImage then sh.Color := RGBA(255, 255, 255);
  n := Length(Lib.Objects[CurObj].Shapes);
  SetLength(Lib.Objects[CurObj].Shapes, n + 1);
  Lib.Objects[CurObj].Shapes[n] := sh;
  SelShape := n;
  SelHandle := -1;
  Status('Added ' + ShapeTypeNames[k]);
end;

procedure InsertShapeCopy(const src: TShape; offset: Single);
var
  n: Integer;
  sh: TShape;
begin
  if not HaveObj then Exit;
  PushUndo;
  sh := CloneShape(src);
  MoveShape(sh, offset, offset);
  n := Length(Lib.Objects[CurObj].Shapes);
  SetLength(Lib.Objects[CurObj].Shapes, n + 1);
  Lib.Objects[CurObj].Shapes[n] := sh;
  SelShape := n;
end;

procedure DeleteShape;
var
  i: Integer;
begin
  if not HaveShape then Exit;
  PushUndo;
  for i := SelShape to High(Lib.Objects[CurObj].Shapes) - 1 do
    Lib.Objects[CurObj].Shapes[i] := Lib.Objects[CurObj].Shapes[i + 1];
  SetLength(Lib.Objects[CurObj].Shapes, Length(Lib.Objects[CurObj].Shapes) - 1);
  SelShape := Min(SelShape, High(Lib.Objects[CurObj].Shapes));
  SelHandle := -1;
end;

procedure MoveLayer(delta: Integer);
var
  j: Integer;
  t: TShape;
begin
  if not HaveShape then Exit;
  j := SelShape + delta;
  if (j < 0) or (j > High(Lib.Objects[CurObj].Shapes)) then Exit;
  PushUndo;
  t := Lib.Objects[CurObj].Shapes[SelShape];
  Lib.Objects[CurObj].Shapes[SelShape] := Lib.Objects[CurObj].Shapes[j];
  Lib.Objects[CurObj].Shapes[j] := t;
  SelShape := j;
end;

procedure ConvertShape(var sh: TShape; k: TShapeType);
var
  ns: TShape;
  x0, y0, x1, y1, cx, cy: Single;
begin
  if sh.Kind = k then Exit;
  ShapeBounds(sh, x0, y0, x1, y1);
  cx := (x0 + x1) / 2;
  cy := (y0 + y1) / 2;
  ns := NewShape(k);
  ns.Name := sh.Name;
  ns.Color := sh.Color; ns.Color2 := sh.Color2; ns.HasGrad := sh.HasGrad;
  ns.Add := sh.Add; ns.Bob := sh.Bob; ns.Hover := sh.Hover;
  ns.Anim := sh.Anim; ns.Amp := sh.Amp; ns.Freq := sh.Freq; ns.PX := sh.PX; ns.PY := sh.PY;
  ns.MinLevel := sh.MinLevel; ns.MaxLevel := sh.MaxLevel; ns.Fire := sh.Fire;
  case k of
    stCircle, stPie: ns.R := Max(1, Max(x1 - x0, y1 - y0) / 2);
    stEllipse, stRingShape:
      begin
        ns.RX := Max(1, (x1 - x0) / 2);
        ns.RY := Max(1, (y1 - y0) / 2);
      end;
    stRect, stRRect, stImage:
      begin
        ns.W := Max(1, x1 - x0);
        ns.H := Max(1, y1 - y0);
      end;
  end;
  // re-centre the new shape on the old one's centre
  ShapeBounds(ns, x0, y0, x1, y1);
  MoveShape(ns, cx - (x0 + x1) / 2, cy - (y0 + y1) / 2);
  if AnimUsesPivot(ns.Anim) then
  begin
    ns.PX := sh.PX;
    ns.PY := sh.PY;
  end;
  sh := ns;
end;

procedure AddVertex;
var
  n: Integer;
  sh: ^TShape;
  x, y: Single;
begin
  if not HaveShape then Exit;
  sh := @Lib.Objects[CurObj].Shapes[SelShape];
  if not (sh^.Kind in [stPoly, stLine]) then Exit;
  PushUndo;
  n := Length(sh^.Pts);
  // new vertex halfway between the last and first point
  x := (sh^.Pts[n - 2] + sh^.Pts[0]) / 2 + 2;
  y := (sh^.Pts[n - 1] + sh^.Pts[1]) / 2 + 2;
  SetLength(sh^.Pts, n + 2);
  sh^.Pts[n] := Snap(x);
  sh^.Pts[n + 1] := Snap(y);
  SelHandle := n div 2;
end;

procedure RemoveVertex;
var
  n, v, i: Integer;
  sh: ^TShape;
begin
  if not HaveShape then Exit;
  sh := @Lib.Objects[CurObj].Shapes[SelShape];
  n := Length(sh^.Pts) div 2;
  if (sh^.Kind = stPoly) and (n <= 3) then Exit;
  if (sh^.Kind = stLine) and (n <= 2) then Exit;
  if not (sh^.Kind in [stPoly, stLine]) then Exit;
  PushUndo;
  v := SelHandle;
  if (v < 0) or (v >= n) then v := n - 1;
  for i := v to n - 2 do
  begin
    sh^.Pts[i * 2] := sh^.Pts[i * 2 + 2];
    sh^.Pts[i * 2 + 1] := sh^.Pts[i * 2 + 3];
  end;
  SetLength(sh^.Pts, (n - 1) * 2);
  SelHandle := -1;
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
var
  sh: TShape;
  i: Integer;
begin
  SetLength(Rows, 0);
  if not HaveObj then Exit;
  if not HaveShape then
  begin
    AddRow('oname', 'object name', pkText);
    AddRow('ocat', 'category', pkText);
    AddRow('onotes', 'notes', pkText);
    AddRow('', 'Select a shape to edit it.', pkInfo);
    Exit;
  end;
  sh := Lib.Objects[CurObj].Shapes[SelShape];
  AddRow('name', 'name', pkText);
  AddRow('type', 'type', pkEnum);
  case sh.Kind of
    stCircle: begin AddRow('x', 'x', pkNum); AddRow('y', 'y', pkNum); AddRow('r', 'radius', pkNum); end;
    stEllipse:
      begin
        AddRow('x', 'x', pkNum); AddRow('y', 'y', pkNum);
        AddRow('rx', 'radius x', pkNum); AddRow('ry', 'radius y', pkNum);
      end;
    stRingShape:
      begin
        AddRow('x', 'x', pkNum); AddRow('y', 'y', pkNum);
        AddRow('rx', 'radius x', pkNum); AddRow('ry', 'radius y', pkNum); AddRow('w', 'thickness', pkNum);
      end;
    stRect, stImage:
      begin
        AddRow('x', 'left', pkNum); AddRow('y', 'top', pkNum);
        AddRow('w', 'width', pkNum); AddRow('h', 'height', pkNum);
      end;
    stRRect:
      begin
        AddRow('x', 'left', pkNum); AddRow('y', 'top', pkNum);
        AddRow('w', 'width', pkNum); AddRow('h', 'height', pkNum); AddRow('r', 'corner', pkNum);
      end;
    stPie:
      begin
        AddRow('x', 'x', pkNum); AddRow('y', 'y', pkNum); AddRow('r', 'radius', pkNum);
        AddRow('a0', 'start angle', pkNum); AddRow('a1', 'end angle', pkNum);
      end;
    stPoly, stLine:
      begin
        if sh.Kind = stLine then AddRow('w', 'width', pkNum);
        for i := 0 to Length(sh.Pts) div 2 - 1 do
        begin
          AddRow('p' + IntToStr(i) + 'x', 'point ' + IntToStr(i) + ' x', pkNum);
          AddRow('p' + IntToStr(i) + 'y', 'point ' + IntToStr(i) + ' y', pkNum);
        end;
      end;
  end;
  if sh.Kind = stImage then AddRow('image', 'image file', pkText);
  AddRow('color', 'color', pkColor);
  AddRow('cr', '  red', pkNum); AddRow('cg', '  green', pkNum);
  AddRow('cb', '  blue', pkNum); AddRow('ca', '  alpha', pkNum);
  if sh.Kind in [stCircle, stEllipse] then
  begin
    AddRow('grad', 'gradient', pkBool);
    if sh.HasGrad then AddRow('color2', 'edge color', pkColor);
  end;
  AddRow('add', 'additive glow', pkBool);
  AddRow('hidden', 'hidden', pkBool);
  AddRow('bob', 'walk bob', pkNum);
  AddRow('hover', 'hover', pkNum);
  AddRow('anim', 'animation', pkEnum);
  if sh.Anim <> akNone then
  begin
    AddRow('amp', 'amplitude', pkNum);
    if sh.Anim in [akStep, akFlap, akPulse, akGlow] then AddRow('freq', 'frequency', pkNum);
    if AnimUsesPivot(sh.Anim) then
    begin
      AddRow('px', 'pivot x', pkNum);
      AddRow('py', 'pivot y', pkNum);
    end;
  end;
  AddRow('minLevel', 'min level', pkNum);
  AddRow('maxLevel', 'max level', pkNum);
  AddRow('fire', 'fire flash (s)', pkNum);
end;

function PtIndex(const key: string; out idx: Integer; out isY: Boolean): Boolean;
begin
  Result := (Length(key) >= 3) and (key[1] = 'p') and (key[Length(key)] in ['x', 'y']) and
    TryStrToInt(Copy(key, 2, Length(key) - 2), idx);
  isY := Result and (key[Length(key)] = 'y');
end;

function GetNum(const sh: TShape; const key: string): Single;
var
  idx: Integer;
  isY: Boolean;
begin
  Result := 0;
  if PtIndex(key, idx, isY) then
  begin
    if idx * 2 + 1 <= High(sh.Pts) then Result := sh.Pts[idx * 2 + Ord(isY)];
    Exit;
  end;
  case key of
    'x': Result := sh.X;
    'y': Result := sh.Y;
    'r': Result := sh.R;
    'rx': Result := sh.RX;
    'ry': Result := sh.RY;
    'w': Result := sh.W;
    'h': Result := sh.H;
    'a0': Result := sh.A0;
    'a1': Result := sh.A1;
    'bob': Result := sh.Bob;
    'hover': Result := sh.Hover;
    'amp': Result := sh.Amp;
    'freq': Result := sh.Freq;
    'px': Result := sh.PX;
    'py': Result := sh.PY;
    'minLevel': Result := sh.MinLevel;
    'maxLevel': Result := sh.MaxLevel;
    'fire': Result := sh.Fire;
    'cr': Result := sh.Color.r;
    'cg': Result := sh.Color.g;
    'cb': Result := sh.Color.b;
    'ca': Result := sh.Color.a;
  end;
end;

procedure SetNum(var sh: TShape; const key: string; v: Single);
var
  idx: Integer;
  isY: Boolean;
begin
  if PtIndex(key, idx, isY) then
  begin
    if idx * 2 + 1 <= High(sh.Pts) then sh.Pts[idx * 2 + Ord(isY)] := v;
    Exit;
  end;
  case key of
    'x': sh.X := v;
    'y': sh.Y := v;
    'r': sh.R := Max(0, v);
    'rx': sh.RX := Max(0, v);
    'ry': sh.RY := Max(0, v);
    'w': sh.W := v;
    'h': sh.H := v;
    'a0': sh.A0 := v;
    'a1': sh.A1 := v;
    'bob': sh.Bob := v;
    'hover': sh.Hover := v;
    'amp': sh.Amp := v;
    'freq': sh.Freq := v;
    'px': sh.PX := v;
    'py': sh.PY := v;
    'minLevel': sh.MinLevel := EnsureRange(Round(v), 0, 9);
    'maxLevel': sh.MaxLevel := EnsureRange(Round(v), 0, 9);
    'fire': sh.Fire := Max(0, v);
    'cr': sh.Color.r := EnsureRange(Round(v), 0, 255);
    'cg': sh.Color.g := EnsureRange(Round(v), 0, 255);
    'cb': sh.Color.b := EnsureRange(Round(v), 0, 255);
    'ca': sh.Color.a := EnsureRange(Round(v), 0, 255);
  end;
end;

function NumStep(const key: string): Single;
begin
  if (key = 'cr') or (key = 'cg') or (key = 'cb') or (key = 'ca') then Result := 1
  else if (key = 'minLevel') or (key = 'maxLevel') then Result := 1
  else if (key = 'a0') or (key = 'a1') then Result := 5
  else if (key = 'fire') then Result := 0.05
  else Result := 0.5;
  if ModShift then Result := Result / 5
  else if ModCtrl then Result := Result * 10;
end;

function GetText(const key: string): string;
var
  sh: TShape;
begin
  Result := '';
  if not HaveObj then Exit;
  if key = 'oname' then Exit(Lib.Objects[CurObj].Name);
  if key = 'ocat' then Exit(Lib.Objects[CurObj].Category);
  if key = 'onotes' then Exit(Lib.Objects[CurObj].Notes);
  if not HaveShape then Exit;
  sh := Lib.Objects[CurObj].Shapes[SelShape];
  case key of
    'name': Result := sh.Name;
    'image': Result := sh.Image;
    'color': Result := ColorToStr(sh.Color);
    'color2': Result := ColorToStr(sh.Color2);
    'type': Result := ShapeTypeNames[sh.Kind];
    'anim': Result := AnimNames[sh.Anim];
    'grad': Result := BoolToStr(sh.HasGrad, 'yes', 'no');
    'add': Result := BoolToStr(sh.Add, 'yes', 'no');
    'hidden': Result := BoolToStr(sh.Hidden, 'yes', 'no');
  else
    Result := FmtNum(GetNum(sh, key));
  end;
end;

procedure CommitText(const key, value: string);
var
  sh: ^TShape;
  v: Single;
  fs: TFormatSettings;
begin
  if not HaveObj then Exit;
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  if key = 'oname' then
  begin
    if (Trim(value) <> '') and (Trim(value) <> Lib.Objects[CurObj].Name) then
    begin
      if (Lib.Find(Trim(value)) >= 0) and (Lib.Find(Trim(value)) <> CurObj) then
      begin
        Status('An object named "' + Trim(value) + '" already exists');
        Exit;
      end;
      PushUndo;
      Lib.Objects[CurObj].Name := Trim(value);
    end;
    Exit;
  end;
  if key = 'ocat' then
  begin
    PushUndo;
    Lib.Objects[CurObj].Category := Trim(value);
    Exit;
  end;
  if key = 'onotes' then
  begin
    PushUndo;
    Lib.Objects[CurObj].Notes := value;
    Exit;
  end;
  if not HaveShape then Exit;
  sh := @Lib.Objects[CurObj].Shapes[SelShape];
  PushUndo;
  case key of
    'name': sh^.Name := value;
    'image':
      begin
        sh^.Image := Trim(value);
        sh^.Tex := nil;
      end;
    'color': sh^.Color := ParseColor(value, sh^.Color);
    'color2': sh^.Color2 := ParseColor(value, sh^.Color2);
  else
    if TryStrToFloat(StringReplace(Trim(value), ',', '.', []), v, fs) then
      SetNum(sh^, key, v)
    else
      Status('Not a number: ' + value);
  end;
end;

procedure CycleEnum(const key: string; dir: Integer);
var
  sh: ^TShape;
  k: Integer;
begin
  if not HaveShape then Exit;
  sh := @Lib.Objects[CurObj].Shapes[SelShape];
  PushUndo;
  if key = 'type' then
  begin
    k := (Ord(sh^.Kind) + dir + Ord(High(TShapeType)) + 1) mod (Ord(High(TShapeType)) + 1);
    ConvertShape(sh^, TShapeType(k));
    SelHandle := -1;
  end
  else if key = 'anim' then
  begin
    k := (Ord(sh^.Anim) + dir + Ord(High(TAnimKind)) + 1) mod (Ord(High(TAnimKind)) + 1);
    sh^.Anim := TAnimKind(k);
    if (sh^.Anim <> akNone) and (sh^.Amp = 0) then
      case sh^.Anim of
        akStep: sh^.Amp := 2;
        akFlap: sh^.Amp := 25;
        akAimTilt: sh^.Amp := 30;
        akPulse: sh^.Amp := 0.15;
        akFlicker: sh^.Amp := 0.15;
        akGlow: sh^.Amp := 0.5;
        akSpin: sh^.Amp := 90;
      end;
  end;
end;

procedure ToggleBool(const key: string);
var
  sh: ^TShape;
begin
  if not HaveShape then Exit;
  sh := @Lib.Objects[CurObj].Shapes[SelShape];
  PushUndo;
  case key of
    'grad':
      begin
        sh^.HasGrad := not sh^.HasGrad;
        if sh^.HasGrad and (sh^.Color2.a = 0) and (sh^.Color2.r = 0) then
          sh^.Color2 := Shade(sh^.Color, 0.6);
      end;
    'add': sh^.Add := not sh^.Add;
    'hidden': sh^.Hidden := not sh^.Hidden;
  end;
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
  UI widgets (immediate mode)
  ====================================================================== }

{ ======================================================================
  panels
  ====================================================================== }

const
  BgNames: array[0..2] of string = ('dark', 'ground', 'check');

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
  if TB(60, 'Open') then AskOpen;
  if TB(60, 'Save', False, Lib.Count > 0) then DoSave;
  if TB(70, 'Save as', False, Lib.Count > 0) then AskSaveAs;
  Gap;
  if TB(56, 'Undo', False, Length(UndoStack) > 0) then DoUndo;
  if TB(56, 'Redo', False, Length(RedoStack) > 0) then DoRedo;
  Gap;
  if TB(46, 'Snap', SnapOn) then SnapOn := not SnapOn;
  if TB(46, 'Grid', ShowGrid) then ShowGrid := not ShowGrid;
  if TB(84, 'BG: ' + BgNames[BgMode]) then BgMode := (BgMode + 1) mod 3;
  if TB(44, 'Fit') then FitView;
  if TB(30, '-') then ViewZoom := Max(0.5, ViewZoom / 1.25);
  if TB(30, '+') then ViewZoom := Min(40, ViewZoom * 1.25);
  Gap;
  if TB(96, 'Export PNG', False, HaveObj) then
  begin
    // handled after the frame (needs the render target)
    EditKey := '';
    StatusMsg := '#export1';
  end;
  if TB(110, 'Export sheet', False, HaveObj) then StatusMsg := '#export8';
  DrawText(WIN_W - 10, 13, Format('zoom %d%%', [Round(ViewZoom * 100)]), C_DIM, fnSmall, ALIGN_RIGHT, False);
end;

procedure DrawObjectList;
var
  i, y0, n, visible: Integer;
  y: Single;
  lbl: string;
begin
  FillRect(0, TOP_H, LEFT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
  FillRect(LEFT_W - 1, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  DrawText(10, TOP_H + 6, Format('OBJECTS (%d)', [Lib.Count]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y0 := TOP_H + 28;
  visible := (WIN_H - STATUS_H - 70 - y0) div ROW_H;
  if Inside(0, y0, LEFT_W, visible * ROW_H) and (WheelY <> 0) then
  begin
    ObjScroll := EnsureRange(ObjScroll - Round(WheelY) * 3, 0, Max(0, Lib.Count - visible));
    WheelY := 0;
  end;
  ObjScroll := EnsureRange(ObjScroll, 0, Max(0, Lib.Count - visible));
  n := 0;
  SetClip(0, y0, LEFT_W, visible * ROW_H);
  for i := ObjScroll to Lib.Count - 1 do
  begin
    if n >= visible then Break;
    y := y0 + n * ROW_H;
    if i = CurObj then FillRect(4, y, LEFT_W - 9, ROW_H - 2, C_SEL)
    else if Inside(4, y, LEFT_W - 9, ROW_H - 2) then FillRect(4, y, LEFT_W - 9, ROW_H - 2, C_PANEL2);
    lbl := Lib.Objects[i].Name;
    DrawText(10, y + 2, lbl, C_TEXT, fnSmall, ALIGN_LEFT, False);
    DrawText(LEFT_W - 12, y + 2, Lib.Objects[i].Category, C_DIM, fnSmall, ALIGN_RIGHT, False);
    if Inside(4, y, LEFT_W - 9, ROW_H - 2) and LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      SelectObject(i);
    end;
    Inc(n);
  end;
  NoClip;
  y := WIN_H - STATUS_H - 64;
  if Button(8, y, 70, 26, 'New') then NewObject;
  if Button(82, y, 70, 26, 'Duplicate', False, HaveObj) then DuplicateObject;
  if Button(156, y, 66, 26, 'Delete', False, HaveObj) then DeleteObject;
  DrawText(10, y + 34, 'Ctrl+N new  Ctrl+O open', C_DIM, fnSmall, ALIGN_LEFT, False);
end;

const
  TypeShort: array[TShapeType] of string = ('circ', 'ell', 'rect', 'rrect', 'poly', 'line', 'ring', 'pie', 'img');

procedure DrawLayers;
var
  x0, y0, i, n, visible, cnt, row: Integer;
  y: Single;
  sh: TShape;
  c: TRGBA;
  st: TAnimState;
  k: TShapeType;
  bx: Single;
begin
  x0 := WIN_W - RIGHT_W;
  FillRect(x0, TOP_H, RIGHT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
  FillRect(x0, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  if not HaveObj then Exit;
  cnt := Length(Lib.Objects[CurObj].Shapes);
  DrawText(x0 + 10, TOP_H + 6, Format('SHAPES (%d)  - top of list is drawn first', [cnt]), C_ACCENT, fnSmall,
    ALIGN_LEFT, False);
  y0 := TOP_H + 28;
  visible := (LAYER_H - 130) div ROW_H;
  if Inside(x0, y0, RIGHT_W, visible * ROW_H) and (WheelY <> 0) then
  begin
    LayerScroll := LayerScroll - Round(WheelY) * 3;
    WheelY := 0;
  end;
  if HaveShape then
  begin
    if SelShape < LayerScroll then LayerScroll := SelShape;
    if SelShape >= LayerScroll + visible then LayerScroll := SelShape - visible + 1;
  end;
  LayerScroll := EnsureRange(LayerScroll, 0, Max(0, cnt - visible));
  st := SimState;
  n := 0;
  SetClip(x0, y0, RIGHT_W, visible * ROW_H);
  for i := LayerScroll to cnt - 1 do
  begin
    if n >= visible then Break;
    sh := Lib.Objects[CurObj].Shapes[i];
    y := y0 + n * ROW_H;
    if i = SelShape then FillRect(x0 + 4, y, RIGHT_W - 9, ROW_H - 2, C_SEL)
    else if Inside(x0 + 4, y, RIGHT_W - 9, ROW_H - 2) then FillRect(x0 + 4, y, RIGHT_W - 9, ROW_H - 2, C_PANEL2);
    // visibility toggle
    if sh.Hidden then c := RGBA(90, 90, 96) else c := C_TEXT;
    Ring(x0 + 16, y + 10, 7, 4.5, 1.5, c);
    if not sh.Hidden then FillCircle(x0 + 16, y + 10, 2.5, c);
    if Inside(x0 + 6, y, 22, ROW_H - 2) and LDown and not Consumed then
    begin
      Consumed := True;
      SelShape := i;
      PushUndo;
      Lib.Objects[CurObj].Shapes[i].Hidden := not sh.Hidden;
    end;
    Swatch(x0 + 30, y + 4, 14, 13, sh.Color);
    if ShapeVisible(sh, st, dmAll) or sh.Hidden then c := C_TEXT else c := RGBA(110, 112, 120);
    DrawText(x0 + 50, y + 2, IntToStr(i) + '  ' + TypeShort[sh.Kind], C_DIM, fnSmall, ALIGN_LEFT, False);
    DrawText(x0 + 108, y + 2, sh.Name, c, fnSmall, ALIGN_LEFT, False);
    if sh.Anim <> akNone then
      DrawText(x0 + RIGHT_W - 12, y + 2, AnimNames[sh.Anim], RGBA(140, 200, 140), fnSmall, ALIGN_RIGHT, False)
    else if (sh.MinLevel > 0) or (sh.MaxLevel > 0) then
      DrawText(x0 + RIGHT_W - 12, y + 2, Format('L%d-%d', [Max(1, sh.MinLevel), IfThen(sh.MaxLevel > 0, sh.MaxLevel, 9)]),
        RGBA(200, 170, 120), fnSmall, ALIGN_RIGHT, False);
    if Inside(x0 + 28, y, RIGHT_W - 33, ROW_H - 2) and LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      SelShape := i;
      SelHandle := -1;
    end;
    Inc(n);
  end;
  NoClip;
  // add-shape buttons
  y := y0 + visible * ROW_H + 6;
  DrawText(x0 + 10, y + 4, 'Add:', C_DIM, fnSmall, ALIGN_LEFT, False);
  bx := x0 + 44;
  row := 0;
  for k := Low(TShapeType) to High(TShapeType) do
  begin
    if Button(bx, y + row * 28, 56, 24, TypeShort[k]) then AddShape(k);
    bx := bx + 60;
    if bx > x0 + RIGHT_W - 60 then
    begin
      bx := x0 + 44;
      Inc(row);
    end;
  end;
  y := y + 2 * 28 + 4;
  if Button(x0 + 8, y, 52, 24, 'Up', False, HaveShape and (SelShape > 0)) then MoveLayer(-1);
  if Button(x0 + 64, y, 52, 24, 'Down', False, HaveShape and (SelShape < cnt - 1)) then MoveLayer(1);
  if Button(x0 + 120, y, 52, 24, 'Copy', False, HaveShape) then
    InsertShapeCopy(Lib.Objects[CurObj].Shapes[SelShape], 2);
  if Button(x0 + 176, y, 60, 24, 'Delete', False, HaveShape) then DeleteShape;
  if HaveShape and (Lib.Objects[CurObj].Shapes[SelShape].Kind in [stPoly, stLine]) then
  begin
    if Button(x0 + 240, y, 48, 24, '+pt') then AddVertex;
    if Button(x0 + 292, y, 48, 24, '-pt') then RemoveVertex;
  end;
end;

procedure DrawProps;
var
  x0, y0, i, visible, n: Integer;
  y, vx: Single;
  r: TPropRow;
  txt: string;
  sh: TShape;
  hover: Boolean;
begin
  x0 := WIN_W - RIGHT_W;
  y0 := TOP_H + LAYER_H + 8;
  FillRect(x0, y0 - 6, RIGHT_W, 1, C_LINE);
  if not HaveObj then Exit;
  BuildRows;
  if HaveShape then
    DrawText(x0 + 10, y0, 'SHAPE PROPERTIES', C_ACCENT, fnSmall, ALIGN_LEFT, False)
  else
    DrawText(x0 + 10, y0, 'OBJECT PROPERTIES', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y0 := y0 + 22;
  visible := (WIN_H - STATUS_H - 8 - y0) div ROW_H;
  if Inside(x0, y0, RIGHT_W, visible * ROW_H) and (WheelY <> 0) and (Drag = drNone) then
  begin
    // wheel over a numeric value steps it; elsewhere it scrolls
    i := PropScroll + Trunc((MY - y0) / ROW_H);
    vx := x0 + 130;
    if (i >= 0) and (i <= High(Rows)) and (Rows[i].Kind = pkNum) and (MX >= vx) and HaveShape then
    begin
      PushUndo;
      sh := Lib.Objects[CurObj].Shapes[SelShape];
      SetNum(Lib.Objects[CurObj].Shapes[SelShape], Rows[i].Key, GetNum(sh, Rows[i].Key) + WheelY * NumStep(Rows[i].Key));
    end
    else
      PropScroll := PropScroll - Round(WheelY) * 2;
    WheelY := 0;
  end;
  PropScroll := EnsureRange(PropScroll, 0, Max(0, Length(Rows) - visible));
  if HaveShape then sh := Lib.Objects[CurObj].Shapes[SelShape];
  n := 0;
  SetClip(x0, y0, RIGHT_W, visible * ROW_H);
  for i := PropScroll to High(Rows) do
  begin
    if n >= visible then Break;
    r := Rows[i];
    y := y0 + n * ROW_H;
    Inc(n);
    if r.Kind = pkInfo then
    begin
      DrawText(x0 + 10, y + 2, r.Caption, C_DIM, fnSmall, ALIGN_LEFT, False);
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
          if r.Key = 'color' then Swatch(vx + 2, y + 3, 30, 15, sh.Color)
          else Swatch(vx + 2, y + 3, 30, 15, sh.Color2);
          DrawText(vx + 38, y + 2, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
        end;
      pkEnum:
        DrawText(vx + 4, y + 2, '< ' + txt + ' >', RGBA(160, 210, 255), fnSmall, ALIGN_LEFT, False);
      pkBool:
        begin
          RoundRect(vx + 2, y + 3, 16, 15, 3, RGBA(25, 27, 32));
          if txt = 'yes' then FillRect(vx + 6, y + 7, 8, 7, C_ACCENT);
        end;
      pkNum:
        begin
          DrawText(vx + 4, y + 2, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
          if hover then DrawText(x0 + RIGHT_W - 12, y + 2, '<->', C_DIM, fnSmall, ALIGN_RIGHT, False);
        end;
    else
      DrawText(vx + 4, y + 2, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
    end;
    if hover and (LDown or RDown) and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      case r.Kind of
        pkText, pkColor: if LDown then BeginEdit(r.Key);
        pkEnum: if LDown then CycleEnum(r.Key, 1) else CycleEnum(r.Key, -1);
        pkBool: if LDown then ToggleBool(r.Key);
        pkNum:
          if LDown then
          begin
            Drag := drScrub;
            ScrubKey := r.Key;
            ScrubStartVal := GetNum(sh, r.Key);
            DragStartX := MX;
            ScrubMoved := False;
            DragUndoPushed := False;
          end;
      end;
    end;
  end;
  NoClip;
  if HaveShape and (sh.Kind = stImage) then
    if Button(x0 + 10, WIN_H - STATUS_H - 32, 120, 24, 'Pick image...') then AskImage;
end;

{ ======================================================================
  canvas
  ====================================================================== }

procedure DrawGrid;
var
  ox, oy, step, x, y: Single;
  i, i0, i1, major: Integer;
  c: TRGBA;
begin
  OriginXY(ox, oy);
  if SimWalkPreview then ox := ox - SimWalkX * ViewZoom;
  step := 5;
  while step * ViewZoom < 8 do step := step * 2;
  major := 5;
  i0 := Floor((CV_X - ox) / (step * ViewZoom));
  i1 := Ceil((CV_X + CV_W - ox) / (step * ViewZoom));
  for i := i0 to i1 do
  begin
    x := ox + i * step * ViewZoom;
    if i mod major = 0 then c := RGBA(255, 255, 255, 34) else c := RGBA(255, 255, 255, 14);
    FillRect(x, CV_Y, 1, CV_H, c);
  end;
  i0 := Floor((CV_Y - oy) / (step * ViewZoom));
  i1 := Ceil((CV_Y + CV_H - oy) / (step * ViewZoom));
  for i := i0 to i1 do
  begin
    y := oy + i * step * ViewZoom;
    if i mod major = 0 then c := RGBA(255, 255, 255, 34) else c := RGBA(255, 255, 255, 14);
    FillRect(CV_X, y, CV_W, 1, c);
  end;
end;

procedure DrawSelection;
var
  sh: TShape;
  x0, y0, x1, y1, sx0, sy0, sx1, sy1, hx, hy, t: Single;
  hs: THandleArray;
  i: Integer;
  c: TRGBA;
begin
  if not HaveShape then Exit;
  sh := Lib.Objects[CurObj].Shapes[SelShape];
  ShapeBounds(sh, x0, y0, x1, y1);
  LocalToScreen(x0, y0, sx0, sy0);
  LocalToScreen(x1, y1, sx1, sy1);
  if sx1 < sx0 then
  begin
    t := sx0; sx0 := sx1; sx1 := t;
  end;
  // dashed bounding box
  i := 0;
  while sx0 + i * 8 < sx1 do
  begin
    FillRect(sx0 + i * 8, sy0 - 3, Min(4, sx1 - sx0 - i * 8), 1, C_ACCENT);
    FillRect(sx0 + i * 8, sy1 + 3, Min(4, sx1 - sx0 - i * 8), 1, C_ACCENT);
    Inc(i);
  end;
  i := 0;
  while sy0 + i * 8 < sy1 do
  begin
    FillRect(sx0 - 3, sy0 + i * 8, 1, Min(4, sy1 - sy0 - i * 8), C_ACCENT);
    FillRect(sx1 + 3, sy0 + i * 8, 1, Min(4, sy1 - sy0 - i * 8), C_ACCENT);
    Inc(i);
  end;
  hs := ShapeHandles(sh);
  for i := 0 to High(hs) do
  begin
    LocalToScreen(hs[i].X, hs[i].Y, hx, hy);
    if hs[i].Id = 1000 then
    begin
      Ring(hx, hy, 7, 7, 2, RGBA(120, 255, 160));
      FillRect(hx - 9, hy, 18, 1, RGBA(120, 255, 160));
      FillRect(hx, hy - 9, 1, 18, RGBA(120, 255, 160));
      Continue;
    end;
    if hs[i].Id = SelHandle then c := RGBA(255, 255, 255) else c := C_ACCENT;
    FillRect(hx - 5, hy - 5, 10, 10, RGBA(20, 20, 20));
    FillRect(hx - 4, hy - 4, 8, 8, c);
  end;
end;

procedure DrawPreviewInset;
var
  x, y, w, h: Single;
  st: TAnimState;
begin
  if not HaveObj then Exit;
  w := 190; h := 150;
  x := CV_X + CV_W - w - 10;
  y := CV_Y + CV_H - h - 10;
  FillRect(x - 2, y - 2, w + 4, h + 4, RGBA(0, 0, 0, 160));
  FillRect(x, y, w, h, RGBA(112, 74, 46));
  FillEllipse(x + w / 2, y + h * 0.72, 70, 22, RGBA(214, 168, 108));
  st := SimState;
  DrawGeo(Lib.Objects[CurObj], x + w / 2 + SimWalkX * 0.25, y + h * 0.72, 1, st);
  DrawText(x + 6, y + 4, 'in-game size (1:1)', RGBA(255, 240, 210), fnSmall, ALIGN_LEFT, True);
end;

procedure DrawCanvas;
var
  ox, oy, lx, ly: Single;
  st: TAnimState;
begin
  SetClip(CV_X, CV_Y, CV_W, CV_H);
  case BgMode of
    0: FillRect(CV_X, CV_Y, CV_W, CV_H, RGBA(24, 26, 30));
    1: FillRect(CV_X, CV_Y, CV_W, CV_H, RGBA(112, 74, 46));
  else
    Checker(CV_X, CV_Y, CV_W, CV_H, 16);
  end;
  if ShowGrid then DrawGrid;
  OriginXY(ox, oy);
  // ground line and origin cross
  FillRect(CV_X, oy, CV_W, 1, RGBA(255, 120, 80, 90));
  FillRect(ox, CV_Y, 1, CV_H, RGBA(80, 160, 255, 70));
  if HaveObj then
  begin
    st := SimState;
    DrawGeo(Lib.Objects[CurObj], ox, oy, ViewZoom, st);
    DrawSelection;
  end
  else
    DrawText(CV_X + CV_W / 2, CV_Y + CV_H / 2, 'No object. Open a geometry file or press New.', C_DIM, fnMedium,
      ALIGN_CENTER, False);
  FillCircle(ox, oy, 3, RGBA(255, 255, 255, 200));
  DrawPreviewInset;
  if Inside(CV_X, CV_Y, CV_W, CV_H) then
  begin
    ScreenToLocal(MX, MY, lx, ly);
    DrawText(CV_X + 8, CV_Y + 6, Format('x %s   y %s', [FmtNum(Round(lx * 10) / 10), FmtNum(Round(ly * 10) / 10)]),
      RGBA(255, 255, 255, 200), fnSmall, ALIGN_LEFT, True);
  end;
  if HaveObj then
    DrawText(CV_X + CV_W - 8, CV_Y + 6, Lib.Objects[CurObj].Name, RGBA(255, 230, 170), fnMedium, ALIGN_RIGHT, True);
  NoClip;
end;

function HitShape(lx, ly: Single): Integer;
var
  i: Integer;
  st: TAnimState;
begin
  Result := -1;
  if not HaveObj then Exit;
  st := SimState;
  st.SinceFire := 0;    // allow picking muzzle flashes
  for i := High(Lib.Objects[CurObj].Shapes) downto 0 do
    if ShapeVisible(Lib.Objects[CurObj].Shapes[i], st, dmAll) and ShapeHit(Lib.Objects[CurObj].Shapes[i], lx, ly) then
      Exit(i);
end;

function HitHandle(sx, sy: Single): Integer;
var
  hs: THandleArray;
  i: Integer;
  hx, hy: Single;
begin
  Result := -1;
  if not HaveShape then Exit;
  hs := ShapeHandles(Lib.Objects[CurObj].Shapes[SelShape]);
  for i := High(hs) downto 0 do
  begin
    LocalToScreen(hs[i].X, hs[i].Y, hx, hy);
    if (Abs(sx - hx) <= 7) and (Abs(sy - hy) <= 7) then Exit(hs[i].Id);
  end;
end;

procedure CanvasInput;
var
  lx, ly, f, ox, oy, dx, dy: Single;
  h: Integer;
begin
  if not Inside(CV_X, CV_Y, CV_W, CV_H) then Exit;
  if WheelY <> 0 then
  begin
    ScreenToLocal(MX, MY, lx, ly);
    f := Power(1.15, WheelY);
    ViewZoom := EnsureRange(ViewZoom * f, 0.5, 40);
    // keep the point under the cursor fixed
    OriginXY(ox, oy);
    if SimFacing < 0 then lx := -lx;
    PanX := PanX + (MX - (ox + lx * ViewZoom));
    PanY := PanY + (MY - (oy + ly * ViewZoom));
    WheelY := 0;
  end;
  if (RDown or MDownBtn) and not Consumed then
  begin
    Consumed := True;
    Drag := drPan;
    DragStartX := MX;
    DragStartY := MY;
  end;
  if LDown and not Consumed then
  begin
    Consumed := True;
    EndEdit(True);
    ScreenToLocal(MX, MY, lx, ly);
    h := HitHandle(MX, MY);
    if h >= 0 then
    begin
      SelHandle := h;
      Drag := drHandle;
    end
    else
    begin
      SelShape := HitShape(lx, ly);
      SelHandle := -1;
      if SelShape >= 0 then Drag := drShape else Drag := drNone;
    end;
    DragLastLX := Snap(lx);
    DragLastLY := Snap(ly);
    DragUndoPushed := False;
  end;
  if (Drag in [drShape, drHandle]) and LHeld and HaveShape then
  begin
    ScreenToLocal(MX, MY, lx, ly);
    lx := Snap(lx);
    ly := Snap(ly);
    dx := lx - DragLastLX;
    dy := ly - DragLastLY;
    if (dx <> 0) or (dy <> 0) then
    begin
      if not DragUndoPushed then
      begin
        PushUndo;
        DragUndoPushed := True;
      end;
      if Drag = drShape then MoveShape(Lib.Objects[CurObj].Shapes[SelShape], dx, dy)
      else MoveHandle(Lib.Objects[CurObj].Shapes[SelShape], SelHandle, lx, ly);
      DragLastLX := lx;
      DragLastLY := ly;
    end;
  end;
end;

procedure UpdateDrags;
var
  v: Single;
  sh: TShape;
begin
  if Drag = drPan then
  begin
    if RHeld or MHeld then
    begin
      PanX := PanX + (MX - DragStartX);
      PanY := PanY + (MY - DragStartY);
      DragStartX := MX;
      DragStartY := MY;
    end
    else
      Drag := drNone;
  end
  else if Drag = drScrub then
  begin
    if not HaveShape then
    begin
      Drag := drNone;
      Exit;
    end;
    if LHeld then
    begin
      if Abs(MX - DragStartX) > 3 then ScrubMoved := True;
      if ScrubMoved then
      begin
        if not DragUndoPushed then
        begin
          PushUndo;
          DragUndoPushed := True;
        end;
        v := ScrubStartVal + Round((MX - DragStartX) / 4) * NumStep(ScrubKey);
        SetNum(Lib.Objects[CurObj].Shapes[SelShape], ScrubKey, v);
      end;
    end
    else
    begin
      if not ScrubMoved then BeginEdit(ScrubKey);
      Drag := drNone;
    end;
  end
  else if (Drag in [drShape, drHandle]) and not LHeld then
    Drag := drNone;
  if HaveShape then sh := Lib.Objects[CurObj].Shapes[SelShape];
end;

{ ======================================================================
  simulation bar
  ====================================================================== }

procedure DrawSimBar;
var
  y, x: Single;

  function SB(w: Single; const caption: string; active: Boolean = False): Boolean;
  begin
    Result := Button(x, y, w, 26, caption, active);
    x := x + w + 4;
  end;

begin
  y := CV_Y + CV_H;
  FillRect(CV_X, y, CV_W, SIM_H, C_PANEL);
  FillRect(CV_X, y, CV_W, 1, C_LINE);
  DrawText(CV_X + 10, y + 6, 'SIMULATE', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y + 8;
  x := CV_X + 90;
  if SB(64, IfThen(Playing, 'Pause', 'Play'), Playing) then Playing := not Playing;
  if SB(64, 'Walking', SimMoving) then SimMoving := not SimMoving;
  if SB(74, 'Walk path', SimWalkPreview) then
  begin
    SimWalkPreview := not SimWalkPreview;
    SimWalkX := 0;
  end;
  if SB(64, IfThen(SimFacing > 0, 'Face >', '< Face')) then SimFacing := -SimFacing;
  if SB(64, 'Attack') then
  begin
    SimSwing := 0.25;
    SimSinceFire := 0;
  end;
  if SB(80, 'Auto attack', SimAuto) then SimAuto := not SimAuto;
  if SB(84, 'Aim: mouse', SimAimMouse) then SimAimMouse := not SimAimMouse;
  y := y + 32;
  x := CV_X + 90;
  DrawText(CV_X + 10, y + 4, 'tower level', C_DIM, fnSmall, ALIGN_LEFT, False);
  if SB(32, '1', SimLevel = 1) then SimLevel := 1;
  if SB(32, '2', SimLevel = 2) then SimLevel := 2;
  if SB(32, '3', SimLevel = 3) then SimLevel := 3;
  x := x + 16;
  DrawText(x, y + 4, 'speed', C_DIM, fnSmall, ALIGN_LEFT, False);
  x := x + 46;
  if SB(52, '0.25x', SimSpeed = 0.25) then SimSpeed := 0.25;
  if SB(44, '0.5x', SimSpeed = 0.5) then SimSpeed := 0.5;
  if SB(44, '1x', SimSpeed = 1) then SimSpeed := 1;
  if SB(44, '2x', SimSpeed = 2) then SimSpeed := 2;
  x := x + 16;
  DrawText(x, y + 4, Format('t=%.2fs  aim=%d deg', [SimTime, Round(RadToDeg(SimAim))]), C_DIM, fnSmall,
    ALIGN_LEFT, False);
end;

procedure UpdateSim(dt: Single);
var
  ox, oy: Single;
begin
  if SimAimMouse and Inside(CV_X, CV_Y, CV_W, CV_H) then
  begin
    OriginXY(ox, oy);
    SimAim := ArcTan2(MY - (oy - 40 * ViewZoom), MX - ox);
  end;
  if not Playing then Exit;
  dt := dt * SimSpeed;
  SimTime := SimTime + dt;
  if SimMoving then SimWalk := SimWalk + dt;
  if SimSwing > 0 then SimSwing := Max(0, SimSwing - dt);
  SimSinceFire := SimSinceFire + dt;
  if SimAuto then
  begin
    SimAutoT := SimAutoT + dt;
    if SimAutoT >= 1 then
    begin
      SimAutoT := 0;
      SimSwing := 0.25;
      SimSinceFire := 0;
    end;
  end;
  if not SimAimMouse then SimAim := SimAim + dt * 0.8;
  if SimWalkPreview and SimMoving then
  begin
    SimWalkX := SimWalkX + SimWalkDir * 40 * dt;
    if Abs(SimWalkX) > 120 then
    begin
      SimWalkX := EnsureRange(SimWalkX, -120, 120);
      SimWalkDir := -SimWalkDir;
    end;
    SimFacing := SimWalkDir;
  end;
end;

{ ======================================================================
  export (bitmaps)
  ====================================================================== }

procedure ExportBitmap(frames: Integer);
const
  SCALE = 2;
  PERIOD = 0.7;     // ~ one walk cycle
var
  i, fw, fh, k: Integer;
  x0, y0, x1, y1, a, b, c, d: Single;
  tex: PSDL_Texture;
  surf: PSDL_Surface;
  st: TAnimState;
  dir, base, fn: string;
  sl: TStringList;
  o: TGeoObject;
begin
  if not HaveObj then Exit;
  o := Lib.Objects[CurObj];
  x0 := 1e9; y0 := 1e9; x1 := -1e9; y1 := -1e9;
  for k := 0 to High(o.Shapes) do
  begin
    ShapeBounds(o.Shapes[k], a, b, c, d);
    x0 := Min(x0, a); y0 := Min(y0, b); x1 := Max(x1, c); y1 := Max(y1, d);
  end;
  if x0 > x1 then Exit;
  // room for animation (bob, swings, flaps)
  x0 := Floor(x0 - 8); y0 := Floor(y0 - 8); x1 := Ceil(x1 + 8); y1 := Ceil(y1 + 8);
  fw := Round((x1 - x0) * SCALE);
  fh := Round((y1 - y0) * SCALE);
  tex := SDL_CreateTexture(Renderer, SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_TARGET, fw * frames, fh);
  if tex = nil then
  begin
    Status('Export failed: ' + string(SDL_GetError));
    Exit;
  end;
  SDL_SetRenderTarget(Renderer, tex);
  SDL_SetRenderDrawColor(Renderer, 0, 0, 0, 0);
  SDL_RenderClear(Renderer);
  for i := 0 to frames - 1 do
  begin
    st := DefaultAnimState;
    st.Level := SimLevel;
    st.Facing := 1;
    st.Aim := SimAim;
    if frames > 1 then
    begin
      st.Time := i * PERIOD / frames;
      st.Walk := st.Time;
      st.Moving := True;
      st.Swing := 0.25 * (1 - i / frames);
    end
    else
      st.Moving := False;
    DrawGeo(o, i * fw - x0 * SCALE, -y0 * SCALE, SCALE, st);
  end;
  surf := SDL_RenderReadPixels(Renderer, nil);
  SDL_SetRenderTarget(Renderer, nil);
  SDL_DestroyTexture(tex);
  if surf = nil then
  begin
    Status('Export failed: ' + string(SDL_GetError));
    Exit;
  end;
  dir := ExtractFilePath(ExpandFileName(Lib.FileName));
  if dir = '' then dir := ExtractFilePath(ParamStr(0));
  dir := dir + 'export' + PathDelim;
  ForceDirectories(dir);
  base := o.Name;
  if frames > 1 then base := base + '_sheet';
  fn := dir + base + '.png';
  if IMG_SavePNG(surf, PAnsiChar(fn)) then
  begin
    // metadata: frame size and where the object's origin (feet) lies in each frame
    sl := TStringList.Create;
    try
      sl.Add('{');
      sl.Add(Format('  "object": "%s", "image": "%s.png", "scale": %d,', [o.Name, base, SCALE]));
      sl.Add(Format('  "frames": %d, "frameWidth": %d, "frameHeight": %d,', [frames, fw, fh]));
      sl.Add(Format('  "originX": %d, "originY": %d, "frameTime": %s', [Round(-x0 * SCALE), Round(-y0 * SCALE),
        FmtNum(PERIOD / frames)]));
      sl.Add('}');
      sl.SaveToFile(dir + base + '.json');
    finally
      sl.Free;
    end;
    Status('Exported ' + fn);
  end
  else
    Status('PNG save failed: ' + string(SDL_GetError));
  SDL_DestroySurface(surf);
end;

procedure ExportScreenshot(const fn: string);
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

{ ======================================================================
  keyboard
  ====================================================================== }

procedure HandleKey(key: TSDL_Keycode);
var
  d: Single;
begin
  if EditKey <> '' then
  begin
    case key of
      SDLK_RETURN: EndEdit(True);
      SDLK_ESCAPE: EndEdit(False);
      SDLK_BACKSPACE: if EditBuf <> '' then Delete(EditBuf, Length(EditBuf), 1);
      SDLK_TAB: EndEdit(True);
    end;
    Exit;
  end;
  if ModCtrl then
  begin
    case key of
      SDLK_S: if ModShift then AskSaveAs else DoSave;
      SDLK_O: AskOpen;
      SDLK_N: NewObject;
      SDLK_Z: if ModShift then DoRedo else DoUndo;
      SDLK_Y: DoRedo;
      SDLK_D: if HaveShape then InsertShapeCopy(Lib.Objects[CurObj].Shapes[SelShape], 2);
      SDLK_C:
        if HaveShape then
        begin
          ClipShape := CloneShape(Lib.Objects[CurObj].Shapes[SelShape]);
          HasClip := True;
          SDL_SetClipboardText(PAnsiChar(ShapeToJSON(ClipShape)));
          Status('Shape copied');
        end;
      SDLK_V: if HasClip then InsertShapeCopy(ClipShape, 0);
    end;
    Exit;
  end;
  if ModShift then d := 5 else d := 1;
  case key of
    SDLK_DELETE: DeleteShape;
    SDLK_ESCAPE:
      begin
        SelShape := -1;
        SelHandle := -1;
      end;
    SDLK_LEFT, SDLK_RIGHT, SDLK_UP, SDLK_DOWN:
      if HaveShape then
      begin
        PushUndo;
        case key of
          SDLK_LEFT: MoveShape(Lib.Objects[CurObj].Shapes[SelShape], -d, 0);
          SDLK_RIGHT: MoveShape(Lib.Objects[CurObj].Shapes[SelShape], d, 0);
          SDLK_UP: MoveShape(Lib.Objects[CurObj].Shapes[SelShape], 0, -d);
          SDLK_DOWN: MoveShape(Lib.Objects[CurObj].Shapes[SelShape], 0, d);
        end;
      end;
    SDLK_PAGEUP: MoveLayer(-1);
    SDLK_PAGEDOWN: MoveLayer(1);
    SDLK_TAB:
      if HaveObj and (Length(Lib.Objects[CurObj].Shapes) > 0) then
      begin
        SelShape := (SelShape + 1) mod Length(Lib.Objects[CurObj].Shapes);
        SelHandle := -1;
      end;
    SDLK_H:
      if HaveShape then
      begin
        PushUndo;
        Lib.Objects[CurObj].Shapes[SelShape].Hidden := not Lib.Objects[CurObj].Shapes[SelShape].Hidden;
      end;
    SDLK_SPACE: Playing := not Playing;
    SDLK_A:
      begin
        SimSwing := 0.25;
        SimSinceFire := 0;
      end;
    SDLK_1: SimLevel := 1;
    SDLK_2: SimLevel := 2;
    SDLK_3: SimLevel := 3;
    SDLK_HOME: FitView;
    SDLK_G: SnapOn := not SnapOn;
  end;
end;

{ ======================================================================
  main
  ====================================================================== }

var
  Event: TSDL_Event;
  Running: Boolean;
  ShotFile: string = '';
  ShotFrames: Integer = 0;
  ShotExport: Integer = 0;
  ArgI: Integer;
  Last, Now_: UInt64;
  Dt: Single;
  StartFile: string;
  ExportReq: Integer;

begin
  InitCriticalSection(DlgLock);
  JsonFilter[0].Name := 'Geometry JSON';
  JsonFilter[0].pattern := 'json';
  ImageFilter[0].Name := 'Images';
  ImageFilter[0].pattern := 'png;bmp;jpg;jpeg;webp';

  if not SDL_Init(SDL_INIT_VIDEO) then Halt(1);
  if not SDL_CreateWindowAndRenderer('GeoEdit', WIN_W, WIN_H, SDL_WINDOW_RESIZABLE, @Window, @Renderer) then
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
  if (ParamCount >= 1) and (Copy(ParamStr(1), 1, 2) <> '--') then StartFile := ParamStr(1)
  else StartFile := ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'geometry.json';
  if FileExists(StartFile) then OpenFile(StartFile)
  else
  begin
    Lib.FileName := StartFile;
    NewObject;
    Modified := False;
    Status('New geometry file - ' + StartFile);
  end;
  UpdateTitle;
  // test hooks: --shot <file.bmp> <object> [shape] [export frames]
  for ArgI := 1 to ParamCount - 2 do
    if ParamStr(ArgI) = '--shot' then
    begin
      ShotFile := ParamStr(ArgI + 1);
      SelectObject(Max(0, Lib.Find(ParamStr(ArgI + 2))));
      if ArgI + 3 <= ParamCount then SelShape := StrToIntDef(ParamStr(ArgI + 3), -1);
      if ArgI + 4 <= ParamCount then ShotExport := StrToIntDef(ParamStr(ArgI + 4), 0);
      MX := CV_X + CV_W * 0.8;
      MY := CV_Y + CV_H * 0.3;
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
          begin
            UIUpdateMods;
            HandleKey(Event.key.key);
          end;
        SDL_EVENT_DROP_FILE:
          if (Event.drop.data <> nil) and ConfirmDiscard then OpenFile(string(Event.drop.data));
      end;
    end;
    UIUpdateMods;
    HandleDialogResult;
    Now_ := SDL_GetTicks;
    Dt := Min(0.05, (Now_ - Last) / 1000);
    Last := Now_;
    UpdateSim(Dt);
    if StatusTime > 0 then StatusTime := StatusTime - Dt;
    UpdateDrags;

    SDL_SetRenderDrawColor(Renderer, C_BG.r, C_BG.g, C_BG.b, 255);
    SDL_RenderClear(Renderer);
    // panels first so their buttons get first claim on clicks; canvas takes what's left
    DrawToolbar;
    DrawObjectList;
    DrawLayers;
    DrawProps;
    DrawSimBar;
    CanvasInput;
    DrawCanvas;
    // status bar
    FillRect(0, WIN_H - STATUS_H, WIN_W, STATUS_H, C_PANEL);
    FillRect(0, WIN_H - STATUS_H, WIN_W, 1, C_LINE);
    ExportReq := 0;
    if StatusMsg = '#export1' then ExportReq := 1
    else if StatusMsg = '#export8' then ExportReq := 8;
    if ExportReq > 0 then StatusMsg := '';
    if (StatusTime > 0) and (StatusMsg <> '') then
      DrawText(10, WIN_H - STATUS_H + 3, StatusMsg, C_ACCENT, fnSmall, ALIGN_LEFT, False)
    else
      DrawText(10, WIN_H - STATUS_H + 3,
        'Drag shapes / handles  |  RMB drag: pan  |  wheel: zoom  |  Ctrl+Z/Y undo/redo  |  Del delete  |  ' +
        'PgUp/PgDn layer order  |  Space play/pause  |  A attack', C_DIM, fnSmall, ALIGN_LEFT, False);
    if Modified then
      DrawText(WIN_W - 10, WIN_H - STATUS_H + 3, 'modified', RGBA(255, 150, 120), fnSmall, ALIGN_RIGHT, False);
    if ShotFile <> '' then
    begin
      Inc(ShotFrames);
      if ShotFrames = 40 then
      begin
        if ShotExport > 0 then ExportReq := ShotExport;
        ExportScreenshot(ShotFile);
        Running := False;
      end;
    end;
    SDL_RenderPresent(Renderer);
    if ExportReq > 0 then
    begin
      SDL_SetRenderLogicalPresentation(Renderer, WIN_W, WIN_H, SDL_LOGICAL_PRESENTATION_DISABLED);
      ExportBitmap(ExportReq);
      SDL_SetRenderLogicalPresentation(Renderer, WIN_W, WIN_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
    end;
    UpdateTitle;
  end;

  Lib.Free;
  GfxDone;
  DoneCriticalSection(DlgLock);
  SDL_DestroyRenderer(Renderer);
  SDL_DestroyWindow(Window);
  SDL_Quit;
end.
