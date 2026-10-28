unit gfx;

{ Small immediate-mode drawing layer on top of SDL3:
  - filled shapes (circles, ellipses, gradients, polygons, thick lines) via SDL_RenderGeometry
  - text via SDL3_ttf, pre-rendered into one glyph atlas per font (fast, batchable),
    with an outline atlas for readable game text. Falls back to SDL debug text. }

{$mode objfpc}{$H+}

interface

uses
  SDL3, SDL3_ttf, SysUtils, Math;

type
  TRGBA = record
    r, g, b, a: Byte;
  end;

  TFontId = (fnSmall, fnMedium, fnBig);

const
  ALIGN_LEFT   = 0;
  ALIGN_CENTER = 1;
  ALIGN_RIGHT  = 2;

var
  Ren: PSDL_Renderer;
  OfsX, OfsY: Single;   // global offset (screen shake), applied to shapes and text

function RGBA(r, g, b: Byte; a: Byte = 255): TRGBA;
function Shade(const c: TRGBA; f: Single): TRGBA;
function WithAlpha(const c: TRGBA; a: Byte): TRGBA;
function Mix(const c1, c2: TRGBA; t: Single): TRGBA;

procedure GfxInit(r: PSDL_Renderer);
procedure GfxDone;

procedure SetBlendAdd(add: Boolean);
procedure FillRect(x, y, w, h: Single; const c: TRGBA);
procedure FillRectGrad(x, y, w, h: Single; const top, bottom: TRGBA);
procedure FillCircle(cx, cy, rad: Single; const c: TRGBA);
procedure FillEllipse(cx, cy, rx, ry: Single; const c: TRGBA);
procedure FillEllipseGrad(cx, cy, rx, ry: Single; const cin, cout: TRGBA);
procedure Ring(cx, cy, rx, ry, thick: Single; const c: TRGBA);
procedure FillPie(cx, cy, rad, a0, a1: Single; const c: TRGBA);
procedure FillTri(x1, y1, x2, y2, x3, y3: Single; const c: TRGBA);
procedure FillQuad(x1, y1, x2, y2, x3, y3, x4, y4: Single; const c: TRGBA);
procedure FillPoly(const pts: array of Single; const c: TRGBA);   // convex, x,y pairs
procedure ThickLine(x1, y1, x2, y2, w: Single; const c: TRGBA);
procedure RoundRect(x, y, w, h, rad: Single; const c: TRGBA);

procedure DrawText(x, y: Single; const s: string; const c: TRGBA;
  f: TFontId = fnSmall; align: Integer = ALIGN_LEFT; outline: Boolean = True);
function TextWidth(const s: string; f: TFontId = fnSmall): Single;
function TextHeight(f: TFontId = fnSmall): Single;

implementation

type
  TGlyph = record
    x, y, w, h: Integer;
  end;

  TFontAtlas = record
    Ok: Boolean;
    Tex, OutTex: PSDL_Texture;
    Glyph, OutGlyph: array[32..126] of TGlyph;
    Height, Outline: Integer;
  end;

const
  MAX_VERTS = 6000;

var
  Verts: array[0..MAX_VERTS - 1] of TSDL_Vertex;
  NVerts: Integer;
  Fonts: array[TFontId] of TFontAtlas;
  TtfOk: Boolean;

{ ---------- colors ---------- }

function RGBA(r, g, b: Byte; a: Byte): TRGBA;
begin
  Result.r := r; Result.g := g; Result.b := b; Result.a := a;
end;

function ClampB(v: Single): Byte;
begin
  if v < 0 then Result := 0
  else if v > 255 then Result := 255
  else Result := Round(v);
end;

function Shade(const c: TRGBA; f: Single): TRGBA;
begin
  Result.r := ClampB(c.r * f);
  Result.g := ClampB(c.g * f);
  Result.b := ClampB(c.b * f);
  Result.a := c.a;
end;

function WithAlpha(const c: TRGBA; a: Byte): TRGBA;
begin
  Result := c;
  Result.a := a;
end;

function Mix(const c1, c2: TRGBA; t: Single): TRGBA;
begin
  Result.r := ClampB(c1.r + (c2.r - c1.r) * t);
  Result.g := ClampB(c1.g + (c2.g - c1.g) * t);
  Result.b := ClampB(c1.b + (c2.b - c1.b) * t);
  Result.a := ClampB(c1.a + (c2.a - c1.a) * t);
end;

{ ---------- geometry batching ---------- }

procedure Flush;
begin
  if NVerts > 0 then
    SDL_RenderGeometry(Ren, nil, @Verts[0], NVerts, nil, 0);
  NVerts := 0;
end;

procedure AddV(x, y: Single; const c: TRGBA); inline;
begin
  with Verts[NVerts] do
  begin
    position.x := x + OfsX;
    position.y := y + OfsY;
    color.r := c.r / 255;
    color.g := c.g / 255;
    color.b := c.b / 255;
    color.a := c.a / 255;
    tex_coord.x := 0;
    tex_coord.y := 0;
  end;
  Inc(NVerts);
end;

procedure Need(n: Integer);
begin
  if NVerts + n > MAX_VERTS then Flush;
end;

procedure SetBlendAdd(add: Boolean);
begin
  Flush;
  if add then
    SDL_SetRenderDrawBlendMode(Ren, SDL_BLENDMODE_ADD)
  else
    SDL_SetRenderDrawBlendMode(Ren, SDL_BLENDMODE_BLEND);
end;

procedure FillTri(x1, y1, x2, y2, x3, y3: Single; const c: TRGBA);
begin
  Need(3);
  AddV(x1, y1, c); AddV(x2, y2, c); AddV(x3, y3, c);
  Flush;
end;

procedure FillQuad(x1, y1, x2, y2, x3, y3, x4, y4: Single; const c: TRGBA);
begin
  Need(6);
  AddV(x1, y1, c); AddV(x2, y2, c); AddV(x3, y3, c);
  AddV(x1, y1, c); AddV(x3, y3, c); AddV(x4, y4, c);
  Flush;
end;

procedure FillRect(x, y, w, h: Single; const c: TRGBA);
begin
  FillQuad(x, y, x + w, y, x + w, y + h, x, y + h, c);
end;

procedure FillRectGrad(x, y, w, h: Single; const top, bottom: TRGBA);
begin
  Need(6);
  AddV(x, y, top); AddV(x + w, y, top); AddV(x + w, y + h, bottom);
  AddV(x, y, top); AddV(x + w, y + h, bottom); AddV(x, y + h, bottom);
  Flush;
end;

procedure FillPoly(const pts: array of Single; const c: TRGBA);
var
  i, n: Integer;
begin
  n := Length(pts) div 2;
  if n < 3 then Exit;
  Need((n - 2) * 3);
  for i := 1 to n - 2 do
  begin
    AddV(pts[0], pts[1], c);
    AddV(pts[i * 2], pts[i * 2 + 1], c);
    AddV(pts[i * 2 + 2], pts[i * 2 + 3], c);
  end;
  Flush;
end;

function Segs(r: Single): Integer;
begin
  Result := EnsureRange(Round(r * 0.9), 12, 72);
end;

procedure FillEllipseGrad(cx, cy, rx, ry: Single; const cin, cout: TRGBA);
var
  i, n: Integer;
  a1, a2: Single;
begin
  if (rx <= 0) or (ry <= 0) then Exit;
  n := Segs(Max(rx, ry));
  Need(n * 3);
  for i := 0 to n - 1 do
  begin
    a1 := 2 * Pi * i / n;
    a2 := 2 * Pi * (i + 1) / n;
    AddV(cx, cy, cin);
    AddV(cx + Cos(a1) * rx, cy + Sin(a1) * ry, cout);
    AddV(cx + Cos(a2) * rx, cy + Sin(a2) * ry, cout);
  end;
  Flush;
end;

procedure FillEllipse(cx, cy, rx, ry: Single; const c: TRGBA);
begin
  FillEllipseGrad(cx, cy, rx, ry, c, c);
end;

procedure FillCircle(cx, cy, rad: Single; const c: TRGBA);
begin
  FillEllipseGrad(cx, cy, rad, rad, c, c);
end;

procedure Ring(cx, cy, rx, ry, thick: Single; const c: TRGBA);
var
  i, n: Integer;
  a1, a2, ix, iy: Single;
begin
  n := Segs(Max(rx, ry));
  ix := Max(0, rx - thick);
  iy := Max(0, ry - thick);
  Need(n * 6);
  for i := 0 to n - 1 do
  begin
    a1 := 2 * Pi * i / n;
    a2 := 2 * Pi * (i + 1) / n;
    AddV(cx + Cos(a1) * rx, cy + Sin(a1) * ry, c);
    AddV(cx + Cos(a2) * rx, cy + Sin(a2) * ry, c);
    AddV(cx + Cos(a2) * ix, cy + Sin(a2) * iy, c);
    AddV(cx + Cos(a1) * rx, cy + Sin(a1) * ry, c);
    AddV(cx + Cos(a2) * ix, cy + Sin(a2) * iy, c);
    AddV(cx + Cos(a1) * ix, cy + Sin(a1) * iy, c);
  end;
  Flush;
end;

procedure FillPie(cx, cy, rad, a0, a1: Single; const c: TRGBA);
var
  i, n: Integer;
  b1, b2: Single;
begin
  if a1 <= a0 then Exit;
  n := Max(2, Round(Segs(rad) * (a1 - a0) / (2 * Pi)));
  Need(n * 3);
  for i := 0 to n - 1 do
  begin
    b1 := a0 + (a1 - a0) * i / n;
    b2 := a0 + (a1 - a0) * (i + 1) / n;
    AddV(cx, cy, c);
    AddV(cx + Cos(b1) * rad, cy + Sin(b1) * rad, c);
    AddV(cx + Cos(b2) * rad, cy + Sin(b2) * rad, c);
  end;
  Flush;
end;

procedure ThickLine(x1, y1, x2, y2, w: Single; const c: TRGBA);
var
  dx, dy, len, nx, ny: Single;
begin
  dx := x2 - x1;
  dy := y2 - y1;
  len := Sqrt(dx * dx + dy * dy);
  if len < 0.001 then Exit;
  nx := -dy / len * w * 0.5;
  ny := dx / len * w * 0.5;
  FillQuad(x1 + nx, y1 + ny, x2 + nx, y2 + ny, x2 - nx, y2 - ny, x1 - nx, y1 - ny, c);
end;

procedure RoundRect(x, y, w, h, rad: Single; const c: TRGBA);
begin
  rad := Min(rad, Min(w, h) / 2);
  FillRect(x + rad, y, w - 2 * rad, h, c);
  FillRect(x, y + rad, rad, h - 2 * rad, c);
  FillRect(x + w - rad, y + rad, rad, h - 2 * rad, c);
  FillPie(x + rad, y + rad, rad, Pi, 1.5 * Pi, c);
  FillPie(x + w - rad, y + rad, rad, 1.5 * Pi, 2 * Pi, c);
  FillPie(x + w - rad, y + h - rad, rad, 0, 0.5 * Pi, c);
  FillPie(x + rad, y + h - rad, rad, 0.5 * Pi, Pi, c);
end;

{ ---------- text ---------- }

function BuildAtlas(font: PTTF_Font; var g: array of TGlyph): PSDL_Texture;
const
  ATLAS_W = 1024;
var
  ch, x, y, rowH: Integer;
  white: TSDL_Color;
  s: array[0..1] of AnsiChar;
  surf, atlas: PSDL_Surface;
  dst: TSDL_Rect;
begin
  Result := nil;
  white.r := 255; white.g := 255; white.b := 255; white.a := 255;
  atlas := SDL_CreateSurface(ATLAS_W, 512, SDL_PIXELFORMAT_ARGB8888);
  if atlas = nil then Exit;
  x := 1; y := 1; rowH := 0;
  for ch := 32 to 126 do
  begin
    s[0] := AnsiChar(ch);
    s[1] := #0;
    surf := TTF_RenderText_Blended(font, @s[0], 1, white);
    g[ch - 32].w := 0;
    g[ch - 32].h := 0;
    if surf = nil then Continue;
    if x + surf^.w + 1 > ATLAS_W then
    begin
      x := 1;
      Inc(y, rowH + 1);
      rowH := 0;
    end;
    dst.x := x; dst.y := y; dst.w := surf^.w; dst.h := surf^.h;
    SDL_SetSurfaceBlendMode(surf, SDL_BLENDMODE_NONE);
    SDL_BlitSurface(surf, nil, atlas, @dst);
    g[ch - 32].x := x; g[ch - 32].y := y;
    g[ch - 32].w := surf^.w; g[ch - 32].h := surf^.h;
    Inc(x, surf^.w + 1);
    rowH := Max(rowH, surf^.h);
    SDL_DestroySurface(surf);
  end;
  Result := SDL_CreateTextureFromSurface(Ren, atlas);
  SDL_DestroySurface(atlas);
  if Result <> nil then
  begin
    SDL_SetTextureBlendMode(Result, SDL_BLENDMODE_BLEND);
    SDL_SetTextureScaleMode(Result, SDL_SCALEMODE_LINEAR);
  end;
end;

procedure LoadFont(id: TFontId; const path: string; size: Single; outline: Integer);
var
  f: PTTF_Font;
begin
  Fonts[id].Ok := False;
  f := TTF_OpenFont(PAnsiChar(path), size);
  if f = nil then Exit;
  Fonts[id].Height := TTF_GetFontHeight(f);
  Fonts[id].Outline := outline;
  Fonts[id].Tex := BuildAtlas(f, Fonts[id].Glyph);
  TTF_SetFontOutline(f, outline);
  Fonts[id].OutTex := BuildAtlas(f, Fonts[id].OutGlyph);
  TTF_CloseFont(f);
  Fonts[id].Ok := (Fonts[id].Tex <> nil) and (Fonts[id].OutTex <> nil);
end;

procedure GfxInit(r: PSDL_Renderer);
const
  Candidates: array[0..3] of string = (
    'segoeuib.ttf', 'arialbd.ttf', 'tahomabd.ttf', 'arial.ttf');
var
  dir, path: string;
  i: Integer;
begin
  Ren := r;
  NVerts := 0;
  OfsX := 0;
  OfsY := 0;
  TtfOk := TTF_Init;
  if not TtfOk then Exit;
  dir := GetEnvironmentVariable('WINDIR') + '\Fonts\';
  path := '';
  // a font shipped next to the exe wins over system fonts
  if FileExists(ExtractFilePath(ParamStr(0)) + 'font.ttf') then
    path := ExtractFilePath(ParamStr(0)) + 'font.ttf'
  else
    for i := Low(Candidates) to High(Candidates) do
      if FileExists(dir + Candidates[i]) then
      begin
        path := dir + Candidates[i];
        Break;
      end;
  if path = '' then
  begin
    TtfOk := False;
    Exit;
  end;
  LoadFont(fnSmall, path, 14, 2);
  LoadFont(fnMedium, path, 20, 2);
  LoadFont(fnBig, path, 44, 3);
end;

procedure GfxDone;
var
  f: TFontId;
begin
  for f := Low(TFontId) to High(TFontId) do
    if Fonts[f].Ok then
    begin
      SDL_DestroyTexture(Fonts[f].Tex);
      SDL_DestroyTexture(Fonts[f].OutTex);
      Fonts[f].Ok := False;
    end;
  if TtfOk then TTF_Quit;
end;

function TextWidth(const s: string; f: TFontId): Single;
var
  i, ch: Integer;
begin
  Result := 0;
  if not Fonts[f].Ok then Exit(Length(s) * 8);
  for i := 1 to Length(s) do
  begin
    ch := Ord(s[i]);
    if (ch >= 32) and (ch <= 126) then
      Result := Result + Fonts[f].Glyph[ch].w;
  end;
end;

function TextHeight(f: TFontId): Single;
begin
  if Fonts[f].Ok then Result := Fonts[f].Height else Result := 8;
end;

procedure DrawGlyphs(tex: PSDL_Texture; const g: array of TGlyph; const adv: array of TGlyph;
  x, y: Single; const s: string; const c: TRGBA);
var
  i, ch: Integer;
  src, dst: TSDL_FRect;
begin
  SDL_SetTextureColorMod(tex, c.r, c.g, c.b);
  SDL_SetTextureAlphaMod(tex, c.a);
  for i := 1 to Length(s) do
  begin
    ch := Ord(s[i]) - 32;
    if (ch < 0) or (ch > 94) then Continue;
    if g[ch].w > 0 then
    begin
      src.x := g[ch].x; src.y := g[ch].y; src.w := g[ch].w; src.h := g[ch].h;
      dst.x := x + OfsX; dst.y := y + OfsY; dst.w := g[ch].w; dst.h := g[ch].h;
      SDL_RenderTexture(Ren, tex, @src, @dst);
    end;
    x := x + adv[ch].w;
  end;
end;

procedure DrawText(x, y: Single; const s: string; const c: TRGBA;
  f: TFontId; align: Integer; outline: Boolean);
var
  w: Single;
  o: Integer;
begin
  if s = '' then Exit;
  Flush;
  w := TextWidth(s, f);
  if align = ALIGN_CENTER then x := x - w / 2
  else if align = ALIGN_RIGHT then x := x - w;
  x := Round(x);
  y := Round(y);
  if not Fonts[f].Ok then
  begin
    SDL_SetRenderDrawColor(Ren, c.r, c.g, c.b, c.a);
    SDL_RenderDebugText(Ren, x + OfsX, y + OfsY, PAnsiChar(s));
    Exit;
  end;
  if outline then
  begin
    o := Fonts[f].Outline;
    DrawGlyphs(Fonts[f].OutTex, Fonts[f].OutGlyph, Fonts[f].Glyph, x - o, y - o, s,
      RGBA(20, 12, 6, Round(c.a * 0.85)));
  end;
  DrawGlyphs(Fonts[f].Tex, Fonts[f].Glyph, Fonts[f].Glyph, x, y, s, c);
end;

end.
