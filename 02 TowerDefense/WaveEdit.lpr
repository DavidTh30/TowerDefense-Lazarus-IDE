program WaveEdit;

{ WaveEdit - wave editor for Brewhold Defense (Lazarus / Free Pascal + SDL3)

  Edits the waves file of the selected map ("waves" in the map json, default data\waves.json).
  Each wave is a list of spawn groups:
    enemy, count, path (index into the map's roads), start (s), interval (s).

  Layout
    left ....... wave list (add / duplicate / delete / reorder), click to select
    centre ..... group table, spawn timeline (one lane per road), difficulty chart for all waves
    right ...... live preview of the selected wave walking the map, wave stats, enemy reference
  Editing
    Table numbers: drag left/right to scrub (Shift fine, Ctrl coarse), click to type, wheel to step.
    Enemy cell: click = next enemy, right-click = previous.
    Timeline: drag a group's spawns sideways to change its start time.
  Keys
    Ctrl+S save   Ctrl+Z / Ctrl+Y undo / redo   Ctrl+D duplicate group   Ins add group   Del delete group
    Up / Down select wave   Space play / pause preview   R restart preview   M next map   F5 play-test from this wave
  Command line: waveedit [--map <name>]    Test hook: --shot <file.bmp> [wave] }

{$mode objfpc}{$H+}
{$APPTYPE GUI}

uses
  SDL3, SysUtils, Math, StrUtils, Classes, Process, gfx, geometry, gamedata, mapcore, ui;

const
  WIN_W = 1440;
  WIN_H = 900;
  TOP_H = 44;
  LEFT_W = 250;
  RIGHT_W = 430;
  STATUS_H = 24;
  CX0 = LEFT_W;
  CW = WIN_W - LEFT_W - RIGHT_W;
  ROW_H = 26;
  TABLE_Y = TOP_H + 30;
  TABLE_ROWS = 9;
  TL_Y = TABLE_Y + ROW_H * (TABLE_ROWS + 1) + 52;
  TL_H = 200;
  CH_Y = TL_Y + TL_H + 46;
  CH_H = WIN_H - STATUS_H - CH_Y - 34;
  PV_W = 410;
  PV_H = 231;
  MAX_UNDO = 300;

  EnemyColors: array[0..7] of TRGBA = (
    (r: 200; g: 110; b: 70; a: 255), (r: 120; g: 190; b: 80; a: 255), (r: 150; g: 160; b: 190; a: 255),
    (r: 170; g: 100; b: 210; a: 255), (r: 230; g: 70; b: 60; a: 255), (r: 240; g: 200; b: 80; a: 255),
    (r: 80; g: 190; b: 220; a: 255), (r: 220; g: 140; b: 180; a: 255));

  // table columns (x offsets inside the centre area)
  COL_NUM = 10;
  COL_ENEMY = 38;
  COL_COUNT = 222;
  COL_PATH = 296;
  COL_START = 364;
  COL_INT = 442;
  COL_END = 528;
  COL_BTN = 600;

type
  TUndoEntry = record
    Json: string;
    Wave, Group: Integer;
  end;

  TSimSpawn = record
    T, Offset: Single;
    Enemy, Path: Integer;
  end;

  TDrag = (drNone, drScrub, drTimeline);

var
  Window: PSDL_Window;
  Renderer: PSDL_Renderer;
  DataDir, MapName: string;
  MapNames: TStringList;
  Paths: TPathArray;
  MapTex: PSDL_Texture = nil;
  Modified: Boolean = False;

  SelWave: Integer = 0;
  SelGroup: Integer = -1;
  WaveScroll: Integer = 0;
  GroupScroll: Integer = 0;

  EnemyBX0, EnemyBY0, EnemyBX1, EnemyBY1: array of Single;

  UndoStack, RedoStack: array of TUndoEntry;

  Drag: TDrag = drNone;
  DragStartX, ScrubStart, DragStartT: Single;
  ScrubKey: string;
  ScrubMoved, DragUndoPushed: Boolean;
  EditKey: string = '';
  EditBuf: string = '';

  // preview simulation
  Sim: array of TSimSpawn;
  SimT: Single = 0;
  SimPlaying: Boolean = True;
  SimSpeed: Single = 2;
  SimLoop: Boolean = True;
  SimForWave: Integer = -1;
  SimJson: string = '';
  AnimTime: Single = 0;

  StatusMsg: string = '';
  StatusTime: Single = 0;

{ ======================================================================
  helpers & stats
  ====================================================================== }

function WavesFileName: string; forward;
procedure SelectWave(w: Integer); forward;

procedure Status(const s: string);
begin
  StatusMsg := s;
  StatusTime := 6;
end;

function WaveCount: Integer;
begin
  Result := Length(Waves);
end;

function HaveWave: Boolean;
begin
  Result := (SelWave >= 0) and (SelWave < WaveCount);
end;

function HaveGroup: Boolean;
begin
  Result := HaveWave and (SelGroup >= 0) and (SelGroup <= High(Waves[SelWave].Groups));
end;

function HpScale(w: Integer): Single;   // w = 0-based wave index
begin
  Result := 1 + Rules.HpGrowth * w + Rules.HpGrowthQuad * Sqr(w);
end;

function GroupEnd(const g: TWaveGroup): Single;
begin
  Result := g.Start + Max(0, g.Count - 1) * g.Interval;
end;

procedure WaveStats(w: Integer; out cnt, gold, lives, fly: Integer; out hp, ehp, dur: Single);
var
  g: Integer;
  e: TEnemyDef;
  grp: TWaveGroup;
begin
  cnt := 0; gold := 0; lives := 0; fly := 0; hp := 0; ehp := 0; dur := 0;
  if (w < 0) or (w >= WaveCount) then Exit;
  for g := 0 to High(Waves[w].Groups) do
  begin
    grp := Waves[w].Groups[g];
    e := EnemyDefs[grp.Enemy];
    Inc(cnt, grp.Count);
    Inc(gold, grp.Count * e.Gold);
    Inc(lives, grp.Count * e.LivesCost);
    if e.Flying then Inc(fly, grp.Count);
    hp := hp + grp.Count * e.Hp * HpScale(w);
    // effective hp against physical damage: armor makes enemies tougher
    ehp := ehp + grp.Count * e.Hp * HpScale(w) / Max(0.1, 1 - e.Armor);
    dur := Max(dur, GroupEnd(grp));
  end;
end;

function EnemyEhp(w, enemy: Integer): Single;
var
  g: Integer;
  e: TEnemyDef;
begin
  Result := 0;
  for g := 0 to High(Waves[w].Groups) do
    if Waves[w].Groups[g].Enemy = enemy then
    begin
      e := EnemyDefs[enemy];
      Result := Result + Waves[w].Groups[g].Count * e.Hp * HpScale(w) / Max(0.1, 1 - e.Armor);
    end;
end;

function GroupIssue(const g: TWaveGroup): string;
begin
  Result := '';
  if (g.Path < 0) or (g.Path > High(Map.Paths)) then
    Result := Format('path %d does not exist on map "%s"', [g.Path, Map.Name])
  else if g.Count <= 0 then
    Result := 'count is 0'
  else if (g.Count > 1) and (g.Interval <= 0) then
    Result := 'interval must be > 0';
end;

function WaveHasIssue(w: Integer): Boolean;
var
  g: Integer;
begin
  Result := Length(Waves[w].Groups) = 0;
  for g := 0 to High(Waves[w].Groups) do
    if GroupIssue(Waves[w].Groups[g]) <> '' then Exit(True);
end;

function FmtK(v: Single): string;
begin
  if v >= 10000 then Result := Format('%.1fk', [v / 1000])
  else Result := IntToStr(Round(v));
end;

procedure ComputeEnemyBounds;
var
  i, k, g: Integer;
  a, b, c, d: Single;
begin
  SetLength(EnemyBX0, Length(EnemyDefs)); SetLength(EnemyBY0, Length(EnemyDefs));
  SetLength(EnemyBX1, Length(EnemyDefs)); SetLength(EnemyBY1, Length(EnemyDefs));
  for i := 0 to High(EnemyDefs) do
  begin
    EnemyBX0[i] := -10; EnemyBY0[i] := -20; EnemyBX1[i] := 10; EnemyBY1[i] := 0;
    g := EnemyDefs[i].GeoIdx;
    if g < 0 then Continue;
    EnemyBX0[i] := 1e9; EnemyBY0[i] := 1e9; EnemyBX1[i] := -1e9; EnemyBY1[i] := -1e9;
    for k := 0 to High(Geo.Objects[g].Shapes) do
    begin
      if Geo.Objects[g].Shapes[k].Add then Continue;
      ShapeBounds(Geo.Objects[g].Shapes[k], a, b, c, d);
      EnemyBX0[i] := Min(EnemyBX0[i], a); EnemyBY0[i] := Min(EnemyBY0[i], b);
      EnemyBX1[i] := Max(EnemyBX1[i], c); EnemyBY1[i] := Max(EnemyBY1[i], d);
    end;
  end;
end;

// draw an enemy centred in a box of the given size
procedure EnemyIcon(e: Integer; cx, cy, size: Single; walking: Boolean = False);
var
  st: TAnimState;
  sc: Single;
begin
  if (e < 0) or (e > High(EnemyDefs)) then Exit;
  st := DefaultAnimState;
  st.Time := AnimTime;
  st.Walk := AnimTime;
  st.Moving := walking;
  st.Seed := e;
  sc := Min(size / Max(1, EnemyBX1[e] - EnemyBX0[e]), size / Max(1, EnemyBY1[e] - EnemyBY0[e]));
  DrawGeoIdx(Geo, EnemyDefs[e].GeoIdx, cx - (EnemyBX0[e] + EnemyBX1[e]) / 2 * sc,
    cy - (EnemyBY0[e] + EnemyBY1[e]) / 2 * sc, sc, st);
end;

{ ======================================================================
  undo / files
  ====================================================================== }

function Snapshot: TUndoEntry;
begin
  Result.Json := WavesToJSON(Waves);
  Result.Wave := SelWave;
  Result.Group := SelGroup;
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
  w: TWaveArray;
begin
  w := nil;
  if not WavesFromJSONText(e.Json, w, err) then Exit;
  Waves := w;
  SelWave := EnsureRange(e.Wave, 0, WaveCount - 1);
  SelGroup := e.Group;
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
end;

function SaveWaves: Boolean;
begin
  Result := SaveWavesFile(DataDir + WavesFileName, Waves);
  if Result then
  begin
    Modified := False;
    Status('Saved ' + DataDir + WavesFileName);
  end
  else
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Save failed', PAnsiChar('Could not write ' + WavesFileName), Window);
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
  data.message := PAnsiChar(WavesFileName + ' has unsaved changes. Save first?');
  data.numbuttons := 3;
  data.Buttons := @btn[0];
  hit := 2;
  SDL_ShowMessageBox(@data, @hit);
  case hit of
    0: Result := SaveWaves;
    1: Result := True;
  else
    Result := False;
  end;
end;

procedure RenderMapTex;
var
  st: TAnimState;
  i: Integer;
begin
  BuildAllPaths(Map, Paths);
  for i := 0 to High(Map.Decor) do Map.Decor[i].GeoIdx := Geo.Find(Map.Decor[i].Geo);
  if MapTex <> nil then SDL_DestroyTexture(MapTex);
  SDL_SetRenderLogicalPresentation(Renderer, WIN_W, WIN_H, SDL_LOGICAL_PRESENTATION_DISABLED);
  MapTex := SDL_CreateTexture(Renderer, SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_TARGET, Map.Width, Map.Height);
  SDL_SetTextureScaleMode(MapTex, SDL_SCALEMODE_LINEAR);
  SDL_SetRenderTarget(Renderer, MapTex);
  SDL_SetRenderDrawColor(Renderer, 0, 0, 0, 255);
  SDL_RenderClear(Renderer);
  DrawMapBase(Map, Paths);
  st := DefaultAnimState;
  for i := 0 to High(Map.Decor) do
    DrawGeoIdx(Geo, Map.Decor[i].GeoIdx, Map.Decor[i].X, Map.Decor[i].Y, Map.Decor[i].S, st, dmStatic);
  if Map.Fortress then DrawFortress(Map.Width, Map.Height);
  SDL_SetRenderTarget(Renderer, nil);
  SDL_SetRenderLogicalPresentation(Renderer, WIN_W, WIN_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
end;

function WavesFileName: string;
begin
  Result := Map.WavesFile;
  if Result = '' then Result := 'waves.json';
end;

// load the waves file the current map uses; False if it does not exist yet (current waves are kept)
function LoadWavesForMap: Boolean;
var
  sl: TStringList;
  w: TWaveArray;
  err: string;
begin
  Result := FileExists(DataDir + WavesFileName);
  SetLength(UndoStack, 0);
  SetLength(RedoStack, 0);
  if not Result then
  begin
    Modified := True;
    Exit;
  end;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(DataDir + WavesFileName);
    w := nil;
    if WavesFromJSONText(sl.Text, w, err) then Waves := w
    else Status('Waves file error: ' + err);
  finally
    sl.Free;
  end;
  Modified := False;
  SelectWave(0);
end;

procedure LoadMapByName(const name: string);
var
  err: string;
  m: TMapDef;
begin
  m := Default(TMapDef);
  if not LoadMapFile(DataDir + 'maps' + PathDelim + name + '.json', m, err) then
  begin
    Status('Cannot load map: ' + err);
    Exit;
  end;
  if not ConfirmDiscard then Exit;
  Map := m;
  MapName := name;
  if Map.WavesFile = '' then Map.WavesFile := 'waves.json';
  RenderMapTex;
  SimForWave := -1;
  if LoadWavesForMap then
    Status(Format('Map "%s": %d roads, waves from %s', [Map.Name, Length(Map.Paths), WavesFileName]))
  else
    Status(Format('Map "%s": %s does not exist yet - editing a copy, Save creates it', [Map.Name, WavesFileName]));
end;

procedure NextMap;
var
  i: Integer;
begin
  if MapNames.Count = 0 then Exit;
  i := MapNames.IndexOf(MapName);
  LoadMapByName(MapNames[(i + 1) mod MapNames.Count]);
end;

procedure ScanMaps;
var
  sr: TSearchRec;
begin
  MapNames.Clear;
  if FindFirst(DataDir + 'maps' + PathDelim + '*.json', faAnyFile, sr) = 0 then
  begin
    repeat
      MapNames.Add(ChangeFileExt(sr.Name, ''));
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  MapNames.Sort;
end;

procedure PlayTest;
var
  pr: TProcess;
  exe: string;
begin
  if Modified and not SaveWaves then Exit;
  exe := ExtractFilePath(ParamStr(0)) + 'towerdefense.exe';
  if not FileExists(exe) then
  begin
    Status('towerdefense.exe not found next to WaveEdit');
    Exit;
  end;
  pr := TProcess.Create(nil);
  try
    pr.Executable := exe;
    pr.Parameters.Add('--map');
    pr.Parameters.Add(MapName);
    pr.Parameters.Add('--wave');
    pr.Parameters.Add(IntToStr(SelWave + 1));
    pr.CurrentDirectory := ExtractFilePath(exe);
    pr.Execute;
    Status(Format('Started the game on "%s" at wave %d', [MapName, SelWave + 1]));
  except
    on e: Exception do Status('Could not start the game: ' + e.Message);
  end;
  pr.Free;
end;

{ ======================================================================
  editing
  ====================================================================== }

procedure SelectWave(w: Integer);
begin
  if WaveCount = 0 then Exit;
  SelWave := EnsureRange(w, 0, WaveCount - 1);
  SelGroup := -1;
  GroupScroll := 0;
  EditKey := '';
  if SelWave < WaveScroll then WaveScroll := SelWave;
end;

procedure AddWave;
var
  n: Integer;
begin
  PushUndo;
  n := WaveCount;
  SetLength(Waves, n + 1);
  SetLength(Waves[n].Groups, 1);
  Waves[n].Groups[0].Enemy := 0;
  Waves[n].Groups[0].Count := 6;
  Waves[n].Groups[0].Path := 0;
  Waves[n].Groups[0].Start := 0;
  Waves[n].Groups[0].Interval := 1.2;
  SelectWave(n);
  Status(Format('Added wave %d', [n + 1]));
end;

procedure DuplicateWave;
var
  i, n: Integer;
begin
  if not HaveWave then Exit;
  PushUndo;
  n := WaveCount;
  SetLength(Waves, n + 1);
  for i := n downto SelWave + 2 do Waves[i] := Waves[i - 1];
  Waves[SelWave + 1].Groups := Copy(Waves[SelWave].Groups);
  SelectWave(SelWave + 1);
  Status('Wave duplicated');
end;

procedure DeleteWave;
var
  i: Integer;
begin
  if not HaveWave then Exit;
  if WaveCount <= 1 then
  begin
    Status('The game needs at least one wave');
    Exit;
  end;
  PushUndo;
  for i := SelWave to WaveCount - 2 do Waves[i] := Waves[i + 1];
  SetLength(Waves, WaveCount - 1);
  SelectWave(Min(SelWave, WaveCount - 1));
end;

procedure MoveWave(d: Integer);
var
  j: Integer;
  t: TWaveDef;
begin
  j := SelWave + d;
  if not HaveWave or (j < 0) or (j >= WaveCount) then Exit;
  PushUndo;
  t := Waves[SelWave];
  Waves[SelWave] := Waves[j];
  Waves[j] := t;
  SelWave := j;
end;

procedure AddGroup;
var
  n: Integer;
  cnt, gold, lives, fly: Integer;
  hp, ehp, dur: Single;
begin
  if not HaveWave then Exit;
  PushUndo;
  WaveStats(SelWave, cnt, gold, lives, fly, hp, ehp, dur);
  n := Length(Waves[SelWave].Groups);
  SetLength(Waves[SelWave].Groups, n + 1);
  Waves[SelWave].Groups[n].Enemy := 0;
  Waves[SelWave].Groups[n].Count := 5;
  Waves[SelWave].Groups[n].Path := 0;
  if n = 0 then Waves[SelWave].Groups[n].Start := 0
  else Waves[SelWave].Groups[n].Start := Round(dur + 2);
  Waves[SelWave].Groups[n].Interval := 1.2;
  SelGroup := n;
  if SelGroup >= GroupScroll + TABLE_ROWS then GroupScroll := SelGroup - TABLE_ROWS + 1;
end;

procedure DuplicateGroup(g: Integer);
var
  n, i: Integer;
begin
  if not HaveWave or (g < 0) or (g > High(Waves[SelWave].Groups)) then Exit;
  PushUndo;
  n := Length(Waves[SelWave].Groups);
  SetLength(Waves[SelWave].Groups, n + 1);
  for i := n downto g + 2 do Waves[SelWave].Groups[i] := Waves[SelWave].Groups[i - 1];
  Waves[SelWave].Groups[g + 1] := Waves[SelWave].Groups[g];
  SelGroup := g + 1;
end;

procedure DeleteGroup(g: Integer);
var
  i: Integer;
begin
  if not HaveWave or (g < 0) or (g > High(Waves[SelWave].Groups)) then Exit;
  PushUndo;
  for i := g to High(Waves[SelWave].Groups) - 1 do
    Waves[SelWave].Groups[i] := Waves[SelWave].Groups[i + 1];
  SetLength(Waves[SelWave].Groups, Length(Waves[SelWave].Groups) - 1);
  SelGroup := Min(g, High(Waves[SelWave].Groups));
end;

// cell keys look like "3.count": group index + field
function ParseKey(const key: string; out g: Integer; out field: string): Boolean;
var
  p: Integer;
begin
  p := Pos('.', key);
  Result := (p > 1) and TryStrToInt(Copy(key, 1, p - 1), g) and HaveWave and
    (g >= 0) and (g <= High(Waves[SelWave].Groups));
  field := Copy(key, p + 1, 20);
end;

function GetNum(const key: string): Single;
var
  g: Integer;
  f: string;
begin
  Result := 0;
  if not ParseKey(key, g, f) then Exit;
  case f of
    'count': Result := Waves[SelWave].Groups[g].Count;
    'path': Result := Waves[SelWave].Groups[g].Path;
    'start': Result := Waves[SelWave].Groups[g].Start;
    'interval': Result := Waves[SelWave].Groups[g].Interval;
  end;
end;

procedure SetNum(const key: string; v: Single);
var
  g: Integer;
  f: string;
begin
  if not ParseKey(key, g, f) then Exit;
  case f of
    'count': Waves[SelWave].Groups[g].Count := EnsureRange(Round(v), 0, 999);
    'path': Waves[SelWave].Groups[g].Path := EnsureRange(Round(v), 0, 9);
    'start': Waves[SelWave].Groups[g].Start := Max(0, Round(v * 10) / 10);
    'interval': Waves[SelWave].Groups[g].Interval := Max(0, Round(v * 100) / 100);
  end;
  Modified := True;
end;

function NumStep(const key: string): Single;
begin
  if (Pos('.start', key) > 0) then Result := 0.5
  else if (Pos('.interval', key) > 0) then Result := 0.1
  else Result := 1;
  if ModShift then Result := Result / 5
  else if ModCtrl then Result := Result * 10;
  if (Pos('.count', key) > 0) or (Pos('.path', key) > 0) then Result := Max(1, Round(Result));
end;

procedure CycleEnemy(g, d: Integer);
begin
  if not HaveWave or (g < 0) or (g > High(Waves[SelWave].Groups)) then Exit;
  PushUndo;
  Waves[SelWave].Groups[g].Enemy :=
    (Waves[SelWave].Groups[g].Enemy + d + Length(EnemyDefs)) mod Length(EnemyDefs);
end;

procedure BeginEdit(const key: string);
begin
  EditKey := key;
  EditBuf := FmtNum(GetNum(key));
  SDL_StartTextInput(Window);
end;

procedure EndEdit(commit: Boolean);
var
  k: string;
  v: Single;
  fs: TFormatSettings;
begin
  if EditKey = '' then Exit;
  k := EditKey;
  EditKey := '';
  SDL_StopTextInput(Window);
  if not commit then Exit;
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  if TryStrToFloat(StringReplace(Trim(EditBuf), ',', '.', []), v, fs) then
  begin
    PushUndo;
    SetNum(k, v);
  end
  else
    Status('Not a number: ' + EditBuf);
end;

{ ======================================================================
  preview simulation
  ====================================================================== }

procedure BuildSim;
var
  g, i, n: Integer;
  grp: TWaveGroup;
begin
  SetLength(Sim, 0);
  if not HaveWave then Exit;
  RandSeed := 1234 + SelWave;
  n := 0;
  for g := 0 to High(Waves[SelWave].Groups) do
  begin
    grp := Waves[SelWave].Groups[g];
    if (grp.Path < 0) or (grp.Path > High(Paths)) then Continue;
    for i := 0 to grp.Count - 1 do
    begin
      SetLength(Sim, n + 1);
      Sim[n].T := grp.Start + i * grp.Interval;
      Sim[n].Enemy := grp.Enemy;
      Sim[n].Path := grp.Path;
      if EnemyDefs[grp.Enemy].Flying then Sim[n].Offset := (Random - 0.5) * 40
      else Sim[n].Offset := (Random - 0.5) * 26;
      Inc(n);
    end;
  end;
  SimForWave := SelWave;
  SimJson := WavesToJSON(Waves);
end;

function SimLastExit: Single;
var
  i: Integer;
  t: Single;
begin
  Result := 0;
  for i := 0 to High(Sim) do
  begin
    t := Sim[i].T + (Paths[Sim[i].Path].Len + 30) / Max(1, EnemyDefs[Sim[i].Enemy].Speed);
    Result := Max(Result, t);
  end;
end;

procedure UpdateSim(dt: Single);
var
  j: string;
begin
  // rebuild when the selected wave or its data changed
  if SimForWave <> SelWave then
  begin
    BuildSim;
    SimT := 0;
  end
  else
  begin
    j := WavesToJSON(Waves);
    if j <> SimJson then BuildSim;
  end;
  if not SimPlaying then Exit;
  SimT := SimT + dt * SimSpeed;
  if SimT > SimLastExit + 1 then
    if SimLoop then SimT := 0 else SimPlaying := False;
end;

{ ======================================================================
  drawing: left (wave list)
  ====================================================================== }

procedure DrawWaveList;
var
  i, n, visible, cnt, gold, lives, fly: Integer;
  y, maxE, bw: Single;
  hp, ehp, dur: Single;
begin
  FillRect(0, TOP_H, LEFT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
  FillRect(LEFT_W - 1, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  DrawText(10, TOP_H + 6, Format('WAVES (%d)', [WaveCount]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  maxE := 1;
  for i := 0 to WaveCount - 1 do
  begin
    WaveStats(i, cnt, gold, lives, fly, hp, ehp, dur);
    maxE := Max(maxE, ehp);
  end;
  visible := (WIN_H - STATUS_H - TOP_H - 30 - 104) div 40;
  if Inside(0, TOP_H + 28, LEFT_W, visible * 40) and (WheelY <> 0) then
  begin
    WaveScroll := WaveScroll - Round(WheelY);
    WheelY := 0;
  end;
  if SelWave >= WaveScroll + visible then WaveScroll := SelWave - visible + 1;
  WaveScroll := EnsureRange(WaveScroll, 0, Max(0, WaveCount - visible));
  n := 0;
  for i := WaveScroll to WaveCount - 1 do
  begin
    if n >= visible then Break;
    y := TOP_H + 28 + n * 40;
    Inc(n);
    WaveStats(i, cnt, gold, lives, fly, hp, ehp, dur);
    if i = SelWave then RoundRect(6, y, LEFT_W - 13, 37, 4, C_SEL)
    else if Inside(6, y, LEFT_W - 13, 37) then RoundRect(6, y, LEFT_W - 13, 37, 4, C_PANEL2);
    DrawText(14, y + 2, Format('Wave %d', [i + 1]), C_TEXT, fnSmall, ALIGN_LEFT, False);
    DrawText(LEFT_W - 14, y + 2, Format('%d enemies  %ds', [cnt, Round(dur)]), C_DIM, fnSmall, ALIGN_RIGHT, False);
    bw := (LEFT_W - 40) * ehp / maxE;
    FillRect(14, y + 24, LEFT_W - 40, 5, RGBA(25, 27, 32));
    FillRect(14, y + 24, bw, 5, Mix(RGBA(120, 200, 90), RGBA(230, 70, 50), ehp / maxE));
    if WaveHasIssue(i) then FillCircle(LEFT_W - 18, y + 26, 4, RGBA(255, 80, 70));
    if Inside(6, y, LEFT_W - 13, 37) and LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      SelectWave(i);
    end;
  end;
  y := WIN_H - STATUS_H - 98;
  if Button(8, y, 74, 26, 'Add') then AddWave;
  if Button(86, y, 80, 26, 'Duplicate', False, HaveWave) then DuplicateWave;
  if Button(170, y, 72, 26, 'Delete', False, WaveCount > 1) then DeleteWave;
  if Button(8, y + 30, 116, 26, 'Move up', False, SelWave > 0) then MoveWave(-1);
  if Button(128, y + 30, 114, 26, 'Move down', False, SelWave < WaveCount - 1) then MoveWave(1);
  DrawText(10, y + 64, 'Bar = effective HP (armor counted)', C_DIM, fnSmall, ALIGN_LEFT, False);
end;

{ ======================================================================
  drawing: centre (table, timeline, chart)
  ====================================================================== }

procedure NumCell(x, y, w: Single; const key: string; bad: Boolean);
var
  hover: Boolean;
  txt: string;
  c: TRGBA;
begin
  hover := Inside(x, y + 1, w, ROW_H - 3);
  if EditKey = key then
  begin
    FillRect(x, y + 1, w, ROW_H - 3, RGBA(20, 22, 26));
    FillRect(x, y + ROW_H - 3, w, 1, C_ACCENT);
    txt := EditBuf;
    if Frac(SDL_GetTicks / 1000) < 0.5 then txt := txt + '|';
    DrawText(x + 6, y + 4, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
    Exit;
  end;
  if hover then FillRect(x, y + 1, w, ROW_H - 3, RGBA(62, 66, 78))
  else FillRect(x, y + 1, w, ROW_H - 3, RGBA(34, 36, 42));
  if bad then c := RGBA(255, 110, 100) else c := C_TEXT;
  DrawText(x + 6, y + 4, FmtNum(GetNum(key)), c, fnSmall, ALIGN_LEFT, False);
  if hover and (WheelY <> 0) and (Drag = drNone) then
  begin
    PushUndo;
    SetNum(key, GetNum(key) + WheelY * NumStep(key));
    WheelY := 0;
  end;
  if hover and LDown and not Consumed then
  begin
    Consumed := True;
    EndEdit(True);
    Drag := drScrub;
    ScrubKey := key;
    ScrubStart := GetNum(key);
    DragStartX := MX;
    ScrubMoved := False;
    DragUndoPushed := False;
  end;
end;

procedure DrawTable;
var
  i, n, rowsShown: Integer;
  y, x0: Single;
  g: TWaveGroup;
  issue, k: string;
  hover: Boolean;
begin
  x0 := CX0;
  FillRect(x0, TOP_H, CW, TL_Y - TOP_H - 30, C_BG);
  if not HaveWave then Exit;
  DrawText(x0 + 10, TOP_H + 6, Format('WAVE %d - SPAWN GROUPS', [SelWave + 1]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := TABLE_Y;
  DrawText(x0 + COL_ENEMY, y + 4, 'enemy', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(x0 + COL_COUNT, y + 4, 'count', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(x0 + COL_PATH, y + 4, 'road', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(x0 + COL_START, y + 4, 'start (s)', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(x0 + COL_INT, y + 4, 'every (s)', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(x0 + COL_END, y + 4, 'last', C_DIM, fnSmall, ALIGN_LEFT, False);
  FillRect(x0 + 6, y + ROW_H - 2, CW - 12, 1, C_LINE);
  rowsShown := TABLE_ROWS;
  if Inside(x0, TABLE_Y + ROW_H, CW, rowsShown * ROW_H) and (WheelY <> 0) and
    not Inside(x0 + COL_COUNT, TABLE_Y + ROW_H, COL_END - COL_COUNT, rowsShown * ROW_H) then
  begin
    GroupScroll := GroupScroll - Round(WheelY);
    WheelY := 0;
  end;
  GroupScroll := EnsureRange(GroupScroll, 0, Max(0, Length(Waves[SelWave].Groups) - rowsShown));
  n := 0;
  for i := GroupScroll to High(Waves[SelWave].Groups) do
  begin
    if n >= rowsShown then Break;
    y := TABLE_Y + ROW_H * (n + 1);
    Inc(n);
    g := Waves[SelWave].Groups[i];
    issue := GroupIssue(g);
    if i = SelGroup then FillRect(x0 + 4, y, CW - 8, ROW_H, RGBA(52, 66, 92));
    DrawText(x0 + COL_NUM, y + 4, IntToStr(i), C_DIM, fnSmall, ALIGN_LEFT, False);
    // enemy cell
    hover := Inside(x0 + COL_ENEMY, y + 1, COL_COUNT - COL_ENEMY - 8, ROW_H - 3);
    if hover then FillRect(x0 + COL_ENEMY, y + 1, COL_COUNT - COL_ENEMY - 8, ROW_H - 3, RGBA(62, 66, 78))
    else FillRect(x0 + COL_ENEMY, y + 1, COL_COUNT - COL_ENEMY - 8, ROW_H - 3, RGBA(34, 36, 42));
    FillRect(x0 + COL_ENEMY, y + 1, 4, ROW_H - 3, EnemyColors[g.Enemy mod Length(EnemyColors)]);
    EnemyIcon(g.Enemy, x0 + COL_ENEMY + 18, y + ROW_H / 2, 20);
    DrawText(x0 + COL_ENEMY + 34, y + 4, '< ' + EnemyDefs[g.Enemy].Name + ' >', RGBA(160, 210, 255), fnSmall,
      ALIGN_LEFT, False);
    if hover and (LDown or RDown) and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      SelGroup := i;
      if LDown then CycleEnemy(i, 1) else CycleEnemy(i, -1);
    end;
    k := IntToStr(i);
    NumCell(x0 + COL_COUNT, y, 66, k + '.count', g.Count <= 0);
    NumCell(x0 + COL_PATH, y, 60, k + '.path', (g.Path < 0) or (g.Path > High(Map.Paths)));
    NumCell(x0 + COL_START, y, 70, k + '.start', False);
    NumCell(x0 + COL_INT, y, 78, k + '.interval', (g.Count > 1) and (g.Interval <= 0));
    DrawText(x0 + COL_END + 4, y + 4, FmtNum(Round(GroupEnd(g) * 10) / 10) + 's', C_DIM, fnSmall, ALIGN_LEFT, False);
    if Button(x0 + COL_BTN, y + 2, 72, ROW_H - 4, 'duplicate') then DuplicateGroup(i);
    if Button(x0 + COL_BTN + 76, y + 2, 60, ROW_H - 4, 'delete') then DeleteGroup(i);
    if issue <> '' then
    begin
      FillCircle(x0 + COL_NUM + 18, y + ROW_H / 2, 4, RGBA(255, 80, 70));
      if Inside(x0 + 4, y, CW - 8, ROW_H) then Status('Group ' + IntToStr(i) + ': ' + issue);
    end;
    if Inside(x0 + 4, y, COL_ENEMY - 6, ROW_H) and LDown and not Consumed then
    begin
      Consumed := True;
      SelGroup := i;
    end;
  end;
  if Length(Waves[SelWave].Groups) = 0 then
    DrawText(x0 + COL_ENEMY, TABLE_Y + ROW_H + 4, 'This wave is empty - add a group.', RGBA(255, 120, 100), fnSmall,
      ALIGN_LEFT, False);
  y := TABLE_Y + ROW_H * (TABLE_ROWS + 1) + 6;
  if Button(x0 + 10, y, 110, 26, '+ Add group') then AddGroup;
  if Length(Waves[SelWave].Groups) > TABLE_ROWS then
    DrawText(x0 + 130, y + 5, Format('%d groups - wheel over the table to scroll', [Length(Waves[SelWave].Groups)]),
      C_DIM, fnSmall, ALIGN_LEFT, False);
end;

function TimelineScale(out maxT: Single): Single;
var
  cnt, gold, lives, fly: Integer;
  hp, ehp, dur: Single;
begin
  WaveStats(SelWave, cnt, gold, lives, fly, hp, ehp, dur);
  maxT := Max(10, Ceil((dur + 3) / 5) * 5);
  Result := (CW - 90) / maxT;
end;

procedure DrawTimeline;
var
  x0, y0, sc, maxT, lx, ly, laneH, t, px: Single;
  lanes, l, g, i, hoverG: Integer;
  grp: TWaveGroup;
  c: TRGBA;
  tt: Integer;
begin
  if not HaveWave then Exit;
  x0 := CX0 + 70;
  y0 := TL_Y;
  DrawText(CX0 + 10, TL_Y - 24, 'TIMELINE - one lane per road (drag spawns to move a group)', C_ACCENT, fnSmall,
    ALIGN_LEFT, False);
  sc := TimelineScale(maxT);
  lanes := Max(1, Length(Map.Paths));
  for g := 0 to High(Waves[SelWave].Groups) do lanes := Max(lanes, Waves[SelWave].Groups[g].Path + 1);
  laneH := (TL_H - 22) / lanes;
  FillRect(CX0 + 6, y0, CW - 12, TL_H, RGBA(24, 26, 31));
  for l := 0 to lanes - 1 do
  begin
    ly := y0 + l * laneH;
    if l mod 2 = 1 then FillRect(x0, ly, CW - 82, laneH, RGBA(30, 32, 38));
    if l <= High(Map.Paths) then c := C_DIM else c := RGBA(255, 100, 90);
    DrawText(CX0 + 12, ly + laneH / 2 - 8, 'road ' + IntToStr(l), c, fnSmall, ALIGN_LEFT, False);
  end;
  // time grid
  tt := 0;
  while tt <= maxT do
  begin
    lx := x0 + tt * sc;
    FillRect(lx, y0, 1, TL_H - 20, RGBA(255, 255, 255, IfThen(tt mod 10 = 0, 40, 16)));
    if tt mod 5 = 0 then
      DrawText(lx, y0 + TL_H - 18, IntToStr(tt) + 's', C_DIM, fnSmall, ALIGN_CENTER, False);
    Inc(tt, 1);
  end;
  // spawns
  hoverG := -1;
  for g := 0 to High(Waves[SelWave].Groups) do
  begin
    grp := Waves[SelWave].Groups[g];
    ly := y0 + grp.Path * laneH + laneH / 2;
    c := EnemyColors[grp.Enemy mod Length(EnemyColors)];
    // group bar
    lx := x0 + grp.Start * sc;
    px := x0 + GroupEnd(grp) * sc;
    if g = SelGroup then
      RoundRect(lx - 12, ly - laneH / 2 + 3, px - lx + 24, laneH - 6, 6, RGBA(70, 110, 170, 150))
    else
      RoundRect(lx - 10, ly - 3, px - lx + 20, 6, 3, WithAlpha(c, 90));
    for i := 0 to grp.Count - 1 do
    begin
      t := grp.Start + i * grp.Interval;
      EnemyIcon(grp.Enemy, x0 + t * sc, ly, Min(22, laneH - 8));
    end;
    if Inside(lx - 12, ly - laneH / 2 + 3, px - lx + 24, laneH - 6) then hoverG := g;
  end;
  // playhead
  if (SimForWave = SelWave) and (SimT > 0) then
  begin
    lx := x0 + SimT * sc;
    if lx < CX0 + CW - 10 then
    begin
      FillRect(lx, y0, 2, TL_H - 20, RGBA(255, 230, 120, 200));
      FillTri(lx - 5, y0, lx + 7, y0, lx + 1, y0 + 7, RGBA(255, 230, 120));
    end;
  end;
  if hoverG >= 0 then
  begin
    grp := Waves[SelWave].Groups[hoverG];
    DrawText(MX + 12, MY - 22, Format('%d x %s on road %d, %s-%ss', [grp.Count, EnemyDefs[grp.Enemy].Name,
      grp.Path, FmtNum(grp.Start), FmtNum(Round(GroupEnd(grp) * 10) / 10)]), RGBA(255, 255, 255), fnSmall,
      ALIGN_LEFT, True);
    if LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      SelGroup := hoverG;
      Drag := drTimeline;
      DragStartX := MX;
      DragStartT := grp.Start;
      DragUndoPushed := False;
    end;
  end;
end;

procedure DrawChart;
var
  x0, y0, bw, h, maxE, maxG, yy, gx, gy, pgx, pgy: Single;
  w, e, cnt, gold, lives, fly, hoverW: Integer;
  hp, ehp, dur, part: Single;
  c: TRGBA;
begin
  x0 := CX0 + 50;
  y0 := CH_Y;
  DrawText(CX0 + 10, CH_Y - 24, 'DIFFICULTY - effective HP per wave by enemy (bars), gold reward (line)', C_ACCENT,
    fnSmall, ALIGN_LEFT, False);
  FillRect(CX0 + 6, y0, CW - 12, CH_H, RGBA(24, 26, 31));
  if WaveCount = 0 then Exit;
  maxE := 1;
  maxG := 1;
  for w := 0 to WaveCount - 1 do
  begin
    WaveStats(w, cnt, gold, lives, fly, hp, ehp, dur);
    maxE := Max(maxE, ehp);
    maxG := Max(maxG, gold);
  end;
  bw := (CW - 70) / WaveCount;
  hoverW := -1;
  pgx := 0; pgy := 0;
  for w := 0 to WaveCount - 1 do
  begin
    gx := x0 + w * bw;
    if w = SelWave then FillRect(gx, y0 + 2, bw, CH_H - 22, RGBA(60, 80, 120, 120));
    if Inside(gx, y0, bw, CH_H) then hoverW := w;
    // stacked bar by enemy type
    yy := y0 + CH_H - 20;
    for e := 0 to High(EnemyDefs) do
    begin
      part := EnemyEhp(w, e);
      if part <= 0 then Continue;
      h := part / maxE * (CH_H - 30);
      c := EnemyColors[e mod Length(EnemyColors)];
      FillRect(gx + bw * 0.18, yy - h, bw * 0.64, h, c);
      yy := yy - h;
    end;
    if w = SelWave then c := C_TEXT else c := C_DIM;
    DrawText(gx + bw / 2, y0 + CH_H - 18, IntToStr(w + 1), c, fnSmall, ALIGN_CENTER, False);
  end;
  // gold line
  for w := 0 to WaveCount - 1 do
  begin
    WaveStats(w, cnt, gold, lives, fly, hp, ehp, dur);
    gx := x0 + w * bw + bw / 2;
    gy := y0 + CH_H - 20 - gold / maxG * (CH_H - 30);
    if w > 0 then ThickLine(pgx, pgy, gx, gy, 2, RGBA(255, 215, 60, 220));
    FillCircle(gx, gy, 3.5, RGBA(255, 215, 60));
    pgx := gx;
    pgy := gy;
  end;
  // legend
  gx := CX0 + 14;
  for e := 0 to High(EnemyDefs) do
  begin
    FillRect(gx, y0 + CH_H + 8, 10, 10, EnemyColors[e mod Length(EnemyColors)]);
    DrawText(gx + 14, y0 + CH_H + 5, EnemyDefs[e].Name, C_DIM, fnSmall, ALIGN_LEFT, False);
    gx := gx + 28 + TextWidth(EnemyDefs[e].Name);
  end;
  if hoverW >= 0 then
  begin
    WaveStats(hoverW, cnt, gold, lives, fly, hp, ehp, dur);
    DrawText(MX + 12, MY - 22, Format('wave %d: %d enemies, eff. HP %s, gold %d', [hoverW + 1, cnt, FmtK(ehp), gold]),
      RGBA(255, 255, 255), fnSmall, ALIGN_LEFT, True);
    if LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      SelectWave(hoverW);
    end;
  end;
end;

{ ======================================================================
  drawing: right (preview + stats + enemy reference)
  ====================================================================== }

procedure DrawPreview;
var
  x0, y0, sc, px, py, dx, dy, d, x, y: Single;
  i, alive, leaked, spawned: Integer;
  dst: TSDL_FRect;
  st: TAnimState;
  e: TEnemyDef;
begin
  x0 := WIN_W - RIGHT_W + 10;
  y0 := TOP_H + 28;
  DrawText(x0, TOP_H + 6, Format('PREVIEW - wave %d on "%s"', [SelWave + 1, Map.Name]), C_ACCENT, fnSmall,
    ALIGN_LEFT, False);
  sc := PV_W / Map.Width;
  dst.x := x0; dst.y := y0; dst.w := PV_W; dst.h := Map.Height * sc;
  if MapTex <> nil then SDL_RenderTexture(Renderer, MapTex, nil, @dst);
  SetClip(Round(x0), Round(y0), PV_W, Round(dst.h));
  alive := 0; leaked := 0; spawned := 0;
  st := DefaultAnimState;
  st.Time := SimT;
  st.Moving := True;
  for i := 0 to High(Sim) do
  begin
    if SimT < Sim[i].T then Continue;
    Inc(spawned);
    e := EnemyDefs[Sim[i].Enemy];
    d := (SimT - Sim[i].T) * e.Speed - 20;
    if d > Paths[Sim[i].Path].Len then
    begin
      Inc(leaked, e.LivesCost);
      Continue;
    end;
    Inc(alive);
    PathPos(Paths[Sim[i].Path], d, px, py, dx, dy);
    x := px - dy * Sim[i].Offset;
    y := py + dx * Sim[i].Offset;
    st.Walk := SimT + i;
    st.Seed := i;
    if dx < 0 then st.Facing := -1 else st.Facing := 1;
    DrawGeoIdx(Geo, e.GeoIdx, x0 + x * sc, y0 + y * sc, 0.55, st);
  end;
  NoClip;
  y := y0 + dst.h + 6;
  if Button(x0, y, 64, 24, IfThen(SimPlaying, 'Pause', 'Play'), SimPlaying) then SimPlaying := not SimPlaying;
  if Button(x0 + 68, y, 64, 24, 'Restart') then
  begin
    SimT := 0;
    SimPlaying := True;
  end;
  if Button(x0 + 136, y, 36, 24, '1x', SimSpeed = 1) then SimSpeed := 1;
  if Button(x0 + 176, y, 36, 24, '2x', SimSpeed = 2) then SimSpeed := 2;
  if Button(x0 + 216, y, 36, 24, '4x', SimSpeed = 4) then SimSpeed := 4;
  if Button(x0 + 256, y, 52, 24, 'Loop', SimLoop) then SimLoop := not SimLoop;
  DrawText(x0 + PV_W, y + 4, Format('t = %.1fs', [SimT]), C_TEXT, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0, y + 30, Format('on road %d   spawned %d/%d   undefended: -%d lives',
    [alive, spawned, Length(Sim), leaked]), C_DIM, fnSmall, ALIGN_LEFT, False);
end;

procedure DrawStats;
var
  x0, y: Single;
  cnt, gold, lives, fly, e, w, total: Integer;
  hp, ehp, dur: Single;
begin
  x0 := WIN_W - RIGHT_W + 10;
  y := TOP_H + 28 + PV_H + 66;
  FillRect(x0 - 10, y - 6, RIGHT_W, 1, C_LINE);
  if not HaveWave then Exit;
  WaveStats(SelWave, cnt, gold, lives, fly, hp, ehp, dur);
  DrawText(x0, y, Format('WAVE %d STATS', [SelWave + 1]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  DrawText(x0, y + 20, Format('enemies %d  (flying %d)     spawn time %ss', [cnt, fly, FmtNum(Round(dur * 10) / 10)]),
    C_TEXT, fnSmall, ALIGN_LEFT, False);
  DrawText(x0, y + 38, Format('total HP %s     effective HP %s     HP x%s', [FmtK(hp), FmtK(ehp),
    FmtNum(Round(HpScale(SelWave) * 100) / 100)]), C_TEXT, fnSmall, ALIGN_LEFT, False);
  total := Rules.StartGold;
  for w := 0 to SelWave - 1 do
  begin
    WaveStats(w, cnt, e, lives, fly, hp, ehp, dur);
    Inc(total, e);
  end;
  WaveStats(SelWave, cnt, gold, lives, fly, hp, ehp, dur);
  DrawText(x0, y + 56, Format('gold reward %d     lives at risk %d', [gold, lives]), C_TEXT, fnSmall, ALIGN_LEFT, False);
  DrawText(x0, y + 74, Format('gold available before this wave ~%d (start + kills)', [total]), C_DIM, fnSmall,
    ALIGN_LEFT, False);

  y := y + 104;
  FillRect(x0 - 10, y - 6, RIGHT_W, 1, C_LINE);
  DrawText(x0, y, Format('ENEMIES (enemies.json) - HP at wave %d', [SelWave + 1]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y + 22;
  DrawText(x0 + 186, y, 'hp', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 232, y, 'speed', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 282, y, 'armor', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 326, y, 'gold', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 370, y, 'lives', C_DIM, fnSmall, ALIGN_RIGHT, False);
  y := y + 18;
  for e := 0 to High(EnemyDefs) do
  begin
    if y > WIN_H - STATUS_H - 30 then Break;
    FillRect(x0, y + 2, 4, 30, EnemyColors[e mod Length(EnemyColors)]);
    EnemyIcon(e, x0 + 24, y + 17, 28, True);
    DrawText(x0 + 44, y + 2, EnemyDefs[e].Name, C_TEXT, fnSmall, ALIGN_LEFT, False);
    if EnemyDefs[e].Flying then DrawText(x0 + 44, y + 18, 'flying', RGBA(170, 140, 230), fnSmall, ALIGN_LEFT, False);
    DrawText(x0 + 186, y + 10, IntToStr(Round(EnemyDefs[e].Hp * HpScale(SelWave))), C_TEXT, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 232, y + 10, FmtNum(EnemyDefs[e].Speed), C_TEXT, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 282, y + 10, IntToStr(Round(EnemyDefs[e].Armor * 100)) + '%', C_TEXT, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 326, y + 10, IntToStr(EnemyDefs[e].Gold), RGBA(255, 215, 60), fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 370, y + 10, IntToStr(EnemyDefs[e].LivesCost), RGBA(255, 120, 120), fnSmall, ALIGN_RIGHT, False);
    y := y + 36;
  end;
end;

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

var
  err: string;
  w: TWaveArray;
begin
  FillRect(0, 0, WIN_W, TOP_H, C_PANEL);
  FillRect(0, TOP_H - 1, WIN_W, 1, C_LINE);
  x := 8;
  if TB(60, 'Save') then SaveWaves;
  if TB(70, 'Reload') and ConfirmDiscard then
  begin
    w := nil;
    with TStringList.Create do
    try
      LoadFromFile(DataDir + WavesFileName);
      if WavesFromJSONText(Text, w, err) then
      begin
        Waves := w;
        Modified := False;
        SelectWave(Min(SelWave, WaveCount - 1));
        Status('Reloaded ' + WavesFileName);
      end
      else Status('Reload failed: ' + err);
    finally
      Free;
    end;
  end;
  Gap;
  if TB(54, 'Undo', False, Length(UndoStack) > 0) then DoUndo;
  if TB(54, 'Redo', False, Length(RedoStack) > 0) then DoRedo;
  Gap;
  if TB(220, 'Map: ' + MapName + '  (M = next)') then NextMap;
  Gap;
  if TB(190, Format('Play test wave %d (F5)', [SelWave + 1]), False, HaveWave) then PlayTest;
end;

{ ======================================================================
  input
  ====================================================================== }

procedure UpdateDrags;
var
  sc, maxT, v: Single;
begin
  case Drag of
    drScrub:
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
          v := ScrubStart + Round((MX - DragStartX) / 6) * NumStep(ScrubKey);
          SetNum(ScrubKey, v);
        end;
      end
      else
      begin
        if not ScrubMoved then BeginEdit(ScrubKey);
        Drag := drNone;
      end;
    drTimeline:
      if LHeld and HaveGroup then
      begin
        sc := TimelineScale(maxT);
        v := Max(0, Round((DragStartT + (MX - DragStartX) / sc) * 2) / 2);
        if v <> Waves[SelWave].Groups[SelGroup].Start then
        begin
          if not DragUndoPushed then
          begin
            PushUndo;
            DragUndoPushed := True;
          end;
          Waves[SelWave].Groups[SelGroup].Start := v;
          Modified := True;
        end;
      end
      else Drag := drNone;
  end;
end;

procedure HandleKey(key: TSDL_Keycode);
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
      SDLK_S: SaveWaves;
      SDLK_Z: if ModShift then DoRedo else DoUndo;
      SDLK_Y: DoRedo;
      SDLK_D: if HaveGroup then DuplicateGroup(SelGroup);
    end;
    Exit;
  end;
  case key of
    SDLK_UP: SelectWave(SelWave - 1);
    SDLK_DOWN: SelectWave(SelWave + 1);
    SDLK_INSERT: AddGroup;
    SDLK_DELETE: if HaveGroup then DeleteGroup(SelGroup);
    SDLK_SPACE: SimPlaying := not SimPlaying;
    SDLK_R:
      begin
        SimT := 0;
        SimPlaying := True;
      end;
    SDLK_M: NextMap;
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
  Err, ShotFile: string;
  ShotFrames, ArgI: Integer;

begin
  DataDir := ExtractFilePath(ParamStr(0)) + 'data' + PathDelim;
  MapName := 'brewhold';
  ShotFile := '';
  for ArgI := 1 to ParamCount - 1 do
    if ParamStr(ArgI) = '--map' then MapName := ParamStr(ArgI + 1);

  if not SDL_Init(SDL_INIT_VIDEO) then Halt(1);
  if not SDL_CreateWindowAndRenderer('WaveEdit', WIN_W, WIN_H, SDL_WINDOW_RESIZABLE, @Window, @Renderer) then
  begin
    SDL_Quit;
    Halt(1);
  end;
  SDL_SetWindowMinimumSize(Window, 960, 600);
  SDL_SetRenderVSync(Renderer, 1);
  SDL_SetRenderDrawBlendMode(Renderer, SDL_BLENDMODE_BLEND);
  SDL_SetRenderLogicalPresentation(Renderer, WIN_W, WIN_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
  GfxInit(Renderer);

  if not LoadGameData(DataDir, MapName, Err) then
  begin
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'WaveEdit - data error', PAnsiChar(Err), Window);
    SDL_Quit;
    Halt(1);
  end;
  MapNames := TStringList.Create;
  ScanMaps;
  ComputeEnemyBounds;
  RenderMapTex;
  SelectWave(0);

  for ArgI := 1 to ParamCount - 1 do
    if ParamStr(ArgI) = '--shot' then
    begin
      ShotFile := ParamStr(ArgI + 1);
      if ArgI + 2 <= ParamCount then SelectWave(StrToIntDef(ParamStr(ArgI + 2), 1) - 1);
      SelGroup := 1;
      MX := CX0 + 300;
      MY := CH_Y + 60;
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
      end;
    end;
    UIUpdateMods;
    Now_ := SDL_GetTicks;
    Dt := Min(0.05, (Now_ - Last) / 1000);
    if ShotFile <> '' then Dt := 0.2;
    Last := Now_;
    AnimTime := AnimTime + Dt;
    if StatusTime > 0 then StatusTime := StatusTime - Dt;
    UpdateDrags;
    if HaveWave then SelGroup := Min(SelGroup, High(Waves[SelWave].Groups));
    UpdateSim(Dt);

    SDL_SetRenderDrawColor(Renderer, C_BG.r, C_BG.g, C_BG.b, 255);
    SDL_RenderClear(Renderer);
    DrawToolbar;
    DrawWaveList;
    DrawTable;
    DrawTimeline;
    DrawChart;
    FillRect(WIN_W - RIGHT_W, TOP_H, RIGHT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
    FillRect(WIN_W - RIGHT_W, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
    DrawPreview;
    DrawStats;
    FillRect(0, WIN_H - STATUS_H, WIN_W, STATUS_H, C_PANEL);
    FillRect(0, WIN_H - STATUS_H, WIN_W, 1, C_LINE);
    if StatusTime > 0 then
      DrawText(10, WIN_H - STATUS_H + 3, StatusMsg, C_ACCENT, fnSmall, ALIGN_LEFT, False)
    else
      DrawText(10, WIN_H - STATUS_H + 3, 'Numbers: drag / click / wheel  |  enemy: click / right-click  |  ' +
        'Ins add group  Del delete  |  Up/Down wave  |  Ctrl+S save  |  F5 play test', C_DIM, fnSmall, ALIGN_LEFT, False);
    if Modified then
      DrawText(WIN_W - 10, WIN_H - STATUS_H + 3, 'modified', RGBA(255, 150, 120), fnSmall, ALIGN_RIGHT, False);
    if ShotFile <> '' then
    begin
      Inc(ShotFrames);
      if ShotFrames = 60 then
      begin
        SaveShot(ShotFile);
        Running := False;
      end;
    end;
    SDL_RenderPresent(Renderer);
    if Modified then SDL_SetWindowTitle(Window, PAnsiChar('WaveEdit - ' + WavesFileName + ' *'))
    else SDL_SetWindowTitle(Window, PAnsiChar('WaveEdit - ' + WavesFileName));
  end;

  if MapTex <> nil then SDL_DestroyTexture(MapTex);
  MapNames.Free;
  GfxDone;
  SDL_DestroyRenderer(Renderer);
  SDL_DestroyWindow(Window);
  SDL_Quit;
end.
