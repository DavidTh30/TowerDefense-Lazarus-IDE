program SoundEdit;

{ SoundEdit - sound effect editor for Brewhold Defense (Lazarus / Free Pascal + SDL3)

  Edits data\sounds.json. Every effect is a stack of synthesized layers (tone / noise / metal / grunt,
  see synth.pas) that are mixed, low-passed and normalized. Changes are re-rendered instantly.

  Layout
    left ...... sound list (lock = used directly by game code; can be edited but not deleted / renamed)
    middle .... sound properties and its layers (add / duplicate / delete / reorder)
    right ..... waveform + layer timeline (drag a bar to move a layer in time) and the layer properties
  Editing: numbers - drag sideways / click to type / wheel; enums - click / right-click
  Keys: Space play   Ctrl+S save   Ctrl+Z / Ctrl+Y undo / redo   Up / Down select sound   Del delete layer
        Ctrl+D duplicate layer   A toggle auto-play on change
  New sounds can be used by towers / enemies / hero abilities through StatEdit.
  Test hook: soundedit --shot <file.bmp> [sound name] }

{$mode objfpc}{$H+}
{$APPTYPE GUI}

uses
  SDL3, SysUtils, Math, StrUtils, Classes, gfx, ui, synth, sfx;

const
  WIN_W = 1440;
  WIN_H = 900;
  TOP_H = 44;
  LEFT_W = 230;
  MID_W = 470;
  STATUS_H = 24;
  MID_X = LEFT_W;
  RIGHT_X = LEFT_W + MID_W;
  RIGHT_W = WIN_W - RIGHT_X;
  ROW_H = 23;
  WAVE_Y = TOP_H + 30;
  WAVE_H = 200;
  TL_Y = WAVE_Y + WAVE_H + 8;
  TL_H = 150;
  MAX_UNDO = 300;

  LayerColors: array[TLayerKind] of TRGBA = (
    (r: 110; g: 180; b: 255; a: 255), (r: 230; g: 200; b: 120; a: 255),
    (r: 190; g: 200; b: 215; a: 255), (r: 230; g: 120; b: 100; a: 255));

type
  TPropKind = (pkNum, pkText, pkEnum, pkInfo, pkHeader);
  TPropRow = record
    Key, Caption: string;
    Kind: TPropKind;
  end;
  TUndoEntry = record
    Json: string;
    Sel, Layer: Integer;
  end;
  TDrag = (drNone, drScrub, drLayer);

var
  Window: PSDL_Window;
  Renderer: PSDL_Renderer;
  DataFile: string;
  Defs: TSoundArray;
  SavedJson: string;
  Sel: Integer = 0;
  SelLayer: Integer = 0;
  Rendered: TBuf;
  RenderedFor: string = '';
  AutoPlay: Boolean = True;
  PlayStart: UInt64 = 0;
  PlayLen: Single = 0;
  ListScroll: Integer = 0;
  UndoStack, RedoStack: array of TUndoEntry;
  Drag: TDrag = drNone;
  DragStartX, ScrubStart, DragStartAt: Single;
  ScrubKey: string;
  ScrubMoved, DragUndoPushed, PlayAfterDrag: Boolean;
  EditKey: string = '';
  EditBuf: string = '';
  StatusMsg: string = '';
  StatusTime: Single = 0;
  Rows, LRows: array of TPropRow;

{ ---------- helpers ---------- }

procedure Status(const s: string);
begin
  StatusMsg := s;
  StatusTime := 6;
end;

function HaveSound: Boolean;
begin
  Result := (Sel >= 0) and (Sel <= High(Defs));
end;

function HaveLayer: Boolean;
begin
  Result := HaveSound and (SelLayer >= 0) and (SelLayer <= High(Defs[Sel].Layers));
end;

function Modified: Boolean;
begin
  Result := SoundsToJSON(Defs) <> SavedJson;
end;

procedure RenderCurrent;
var
  key: string;
begin
  if not HaveSound then
  begin
    SetLength(Rendered, 0);
    Exit;
  end;
  key := SoundsToJSON(Copy(Defs, Sel, 1));
  if key = RenderedFor then Exit;
  Rendered := RenderSound(Defs[Sel]);
  RenderedFor := key;
end;

procedure PlayCurrent;
begin
  RenderCurrent;
  if Length(Rendered) = 0 then Exit;
  StopAllSounds;
  PlayBuffer(Rendered, 1.0 / Max(0.01, MasterVolume));
  PlayStart := SDL_GetTicks;
  PlayLen := Length(Rendered) / RATE;
end;

procedure Changed;
begin
  RenderedFor := '';
  if AutoPlay and (Drag = drNone) then PlayCurrent
  else if Drag <> drNone then PlayAfterDrag := True;
end;

{ ---------- undo / files ---------- }

function Snapshot: TUndoEntry;
begin
  Result.Json := SoundsToJSON(Defs);
  Result.Sel := Sel;
  Result.Layer := SelLayer;
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
  a: TSoundArray;
  err: string;
begin
  if not SoundsFromJSONText(e.Json, a, err) then Exit;
  Defs := a;
  Sel := EnsureRange(e.Sel, 0, High(Defs));
  SelLayer := e.Layer;
  RenderedFor := '';
end;

procedure DoUndo;
begin
  if Length(UndoStack) = 0 then Exit;
  SetLength(RedoStack, Length(RedoStack) + 1);
  RedoStack[High(RedoStack)] := Snapshot;
  Restore(UndoStack[High(UndoStack)]);
  SetLength(UndoStack, Length(UndoStack) - 1);
end;

procedure DoRedo;
begin
  if Length(RedoStack) = 0 then Exit;
  SetLength(UndoStack, Length(UndoStack) + 1);
  UndoStack[High(UndoStack)] := Snapshot;
  Restore(RedoStack[High(RedoStack)]);
  SetLength(RedoStack, Length(RedoStack) - 1);
end;

function SaveAll: Boolean;
var
  err: string;
begin
  Result := SaveTextToFile(DataFile, SoundsToJSON(Defs));
  if Result then
  begin
    SavedJson := SoundsToJSON(Defs);
    SfxLoadSounds(DataFile, err);
    Status('Saved ' + DataFile + ' (' + IntToStr(Length(Defs)) + ' sounds)');
  end
  else
    Status('Could not write ' + DataFile);
end;

function LoadAll: Boolean;
var
  err: string;
  a: TSoundArray;
begin
  Result := LoadSoundsFile(DataFile, a, err);
  if not Result then
  begin
    Status('Load failed: ' + err);
    Exit;
  end;
  Defs := a;
  SavedJson := SoundsToJSON(Defs);
  Sel := EnsureRange(Sel, 0, Max(0, High(Defs)));
  SelLayer := 0;
  SetLength(UndoStack, 0);
  SetLength(RedoStack, 0);
  RenderedFor := '';
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
  data.message := 'sounds.json has unsaved changes. Save first?';
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

{ ---------- sound / layer operations ---------- }

function UniqueName(const base: string): string;
var
  n, i: Integer;
  taken: Boolean;
begin
  n := 1;
  repeat
    if n = 1 then Result := base else Result := base + IntToStr(n);
    taken := False;
    for i := 0 to High(Defs) do if SameText(Defs[i].Name, Result) then taken := True;
    Inc(n);
  until not taken;
end;

procedure AddSound(duplicate: Boolean);
var
  n: Integer;
begin
  PushUndo;
  n := Length(Defs);
  SetLength(Defs, n + 1);
  if duplicate and HaveSound then
  begin
    Defs[n] := Defs[Sel];
    Defs[n].Layers := Copy(Defs[Sel].Layers);
    Defs[n].LowPass := Copy(Defs[Sel].LowPass);
    Defs[n].Name := UniqueName(Defs[Sel].Name + 'Copy');
  end
  else
  begin
    Defs[n] := Default(TSoundDef);
    Defs[n].Name := UniqueName('newSound');
    Defs[n].Peak := 0.5;
    Defs[n].MinGap := 0.03;
    SetLength(Defs[n].Layers, 1);
    Defs[n].Layers[0] := NewLayer(lkTone);
  end;
  Sel := n;
  SelLayer := 0;
  Changed;
  Status('Added "' + Defs[n].Name + '" - assign it to a tower or enemy in StatEdit');
end;

procedure DeleteSound;
var
  i: Integer;
begin
  if not HaveSound then Exit;
  if SoundIsBuiltin(Defs[Sel].Name) then
  begin
    Status('"' + Defs[Sel].Name + '" is used by the game code and cannot be deleted');
    Exit;
  end;
  PushUndo;
  for i := Sel to High(Defs) - 1 do Defs[i] := Defs[i + 1];
  SetLength(Defs, Length(Defs) - 1);
  Sel := Min(Sel, High(Defs));
  SelLayer := 0;
  RenderedFor := '';
end;

procedure AddLayer(k: TLayerKind);
var
  n: Integer;
begin
  if not HaveSound then Exit;
  PushUndo;
  n := Length(Defs[Sel].Layers);
  SetLength(Defs[Sel].Layers, n + 1);
  Defs[Sel].Layers[n] := NewLayer(k);
  SelLayer := n;
  Changed;
end;

procedure DuplicateLayer;
var
  n: Integer;
begin
  if not HaveLayer then Exit;
  PushUndo;
  n := Length(Defs[Sel].Layers);
  SetLength(Defs[Sel].Layers, n + 1);
  Defs[Sel].Layers[n] := Defs[Sel].Layers[SelLayer];
  Defs[Sel].Layers[n].At := Defs[Sel].Layers[n].At + 0.05;
  SelLayer := n;
  Changed;
end;

procedure DeleteLayer;
var
  i: Integer;
begin
  if not HaveLayer then Exit;
  PushUndo;
  for i := SelLayer to High(Defs[Sel].Layers) - 1 do Defs[Sel].Layers[i] := Defs[Sel].Layers[i + 1];
  SetLength(Defs[Sel].Layers, Length(Defs[Sel].Layers) - 1);
  SelLayer := Min(SelLayer, High(Defs[Sel].Layers));
  Changed;
end;

procedure MoveLayer(d: Integer);
var
  j: Integer;
  t: TSoundLayer;
begin
  if not HaveLayer then Exit;
  j := SelLayer + d;
  if (j < 0) or (j > High(Defs[Sel].Layers)) then Exit;
  PushUndo;
  t := Defs[Sel].Layers[SelLayer];
  Defs[Sel].Layers[SelLayer] := Defs[Sel].Layers[j];
  Defs[Sel].Layers[j] := t;
  SelLayer := j;
end;

{ ---------- properties ---------- }

procedure AddRow(var r: array of TPropRow; var n: Integer; const key, caption: string; kind: TPropKind);
begin
  r[n].Key := key;
  r[n].Caption := caption;
  r[n].Kind := kind;
  Inc(n);
end;

procedure BuildRows;
var
  n: Integer;
  L: TSoundLayer;
begin
  SetLength(Rows, 8);
  n := 0;
  if HaveSound then
  begin
    AddRow(Rows, n, 's.name', 'name', pkText);
    AddRow(Rows, n, 's.peak', 'peak (loudness)', pkNum);
    AddRow(Rows, n, 's.minGap', 'min gap between plays', pkNum);
    AddRow(Rows, n, 's.length', 'length (0 = auto)', pkNum);
    AddRow(Rows, n, 's.lowpass', 'master low-pass (Hz list)', pkText);
    AddRow(Rows, n, 's.notes', 'notes', pkText);
  end;
  SetLength(Rows, n);
  SetLength(LRows, 16);
  n := 0;
  if HaveLayer then
  begin
    L := Defs[Sel].Layers[SelLayer];
    AddRow(LRows, n, 'l.type', 'layer type', pkEnum);
    AddRow(LRows, n, 'l.at', 'start (s)', pkNum);
    AddRow(LRows, n, 'l.dur', 'duration (s)', pkNum);
    case L.Kind of
      lkTone:
        begin
          AddRow(LRows, n, 'l.wave', 'wave', pkEnum);
          AddRow(LRows, n, 'l.f0', 'start pitch (Hz)', pkNum);
          AddRow(LRows, n, 'l.f1', 'end pitch (Hz)', pkNum);
          AddRow(LRows, n, 'l.attack', 'attack (s)', pkNum);
          AddRow(LRows, n, 'l.decay', 'decay (s)', pkNum);
          AddRow(LRows, n, 'l.vibrato', 'vibrato depth', pkNum);
        end;
      lkNoise:
        begin
          AddRow(LRows, n, 'l.f0', 'start cutoff (Hz)', pkNum);
          AddRow(LRows, n, 'l.f1', 'end cutoff (Hz)', pkNum);
          AddRow(LRows, n, 'l.attack', 'attack (s)', pkNum);
          AddRow(LRows, n, 'l.decay', 'decay (s)', pkNum);
        end;
      lkMetal:
        begin
          AddRow(LRows, n, 'l.f0', 'base pitch (Hz)', pkNum);
          AddRow(LRows, n, 'l.decay', 'ring time (s)', pkNum);
        end;
      lkGrunt:
        begin
          AddRow(LRows, n, 'l.f0', 'start pitch (Hz)', pkNum);
          AddRow(LRows, n, 'l.f1', 'end pitch (Hz)', pkNum);
          AddRow(LRows, n, 'l.bright', 'brightness (Hz)', pkNum);
        end;
    end;
    AddRow(LRows, n, 'l.gain', 'gain', pkNum);
    AddRow(LRows, n, 'l.cutoff', 'low-pass (Hz, 0 off)', pkNum);
    AddRow(LRows, n, 'l.fade', 'fade out (s)', pkNum);
  end;
  SetLength(LRows, n);
end;

function LowPassText(const d: TSoundDef): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(d.LowPass) do
  begin
    if i > 0 then Result := Result + ' ';
    Result := Result + F3(d.LowPass[i]);
  end;
end;

function GetStr(const key: string): string;
var
  L: TSoundLayer;
begin
  Result := '';
  if not HaveSound then Exit;
  case key of
    's.name': Exit(Defs[Sel].Name);
    's.peak': Exit(F3(Defs[Sel].Peak));
    's.minGap': Exit(F3(Defs[Sel].MinGap));
    's.length': Exit(F3(Defs[Sel].Length));
    's.lowpass': Exit(LowPassText(Defs[Sel]));
    's.notes': Exit(Defs[Sel].Notes);
  end;
  if not HaveLayer then Exit;
  L := Defs[Sel].Layers[SelLayer];
  case key of
    'l.type': Result := LayerKindNames[L.Kind];
    'l.wave': Result := WaveNames[EnsureRange(L.Wave, 0, 4)];
    'l.at': Result := F3(L.At);
    'l.dur': Result := F3(L.Dur);
    'l.f0': Result := F3(L.F0);
    'l.f1': Result := F3(L.F1);
    'l.attack': Result := F3(L.Attack);
    'l.decay': Result := F3(L.Decay);
    'l.vibrato': Result := F3(L.Vibrato);
    'l.bright': Result := F3(L.Bright);
    'l.gain': Result := F3(L.Gain);
    'l.cutoff': Result := F3(L.Cutoff);
    'l.fade': Result := F3(L.FadeOut);
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

procedure SetStr(const key, value: string);
var
  v: Single;
  isNum: Boolean;
  parts: TStringList;
  i: Integer;
  L: ^TSoundLayer;
begin
  if not HaveSound then Exit;
  isNum := ParseNum(value, v);
  case key of
    's.name':
      begin
        if SoundIsBuiltin(Defs[Sel].Name) and not SameText(Trim(value), Defs[Sel].Name) then
        begin
          Status('Built-in sounds keep their name (the game code refers to it)');
          Exit;
        end;
        for i := 0 to High(Defs) do
          if (i <> Sel) and SameText(Defs[i].Name, Trim(value)) then
          begin
            Status('Name already used');
            Exit;
          end;
        if Trim(value) <> '' then Defs[Sel].Name := Trim(value);
        Exit;
      end;
    's.notes': begin Defs[Sel].Notes := value; Exit; end;
    's.lowpass':
      begin
        parts := TStringList.Create;
        try
          parts.Delimiter := ' ';
          parts.StrictDelimiter := False;
          parts.DelimitedText := StringReplace(value, ',', ' ', [rfReplaceAll]);
          SetLength(Defs[Sel].LowPass, 0);
          for i := 0 to parts.Count - 1 do
            if ParseNum(parts[i], v) and (v > 0) then
            begin
              SetLength(Defs[Sel].LowPass, Length(Defs[Sel].LowPass) + 1);
              Defs[Sel].LowPass[High(Defs[Sel].LowPass)] := v;
            end;
        finally
          parts.Free;
        end;
        Exit;
      end;
  end;
  if not isNum then Exit;
  case key of
    's.peak': begin Defs[Sel].Peak := EnsureRange(v, 0.01, 1); Exit; end;
    's.minGap': begin Defs[Sel].MinGap := EnsureRange(v, 0, 2); Exit; end;
    's.length': begin Defs[Sel].Length := EnsureRange(v, 0, 10); Exit; end;
  end;
  if not HaveLayer then Exit;
  L := @Defs[Sel].Layers[SelLayer];
  case key of
    'l.at': L^.At := EnsureRange(v, 0, 10);
    'l.dur': L^.Dur := EnsureRange(v, 0.005, 10);
    'l.f0': L^.F0 := EnsureRange(v, 1, 20000);
    'l.f1': L^.F1 := EnsureRange(v, 1, 20000);
    'l.attack': L^.Attack := EnsureRange(v, 0, 5);
    'l.decay': L^.Decay := EnsureRange(v, 0.001, 10);
    'l.vibrato': L^.Vibrato := EnsureRange(v, 0, 1);
    'l.bright': L^.Bright := EnsureRange(v, 50, 20000);
    'l.gain': L^.Gain := EnsureRange(v, 0, 5);
    'l.cutoff': L^.Cutoff := EnsureRange(v, 0, 20000);
    'l.fade': L^.FadeOut := EnsureRange(v, 0, 10);
  end;
end;

function GetNum(const key: string): Single;
begin
  if not ParseNum(GetStr(key), Result) then Result := 0;
end;

function NumStep(const key: string): Single;
begin
  if (key = 'l.f0') or (key = 'l.f1') or (key = 'l.bright') or (key = 'l.cutoff') then
    Result := Max(1, Round(GetNum(key) * 0.02))
  else if (key = 'l.at') or (key = 'l.dur') or (key = 's.length') or (key = 'l.fade') then Result := 0.01
  else if (key = 'l.attack') or (key = 'l.decay') then Result := 0.005
  else Result := 0.01;
  if ModShift then Result := Result / 5
  else if ModCtrl then Result := Result * 10;
end;

procedure CycleEnum(const key: string; d: Integer);
var
  L: ^TSoundLayer;
begin
  if not HaveLayer then Exit;
  PushUndo;
  L := @Defs[Sel].Layers[SelLayer];
  if key = 'l.type' then
    L^.Kind := TLayerKind((Ord(L^.Kind) + d + 4) mod 4)
  else if key = 'l.wave' then
    L^.Wave := (L^.Wave + d + 5) mod 5;
  Changed;
end;

procedure BeginEdit(const key: string);
begin
  EditKey := key;
  EditBuf := GetStr(key);
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
  if commit and (EditBuf <> GetStr(k)) then
  begin
    PushUndo;
    SetStr(k, EditBuf);
    Changed;
  end;
end;

procedure ValueCell(x, y, w: Single; const key: string; kind: TPropKind);
var
  hover: Boolean;
  txt: string;
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
  txt := GetStr(key);
  if kind = pkEnum then DrawText(x + 5, y + 3, '< ' + txt + ' >', RGBA(160, 210, 255), fnSmall, ALIGN_LEFT, False)
  else DrawText(x + 5, y + 3, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
  if hover and (WheelY <> 0) and (kind = pkNum) and (Drag = drNone) then
  begin
    PushUndo;
    SetStr(key, F3(GetNum(key) + WheelY * NumStep(key)));
    WheelY := 0;
    Changed;
  end;
  if hover and (LDown or RDown) and not Consumed then
  begin
    Consumed := True;
    EndEdit(True);
    case kind of
      pkText: if LDown then BeginEdit(key);
      pkEnum: if LDown then CycleEnum(key, 1) else CycleEnum(key, -1);
      pkNum:
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

procedure DrawRows(const r: array of TPropRow; x, y0, w: Single);
var
  i: Integer;
  y: Single;
begin
  for i := 0 to High(r) do
  begin
    y := y0 + i * ROW_H;
    if r[i].Kind = pkInfo then
    begin
      DrawText(x + 4, y + 3, r[i].Caption, C_DIM, fnSmall, ALIGN_LEFT, False);
      Continue;
    end;
    DrawText(x + 4, y + 3, r[i].Caption, C_DIM, fnSmall, ALIGN_LEFT, False);
    ValueCell(x + 180, y, w - 186, r[i].Key, r[i].Kind);
  end;
end;

{ ---------- panels ---------- }

procedure DrawToolbar;
var
  x: Single;

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
  if TB(56, 'Save', False, Modified) then SaveAll;
  if TB(66, 'Reload') and ConfirmDiscard then LoadAll;
  Gap;
  if TB(52, 'Undo', False, Length(UndoStack) > 0) then DoUndo;
  if TB(52, 'Redo', False, Length(RedoStack) > 0) then DoRedo;
  Gap;
  if TB(96, 'Play (Space)', False, HaveSound) then PlayCurrent;
  if TB(120, 'Auto-play: ' + IfThen(AutoPlay, 'on', 'off'), AutoPlay) then AutoPlay := not AutoPlay;
  if TB(96, 'Export WAV', False, HaveSound) then
  begin
    RenderCurrent;
    if SaveWav(ExtractFilePath(DataFile) + 'export' + PathDelim + Defs[Sel].Name + '.wav', Rendered) then
      Status('Exported data\export\' + Defs[Sel].Name + '.wav');
  end;
  if Modified then DrawText(WIN_W - 10, 13, 'unsaved', RGBA(255, 150, 120), fnSmall, ALIGN_RIGHT, False);
end;

procedure DrawSoundList;
var
  i, n, visible: Integer;
  y: Single;
  builtin: Boolean;
begin
  FillRect(0, TOP_H, LEFT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
  FillRect(LEFT_W - 1, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  DrawText(10, TOP_H + 6, Format('SOUNDS (%d)', [Length(Defs)]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  visible := (WIN_H - STATUS_H - TOP_H - 30 - 70) div ROW_H;
  if Inside(0, TOP_H + 28, LEFT_W, visible * ROW_H) and (WheelY <> 0) then
  begin
    ListScroll := ListScroll - Round(WheelY) * 3;
    WheelY := 0;
  end;
  if Sel < ListScroll then ListScroll := Sel;
  if Sel >= ListScroll + visible then ListScroll := Sel - visible + 1;
  ListScroll := EnsureRange(ListScroll, 0, Max(0, Length(Defs) - visible));
  n := 0;
  for i := ListScroll to High(Defs) do
  begin
    if n >= visible then Break;
    y := TOP_H + 28 + n * ROW_H;
    Inc(n);
    if i = Sel then FillRect(4, y, LEFT_W - 9, ROW_H - 2, C_SEL)
    else if Inside(4, y, LEFT_W - 9, ROW_H - 2) then FillRect(4, y, LEFT_W - 9, ROW_H - 2, C_PANEL2);
    builtin := SoundIsBuiltin(Defs[i].Name);
    if builtin then
    begin
      // small padlock
      FillRect(12, y + 9, 9, 7, RGBA(200, 170, 90));
      Ring(16.5, y + 9, 3, 3.5, 1.5, RGBA(200, 170, 90));
    end;
    DrawText(28, y + 2, Defs[i].Name, C_TEXT, fnSmall, ALIGN_LEFT, False);
    DrawText(LEFT_W - 12, y + 2, F3(Round(SoundDuration(Defs[i]) * 100) / 100) + 's', C_DIM, fnSmall, ALIGN_RIGHT, False);
    if Inside(4, y, LEFT_W - 9, ROW_H - 2) and LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      Sel := i;
      SelLayer := 0;
      PlayCurrent;
    end;
  end;
  y := WIN_H - STATUS_H - 64;
  if Button(8, y, 70, 26, 'New') then AddSound(False);
  if Button(82, y, 74, 26, 'Duplicate', False, HaveSound) then AddSound(True);
  if Button(160, y, 62, 26, 'Delete', False, HaveSound and not SoundIsBuiltin(Defs[Sel].Name)) then DeleteSound;
  DrawText(10, y + 34, 'lock = used by game code', C_DIM, fnSmall, ALIGN_LEFT, False);
end;

procedure DrawMiddle;
var
  y, x0: Single;
  i: Integer;
  L: TSoundLayer;
  k: TLayerKind;
  c: TRGBA;
  desc: string;
begin
  x0 := MID_X;
  FillRect(x0, TOP_H, MID_W, WIN_H - TOP_H - STATUS_H, C_BG);
  FillRect(RIGHT_X - 1, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  if not HaveSound then Exit;
  BuildRows;
  DrawText(x0 + 10, TOP_H + 6, 'SOUND', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  DrawRows(Rows, x0 + 6, TOP_H + 28, MID_W - 12);
  y := TOP_H + 28 + Length(Rows) * ROW_H + 14;
  DrawText(x0 + 10, y, Format('LAYERS (%d) - mixed together, top to bottom', [Length(Defs[Sel].Layers)]), C_ACCENT,
    fnSmall, ALIGN_LEFT, False);
  y := y + 22;
  for i := 0 to High(Defs[Sel].Layers) do
  begin
    L := Defs[Sel].Layers[i];
    if i = SelLayer then FillRect(x0 + 4, y, MID_W - 8, ROW_H - 1, C_SEL)
    else if Inside(x0 + 4, y, MID_W - 8, ROW_H - 1) then FillRect(x0 + 4, y, MID_W - 8, ROW_H - 1, C_PANEL2);
    c := LayerColors[L.Kind];
    FillRect(x0 + 8, y + 4, 6, 14, c);
    case L.Kind of
      lkTone: desc := Format('%s %s -> %s Hz', [WaveNames[EnsureRange(L.Wave, 0, 4)], F3(Round(L.F0)), F3(Round(L.F1))]);
      lkNoise: desc := Format('cutoff %s -> %s Hz', [F3(Round(L.F0)), F3(Round(L.F1))]);
      lkMetal: desc := Format('ring %s Hz', [F3(Round(L.F0))]);
      lkGrunt: desc := Format('voice %s -> %s Hz', [F3(Round(L.F0)), F3(Round(L.F1))]);
    end;
    DrawText(x0 + 20, y + 2, LayerKindNames[L.Kind], C_TEXT, fnSmall, ALIGN_LEFT, False);
    DrawText(x0 + 76, y + 2, desc, C_DIM, fnSmall, ALIGN_LEFT, False);
    DrawText(x0 + MID_W - 12, y + 2, Format('%ss + %ss  x%s', [F3(L.At), F3(L.Dur), F3(L.Gain)]), C_DIM, fnSmall,
      ALIGN_RIGHT, False);
    if Inside(x0 + 4, y, MID_W - 8, ROW_H - 1) and LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      SelLayer := i;
    end;
    y := y + ROW_H;
  end;
  y := y + 8;
  DrawText(x0 + 10, y + 5, 'Add:', C_DIM, fnSmall, ALIGN_LEFT, False);
  i := 0;
  for k := Low(TLayerKind) to High(TLayerKind) do
  begin
    if Button(x0 + 46 + i * 70, y, 66, 24, LayerKindNames[k]) then AddLayer(k);
    Inc(i);
  end;
  y := y + 30;
  if Button(x0 + 10, y, 60, 24, 'Up', False, HaveLayer and (SelLayer > 0)) then MoveLayer(-1);
  if Button(x0 + 74, y, 60, 24, 'Down', False, HaveLayer and (SelLayer < High(Defs[Sel].Layers))) then MoveLayer(1);
  if Button(x0 + 138, y, 80, 24, 'Duplicate', False, HaveLayer) then DuplicateLayer;
  if Button(x0 + 222, y, 64, 24, 'Delete', False, HaveLayer) then DeleteLayer;
end;

procedure DrawWaveform;
var
  x0, w, mid, t, x, y, dur, sc: Single;
  i, col, a, b, j: Integer;
  mn, mxv: Single;
  L: TSoundLayer;
  c: TRGBA;
begin
  x0 := RIGHT_X + 10;
  w := RIGHT_W - 20;
  DrawText(x0, TOP_H + 6, 'WAVEFORM', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  FillRect(x0, WAVE_Y, w, WAVE_H, RGBA(20, 22, 26));
  RenderCurrent;
  if Length(Rendered) = 0 then Exit;
  dur := Length(Rendered) / RATE;
  mid := WAVE_Y + WAVE_H / 2;
  FillRect(x0, mid, w, 1, RGBA(255, 255, 255, 40));
  for col := 0 to Round(w) - 1 do
  begin
    a := Round(col / w * Length(Rendered));
    b := Min(High(Rendered), Round((col + 1) / w * Length(Rendered)));
    mn := 0; mxv := 0;
    for j := a to b do
    begin
      mn := Min(mn, Rendered[j]);
      mxv := Max(mxv, Rendered[j]);
    end;
    FillRect(x0 + col, mid - mxv * WAVE_H * 0.5, 1, Max(1, (mxv - mn) * WAVE_H * 0.5), RGBA(255, 190, 80, 220));
  end;
  // time grid
  t := 0;
  while t <= dur do
  begin
    x := x0 + t / dur * w;
    FillRect(x, WAVE_Y, 1, WAVE_H, RGBA(255, 255, 255, 25));
    DrawText(x + 3, WAVE_Y + WAVE_H - 18, F3(t) + 's', C_DIM, fnSmall, ALIGN_LEFT, False);
    if dur > 1.5 then t := t + 0.25 else t := t + 0.1;
  end;
  // play cursor
  if (PlayStart > 0) and ((SDL_GetTicks - PlayStart) / 1000 < PlayLen) then
  begin
    x := x0 + ((SDL_GetTicks - PlayStart) / 1000) / dur * w;
    FillRect(x, WAVE_Y, 2, WAVE_H, RGBA(255, 255, 255, 200));
  end;

  // layer timeline
  DrawText(x0, TL_Y, 'LAYER TIMELINE - drag a bar to move the layer in time', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  FillRect(x0, TL_Y + 20, w, TL_H, RGBA(24, 26, 31));
  if Length(Defs[Sel].Layers) = 0 then Exit;
  sc := w / dur;
  for i := 0 to High(Defs[Sel].Layers) do
  begin
    L := Defs[Sel].Layers[i];
    y := TL_Y + 26 + i * Min(24, (TL_H - 10) / Length(Defs[Sel].Layers));
    c := LayerColors[L.Kind];
    if i <> SelLayer then c := Shade(c, 0.6);
    x := x0 + L.At * sc;
    RoundRect(x, y, Max(4, L.Dur * sc), Min(20, (TL_H - 14) / Length(Defs[Sel].Layers)), 4, c);
    DrawText(x + 4, y + 1, LayerKindNames[L.Kind], RGBA(20, 20, 24), fnSmall, ALIGN_LEFT, False);
    if Inside(x, y, Max(4, L.Dur * sc), 20) and LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      SelLayer := i;
      Drag := drLayer;
      DragStartX := MX;
      DragStartAt := L.At;
      DragUndoPushed := False;
    end;
  end;
end;

procedure DrawLayerProps;
var
  y0: Single;
begin
  y0 := TL_Y + TL_H + 32;
  FillRect(RIGHT_X, y0 - 8, RIGHT_W, 1, C_LINE);
  if not HaveLayer then
  begin
    DrawText(RIGHT_X + 10, y0, 'No layer selected - add one in the middle panel.', C_DIM, fnSmall, ALIGN_LEFT, False);
    Exit;
  end;
  DrawText(RIGHT_X + 10, y0, Format('LAYER %d PROPERTIES', [SelLayer]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  DrawRows(LRows, RIGHT_X + 6, y0 + 22, 460);
  DrawText(RIGHT_X + 490, y0 + 26, 'tone  - pitched, glides f0 to f1', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(RIGHT_X + 490, y0 + 44, 'noise - filtered, cutoff glides', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(RIGHT_X + 490, y0 + 62, 'metal - bell / clang ring', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(RIGHT_X + 490, y0 + 80, 'grunt - buzzy voice', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(RIGHT_X + 490, y0 + 108, 'After mixing: master low-pass,', C_DIM, fnSmall, ALIGN_LEFT, False);
  DrawText(RIGHT_X + 490, y0 + 126, 'then normalized to "peak".', C_DIM, fnSmall, ALIGN_LEFT, False);
end;

{ ---------- input ---------- }

procedure UpdateDrags;
var
  v: Single;
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
          v := ScrubStart + Round((MX - DragStartX) / 4) * NumStep(ScrubKey);
          SetStr(ScrubKey, F3(v));
          RenderedFor := '';
          PlayAfterDrag := True;
        end;
      end
      else
      begin
        if not ScrubMoved then BeginEdit(ScrubKey);
        Drag := drNone;
      end;
    drLayer:
      if LHeld and HaveLayer and (Length(Rendered) > 0) then
      begin
        v := Max(0, Round((DragStartAt + (MX - DragStartX) / (RIGHT_W - 20) * (Length(Rendered) / RATE)) * 200) / 200);
        if v <> Defs[Sel].Layers[SelLayer].At then
        begin
          if not DragUndoPushed then
          begin
            PushUndo;
            DragUndoPushed := True;
          end;
          Defs[Sel].Layers[SelLayer].At := v;
          PlayAfterDrag := True;
        end;
      end
      else Drag := drNone;
  end;
  if (Drag = drNone) and PlayAfterDrag then
  begin
    PlayAfterDrag := False;
    RenderedFor := '';
    if AutoPlay then PlayCurrent;
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
      SDLK_S: SaveAll;
      SDLK_Z: if ModShift then DoRedo else DoUndo;
      SDLK_Y: DoRedo;
      SDLK_D: DuplicateLayer;
    end;
    Exit;
  end;
  case key of
    SDLK_SPACE: PlayCurrent;
    SDLK_UP: if Sel > 0 then begin Sel := Sel - 1; SelLayer := 0; PlayCurrent; end;
    SDLK_DOWN: if Sel < High(Defs) then begin Sel := Sel + 1; SelLayer := 0; PlayCurrent; end;
    SDLK_DELETE: DeleteLayer;
    SDLK_A: AutoPlay := not AutoPlay;
  end;
end;

{ ---------- main ---------- }

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
  ShotFrames, ArgI, k: Integer;

begin
  DataFile := ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'sounds.json';
  if not SDL_Init(SDL_INIT_VIDEO) then Halt(1);
  if not SDL_CreateWindowAndRenderer('SoundEdit', WIN_W, WIN_H, SDL_WINDOW_RESIZABLE, @Window, @Renderer) then
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
  LoadAll;

  ShotFile := '';
  for ArgI := 1 to ParamCount - 1 do
    if ParamStr(ArgI) = '--shot' then
    begin
      ShotFile := ParamStr(ArgI + 1);
      SoundMuted := True;
      if ArgI + 2 <= ParamCount then
        for k := 0 to High(Defs) do
          if SameText(Defs[k].Name, ParamStr(ArgI + 2)) then Sel := k;
      SelLayer := 1;
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
        SDL_EVENT_QUIT: if ConfirmDiscard then Running := False;
        SDL_EVENT_TEXT_INPUT: if EditKey <> '' then EditBuf := EditBuf + string(Event.text.text);
        SDL_EVENT_KEY_DOWN: HandleKey(Event.key.key);
      end;
    end;
    UIUpdateMods;
    Now_ := SDL_GetTicks;
    Dt := Min(0.05, (Now_ - Last) / 1000);
    Last := Now_;
    SfxUpdate(Dt);
    if StatusTime > 0 then StatusTime := StatusTime - Dt;
    UpdateDrags;

    SDL_SetRenderDrawColor(Renderer, C_BG.r, C_BG.g, C_BG.b, 255);
    SDL_RenderClear(Renderer);
    DrawToolbar;
    DrawSoundList;
    DrawMiddle;
    FillRect(RIGHT_X, TOP_H, RIGHT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
    if HaveSound then
    begin
      DrawWaveform;
      DrawLayerProps;
    end;
    FillRect(0, WIN_H - STATUS_H, WIN_W, STATUS_H, C_PANEL);
    FillRect(0, WIN_H - STATUS_H, WIN_W, 1, C_LINE);
    if StatusTime > 0 then
      DrawText(10, WIN_H - STATUS_H + 3, StatusMsg, C_ACCENT, fnSmall, ALIGN_LEFT, False)
    else
      DrawText(10, WIN_H - STATUS_H + 3, 'Space play  |  numbers: drag / click / wheel  |  enums: click / right-click  |  ' +
        'Del delete layer  |  Ctrl+S save  |  Ctrl+Z/Y undo/redo', C_DIM, fnSmall, ALIGN_LEFT, False);
    if ShotFile <> '' then
    begin
      Inc(ShotFrames);
      if ShotFrames = 20 then
      begin
        SaveShot(ShotFile);
        Running := False;
      end;
    end;
    SDL_RenderPresent(Renderer);
    if Modified then SDL_SetWindowTitle(Window, 'SoundEdit - sounds.json *')
    else SDL_SetWindowTitle(Window, 'SoundEdit - sounds.json');
  end;
  SfxDone;
  GfxDone;
  SDL_DestroyRenderer(Renderer);
  SDL_DestroyWindow(Window);
  SDL_Quit;
end.
