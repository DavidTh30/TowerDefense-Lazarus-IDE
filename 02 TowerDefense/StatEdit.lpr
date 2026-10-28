program StatEdit;

{ StatEdit - tower / enemy / rules / hero editor for Brewhold Defense (Lazarus / Free Pascal + SDL3)

  Edits data\towers.json, data\enemies.json, data\rules.json and data\hero.json, and keeps EVERY waves file
  (one per map) in step when enemies are renamed, reordered, added or removed.

  Tabs: Towers | Enemies | Rules | Hero (data\hero.json)
    left ...... item list (add / duplicate / delete / reorder) - Rules: section index
    middle .... properties; towers also get an upgrade-level table
    right ..... animated preview + balance analysis (DPS, DPS per gold, time-to-kill vs every enemy,
                map crossing time, economy curves) for a chosen "analysis wave"
  Editing: numbers - drag sideways / click to type / wheel; enums & sounds - click next, right-click previous
           (sounds play when changed); text & colours - click to type.
  Keys: Ctrl+S save   Ctrl+Z / Ctrl+Y undo / redo   Up/Down select item   Tab next tab   F5 play-test
  Test hook: statedit --shot <file.bmp> [tab 1-3] [item] }

{$mode objfpc}{$H+}
{$APPTYPE GUI}

uses
  SDL3, SysUtils, Math, StrUtils, Classes, Process, TypInfo, gfx, sfx, geometry, gamedata, mapcore, ui;

const
  WIN_W = 1440;
  WIN_H = 900;
  TOP_H = 44;
  LEFT_W = 230;
  MID_W = 500;
  STATUS_H = 24;
  MID_X = LEFT_W;
  RIGHT_X = LEFT_W + MID_W;
  RIGHT_W = WIN_W - RIGHT_X;
  ROW_H = 23;
  PREVIEW_H = 270;
  MAX_UNDO = 300;

  TAB_TOWERS = 0;
  TAB_ENEMIES = 1;
  TAB_RULES = 2;
  TAB_HERO = 3;
  TabNames: array[0..3] of string = ('Towers', 'Enemies', 'Rules', 'Hero');

  BarColors: array[0..5] of TRGBA = (
    (r: 230; g: 160; b: 70; a: 255), (r: 170; g: 110; b: 230; a: 255), (r: 120; g: 170; b: 220; a: 255),
    (r: 220; g: 80; b: 70; a: 255), (r: 120; g: 200; b: 110; a: 255), (r: 240; g: 210; b: 90; a: 255));

type
  TPropKind = (pkText, pkNum, pkInt, pkBool, pkEnum, pkSound, pkColor, pkHeader, pkInfo);
  TPropRow = record
    Key, Caption: string;
    Kind: TPropKind;
  end;

  TUndoEntry = record
    T, E, R, W, H: string;
    Tab, Sel: Integer;
  end;

  TDrag = (drNone, drScrub);

  TWaveSet = record
    FileName: string;
    W: TWaveArray;
    Saved: string;
  end;

var
  Window: PSDL_Window;
  Renderer: PSDL_Renderer;
  DataDir: string;
  Paths: TPathArray;

  Tab: Integer = TAB_TOWERS;
  Sel: Integer = 0;
  PrevLevel: Integer = 1;
  AnaWave: Integer = 10;
  ListScroll, PropScroll: Integer;

  Rows: array of TPropRow;
  SoundNames: array of string;

  SavedT, SavedE, SavedR, SavedW, SavedH: string;
  UndoStack, RedoStack: array of TUndoEntry;

  Drag: TDrag = drNone;
  DragStartX, ScrubStart: Single;
  ScrubKey: string;
  ScrubMoved, DragUndoPushed: Boolean;
  EditKey: string = '';
  EditBuf: string = '';

  AnimTime: Single = 0;
  PvTarget: Single = 0;
  PvSinceFire: Single = 99;
  PvFireT: Single = 0;
  PvShotT: Single = -1;
  PvShotX, PvShotY: Single;
  PvWalking: Boolean = True;

  StatusMsg: string = '';
  StatusTime: Single = 0;
  Issues: TStringList;
  WaveSets: array of TWaveSet;      // [0] = the analysed map's waves (shared with gamedata.Waves)

{ ======================================================================
  helpers
  ====================================================================== }

procedure Status(const s: string);
begin
  StatusMsg := s;
  StatusTime := 6;
end;

function ItemCount: Integer;
begin
  case Tab of
    TAB_TOWERS: Result := Length(TowerDefs);
    TAB_ENEMIES: Result := Length(EnemyDefs);
  else
    Result := 0;
  end;
end;

function HaveItem: Boolean;
begin
  Result := (Sel >= 0) and (Sel < ItemCount);
end;

function HpScale(w: Integer): Single;     // w = 1-based wave number
begin
  Result := 1 + Rules.HpGrowth * (w - 1) + Rules.HpGrowthQuad * Sqr(w - 1);
end;

function TotalWaves: Integer;
begin
  Result := Max(1, Length(Waves));
end;

// single-target damage per second of a tower level (barracks: all soldiers together)
function TowerDps(k, lvl: Integer): Single;
var
  L: TTowerLevel;
begin
  L := TowerDefs[k].Levels[EnsureRange(lvl - 1, 0, High(TowerDefs[k].Levels))];
  if TowerDefs[k].Behavior = TB_BARRACKS then
    Result := TowerDefs[k].Soldiers * L.Damage / Max(0.05, SoldierRules.AttackRate)
  else
    Result := L.Damage / Max(0.05, L.Rate);
end;

function TowerSpent(k, lvl: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to Min(lvl, Length(TowerDefs[k].Levels)) - 1 do Inc(Result, TowerDefs[k].Levels[i].Cost);
end;


const
  SET_SEP = '@@WAVESET@@';

// all waves files referenced by the maps (plus waves.json), parsed against the current enemies
procedure LoadWaveSets;
var
  sr: TSearchRec;
  files: TStringList;
  m: TMapDef;
  err: string;
  i: Integer;
  sl: TStringList;
  w: TWaveArray;
begin
  files := TStringList.Create;
  try
    files.Add(Map.WavesFile);
    if files.IndexOf('waves.json') < 0 then files.Add('waves.json');
    if FindFirst(DataDir + 'maps' + PathDelim + '*.json', faAnyFile, sr) = 0 then
    begin
      repeat
        m := Default(TMapDef);
        if LoadMapFile(DataDir + 'maps' + PathDelim + sr.Name, m, err) then
        begin
          if m.WavesFile = '' then m.WavesFile := 'waves.json';
          if files.IndexOf(m.WavesFile) < 0 then files.Add(m.WavesFile);
        end;
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    SetLength(WaveSets, 0);
    for i := 0 to files.Count - 1 do
    begin
      if not FileExists(DataDir + files[i]) then Continue;
      sl := TStringList.Create;
      try
        sl.LoadFromFile(DataDir + files[i]);
        w := nil;
        if not WavesFromJSONText(sl.Text, w, err) then
        begin
          Issues.Add(files[i] + ': ' + err);
          Continue;
        end;
      finally
        sl.Free;
      end;
      SetLength(WaveSets, Length(WaveSets) + 1);
      WaveSets[High(WaveSets)].FileName := files[i];
      WaveSets[High(WaveSets)].W := w;
      WaveSets[High(WaveSets)].Saved := WavesToJSON(w);
    end;
  finally
    files.Free;
  end;
  if Length(WaveSets) > 0 then Waves := WaveSets[0].W;
end;

function AllWavesJSON: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(WaveSets) do
    Result := Result + WavesToJSON(WaveSets[i].W) + SET_SEP + LineEnding;
end;

procedure RestoreWaveSets(const txt: string);
var
  rest, part, err: string;
  i, p: Integer;
  w: TWaveArray;
begin
  rest := txt;
  for i := 0 to High(WaveSets) do
  begin
    p := Pos(SET_SEP, rest);
    if p = 0 then Break;
    part := Copy(rest, 1, p - 1);
    Delete(rest, 1, p + Length(SET_SEP) - 1);
    w := nil;
    if WavesFromJSONText(part, w, err) then WaveSets[i].W := w;
  end;
  if Length(WaveSets) > 0 then Waves := WaveSets[0].W;
end;

function WaveSetsDirty: Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(WaveSets) do
    if WavesToJSON(WaveSets[i].W) <> WaveSets[i].Saved then Exit(True);
end;

function EnemyUsage(e: Integer; out spawned: Integer): Integer;
var
  w, g, k: Integer;
begin
  Result := 0;
  spawned := 0;
  for k := 0 to High(WaveSets) do
    for w := 0 to High(WaveSets[k].W) do
      for g := 0 to High(WaveSets[k].W[w].Groups) do
        if WaveSets[k].W[w].Groups[g].Enemy = e then
        begin
          Inc(Result);
          Inc(spawned, WaveSets[k].W[w].Groups[g].Count);
        end;
end;

function FmtK(v: Single): string;
begin
  if v >= 10000 then Result := Format('%.1fk', [v / 1000]) else Result := IntToStr(Round(v));
end;

function F1(v: Single): string;
begin
  Result := FmtNum(Round(v * 10) / 10);
end;

procedure GeoIcon(const geoName: string; cx, cy, size: Single; walking: Boolean; level: Integer = 1);
var
  g, k: Integer;
  st: TAnimState;
  x0, y0, x1, y1, a, b, c, d, sc: Single;
begin
  g := Geo.Find(geoName);
  if g < 0 then
  begin
    Ring(cx, cy, size / 3, size / 3, 2, RGBA(255, 0, 255));
    Exit;
  end;
  x0 := 1e9; y0 := 1e9; x1 := -1e9; y1 := -1e9;
  for k := 0 to High(Geo.Objects[g].Shapes) do
  begin
    if Geo.Objects[g].Shapes[k].Add or (Geo.Objects[g].Shapes[k].Fire > 0) then Continue;
    ShapeBounds(Geo.Objects[g].Shapes[k], a, b, c, d);
    x0 := Min(x0, a); y0 := Min(y0, b); x1 := Max(x1, c); y1 := Max(y1, d);
  end;
  if x0 > x1 then Exit;
  sc := Min(size / Max(1, x1 - x0), size / Max(1, y1 - y0));
  st := DefaultAnimState;
  st.Time := AnimTime;
  st.Walk := AnimTime;
  st.Moving := walking;
  st.Level := level;
  st.Aim := -Pi / 4;
  DrawGeo(Geo.Objects[g], cx - (x0 + x1) / 2 * sc, cy - (y0 + y1) / 2 * sc, sc, st);
end;

{ ======================================================================
  undo / files
  ====================================================================== }

function Snapshot: TUndoEntry;
begin
  Result.T := TowersToJSON;
  Result.E := EnemiesToJSON;
  Result.R := RulesToJSON;
  Result.W := AllWavesJSON;
  Result.H := HeroToJSON;
  Result.Tab := Tab;
  Result.Sel := Sel;
end;

procedure PushUndo;
begin
  if Length(UndoStack) >= MAX_UNDO then Delete(UndoStack, 0, 1);
  SetLength(UndoStack, Length(UndoStack) + 1);
  UndoStack[High(UndoStack)] := Snapshot;
  SetLength(RedoStack, 0);
end;

procedure Restore(const e: TUndoEntry);
var
  err: string;
  w: TWaveArray;
begin
  EnemiesFromJSONText(e.E, err);       // enemies first: waves refer to them by id
  RestoreWaveSets(e.W);
  TowersFromJSONText(e.T, err);
  RulesFromJSONText(e.R, err);
  HeroFromJSONText(e.H, err);
  Tab := e.Tab;
  Sel := e.Sel;
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

procedure MarkSaved;
var
  i: Integer;
begin
  SavedT := TowersToJSON;
  SavedE := EnemiesToJSON;
  SavedR := RulesToJSON;
  SavedW := AllWavesJSON;
  for i := 0 to High(WaveSets) do WaveSets[i].Saved := WavesToJSON(WaveSets[i].W);
  SavedH := HeroToJSON;
end;

function HeroDirty: Boolean;
begin
  Result := HeroToJSON <> SavedH;
end;

function Dirty(out t, e, r, w: Boolean): Boolean;
begin
  t := TowersToJSON <> SavedT;
  e := EnemiesToJSON <> SavedE;
  r := RulesToJSON <> SavedR;
  w := WaveSetsDirty;
  Result := t or e or r or w or HeroDirty;
end;

function IsModified: Boolean;
var
  t, e, r, w: Boolean;
begin
  Result := Dirty(t, e, r, w);
end;

function SaveAll: Boolean;
var
  t, e, r, w: Boolean;
  i: Integer;
  files: string;
begin
  Result := True;
  Dirty(t, e, r, w);
  files := '';
  if t then
  begin
    Result := Result and SaveTextFile(DataDir + 'towers.json', TowersToJSON);
    files := files + ' towers.json';
  end;
  if e then
  begin
    Result := Result and SaveTextFile(DataDir + 'enemies.json', EnemiesToJSON);
    files := files + ' enemies.json';
  end;
  if r then
  begin
    Result := Result and SaveTextFile(DataDir + 'rules.json', RulesToJSON);
    files := files + ' rules.json';
  end;
  if w then
    for i := 0 to High(WaveSets) do
      if WavesToJSON(WaveSets[i].W) <> WaveSets[i].Saved then
      begin
        Result := Result and SaveTextFile(DataDir + WaveSets[i].FileName, WavesToJSON(WaveSets[i].W));
        files := files + ' ' + WaveSets[i].FileName;
      end;
  if HeroDirty then
  begin
    Result := Result and SaveTextFile(DataDir + 'hero.json', HeroToJSON);
    files := files + ' hero.json';
  end;
  if Result then
  begin
    MarkSaved;
    if files = '' then Status('Nothing to save') else Status('Saved' + files);
  end
  else
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Save failed', 'Could not write a data file', Window);
end;

function ConfirmDiscard: Boolean;
var
  btn: array[0..2] of TSDL_MessageBoxButtonData;
  data: TSDL_MessageBoxData;
  hit: LongInt;
begin
  Result := True;
  if not IsModified then Exit;
  btn[0].flags := SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT; btn[0].buttonID := 0; btn[0].Text := 'Save';
  btn[1].flags := 0; btn[1].buttonID := 1; btn[1].Text := 'Discard';
  btn[2].flags := SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT; btn[2].buttonID := 2; btn[2].Text := 'Cancel';
  FillChar(data, SizeOf(data), 0);
  data.flags := SDL_MESSAGEBOX_WARNING;
  data.window := Window;
  data.title := 'Unsaved changes';
  data.message := 'Tower / enemy / rules data has unsaved changes. Save first?';
  data.numbuttons := 3;
  data.Buttons := @btn[0];
  hit := 2;
  SDL_ShowMessageBox(@data, @hit);
  case hit of
    0: Result := SaveAll;
    1: Result := True;
  else
    Result := False;
  end;
end;

function ReloadAll: Boolean;
var
  err: string;
begin
  Result := LoadGameData(DataDir, 'brewhold', err);
  if not Result then
  begin
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'StatEdit - data error', PAnsiChar(err), Window);
    Exit;
  end;
  BuildAllPaths(Map, Paths);
  LoadWaveSets;
  MarkSaved;
  SetLength(UndoStack, 0);
  SetLength(RedoStack, 0);
  Sel := EnsureRange(Sel, 0, Max(0, ItemCount - 1));
  AnaWave := EnsureRange(AnaWave, 1, TotalWaves);
end;

procedure PlayTest;
var
  pr: TProcess;
  exe: string;
begin
  if IsModified and not SaveAll then Exit;
  exe := ExtractFilePath(ParamStr(0)) + 'towerdefense.exe';
  if not FileExists(exe) then
  begin
    Status('towerdefense.exe not found next to StatEdit');
    Exit;
  end;
  pr := TProcess.Create(nil);
  try
    pr.Executable := exe;
    pr.Parameters.Add('--wave');
    pr.Parameters.Add(IntToStr(AnaWave));
    pr.CurrentDirectory := ExtractFilePath(exe);
    pr.Execute;
    Status(Format('Started the game at wave %d', [AnaWave]));
  except
    on e: Exception do Status('Could not start the game: ' + e.Message);
  end;
  pr.Free;
end;

{ ======================================================================
  list operations (keep waves consistent with enemy indexes)
  ====================================================================== }

procedure RemapEnemyInWaves(oldIdx, newIdx: Integer);   // newIdx = -2: shift down indexes above oldIdx
var
  w, g, k: Integer;
begin
  for k := 0 to High(WaveSets) do
    for w := 0 to High(WaveSets[k].W) do
      for g := 0 to High(WaveSets[k].W[w].Groups) do
        if newIdx = -2 then
        begin
          if WaveSets[k].W[w].Groups[g].Enemy > oldIdx then Dec(WaveSets[k].W[w].Groups[g].Enemy);
        end
        else if WaveSets[k].W[w].Groups[g].Enemy = oldIdx then
          WaveSets[k].W[w].Groups[g].Enemy := newIdx;
end;

function UniqueId(const base: string; enemies: Boolean): string;
var
  n, i: Integer;
  taken: Boolean;
begin
  n := 1;
  repeat
    if n = 1 then Result := base else Result := base + IntToStr(n);
    taken := False;
    if enemies then
    begin
      for i := 0 to High(EnemyDefs) do if SameText(EnemyDefs[i].Id, Result) then taken := True;
    end
    else
      for i := 0 to High(TowerDefs) do if SameText(TowerDefs[i].Id, Result) then taken := True;
    Inc(n);
  until not taken;
end;

procedure AddItem(duplicate: Boolean);
var
  n: Integer;
begin
  PushUndo;
  if Tab = TAB_TOWERS then
  begin
    n := Length(TowerDefs);
    SetLength(TowerDefs, n + 1);
    if duplicate and HaveItem then
    begin
      TowerDefs[n] := TowerDefs[Sel];
      TowerDefs[n].Levels := Copy(TowerDefs[Sel].Levels);
      TowerDefs[n].Id := UniqueId(TowerDefs[Sel].Id, False);
      TowerDefs[n].Name := TowerDefs[Sel].Name + ' copy';
    end
    else
    begin
      TowerDefs[n] := TowerDefs[0];
      TowerDefs[n].Levels := Copy(TowerDefs[0].Levels);
      TowerDefs[n].Id := UniqueId('tower', False);
      TowerDefs[n].Name := 'New Tower';
      TowerDefs[n].Desc := '';
    end;
  end
  else if Tab = TAB_ENEMIES then
  begin
    n := Length(EnemyDefs);
    SetLength(EnemyDefs, n + 1);
    if duplicate and HaveItem then
    begin
      EnemyDefs[n] := EnemyDefs[Sel];
      EnemyDefs[n].Id := UniqueId(EnemyDefs[Sel].Id, True);
      EnemyDefs[n].Name := EnemyDefs[Sel].Name + ' copy';
    end
    else
    begin
      EnemyDefs[n] := EnemyDefs[0];
      EnemyDefs[n].Id := UniqueId('enemy', True);
      EnemyDefs[n].Name := 'New Enemy';
      EnemyDefs[n].Desc := '';
    end;
  end
  else Exit;
  Sel := n;
  Status('Added ' + IfThen(Tab = TAB_TOWERS, TowerDefs[n].Id, EnemyDefs[n].Id) +
    IfThen(Tab = TAB_ENEMIES, ' (use it in WaveEdit to make it appear)', ''));
end;

procedure DeleteItem;
var
  i, groups, spawned: Integer;
begin
  if not HaveItem then Exit;
  if ItemCount <= 1 then
  begin
    Status('At least one entry is required');
    Exit;
  end;
  if Tab = TAB_ENEMIES then
  begin
    groups := EnemyUsage(Sel, spawned);
    if groups > 0 then
    begin
      Status(Format('"%s" is used by %d wave groups (all maps) - remove it in WaveEdit first', [EnemyDefs[Sel].Id,
        groups]));
      Exit;
    end;
    PushUndo;
    for i := Sel to High(EnemyDefs) - 1 do EnemyDefs[i] := EnemyDefs[i + 1];
    SetLength(EnemyDefs, Length(EnemyDefs) - 1);
    RemapEnemyInWaves(Sel, -2);
  end
  else if Tab = TAB_TOWERS then
  begin
    PushUndo;
    for i := Sel to High(TowerDefs) - 1 do TowerDefs[i] := TowerDefs[i + 1];
    SetLength(TowerDefs, Length(TowerDefs) - 1);
  end;
  Sel := Min(Sel, ItemCount - 1);
end;

procedure MoveItem(d: Integer);
var
  j: Integer;
  tt: TTowerDef;
  te: TEnemyDef;
begin
  j := Sel + d;
  if not HaveItem or (j < 0) or (j >= ItemCount) then Exit;
  PushUndo;
  if Tab = TAB_TOWERS then
  begin
    tt := TowerDefs[Sel]; TowerDefs[Sel] := TowerDefs[j]; TowerDefs[j] := tt;
  end
  else
  begin
    te := EnemyDefs[Sel]; EnemyDefs[Sel] := EnemyDefs[j]; EnemyDefs[j] := te;
    RemapEnemyInWaves(Sel, 9999);
    RemapEnemyInWaves(j, Sel);
    RemapEnemyInWaves(9999, j);
  end;
  Sel := j;
end;

procedure AddLevel;
var
  n: Integer;
begin
  if (Tab <> TAB_TOWERS) or not HaveItem then Exit;
  PushUndo;
  n := Length(TowerDefs[Sel].Levels);
  SetLength(TowerDefs[Sel].Levels, n + 1);
  TowerDefs[Sel].Levels[n] := TowerDefs[Sel].Levels[n - 1];
  TowerDefs[Sel].Levels[n].Damage := Round(TowerDefs[Sel].Levels[n].Damage * 1.5);
  TowerDefs[Sel].Levels[n].Cost := Round(TowerDefs[Sel].Levels[n].Cost * 1.5);
  TowerDefs[Sel].Levels[n].Range := TowerDefs[Sel].Levels[n].Range + 15;
  PrevLevel := n + 1;
  Status('Level added. Geometry shapes can use minLevel to show it (GeoEdit).');
end;

procedure RemoveLevel;
begin
  if (Tab <> TAB_TOWERS) or not HaveItem or (Length(TowerDefs[Sel].Levels) <= 1) then Exit;
  PushUndo;
  SetLength(TowerDefs[Sel].Levels, Length(TowerDefs[Sel].Levels) - 1);
  PrevLevel := Min(PrevLevel, Length(TowerDefs[Sel].Levels));
end;

{ ======================================================================
  properties: rows, get / set
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
  t: TTowerDef;
begin
  SetLength(Rows, 0);
  case Tab of
    TAB_TOWERS:
      if HaveItem then
      begin
        t := TowerDefs[Sel];
        AddRow('id', 'id', pkText);
        AddRow('name', 'name', pkText);
        AddRow('desc', 'description', pkText);
        AddRow('behavior', 'behavior', pkEnum);
        AddRow('geometry', 'geometry', pkEnum);
        if t.Behavior <> TB_BARRACKS then AddRow('projectile', 'projectile', pkEnum);
        AddRow('hitsAir', 'hits flying', pkBool);
        AddRow('magic', 'magic (ignores armor)', pkBool);
        if t.Behavior <> TB_BARRACKS then
        begin
          AddRow('muzzleY', 'muzzle height', pkNum);
          if t.Behavior = TB_BOMB then
          begin
            AddRow('flightTime', 'shell flight time (s)', pkNum);
            AddRow('projArc', 'shell arc (px)', pkNum);
          end
          else
          begin
            AddRow('projSpeed', 'projectile speed', pkNum);
            AddRow('projArc', 'arc (share of distance)', pkNum);
          end;
          AddRow('fireSound', 'fire sound', pkSound);
          AddRow('hitSound', 'hit sound', pkSound);
        end
        else
          AddRow('soldiers', 'soldiers', pkInt);
      end;
    TAB_ENEMIES:
      if HaveItem then
      begin
        AddRow('id', 'id (used in waves)', pkText);
        AddRow('name', 'name', pkText);
        AddRow('desc', 'description', pkText);
        AddRow('geometry', 'geometry', pkEnum);
        AddRow('', 'Combat', pkHeader);
        AddRow('hp', 'hit points (wave 1)', pkNum);
        AddRow('speed', 'speed (px/s)', pkNum);
        AddRow('armor', 'armor (0-0.95)', pkNum);
        AddRow('damage', 'damage to soldiers', pkNum);
        AddRow('flying', 'flying', pkBool);
        AddRow('', 'Rewards', pkHeader);
        AddRow('gold', 'gold reward', pkInt);
        AddRow('lives', 'lives cost', pkInt);
        AddRow('', 'Presentation', pkHeader);
        AddRow('radius', 'radius', pkNum);
        AddRow('hitY', 'hit height', pkNum);
        AddRow('barY', 'health bar height', pkNum);
        AddRow('barW', 'health bar width', pkNum);
        AddRow('explode', 'explode on death', pkBool);
        AddRow('deathSound', 'death sound', pkSound);
        AddRow('deathColor', 'death colour', pkColor);
      end;
    TAB_HERO:
      begin
        AddRow('h.enabled', 'hero enabled', pkBool);
        AddRow('h.name', 'name', pkText);
        AddRow('h.desc', 'description', pkText);
        AddRow('h.geometry', 'geometry', pkEnum);
        AddRow('h.speed', 'walk speed', pkNum);
        AddRow('h.engage', 'engage range', pkNum);
        AddRow('h.respawn', 'respawn time (s)', pkNum);
        AddRow('h.regen', 'idle regen / s (share)', pkNum);
        AddRow('h.xpPerGold', 'xp per gold of a kill', pkNum);
        AddRow('', 'Ability 1 (key 3)', pkHeader);
        AddRow('h.s.name', 'name', pkText);
        AddRow('h.s.desc', 'description', pkText);
        AddRow('h.s.cooldown', 'cooldown (s)', pkNum);
        AddRow('h.s.radius', 'radius', pkNum);
        AddRow('h.s.damage', 'damage', pkNum);
        AddRow('h.s.perLevel', 'damage per level', pkNum);
        AddRow('h.s.stun', 'stun (s)', pkNum);
        AddRow('h.s.sound', 'sound', pkSound);
        AddRow('', 'Ability 2 (key 4)', pkHeader);
        AddRow('h.h.name', 'name', pkText);
        AddRow('h.h.desc', 'description', pkText);
        AddRow('h.h.cooldown', 'cooldown (s)', pkNum);
        AddRow('h.h.radius', 'throw range', pkNum);
        AddRow('h.h.damage', 'damage', pkNum);
        AddRow('h.h.perLevel', 'damage per level', pkNum);
        AddRow('h.h.splash', 'splash radius', pkNum);
        AddRow('h.h.geometry', 'projectile', pkEnum);
        AddRow('h.h.sound', 'sound', pkSound);
      end;
    TAB_RULES:
      begin
        AddRow('', 'Economy', pkHeader);
        AddRow('r.startGold', 'start gold', pkInt);
        AddRow('r.startLives', 'start lives', pkInt);
        AddRow('r.waveGap', 'time between waves (s)', pkNum);
        AddRow('r.earlyBonus', 'early call gold / s', pkNum);
        AddRow('r.earlyCut', 'early call cooldown cut', pkNum);
        AddRow('r.sell', 'sell refund ratio', pkNum);
        AddRow('', 'Enemy scaling', pkHeader);
        AddRow('r.hpGrowth', 'hp growth / wave', pkNum);
        AddRow('r.hpQuad', 'hp growth (quadratic)', pkNum);
        AddRow('r.dmgGrowth', 'damage growth / wave', pkNum);
        AddRow('', 'Rain of Fire', pkHeader);
        AddRow('f.name', 'name', pkText);
        AddRow('f.desc', 'description', pkText);
        AddRow('f.geometry', 'geometry', pkEnum);
        AddRow('f.cooldown', 'cooldown (s)', pkNum);
        AddRow('f.meteors', 'meteors', pkInt);
        AddRow('f.damage', 'damage', pkNum);
        AddRow('f.damagePerWave', 'damage per wave', pkNum);
        AddRow('f.splash', 'splash radius', pkNum);
        AddRow('f.spreadX', 'spread x', pkNum);
        AddRow('f.spreadY', 'spread y', pkNum);
        AddRow('f.delay', 'delay between', pkNum);
        AddRow('f.fall', 'fall time', pkNum);
        AddRow('', 'Reinforcements', pkHeader);
        AddRow('m.name', 'name', pkText);
        AddRow('m.desc', 'description', pkText);
        AddRow('m.geometry', 'geometry', pkEnum);
        AddRow('m.cooldown', 'cooldown (s)', pkNum);
        AddRow('m.count', 'militia count', pkInt);
        AddRow('m.hp', 'hp', pkNum);
        AddRow('m.hpPerWave', 'hp per wave', pkNum);
        AddRow('m.damage', 'damage', pkNum);
        AddRow('m.damagePerWave', 'damage per wave', pkNum);
        AddRow('m.lifetime', 'lifetime (s)', pkNum);
        AddRow('', 'Barracks soldiers', pkHeader);
        AddRow('s.geometry', 'geometry', pkEnum);
        AddRow('s.walk', 'walk speed', pkNum);
        AddRow('s.engage', 'engage range', pkNum);
        AddRow('s.leash', 'leash range', pkNum);
        AddRow('s.respawn', 'respawn time (s)', pkNum);
        AddRow('s.attack', 'attack interval (s)', pkNum);
        AddRow('s.regen', 'idle regen / s', pkNum);
      end;
  end;
end;

function GeoOptions(const category: string): TStringArray;
var
  i: Integer;
begin
  SetLength(Result, 0);
  for i := 0 to Geo.Count - 1 do
    if (category = '') or SameText(Geo.Objects[i].Category, category) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Geo.Objects[i].Name;
    end;
end;

function Options(const key: string): TStringArray;
begin
  SetLength(Result, 0);
  if key = 'behavior' then
  begin
    SetLength(Result, 4);
    Result[0] := 'arrow'; Result[1] := 'bolt'; Result[2] := 'bomb'; Result[3] := 'barracks';
  end
  else if key = 'geometry' then
  begin
    if Tab = TAB_TOWERS then Result := GeoOptions('tower') else Result := GeoOptions('enemy');
  end
  else if key = 'projectile' then Result := GeoOptions('projectile')
  else if key = 'f.geometry' then Result := GeoOptions('projectile')
  else if (key = 'm.geometry') or (key = 's.geometry') or (key = 'h.geometry') then Result := GeoOptions('unit')
  else if key = 'h.h.geometry' then Result := GeoOptions('projectile')
  else if (key = 'h.s.sound') or (key = 'h.h.sound') then Result := SoundNames
  else if (key = 'fireSound') or (key = 'hitSound') or (key = 'deathSound') then Result := SoundNames;
end;

function GetStr(const key: string): string;
var
  t: TTowerDef;
  e: TEnemyDef;
begin
  Result := '';
  if (Tab = TAB_TOWERS) and HaveItem then
  begin
    t := TowerDefs[Sel];
    case key of
      'id': Exit(t.Id);
      'name': Exit(t.Name);
      'desc': Exit(t.Desc);
      'behavior': Exit(BehaviorName(t.Behavior));
      'geometry': Exit(t.Geometry);
      'projectile': Exit(t.Projectile);
      'hitsAir': Exit(BoolToStr(t.HitsAir, 'yes', 'no'));
      'magic': Exit(BoolToStr(t.Magic, 'yes', 'no'));
      'muzzleY': Exit(FmtNum(t.MuzzleY));
      'projSpeed': Exit(FmtNum(t.ProjSpeed));
      'projArc': Exit(FmtNum(t.ProjArc));
      'flightTime': Exit(FmtNum(t.ProjTime));
      'soldiers': Exit(IntToStr(t.Soldiers));
      'fireSound': Exit(t.FireSound);
      'hitSound': Exit(t.HitSound);
    end;
  end;
  if (Tab = TAB_ENEMIES) and HaveItem then
  begin
    e := EnemyDefs[Sel];
    case key of
      'id': Exit(e.Id);
      'name': Exit(e.Name);
      'desc': Exit(e.Desc);
      'geometry': Exit(e.Geometry);
      'hp': Exit(FmtNum(e.Hp));
      'speed': Exit(FmtNum(e.Speed));
      'armor': Exit(FmtNum(e.Armor));
      'damage': Exit(FmtNum(e.Dmg));
      'flying': Exit(BoolToStr(e.Flying, 'yes', 'no'));
      'gold': Exit(IntToStr(e.Gold));
      'lives': Exit(IntToStr(e.LivesCost));
      'radius': Exit(FmtNum(e.Radius));
      'hitY': Exit(FmtNum(e.HitY));
      'barY': Exit(FmtNum(e.BarY));
      'barW': Exit(FmtNum(e.BarW));
      'explode': Exit(BoolToStr(e.ExplodeOnDeath, 'yes', 'no'));
      'deathSound': Exit(e.DeathSound);
      'deathColor': Exit(ColorToStr(e.DeathColor));
    end;
  end;
  case key of
    'r.startGold': Result := IntToStr(Rules.StartGold);
    'r.startLives': Result := IntToStr(Rules.StartLives);
    'r.waveGap': Result := FmtNum(Rules.WaveGap);
    'r.earlyBonus': Result := FmtNum(Rules.EarlyBonusPerSec);
    'r.earlyCut': Result := FmtNum(Rules.EarlyCooldownCut);
    'r.sell': Result := FmtNum(Rules.SellRatio);
    'r.hpGrowth': Result := FmtNum(Rules.HpGrowth);
    'r.hpQuad': Result := FmtNum(Rules.HpGrowthQuad);
    'r.dmgGrowth': Result := FmtNum(Rules.DmgGrowth);
    'f.name': Result := FireSpell.Name;
    'f.desc': Result := FireSpell.Desc;
    'f.geometry': Result := FireSpell.Geometry;
    'f.cooldown': Result := FmtNum(FireSpell.Cooldown);
    'f.meteors': Result := IntToStr(FireSpell.Meteors);
    'f.damage': Result := FmtNum(FireSpell.DmgBase);
    'f.damagePerWave': Result := FmtNum(FireSpell.DmgPerWave);
    'f.splash': Result := FmtNum(FireSpell.Splash);
    'f.spreadX': Result := FmtNum(FireSpell.SpreadX);
    'f.spreadY': Result := FmtNum(FireSpell.SpreadY);
    'f.delay': Result := FmtNum(FireSpell.Delay);
    'f.fall': Result := FmtNum(FireSpell.FallTime);
    'm.name': Result := Reinf.Name;
    'm.desc': Result := Reinf.Desc;
    'm.geometry': Result := Reinf.Geometry;
    'm.cooldown': Result := FmtNum(Reinf.Cooldown);
    'm.count': Result := IntToStr(Reinf.Count);
    'm.hp': Result := FmtNum(Reinf.HpBase);
    'm.hpPerWave': Result := FmtNum(Reinf.HpPerWave);
    'm.damage': Result := FmtNum(Reinf.DmgBase);
    'm.damagePerWave': Result := FmtNum(Reinf.DmgPerWave);
    'm.lifetime': Result := FmtNum(Reinf.Lifetime);
    's.geometry': Result := SoldierRules.Geometry;
    's.walk': Result := FmtNum(SoldierRules.Walk);
    's.engage': Result := FmtNum(SoldierRules.Engage);
    's.leash': Result := FmtNum(SoldierRules.Leash);
    's.respawn': Result := FmtNum(SoldierRules.Respawn);
    's.attack': Result := FmtNum(SoldierRules.AttackRate);
    's.regen': Result := FmtNum(SoldierRules.RegenFrac);
    'h.enabled': Result := BoolToStr(Hero.Enabled, 'yes', 'no');
    'h.name': Result := Hero.Name;
    'h.desc': Result := Hero.Desc;
    'h.geometry': Result := Hero.Geometry;
    'h.speed': Result := FmtNum(Hero.Speed);
    'h.engage': Result := FmtNum(Hero.Engage);
    'h.respawn': Result := FmtNum(Hero.Respawn);
    'h.regen': Result := FmtNum(Hero.Regen);
    'h.xpPerGold': Result := FmtNum(Hero.XpPerGold);
    'h.s.name': Result := Hero.Slam.Name;
    'h.s.desc': Result := Hero.Slam.Desc;
    'h.s.cooldown': Result := FmtNum(Hero.Slam.Cooldown);
    'h.s.radius': Result := FmtNum(Hero.Slam.Radius);
    'h.s.damage': Result := FmtNum(Hero.Slam.Damage);
    'h.s.perLevel': Result := FmtNum(Hero.Slam.DamagePerLevel);
    'h.s.stun': Result := FmtNum(Hero.Slam.Stun);
    'h.s.sound': Result := Hero.Slam.Sound;
    'h.h.name': Result := Hero.Hammer.Name;
    'h.h.desc': Result := Hero.Hammer.Desc;
    'h.h.cooldown': Result := FmtNum(Hero.Hammer.Cooldown);
    'h.h.radius': Result := FmtNum(Hero.Hammer.Radius);
    'h.h.damage': Result := FmtNum(Hero.Hammer.Damage);
    'h.h.perLevel': Result := FmtNum(Hero.Hammer.DamagePerLevel);
    'h.h.splash': Result := FmtNum(Hero.Hammer.Splash);
    'h.h.geometry': Result := Hero.Hammer.Geometry;
    'h.h.sound': Result := Hero.Hammer.Sound;
  end;
end;

function ParseNum(const s: string; out v: Single): Boolean;
var
  fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  Result := TryStrToFloat(StringReplace(Trim(s), ',', '.', []), v, fs);
end;

// level table cells: "L<i>.<field>"
function LevelKey(const key: string; out lvl: Integer; out field: string): Boolean;
var
  p: Integer;
begin
  Result := False;
  if (Tab <> TAB_TOWERS) or not HaveItem or (Length(key) < 4) or (key[1] <> 'L') then Exit;
  p := Pos('.', key);
  if (p < 3) or not TryStrToInt(Copy(key, 2, p - 2), lvl) then Exit;
  field := Copy(key, p + 1, 20);
  Result := (lvl >= 0) and (lvl <= High(TowerDefs[Sel].Levels));
end;

function HeroLevelKey(const key: string; out lvl: Integer; out field: string): Boolean;
var
  p: Integer;
begin
  Result := False;
  if (Length(key) < 4) or (key[1] <> 'H') then Exit;
  p := Pos('.', key);
  if (p < 3) or not TryStrToInt(Copy(key, 2, p - 2), lvl) then Exit;
  field := Copy(key, p + 1, 20);
  Result := (lvl >= 0) and (lvl <= High(Hero.Levels));
end;

procedure SetStr(const key, value: string);
var
  v: Single;
  isNum: Boolean;
  lvl, i: Integer;
  field: string;
begin
  isNum := ParseNum(value, v);
  if LevelKey(key, lvl, field) then
  begin
    if not isNum then Exit;
    case field of
      'range': TowerDefs[Sel].Levels[lvl].Range := Max(10, v);
      'damage': TowerDefs[Sel].Levels[lvl].Damage := Max(0, v);
      'rate': TowerDefs[Sel].Levels[lvl].Rate := Max(0.05, v);
      'splash': TowerDefs[Sel].Levels[lvl].Splash := Max(0, v);
      'hp': TowerDefs[Sel].Levels[lvl].SoldierHp := Max(1, v);
      'cost': TowerDefs[Sel].Levels[lvl].Cost := Max(0, Round(v));
    end;
    Exit;
  end;
  if (Tab = TAB_TOWERS) and HaveItem then
    case key of
      'id':
        begin
          for i := 0 to High(TowerDefs) do
            if (i <> Sel) and SameText(TowerDefs[i].Id, Trim(value)) then
            begin
              Status('Id already used');
              Exit;
            end;
          if Trim(value) <> '' then TowerDefs[Sel].Id := Trim(value);
          Exit;
        end;
      'name': begin TowerDefs[Sel].Name := value; Exit; end;
      'desc': begin TowerDefs[Sel].Desc := value; Exit; end;
      'behavior':
        begin
          if value = 'bolt' then TowerDefs[Sel].Behavior := TB_BOLT
          else if value = 'bomb' then TowerDefs[Sel].Behavior := TB_BOMB
          else if value = 'barracks' then TowerDefs[Sel].Behavior := TB_BARRACKS
          else TowerDefs[Sel].Behavior := TB_ARROW;
          Exit;
        end;
      'geometry': begin TowerDefs[Sel].Geometry := value; Exit; end;
      'projectile': begin TowerDefs[Sel].Projectile := value; Exit; end;
      'fireSound': begin TowerDefs[Sel].FireSound := value; Exit; end;
      'hitSound': begin TowerDefs[Sel].HitSound := value; Exit; end;
      'hitsAir': begin TowerDefs[Sel].HitsAir := not TowerDefs[Sel].HitsAir; Exit; end;
      'magic': begin TowerDefs[Sel].Magic := not TowerDefs[Sel].Magic; Exit; end;
    end;
  if (Tab = TAB_ENEMIES) and HaveItem then
    case key of
      'id':
        begin
          for i := 0 to High(EnemyDefs) do
            if (i <> Sel) and SameText(EnemyDefs[i].Id, Trim(value)) then
            begin
              Status('Id already used');
              Exit;
            end;
          if Trim(value) <> '' then
          begin
            EnemyDefs[Sel].Id := Trim(value);
            Status('Renamed - waves.json will be updated on save');
          end;
          Exit;
        end;
      'name': begin EnemyDefs[Sel].Name := value; Exit; end;
      'desc': begin EnemyDefs[Sel].Desc := value; Exit; end;
      'geometry': begin EnemyDefs[Sel].Geometry := value; Exit; end;
      'deathSound': begin EnemyDefs[Sel].DeathSound := value; Exit; end;
      'deathColor': begin EnemyDefs[Sel].DeathColor := ParseColor(value, EnemyDefs[Sel].DeathColor); Exit; end;
      'flying': begin EnemyDefs[Sel].Flying := not EnemyDefs[Sel].Flying; Exit; end;
      'explode': begin EnemyDefs[Sel].ExplodeOnDeath := not EnemyDefs[Sel].ExplodeOnDeath; Exit; end;
    end;
  if HeroLevelKey(key, lvl, field) then
  begin
    if not isNum then Exit;
    case field of
      'hp': Hero.Levels[lvl].Hp := Max(1, v);
      'damage': Hero.Levels[lvl].Damage := Max(0, v);
      'rate': Hero.Levels[lvl].Rate := Max(0.1, v);
      'armor': Hero.Levels[lvl].Armor := EnsureRange(v, 0, 0.9);
      'xp': Hero.Levels[lvl].Xp := Max(0, Round(v));
    end;
    Exit;
  end;
  case key of
    'h.enabled': begin Hero.Enabled := not Hero.Enabled; Exit; end;
    'h.name': begin Hero.Name := value; Exit; end;
    'h.desc': begin Hero.Desc := value; Exit; end;
    'h.geometry': begin Hero.Geometry := value; Exit; end;
    'h.s.name': begin Hero.Slam.Name := value; Exit; end;
    'h.s.desc': begin Hero.Slam.Desc := value; Exit; end;
    'h.s.sound': begin Hero.Slam.Sound := value; Exit; end;
    'h.h.name': begin Hero.Hammer.Name := value; Exit; end;
    'h.h.desc': begin Hero.Hammer.Desc := value; Exit; end;
    'h.h.geometry': begin Hero.Hammer.Geometry := value; Exit; end;
    'h.h.sound': begin Hero.Hammer.Sound := value; Exit; end;
  end;
  case key of
    'f.name': begin FireSpell.Name := value; Exit; end;
    'f.desc': begin FireSpell.Desc := value; Exit; end;
    'f.geometry': begin FireSpell.Geometry := value; Exit; end;
    'm.name': begin Reinf.Name := value; Exit; end;
    'm.desc': begin Reinf.Desc := value; Exit; end;
    'm.geometry': begin Reinf.Geometry := value; Exit; end;
    's.geometry': begin SoldierRules.Geometry := value; Exit; end;
  end;
  if not isNum then
  begin
    Status('Not a number: ' + value);
    Exit;
  end;
  if (Tab = TAB_TOWERS) and HaveItem then
    case key of
      'muzzleY': TowerDefs[Sel].MuzzleY := v;
      'projSpeed': TowerDefs[Sel].ProjSpeed := Max(10, v);
      'projArc': TowerDefs[Sel].ProjArc := Max(0, v);
      'flightTime': TowerDefs[Sel].ProjTime := Max(0.1, v);
      'soldiers': TowerDefs[Sel].Soldiers := EnsureRange(Round(v), 1, 8);
    end;
  if (Tab = TAB_ENEMIES) and HaveItem then
    case key of
      'hp': EnemyDefs[Sel].Hp := Max(1, v);
      'speed': EnemyDefs[Sel].Speed := Max(1, v);
      'armor': EnemyDefs[Sel].Armor := EnsureRange(v, 0, 0.95);
      'damage': EnemyDefs[Sel].Dmg := Max(0, v);
      'gold': EnemyDefs[Sel].Gold := Max(0, Round(v));
      'lives': EnemyDefs[Sel].LivesCost := Max(0, Round(v));
      'radius': EnemyDefs[Sel].Radius := Max(1, v);
      'hitY': EnemyDefs[Sel].HitY := v;
      'barY': EnemyDefs[Sel].BarY := v;
      'barW': EnemyDefs[Sel].BarW := Max(4, v);
    end;
  case key of
    'r.startGold': Rules.StartGold := Max(0, Round(v));
    'r.startLives': Rules.StartLives := Max(1, Round(v));
    'r.waveGap': Rules.WaveGap := Max(1, v);
    'r.earlyBonus': Rules.EarlyBonusPerSec := Max(0, v);
    'r.earlyCut': Rules.EarlyCooldownCut := Max(0, v);
    'r.sell': Rules.SellRatio := EnsureRange(v, 0, 1);
    'r.hpGrowth': Rules.HpGrowth := Max(0, v);
    'r.hpQuad': Rules.HpGrowthQuad := Max(0, v);
    'r.dmgGrowth': Rules.DmgGrowth := Max(0, v);
    'f.cooldown': FireSpell.Cooldown := Max(1, v);
    'f.meteors': FireSpell.Meteors := EnsureRange(Round(v), 1, 30);
    'f.damage': FireSpell.DmgBase := Max(0, v);
    'f.damagePerWave': FireSpell.DmgPerWave := Max(0, v);
    'f.splash': FireSpell.Splash := Max(5, v);
    'f.spreadX': FireSpell.SpreadX := Max(0, v);
    'f.spreadY': FireSpell.SpreadY := Max(0, v);
    'f.delay': FireSpell.Delay := Max(0, v);
    'f.fall': FireSpell.FallTime := Max(0.1, v);
    'm.cooldown': Reinf.Cooldown := Max(1, v);
    'm.count': Reinf.Count := EnsureRange(Round(v), 1, 8);
    'm.hp': Reinf.HpBase := Max(1, v);
    'm.hpPerWave': Reinf.HpPerWave := Max(0, v);
    'm.damage': Reinf.DmgBase := Max(0, v);
    'm.damagePerWave': Reinf.DmgPerWave := Max(0, v);
    'm.lifetime': Reinf.Lifetime := Max(1, v);
    's.walk': SoldierRules.Walk := Max(5, v);
    's.engage': SoldierRules.Engage := Max(10, v);
    's.leash': SoldierRules.Leash := Max(10, v);
    's.respawn': SoldierRules.Respawn := Max(0.5, v);
    's.attack': SoldierRules.AttackRate := Max(0.05, v);
    's.regen': SoldierRules.RegenFrac := Max(0, v);
    'h.speed': Hero.Speed := Max(5, v);
    'h.engage': Hero.Engage := Max(10, v);
    'h.respawn': Hero.Respawn := Max(1, v);
    'h.regen': Hero.Regen := Max(0, v);
    'h.xpPerGold': Hero.XpPerGold := Max(0, v);
    'h.s.cooldown': Hero.Slam.Cooldown := Max(1, v);
    'h.s.radius': Hero.Slam.Radius := Max(10, v);
    'h.s.damage': Hero.Slam.Damage := Max(0, v);
    'h.s.perLevel': Hero.Slam.DamagePerLevel := Max(0, v);
    'h.s.stun': Hero.Slam.Stun := Max(0, v);
    'h.h.cooldown': Hero.Hammer.Cooldown := Max(1, v);
    'h.h.radius': Hero.Hammer.Radius := Max(20, v);
    'h.h.damage': Hero.Hammer.Damage := Max(0, v);
    'h.h.perLevel': Hero.Hammer.DamagePerLevel := Max(0, v);
    'h.h.splash': Hero.Hammer.Splash := Max(0, v);
  end;
end;

function GetLevelNum(const key: string): Single;
var
  lvl: Integer;
  field: string;
begin
  Result := 0;
  if not LevelKey(key, lvl, field) then Exit;
  case field of
    'range': Result := TowerDefs[Sel].Levels[lvl].Range;
    'damage': Result := TowerDefs[Sel].Levels[lvl].Damage;
    'rate': Result := TowerDefs[Sel].Levels[lvl].Rate;
    'splash': Result := TowerDefs[Sel].Levels[lvl].Splash;
    'hp': Result := TowerDefs[Sel].Levels[lvl].SoldierHp;
    'cost': Result := TowerDefs[Sel].Levels[lvl].Cost;
  end;
end;

function GetNum(const key: string): Single;
var
  hl: Integer;
  hf: string;
begin
  if (Length(key) > 1) and (key[1] = 'L') and (Pos('.', key) > 0) then Exit(GetLevelNum(key));
  if HeroLevelKey(key, hl, hf) then
  begin
    case hf of
      'hp': Exit(Hero.Levels[hl].Hp);
      'damage': Exit(Hero.Levels[hl].Damage);
      'rate': Exit(Hero.Levels[hl].Rate);
      'armor': Exit(Hero.Levels[hl].Armor);
      'xp': Exit(Hero.Levels[hl].Xp);
    end;
    Exit(0);
  end;
  if not ParseNum(GetStr(key), Result) then Result := 0;
end;

procedure SetNum(const key: string; v: Single);
begin
  SetStr(key, FmtNum(v));
end;

function NumStep(const key: string): Single;
var
  lvl: Integer;
  f: string;
begin
  Result := 1;
  if LevelKey(key, lvl, f) then
  begin
    if f = 'rate' then Result := 0.05 else if f = 'cost' then Result := 5 else Result := 1;
  end
  else if (Pos('.armor', key) > 0) or (Pos('.rate', key) > 0) or (key = 'h.regen') then Result := 0.05
  else if Pos('.xp', key) > 0 then Result := 10
  else if (key = 'armor') or (key = 'r.sell') or (key = 'r.earlyCut') or (key = 'projArc') or
    (key = 's.attack') or (key = 'f.delay') or (key = 'f.fall') or (key = 'flightTime') then Result := 0.05
  else if (key = 'r.hpGrowth') or (key = 'm.damagePerWave') or (key = 's.regen') then Result := 0.01
  else if key = 'r.hpQuad' then Result := 0.001
  else if (key = 'r.dmgGrowth') or (key = 'r.earlyBonus') then Result := 0.05
  else if (key = 'projSpeed') or (key = 'r.startGold') then Result := 10;
  if ModShift then Result := Result / 5
  else if ModCtrl then Result := Result * 10;
end;

procedure CycleOption(const key: string; d: Integer);
var
  opts: TStringArray;
  cur, i: Integer;
  snd: Integer;
begin
  opts := Options(key);
  if Length(opts) = 0 then Exit;
  cur := -1;
  for i := 0 to High(opts) do
    if SameText(opts[i], GetStr(key)) then cur := i;
  cur := (cur + d + Length(opts)) mod Length(opts);
  PushUndo;
  SetStr(key, opts[cur]);
  snd := SoundByName(opts[cur]);
  if (snd >= 0) and (Pos('ound', key) > 0) then PlaySoundIdx(snd, 1, 0);
end;

procedure BeginEdit(const key: string; const initial: string);
begin
  EditKey := key;
  EditBuf := initial;
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
  if commit then
  begin
    PushUndo;
    SetStr(k, EditBuf);
  end;
end;

{ ======================================================================
  validation
  ====================================================================== }

procedure Validate;
var
  i, j, groups, spawned: Integer;
begin
  Issues.Clear;
  for i := 0 to High(TowerDefs) do
  begin
    for j := i + 1 to High(TowerDefs) do
      if SameText(TowerDefs[i].Id, TowerDefs[j].Id) then Issues.Add('Tower id "' + TowerDefs[i].Id + '" is used twice');
    if Geo.Find(TowerDefs[i].Geometry) < 0 then
      Issues.Add(Format('Tower %s: geometry "%s" not found', [TowerDefs[i].Id, TowerDefs[i].Geometry]));
    if (TowerDefs[i].Behavior <> TB_BARRACKS) and (Geo.Find(TowerDefs[i].Projectile) < 0) then
      Issues.Add(Format('Tower %s: projectile "%s" not found', [TowerDefs[i].Id, TowerDefs[i].Projectile]));
    if (TowerDefs[i].FireSound <> '') and (SoundByName(TowerDefs[i].FireSound) < 0) then
      Issues.Add(Format('Tower %s: unknown sound "%s"', [TowerDefs[i].Id, TowerDefs[i].FireSound]));
    for j := 0 to High(TowerDefs[i].Levels) do
      if TowerDefs[i].Levels[j].Cost <= 0 then
        Issues.Add(Format('Tower %s level %d costs nothing', [TowerDefs[i].Id, j + 1]));
    if (TowerDefs[i].Behavior = TB_BOMB) and (TowerDefs[i].Levels[0].Splash <= 0) then
      Issues.Add(Format('Tower %s: bomb tower without splash radius', [TowerDefs[i].Id]));
  end;
  for i := 0 to High(EnemyDefs) do
  begin
    for j := i + 1 to High(EnemyDefs) do
      if SameText(EnemyDefs[i].Id, EnemyDefs[j].Id) then Issues.Add('Enemy id "' + EnemyDefs[i].Id + '" is used twice');
    if Geo.Find(EnemyDefs[i].Geometry) < 0 then
      Issues.Add(Format('Enemy %s: geometry "%s" not found', [EnemyDefs[i].Id, EnemyDefs[i].Geometry]));
    if (EnemyDefs[i].DeathSound <> '') and (SoundByName(EnemyDefs[i].DeathSound) < 0) then
      Issues.Add(Format('Enemy %s: unknown sound "%s"', [EnemyDefs[i].Id, EnemyDefs[i].DeathSound]));
    groups := EnemyUsage(i, spawned);
    if groups = 0 then Issues.Add(Format('Enemy %s never appears in any wave', [EnemyDefs[i].Id]));
  end;
  if Geo.Find(FireSpell.Geometry) < 0 then Issues.Add('Rain of Fire geometry not found');
  if Geo.Find(Reinf.Geometry) < 0 then Issues.Add('Reinforcements geometry not found');
  if Geo.Find(SoldierRules.Geometry) < 0 then Issues.Add('Soldier geometry not found');
  if Hero.Enabled then
  begin
    if Geo.Find(Hero.Geometry) < 0 then Issues.Add('Hero geometry "' + Hero.Geometry + '" not found');
    if Geo.Find(Hero.Hammer.Geometry) < 0 then Issues.Add('Hero projectile "' + Hero.Hammer.Geometry + '" not found');
    if (Hero.Slam.Sound <> '') and (SoundByName(Hero.Slam.Sound) < 0) then Issues.Add('Hero: unknown sound ' + Hero.Slam.Sound);
    if (Hero.Hammer.Sound <> '') and (SoundByName(Hero.Hammer.Sound) < 0) then Issues.Add('Hero: unknown sound ' + Hero.Hammer.Sound);
    for i := 1 to High(Hero.Levels) do
      if Hero.Levels[i].Xp <= Hero.Levels[i - 1].Xp then
        Issues.Add(Format('Hero level %d needs no more xp than level %d', [i + 1, i]));
  end;
end;

{ ======================================================================
  widgets
  ====================================================================== }

procedure ValueCell(x, y, w: Single; const key: string; kind: TPropKind);
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
    DrawText(x + 5, y + 3, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
    Exit;
  end;
  if hover then FillRect(x, y + 1, w, ROW_H - 3, RGBA(62, 66, 78))
  else FillRect(x, y + 1, w, ROW_H - 3, RGBA(34, 36, 42));
  if kind in [pkNum, pkInt] then txt := FmtNum(GetNum(key)) else txt := GetStr(key);
  case kind of
    pkBool:
      begin
        RoundRect(x + 4, y + 4, 15, 14, 3, RGBA(22, 24, 28));
        if txt = 'yes' then FillRect(x + 8, y + 8, 7, 6, C_ACCENT);
      end;
    pkEnum: DrawText(x + 5, y + 3, '< ' + txt + ' >', RGBA(160, 210, 255), fnSmall, ALIGN_LEFT, False);
    pkSound:
      begin
        if (txt <> '') and (SoundByName(txt) < 0) then c := RGBA(255, 110, 100) else c := RGBA(160, 210, 255);
        DrawText(x + 5, y + 3, '< ' + IfThen(txt = '', '(none)', txt) + ' >', c, fnSmall, ALIGN_LEFT, False);
        FillTri(x + w - 16, y + 5, x + w - 16, y + 17, x + w - 6, y + 11, RGBA(140, 220, 140));
      end;
    pkColor:
      begin
        Swatch(x + 4, y + 4, 26, 14, ParseColor(txt, RGBA(0, 0, 0)));
        DrawText(x + 36, y + 3, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
      end;
  else
    begin
      if (kind = pkEnum) or ((key = 'geometry') and (Geo.Find(txt) < 0)) then c := RGBA(255, 110, 100) else c := C_TEXT;
      DrawText(x + 5, y + 3, txt, c, fnSmall, ALIGN_LEFT, False);
    end;
  end;
  if hover and (WheelY <> 0) and (kind in [pkNum, pkInt]) and (Drag = drNone) then
  begin
    PushUndo;
    SetNum(key, GetNum(key) + WheelY * NumStep(key));
    WheelY := 0;
  end;
  if hover and (LDown or RDown) and not Consumed then
  begin
    Consumed := True;
    EndEdit(True);
    case kind of
      pkText: if LDown then BeginEdit(key, GetStr(key));
      pkColor: if LDown then BeginEdit(key, GetStr(key));
      pkBool:
        if LDown then
        begin
          PushUndo;
          SetStr(key, '');
        end;
      pkEnum: if LDown then CycleOption(key, 1) else CycleOption(key, -1);
      pkSound:
        if LDown and (MX > x + w - 22) then PlaySoundIdx(SoundByName(GetStr(key)), 1, 0)
        else if LDown then CycleOption(key, 1)
        else CycleOption(key, -1);
      pkNum, pkInt:
        if LDown then
        begin
          Drag := drScrub;
          ScrubKey := key;
          ScrubStart := GetNum(key);
          DragStartX := MX;
          ScrubMoved := False;
          DragUndoPushed := False;
        end;
    end;
  end;
end;

{ ======================================================================
  panels
  ====================================================================== }

procedure DrawToolbar;
var
  x: Single;
  i: Integer;
  t, e, r, w: Boolean;

  function TB(wd: Single; const caption: string; active: Boolean = False; enabled: Boolean = True): Boolean;
  begin
    Result := Button(x, 8, wd, 28, caption, active, enabled);
    x := x + wd + 4;
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
  for i := 0 to 3 do
    if TB(72, TabNames[i], Tab = i) then
    begin
      EndEdit(True);
      Tab := i;
      Sel := EnsureRange(Sel, 0, Max(0, ItemCount - 1));
      PropScroll := 0;
      ListScroll := 0;
    end;
  Gap;
  if TB(56, 'Save', False, IsModified) then SaveAll;
  if TB(64, 'Reload') and ConfirmDiscard then ReloadAll;
  Gap;
  if TB(52, 'Undo', False, Length(UndoStack) > 0) then DoUndo;
  if TB(52, 'Redo', False, Length(RedoStack) > 0) then DoRedo;
  Gap;
  DrawText(x, 13, 'analysis wave', C_DIM, fnSmall, ALIGN_LEFT, False);
  x := x + 98;
  if TB(26, '-') then AnaWave := Max(1, AnaWave - 1);
  DrawText(x + 14, 13, IntToStr(AnaWave), C_TEXT, fnSmall, ALIGN_CENTER, False);
  x := x + 30;
  if TB(26, '+') then AnaWave := Min(TotalWaves, AnaWave + 1);
  Gap;
  if TB(170, Format('Play test wave %d (F5)', [AnaWave])) then PlayTest;
  if Dirty(t, e, r, w) then
    DrawText(WIN_W - 10, 13, 'unsaved:' + IfThen(t, ' towers', '') + IfThen(e, ' enemies', '') +
      IfThen(r, ' rules', '') + IfThen(w, ' waves', '') + IfThen(HeroDirty, ' hero', ''), RGBA(255, 150, 120), fnSmall,
      ALIGN_RIGHT, False);
end;

procedure DrawList;
var
  i, n, visible: Integer;
  y: Single;
  k: Integer;
const
  sections: array[0..4] of string = ('Economy', 'Enemy scaling', 'Rain of Fire', 'Reinforcements', 'Barracks soldiers');
begin
  FillRect(0, TOP_H, LEFT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
  FillRect(LEFT_W - 1, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  if Tab = TAB_HERO then
  begin
    DrawText(10, TOP_H + 6, 'HERO', C_ACCENT, fnSmall, ALIGN_LEFT, False);
    GeoIcon(Hero.Geometry, LEFT_W / 2, TOP_H + 110, 110, True, PrevLevel);
    DrawText(LEFT_W / 2, TOP_H + 176, Hero.Name, C_TEXT, fnMedium, ALIGN_CENTER, False);
    DrawText(LEFT_W / 2, TOP_H + 204, Format('%d levels', [Length(Hero.Levels)]), C_DIM, fnSmall, ALIGN_CENTER, False);
    if not Hero.Enabled then
      DrawText(LEFT_W / 2, TOP_H + 224, 'disabled - no hero in game', RGBA(255, 140, 100), fnSmall, ALIGN_CENTER, False);
    DrawText(10, TOP_H + 260, 'One hero per game.', C_DIM, fnSmall, ALIGN_LEFT, False);
    DrawText(10, TOP_H + 278, 'In game: click him or press H,', C_DIM, fnSmall, ALIGN_LEFT, False);
    DrawText(10, TOP_H + 296, 'then click where he should go.', C_DIM, fnSmall, ALIGN_LEFT, False);
    DrawText(10, TOP_H + 314, 'Keys 3 / 4 cast his abilities.', C_DIM, fnSmall, ALIGN_LEFT, False);
    DrawText(10, TOP_H + 350, 'Spawn point: "heroSpawn" in', C_DIM, fnSmall, ALIGN_LEFT, False);
    DrawText(10, TOP_H + 368, 'the map file; default is 72%', C_DIM, fnSmall, ALIGN_LEFT, False);
    DrawText(10, TOP_H + 386, 'along road 0.', C_DIM, fnSmall, ALIGN_LEFT, False);
    Exit;
  end;
  if Tab = TAB_RULES then
  begin
    DrawText(10, TOP_H + 6, 'SECTIONS', C_ACCENT, fnSmall, ALIGN_LEFT, False);
    for i := 0 to High(sections) do
      if Button(8, TOP_H + 30 + i * 32, LEFT_W - 16, 28, sections[i]) then
      begin
        BuildRows;
        for k := 0 to High(Rows) do
          if (Rows[k].Kind = pkHeader) and (Rows[k].Caption = sections[i]) then PropScroll := k;
      end;
    DrawText(10, TOP_H + 200, 'Global rules, spells and soldier', C_DIM, fnSmall, ALIGN_LEFT, False);
    DrawText(10, TOP_H + 218, 'mechanics from rules.json.', C_DIM, fnSmall, ALIGN_LEFT, False);
    Exit;
  end;
  DrawText(10, TOP_H + 6, Format('%s (%d)', [UpperCase(TabNames[Tab]), ItemCount]), C_ACCENT, fnSmall,
    ALIGN_LEFT, False);
  visible := (WIN_H - STATUS_H - TOP_H - 30 - 70) div 52;
  if Inside(0, TOP_H + 28, LEFT_W, visible * 52) and (WheelY <> 0) then
  begin
    ListScroll := ListScroll - Round(WheelY);
    WheelY := 0;
  end;
  if Sel >= ListScroll + visible then ListScroll := Sel - visible + 1;
  if Sel < ListScroll then ListScroll := Sel;
  ListScroll := EnsureRange(ListScroll, 0, Max(0, ItemCount - visible));
  n := 0;
  for i := ListScroll to ItemCount - 1 do
  begin
    if n >= visible then Break;
    y := TOP_H + 28 + n * 52;
    Inc(n);
    if i = Sel then RoundRect(6, y, LEFT_W - 13, 49, 5, C_SEL)
    else if Inside(6, y, LEFT_W - 13, 49) then RoundRect(6, y, LEFT_W - 13, 49, 5, C_PANEL2);
    if Tab = TAB_TOWERS then
    begin
      GeoIcon(TowerDefs[i].Geometry, 32, y + 25, 40, False, 1);
      DrawText(60, y + 6, TowerDefs[i].Name, C_TEXT, fnSmall, ALIGN_LEFT, False);
      DrawText(60, y + 25, TowerDefs[i].Id + ' - ' + BehaviorName(TowerDefs[i].Behavior), C_DIM, fnSmall,
        ALIGN_LEFT, False);
    end
    else
    begin
      GeoIcon(EnemyDefs[i].Geometry, 32, y + 25, 36, True);
      DrawText(60, y + 6, EnemyDefs[i].Name, C_TEXT, fnSmall, ALIGN_LEFT, False);
      DrawText(60, y + 25, Format('%s - hp %s', [EnemyDefs[i].Id, FmtNum(EnemyDefs[i].Hp)]), C_DIM, fnSmall,
        ALIGN_LEFT, False);
    end;
    if Inside(6, y, LEFT_W - 13, 49) and LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      Sel := i;
      PropScroll := 0;
      PrevLevel := 1;
    end;
  end;
  y := WIN_H - STATUS_H - 64;
  if Button(8, y, 70, 26, 'Add') then AddItem(False);
  if Button(82, y, 74, 26, 'Duplicate', False, HaveItem) then AddItem(True);
  if Button(160, y, 62, 26, 'Delete', False, ItemCount > 1) then DeleteItem;
  if Button(8, y + 30, 105, 26, 'Move up', False, Sel > 0) then MoveItem(-1);
  if Button(117, y + 30, 105, 26, 'Move down', False, Sel < ItemCount - 1) then MoveItem(1);
end;

procedure DrawLevelTable(y0: Single);
var
  t: TTowerDef;
  i: Integer;
  y, x0: Single;
  bomb, bar: Boolean;
  cols: array of string;
  keys: array of string;
  c: Integer;
  cw: Single;
begin
  t := TowerDefs[Sel];
  bomb := t.Behavior = TB_BOMB;
  bar := t.Behavior = TB_BARRACKS;
  x0 := MID_X + 10;
  DrawText(x0, y0, 'UPGRADE LEVELS (level 1 cost = build price)', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y0 := y0 + 22;
  SetLength(cols, 0);
  SetLength(keys, 0);
  cols := ['range', 'damage', 'interval s'];
  keys := ['range', 'damage', 'rate'];
  if bomb then
  begin
    cols := Concat(cols, ['splash']);
    keys := Concat(keys, ['splash']);
  end;
  if bar then
  begin
    cols := ['range', 'damage', 'soldier hp'];
    keys := ['range', 'damage', 'hp'];
  end;
  cols := Concat(cols, ['cost']);
  keys := Concat(keys, ['cost']);
  cw := (MID_W - 60) / Length(cols);
  DrawText(x0, y0 + 3, 'lvl', C_DIM, fnSmall, ALIGN_LEFT, False);
  for c := 0 to High(cols) do
    DrawText(x0 + 30 + c * cw, y0 + 3, cols[c], C_DIM, fnSmall, ALIGN_LEFT, False);
  for i := 0 to High(t.Levels) do
  begin
    y := y0 + ROW_H * (i + 1);
    if i + 1 = PrevLevel then FillRect(x0 - 4, y, MID_W - 12, ROW_H, RGBA(52, 66, 92));
    DrawText(x0 + 4, y + 3, IntToStr(i + 1), C_TEXT, fnSmall, ALIGN_LEFT, False);
    if Inside(x0 - 4, y, 28, ROW_H) and LDown and not Consumed then
    begin
      Consumed := True;
      PrevLevel := i + 1;
    end;
    for c := 0 to High(keys) do
      ValueCell(x0 + 30 + c * cw, y, cw - 6, 'L' + IntToStr(i) + '.' + keys[c], pkNum);
  end;
  y := y0 + ROW_H * (Length(t.Levels) + 1) + 6;
  if Button(x0, y, 100, 24, '+ Add level') then AddLevel;
  if Button(x0 + 104, y, 120, 24, '- Remove last', False, Length(t.Levels) > 1) then RemoveLevel;
  DrawText(x0 + 234, y + 4, 'click a level number to preview it', C_DIM, fnSmall, ALIGN_LEFT, False);
end;

procedure DrawHeroLevelTable(y0: Single); forward;

procedure DrawProps;
var
  i, n, visible: Integer;
  y, maxY: Single;
  r: TPropRow;
begin
  FillRect(MID_X, TOP_H, MID_W, WIN_H - TOP_H - STATUS_H, C_BG);
  FillRect(RIGHT_X - 1, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  BuildRows;
  if Tab = TAB_HERO then DrawText(MID_X + 10, TOP_H + 6, 'HERO (hero.json)', C_ACCENT, fnSmall, ALIGN_LEFT, False)
  else if Tab = TAB_RULES then DrawText(MID_X + 10, TOP_H + 6, 'RULES (rules.json)', C_ACCENT, fnSmall, ALIGN_LEFT, False)
  else if HaveItem then
    DrawText(MID_X + 10, TOP_H + 6, UpperCase(IfThen(Tab = TAB_TOWERS, TowerDefs[Sel].Name, EnemyDefs[Sel].Name)),
      C_ACCENT, fnSmall, ALIGN_LEFT, False);
  if Tab = TAB_TOWERS then maxY := WIN_H - STATUS_H - 230
  else if Tab = TAB_HERO then maxY := WIN_H - STATUS_H - 200
  else maxY := WIN_H - STATUS_H - 8;
  visible := Trunc((maxY - TOP_H - 28) / ROW_H);
  if Inside(MID_X, TOP_H + 28, MID_W, visible * ROW_H) and (WheelY <> 0) and
    not Inside(MID_X + 190, TOP_H + 28, MID_W, visible * ROW_H) then
  begin
    PropScroll := PropScroll - Round(WheelY) * 2;
    WheelY := 0;
  end;
  PropScroll := EnsureRange(PropScroll, 0, Max(0, Length(Rows) - visible));
  n := 0;
  for i := PropScroll to High(Rows) do
  begin
    if n >= visible then Break;
    r := Rows[i];
    y := TOP_H + 28 + n * ROW_H;
    Inc(n);
    if r.Kind = pkHeader then
    begin
      DrawText(MID_X + 10, y + 5, UpperCase(r.Caption), RGBA(255, 210, 140), fnSmall, ALIGN_LEFT, False);
      FillRect(MID_X + 10, y + ROW_H - 2, MID_W - 20, 1, C_LINE);
      Continue;
    end;
    DrawText(MID_X + 14, y + 3, r.Caption, C_DIM, fnSmall, ALIGN_LEFT, False);
    ValueCell(MID_X + 190, y, MID_W - 200, r.Key, r.Kind);
  end;
  if (Tab = TAB_TOWERS) and HaveItem then DrawLevelTable(WIN_H - STATUS_H - 222);
  if Tab = TAB_HERO then DrawHeroLevelTable(WIN_H - STATUS_H - 192);
end;

{ ---------- right side: preview + analysis ---------- }

procedure DrawTowerPreview(x0, y0, w, h: Single);
var
  t: TTowerDef;
  L: TTowerLevel;
  cx, cy, sc, ex, ey, a, f, muzX, muzY: Single;
  st: TAnimState;
  g, eg, i: Integer;
begin
  t := TowerDefs[Sel];
  PrevLevel := EnsureRange(PrevLevel, 1, Length(t.Levels));
  L := t.Levels[PrevLevel - 1];
  sc := Min(1.0, (h - 40) / (L.Range * 2 * 0.72));
  cx := x0 + w * 0.5;
  cy := y0 + h * 0.55;
  FillRect(x0, y0, w, h, RGBA(112, 74, 46));
  FillEllipse(cx, cy, L.Range * sc, L.Range * 0.72 * sc, RGBA(255, 255, 255, 30));
  Ring(cx, cy, L.Range * sc, L.Range * 0.72 * sc, 2, RGBA(255, 255, 255, 140));
  // dummy target walking around inside the range
  a := PvTarget;
  ex := cx + Cos(a) * L.Range * 0.75 * sc;
  ey := cy + Sin(a) * L.Range * 0.72 * 0.75 * sc;
  eg := Geo.Find('enemy.raider');
  st := DefaultAnimState;
  st.Time := AnimTime;
  st.Walk := AnimTime;
  st.Moving := True;
  if -Sin(a) > 0 then st.Facing := 1 else st.Facing := -1;
  if t.Behavior <> TB_BARRACKS then DrawGeoIdx(Geo, eg, ex, ey, sc * 1.2, st);
  // tower
  g := Geo.Find(t.Geometry);
  st := DefaultAnimState;
  st.Time := AnimTime;
  st.Level := PrevLevel;
  st.Aim := ArcTan2(ey - cy, ex - cx);
  st.SinceFire := PvSinceFire;
  DrawGeoIdx(Geo, Geo.Find('plot.built'), cx, cy, sc * 1.4, st);
  DrawGeoIdx(Geo, g, cx, cy, sc * 1.4, st);
  // projectile in flight
  if (PvShotT >= 0) and (t.Behavior <> TB_BARRACKS) then
  begin
    f := Min(1, PvShotT / 0.35);
    muzX := cx;
    muzY := cy - t.MuzzleY * sc * 1.4;
    st := DefaultAnimState;
    st.Time := AnimTime;
    st.Aim := ArcTan2(ey - 10 - muzY, ex - muzX);
    DrawGeoIdx(Geo, Geo.Find(t.Projectile), muzX + (ex - muzX) * f, muzY + (ey - 10 - muzY) * f - 40 * sc * 4 * f * (1 - f) *
      Ord(t.Behavior <> TB_BOLT), sc * 1.4, st);
  end;
  if t.Behavior = TB_BARRACKS then
  begin
    st := DefaultAnimState;
    st.Time := AnimTime;
    st.Swing := Max(0, 0.25 - Frac(AnimTime / Max(0.1, SoldierRules.AttackRate)) * 0.6);
    for i := 0 to t.Soldiers - 1 do
      DrawGeoIdx(Geo, Geo.Find(SoldierRules.Geometry), cx - 60 * sc + i * 40 * sc, cy + 70 * sc, sc * 1.5, st);
  end;
  // level buttons
  for i := 1 to Length(t.Levels) do
    if Button(x0 + 8 + (i - 1) * 40, y0 + 8, 36, 24, 'L' + IntToStr(i), PrevLevel = i) then PrevLevel := i;
  DrawText(x0 + w - 8, y0 + 10, Format('range %d   every %ss', [Round(L.Range), F1(L.Rate)]), RGBA(255, 255, 255),
    fnSmall, ALIGN_RIGHT, True);
end;

procedure DrawEnemyPreview(x0, y0, w, h: Single);
var
  e: TEnemyDef;
  st: TAnimState;
  cx, cy, sc, hp: Single;
  g: Integer;
begin
  e := EnemyDefs[Sel];
  FillRect(x0, y0, w, h, RGBA(112, 74, 46));
  FillEllipse(x0 + w / 2, y0 + h * 0.78, w * 0.42, 34, RGBA(214, 168, 108));
  g := Geo.Find(e.Geometry);
  sc := 3;
  cx := x0 + w / 2;
  cy := y0 + h * 0.8;
  st := DefaultAnimState;
  st.Time := AnimTime;
  st.Walk := AnimTime;
  st.Moving := PvWalking;
  st.Facing := 1;
  DrawGeoIdx(Geo, g, cx, cy, sc, st);
  // markers: hit point, radius, health bar position as the game uses them
  Ring(cx, cy - e.HitY * sc, e.Radius * sc, e.Radius * sc, 1.5, RGBA(255, 255, 255, 120));
  FillCircle(cx, cy - e.HitY * sc, 3, RGBA(255, 80, 80));
  hp := 0.5 + 0.5 * Sin(AnimTime);
  FillRect(cx - e.BarW * sc / 2 - 1, cy - e.BarY * sc - 1, e.BarW * sc + 2, 5 * sc / 1.5, RGBA(20, 10, 5, 220));
  FillRect(cx - e.BarW * sc / 2, cy - e.BarY * sc, e.BarW * sc * hp, 3 * sc / 1.5, RGBA(90, 220, 60));
  // in-game size
  st.Moving := True;
  DrawGeoIdx(Geo, g, x0 + w - 60, y0 + h - 30, 1, st);
  DrawText(x0 + w - 60, y0 + h - 22, '1:1', RGBA(255, 255, 255), fnSmall, ALIGN_CENTER, True);
  if Button(x0 + 8, y0 + 8, 80, 24, 'Walking', PvWalking) then PvWalking := not PvWalking;
  DrawText(x0 + 10, y0 + h - 22, 'red dot = projectile aim (hitY), ring = radius, bar = health bar position',
    RGBA(255, 255, 255), fnSmall, ALIGN_LEFT, True);
end;

procedure DrawTowerAnalysis(x0, y0, w: Single);
var
  t: TTowerDef;
  L: TTowerLevel;
  i, k, e, n: Integer;
  y, dps, hp, eff, ttk, inRange, bw, bh, maxV, v, x: Single;
  c: TRGBA;
  verdict: string;
begin
  t := TowerDefs[Sel];
  L := t.Levels[PrevLevel - 1];
  DrawText(x0, y0, 'LEVELS', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y0 + 20;
  DrawText(x0, y, 'lvl', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(x0 + 90, y, 'spent', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 150, y, 'sell', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 220, y, 'DPS', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 320, y, 'DPS / 100g', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 400, y, 'range', C_DIM, fnSmall, ALIGN_RIGHT, False);
  for i := 1 to Length(t.Levels) do
  begin
    y := y + 18;
    dps := TowerDps(Sel, i);
    if i = PrevLevel then c := C_TEXT else c := RGBA(170, 175, 185);
    DrawText(x0, y, IntToStr(i), c, fnSmall, ALIGN_LEFT, False);
    DrawText(x0 + 90, y, IntToStr(TowerSpent(Sel, i)), RGBA(255, 215, 60), fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 150, y, IntToStr(Round(TowerSpent(Sel, i) * Rules.SellRatio)), c, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 220, y, F1(dps), c, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 320, y, F1(dps * 100 / Max(1, TowerSpent(Sel, i))), c, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 400, y, IntToStr(Round(t.Levels[i - 1].Range)), c, fnSmall, ALIGN_RIGHT, False);
  end;
  if t.Behavior = TB_BOMB then
    DrawText(x0 + 420, y0 + 38, 'bombs hit every', C_DIM, fnSmall, ALIGN_LEFT, False);
  if t.Behavior = TB_BOMB then
    DrawText(x0 + 420, y0 + 56, 'enemy in the splash', C_DIM, fnSmall, ALIGN_LEFT, False);

  // time to kill vs every enemy at the analysis wave
  y := y + 30;
  DrawText(x0, y, Format('LEVEL %d vs ENEMIES AT WAVE %d (single tower, enemy walking through the middle of the range)',
    [PrevLevel, AnaWave]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  DrawText(x0 + 150, y, 'hp', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 220, y, 'dmg x', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 300, y, 'kill time', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 380, y, 'in range', C_DIM, fnSmall, ALIGN_RIGHT, False);
  dps := TowerDps(Sel, PrevLevel);
  for e := 0 to High(EnemyDefs) do
  begin
    y := y + 22;
    GeoIcon(EnemyDefs[e].Geometry, x0 + 10, y + 8, 20, True);
    DrawText(x0 + 26, y, EnemyDefs[e].Name, C_TEXT, fnSmall, ALIGN_LEFT, False);
    hp := EnemyDefs[e].Hp * HpScale(AnaWave);
    if t.Magic then eff := 1 else eff := 1 - EnemyDefs[e].Armor;
    DrawText(x0 + 150, y, FmtK(hp), C_TEXT, fnSmall, ALIGN_RIGHT, False);
    inRange := 2 * L.Range * 0.8 / Max(1, EnemyDefs[e].Speed);
    if EnemyDefs[e].Flying and not t.HitsAir then
    begin
      DrawText(x0 + 220, y, '-', C_DIM, fnSmall, ALIGN_RIGHT, False);
      DrawText(x0 + 300, y, 'cannot hit', RGBA(255, 110, 100), fnSmall, ALIGN_RIGHT, False);
      DrawText(x0 + 380, y, F1(inRange) + 's', C_DIM, fnSmall, ALIGN_RIGHT, False);
      Continue;
    end;
    DrawText(x0 + 220, y, F1(eff), C_TEXT, fnSmall, ALIGN_RIGHT, False);
    ttk := hp / Max(0.01, dps * eff);
    if ttk <= inRange * 0.6 then begin c := RGBA(120, 220, 110); verdict := 'kills alone'; end
    else if ttk <= inRange then begin c := RGBA(240, 210, 90); verdict := 'just in time'; end
    else begin c := RGBA(255, 110, 100); verdict := Format('needs %.1f towers', [ttk / Max(0.01, inRange)]); end;
    if t.Behavior = TB_BARRACKS then verdict := Format('%.1f hits to drop a soldier',
      [L.SoldierHp / Max(0.1, EnemyDefs[e].Dmg * (1 + Rules.DmgGrowth * AnaWave))]);
    DrawText(x0 + 300, y, F1(ttk) + 's', c, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 380, y, F1(inRange) + 's', C_DIM, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 396, y, verdict, c, fnSmall, ALIGN_LEFT, False);
  end;

  // comparison: DPS per 100 gold for every tower and level
  y := y + 34;
  DrawText(x0, y, 'ALL TOWERS - DPS per 100 gold spent (by level)', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  bh := WIN_H - STATUS_H - y - 30;
  if bh < 40 then Exit;
  maxV := 0.01;
  n := 0;
  for k := 0 to High(TowerDefs) do
    for i := 1 to Length(TowerDefs[k].Levels) do
    begin
      maxV := Max(maxV, TowerDps(k, i) * 100 / Max(1, TowerSpent(k, i)));
      Inc(n);
    end;
  bw := (w - 20) / Max(1, n + Length(TowerDefs));
  x := x0;
  FillRect(x0 - 4, y, w - 8, bh + 22, RGBA(24, 26, 31));
  for k := 0 to High(TowerDefs) do
  begin
    for i := 1 to Length(TowerDefs[k].Levels) do
    begin
      v := TowerDps(k, i) * 100 / Max(1, TowerSpent(k, i));
      c := BarColors[k mod Length(BarColors)];
      if k <> Sel then c := Shade(c, 0.6);
      FillRect(x + 2, y + bh - v / maxV * (bh - 14), bw - 4, v / maxV * (bh - 14), c);
      DrawText(x + bw / 2, y + bh - v / maxV * (bh - 14) - 16, F1(v), C_DIM, fnSmall, ALIGN_CENTER, False);
      x := x + bw;
    end;
    if k = Sel then c := C_TEXT else c := C_DIM;
    DrawText(x - bw * Length(TowerDefs[k].Levels) / 2, y + bh + 3, TowerDefs[k].Id, c, fnSmall, ALIGN_CENTER, False);
    x := x + bw;
  end;
end;

procedure DrawEnemyAnalysis(x0, y0, w: Single);
var
  e: TEnemyDef;
  i, groups, spawned, k, step: Integer;
  y, minLen, maxLen, bh, bw, maxV, v, x: Single;
  c: TRGBA;
begin
  e := EnemyDefs[Sel];
  DrawText(x0, y0, 'DERIVED NUMBERS', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y0 + 22;
  DrawText(x0, y, 'hit points by wave:', C_DIM, fnSmall, ALIGN_LEFT, False);
  x := x0 + 150;
  step := Max(1, TotalWaves div 5);
  i := 1;
  while i <= TotalWaves do
  begin
    DrawText(x, y, Format('w%d: %s', [i, FmtK(e.Hp * HpScale(i))]), C_TEXT, fnSmall, ALIGN_LEFT, False);
    x := x + 88;
    if i = 1 then i := step else Inc(i, step);
    if x > x0 + w - 80 then Break;
  end;
  y := y + 20;
  DrawText(x0, y, Format('effective hp vs arrows/bombs at wave %d: %s  (armor %d%%)', [AnaWave,
    FmtK(e.Hp * HpScale(AnaWave) / Max(0.05, 1 - e.Armor)), Round(e.Armor * 100)]), C_TEXT, fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  DrawText(x0, y, Format('gold per 100 effective hp at wave %d: %s', [AnaWave,
    F1(e.Gold * 100 / Max(1, e.Hp * HpScale(AnaWave) / Max(0.05, 1 - e.Armor)))]), C_TEXT, fnSmall, ALIGN_LEFT, False);
  minLen := 1e9;
  maxLen := 0;
  for i := 0 to High(Paths) do
  begin
    minLen := Min(minLen, Paths[i].Len);
    maxLen := Max(maxLen, Paths[i].Len);
  end;
  y := y + 20;
  DrawText(x0, y, Format('crosses "%s" in %s - %ss (road %d - %d px)', [Map.Name, F1(minLen / Max(1, e.Speed)),
    F1(maxLen / Max(1, e.Speed)), Round(minLen), Round(maxLen)]), C_TEXT, fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  DrawText(x0, y, Format('damage to soldiers at wave %d: %s / hit', [AnaWave, F1(e.Dmg * (1 + Rules.DmgGrowth * AnaWave))]),
    C_TEXT, fnSmall, ALIGN_LEFT, False);
  groups := EnemyUsage(Sel, spawned);
  y := y + 20;
  if groups = 0 then c := RGBA(255, 180, 90) else c := C_TEXT;
  DrawText(x0, y, Format('used in %d wave groups, %d spawns in total', [groups, spawned]), c, fnSmall, ALIGN_LEFT, False);

  // comparison chart
  y := y + 36;
  DrawText(x0, y, Format('ALL ENEMIES AT WAVE %d - effective hp (bars), speed (dots), gold (numbers)', [AnaWave]),
    C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y + 22;
  bh := WIN_H - STATUS_H - y - 34;
  if bh < 40 then Exit;
  FillRect(x0 - 4, y, w - 8, bh + 26, RGBA(24, 26, 31));
  maxV := 1;
  for k := 0 to High(EnemyDefs) do
    maxV := Max(maxV, EnemyDefs[k].Hp * HpScale(AnaWave) / Max(0.05, 1 - EnemyDefs[k].Armor));
  bw := (w - 20) / Max(1, Length(EnemyDefs));
  for k := 0 to High(EnemyDefs) do
  begin
    x := x0 + k * bw;
    v := EnemyDefs[k].Hp * HpScale(AnaWave) / Max(0.05, 1 - EnemyDefs[k].Armor);
    c := BarColors[k mod Length(BarColors)];
    if k <> Sel then c := Shade(c, 0.6);
    FillRect(x + bw * 0.2, y + bh - v / maxV * (bh - 20), bw * 0.6, v / maxV * (bh - 20), c);
    DrawText(x + bw / 2, y + bh - v / maxV * (bh - 20) - 16, FmtK(v), C_DIM, fnSmall, ALIGN_CENTER, False);
    FillCircle(x + bw / 2, y + bh - EnemyDefs[k].Speed / 80 * (bh - 20), 4, RGBA(120, 220, 255));
    if k = Sel then c := C_TEXT else c := C_DIM;
    DrawText(x + bw / 2, y + bh + 4, EnemyDefs[k].Id + '  ' + IntToStr(EnemyDefs[k].Gold) + 'g', c, fnSmall, ALIGN_CENTER, False);
  end;
end;

procedure DrawRulesAnalysis(x0, y0, w: Single);
var
  wv, g, cum, cnt: Integer;
  y, h, bw, x, maxHp, maxG, gx, gy, pgx, pgy: Single;
  rewards: array of Integer;
  lc: TRGBA;
begin
  DrawText(x0, y0, 'ENEMY HP MULTIPLIER BY WAVE (line) AND GOLD REWARD PER WAVE (bars)', C_ACCENT, fnSmall,
    ALIGN_LEFT, False);
  y := y0 + 22;
  h := 210;
  FillRect(x0 - 4, y, w - 8, h + 24, RGBA(24, 26, 31));
  SetLength(rewards, TotalWaves);
  maxG := 1;
  for wv := 0 to High(Waves) do
  begin
    rewards[wv] := 0;
    for g := 0 to High(Waves[wv].Groups) do
      Inc(rewards[wv], Waves[wv].Groups[g].Count * EnemyDefs[Waves[wv].Groups[g].Enemy].Gold);
    maxG := Max(maxG, rewards[wv]);
  end;
  maxHp := HpScale(TotalWaves);
  bw := (w - 30) / TotalWaves;
  pgx := 0; pgy := 0;
  for wv := 0 to High(Waves) do
  begin
    x := x0 + wv * bw;
    FillRect(x + bw * 0.25, y + h - rewards[wv] / maxG * (h - 20), bw * 0.5, rewards[wv] / maxG * (h - 20),
      RGBA(200, 170, 60, 160));
    if wv + 1 = AnaWave then lc := C_TEXT else lc := C_DIM;
    DrawText(x + bw / 2, y + h + 4, IntToStr(wv + 1), lc, fnSmall, ALIGN_CENTER, False);
    gx := x + bw / 2;
    gy := y + h - HpScale(wv + 1) / maxHp * (h - 20);
    if wv > 0 then ThickLine(pgx, pgy, gx, gy, 2.5, RGBA(255, 110, 90));
    FillCircle(gx, gy, 3.5, RGBA(255, 110, 90));
    pgx := gx;
    pgy := gy;
  end;
  DrawText(x0 + 6, y + 4, Format('x%s at wave %d', [F1(maxHp), TotalWaves]), RGBA(255, 110, 90), fnSmall, ALIGN_LEFT, False);

  y := y + h + 40;
  DrawText(x0, y, Format('AT WAVE %d', [AnaWave]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  cum := Rules.StartGold;
  for wv := 0 to AnaWave - 2 do
    if wv <= High(rewards) then Inc(cum, rewards[wv]);
  cnt := 0;
  if AnaWave - 1 <= High(Waves) then
    for g := 0 to High(Waves[AnaWave - 1].Groups) do Inc(cnt, Waves[AnaWave - 1].Groups[g].Count);
  y := y + 22;
  DrawText(x0, y, Format('enemy hp x%s, enemy damage x%s', [F1(HpScale(AnaWave)), F1(1 + Rules.DmgGrowth * AnaWave)]),
    C_TEXT, fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  DrawText(x0, y, Format('gold available before the wave: ~%d (start %d + kills)', [cum, Rules.StartGold]), C_TEXT,
    fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  DrawText(x0, y, Format('%s: %d meteors x %s damage = %s per cast, every %ss', [FireSpell.Name, FireSpell.Meteors,
    F1(FireSpell.DmgBase + AnaWave * FireSpell.DmgPerWave),
    F1(FireSpell.Meteors * (FireSpell.DmgBase + AnaWave * FireSpell.DmgPerWave)), F1(FireSpell.Cooldown)]),
    C_TEXT, fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  DrawText(x0, y, Format('%s: %d militia with %s hp, %s damage, for %ss, every %ss', [Reinf.Name, Reinf.Count,
    F1(Reinf.HpBase + AnaWave * Reinf.HpPerWave), F1(Reinf.DmgBase + AnaWave * Reinf.DmgPerWave),
    F1(Reinf.Lifetime), F1(Reinf.Cooldown)]), C_TEXT, fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  DrawText(x0, y, Format('soldier: %s attacks/s (damage comes from the barracks level), back after %ss',
    [F1(1 / Max(0.05, SoldierRules.AttackRate)), F1(SoldierRules.Respawn)]), C_DIM, fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  DrawText(x0, y, Format('wave %d has %d enemies; next wave every %ss (early call pays up to %d gold)', [AnaWave, cnt,
    F1(Rules.WaveGap), Round(Rules.WaveGap * Rules.EarlyBonusPerSec)]), C_DIM, fnSmall, ALIGN_LEFT, False);
end;

{ ---------- hero tab ---------- }

function HeroDps(lvl: Integer): Single;
var
  L: THeroLevel;
begin
  L := Hero.Levels[EnsureRange(lvl - 1, 0, High(Hero.Levels))];
  Result := L.Damage / Max(0.05, L.Rate);
end;

function HeroAbilityDmg(const a: THeroAbility; lvl: Integer): Single;
begin
  Result := a.Damage + (lvl - 1) * a.DamagePerLevel;
end;

procedure DrawHeroLevelTable(y0: Single);
const
  Cols: array[0..4] of string = ('hp', 'damage', 'interval s', 'armor', 'xp to reach');
  Keys: array[0..4] of string = ('hp', 'damage', 'rate', 'armor', 'xp');
var
  i, c, n: Integer;
  y, x0, cw: Single;
begin
  x0 := MID_X + 10;
  DrawText(x0, y0, 'HERO LEVELS (xp = total needed to reach the level)', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y0 := y0 + 22;
  cw := (MID_W - 60) / Length(Cols);
  DrawText(x0, y0 + 3, 'lvl', C_DIM, fnSmall, ALIGN_LEFT, False);
  for c := 0 to High(Cols) do DrawText(x0 + 30 + c * cw, y0 + 3, Cols[c], C_DIM, fnSmall, ALIGN_LEFT, False);
  for i := 0 to High(Hero.Levels) do
  begin
    y := y0 + ROW_H * (i + 1);
    if i + 1 = PrevLevel then FillRect(x0 - 4, y, MID_W - 12, ROW_H, RGBA(52, 66, 92));
    DrawText(x0 + 4, y + 3, IntToStr(i + 1), C_TEXT, fnSmall, ALIGN_LEFT, False);
    if Inside(x0 - 4, y, 28, ROW_H) and LDown and not Consumed then
    begin
      Consumed := True;
      PrevLevel := i + 1;
    end;
    for c := 0 to High(Keys) do
      ValueCell(x0 + 30 + c * cw, y, cw - 6, 'H' + IntToStr(i) + '.' + Keys[c], pkNum);
  end;
  y := y0 + ROW_H * (Length(Hero.Levels) + 1) + 4;
  n := Length(Hero.Levels);
  if Button(x0, y, 100, 22, '+ Add level') then
  begin
    PushUndo;
    SetLength(Hero.Levels, n + 1);
    Hero.Levels[n] := Hero.Levels[n - 1];
    Hero.Levels[n].Hp := Round(Hero.Levels[n].Hp * 1.15);
    Hero.Levels[n].Damage := Round(Hero.Levels[n].Damage * 1.2);
    Hero.Levels[n].Xp := Round(Hero.Levels[n].Xp * 1.6 + 100);
    PrevLevel := n + 1;
  end;
  if Button(x0 + 104, y, 120, 22, '- Remove last', False, n > 1) then
  begin
    PushUndo;
    SetLength(Hero.Levels, n - 1);
    PrevLevel := Min(PrevLevel, n - 1);
  end;
end;

procedure DrawHeroPreview(x0, y0, w, h: Single);
var
  st: TAnimState;
  cx, cy, sc: Single;
  i: Integer;
begin
  PrevLevel := EnsureRange(PrevLevel, 1, Max(1, Length(Hero.Levels)));
  FillRect(x0, y0, w, h, RGBA(112, 74, 46));
  sc := 0.62;
  cx := x0 + w * 0.5;
  cy := y0 + h * 0.62;
  FillEllipse(cx, cy, w * 0.46, 46, RGBA(214, 168, 108));
  // ability ranges at the same scale as the game would show them (shrunk to fit)
  Ring(cx, cy, Hero.Hammer.Radius * sc, Hero.Hammer.Radius * 0.72 * sc, 1.5, RGBA(140, 210, 255, 150));
  Ring(cx, cy, Hero.Slam.Radius * sc, Hero.Slam.Radius * 0.72 * sc, 2, RGBA(255, 220, 150, 200));
  Ring(cx, cy, Hero.Engage * sc, Hero.Engage * 0.72 * sc, 1.5, RGBA(120, 255, 140, 150));
  st := DefaultAnimState;
  st.Time := AnimTime;
  st.Walk := AnimTime;
  st.Moving := PvWalking;
  st.Level := PrevLevel;
  st.Swing := Max(0, 0.25 - Frac(AnimTime / Max(0.1, Hero.Levels[PrevLevel - 1].Rate)) * 0.6);
  DrawGeoIdx(Geo, Geo.Find(Hero.Geometry), cx, cy, 2.4, st);
  st.Moving := True;
  DrawGeoIdx(Geo, Geo.Find(Hero.Geometry), x0 + w - 50, y0 + h - 26, 1, st);
  DrawText(x0 + w - 50, y0 + h - 20, '1:1', RGBA(255, 255, 255), fnSmall, ALIGN_CENTER, True);
  st := DefaultAnimState;
  st.Time := AnimTime;
  DrawGeoIdx(Geo, Geo.Find(Hero.Hammer.Geometry), x0 + 60, y0 + h - 40, 2, st);
  for i := 1 to Length(Hero.Levels) do
    if Button(x0 + 8 + (i - 1) * 40, y0 + 8, 36, 24, 'L' + IntToStr(i), PrevLevel = i) then PrevLevel := i;
  if Button(x0 + 8 + Length(Hero.Levels) * 40 + 8, y0 + 8, 76, 24, 'Walking', PvWalking) then PvWalking := not PvWalking;
  DrawText(x0 + 10, y0 + 40, 'green = engage range   gold = slam radius   blue = throw range (scaled to fit)',
    RGBA(255, 255, 255), fnSmall, ALIGN_LEFT, True);
end;

procedure DrawHeroAnalysis(x0, y0, w: Single);
var
  i, e, wv, g, cum, lvl, gold: Integer;
  y, hp, dmgIn, ttk, survive, bh, bw, x: Single;
  c: TRGBA;
  L: THeroLevel;
begin
  DrawText(x0, y0, 'LEVELS', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y0 + 20;
  DrawText(x0, y, 'lvl', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(x0 + 80, y, 'xp', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 140, y, 'DPS', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 230, y, 'effective hp', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 330, y, Hero.Slam.Name, C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 450, y, Hero.Hammer.Name, C_DIM, fnSmall, ALIGN_RIGHT, False);
  for i := 1 to Length(Hero.Levels) do
  begin
    y := y + 18;
    L := Hero.Levels[i - 1];
    if i = PrevLevel then c := C_TEXT else c := RGBA(170, 175, 185);
    DrawText(x0, y, IntToStr(i), c, fnSmall, ALIGN_LEFT, False);
    DrawText(x0 + 80, y, IntToStr(L.Xp), RGBA(110, 180, 255), fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 140, y, F1(HeroDps(i)), c, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 230, y, IntToStr(Round(L.Hp / Max(0.05, 1 - L.Armor))), c, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 330, y, IntToStr(Round(HeroAbilityDmg(Hero.Slam, i))), c, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 450, y, IntToStr(Round(HeroAbilityDmg(Hero.Hammer, i))), c, fnSmall, ALIGN_RIGHT, False);
  end;

  // duels against every enemy at the analysis wave
  y := y + 30;
  L := Hero.Levels[PrevLevel - 1];
  DrawText(x0, y, Format('LEVEL %d HERO vs ONE ENEMY AT WAVE %d (melee, no abilities)', [PrevLevel, AnaWave]), C_ACCENT,
    fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  DrawText(x0 + 160, y, 'kill time', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 250, y, 'dmg taken', C_DIM, fnSmall, ALIGN_RIGHT, False);
  DrawText(x0 + 340, y, 'hero hp left', C_DIM, fnSmall, ALIGN_RIGHT, False);
  for e := 0 to High(EnemyDefs) do
  begin
    y := y + 22;
    GeoIcon(EnemyDefs[e].Geometry, x0 + 10, y + 8, 20, True);
    DrawText(x0 + 26, y, EnemyDefs[e].Name, C_TEXT, fnSmall, ALIGN_LEFT, False);
    if EnemyDefs[e].Flying then
    begin
      DrawText(x0 + 160, y, 'flies over', C_DIM, fnSmall, ALIGN_RIGHT, False);
      DrawText(x0 + 356, y, Format('use %s (%d dmg)', [Hero.Hammer.Name, Round(HeroAbilityDmg(Hero.Hammer, PrevLevel))]),
        C_DIM, fnSmall, ALIGN_LEFT, False);
      Continue;
    end;
    hp := EnemyDefs[e].Hp * HpScale(AnaWave);
    ttk := hp / Max(0.01, HeroDps(PrevLevel) * (1 - EnemyDefs[e].Armor));
    dmgIn := EnemyDefs[e].Dmg * (1 + Rules.DmgGrowth * AnaWave) * (1 - L.Armor) * Ceil(ttk);
    survive := L.Hp - dmgIn;
    if survive > L.Hp * 0.5 then c := RGBA(120, 220, 110)
    else if survive > 0 then c := RGBA(240, 210, 90)
    else c := RGBA(255, 110, 100);
    DrawText(x0 + 160, y, F1(ttk) + 's', c, fnSmall, ALIGN_RIGHT, False);
    DrawText(x0 + 250, y, IntToStr(Round(dmgIn)), C_TEXT, fnSmall, ALIGN_RIGHT, False);
    if survive > 0 then
      DrawText(x0 + 340, y, Format('%d%%', [Round(survive / L.Hp * 100)]), c, fnSmall, ALIGN_RIGHT, False)
    else
      DrawText(x0 + 340, y, 'loses', c, fnSmall, ALIGN_RIGHT, False);
  end;

  // expected level per wave if the hero is credited with about a third of the kills
  y := y + 34;
  DrawText(x0, y, 'EXPECTED HERO LEVEL BY WAVE (hero credited with ~1/3 of kill xp)', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y + 20;
  bh := WIN_H - STATUS_H - y - 30;
  if bh < 30 then Exit;
  FillRect(x0 - 4, y, w - 8, bh + 24, RGBA(24, 26, 31));
  bw := (w - 20) / TotalWaves;
  cum := 0;
  for wv := 0 to High(Waves) do
  begin
    gold := 0;
    for g := 0 to High(Waves[wv].Groups) do
      Inc(gold, Waves[wv].Groups[g].Count * EnemyDefs[Waves[wv].Groups[g].Enemy].Gold);
    Inc(cum, Round(gold * Hero.XpPerGold * 0.35));
    lvl := 1;
    while (lvl < Length(Hero.Levels)) and (cum >= Hero.Levels[lvl].Xp) do Inc(lvl);
    x := x0 + wv * bw;
    c := BarColors[(lvl - 1) mod Length(BarColors)];
    if wv + 1 <> AnaWave then c := Shade(c, 0.7);
    FillRect(x + bw * 0.2, y + bh - lvl / Length(Hero.Levels) * (bh - 14), bw * 0.6, lvl / Length(Hero.Levels) * (bh - 14), c);
    DrawText(x + bw / 2, y + bh - lvl / Length(Hero.Levels) * (bh - 14) - 16, IntToStr(lvl), C_DIM, fnSmall,
      ALIGN_CENTER, False);
    DrawText(x + bw / 2, y + bh + 4, IntToStr(wv + 1), C_DIM, fnSmall, ALIGN_CENTER, False);
  end;
end;

procedure DrawRight;
var
  i: Integer;
  y: Single;
begin
  FillRect(RIGHT_X, TOP_H, RIGHT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
  if (Tab = TAB_TOWERS) and HaveItem then
  begin
    DrawTowerPreview(RIGHT_X + 10, TOP_H + 10, RIGHT_W - 20, PREVIEW_H);
    DrawTowerAnalysis(RIGHT_X + 14, TOP_H + PREVIEW_H + 22, RIGHT_W - 20);
  end
  else if (Tab = TAB_ENEMIES) and HaveItem then
  begin
    DrawEnemyPreview(RIGHT_X + 10, TOP_H + 10, RIGHT_W - 20, PREVIEW_H);
    DrawEnemyAnalysis(RIGHT_X + 14, TOP_H + PREVIEW_H + 22, RIGHT_W - 20);
  end
  else if Tab = TAB_HERO then
  begin
    DrawHeroPreview(RIGHT_X + 10, TOP_H + 10, RIGHT_W - 20, PREVIEW_H);
    DrawHeroAnalysis(RIGHT_X + 14, TOP_H + PREVIEW_H + 22, RIGHT_W - 20);
  end
  else if Tab = TAB_RULES then
  begin
    DrawRulesAnalysis(RIGHT_X + 14, TOP_H + 10, RIGHT_W - 20);
    // issues list
    y := TOP_H + 470;
    FillRect(RIGHT_X, y - 8, RIGHT_W, 1, C_LINE);
    if Issues.Count = 0 then
      DrawText(RIGHT_X + 14, y, 'CHECKS: all good', RGBA(120, 220, 120), fnSmall, ALIGN_LEFT, False)
    else
      DrawText(RIGHT_X + 14, y, Format('CHECKS: %d issue(s)', [Issues.Count]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
    for i := 0 to Issues.Count - 1 do
    begin
      y := y + 20;
      if y > WIN_H - STATUS_H - 24 then Break;
      FillCircle(RIGHT_X + 20, y + 9, 4, RGBA(255, 160, 80));
      DrawText(RIGHT_X + 30, y, Issues[i], C_TEXT, fnSmall, ALIGN_LEFT, False);
    end;
  end;
end;

{ ======================================================================
  input
  ====================================================================== }

procedure UpdateDrags;
var
  v: Single;
begin
  if Drag <> drScrub then Exit;
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
      v := ScrubStart + Round((MX - DragStartX) / 4) * NumStep(ScrubKey);
      SetNum(ScrubKey, v);
    end;
  end
  else
  begin
    if not ScrubMoved then BeginEdit(ScrubKey, FmtNum(GetNum(ScrubKey)));
    Drag := drNone;
  end;
end;

procedure HandleKey(key: TSDL_Keycode);
begin
  if EditKey <> '' then
  begin
    case key of
      SDLK_RETURN: EndEdit(True);
      SDLK_ESCAPE: EndEdit(False);
      SDLK_BACKSPACE: if EditBuf <> '' then Delete(EditBuf, Length(EditBuf), 1);
    end;
    Exit;
  end;
  if ModCtrl then
  begin
    case key of
      SDLK_S: SaveAll;
      SDLK_Z: if ModShift then DoRedo else DoUndo;
      SDLK_Y: DoRedo;
      SDLK_D: AddItem(True);
    end;
    Exit;
  end;
  case key of
    SDLK_UP: Sel := Max(0, Sel - 1);
    SDLK_DOWN: Sel := Min(ItemCount - 1, Sel + 1);
    SDLK_TAB:
      begin
        Tab := (Tab + 1) mod 4;
        Sel := EnsureRange(Sel, 0, Max(0, ItemCount - 1));
        PropScroll := 0;
      end;
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
  ShotFile: string;
  ShotFrames, ArgI: Integer;
  s: TSound;
  L: TTowerLevel;
  SndName: string;

begin
  DataDir := ExtractFilePath(ParamStr(0)) + 'data' + PathDelim;
  Issues := TStringList.Create;

  if not SDL_Init(SDL_INIT_VIDEO) then Halt(1);
  if not SDL_CreateWindowAndRenderer('StatEdit', WIN_W, WIN_H, SDL_WINDOW_RESIZABLE, @Window, @Renderer) then
  begin
    SDL_Quit;
    Halt(1);
  end;
  SDL_SetWindowMinimumSize(Window, 960, 600);
  SDL_SetRenderVSync(Renderer, 1);
  SDL_SetRenderDrawBlendMode(Renderer, SDL_BLENDMODE_BLEND);
  SDL_SetRenderLogicalPresentation(Renderer, WIN_W, WIN_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
  GfxInit(Renderer);
  SfxInit;
  // every sound in data\sounds.json (built-in and custom ones made in SoundEdit)
  SetLength(SoundNames, SoundCount);
  for ArgI := 0 to SoundCount - 1 do SoundNames[ArgI] := SoundNameOf(ArgI);
  if not ReloadAll then
  begin
    SDL_Quit;
    Halt(1);
  end;

  if (ParamCount >= 2) and (ParamStr(1) = '--selftest') then
  begin
    // exercise the enemy list operations and dump the results (waves must stay consistent)
    Tab := TAB_ENEMIES;
    Sel := 0;
    SetStr('id', 'raider_renamed');
    MoveItem(1);                    // raider moves to index 1, runner to 0
    AddItem(True);                  // duplicate -> unused enemy at the end
    DeleteItem;                     // unused: allowed
    Sel := 0;
    DeleteItem;                     // used by waves: must be refused
    SaveTextFile(ParamStr(2) + PathDelim + 'enemies_test.json', EnemiesToJSON);
    for ArgI := 0 to High(WaveSets) do
      SaveTextFile(ParamStr(2) + PathDelim + 'test_' + WaveSets[ArgI].FileName, WavesToJSON(WaveSets[ArgI].W));
    SaveTextFile(ParamStr(2) + PathDelim + 'status_test.txt', StatusMsg);
    SDL_Quit;
    Halt(0);
  end;
  ShotFile := '';
  for ArgI := 1 to ParamCount - 1 do
    if ParamStr(ArgI) = '--shot' then
    begin
      ShotFile := ParamStr(ArgI + 1);
      SoundMuted := True;
      if ArgI + 2 <= ParamCount then Tab := EnsureRange(StrToIntDef(ParamStr(ArgI + 2), 1) - 1, 0, 3);
      if ArgI + 3 <= ParamCount then Sel := EnsureRange(StrToIntDef(ParamStr(ArgI + 3), 0), 0, Max(0, ItemCount - 1));
      if Tab = TAB_TOWERS then PrevLevel := 2;
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
    if ShotFile <> '' then Dt := 0.05;
    Last := Now_;
    AnimTime := AnimTime + Dt;
    SfxUpdate(Dt);
    if StatusTime > 0 then StatusTime := StatusTime - Dt;
    Sel := EnsureRange(Sel, 0, Max(0, ItemCount - 1));
    UpdateDrags;
    Validate;

    // tower preview: target circles, tower fires at its real interval
    PvTarget := PvTarget + Dt * 0.6;
    PvSinceFire := PvSinceFire + Dt;
    if PvShotT >= 0 then
    begin
      PvShotT := PvShotT + Dt;
      if PvShotT > 0.35 then PvShotT := -1;
    end;
    if (Tab = TAB_TOWERS) and HaveItem then
    begin
      L := TowerDefs[Sel].Levels[EnsureRange(PrevLevel - 1, 0, High(TowerDefs[Sel].Levels))];
      PvFireT := PvFireT + Dt;
      if PvFireT >= L.Rate then
      begin
        PvFireT := 0;
        PvSinceFire := 0;
        PvShotT := 0;
      end;
    end;

    SDL_SetRenderDrawColor(Renderer, C_BG.r, C_BG.g, C_BG.b, 255);
    SDL_RenderClear(Renderer);
    DrawToolbar;
    DrawList;
    DrawProps;
    DrawRight;
    FillRect(0, WIN_H - STATUS_H, WIN_W, STATUS_H, C_PANEL);
    FillRect(0, WIN_H - STATUS_H, WIN_W, 1, C_LINE);
    if StatusTime > 0 then
      DrawText(10, WIN_H - STATUS_H + 3, StatusMsg, C_ACCENT, fnSmall, ALIGN_LEFT, False)
    else if Issues.Count > 0 then
      DrawText(10, WIN_H - STATUS_H + 3, Format('%d check(s) failed - see the Rules tab. First: %s', [Issues.Count,
        Issues[0]]), RGBA(255, 170, 90), fnSmall, ALIGN_LEFT, False)
    else
      DrawText(10, WIN_H - STATUS_H + 3, 'Numbers: drag / click / wheel  |  enums & sounds: click / right-click  |  ' +
        'Tab next tab  |  Ctrl+S save  |  Ctrl+Z/Y undo/redo  |  F5 play test', C_DIM, fnSmall, ALIGN_LEFT, False);
    if ShotFile <> '' then
    begin
      Inc(ShotFrames);
      if ShotFrames = 45 then
      begin
        SaveShot(ShotFile);
        Running := False;
      end;
    end;
    SDL_RenderPresent(Renderer);
    if IsModified then SDL_SetWindowTitle(Window, 'StatEdit - towers / enemies / rules *')
    else SDL_SetWindowTitle(Window, 'StatEdit - towers / enemies / rules');
  end;

  Issues.Free;
  SfxDone;
  GfxDone;
  SDL_DestroyRenderer(Renderer);
  SDL_DestroyWindow(Window);
  SDL_Quit;
end.
