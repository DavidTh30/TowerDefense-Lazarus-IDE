unit geometry;

(* Object geometry: vector sprites built from simple shapes, with animation channels.
  Shared by the game (rendering) and GeoEdit (editing / simulation).

  File format (JSON):
    { "version": 1,
      "objects": [
        { "name": "enemy.raider", "category": "enemy", "notes": "...",
          "shapes": [ { "type": "ellipse", "x": 0, "y": -10, "rx": 9, "ry": 9, "color": "#783C28", "bob": 2 }, ... ] } ] }

  Coordinates: origin (0,0) = the point where the object stands on the ground; +x = facing direction
  (the whole object is mirrored when the unit faces left), +y = down.

  Shape types and their fields:
    circle   x y r            ellipse x y rx ry [color2 = gradient edge colour]
    rect     x y w h          rrect   x y w h r (corner radius)
    poly     pts [x1,y1,...]  (convex)
    line     pts [x1,y1,x2,y2] w (width)
    ring     x y rx ry w (thickness)
    pie      x y r a0 a1 (degrees, 0 = right, 90 = down)
    image    x y w h image (file name relative to the geometry file; png/bmp/...)
  Common fields:
    color "#RRGGBB[AA]", add (additive blend), name (label), hidden
    bob   amplitude of the walk bob (only while moving)
    hover amplitude of a slow float (flying units)
    anim  one of: none step flap aim aimTilt swing pulse flicker glow spin
    amp / freq / px / py   channel amplitude, frequency, pivot
    minLevel / maxLevel    only drawn for these tower levels (0 = any)
    fire  only drawn for this many seconds after the owner fired (muzzle flash) *)

{$mode objfpc}{$H+}

interface

uses
  SDL3, SDL3_image, SysUtils, Math, Classes, fpjson, jsonparser, gfx;

type
  TShapeType = (stCircle, stEllipse, stRect, stRRect, stPoly, stLine, stRingShape, stPie, stImage);
  TAnimKind = (akNone, akStep, akFlap, akAim, akAimTilt, akSwing, akPulse, akFlicker, akGlow, akSpin);

  TShape = record
    Kind: TShapeType;
    Name: string;
    X, Y, R, RX, RY, W, H, A0, A1: Single;
    Pts: array of Single;
    Color, Color2: TRGBA;
    HasGrad, Add, Hidden: Boolean;
    Bob, Hover: Single;
    Anim: TAnimKind;
    Amp, Freq, PX, PY: Single;
    MinLevel, MaxLevel: Integer;
    Fire: Single;
    Image: string;
    Tex: PSDL_Texture;     // runtime only
  end;

  PShape = ^TShape;

  TGeoObject = record
    Name, Category, Notes: string;
    Shapes: array of TShape;
  end;

  TAnimState = record
    Time: Single;      // global time (s)
    Walk: Single;      // walk cycle time (advances while moving)
    Moving: Boolean;
    Facing: Single;    // +1 right, -1 left
    Aim: Single;       // radians
    Swing: Single;     // >0 while a melee swing is in progress (0.25 .. 0)
    SinceFire: Single; // seconds since the owner last fired
    Level: Integer;
    Seed: Single;      // per-instance phase offset
  end;

  TDrawMode = (dmAll, dmStatic, dmDynamic);

  THandle2D = record
    X, Y: Single;
    Id: Integer;       // 0..n-1 = shape points, 1000 = pivot
  end;
  THandleArray = array of THandle2D;

  { TGeoLib }

  TGeoLib = class
  public
    Objects: array of TGeoObject;
    FileName: string;
    function Count: Integer;
    function Find(const name: string): Integer;
    function LoadFromFile(const fn: string; out err: string): Boolean;
    function SaveToFile(const fn: string): Boolean;
    procedure Clear;
    destructor Destroy; override;
  end;

const
  ShapeTypeNames: array[TShapeType] of string =
    ('circle', 'ellipse', 'rect', 'rrect', 'poly', 'line', 'ring', 'pie', 'image');
  AnimNames: array[TAnimKind] of string =
    ('none', 'step', 'flap', 'aim', 'aimTilt', 'swing', 'pulse', 'flicker', 'glow', 'spin');

var
  ImageBaseDir: string = '';

function DefaultAnimState: TAnimState;
function ParseColor(const s: string; const def: TRGBA): TRGBA;
function ColorToStr(const c: TRGBA): string;
function NewShape(k: TShapeType): TShape;
function CloneShape(const sh: TShape): TShape;
function CloneObject(const o: TGeoObject): TGeoObject;

function ShapeToJSON(const sh: TShape): string;
function ShapeFromJSON(o: TJSONObject): TShape;
function ObjectToJSON(const o: TGeoObject; indent: string = '    '): string;
function ObjectFromJSON(o: TJSONObject): TGeoObject;
function ObjectFromJSONText(const s: string; out obj: TGeoObject): Boolean;

function ShapeVisible(const sh: TShape; const st: TAnimState; mode: TDrawMode): Boolean;
procedure DrawShape(const sh: TShape; x, y, scale: Single; const st: TAnimState);
procedure DrawGeo(const obj: TGeoObject; x, y, scale: Single; const st: TAnimState;
  mode: TDrawMode = dmAll);
procedure DrawGeoIdx(lib: TGeoLib; idx: Integer; x, y, scale: Single; const st: TAnimState;
  mode: TDrawMode = dmAll);

// editor helpers (local, un-animated coordinates)
function ShapeHit(const sh: TShape; lx, ly: Single): Boolean;
procedure ShapeBounds(const sh: TShape; out x0, y0, x1, y1: Single);
function ShapeHandles(const sh: TShape): THandleArray;
procedure MoveHandle(var sh: TShape; id: Integer; nx, ny: Single);
procedure MoveShape(var sh: TShape; dx, dy: Single);
function AnimUsesPivot(a: TAnimKind): Boolean;
function FmtNum(v: Single): string;

implementation

var
  FS: TFormatSettings;

function FmtNum(v: Single): string;
begin
  if Abs(v - Round(v)) < 0.0005 then Result := IntToStr(Round(v))
  else Result := FormatFloat('0.###', v, FS);
end;

function DefaultAnimState: TAnimState;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Facing := 1;
  Result.Level := 1;
  Result.SinceFire := 99;
end;

{ ---------- colours ---------- }

function HexVal(const s: string; p: Integer): Integer;
begin
  Result := StrToIntDef('$' + Copy(s, p, 2), 0);
end;

function ParseColor(const s: string; const def: TRGBA): TRGBA;
var
  t: string;
begin
  t := Trim(s);
  if (Length(t) > 0) and (t[1] = '#') then Delete(t, 1, 1);
  if Length(t) = 6 then
    Result := RGBA(HexVal(t, 1), HexVal(t, 3), HexVal(t, 5))
  else if Length(t) = 8 then
    Result := RGBA(HexVal(t, 1), HexVal(t, 3), HexVal(t, 5), HexVal(t, 7))
  else
    Result := def;
end;

function ColorToStr(const c: TRGBA): string;
begin
  Result := '#' + IntToHex(c.r, 2) + IntToHex(c.g, 2) + IntToHex(c.b, 2);
  if c.a <> 255 then Result := Result + IntToHex(c.a, 2);
end;

{ ---------- construction ---------- }

function NewShape(k: TShapeType): TShape;
begin
  Result := Default(TShape);
  Result.Kind := k;
  Result.Color := RGBA(200, 200, 200);
  Result.Color2 := RGBA(0, 0, 0, 0);
  case k of
    stCircle: Result.R := 10;
    stEllipse, stRingShape:
      begin
        Result.RX := 14; Result.RY := 9;
        if k = stRingShape then Result.W := 3;
      end;
    stRect, stRRect, stImage:
      begin
        Result.X := -10; Result.Y := -20; Result.W := 20; Result.H := 20;
        if k = stRRect then Result.R := 4;
      end;
    stPoly:
      begin
        SetLength(Result.Pts, 6);
        Result.Pts[0] := -10; Result.Pts[1] := 0;
        Result.Pts[2] := 0;   Result.Pts[3] := -18;
        Result.Pts[4] := 10;  Result.Pts[5] := 0;
      end;
    stLine:
      begin
        SetLength(Result.Pts, 4);
        Result.Pts[0] := -10; Result.Pts[1] := -10;
        Result.Pts[2] := 10;  Result.Pts[3] := -10;
        Result.W := 3;
      end;
    stPie:
      begin
        Result.R := 10; Result.A0 := 180; Result.A1 := 360;
      end;
  end;
end;

function CloneShape(const sh: TShape): TShape;
begin
  Result := sh;
  Result.Pts := Copy(sh.Pts);
  Result.Tex := nil;
end;

function CloneObject(const o: TGeoObject): TGeoObject;
var
  i: Integer;
begin
  Result.Name := o.Name;
  Result.Category := o.Category;
  Result.Notes := o.Notes;
  SetLength(Result.Shapes, Length(o.Shapes));
  for i := 0 to High(o.Shapes) do
    Result.Shapes[i] := CloneShape(o.Shapes[i]);
end;

{ ---------- JSON ---------- }

function JsonStr(const s: string): string;
begin
  Result := StringToJSONString(s);
  Result := '"' + Result + '"';
end;

function ShapeToJSON(const sh: TShape): string;
var
  parts: TStringList;
  i: Integer;
  s: string;

  procedure N(const key: string; v: Single);
  begin
    parts.Add('"' + key + '": ' + FmtNum(v));
  end;

  procedure NZ(const key: string; v: Single);
  begin
    if v <> 0 then N(key, v);
  end;

begin
  parts := TStringList.Create;
  try
    parts.Add('"type": "' + ShapeTypeNames[sh.Kind] + '"');
    if sh.Name <> '' then parts.Add('"name": ' + JsonStr(sh.Name));
    case sh.Kind of
      stCircle: begin N('x', sh.X); N('y', sh.Y); N('r', sh.R); end;
      stEllipse: begin N('x', sh.X); N('y', sh.Y); N('rx', sh.RX); N('ry', sh.RY); end;
      stRect, stImage: begin N('x', sh.X); N('y', sh.Y); N('w', sh.W); N('h', sh.H); end;
      stRRect: begin N('x', sh.X); N('y', sh.Y); N('w', sh.W); N('h', sh.H); N('r', sh.R); end;
      stRingShape: begin N('x', sh.X); N('y', sh.Y); N('rx', sh.RX); N('ry', sh.RY); N('w', sh.W); end;
      stPie: begin N('x', sh.X); N('y', sh.Y); N('r', sh.R); N('a0', sh.A0); N('a1', sh.A1); end;
      stPoly, stLine:
        begin
          s := '"pts": [';
          for i := 0 to High(sh.Pts) do
          begin
            if i > 0 then s := s + ', ';
            s := s + FmtNum(sh.Pts[i]);
          end;
          parts.Add(s + ']');
          if sh.Kind = stLine then N('w', sh.W);
        end;
    end;
    if sh.Kind = stImage then parts.Add('"image": ' + JsonStr(sh.Image));
    parts.Add('"color": "' + ColorToStr(sh.Color) + '"');
    if sh.HasGrad then parts.Add('"color2": "' + ColorToStr(sh.Color2) + '"');
    if sh.Add then parts.Add('"add": true');
    if sh.Hidden then parts.Add('"hidden": true');
    NZ('bob', sh.Bob);
    NZ('hover', sh.Hover);
    if sh.Anim <> akNone then
    begin
      parts.Add('"anim": "' + AnimNames[sh.Anim] + '"');
      NZ('amp', sh.Amp);
      NZ('freq', sh.Freq);
      if AnimUsesPivot(sh.Anim) then
      begin
        N('px', sh.PX);
        N('py', sh.PY);
      end;
    end;
    if sh.MinLevel > 0 then N('minLevel', sh.MinLevel);
    if sh.MaxLevel > 0 then N('maxLevel', sh.MaxLevel);
    NZ('fire', sh.Fire);
    Result := '{';
    for i := 0 to parts.Count - 1 do
    begin
      if i > 0 then Result := Result + ', ';
      Result := Result + parts[i];
    end;
    Result := Result + '}';
  finally
    parts.Free;
  end;
end;

function JF(o: TJSONObject; const key: string; def: Single = 0): Single;
var
  d: TJSONData;
begin
  d := o.Find(key);
  if (d <> nil) and (d.JSONType = jtNumber) then Result := d.AsFloat else Result := def;
end;

function JS(o: TJSONObject; const key: string; const def: string = ''): string;
var
  d: TJSONData;
begin
  d := o.Find(key);
  if (d <> nil) and (d.JSONType = jtString) then Result := d.AsString else Result := def;
end;

function JB(o: TJSONObject; const key: string): Boolean;
var
  d: TJSONData;
begin
  d := o.Find(key);
  Result := (d <> nil) and (d.JSONType = jtBoolean) and d.AsBoolean;
end;

function ShapeFromJSON(o: TJSONObject): TShape;
var
  t: string;
  k: TShapeType;
  a: TAnimKind;
  arr: TJSONArray;
  i: Integer;
begin
  Result := NewShape(stCircle);
  t := JS(o, 'type', 'circle');
  for k := Low(TShapeType) to High(TShapeType) do
    if SameText(ShapeTypeNames[k], t) then Result.Kind := k;
  Result.Name := JS(o, 'name');
  Result.X := JF(o, 'x');
  Result.Y := JF(o, 'y');
  Result.R := JF(o, 'r');
  Result.RX := JF(o, 'rx');
  Result.RY := JF(o, 'ry');
  Result.W := JF(o, 'w');
  Result.H := JF(o, 'h');
  Result.A0 := JF(o, 'a0');
  Result.A1 := JF(o, 'a1');
  SetLength(Result.Pts, 0);
  if (o.Find('pts') <> nil) and (o.Find('pts').JSONType = jtArray) then
  begin
    arr := TJSONArray(o.Find('pts'));
    SetLength(Result.Pts, arr.Count);
    for i := 0 to arr.Count - 1 do
      Result.Pts[i] := arr.Items[i].AsFloat;
  end;
  Result.Color := ParseColor(JS(o, 'color', '#FFFFFF'), RGBA(255, 255, 255));
  Result.HasGrad := o.Find('color2') <> nil;
  Result.Color2 := ParseColor(JS(o, 'color2', '#00000000'), RGBA(0, 0, 0, 0));
  Result.Add := JB(o, 'add');
  Result.Hidden := JB(o, 'hidden');
  Result.Bob := JF(o, 'bob');
  Result.Hover := JF(o, 'hover');
  Result.Anim := akNone;
  t := JS(o, 'anim', 'none');
  for a := Low(TAnimKind) to High(TAnimKind) do
    if SameText(AnimNames[a], t) then Result.Anim := a;
  Result.Amp := JF(o, 'amp');
  Result.Freq := JF(o, 'freq');
  Result.PX := JF(o, 'px');
  Result.PY := JF(o, 'py');
  Result.MinLevel := Round(JF(o, 'minLevel'));
  Result.MaxLevel := Round(JF(o, 'maxLevel'));
  Result.Fire := JF(o, 'fire');
  Result.Image := JS(o, 'image');
  Result.Tex := nil;
end;

function ObjectToJSON(const o: TGeoObject; indent: string): string;
var
  i: Integer;
  nl: string;
begin
  nl := LineEnding;
  Result := indent + '{"name": ' + JsonStr(o.Name) + ', "category": ' + JsonStr(o.Category);
  if o.Notes <> '' then Result := Result + ', "notes": ' + JsonStr(o.Notes);
  Result := Result + ',' + nl + indent + ' "shapes": [' + nl;
  for i := 0 to High(o.Shapes) do
  begin
    Result := Result + indent + '   ' + ShapeToJSON(o.Shapes[i]);
    if i < High(o.Shapes) then Result := Result + ',';
    Result := Result + nl;
  end;
  Result := Result + indent + ' ]}';
end;

function ObjectFromJSON(o: TJSONObject): TGeoObject;
var
  arr: TJSONArray;
  i: Integer;
begin
  Result.Name := JS(o, 'name', 'unnamed');
  Result.Category := JS(o, 'category', 'misc');
  Result.Notes := JS(o, 'notes');
  SetLength(Result.Shapes, 0);
  if (o.Find('shapes') <> nil) and (o.Find('shapes').JSONType = jtArray) then
  begin
    arr := TJSONArray(o.Find('shapes'));
    SetLength(Result.Shapes, arr.Count);
    for i := 0 to arr.Count - 1 do
      if arr.Items[i].JSONType = jtObject then
        Result.Shapes[i] := ShapeFromJSON(TJSONObject(arr.Items[i]));
  end;
end;

function ObjectFromJSONText(const s: string; out obj: TGeoObject): Boolean;
var
  d: TJSONData;
begin
  Result := False;
  obj := Default(TGeoObject);
  try
    d := GetJSON(s);
  except
    Exit;
  end;
  try
    if d.JSONType = jtObject then
    begin
      obj := ObjectFromJSON(TJSONObject(d));
      Result := True;
    end;
  finally
    d.Free;
  end;
end;

{ ---------- TGeoLib ---------- }

function TGeoLib.Count: Integer;
begin
  Result := Length(Objects);
end;

function TGeoLib.Find(const name: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(Objects) do
    if SameText(Objects[i].Name, name) then Exit(i);
  Result := -1;
end;

procedure TGeoLib.Clear;
var
  i, j: Integer;
begin
  for i := 0 to High(Objects) do
    for j := 0 to High(Objects[i].Shapes) do
      if Objects[i].Shapes[j].Tex <> nil then
        SDL_DestroyTexture(Objects[i].Shapes[j].Tex);
  SetLength(Objects, 0);
end;

destructor TGeoLib.Destroy;
begin
  Clear;
  inherited Destroy;
end;

function TGeoLib.LoadFromFile(const fn: string; out err: string): Boolean;
var
  sl: TStringList;
  d: TJSONData;
  arr: TJSONArray;
  i: Integer;
begin
  Result := False;
  err := '';
  if not FileExists(fn) then
  begin
    err := 'File not found: ' + fn;
    Exit;
  end;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(fn);
    try
      d := GetJSON(sl.Text);
    except
      on e: Exception do
      begin
        err := 'JSON error in ' + ExtractFileName(fn) + ': ' + e.Message;
        Exit;
      end;
    end;
  finally
    sl.Free;
  end;
  try
    if (d.JSONType <> jtObject) or (TJSONObject(d).Find('objects') = nil) then
    begin
      err := 'No "objects" array in ' + fn;
      Exit;
    end;
    Clear;
    arr := TJSONArray(TJSONObject(d).Find('objects'));
    SetLength(Objects, arr.Count);
    for i := 0 to arr.Count - 1 do
      Objects[i] := ObjectFromJSON(TJSONObject(arr.Items[i]));
    FileName := fn;
    ImageBaseDir := ExtractFilePath(ExpandFileName(fn));
    Result := True;
  finally
    d.Free;
  end;
end;

function TGeoLib.SaveToFile(const fn: string): Boolean;
var
  sl: TStringList;
  i: Integer;
  s: string;
begin
  Result := False;
  sl := TStringList.Create;
  try
    s := '{"version": 1,' + LineEnding + ' "objects": [' + LineEnding;
    for i := 0 to High(Objects) do
    begin
      s := s + ObjectToJSON(Objects[i], '  ');
      if i < High(Objects) then s := s + ',';
      s := s + LineEnding;
    end;
    s := s + ' ]}' + LineEnding;
    sl.Text := s;
    try
      sl.SaveToFile(fn);
      FileName := fn;
      Result := True;
    except
      Result := False;
    end;
  finally
    sl.Free;
  end;
end;

{ ---------- animation & transform ---------- }

function AnimUsesPivot(a: TAnimKind): Boolean;
begin
  Result := a in [akFlap, akAim, akAimTilt, akSwing, akPulse, akFlicker, akSpin];
end;

type
  TXform = record
    Rot, CosR, SinR: Single;     // rotation about pivot
    SX, SY: Single;              // scale about pivot
    PX, PY: Single;
    OX, OY: Single;              // offset
    Alpha: Single;               // alpha multiplier
    Mirror: Boolean;
    WX, WY, Scale: Single;       // world placement
  end;

function DefFreq(const sh: TShape; def: Single): Single; inline;
begin
  if sh.Freq <> 0 then Result := sh.Freq else Result := def;
end;

function MakeXform(const sh: TShape; x, y, scale: Single; const st: TAnimState): TXform;
var
  f, n: Single;
begin
  Result.Rot := 0;
  Result.SX := 1;
  Result.SY := 1;
  Result.PX := sh.PX;
  Result.PY := sh.PY;
  Result.OX := 0;
  Result.OY := 0;
  Result.Alpha := 1;
  case sh.Anim of
    akStep:
      if st.Moving then Result.OX := Sin(st.Walk * DefFreq(sh, 9)) * sh.Amp;
    akFlap:
      Result.Rot := DegToRad(sh.Amp * Sin(st.Time * DefFreq(sh, 18) + st.Seed));
    akAim:
      Result.Rot := st.Aim + DegToRad(sh.Amp);
    akAimTilt:
      if Cos(st.Aim) >= 0 then Result.Rot := DegToRad(sh.Amp) else Result.Rot := -DegToRad(sh.Amp);
    akSwing:
      if st.Swing > 0 then
        Result.Rot := DegToRad(-69 + (1 - st.Swing / 0.25) * 115)
      else
        Result.Rot := DegToRad(-34);
    akPulse:
      begin
        f := 1 + sh.Amp * Sin(st.Time * DefFreq(sh, 3) + st.Seed);
        Result.SX := f;
        Result.SY := f;
      end;
    akFlicker:
      begin
        n := (Sin(st.Time * 13 + st.Seed) + Sin(st.Time * 7.3 + st.Seed * 2)) * 0.5;
        Result.SY := 1 + sh.Amp * n;
        Result.SX := 1 + sh.Amp * 0.3 * Sin(st.Time * 11 + st.Seed);
      end;
    akGlow:
      Result.Alpha := (1 - sh.Amp) + sh.Amp * (0.5 + 0.5 * Sin(st.Time * DefFreq(sh, 2) + st.Seed));
    akSpin:
      Result.Rot := DegToRad(st.Time * sh.Amp);
  end;
  if (sh.Bob <> 0) and st.Moving then
    Result.OY := Result.OY - Abs(Sin(st.Walk * 9)) * sh.Bob;
  if sh.Hover <> 0 then
    Result.OY := Result.OY + Sin(st.Time * 4 + st.Seed) * sh.Hover;
  Result.CosR := Cos(Result.Rot);
  Result.SinR := Sin(Result.Rot);
  Result.Mirror := st.Facing < 0;
  Result.WX := x;
  Result.WY := y;
  Result.Scale := scale;
end;

procedure XP(const t: TXform; lx, ly: Single; out wx, wy: Single); inline;
var
  dx, dy, rx, ry: Single;
begin
  dx := (lx - t.PX) * t.SX;
  dy := (ly - t.PY) * t.SY;
  rx := t.PX + dx * t.CosR - dy * t.SinR + t.OX;
  ry := t.PY + dx * t.SinR + dy * t.CosR + t.OY;
  if t.Mirror then rx := -rx;
  wx := t.WX + rx * t.Scale;
  wy := t.WY + ry * t.Scale;
end;

function AlphaMul(const c: TRGBA; f: Single): TRGBA; inline;
begin
  Result := c;
  if f < 0.999 then Result.a := Round(EnsureRange(c.a * f, 0, 255));
end;

function ShapeVisible(const sh: TShape; const st: TAnimState; mode: TDrawMode): Boolean;
var
  dyn: Boolean;
begin
  Result := False;
  if sh.Hidden then Exit;
  if (sh.MinLevel > 0) and (st.Level < sh.MinLevel) then Exit;
  if (sh.MaxLevel > 0) and (st.Level > sh.MaxLevel) then Exit;
  if (sh.Fire > 0) and (st.SinceFire >= sh.Fire) then Exit;
  if mode <> dmAll then
  begin
    dyn := (sh.Anim <> akNone) or (sh.Hover <> 0) or (sh.Fire > 0);
    if (mode = dmStatic) and dyn then Exit;
    if (mode = dmDynamic) and not dyn then Exit;
  end;
  Result := True;
end;

procedure DrawShape(const sh: TShape; x, y, scale: Single; const st: TAnimState);
var
  t: TXform;
  cx, cy, x1, y1, x2, y2, x3, y3, x4, y4, a0, a1, tmp, sc: Single;
  c, c2: TRGBA;
  pts: array of Single;
  i: Integer;
  dst: TSDL_FRect;
  flip: TSDL_FlipMode;
  pp: TShape;
begin
  t := MakeXform(sh, x, y, scale, st);
  c := AlphaMul(sh.Color, t.Alpha);
  if sh.HasGrad then c2 := AlphaMul(sh.Color2, t.Alpha) else c2 := c;
  if sh.Add then SetBlendAdd(True);
  sc := scale * Sqrt(Abs(t.SX * t.SY));
  case sh.Kind of
    stCircle:
      begin
        XP(t, sh.X, sh.Y, cx, cy);
        FillEllipseGrad(cx, cy, sh.R * scale * t.SX, sh.R * scale * t.SY, c, c2);
      end;
    stEllipse:
      begin
        XP(t, sh.X, sh.Y, cx, cy);
        FillEllipseGrad(cx, cy, sh.RX * scale * t.SX, sh.RY * scale * t.SY, c, c2);
      end;
    stRingShape:
      begin
        XP(t, sh.X, sh.Y, cx, cy);
        Ring(cx, cy, sh.RX * scale * t.SX, sh.RY * scale * t.SY, sh.W * sc, c);
      end;
    stRect, stRRect:
      if (sh.Kind = stRRect) and (t.Rot = 0) then
      begin
        XP(t, sh.X, sh.Y, x1, y1);
        XP(t, sh.X + sh.W, sh.Y + sh.H, x3, y3);
        if x3 < x1 then
        begin
          tmp := x1; x1 := x3; x3 := tmp;
        end;
        RoundRect(x1, y1, x3 - x1, y3 - y1, sh.R * sc, c);
      end
      else
      begin
        XP(t, sh.X, sh.Y, x1, y1);
        XP(t, sh.X + sh.W, sh.Y, x2, y2);
        XP(t, sh.X + sh.W, sh.Y + sh.H, x3, y3);
        XP(t, sh.X, sh.Y + sh.H, x4, y4);
        FillQuad(x1, y1, x2, y2, x3, y3, x4, y4, c);
      end;
    stPoly:
      if Length(sh.Pts) >= 6 then
      begin
        SetLength(pts, Length(sh.Pts));
        for i := 0 to Length(sh.Pts) div 2 - 1 do
          XP(t, sh.Pts[i * 2], sh.Pts[i * 2 + 1], pts[i * 2], pts[i * 2 + 1]);
        FillPoly(pts, c);
      end;
    stLine:
      if Length(sh.Pts) >= 4 then
      begin
        for i := 0 to Length(sh.Pts) div 2 - 2 do
        begin
          XP(t, sh.Pts[i * 2], sh.Pts[i * 2 + 1], x1, y1);
          XP(t, sh.Pts[i * 2 + 2], sh.Pts[i * 2 + 3], x2, y2);
          ThickLine(x1, y1, x2, y2, Max(0.5, sh.W * sc), c);
        end;
      end;
    stPie:
      begin
        XP(t, sh.X, sh.Y, cx, cy);
        a0 := DegToRad(sh.A0) + t.Rot;
        a1 := DegToRad(sh.A1) + t.Rot;
        if t.Mirror then
        begin
          tmp := Pi - a1;
          a1 := Pi - a0;
          a0 := tmp;
        end;
        FillPie(cx, cy, sh.R * sc, a0, a1, c);
      end;
    stImage:
      begin
        pp := sh;
        if (pp.Tex = nil) and (pp.Image <> '') then
        begin
          // lazily load; cache in the original record through a pointer cast
          PShape(@sh)^.Tex := IMG_LoadTexture(Ren, PAnsiChar(ImageBaseDir + sh.Image));
          pp.Tex := sh.Tex;
        end;
        XP(t, sh.X + sh.W / 2, sh.Y + sh.H / 2, cx, cy);
        if pp.Tex <> nil then
        begin
          dst.w := sh.W * scale * t.SX;
          dst.h := sh.H * scale * t.SY;
          dst.x := cx - dst.w / 2 + OfsX;
          dst.y := cy - dst.h / 2 + OfsY;
          if t.Mirror then flip := SDL_FLIP_HORIZONTAL else flip := SDL_FLIP_NONE;
          SDL_SetTextureColorMod(pp.Tex, sh.Color.r, sh.Color.g, sh.Color.b);
          SDL_SetTextureAlphaMod(pp.Tex, c.a);
          if t.Mirror then tmp := -RadToDeg(t.Rot) else tmp := RadToDeg(t.Rot);
          SDL_RenderTextureRotated(Ren, pp.Tex, nil, @dst, tmp, nil, flip);
        end
        else
        begin
          // missing image: magenta placeholder
          XP(t, sh.X, sh.Y, x1, y1);
          XP(t, sh.X + sh.W, sh.Y + sh.H, x3, y3);
          FillRect(Min(x1, x3), Min(y1, y3), Abs(x3 - x1), Abs(y3 - y1), RGBA(255, 0, 255, 120));
        end;
      end;
  end;
  if sh.Add then SetBlendAdd(False);
end;

procedure DrawGeo(const obj: TGeoObject; x, y, scale: Single; const st: TAnimState; mode: TDrawMode);
var
  i: Integer;
begin
  for i := 0 to High(obj.Shapes) do
    if ShapeVisible(obj.Shapes[i], st, mode) then
      DrawShape(obj.Shapes[i], x, y, scale, st);
end;

procedure DrawGeoIdx(lib: TGeoLib; idx: Integer; x, y, scale: Single; const st: TAnimState; mode: TDrawMode);
begin
  if (lib = nil) or (idx < 0) or (idx >= lib.Count) then Exit;
  DrawGeo(lib.Objects[idx], x, y, scale, st, mode);
end;

{ ---------- editor helpers ---------- }

function PointInPoly(const p: array of Single; x, y: Single): Boolean;
var
  i, j, n: Integer;
begin
  Result := False;
  n := Length(p) div 2;
  j := n - 1;
  for i := 0 to n - 1 do
  begin
    if ((p[i * 2 + 1] > y) <> (p[j * 2 + 1] > y)) and
      (x < (p[j * 2] - p[i * 2]) * (y - p[i * 2 + 1]) / (p[j * 2 + 1] - p[i * 2 + 1] + 1e-9) + p[i * 2]) then
      Result := not Result;
    j := i;
  end;
end;

function SegDist(px, py, ax, ay, bx, by: Single): Single;
var
  dx, dy, t: Single;
begin
  dx := bx - ax;
  dy := by - ay;
  t := 0;
  if dx * dx + dy * dy > 1e-9 then
    t := EnsureRange(((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy), 0, 1);
  Result := Sqrt(Sqr(px - (ax + dx * t)) + Sqr(py - (ay + dy * t)));
end;

function ShapeHit(const sh: TShape; lx, ly: Single): Boolean;
var
  i: Integer;
  d: Single;
begin
  Result := False;
  case sh.Kind of
    stCircle, stPie:
      Result := Sqr(lx - sh.X) + Sqr(ly - sh.Y) <= Sqr(Max(sh.R, 2));
    stEllipse:
      Result := Sqr((lx - sh.X) / Max(sh.RX, 1)) + Sqr((ly - sh.Y) / Max(sh.RY, 1)) <= 1;
    stRingShape:
      begin
        d := Sqr((lx - sh.X) / Max(sh.RX, 1)) + Sqr((ly - sh.Y) / Max(sh.RY, 1));
        Result := (d <= 1.1) and (d >= Sqr(Max(0, 1 - (sh.W + 2) / Max(1, Min(sh.RX, sh.RY)))));
      end;
    stRect, stRRect, stImage:
      Result := (lx >= Min(sh.X, sh.X + sh.W)) and (lx <= Max(sh.X, sh.X + sh.W)) and
        (ly >= Min(sh.Y, sh.Y + sh.H)) and (ly <= Max(sh.Y, sh.Y + sh.H));
    stPoly:
      Result := PointInPoly(sh.Pts, lx, ly);
    stLine:
      for i := 0 to Length(sh.Pts) div 2 - 2 do
        if SegDist(lx, ly, sh.Pts[i * 2], sh.Pts[i * 2 + 1], sh.Pts[i * 2 + 2], sh.Pts[i * 2 + 3]) <=
          sh.W / 2 + 1.5 then
          Exit(True);
  end;
end;

procedure ShapeBounds(const sh: TShape; out x0, y0, x1, y1: Single);
var
  i: Integer;
begin
  case sh.Kind of
    stCircle, stPie:
      begin
        x0 := sh.X - sh.R; x1 := sh.X + sh.R; y0 := sh.Y - sh.R; y1 := sh.Y + sh.R;
      end;
    stEllipse, stRingShape:
      begin
        x0 := sh.X - sh.RX; x1 := sh.X + sh.RX; y0 := sh.Y - sh.RY; y1 := sh.Y + sh.RY;
      end;
    stRect, stRRect, stImage:
      begin
        x0 := Min(sh.X, sh.X + sh.W); x1 := Max(sh.X, sh.X + sh.W);
        y0 := Min(sh.Y, sh.Y + sh.H); y1 := Max(sh.Y, sh.Y + sh.H);
      end;
  else
    begin
      x0 := 1e9; y0 := 1e9; x1 := -1e9; y1 := -1e9;
      for i := 0 to Length(sh.Pts) div 2 - 1 do
      begin
        x0 := Min(x0, sh.Pts[i * 2]); x1 := Max(x1, sh.Pts[i * 2]);
        y0 := Min(y0, sh.Pts[i * 2 + 1]); y1 := Max(y1, sh.Pts[i * 2 + 1]);
      end;
      if x0 > x1 then
      begin
        x0 := 0; y0 := 0; x1 := 0; y1 := 0;
      end;
    end;
  end;
end;

function ShapeHandles(const sh: TShape): THandleArray;
var
  n, i: Integer;

  procedure AddH(x, y: Single; id: Integer);
  begin
    SetLength(Result, n + 1);
    Result[n].X := x;
    Result[n].Y := y;
    Result[n].Id := id;
    Inc(n);
  end;

begin
  n := 0;
  SetLength(Result, 0);
  case sh.Kind of
    stCircle: begin AddH(sh.X, sh.Y, 0); AddH(sh.X + sh.R, sh.Y, 1); end;
    stPie:
      begin
        AddH(sh.X, sh.Y, 0);
        AddH(sh.X + Cos(DegToRad(sh.A0)) * sh.R, sh.Y + Sin(DegToRad(sh.A0)) * sh.R, 2);
        AddH(sh.X + Cos(DegToRad(sh.A1)) * sh.R, sh.Y + Sin(DegToRad(sh.A1)) * sh.R, 3);
      end;
    stEllipse, stRingShape:
      begin
        AddH(sh.X, sh.Y, 0); AddH(sh.X + sh.RX, sh.Y, 1); AddH(sh.X, sh.Y + sh.RY, 2);
      end;
    stRect, stRRect, stImage:
      begin
        AddH(sh.X, sh.Y, 0); AddH(sh.X + sh.W, sh.Y + sh.H, 1);
      end;
    stPoly, stLine:
      for i := 0 to Length(sh.Pts) div 2 - 1 do
        AddH(sh.Pts[i * 2], sh.Pts[i * 2 + 1], i);
  end;
  if (sh.Anim <> akNone) and AnimUsesPivot(sh.Anim) then
    AddH(sh.PX, sh.PY, 1000);
end;

procedure MoveHandle(var sh: TShape; id: Integer; nx, ny: Single);
begin
  if id = 1000 then
  begin
    sh.PX := nx;
    sh.PY := ny;
    Exit;
  end;
  case sh.Kind of
    stCircle:
      if id = 0 then begin sh.X := nx; sh.Y := ny; end
      else sh.R := Max(0.5, Sqrt(Sqr(nx - sh.X) + Sqr(ny - sh.Y)));
    stPie:
      case id of
        0: begin sh.X := nx; sh.Y := ny; end;
        2: begin
             sh.A0 := RadToDeg(ArcTan2(ny - sh.Y, nx - sh.X));
             sh.R := Max(0.5, Sqrt(Sqr(nx - sh.X) + Sqr(ny - sh.Y)));
             if sh.A1 < sh.A0 then sh.A1 := sh.A1 + 360;
           end;
        3: begin
             sh.A1 := RadToDeg(ArcTan2(ny - sh.Y, nx - sh.X));
             sh.R := Max(0.5, Sqrt(Sqr(nx - sh.X) + Sqr(ny - sh.Y)));
             while sh.A1 <= sh.A0 do sh.A1 := sh.A1 + 360;
           end;
      end;
    stEllipse, stRingShape:
      case id of
        0: begin sh.X := nx; sh.Y := ny; end;
        1: sh.RX := Max(0.5, Abs(nx - sh.X));
        2: sh.RY := Max(0.5, Abs(ny - sh.Y));
      end;
    stRect, stRRect, stImage:
      if id = 0 then
      begin
        sh.W := sh.W + (sh.X - nx);
        sh.H := sh.H + (sh.Y - ny);
        sh.X := nx;
        sh.Y := ny;
      end
      else
      begin
        sh.W := nx - sh.X;
        sh.H := ny - sh.Y;
      end;
    stPoly, stLine:
      if (id >= 0) and (id * 2 + 1 <= High(sh.Pts)) then
      begin
        sh.Pts[id * 2] := nx;
        sh.Pts[id * 2 + 1] := ny;
      end;
  end;
end;

procedure MoveShape(var sh: TShape; dx, dy: Single);
var
  i: Integer;
begin
  sh.X := sh.X + dx;
  sh.Y := sh.Y + dy;
  for i := 0 to Length(sh.Pts) div 2 - 1 do
  begin
    sh.Pts[i * 2] := sh.Pts[i * 2] + dx;
    sh.Pts[i * 2 + 1] := sh.Pts[i * 2 + 1] + dy;
  end;
  if AnimUsesPivot(sh.Anim) then
  begin
    sh.PX := sh.PX + dx;
    sh.PY := sh.PY + dy;
  end;
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
end.
