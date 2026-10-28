unit synth;

{ Sound synthesis shared by the game, SoundEdit and MusicEdit.

  A sound effect is a list of layers mixed together, then optionally low-passed and normalized:
    tone   pitched oscillator, glide f0 -> f1 (Hz), wave sine/saw/square/triangle, attack/decay envelope, vibrato
    noise  filtered noise burst, low-pass cutoff glides f0 -> f1 (Hz)
    metal  inharmonic metallic ring at base frequency f0
    grunt  buzzy vocal grunt gliding f0 -> f1, brightness = formant cutoff
  Common layer fields: at (start, s), dur (s), gain, lowpass (Hz, 0 = off), fadeOut (s).
  Stored in data\sounds.json; see SoundsToJSON for the exact format. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, StrUtils, fpjson, jsonparser;

const
  RATE = 44100;
  WaveNames: array[0..4] of string = ('sine', 'saw', 'square', 'triangle', 'noise');

type
  TBuf = array of Single;

  TLayerKind = (lkTone, lkNoise, lkMetal, lkGrunt);

  TSoundLayer = record
    Kind: TLayerKind;
    At, Dur, F0, F1: Single;
    Wave: Integer;
    Attack, Decay, Vibrato, Bright: Single;
    Gain, Cutoff, FadeOut: Single;
  end;

  TSoundDef = record
    Name, Notes: string;
    Peak, MinGap, Length: Single;     // Length 0 = automatic (end of the last layer)
    LowPass: array of Single;
    Layers: array of TSoundLayer;
  end;
  TSoundArray = array of TSoundDef;

const
  LayerKindNames: array[TLayerKind] of string = ('tone', 'noise', 'metal', 'grunt');

function NewLayer(k: TLayerKind): TSoundLayer;
function RenderLayer(const L: TSoundLayer; var seed: LongWord): TBuf;
function RenderSound(const d: TSoundDef): TBuf;
function SoundDuration(const d: TSoundDef): Single;

function SoundsToJSON(const a: TSoundArray): string;
function SoundsFromJSONText(const txt: string; out a: TSoundArray; out err: string): Boolean;
function LoadSoundsFile(const fn: string; out a: TSoundArray; out err: string): Boolean;
function SaveTextToFile(const fn, txt: string): Boolean;
function SaveWav(const fn: string; const b: TBuf): Boolean;

// small DSP helpers (also used by the music renderer)
function NoiseNext(var seed: LongWord): Single; inline;
procedure LowPassBuf(var b: TBuf; cutoff: Single);
procedure NormalizeBuf(var b: TBuf; peak: Single);
function NameSeed(const s: string): LongWord;
function F3(v: Single): string;

implementation

var
  FS: TFormatSettings;

function F3(v: Single): string;
begin
  if Abs(v - Round(v)) < 0.00005 then Result := IntToStr(Round(v))
  else Result := FormatFloat('0.####', v, FS);
end;

function NoiseNext(var seed: LongWord): Single; inline;
begin
  seed := seed * 1664525 + 1013904223;
  Result := (seed shr 8) / 8388608.0 - 1.0;
end;

function NameSeed(const s: string): LongWord;
var
  i: Integer;
begin
  Result := 2166136261;
  for i := 1 to Length(s) do Result := (Result xor Ord(s[i])) * 16777619;
end;

function NewBuf(seconds: Single): TBuf;
begin
  SetLength(Result, Max(1, Round(seconds * RATE)));
  FillChar(Result[0], Length(Result) * SizeOf(Single), 0);
end;

function Env(t, attack, decay: Single): Single; inline;
begin
  if t < attack then Result := t / Max(1e-5, attack)
  else Result := Exp(-(t - attack) / Max(1e-5, decay));
end;

procedure LowPassBuf(var b: TBuf; cutoff: Single);
var
  i: Integer;
  a, y: Single;
begin
  if cutoff <= 0 then Exit;
  a := 1 - Exp(-2 * Pi * cutoff / RATE);
  y := 0;
  for i := 0 to High(b) do
  begin
    y := y + a * (b[i] - y);
    b[i] := y;
  end;
end;

procedure NormalizeBuf(var b: TBuf; peak: Single);
var
  i: Integer;
  m: Single;
begin
  m := 0;
  for i := 0 to High(b) do m := Max(m, Abs(b[i]));
  if m < 1e-6 then Exit;
  m := peak / m;
  for i := 0 to High(b) do b[i] := b[i] * m;
end;

function NewLayer(k: TLayerKind): TSoundLayer;
begin
  Result := Default(TSoundLayer);
  Result.Kind := k;
  Result.Gain := 1;
  Result.Dur := 0.3;
  Result.Attack := 0.005;
  Result.Decay := 0.08;
  case k of
    lkTone: begin Result.F0 := 440; Result.F1 := 440; end;
    lkNoise: begin Result.F0 := 3000; Result.F1 := 600; end;
    lkMetal: Result.F0 := 1800;
    lkGrunt: begin Result.F0 := 160; Result.F1 := 80; Result.Bright := 900; end;
  end;
end;

function RenderLayer(const L: TSoundLayer; var seed: LongWord): TBuf;
const
  RATIOS: array[0..5] of Single = (1.0, 1.47, 2.09, 2.76, 3.52, 4.43);
var
  i, k: Integer;
  t, f, s, a, y, c, dur: Single;
  ph: Double;
begin
  dur := Max(0.005, L.Dur);
  Result := NewBuf(dur);
  ph := 0;
  y := 0;
  case L.Kind of
    lkTone:
      for i := 0 to High(Result) do
      begin
        t := i / RATE;
        f := Max(1, L.F0) * Power(Max(1, L.F1) / Max(1, L.F0), t / dur);
        if L.Vibrato > 0 then f := f * (1 + L.Vibrato * Sin(2 * Pi * 5.5 * t));
        ph := ph + f / RATE;
        case L.Wave of
          0: s := Sin(2 * Pi * ph);
          1: s := 2 * Frac(ph) - 1;
          2: if Frac(ph) < 0.5 then s := 1 else s := -1;
          4: s := NoiseNext(seed);
        else
          s := 1 - 4 * Abs(Frac(ph + 0.25) - 0.5);
        end;
        Result[i] := s * Env(t, L.Attack, L.Decay);
      end;
    lkNoise:
      for i := 0 to High(Result) do
      begin
        t := i / RATE;
        c := Max(10, L.F0) * Power(Max(10, L.F1) / Max(10, L.F0), t / dur);
        a := 1 - Exp(-2 * Pi * c / RATE);
        y := y + a * (NoiseNext(seed) - y);
        Result[i] := y * Env(t, L.Attack, L.Decay);
      end;
    lkMetal:
      for i := 0 to High(Result) do
      begin
        t := i / RATE;
        s := 0;
        for k := 0 to High(RATIOS) do
          s := s + Sin(2 * Pi * L.F0 * RATIOS[k] * t) * Exp(-t / (Max(1e-4, L.Decay) / (1 + k * 0.35))) / (1 + k * 0.4);
        Result[i] := s;
      end;
    lkGrunt:
      begin
        for i := 0 to High(Result) do
        begin
          t := i / RATE;
          f := Max(1, L.F0) * Power(Max(1, L.F1) / Max(1, L.F0), t / dur) * (1 + 0.03 * NoiseNext(seed));
          ph := ph + f / RATE;
          s := (2 * Frac(ph) - 1) * 0.8 + NoiseNext(seed) * 0.25;
          Result[i] := s * Env(t, 0.015, dur * 0.35) * Min(1, (dur - t) * 20);
        end;
        LowPassBuf(Result, Max(50, L.Bright));
        LowPassBuf(Result, Max(50, L.Bright) * 1.5);
      end;
  end;
  if L.Cutoff > 0 then LowPassBuf(Result, L.Cutoff);
  if L.FadeOut > 0 then
    for i := 0 to High(Result) do
      Result[i] := Result[i] * Min(1, (High(Result) - i) / (RATE * L.FadeOut));
end;

function SoundDuration(const d: TSoundDef): Single;
var
  i: Integer;
begin
  Result := d.Length;
  if Result <= 0 then
    for i := 0 to High(d.Layers) do
      Result := Max(Result, d.Layers[i].At + d.Layers[i].Dur);
  Result := Max(0.01, Result);
end;

function RenderSound(const d: TSoundDef): TBuf;
var
  i, j, o, fade: Integer;
  lb: TBuf;
  seed: LongWord;
begin
  Result := NewBuf(SoundDuration(d));
  seed := NameSeed(d.Name);
  for i := 0 to High(d.Layers) do
  begin
    lb := RenderLayer(d.Layers[i], seed);
    o := Round(d.Layers[i].At * RATE);
    for j := 0 to High(lb) do
      if (o + j >= 0) and (o + j <= High(Result)) then
        Result[o + j] := Result[o + j] + lb[j] * d.Layers[i].Gain;
  end;
  for i := 0 to High(d.LowPass) do LowPassBuf(Result, d.LowPass[i]);
  NormalizeBuf(Result, d.Peak);
  // short fade-out so nothing ends with a click
  fade := Min(High(Result), RATE div 50);
  for i := 0 to fade do
    Result[High(Result) - i] := Result[High(Result) - i] * (i / Max(1, RATE / 50));
end;

{ ---------- JSON ---------- }

function LayerToJSON(const L: TSoundLayer): string;
begin
  Result := '{"type": "' + LayerKindNames[L.Kind] + '", "at": ' + F3(L.At) + ', "dur": ' + F3(L.Dur);
  case L.Kind of
    lkTone:
      Result := Result + ', "wave": "' + WaveNames[EnsureRange(L.Wave, 0, 4)] + '", "f0": ' + F3(L.F0) + ', "f1": ' +
        F3(L.F1) + ', "attack": ' + F3(L.Attack) + ', "decay": ' + F3(L.Decay) +
        IfThen(L.Vibrato <> 0, ', "vibrato": ' + F3(L.Vibrato), '');
    lkNoise:
      Result := Result + ', "f0": ' + F3(L.F0) + ', "f1": ' + F3(L.F1) + ', "attack": ' + F3(L.Attack) +
        ', "decay": ' + F3(L.Decay);
    lkMetal:
      Result := Result + ', "f0": ' + F3(L.F0) + ', "decay": ' + F3(L.Decay);
    lkGrunt:
      Result := Result + ', "f0": ' + F3(L.F0) + ', "f1": ' + F3(L.F1) + ', "bright": ' + F3(L.Bright);
  end;
  Result := Result + ', "gain": ' + F3(L.Gain);
  if L.Cutoff > 0 then Result := Result + ', "lowpass": ' + F3(L.Cutoff);
  if L.FadeOut > 0 then Result := Result + ', "fadeOut": ' + F3(L.FadeOut);
  Result := Result + '}';
end;

function SoundsToJSON(const a: TSoundArray): string;
var
  sb: TStringList;
  i, j: Integer;
  line, lp: string;
begin
  sb := TStringList.Create;
  try
    sb.Add('{"sounds": [');
    for i := 0 to High(a) do
    begin
      lp := '';
      for j := 0 to High(a[i].LowPass) do
      begin
        if j > 0 then lp := lp + ', ';
        lp := lp + F3(a[i].LowPass[j]);
      end;
      line := '  {"name": "' + StringToJSONString(a[i].Name) + '", "peak": ' + F3(a[i].Peak) + ', "minGap": ' +
        F3(a[i].MinGap);
      if a[i].Length > 0 then line := line + ', "length": ' + F3(a[i].Length);
      if lp <> '' then line := line + ', "lowpass": [' + lp + ']';
      if a[i].Notes <> '' then line := line + ', "notes": "' + StringToJSONString(a[i].Notes) + '"';
      sb.Add(line + ',');
      sb.Add('   "layers": [');
      for j := 0 to High(a[i].Layers) do
      begin
        line := '     ' + LayerToJSON(a[i].Layers[j]);
        if j < High(a[i].Layers) then line := line + ',';
        sb.Add(line);
      end;
      line := '   ]}';
      if i < High(a) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add(']}');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

function JNum(o: TJSONObject; const k: string; def: Single): Single;
var
  d: TJSONData;
begin
  d := o.Find(k);
  if (d <> nil) and (d.JSONType = jtNumber) then Result := d.AsFloat else Result := def;
end;

function JStr(o: TJSONObject; const k, def: string): string;
var
  d: TJSONData;
begin
  d := o.Find(k);
  if (d <> nil) and (d.JSONType = jtString) then Result := d.AsString else Result := def;
end;

function SoundsFromJSONText(const txt: string; out a: TSoundArray; out err: string): Boolean;
var
  d: TJSONData;
  arr, la: TJSONArray;
  o, lo: TJSONObject;
  i, j, w: Integer;
  k: TLayerKind;
  t: string;
begin
  Result := False;
  err := '';
  SetLength(a, 0);
  try
    d := GetJSON(txt);
  except
    on e: Exception do
    begin
      err := e.Message;
      Exit;
    end;
  end;
  try
    if (d.JSONType <> jtObject) or (TJSONObject(d).Find('sounds') = nil) then
    begin
      err := '"sounds" array missing';
      Exit;
    end;
    arr := TJSONArray(TJSONObject(d).Find('sounds'));
    SetLength(a, arr.Count);
    for i := 0 to arr.Count - 1 do
    begin
      o := TJSONObject(arr.Items[i]);
      a[i].Name := JStr(o, 'name', 'sound' + IntToStr(i));
      a[i].Notes := JStr(o, 'notes', '');
      a[i].Peak := JNum(o, 'peak', 0.5);
      a[i].MinGap := JNum(o, 'minGap', 0.03);
      a[i].Length := JNum(o, 'length', 0);
      SetLength(a[i].LowPass, 0);
      if (o.Find('lowpass') <> nil) and (o.Find('lowpass').JSONType = jtArray) then
      begin
        la := TJSONArray(o.Find('lowpass'));
        SetLength(a[i].LowPass, la.Count);
        for j := 0 to la.Count - 1 do a[i].LowPass[j] := la.Items[j].AsFloat;
      end;
      SetLength(a[i].Layers, 0);
      if (o.Find('layers') <> nil) and (o.Find('layers').JSONType = jtArray) then
      begin
        la := TJSONArray(o.Find('layers'));
        SetLength(a[i].Layers, la.Count);
        for j := 0 to la.Count - 1 do
        begin
          lo := TJSONObject(la.Items[j]);
          t := JStr(lo, 'type', 'tone');
          a[i].Layers[j] := NewLayer(lkTone);
          for k := Low(TLayerKind) to High(TLayerKind) do
            if SameText(LayerKindNames[k], t) then a[i].Layers[j].Kind := k;
          a[i].Layers[j].At := JNum(lo, 'at', 0);
          a[i].Layers[j].Dur := JNum(lo, 'dur', 0.3);
          a[i].Layers[j].F0 := JNum(lo, 'f0', 440);
          a[i].Layers[j].F1 := JNum(lo, 'f1', a[i].Layers[j].F0);
          a[i].Layers[j].Attack := JNum(lo, 'attack', 0.005);
          a[i].Layers[j].Decay := JNum(lo, 'decay', 0.08);
          a[i].Layers[j].Vibrato := JNum(lo, 'vibrato', 0);
          a[i].Layers[j].Bright := JNum(lo, 'bright', 900);
          a[i].Layers[j].Gain := JNum(lo, 'gain', 1);
          a[i].Layers[j].Cutoff := JNum(lo, 'lowpass', 0);
          a[i].Layers[j].FadeOut := JNum(lo, 'fadeOut', 0);
          a[i].Layers[j].Wave := 0;
          t := JStr(lo, 'wave', 'sine');
          for w := 0 to 4 do
            if SameText(WaveNames[w], t) then a[i].Layers[j].Wave := w;
        end;
      end;
    end;
    Result := True;
  finally
    d.Free;
  end;
end;

function LoadSoundsFile(const fn: string; out a: TSoundArray; out err: string): Boolean;
var
  sl: TStringList;
begin
  SetLength(a, 0);
  Result := False;
  if not FileExists(fn) then
  begin
    err := 'missing ' + fn;
    Exit;
  end;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(fn);
    Result := SoundsFromJSONText(sl.Text, a, err);
  finally
    sl.Free;
  end;
end;

function SaveTextToFile(const fn, txt: string): Boolean;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Text := txt;
    try
      ForceDirectories(ExtractFilePath(ExpandFileName(fn)));
      sl.SaveToFile(fn);
      Result := True;
    except
      Result := False;
    end;
  finally
    sl.Free;
  end;
end;

function SaveWav(const fn: string; const b: TBuf): Boolean;
var
  f: TFileStream;
  hdr: packed record
    riff: array[0..3] of AnsiChar; size: LongWord; wave: array[0..3] of AnsiChar;
    fmt: array[0..3] of AnsiChar; fmtSize: LongWord; format, channels: Word; rate, bytesPerSec: LongWord;
    align, bits: Word; data: array[0..3] of AnsiChar; dataSize: LongWord;
  end;
  pcm: array of SmallInt;
  i: Integer;
begin
  Result := False;
  SetLength(pcm, Length(b));
  for i := 0 to High(b) do pcm[i] := Round(EnsureRange(b[i], -1, 1) * 32767);
  hdr.riff := 'RIFF'; hdr.wave := 'WAVE'; hdr.fmt := 'fmt '; hdr.data := 'data';
  hdr.fmtSize := 16; hdr.format := 1; hdr.channels := 1; hdr.rate := RATE; hdr.bytesPerSec := RATE * 2;
  hdr.align := 2; hdr.bits := 16;
  hdr.dataSize := Length(pcm) * 2;
  hdr.size := 36 + hdr.dataSize;
  try
    ForceDirectories(ExtractFilePath(ExpandFileName(fn)));
    f := TFileStream.Create(fn, fmCreate);
  except
    Exit;
  end;
  try
    f.WriteBuffer(hdr, SizeOf(hdr));
    if Length(pcm) > 0 then f.WriteBuffer(pcm[0], Length(pcm) * 2);
    Result := True;
  finally
    f.Free;
  end;
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
end.
