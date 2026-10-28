unit mapcore;

{ Map geometry shared by the game and MapEdit:
  smooth road paths (Catmull-Rom through the map's control points) and
  rendering of the static map background (ground, roads, fortress). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, gfx, gamedata;

type
  TPath = record
    N: Integer;
    X, Y, D: array of Single;   // sampled points + cumulative distance
    Len: Single;
  end;
  TPathArray = array of TPath;

procedure BuildPath(var p: TPath; const ctrl: array of Single);
procedure BuildAllPaths(const m: TMapDef; var paths: TPathArray);
procedure PathPos(const p: TPath; d: Single; out x, y, dx, dy: Single);
procedure NearestPathPoint(const paths: TPathArray; x, y: Single; out nx, ny, dist: Single);
function DistToPaths(const paths: TPathArray; x, y: Single): Single;

// draws ground, roads and the fortress (no decoration) at map coordinates
procedure DrawMapBase(const m: TMapDef; const paths: TPathArray);
procedure DrawFortress(w, h: Single);
procedure DrawVignette(w, h: Single);

implementation

function Dist2(x1, y1, x2, y2: Single): Single; inline;
begin
  Result := Sqr(x2 - x1) + Sqr(y2 - y1);
end;

procedure BuildPath(var p: TPath; const ctrl: array of Single);
const
  STEPS = 24;
var
  k, i, s, cnt: Integer;
  t, t2, t3: Single;
  x0, y0, x1, y1, x2, y2, x3, y3: Single;

  function CX(j: Integer): Single;
  begin
    Result := ctrl[EnsureRange(j, 0, k - 1) * 2];
  end;

  function CY(j: Integer): Single;
  begin
    Result := ctrl[EnsureRange(j, 0, k - 1) * 2 + 1];
  end;

begin
  k := Length(ctrl) div 2;
  if k < 2 then
  begin
    p.N := 0;
    p.Len := 0;
    Exit;
  end;
  cnt := (k - 1) * STEPS + 1;
  SetLength(p.X, cnt);
  SetLength(p.Y, cnt);
  SetLength(p.D, cnt);
  p.N := 0;
  for i := 0 to k - 2 do
  begin
    x0 := CX(i - 1); y0 := CY(i - 1);
    x1 := CX(i);     y1 := CY(i);
    x2 := CX(i + 1); y2 := CY(i + 1);
    x3 := CX(i + 2); y3 := CY(i + 2);
    for s := 0 to STEPS - 1 do
    begin
      if (i > 0) and (s = 0) then Continue;
      t := s / STEPS;
      t2 := t * t;
      t3 := t2 * t;
      p.X[p.N] := 0.5 * ((2 * x1) + (-x0 + x2) * t + (2 * x0 - 5 * x1 + 4 * x2 - x3) * t2 +
        (-x0 + 3 * x1 - 3 * x2 + x3) * t3);
      p.Y[p.N] := 0.5 * ((2 * y1) + (-y0 + y2) * t + (2 * y0 - 5 * y1 + 4 * y2 - y3) * t2 +
        (-y0 + 3 * y1 - 3 * y2 + y3) * t3);
      Inc(p.N);
    end;
  end;
  p.X[p.N] := CX(k - 1);
  p.Y[p.N] := CY(k - 1);
  Inc(p.N);
  p.D[0] := 0;
  for i := 1 to p.N - 1 do
    p.D[i] := p.D[i - 1] + Sqrt(Dist2(p.X[i - 1], p.Y[i - 1], p.X[i], p.Y[i]));
  p.Len := p.D[p.N - 1];
end;

procedure BuildAllPaths(const m: TMapDef; var paths: TPathArray);
var
  i: Integer;
begin
  SetLength(paths, Length(m.Paths));
  for i := 0 to High(m.Paths) do
    BuildPath(paths[i], m.Paths[i].Ctrl);
end;

procedure PathPos(const p: TPath; d: Single; out x, y, dx, dy: Single);
var
  lo, hi, mid: Integer;
  t, len: Single;
begin
  if p.N < 2 then
  begin
    x := 0; y := 0; dx := 1; dy := 0;
    Exit;
  end;
  if d <= 0 then
  begin
    lo := 0;
    hi := 1;
  end
  else if d >= p.Len then
  begin
    lo := p.N - 2;
    hi := p.N - 1;
  end
  else
  begin
    lo := 0;
    hi := p.N - 1;
    while hi - lo > 1 do
    begin
      mid := (lo + hi) div 2;
      if p.D[mid] <= d then lo := mid else hi := mid;
    end;
  end;
  len := p.D[hi] - p.D[lo];
  dx := p.X[hi] - p.X[lo];
  dy := p.Y[hi] - p.Y[lo];
  if len > 0.0001 then
  begin
    t := (d - p.D[lo]) / len;
    dx := dx / len;
    dy := dy / len;
  end
  else
  begin
    t := 0;
    dx := 1;
    dy := 0;
  end;
  x := p.X[lo] + (p.X[hi] - p.X[lo]) * t;
  y := p.Y[lo] + (p.Y[hi] - p.Y[lo]) * t;
  if d < 0 then
  begin
    x := x + dx * d;
    y := y + dy * d;
  end;
end;

procedure NearestPathPoint(const paths: TPathArray; x, y: Single; out nx, ny, dist: Single);
var
  pi_, i: Integer;
  best, d: Single;
begin
  best := 1e12;
  nx := x;
  ny := y;
  for pi_ := 0 to High(paths) do
    for i := 0 to paths[pi_].N - 1 do
    begin
      d := Dist2(x, y, paths[pi_].X[i], paths[pi_].Y[i]);
      if d < best then
      begin
        best := d;
        nx := paths[pi_].X[i];
        ny := paths[pi_].Y[i];
      end;
    end;
  dist := Sqrt(best);
end;

function DistToPaths(const paths: TPathArray; x, y: Single): Single;
var
  nx, ny: Single;
begin
  NearestPathPoint(paths, x, y, nx, ny, Result);
end;

function RandF(a, b: Single): Single;
begin
  Result := a + Random * (b - a);
end;

procedure DrawMapBase(const m: TMapDef; const paths: TPathArray);
var
  i, pi_: Integer;
  x, y, r, ph, w, h: Single;
begin
  w := m.Width;
  h := m.Height;
  FillRect(0, 0, w, h, m.Ground);
  RandSeed := m.Seed;
  for i := 0 to 500 do
  begin
    x := RandF(-40, w + 40);
    y := RandF(-40, h + 40);
    r := RandF(20, 90);
    if Random(2) = 0 then FillEllipse(x, y, r, r * 0.55, m.GroundDark)
    else FillEllipse(x, y, r, r * 0.55, m.GroundLight);
  end;
  for i := 0 to 260 do
  begin
    x := RandF(0, w);
    y := RandF(0, h);
    FillEllipse(x, y, RandF(2, 5), RandF(1.5, 3), RGBA(80, 50, 30, 150));
    FillEllipse(x - 1, y - 1, 1.5, 1, RGBA(160, 120, 80, 120));
  end;
  ph := m.PathHalf;
  for pi_ := 0 to High(paths) do
    for i := 0 to paths[pi_].N - 1 do
      if i mod 2 = 0 then FillCircle(paths[pi_].X[i], paths[pi_].Y[i] + 3, ph + 4, m.RoadBorder);
  for pi_ := 0 to High(paths) do
    for i := 0 to paths[pi_].N - 1 do
      if i mod 2 = 0 then FillCircle(paths[pi_].X[i], paths[pi_].Y[i], ph, m.RoadEdge);
  for pi_ := 0 to High(paths) do
    for i := 0 to paths[pi_].N - 1 do
      if i mod 2 = 0 then FillCircle(paths[pi_].X[i], paths[pi_].Y[i], ph - 6, m.RoadSand);
  for pi_ := 0 to High(paths) do
    for i := 0 to paths[pi_].N - 1 do
      if i mod 3 = 0 then FillCircle(paths[pi_].X[i] - 3, paths[pi_].Y[i] - 4, ph - 16, m.RoadLight);
  for i := 0 to 500 do
  begin
    x := RandF(0, w);
    y := RandF(0, h);
    if DistToPaths(paths, x, y) < ph - 8 then
    begin
      FillEllipse(x, y, RandF(1.5, 3.5), RandF(1, 2.2), RGBA(170, 126, 80, 200));
      FillEllipse(x - 0.5, y - 0.8, 1.2, 0.8, RGBA(240, 210, 160, 160));
    end;
  end;
end;

procedure DrawFortress(w, h: Single);
var
  i, j: Integer;
  x, y, fx: Single;
begin
  fx := w - 75;      // keep at the right edge for any map width
  FillRect(fx + 10, 0, 65, h, RGBA(70, 62, 60));
  for j := 0 to Ceil(h / 30) do
    for i := 0 to 1 do
    begin
      x := fx + 13 + i * 32 + (j mod 2) * 16;
      y := j * 30;
      RoundRect(x, y + 2, 28, 26, 4, RGBA(112 + (i * 7 + j * 13) mod 20, 100, 92));
    end;
  FillRect(fx, 0, 14, h, RGBA(52, 46, 46));
  FillRect(fx, 312, 75, 90, RGBA(40, 30, 26));
  FillEllipse(fx + 38, 312, 38, 26, RGBA(40, 30, 26));
  FillRect(fx + 10, 310, 65, 92, RGBA(20, 14, 12));
  FillEllipse(fx + 43, 312, 33, 22, RGBA(20, 14, 12));
  for i := 0 to 4 do
    FillRect(fx + 17 + i * 12, 300, 3, 102, RGBA(90, 90, 96));
  FillRect(fx + 1, 230, 18, 60, RGBA(40, 70, 150));
  FillTri(fx + 1, 290, fx + 19, 290, fx + 10, 300, RGBA(40, 70, 150));
  FillRect(fx + 1, 420, 18, 60, RGBA(40, 70, 150));
  FillTri(fx + 1, 480, fx + 19, 480, fx + 10, 490, RGBA(40, 70, 150));
  FillCircle(fx + 10, 255, 5, RGBA(230, 200, 80));
  FillCircle(fx + 10, 445, 5, RGBA(230, 200, 80));
end;

procedure DrawVignette(w, h: Single);
var
  i: Integer;
begin
  for i := 0 to 11 do
  begin
    FillRect(0, 0, w, 6 + i * 3, RGBA(30, 16, 8, 10));
    FillRect(0, h - 6 - i * 3, w, 6 + i * 3, RGBA(30, 16, 8, 10));
    FillRect(0, 0, 6 + i * 3, h, RGBA(30, 16, 8, 10));
  end;
end;

end.
