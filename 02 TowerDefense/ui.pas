unit ui;

{ Minimal immediate-mode UI shared by the editors (GeoEdit, MapEdit):
  per-frame mouse state, buttons, swatches, clipping. Call UIBeginFrame before polling events,
  UIHandleEvent for every event, then draw widgets; the first widget that claims a click sets Consumed. }

{$mode objfpc}{$H+}

interface

uses
  SDL3, Math, gfx;

const
  C_BG: TRGBA = (r: 30; g: 32; b: 38; a: 255);
  C_PANEL: TRGBA = (r: 40; g: 43; b: 50; a: 255);
  C_PANEL2: TRGBA = (r: 48; g: 52; b: 60; a: 255);
  C_LINE: TRGBA = (r: 62; g: 66; b: 76; a: 255);
  C_TEXT: TRGBA = (r: 225; g: 228; b: 235; a: 255);
  C_DIM: TRGBA = (r: 140; g: 145; b: 155; a: 255);
  C_ACCENT: TRGBA = (r: 255; g: 190; b: 80; a: 255);
  C_SEL: TRGBA = (r: 70; g: 110; b: 170; a: 255);

var
  MX, MY: Single;
  LDown, LUp, LHeld, RDown, RHeld, MDownBtn, MHeld: Boolean;
  DblClick: Boolean;
  WheelY: Single;
  Consumed: Boolean;
  ModCtrl, ModShift, ModAlt: Boolean;

procedure UIBeginFrame;
procedure UIHandleEvent(const ev: TSDL_Event);   // mouse + modifier tracking
procedure UIUpdateMods;

function Inside(x, y, w, h: Single): Boolean;
function Button(x, y, w, h: Single; const caption: string; active: Boolean = False;
  enabled: Boolean = True): Boolean;
procedure Checker(x, y, w, h, cell: Single);
procedure Swatch(x, y, w, h: Single; const c: TRGBA);
procedure SetClip(x, y, w, h: Integer);
procedure NoClip;

implementation

procedure UIBeginFrame;
begin
  LDown := False;
  LUp := False;
  RDown := False;
  MDownBtn := False;
  DblClick := False;
  WheelY := 0;
  Consumed := False;
end;

procedure UIUpdateMods;
var
  ms: TSDL_Keymod;
begin
  ms := SDL_GetModState;
  ModCtrl := (ms and SDL_KMOD_CTRL) <> 0;
  ModShift := (ms and SDL_KMOD_SHIFT) <> 0;
  ModAlt := (ms and SDL_KMOD_ALT) <> 0;
end;

procedure UIHandleEvent(const ev: TSDL_Event);
begin
  case ev._type of
    SDL_EVENT_MOUSE_MOTION:
      begin
        MX := ev.motion.x;
        MY := ev.motion.y;
      end;
    SDL_EVENT_MOUSE_BUTTON_DOWN:
      begin
        MX := ev.button.x;
        MY := ev.button.y;
        case ev.button.button of
          SDL_BUTTON_LEFT:
            begin
              LDown := True;
              LHeld := True;
              if ev.button.clicks >= 2 then DblClick := True;
            end;
          SDL_BUTTON_RIGHT: begin RDown := True; RHeld := True; end;
          SDL_BUTTON_MIDDLE: begin MDownBtn := True; MHeld := True; end;
        end;
      end;
    SDL_EVENT_MOUSE_BUTTON_UP:
      case ev.button.button of
        SDL_BUTTON_LEFT: begin LUp := True; LHeld := False; end;
        SDL_BUTTON_RIGHT: RHeld := False;
        SDL_BUTTON_MIDDLE: MHeld := False;
      end;
    SDL_EVENT_MOUSE_WHEEL:
      WheelY := WheelY + ev.wheel.y;
    SDL_EVENT_KEY_DOWN, SDL_EVENT_KEY_UP:
      UIUpdateMods;
  end;
end;

function Inside(x, y, w, h: Single): Boolean;
begin
  Result := (MX >= x) and (MX < x + w) and (MY >= y) and (MY < y + h);
end;

function Button(x, y, w, h: Single; const caption: string; active: Boolean; enabled: Boolean): Boolean;
var
  hover: Boolean;
  c: TRGBA;
begin
  hover := Inside(x, y, w, h) and enabled;
  if active then c := C_SEL
  else if hover then c := RGBA(70, 75, 88)
  else c := C_PANEL2;
  if not enabled then c := RGBA(44, 46, 52);
  RoundRect(x, y, w, h, 4, c);
  if enabled then
    DrawText(x + w / 2, y + (h - TextHeight(fnSmall)) / 2, caption, C_TEXT, fnSmall, ALIGN_CENTER, False)
  else
    DrawText(x + w / 2, y + (h - TextHeight(fnSmall)) / 2, caption, RGBA(100, 104, 112), fnSmall, ALIGN_CENTER, False);
  Result := False;
  if hover and LDown and not Consumed then
  begin
    Consumed := True;
    Result := True;
  end;
end;

procedure Checker(x, y, w, h, cell: Single);
var
  i, j: Integer;
begin
  for j := 0 to Ceil(h / cell) - 1 do
    for i := 0 to Ceil(w / cell) - 1 do
      if (i + j) mod 2 = 0 then
        FillRect(x + i * cell, y + j * cell, Min(cell, w - i * cell), Min(cell, h - j * cell), RGBA(200, 200, 200))
      else
        FillRect(x + i * cell, y + j * cell, Min(cell, w - i * cell), Min(cell, h - j * cell), RGBA(150, 150, 150));
end;

procedure Swatch(x, y, w, h: Single; const c: TRGBA);
begin
  Checker(x, y, w, h, 5);
  FillRect(x, y, w, h, c);
  FillRect(x, y, w, 1, C_LINE); FillRect(x, y + h - 1, w, 1, C_LINE);
  FillRect(x, y, 1, h, C_LINE); FillRect(x + w - 1, y, 1, h, C_LINE);
end;

procedure SetClip(x, y, w, h: Integer);
var
  r: TSDL_Rect;
begin
  r.x := x; r.y := y; r.w := w; r.h := h;
  SDL_SetRenderClipRect(Ren, @r);
end;

procedure NoClip;
begin
  SDL_SetRenderClipRect(Ren, nil);
end;

end.
