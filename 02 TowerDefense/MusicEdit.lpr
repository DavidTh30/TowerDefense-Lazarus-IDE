program MusicEdit;

{ MusicEdit - tracker-style music editor for Brewhold Defense (Lazarus / Free Pascal + SDL3)

  Edits data\music\*.json (format: music.pas). A song is a set of 16-step (or longer) patterns played in
  the order list; every channel plays one instrument. Maps choose their song with "music" (MapEdit).

  Layout
    left ...... songs, song settings (tempo, swing, echo)
    middle .... pattern grid (rows = steps, columns = channels) and the order list (arrangement)
    right ..... instruments and the selected channel
  Note entry (cursor in the grid)
    Z S X D C V G B H N J M  = C..B in the current octave,   Q 2 W 3 E R 5 T 6 Y 7 U I  = one octave up
    A = note off   Del / Backspace = clear   [ / ] octave down / up   - / = edit step
    Arrows move   Tab next channel   PgUp / PgDn previous / next pattern   wheel on a note = +-1 (Shift = octave)
  Playback: Enter play song   Space play / stop pattern   Esc stop   (edits re-render while playing)
  Keys: Ctrl+S save   Ctrl+Z / Ctrl+Y undo / redo   Ctrl+C / Ctrl+V copy / paste pattern
  Test hook: musicedit --shot <file.bmp> [song file] }

{$mode objfpc}{$H+}
{$APPTYPE GUI}

uses
  SDL3, SysUtils, Math, StrUtils, Classes, gfx, ui, synth, music, sfx, gamedata;

const
  WIN_W = 1440;
  WIN_H = 900;
  TOP_H = 44;
  LEFT_W = 240;
  RIGHT_W = 360;
  STATUS_H = 24;
  MID_X = LEFT_W;
  MID_W = WIN_W - LEFT_W - RIGHT_W;
  RIGHT_X = WIN_W - RIGHT_W;
  ROW_H = 23;
  GRID_Y = TOP_H + 76;
  CELL_H = 22;
  ROWNUM_W = 38;
  ORDER_H = 92;
  MAX_UNDO = 300;

type
  TPropKind = (pkNum, pkText, pkEnum, pkBool, pkInfo, pkHeader);
  TPropRow = record
    Key, Caption: string;
    Kind: TPropKind;
  end;
  TUndoEntry = record
    Json: string;
    Pat, Ord_, Row, Chan: Integer;
  end;
  TDrag = (drNone, drScrub);

var
  Window: PSDL_Window;
  Renderer: PSDL_Renderer;
  MusicDir: string;
  SongFiles: TStringList;
  CurFile: string = '';
  Song: TSong;
  SavedJson: string;
  CurPat: Integer = 0;
  CurOrder: Integer = 0;
  CurRow: Integer = 0;
  CurChan: Integer = 0;
  CurInst: Integer = 0;
  Octave: Integer = 4;
  EditStep: Integer = 1;
  Follow: Boolean = True;
  GridScroll: Integer = 0;
  OrderScroll: Integer = 0;
  ClipPattern: TPattern;
  HasClip: Boolean = False;
  UndoStack, RedoStack: array of TUndoEntry;
  // playback
  PlayMode: Integer = 0;          // 0 stopped, 1 song, 2 pattern
  PlayFromOrder: Integer = 0;
  PlayPattern: Integer = 0;
  RerenderAt: Single = -1;        // time left before re-rendering after an edit while playing
  // editing
  Drag: TDrag = drNone;
  DragStartX, ScrubStart: Single;
  ScrubKey: string;
  ScrubMoved, DragUndoPushed: Boolean;
  EditKey: string = '';
  EditBuf: string = '';
  StatusMsg: string = '';
  StatusTime: Single = 0;
  UsedBy: string = '';

{ ---------- helpers ---------- }

procedure Status(const s: string);
begin
  StatusMsg := s;
  StatusTime := 6;
end;

function Modified: Boolean;
begin
  Result := SongToJSON(Song) <> SavedJson;
end;

function PatCount: Integer;
begin
  Result := Length(Song.Patterns);
end;

function ChanCount: Integer;
begin
  Result := Length(Song.Channels);
end;

procedure ClampCursor;
begin
  CurPat := EnsureRange(CurPat, 0, Max(0, PatCount - 1));
  CurOrder := EnsureRange(CurOrder, 0, Max(0, High(Song.Order)));
  CurRow := EnsureRange(CurRow, 0, Song.PatternLen - 1);
  CurChan := EnsureRange(CurChan, 0, Max(0, ChanCount - 1));
  CurInst := EnsureRange(CurInst, 0, Max(0, High(Song.Instruments)));
end;

procedure MarkEdited;
begin
  if PlayMode <> 0 then RerenderAt := 0.3;
end;

{ ---------- undo / files ---------- }

function Snapshot: TUndoEntry;
begin
  Result.Json := SongToJSON(Song);
  Result.Pat := CurPat;
  Result.Ord_ := CurOrder;
  Result.Row := CurRow;
  Result.Chan := CurChan;
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
  s: TSong;
  err: string;
begin
  if not SongFromJSONText(e.Json, s, err) then Exit;
  Song := s;
  CurPat := e.Pat;
  CurOrder := e.Ord_;
  CurRow := e.Row;
  CurChan := e.Chan;
  ClampCursor;
  MarkEdited;
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

procedure ScanSongs;
var
  sr: TSearchRec;
begin
  SongFiles.Clear;
  if FindFirst(MusicDir + '*.json', faAnyFile, sr) = 0 then
  begin
    repeat
      SongFiles.Add(sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  SongFiles.Sort;
end;

procedure FindUsers;
var
  sr: TSearchRec;
  m: TMapDef;
  err: string;
begin
  UsedBy := '';
  if FindFirst(ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'maps' + PathDelim + '*.json', faAnyFile, sr) = 0 then
  begin
    repeat
      m := Default(TMapDef);
      if LoadMapFile(ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'maps' + PathDelim + sr.Name, m, err) and
        SameText(m.Music, CurFile) then
      begin
        if UsedBy <> '' then UsedBy := UsedBy + ', ';
        UsedBy := UsedBy + m.Name;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  if SameText(CurFile, 'title.json') then
  begin
    if UsedBy <> '' then UsedBy := UsedBy + ', ';
    UsedBy := UsedBy + 'main menu';
  end;
end;

procedure StopPlay;
begin
  MusicStop(0);
  PlayMode := 0;
end;

function OpenSong(const fn: string): Boolean;
var
  s: TSong;
  err: string;
begin
  Result := LoadSong(MusicDir + fn, s, err);
  if not Result then
  begin
    Status('Cannot open ' + fn + ': ' + err);
    Exit;
  end;
  StopPlay;
  Song := s;
  CurFile := fn;
  SavedJson := SongToJSON(Song);
  CurPat := 0; CurOrder := 0; CurRow := 0; CurChan := 0; CurInst := 0;
  GridScroll := 0;
  SetLength(UndoStack, 0);
  SetLength(RedoStack, 0);
  FindUsers;
  Status(Format('Opened %s: "%s", %d patterns, %d channels', [fn, Song.Name, PatCount, ChanCount]));
end;

function SaveCurrent: Boolean;
var
  err: string;
begin
  Result := SaveSong(MusicDir + CurFile, Song);
  if Result then
  begin
    SavedJson := SongToJSON(Song);
    Status('Saved ' + CurFile);
  end
  else
    Status('Could not write ' + CurFile);
  err := '';
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
  data.message := PAnsiChar(CurFile + ' has unsaved changes. Save first?');
  data.numbuttons := 3;
  data.Buttons := @btn[0];
  hit := 2;
  SDL_ShowMessageBox(@data, @hit);
  case hit of
    0: Result := SaveCurrent;
    1: Result := True;
  else
    Result := False;
  end;
end;

function UniqueFile(const base: string): string;
var
  n: Integer;
begin
  n := 1;
  repeat
    if n = 1 then Result := base + '.json' else Result := base + IntToStr(n) + '.json';
    Inc(n);
  until not FileExists(MusicDir + Result);
end;

procedure NewSongFile(duplicate: Boolean);
var
  fn: string;
  i: Integer;
begin
  if not ConfirmDiscard then Exit;
  StopPlay;
  if duplicate then
  begin
    fn := UniqueFile(ChangeFileExt(CurFile, '') + '_copy');
    Song.Name := Song.Name + ' (copy)';
  end
  else
  begin
    fn := UniqueFile('newsong');
    Song := NewSong;
    // a useful starter kit of instruments
    SetLength(Song.Instruments, 6);
    Song.Instruments[0] := NewInstrument; Song.Instruments[0].Name := 'bass'; Song.Instruments[0].Cutoff := 800;
    Song.Instruments[1] := NewInstrument; Song.Instruments[1].Name := 'pad'; Song.Instruments[1].Wave := 1;
    Song.Instruments[1].Attack := 0.2; Song.Instruments[1].Cutoff := 1400; Song.Instruments[1].Detune := 8;
    Song.Instruments[1].Volume := 0.25;
    Song.Instruments[2] := NewInstrument; Song.Instruments[2].Name := 'lead'; Song.Instruments[2].Wave := 2;
    Song.Instruments[2].Vibrato := 0.15; Song.Instruments[2].Cutoff := 2500; Song.Instruments[2].Volume := 0.3;
    Song.Instruments[3] := NewInstrument; Song.Instruments[3].Name := 'kick'; Song.Instruments[3].Wave := 0;
    Song.Instruments[3].Decay := 0.18; Song.Instruments[3].Sustain := 0; Song.Instruments[3].PitchDrop := 24;
    Song.Instruments[3].Volume := 0.9;
    Song.Instruments[4] := NewInstrument; Song.Instruments[4].Name := 'snare'; Song.Instruments[4].Decay := 0.12;
    Song.Instruments[4].Sustain := 0; Song.Instruments[4].NoiseMix := 0.75; Song.Instruments[4].PitchDrop := 8;
    Song.Instruments[4].Volume := 0.5;
    Song.Instruments[5] := NewInstrument; Song.Instruments[5].Name := 'hat'; Song.Instruments[5].Wave := 4;
    Song.Instruments[5].Decay := 0.035; Song.Instruments[5].Sustain := 0; Song.Instruments[5].Volume := 0.16;
    SetLength(Song.Channels, 6);
    for i := 0 to 5 do
    begin
      Song.Channels[i].Name := Song.Instruments[i].Name;
      Song.Channels[i].Instrument := i;
      Song.Channels[i].Volume := 1;
    end;
    FixSong(Song);
  end;
  CurFile := fn;
  SaveCurrent;
  ScanSongs;
  SetLength(UndoStack, 0);
  SetLength(RedoStack, 0);
  FindUsers;
  Status('Created ' + fn + ' - set it as a map''s "music" in MapEdit');
end;

{ ---------- playback ---------- }

procedure StartPlay(mode: Integer; fromSeconds: Single = 0);
var
  b: TBuf;
begin
  if mode = 1 then
  begin
    PlayFromOrder := CurOrder;
    b := RenderSong(Song, PlayFromOrder, -1, -1, False);
  end
  else
  begin
    PlayPattern := CurPat;
    b := RenderSong(Song, -1, -1, PlayPattern, True);
  end;
  MusicPlayBuffer(b, True, fromSeconds);
  PlayMode := mode;
  RerenderAt := -1;
end;

// current playing step (absolute within the rendered buffer), -1 if stopped
function PlayStep: Integer;
begin
  if (PlayMode = 0) or not MusicPlaying then Exit(-1);
  Result := Trunc(MusicPosition / StepDuration(Song));
end;

procedure PreviewNote(note: Integer);
var
  b: TBuf;
begin
  if (note <= 0) or (ChanCount = 0) then Exit;
  b := RenderNotePreview(Song.Instruments[Song.Channels[CurChan].Instrument], note, 0.35);
  PlayBuffer(b, 0.9 / Max(0.05, MasterVolume));
end;

{ ---------- note editing ---------- }

procedure SetCell(note: Integer; advance: Boolean);
begin
  if (PatCount = 0) or (ChanCount = 0) then Exit;
  PushUndo;
  Song.Patterns[CurPat].Notes[CurChan][CurRow] := note;
  if note > 0 then PreviewNote(note);
  if advance then CurRow := (CurRow + EditStep) mod Song.PatternLen;
  MarkEdited;
end;

function PianoKey(key: TSDL_Keycode; out semitone: Integer): Boolean;
const
  Lower = 'zsxdcvgbhnjm,l.;';
  Upper = 'q2w3er5t6y7ui9o0p';
var
  ch: Char;
  p: Integer;
begin
  Result := False;
  if (key < 32) or (key > 126) then Exit;
  ch := Chr(key);
  p := Pos(ch, Lower);
  if p > 0 then
  begin
    semitone := p - 1;
    Exit(True);
  end;
  p := Pos(ch, Upper);
  if p > 0 then
  begin
    semitone := 12 + p - 1;
    Exit(True);
  end;
end;

{ ---------- property rows ---------- }

function GetStr(const key: string): string;
var
  ins: TInstrument;
begin
  Result := '';
  case key of
    'song.name': Exit(Song.Name);
    'song.bpm': Exit(F3(Song.Bpm));
    'song.spb': Exit(IntToStr(Song.StepsPerBeat));
    'song.len': Exit(IntToStr(Song.PatternLen));
    'song.swing': Exit(F3(Song.Swing));
    'song.echoT': Exit(F3(Song.EchoTime));
    'song.echoF': Exit(F3(Song.EchoFeedback));
    'song.echoM': Exit(F3(Song.EchoMix));
    'pat.name': if PatCount > 0 then Exit(Song.Patterns[CurPat].Name);
  end;
  if ChanCount > 0 then
    case key of
      'ch.name': Exit(Song.Channels[CurChan].Name);
      'ch.inst': Exit(Song.Instruments[Song.Channels[CurChan].Instrument].Name);
      'ch.vol': Exit(F3(Song.Channels[CurChan].Volume));
      'ch.mute': Exit(BoolToStr(Song.Channels[CurChan].Muted, 'yes', 'no'));
    end;
  if Length(Song.Instruments) = 0 then Exit;
  ins := Song.Instruments[CurInst];
  case key of
    'ins.name': Result := ins.Name;
    'ins.wave': Result := WaveNames[EnsureRange(ins.Wave, 0, 4)];
    'ins.attack': Result := F3(ins.Attack);
    'ins.decay': Result := F3(ins.Decay);
    'ins.sustain': Result := F3(ins.Sustain);
    'ins.release': Result := F3(ins.Release);
    'ins.volume': Result := F3(ins.Volume);
    'ins.cutoff': Result := F3(ins.Cutoff);
    'ins.vibrato': Result := F3(ins.Vibrato);
    'ins.vibRate': Result := F3(ins.VibRate);
    'ins.drop': Result := F3(ins.PitchDrop);
    'ins.noise': Result := F3(ins.NoiseMix);
    'ins.detune': Result := F3(ins.Detune);
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
  ins: ^TInstrument;
begin
  isNum := ParseNum(value, v);
  case key of
    'song.name': begin Song.Name := value; Exit; end;
    'pat.name': begin if PatCount > 0 then Song.Patterns[CurPat].Name := Trim(value); Exit; end;
    'ch.name': begin if ChanCount > 0 then Song.Channels[CurChan].Name := value; Exit; end;
    'ins.name': begin if Length(Song.Instruments) > 0 then Song.Instruments[CurInst].Name := value; Exit; end;
  end;
  if not isNum then Exit;
  case key of
    'song.bpm': Song.Bpm := EnsureRange(v, 30, 300);
    'song.spb': Song.StepsPerBeat := EnsureRange(Round(v), 1, 8);
    'song.len':
      begin
        Song.PatternLen := EnsureRange(Round(v), 4, 64);
        FixSong(Song);
        ClampCursor;
      end;
    'song.swing': Song.Swing := EnsureRange(v, 0, 0.6);
    'song.echoT': Song.EchoTime := EnsureRange(v, 0.02, 1.5);
    'song.echoF': Song.EchoFeedback := EnsureRange(v, 0, 0.9);
    'song.echoM': Song.EchoMix := EnsureRange(v, 0, 1);
    'ch.vol': if ChanCount > 0 then Song.Channels[CurChan].Volume := EnsureRange(v, 0, 2);
  end;
  if Length(Song.Instruments) = 0 then Exit;
  ins := @Song.Instruments[CurInst];
  case key of
    'ins.attack': ins^.Attack := EnsureRange(v, 0, 4);
    'ins.decay': ins^.Decay := EnsureRange(v, 0.001, 8);
    'ins.sustain': ins^.Sustain := EnsureRange(v, 0, 1);
    'ins.release': ins^.Release := EnsureRange(v, 0.001, 8);
    'ins.volume': ins^.Volume := EnsureRange(v, 0, 2);
    'ins.cutoff': ins^.Cutoff := EnsureRange(v, 0, 18000);
    'ins.vibrato': ins^.Vibrato := EnsureRange(v, 0, 2);
    'ins.vibRate': ins^.VibRate := EnsureRange(v, 0.1, 20);
    'ins.drop': ins^.PitchDrop := EnsureRange(v, -48, 48);
    'ins.noise': ins^.NoiseMix := EnsureRange(v, 0, 1);
    'ins.detune': ins^.Detune := EnsureRange(v, -100, 100);
  end;
end;

function GetNum(const key: string): Single;
begin
  if not ParseNum(GetStr(key), Result) then Result := 0;
end;

function NumStep(const key: string): Single;
begin
  if (key = 'song.bpm') or (key = 'song.spb') or (key = 'song.len') or (key = 'ins.drop') or (key = 'ins.detune') then
    Result := 1
  else if key = 'ins.cutoff' then Result := 50
  else if key = 'ins.vibRate' then Result := 0.1
  else Result := 0.01;
  if ModShift then Result := Result / 5
  else if ModCtrl then Result := Result * 10;
end;

procedure CycleEnum(const key: string; d: Integer);
begin
  PushUndo;
  if (key = 'ins.wave') and (Length(Song.Instruments) > 0) then
    Song.Instruments[CurInst].Wave := (Song.Instruments[CurInst].Wave + d + 5) mod 5
  else if (key = 'ch.inst') and (ChanCount > 0) then
    Song.Channels[CurChan].Instrument := (Song.Channels[CurChan].Instrument + d + Length(Song.Instruments)) mod
      Length(Song.Instruments)
  else if (key = 'ch.mute') and (ChanCount > 0) then
    Song.Channels[CurChan].Muted := not Song.Channels[CurChan].Muted;
  MarkEdited;
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
    MarkEdited;
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
  case kind of
    pkEnum: DrawText(x + 5, y + 3, '< ' + txt + ' >', RGBA(160, 210, 255), fnSmall, ALIGN_LEFT, False);
    pkBool:
      begin
        RoundRect(x + 4, y + 4, 15, 14, 3, RGBA(22, 24, 28));
        if txt = 'yes' then FillRect(x + 8, y + 8, 7, 6, C_ACCENT);
      end;
  else
    DrawText(x + 5, y + 3, txt, C_TEXT, fnSmall, ALIGN_LEFT, False);
  end;
  if hover and (WheelY <> 0) and (kind = pkNum) and (Drag = drNone) then
  begin
    PushUndo;
    SetStr(key, F3(GetNum(key) + WheelY * NumStep(key)));
    WheelY := 0;
    MarkEdited;
  end;
  if hover and (LDown or RDown) and not Consumed then
  begin
    Consumed := True;
    EndEdit(True);
    case kind of
      pkText: if LDown then BeginEdit(key);
      pkEnum, pkBool: if LDown then CycleEnum(key, 1) else CycleEnum(key, -1);
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

procedure PropRow(x, y, w: Single; const key, caption: string; kind: TPropKind);
begin
  DrawText(x + 4, y + 3, caption, C_DIM, fnSmall, ALIGN_LEFT, False);
  ValueCell(x + w * 0.48, y, w * 0.52 - 4, key, kind);
end;

{ ---------- structure operations ---------- }

procedure AddPattern(duplicate: Boolean);
var
  n, c: Integer;
begin
  PushUndo;
  n := PatCount;
  SetLength(Song.Patterns, n + 1);
  if duplicate and (n > 0) then
  begin
    Song.Patterns[n].Name := Song.Patterns[CurPat].Name + '''';
    SetLength(Song.Patterns[n].Notes, ChanCount);
    for c := 0 to ChanCount - 1 do Song.Patterns[n].Notes[c] := Copy(Song.Patterns[CurPat].Notes[c]);
  end
  else
  begin
    Song.Patterns[n].Name := 'P' + IntToStr(n + 1);
    SetLength(Song.Patterns[n].Notes, 0);
  end;
  FixSong(Song);
  CurPat := n;
  MarkEdited;
end;

procedure DeletePattern;
var
  i, j, n: Integer;
begin
  if PatCount <= 1 then
  begin
    Status('A song needs at least one pattern');
    Exit;
  end;
  PushUndo;
  for i := CurPat to PatCount - 2 do Song.Patterns[i] := Song.Patterns[i + 1];
  SetLength(Song.Patterns, PatCount - 1);
  // drop the pattern from the order list and shift references
  n := 0;
  for i := 0 to High(Song.Order) do
    if Song.Order[i] <> CurPat then
    begin
      j := Song.Order[i];
      if j > CurPat then Dec(j);
      Song.Order[n] := j;
      Inc(n);
    end;
  SetLength(Song.Order, Max(1, n));
  if n = 0 then Song.Order[0] := 0;
  ClampCursor;
  MarkEdited;
end;

procedure OrderInsert(atEnd: Boolean);
var
  i, p: Integer;
begin
  PushUndo;
  SetLength(Song.Order, Length(Song.Order) + 1);
  if atEnd then p := High(Song.Order)
  else
  begin
    p := CurOrder + 1;
    for i := High(Song.Order) downto p + 1 do Song.Order[i] := Song.Order[i - 1];
  end;
  Song.Order[p] := CurPat;
  CurOrder := p;
  MarkEdited;
end;

procedure OrderRemove;
var
  i: Integer;
begin
  if Length(Song.Order) <= 1 then Exit;
  PushUndo;
  for i := CurOrder to High(Song.Order) - 1 do Song.Order[i] := Song.Order[i + 1];
  SetLength(Song.Order, Length(Song.Order) - 1);
  ClampCursor;
  CurPat := Song.Order[CurOrder];
  MarkEdited;
end;

procedure OrderMove(d: Integer);
var
  j, t: Integer;
begin
  j := CurOrder + d;
  if (j < 0) or (j > High(Song.Order)) then Exit;
  PushUndo;
  t := Song.Order[CurOrder];
  Song.Order[CurOrder] := Song.Order[j];
  Song.Order[j] := t;
  CurOrder := j;
  MarkEdited;
end;

procedure AddChannel;
var
  n: Integer;
begin
  if ChanCount >= 12 then Exit;
  PushUndo;
  n := ChanCount;
  SetLength(Song.Channels, n + 1);
  Song.Channels[n].Name := 'ch' + IntToStr(n + 1);
  Song.Channels[n].Instrument := CurInst;
  Song.Channels[n].Volume := 1;
  FixSong(Song);
  CurChan := n;
  MarkEdited;
end;

procedure DeleteChannel;
var
  i, p: Integer;
begin
  if ChanCount <= 1 then Exit;
  PushUndo;
  for p := 0 to PatCount - 1 do
  begin
    for i := CurChan to ChanCount - 2 do Song.Patterns[p].Notes[i] := Song.Patterns[p].Notes[i + 1];
    SetLength(Song.Patterns[p].Notes, ChanCount - 1);
  end;
  for i := CurChan to ChanCount - 2 do Song.Channels[i] := Song.Channels[i + 1];
  SetLength(Song.Channels, ChanCount - 1);
  ClampCursor;
  MarkEdited;
end;

procedure AddInstrument(duplicate: Boolean);
var
  n: Integer;
begin
  PushUndo;
  n := Length(Song.Instruments);
  SetLength(Song.Instruments, n + 1);
  if duplicate then
  begin
    Song.Instruments[n] := Song.Instruments[CurInst];
    Song.Instruments[n].Name := Song.Instruments[CurInst].Name + ' 2';
  end
  else
    Song.Instruments[n] := NewInstrument;
  CurInst := n;
end;

procedure DeleteInstrument;
var
  c, i: Integer;
begin
  if Length(Song.Instruments) <= 1 then Exit;
  for c := 0 to ChanCount - 1 do
    if Song.Channels[c].Instrument = CurInst then
    begin
      Status('Instrument is used by channel "' + Song.Channels[c].Name + '"');
      Exit;
    end;
  PushUndo;
  for i := CurInst to High(Song.Instruments) - 1 do Song.Instruments[i] := Song.Instruments[i + 1];
  SetLength(Song.Instruments, Length(Song.Instruments) - 1);
  for c := 0 to ChanCount - 1 do
    if Song.Channels[c].Instrument > CurInst then Dec(Song.Channels[c].Instrument);
  ClampCursor;
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

var
  b: TBuf;
begin
  FillRect(0, 0, WIN_W, TOP_H, C_PANEL);
  FillRect(0, TOP_H - 1, WIN_W, 1, C_LINE);
  x := 8;
  if TB(56, 'Save', False, Modified) then SaveCurrent;
  Gap;
  if TB(52, 'Undo', False, Length(UndoStack) > 0) then DoUndo;
  if TB(52, 'Redo', False, Length(RedoStack) > 0) then DoRedo;
  Gap;
  if TB(126, 'Play song (Enter)', PlayMode = 1) then StartPlay(1);
  if TB(140, 'Play pattern (Space)', PlayMode = 2) then StartPlay(2);
  if TB(80, 'Stop (Esc)', False, PlayMode <> 0) then StopPlay;
  if TB(70, 'Follow', Follow) then Follow := not Follow;
  Gap;
  DrawText(x, 13, 'octave', C_DIM, fnSmall, ALIGN_LEFT, False);
  x := x + 50;
  if TB(26, '-') then Octave := Max(0, Octave - 1);
  DrawText(x + 8, 13, IntToStr(Octave), C_TEXT, fnSmall, ALIGN_CENTER, False);
  x := x + 18;
  if TB(26, '+') then Octave := Min(8, Octave + 1);
  DrawText(x + 4, 13, 'step', C_DIM, fnSmall, ALIGN_LEFT, False);
  x := x + 38;
  if TB(26, '-') then EditStep := Max(0, EditStep - 1);
  DrawText(x + 8, 13, IntToStr(EditStep), C_TEXT, fnSmall, ALIGN_CENTER, False);
  x := x + 18;
  if TB(26, '+') then EditStep := Min(16, EditStep + 1);
  Gap;
  if TB(96, 'Export WAV') then
  begin
    b := RenderSong(Song, -1, -1, -1, False);
    if SaveWav(ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'export' + PathDelim +
      ChangeFileExt(CurFile, '.wav'), b) then
      Status(Format('Exported data\export\%s (%.1fs)', [ChangeFileExt(CurFile, '.wav'), Length(b) / RATE]));
  end;
  if Modified then DrawText(WIN_W - 10, 13, 'unsaved', RGBA(255, 150, 120), fnSmall, ALIGN_RIGHT, False);
end;

procedure DrawLeft;
var
  i: Integer;
  y: Single;
begin
  FillRect(0, TOP_H, LEFT_W, WIN_H - TOP_H - STATUS_H, C_PANEL);
  FillRect(LEFT_W - 1, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  DrawText(10, TOP_H + 6, Format('SONGS (%d)', [SongFiles.Count]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := TOP_H + 28;
  for i := 0 to SongFiles.Count - 1 do
  begin
    if y > TOP_H + 230 then Break;
    if SameText(SongFiles[i], CurFile) then FillRect(4, y, LEFT_W - 9, ROW_H - 2, C_SEL)
    else if Inside(4, y, LEFT_W - 9, ROW_H - 2) then FillRect(4, y, LEFT_W - 9, ROW_H - 2, C_PANEL2);
    DrawText(12, y + 2, SongFiles[i], C_TEXT, fnSmall, ALIGN_LEFT, False);
    if Inside(4, y, LEFT_W - 9, ROW_H - 2) and LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      if not SameText(SongFiles[i], CurFile) and ConfirmDiscard then OpenSong(SongFiles[i]);
    end;
    y := y + ROW_H;
  end;
  y := TOP_H + 240;
  if Button(8, y, 70, 24, 'New') then NewSongFile(False);
  if Button(82, y, 90, 24, 'Duplicate') then NewSongFile(True);
  y := y + 36;
  FillRect(0, y - 6, LEFT_W, 1, C_LINE);
  DrawText(10, y, 'SONG', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y + 22;
  PropRow(4, y, LEFT_W - 8, 'song.name', 'title', pkText); y := y + ROW_H;
  PropRow(4, y, LEFT_W - 8, 'song.bpm', 'tempo (bpm)', pkNum); y := y + ROW_H;
  PropRow(4, y, LEFT_W - 8, 'song.spb', 'steps / beat', pkNum); y := y + ROW_H;
  PropRow(4, y, LEFT_W - 8, 'song.len', 'pattern length', pkNum); y := y + ROW_H;
  PropRow(4, y, LEFT_W - 8, 'song.swing', 'swing', pkNum); y := y + ROW_H;
  PropRow(4, y, LEFT_W - 8, 'song.echoT', 'echo time', pkNum); y := y + ROW_H;
  PropRow(4, y, LEFT_W - 8, 'song.echoF', 'echo feedback', pkNum); y := y + ROW_H;
  PropRow(4, y, LEFT_W - 8, 'song.echoM', 'echo mix', pkNum); y := y + ROW_H + 10;
  DrawText(10, y, Format('length %.1fs (%d patterns played)', [SongDuration(Song), Length(Song.Order)]), C_DIM, fnSmall,
    ALIGN_LEFT, False);
  y := y + 18;
  if UsedBy <> '' then DrawText(10, y, 'used by: ' + UsedBy, RGBA(140, 220, 140), fnSmall, ALIGN_LEFT, False)
  else DrawText(10, y, 'not used by any map yet', RGBA(220, 170, 110), fnSmall, ALIGN_LEFT, False);
end;

procedure DrawGrid;
var
  x0, cw, y, x, gridH: Single;
  c, r, visible, n, ps, playRow, playPat: Integer;
  note: SmallInt;
  txt: string;
  tc: TRGBA;
begin
  x0 := MID_X + 6;
  // pattern selector
  DrawText(x0 + 4, TOP_H + 8, 'PATTERN', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  if Button(x0 + 70, TOP_H + 5, 26, 24, '<', False, CurPat > 0) then CurPat := CurPat - 1;
  DrawText(x0 + 134, TOP_H + 8, Format('%d / %d', [CurPat + 1, PatCount]), C_TEXT, fnSmall, ALIGN_CENTER, False);
  if Button(x0 + 172, TOP_H + 5, 26, 24, '>', False, CurPat < PatCount - 1) then CurPat := CurPat + 1;
  ValueCell(x0 + 206, TOP_H + 5, 110, 'pat.name', pkText);
  if Button(x0 + 322, TOP_H + 5, 50, 24, 'New') then AddPattern(False);
  if Button(x0 + 376, TOP_H + 5, 50, 24, 'Copy') then AddPattern(True);
  if Button(x0 + 430, TOP_H + 5, 58, 24, 'Delete', False, PatCount > 1) then DeletePattern;
  if Button(x0 + 500, TOP_H + 5, 76, 24, '+ channel', False, ChanCount < 12) then AddChannel;
  if Button(x0 + 580, TOP_H + 5, 76, 24, '- channel', False, ChanCount > 1) then DeleteChannel;
  if (PatCount = 0) or (ChanCount = 0) then Exit;

  cw := (MID_W - 12 - ROWNUM_W) / ChanCount;
  // channel headers
  y := GRID_Y - 38;
  for c := 0 to ChanCount - 1 do
  begin
    x := x0 + ROWNUM_W + c * cw;
    if c = CurChan then FillRect(x + 1, y, cw - 2, 34, C_SEL) else FillRect(x + 1, y, cw - 2, 34, C_PANEL2);
    DrawText(x + 5, y + 1, Song.Channels[c].Name, C_TEXT, fnSmall, ALIGN_LEFT, False);
    DrawText(x + 5, y + 17, Song.Instruments[Song.Channels[c].Instrument].Name, C_DIM, fnSmall, ALIGN_LEFT, False);
    if Song.Channels[c].Muted then DrawText(x + cw - 6, y + 1, 'M', RGBA(255, 110, 100), fnSmall, ALIGN_RIGHT, False);
    if Inside(x + 1, y, cw - 2, 34) and (LDown or RDown) and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      CurChan := c;
      CurInst := Song.Channels[c].Instrument;
      if RDown then
      begin
        PushUndo;
        Song.Channels[c].Muted := not Song.Channels[c].Muted;
        MarkEdited;
      end;
    end;
  end;
  // rows
  gridH := WIN_H - STATUS_H - ORDER_H - GRID_Y - 6;
  visible := Trunc(gridH / CELL_H);
  if CurRow < GridScroll then GridScroll := CurRow;
  if CurRow >= GridScroll + visible then GridScroll := CurRow - visible + 1;
  GridScroll := EnsureRange(GridScroll, 0, Max(0, Song.PatternLen - visible));
  // playing row (only when the shown pattern is the one sounding)
  playRow := -1;
  ps := PlayStep;
  if ps >= 0 then
  begin
    if PlayMode = 2 then playPat := PlayPattern
    else playPat := Song.Order[EnsureRange(PlayFromOrder + ps div Song.PatternLen, 0, High(Song.Order))];
    if playPat = CurPat then playRow := ps mod Song.PatternLen;
  end;
  n := 0;
  for r := GridScroll to Song.PatternLen - 1 do
  begin
    if n >= visible then Break;
    y := GRID_Y + n * CELL_H;
    Inc(n);
    if r = playRow then FillRect(x0, y, MID_W - 12, CELL_H - 1, RGBA(90, 80, 40))
    else if r mod Song.StepsPerBeat = 0 then FillRect(x0, y, MID_W - 12, CELL_H - 1, RGBA(40, 43, 51))
    else FillRect(x0, y, MID_W - 12, CELL_H - 1, RGBA(30, 32, 38));
    if r mod Song.StepsPerBeat = 0 then tc := C_TEXT else tc := C_DIM;
    DrawText(x0 + ROWNUM_W - 8, y + 2, Format('%.2d', [r]), tc, fnSmall, ALIGN_RIGHT, False);
    for c := 0 to ChanCount - 1 do
    begin
      x := x0 + ROWNUM_W + c * cw;
      note := Song.Patterns[CurPat].Notes[c][r];
      if (r = CurRow) and (c = CurChan) then
      begin
        FillRect(x + 1, y, cw - 2, CELL_H - 1, C_ACCENT);
        FillRect(x + 3, y + 2, cw - 6, CELL_H - 5, RGBA(70, 110, 170));
      end;
      txt := NoteName(note);
      if note > 0 then tc := RGBA(240, 235, 220)
      else if note = NOTE_OFF then tc := RGBA(255, 140, 110)
      else tc := RGBA(80, 84, 94);
      if Song.Channels[c].Muted then tc := Shade(tc, 0.5);
      DrawText(x + cw / 2, y + 2, txt, tc, fnSmall, ALIGN_CENTER, False);
      if Inside(x + 1, y, cw - 2, CELL_H - 1) then
      begin
        if LDown and not Consumed then
        begin
          Consumed := True;
          EndEdit(True);
          CurRow := r;
          CurChan := c;
          CurInst := Song.Channels[c].Instrument;
          if note > 0 then PreviewNote(note);
        end;
        if (WheelY <> 0) and (note > 0) then
        begin
          PushUndo;
          if ModShift then note := EnsureRange(note + Round(WheelY) * 12, 1, 127)
          else note := EnsureRange(note + Round(WheelY), 1, 127);
          Song.Patterns[CurPat].Notes[c][r] := note;
          PreviewNote(note);
          WheelY := 0;
          MarkEdited;
        end;
      end;
    end;
  end;
  if Inside(x0, GRID_Y, MID_W, gridH) and (WheelY <> 0) then
  begin
    GridScroll := GridScroll - Round(WheelY) * 2;
    WheelY := 0;
  end;
end;

procedure DrawOrder;
var
  y0, x, cw: Single;
  i, n, ps, playIdx: Integer;
  c: TRGBA;
begin
  y0 := WIN_H - STATUS_H - ORDER_H;
  FillRect(MID_X, y0, MID_W, ORDER_H, C_PANEL);
  FillRect(MID_X, y0, MID_W, 1, C_LINE);
  DrawText(MID_X + 10, y0 + 6, 'ORDER (arrangement) - click to edit that pattern', C_ACCENT, fnSmall, ALIGN_LEFT, False);
  cw := 48;
  n := Trunc((MID_W - 20) / (cw + 4));
  if CurOrder < OrderScroll then OrderScroll := CurOrder;
  if CurOrder >= OrderScroll + n then OrderScroll := CurOrder - n + 1;
  OrderScroll := EnsureRange(OrderScroll, 0, Max(0, Length(Song.Order) - n));
  playIdx := -1;
  ps := PlayStep;
  if (ps >= 0) and (PlayMode = 1) then playIdx := PlayFromOrder + ps div Song.PatternLen;
  for i := OrderScroll to High(Song.Order) do
  begin
    if i - OrderScroll >= n then Break;
    x := MID_X + 10 + (i - OrderScroll) * (cw + 4);
    if i = playIdx then c := RGBA(150, 120, 50)
    else if i = CurOrder then c := C_SEL
    else c := C_PANEL2;
    RoundRect(x, y0 + 28, cw, 26, 4, c);
    DrawText(x + cw / 2, y0 + 32, Song.Patterns[Song.Order[i]].Name, C_TEXT, fnSmall, ALIGN_CENTER, False);
    if Inside(x, y0 + 28, cw, 26) and LDown and not Consumed then
    begin
      Consumed := True;
      CurOrder := i;
      CurPat := Song.Order[i];
    end;
  end;
  if Button(MID_X + 10, y0 + 60, 120, 24, '+ pattern at end') then OrderInsert(True);
  if Button(MID_X + 134, y0 + 60, 110, 24, 'insert after') then OrderInsert(False);
  if Button(MID_X + 248, y0 + 60, 70, 24, 'remove', False, Length(Song.Order) > 1) then OrderRemove;
  if Button(MID_X + 322, y0 + 60, 36, 24, '<', False, CurOrder > 0) then OrderMove(-1);
  if Button(MID_X + 362, y0 + 60, 36, 24, '>', False, CurOrder < High(Song.Order)) then OrderMove(1);
end;

procedure DrawRight;
var
  x0, y, w: Single;
  i: Integer;
begin
  x0 := RIGHT_X;
  w := RIGHT_W;
  FillRect(x0, TOP_H, w, WIN_H - TOP_H - STATUS_H, C_PANEL);
  FillRect(x0, TOP_H, 1, WIN_H - TOP_H - STATUS_H, C_LINE);
  DrawText(x0 + 10, TOP_H + 6, Format('INSTRUMENTS (%d)', [Length(Song.Instruments)]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := TOP_H + 28;
  for i := 0 to High(Song.Instruments) do
  begin
    if y > TOP_H + 200 then Break;
    if i = CurInst then FillRect(x0 + 4, y, w - 8, ROW_H - 2, C_SEL)
    else if Inside(x0 + 4, y, w - 8, ROW_H - 2) then FillRect(x0 + 4, y, w - 8, ROW_H - 2, C_PANEL2);
    DrawText(x0 + 12, y + 2, Song.Instruments[i].Name, C_TEXT, fnSmall, ALIGN_LEFT, False);
    DrawText(x0 + w - 12, y + 2, WaveNames[EnsureRange(Song.Instruments[i].Wave, 0, 4)], C_DIM, fnSmall, ALIGN_RIGHT, False);
    if Inside(x0 + 4, y, w - 8, ROW_H - 2) and LDown and not Consumed then
    begin
      Consumed := True;
      EndEdit(True);
      CurInst := i;
    end;
    y := y + ROW_H;
  end;
  y := TOP_H + 206;
  if Button(x0 + 8, y, 56, 24, 'New') then AddInstrument(False);
  if Button(x0 + 68, y, 56, 24, 'Copy') then AddInstrument(True);
  if Button(x0 + 128, y, 60, 24, 'Delete', False, Length(Song.Instruments) > 1) then DeleteInstrument;
  if Button(x0 + 192, y, 80, 24, 'Preview') then
    PlayBuffer(RenderNotePreview(Song.Instruments[CurInst], (Octave + 1) * 12, 0.5), 0.9 / Max(0.05, MasterVolume));
  y := y + 34;
  PropRow(x0 + 4, y, w - 8, 'ins.name', 'name', pkText); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.wave', 'wave', pkEnum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.attack', 'attack (s)', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.decay', 'decay (s)', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.sustain', 'sustain level', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.release', 'release (s)', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.volume', 'volume', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.cutoff', 'low-pass (Hz, 0 off)', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.vibrato', 'vibrato (semitones)', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.vibRate', 'vibrato rate (Hz)', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.drop', 'pitch drop (semitones)', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.noise', 'noise mix', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ins.detune', 'detune (cents)', pkNum); y := y + ROW_H + 12;
  FillRect(x0, y - 6, w, 1, C_LINE);
  if ChanCount = 0 then Exit;
  DrawText(x0 + 10, y, Format('CHANNEL %d', [CurChan + 1]), C_ACCENT, fnSmall, ALIGN_LEFT, False);
  y := y + 22;
  PropRow(x0 + 4, y, w - 8, 'ch.name', 'name', pkText); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ch.inst', 'instrument', pkEnum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ch.vol', 'volume', pkNum); y := y + ROW_H;
  PropRow(x0 + 4, y, w - 8, 'ch.mute', 'muted', pkBool); y := y + ROW_H;
  DrawText(x0 + 10, y + 6, 'right-click a channel header to mute it', C_DIM, fnSmall, ALIGN_LEFT, False);
end;

{ ---------- input ---------- }

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
      SetStr(ScrubKey, F3(v));
      MarkEdited;
    end;
  end
  else
  begin
    if not ScrubMoved then BeginEdit(ScrubKey);
    Drag := drNone;
  end;
end;

procedure HandleKey(key: TSDL_Keycode);
var
  semi: Integer;
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
      SDLK_S: SaveCurrent;
      SDLK_Z: if ModShift then DoRedo else DoUndo;
      SDLK_Y: DoRedo;
      SDLK_C:
        begin
          ClipPattern.Name := Song.Patterns[CurPat].Name;
          ClipPattern.Notes := Copy(Song.Patterns[CurPat].Notes);
          for semi := 0 to High(ClipPattern.Notes) do ClipPattern.Notes[semi] := Copy(Song.Patterns[CurPat].Notes[semi]);
          HasClip := True;
          Status('Pattern copied');
        end;
      SDLK_V:
        if HasClip then
        begin
          PushUndo;
          for semi := 0 to Min(High(ClipPattern.Notes), ChanCount - 1) do
            Song.Patterns[CurPat].Notes[semi] := Copy(ClipPattern.Notes[semi]);
          FixSong(Song);
          MarkEdited;
          Status('Pattern pasted');
        end;
    end;
    Exit;
  end;
  case key of
    SDLK_UP: CurRow := (CurRow - 1 + Song.PatternLen) mod Song.PatternLen;
    SDLK_DOWN: CurRow := (CurRow + 1) mod Song.PatternLen;
    SDLK_LEFT: CurChan := Max(0, CurChan - 1);
    SDLK_RIGHT: CurChan := Min(ChanCount - 1, CurChan + 1);
    SDLK_TAB: CurChan := (CurChan + 1) mod Max(1, ChanCount);
    SDLK_PAGEUP: CurPat := Max(0, CurPat - 1);
    SDLK_PAGEDOWN: CurPat := Min(PatCount - 1, CurPat + 1);
    SDLK_DELETE, SDLK_BACKSPACE: SetCell(NOTE_NONE, True);
    SDLK_A: SetCell(NOTE_OFF, True);
    SDLK_LEFTBRACKET: Octave := Max(0, Octave - 1);
    SDLK_RIGHTBRACKET: Octave := Min(8, Octave + 1);
    SDLK_MINUS: EditStep := Max(0, EditStep - 1);
    SDLK_EQUALS: EditStep := Min(16, EditStep + 1);
    SDLK_SPACE: if PlayMode = 2 then StopPlay else StartPlay(2);
    SDLK_RETURN: StartPlay(1);
    SDLK_ESCAPE: StopPlay;
  else
    if PianoKey(key, semi) then SetCell(EnsureRange((Octave + 1) * 12 + semi, 1, 127), True);
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
  Dt, pos: Single;
  ShotFile, startFile: string;
  ShotFrames, ArgI, ps: Integer;

begin
  MusicDir := ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'music' + PathDelim;
  ForceDirectories(MusicDir);
  SongFiles := TStringList.Create;
  if not SDL_Init(SDL_INIT_VIDEO) then Halt(1);
  if not SDL_CreateWindowAndRenderer('MusicEdit', WIN_W, WIN_H, SDL_WINDOW_RESIZABLE, @Window, @Renderer) then
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
  ScanSongs;
  ShotFile := '';
  startFile := '';
  for ArgI := 1 to ParamCount - 1 do
    if ParamStr(ArgI) = '--shot' then
    begin
      ShotFile := ParamStr(ArgI + 1);
      SoundMuted := True;
      if ArgI + 2 <= ParamCount then startFile := ParamStr(ArgI + 2);
    end;
  if (startFile = '') and (SongFiles.Count > 0) then startFile := SongFiles[0];
  if startFile <> '' then OpenSong(startFile)
  else
  begin
    Song := NewSong;
    CurFile := 'newsong.json';
    SavedJson := '';
  end;
  if ShotFile <> '' then
  begin
    CurPat := Min(9, PatCount - 1);
    CurRow := 4;
    CurChan := Min(4, ChanCount - 1);
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
    ClampCursor;
    // re-render shortly after an edit while playing, continuing from the same spot
    if RerenderAt >= 0 then
    begin
      RerenderAt := RerenderAt - Dt;
      if (RerenderAt < 0) and (PlayMode <> 0) then
      begin
        pos := MusicPosition;
        StartPlay(PlayMode, pos);
      end;
    end;
    // follow the song while it plays
    ps := PlayStep;
    if Follow and (ps >= 0) and (PlayMode = 1) then
    begin
      CurOrder := EnsureRange(PlayFromOrder + ps div Song.PatternLen, 0, High(Song.Order));
      CurPat := Song.Order[CurOrder];
    end;

    SDL_SetRenderDrawColor(Renderer, C_BG.r, C_BG.g, C_BG.b, 255);
    SDL_RenderClear(Renderer);
    DrawToolbar;
    DrawLeft;
    DrawRight;
    DrawOrder;
    DrawGrid;
    FillRect(0, WIN_H - STATUS_H, WIN_W, STATUS_H, C_PANEL);
    FillRect(0, WIN_H - STATUS_H, WIN_W, 1, C_LINE);
    if StatusTime > 0 then
      DrawText(10, WIN_H - STATUS_H + 3, StatusMsg, C_ACCENT, fnSmall, ALIGN_LEFT, False)
    else
      DrawText(10, WIN_H - STATUS_H + 3, Format('Octave %d  step %d  |  notes: Z..M / Q..I  A off  Del clear  |  ' +
        'Space pattern  Enter song  Esc stop  |  [ ] octave  - = step  |  Ctrl+S save', [Octave, EditStep]), C_DIM,
        fnSmall, ALIGN_LEFT, False);
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
    if Modified then SDL_SetWindowTitle(Window, PAnsiChar('MusicEdit - ' + CurFile + ' *'))
    else SDL_SetWindowTitle(Window, PAnsiChar('MusicEdit - ' + CurFile));
  end;
  SfxDone;
  GfxDone;
  SongFiles.Free;
  SDL_DestroyRenderer(Renderer);
  SDL_DestroyWindow(Window);
  SDL_Quit;
end.
