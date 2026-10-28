unit music;

{ Tracker-style music for Brewhold Defense (data\music\*.json), rendered offline into a looping buffer.

  Song   : bpm, stepsPerBeat, patternLength, swing, echo, instruments, channels, patterns, order
  Pattern: one track string per channel, one token per step:
             "C-4" / "F#3" note (C-0 .. B-9)   "---" nothing (previous note keeps sounding)   "===" note off
  Channel: plays one instrument at a volume; can be muted.
  Instrument: wave (sine / saw / square / triangle / noise), ADSR, volume, low-pass cutoff, vibrato,
              pitchDrop (semitones falling at the note start - kicks & toms), noise mix, detune (cents). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, StrUtils, fpjson, jsonparser, synth;

const
  NOTE_NONE = 0;
  NOTE_OFF = -1;

type
  TInstrument = record
    Name: string;
    Wave: Integer;
    Attack, Decay, Sustain, Release: Single;
    Volume, Cutoff, Vibrato, VibRate, PitchDrop, NoiseMix, Detune: Single;
  end;

  TChannel = record
    Name: string;
    Instrument: Integer;
    Volume: Single;
    Muted: Boolean;
  end;

  TPattern = record
    Name: string;
    Notes: array of array of SmallInt;     // [channel][step]
  end;

  TSong = record
    Name: string;
    Bpm, Swing: Single;
    StepsPerBeat, PatternLen: Integer;
    EchoTime, EchoFeedback, EchoMix: Single;
    Instruments: array of TInstrument;
    Channels: array of TChannel;
    Patterns: array of TPattern;
    Order: array of Integer;
  end;

function NoteName(n: Integer): string;
function ParseNote(const s: string): Integer;
function NoteFreq(n: Integer): Single;
function NewInstrument: TInstrument;
function NewSong: TSong;
procedure FixSong(var s: TSong);                   // makes pattern sizes match channels / length
function StepDuration(const s: TSong): Single;
function SongDuration(const s: TSong): Single;

function SongToJSON(const s: TSong): string;
function SongFromJSONText(const txt: string; out s: TSong; out err: string): Boolean;
function LoadSong(const fn: string; out s: TSong; out err: string): Boolean;
function SaveSong(const fn: string; const s: TSong): Boolean;

// orderFrom/orderTo: part of the order list (-1 = all). patternOnly >= 0 renders that pattern once.
// loop = fold the release / echo tail into the start so the buffer loops seamlessly.
function RenderSong(const s: TSong; orderFrom, orderTo, patternOnly: Integer; loop: Boolean): TBuf;
function RenderNotePreview(const inst: TInstrument; note: Integer; seconds: Single): TBuf;

implementation

const
  SEMI = 0.057762265;   // ln(2) / 12
  NoteNames: array[0..11] of string = ('C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-');

function NoteName(n: Integer): string;
begin
  if n = NOTE_NONE then Result := '---'
  else if n = NOTE_OFF then Result := '==='
  else Result := NoteNames[n mod 12] + IntToStr(n div 12 - 1);
end;

function ParseNote(const s: string): Integer;
var
  t: string;
  i, oct: Integer;
begin
  t := UpperCase(Trim(s));
  if (t = '') or (t = '---') or (t = '.') then Exit(NOTE_NONE);
  if (t = '===') or (t = 'OFF') then Exit(NOTE_OFF);
  Result := NOTE_NONE;
  if Length(t) = 2 then t := t[1] + '-' + t[2];
  if Length(t) < 3 then Exit;
  for i := 0 to 11 do
    if Copy(t, 1, 2) = NoteNames[i] then
      if TryStrToInt(Copy(t, 3, 2), oct) then Exit(EnsureRange((oct + 1) * 12 + i, 1, 127));
end;

function NoteFreq(n: Integer): Single;
begin
  Result := 440 * Power(2, (n - 69) / 12);
end;

function NewInstrument: TInstrument;
begin
  Result := Default(TInstrument);
  Result.Name := 'instrument';
  Result.Wave := 3;
  Result.Attack := 0.01;
  Result.Decay := 0.2;
  Result.Sustain := 0.5;
  Result.Release := 0.15;
  Result.Volume := 0.6;
  Result.VibRate := 5.5;
end;

function NewSong: TSong;
begin
  Result := Default(TSong);
  Result.Name := 'New Song';
  Result.Bpm := 110;
  Result.StepsPerBeat := 4;
  Result.PatternLen := 16;
  Result.EchoTime := 0.27;
  Result.EchoFeedback := 0.3;
  Result.EchoMix := 0.15;
  SetLength(Result.Instruments, 1);
  Result.Instruments[0] := NewInstrument;
  SetLength(Result.Channels, 4);
  Result.Channels[0].Name := 'Bass';
  Result.Channels[1].Name := 'Chords';
  Result.Channels[2].Name := 'Lead';
  Result.Channels[3].Name := 'Drums';
  Result.Channels[0].Volume := 1; Result.Channels[1].Volume := 1;
  Result.Channels[2].Volume := 1; Result.Channels[3].Volume := 1;
  SetLength(Result.Patterns, 1);
  Result.Patterns[0].Name := 'A';
  SetLength(Result.Order, 1);
  Result.Order[0] := 0;
  FixSong(Result);
end;

procedure FixSong(var s: TSong);
var
  p, c, k: Integer;
begin
  s.PatternLen := EnsureRange(s.PatternLen, 1, 128);
  s.StepsPerBeat := EnsureRange(s.StepsPerBeat, 1, 16);
  s.Bpm := EnsureRange(s.Bpm, 20, 400);
  if Length(s.Instruments) = 0 then
  begin
    SetLength(s.Instruments, 1);
    s.Instruments[0] := NewInstrument;
  end;
  for c := 0 to High(s.Channels) do
    s.Channels[c].Instrument := EnsureRange(s.Channels[c].Instrument, 0, High(s.Instruments));
  for p := 0 to High(s.Patterns) do
  begin
    k := Length(s.Patterns[p].Notes);
    SetLength(s.Patterns[p].Notes, Length(s.Channels));
    for c := 0 to High(s.Channels) do
    begin
      if c >= k then SetLength(s.Patterns[p].Notes[c], 0);
      k := Length(s.Patterns[p].Notes[c]);
      SetLength(s.Patterns[p].Notes[c], s.PatternLen);
      while k < s.PatternLen do
      begin
        s.Patterns[p].Notes[c][k] := NOTE_NONE;
        Inc(k);
      end;
    end;
  end;
  for k := 0 to High(s.Order) do s.Order[k] := EnsureRange(s.Order[k], 0, Max(0, High(s.Patterns)));
end;

function StepDuration(const s: TSong): Single;
begin
  Result := 60 / Max(1, s.Bpm) / Max(1, s.StepsPerBeat);
end;

function SongDuration(const s: TSong): Single;
begin
  Result := Length(s.Order) * s.PatternLen * StepDuration(s);
end;

{ ---------- JSON ---------- }

function Q(const t: string): string;
begin
  Result := '"' + StringToJSONString(t) + '"';
end;

function SongToJSON(const s: TSong): string;
var
  sb: TStringList;
  i, c, k: Integer;
  line, trk: string;
  ins: TInstrument;
begin
  sb := TStringList.Create;
  try
    sb.Add('{');
    sb.Add('  "name": ' + Q(s.Name) + ',');
    sb.Add(Format('  "bpm": %s, "stepsPerBeat": %d, "patternLength": %d, "swing": %s,',
      [F3(s.Bpm), s.StepsPerBeat, s.PatternLen, F3(s.Swing)]));
    sb.Add(Format('  "echo": {"time": %s, "feedback": %s, "mix": %s},', [F3(s.EchoTime), F3(s.EchoFeedback), F3(s.EchoMix)]));
    sb.Add('  "instruments": [');
    for i := 0 to High(s.Instruments) do
    begin
      ins := s.Instruments[i];
      line := Format('    {"name": %s, "wave": "%s", "attack": %s, "decay": %s, "sustain": %s, "release": %s, ' +
        '"volume": %s, "cutoff": %s, "vibrato": %s, "vibRate": %s, "pitchDrop": %s, "noise": %s, "detune": %s}',
        [Q(ins.Name), WaveNames[EnsureRange(ins.Wave, 0, 4)], F3(ins.Attack), F3(ins.Decay), F3(ins.Sustain),
         F3(ins.Release), F3(ins.Volume), F3(ins.Cutoff), F3(ins.Vibrato), F3(ins.VibRate), F3(ins.PitchDrop),
         F3(ins.NoiseMix), F3(ins.Detune)]);
      if i < High(s.Instruments) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add('  ],');
    sb.Add('  "channels": [');
    for c := 0 to High(s.Channels) do
    begin
      line := Format('    {"name": %s, "instrument": %d, "volume": %s%s}', [Q(s.Channels[c].Name),
        s.Channels[c].Instrument, F3(s.Channels[c].Volume), IfThen(s.Channels[c].Muted, ', "muted": true', '')]);
      if c < High(s.Channels) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add('  ],');
    sb.Add('  "patterns": [');
    for i := 0 to High(s.Patterns) do
    begin
      sb.Add('    {"name": ' + Q(s.Patterns[i].Name) + ', "tracks": [');
      for c := 0 to High(s.Channels) do
      begin
        trk := '';
        for k := 0 to s.PatternLen - 1 do
        begin
          if k > 0 then trk := trk + ' ';
          trk := trk + NoteName(s.Patterns[i].Notes[c][k]);
        end;
        line := '      "' + trk + '"';
        if c < High(s.Channels) then line := line + ',';
        sb.Add(line);
      end;
      line := '    ]}';
      if i < High(s.Patterns) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add('  ],');
    line := '  "order": [';
    for i := 0 to High(s.Order) do
    begin
      if i > 0 then line := line + ', ';
      line := line + IntToStr(s.Order[i]);
    end;
    sb.Add(line + ']');
    sb.Add('}');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

function JN(o: TJSONObject; const k: string; def: Single): Single;
var
  d: TJSONData;
begin
  Result := def;
  if o = nil then Exit;
  d := o.Find(k);
  if (d <> nil) and (d.JSONType = jtNumber) then Result := d.AsFloat;
end;

function JS(o: TJSONObject; const k, def: string): string;
var
  d: TJSONData;
begin
  Result := def;
  if o = nil then Exit;
  d := o.Find(k);
  if (d <> nil) and (d.JSONType = jtString) then Result := d.AsString;
end;

function Tokens(const line: string): TStringArray;
var
  i, n: Integer;
  cur: string;
begin
  SetLength(Result, 0);
  cur := '';
  for i := 1 to Length(line) + 1 do
    if (i > Length(line)) or (line[i] in [' ', #9, ',']) then
    begin
      if cur <> '' then
      begin
        n := Length(Result);
        SetLength(Result, n + 1);
        Result[n] := cur;
        cur := '';
      end;
    end
    else
      cur := cur + line[i];
end;

function SongFromJSONText(const txt: string; out s: TSong; out err: string): Boolean;
var
  d: TJSONData;
  root, o, e: TJSONObject;
  a, t: TJSONArray;
  i, c, k, w: Integer;
  toks: TStringArray;
begin
  Result := False;
  err := '';
  s := NewSong;
  try
    d := GetJSON(txt);
  except
    on ex: Exception do
    begin
      err := ex.Message;
      Exit;
    end;
  end;
  try
    if d.JSONType <> jtObject then
    begin
      err := 'not a JSON object';
      Exit;
    end;
    root := TJSONObject(d);
    s.Name := JS(root, 'name', 'Song');
    s.Bpm := JN(root, 'bpm', 110);
    s.StepsPerBeat := Round(JN(root, 'stepsPerBeat', 4));
    s.PatternLen := Round(JN(root, 'patternLength', 16));
    s.Swing := JN(root, 'swing', 0);
    e := nil;
    if (root.Find('echo') <> nil) and (root.Find('echo').JSONType = jtObject) then e := TJSONObject(root.Find('echo'));
    s.EchoTime := JN(e, 'time', 0.27);
    s.EchoFeedback := JN(e, 'feedback', 0.3);
    s.EchoMix := JN(e, 'mix', 0);
    SetLength(s.Instruments, 0);
    if (root.Find('instruments') <> nil) and (root.Find('instruments').JSONType = jtArray) then
    begin
      a := TJSONArray(root.Find('instruments'));
      SetLength(s.Instruments, a.Count);
      for i := 0 to a.Count - 1 do
      begin
        o := TJSONObject(a.Items[i]);
        s.Instruments[i] := NewInstrument;
        s.Instruments[i].Name := JS(o, 'name', 'instrument');
        for w := 0 to 4 do
          if SameText(WaveNames[w], JS(o, 'wave', 'triangle')) then s.Instruments[i].Wave := w;
        s.Instruments[i].Attack := JN(o, 'attack', 0.01);
        s.Instruments[i].Decay := JN(o, 'decay', 0.2);
        s.Instruments[i].Sustain := JN(o, 'sustain', 0.5);
        s.Instruments[i].Release := JN(o, 'release', 0.15);
        s.Instruments[i].Volume := JN(o, 'volume', 0.6);
        s.Instruments[i].Cutoff := JN(o, 'cutoff', 0);
        s.Instruments[i].Vibrato := JN(o, 'vibrato', 0);
        s.Instruments[i].VibRate := JN(o, 'vibRate', 5.5);
        s.Instruments[i].PitchDrop := JN(o, 'pitchDrop', 0);
        s.Instruments[i].NoiseMix := JN(o, 'noise', 0);
        s.Instruments[i].Detune := JN(o, 'detune', 0);
      end;
    end;
    SetLength(s.Channels, 0);
    if (root.Find('channels') <> nil) and (root.Find('channels').JSONType = jtArray) then
    begin
      a := TJSONArray(root.Find('channels'));
      SetLength(s.Channels, a.Count);
      for c := 0 to a.Count - 1 do
      begin
        o := TJSONObject(a.Items[c]);
        s.Channels[c].Name := JS(o, 'name', 'ch' + IntToStr(c));
        s.Channels[c].Instrument := Round(JN(o, 'instrument', 0));
        s.Channels[c].Volume := JN(o, 'volume', 1);
        s.Channels[c].Muted := (o.Find('muted') <> nil) and o.Find('muted').AsBoolean;
      end;
    end;
    SetLength(s.Patterns, 0);
    if (root.Find('patterns') <> nil) and (root.Find('patterns').JSONType = jtArray) then
    begin
      a := TJSONArray(root.Find('patterns'));
      SetLength(s.Patterns, a.Count);
      for i := 0 to a.Count - 1 do
      begin
        o := TJSONObject(a.Items[i]);
        s.Patterns[i].Name := JS(o, 'name', IntToStr(i));
        SetLength(s.Patterns[i].Notes, Length(s.Channels));
        if (o.Find('tracks') <> nil) and (o.Find('tracks').JSONType = jtArray) then
        begin
          t := TJSONArray(o.Find('tracks'));
          for c := 0 to Min(t.Count, Length(s.Channels)) - 1 do
          begin
            toks := Tokens(t.Items[c].AsString);
            SetLength(s.Patterns[i].Notes[c], Length(toks));
            for k := 0 to High(toks) do s.Patterns[i].Notes[c][k] := ParseNote(toks[k]);
          end;
        end;
      end;
    end;
    SetLength(s.Order, 0);
    if (root.Find('order') <> nil) and (root.Find('order').JSONType = jtArray) then
    begin
      a := TJSONArray(root.Find('order'));
      SetLength(s.Order, a.Count);
      for i := 0 to a.Count - 1 do s.Order[i] := a.Items[i].AsInteger;
    end;
    if Length(s.Patterns) = 0 then
    begin
      SetLength(s.Patterns, 1);
      s.Patterns[0].Name := 'A';
    end;
    if Length(s.Order) = 0 then
    begin
      SetLength(s.Order, 1);
      s.Order[0] := 0;
    end;
    FixSong(s);
    Result := True;
  finally
    d.Free;
  end;
end;

function LoadSong(const fn: string; out s: TSong; out err: string): Boolean;
var
  sl: TStringList;
begin
  Result := False;
  s := NewSong;
  if not FileExists(fn) then
  begin
    err := 'missing ' + fn;
    Exit;
  end;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(fn);
    Result := SongFromJSONText(sl.Text, s, err);
  finally
    sl.Free;
  end;
end;

function SaveSong(const fn: string; const s: TSong): Boolean;
begin
  Result := SaveTextToFile(fn, SongToJSON(s));
end;

{ ---------- rendering ---------- }

// one note into buf at sample offset `start`, gate = held length in seconds
procedure RenderNote(var buf: TBuf; start: Integer; const inst: TInstrument; note: Integer; gate, gain: Single;
  var seed: LongWord);
var
  i, n, idx: Integer;
  t, f, env, s, s2, a, y, base, relStart, relLevel, detuneRatio: Single;
  ph, ph2: Double;
begin
  base := NoteFreq(note);
  detuneRatio := Power(2, inst.Detune / 1200);
  n := Round((gate + Max(0.005, inst.Release)) * RATE);
  ph := 0;
  ph2 := 0;
  y := 0;
  relLevel := 0;
  if inst.Cutoff > 0 then a := 1 - Exp(-2 * Pi * inst.Cutoff / RATE) else a := 1;
  for i := 0 to n - 1 do
  begin
    idx := start + i;
    if idx > High(buf) then Break;
    if idx < 0 then Continue;
    t := i / RATE;
    // ADSR
    if t < gate then
    begin
      if t < inst.Attack then env := t / Max(1e-4, inst.Attack)
      else if t < inst.Attack + inst.Decay then
        env := 1 - (1 - inst.Sustain) * (t - inst.Attack) / Max(1e-4, inst.Decay)
      else env := inst.Sustain;
      relLevel := env;
    end
    else
    begin
      relStart := t - gate;
      env := relLevel * Max(0, 1 - relStart / Max(1e-4, inst.Release));
    end;
    f := base;
    // semitone factors via exp(x * ln2/12): much cheaper than Power() per sample
    if (inst.PitchDrop <> 0) and (t < 0.3) then f := f * Exp(SEMI * inst.PitchDrop * Exp(-t * 30));
    if (inst.Vibrato > 0) and (t > inst.Attack) then f := f * (1 + SEMI * inst.Vibrato * Sin(2 * Pi * inst.VibRate * t));
    ph := ph + f / RATE;
    case inst.Wave of
      0: s := Sin(2 * Pi * ph);
      1: s := 2 * Frac(ph) - 1;
      2: if Frac(ph) < 0.5 then s := 0.7 else s := -0.7;
      4: s := NoiseNext(seed);
    else
      s := 1 - 4 * Abs(Frac(ph + 0.25) - 0.5);
    end;
    if inst.Detune <> 0 then
    begin
      ph2 := ph2 + f * detuneRatio / RATE;
      case inst.Wave of
        0: s2 := Sin(2 * Pi * ph2);
        1: s2 := 2 * Frac(ph2) - 1;
        2: if Frac(ph2) < 0.5 then s2 := 0.7 else s2 := -0.7;
      else
        s2 := 1 - 4 * Abs(Frac(ph2 + 0.25) - 0.5);
      end;
      s := (s + s2) * 0.6;
    end;
    if inst.NoiseMix > 0 then s := s * (1 - inst.NoiseMix) + NoiseNext(seed) * inst.NoiseMix;
    y := y + a * (s - y);
    buf[idx] := buf[idx] + y * env * inst.Volume * gain;
  end;
end;

function RenderSong(const s: TSong; orderFrom, orderTo, patternOnly: Integer; loop: Boolean): TBuf;
const
  TAIL = 3.0;
var
  sd, total, gate, chVol: Single;
  pats: array of Integer;
  i, c, k, steps, st, total_n, mainLen, d, cur, curStart: Integer;
  seed: LongWord;
  wet: TBuf;
  note: SmallInt;
  inst: TInstrument;

  function StepTime(stepIdx: Integer): Single;
  begin
    Result := stepIdx * sd;
    if (stepIdx mod 2 = 1) then Result := Result + s.Swing * sd;
  end;

  procedure Flush(endStep: Integer);
  begin
    if cur > 0 then
    begin
      gate := Max(0.01, StepTime(endStep) - StepTime(curStart));
      RenderNote(Result, Round(StepTime(curStart) * RATE), inst, cur, gate, chVol * 0.35, seed);
    end;
    cur := 0;
  end;

begin
  sd := StepDuration(s);
  SetLength(pats, 0);
  if patternOnly >= 0 then
  begin
    SetLength(pats, 1);
    pats[0] := EnsureRange(patternOnly, 0, High(s.Patterns));
  end
  else
  begin
    if orderFrom < 0 then orderFrom := 0;
    if (orderTo < 0) or (orderTo > High(s.Order)) then orderTo := High(s.Order);
    for i := orderFrom to orderTo do
    begin
      SetLength(pats, Length(pats) + 1);
      pats[High(pats)] := EnsureRange(s.Order[i], 0, High(s.Patterns));
    end;
  end;
  steps := Length(pats) * s.PatternLen;
  total := steps * sd;
  mainLen := Max(1, Round(total * RATE));
  total_n := mainLen + Round(TAIL * RATE);
  SetLength(Result, total_n);
  FillChar(Result[0], total_n * SizeOf(Single), 0);
  seed := NameSeed(s.Name);
  for c := 0 to High(s.Channels) do
  begin
    if s.Channels[c].Muted then Continue;
    inst := s.Instruments[EnsureRange(s.Channels[c].Instrument, 0, High(s.Instruments))];
    chVol := s.Channels[c].Volume;
    cur := 0;
    curStart := 0;
    for st := 0 to steps - 1 do
    begin
      k := pats[st div s.PatternLen];
      note := s.Patterns[k].Notes[c][st mod s.PatternLen];
      if note = NOTE_OFF then Flush(st)
      else if note > 0 then
      begin
        Flush(st);
        cur := note;
        curStart := st;
      end;
    end;
    Flush(steps);
  end;
  // echo
  if (s.EchoMix > 0) and (s.EchoTime > 0.01) then
  begin
    d := Round(s.EchoTime * RATE);
    SetLength(wet, total_n);
    FillChar(wet[0], total_n * SizeOf(Single), 0);
    for i := d to total_n - 1 do
      wet[i] := Result[i - d] + wet[i - d] * EnsureRange(s.EchoFeedback, 0, 0.95);
    for i := 0 to total_n - 1 do Result[i] := Result[i] + wet[i] * s.EchoMix;
  end;
  if loop then
  begin
    // fold the tail into the beginning: seamless loop
    for i := mainLen to total_n - 1 do
      Result[i - mainLen] := Result[i - mainLen] + Result[i];
    SetLength(Result, mainLen);
  end;
  NormalizeBuf(Result, 0.8);
end;

function RenderNotePreview(const inst: TInstrument; note: Integer; seconds: Single): TBuf;
var
  seed: LongWord;
begin
  SetLength(Result, Round((seconds + Max(0.005, inst.Release) + 0.05) * RATE));
  FillChar(Result[0], Length(Result) * SizeOf(Single), 0);
  seed := 12345;
  RenderNote(Result, 0, inst, note, seconds, 1, seed);
  NormalizeBuf(Result, 0.6);
end;

end.
