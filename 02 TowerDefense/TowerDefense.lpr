program TowerDefense;

{ Brewhold Defense - a Kingdom-Rush-style tower defense
  Lazarus / Free Pascal + SDL3 (+ SDL3_ttf for text, SDL3_image for bitmap shapes).

  All content is data-driven, loaded from the "data" folder next to the exe:
    rules.json, towers.json, enemies.json, waves.json, maps/<map>.json, geometry.json
  Edit geometry with GeoEdit; edit everything else in any text editor and press F5 in game.

  Controls
    LMB on a stone plot ........ open build menu
    LMB on a tower ............. upgrade / sell / move rally point (barracks)
    LMB on a skull ............. call the next wave early (bonus gold)
    1 / 2 ...................... Rain of Fire / Reinforcements, then click on the map
    H or click the hero ........ select the hero, then click where he should go
    3 / 4 ...................... hero abilities: Thunder Slam / Hammer Throw
    SPACE ...................... call next wave
    F .......................... toggle game speed x1 / x2
    M .......................... mute / unmute sound
    F5 ......................... reload all data files and restart
    P or ESC ................... pause (ESC cancels selection first)
    R .......................... restart (when paused / game over)
    L .......................... back to the map select screen (when paused / game over)
    F11 ........................ toggle fullscreen
  Main menu: New Game (map select), Continue (checkpoint saved at the start of every wave in
  savegame.json), Options (music / sound volume, fullscreen, screen shake -> options.json), Exit.

  Command line
    --map <name>                 skip the map select screen and play data\maps\<name>.json
    --menu                       start on the map select screen (also with --shot)
    --title                      start on the main menu (also with --shot)
    --shot <file.bmp> [seconds]  build a demo defence, simulate, save a screenshot, quit
    --sound                      keep sound on in --shot mode
    --wave <n>                   start at wave n, with the gold earned from earlier waves (play-testing)
    --dumpsfx <folder>           write every synthesized sound effect as a WAV file }

{$mode objfpc}{$H+}
{$APPTYPE GUI}

uses
  SDL3, SysUtils, Classes, Math, StrUtils, fpjson, jsonparser, gfx, sfx, geometry, gamedata, mapcore;

const
  SCR_W = 1280;
  SCR_H = 720;

  MAX_ENEMIES   = 300;
  MAX_SOLDIERS  = 160;
  MAX_PROJ      = 400;
  MAX_PARTICLES = 1500;
  MAX_SPAWNS    = 600;
  MAX_PLOTS     = 64;

  // projectile kinds
  PK_ARROW = 0;
  PK_BOLT = 1;
  PK_BOMB = 2;
  PK_METEOR = 3;
  PK_HAMMER = 4;

  HERO_BLOCK = 100000;   // Enemy.Blocker value meaning 'blocked by the hero'

  // particle kinds
  PT_DOT = 0;
  PT_SMOKE = 1;
  PT_SPARK = 2;
  PT_TEXT = 3;
  PT_RING = 4;
  PT_FLASH = 5;
  PT_ARROW = 6;

  // spells
  SP_NONE = 0;
  SP_FIRE = 1;
  SP_REINF = 2;

type
  TPlot = record
    X, Y: Single;
    Kind, Level: Integer;        // Kind = index into TowerDefs, -1 = empty
    Cooldown, Aim, SinceFire: Single;
    RallyX, RallyY: Single;
    Spent: Integer;
  end;

  TEnemy = record
    Active: Boolean;
    Id, Kind, PathIdx: Integer;
    Dist, Offset: Single;
    X, Y: Single;
    Hp, MaxHp, Speed, Armor, Dmg: Single;
    Flying: Boolean;
    Blocker: Integer;
    AtkCd, Facing, Anim, Flash, StunT: Single;
  end;

  TSoldier = record
    Active, Alive, Moving: Boolean;
    Owner, Slot: Integer;       // Owner = plot index, -1 = militia
    X, Y: Single;
    Hp, MaxHp, Dmg: Single;
    Target, TargetId: Integer;
    AtkCd, Respawn, Life, MaxLife, Facing, Anim, Swing: Single;
    GuardX, GuardY: Single;
  end;

  TProj = record
    Active: Boolean;
    Kind, Geo, HitSnd: Integer;
    Magic, HitsAir, FromHero: Boolean;
    SX, SY, TX, TY, X, Y, PX, PY: Single;
    Target, TargetId: Integer;
    T, Dur, ArcH, Dmg, Splash: Single;
  end;

  TParticle = record
    Active: Boolean;
    Kind: Integer;
    X, Y, VX, VY, Grav: Single;
    Life, MaxLife, Size, Rot: Single;
    Col: TRGBA;
    Txt: string[24];
  end;

  TSpawn = record
    T: Single;
    Kind, Path: Integer;
  end;

  TDrawItem = record
    Y: Single;
    Kind, Idx: Integer;
  end;

  THeroUnit = record
    Alive, Ordered, Moving, Selected: Boolean;
    X, Y, TX, TY: Single;
    Hp, MaxHp: Single;
    Level, Xp: Integer;
    AtkCd, Swing, Facing, Anim, Respawn, SlamCd, HammerCd, LevelFlash: Single;
    Target, TargetId: Integer;
  end;

  TUIButton = record
    X, Y, W, H: Single;
    Id: Integer;
  end;

  TGameState = (gsPlaying, gsWon, gsLost, gsMenu, gsTitle);

var
  Window: PSDL_Window;
  Renderer: PSDL_Renderer;
  BgTex: PSDL_Texture;
  MapName: string;

  Paths: TPathArray;
  Plots: array[0..MAX_PLOTS - 1] of TPlot;
  NPlots: Integer;
  Enemies: array[0..MAX_ENEMIES - 1] of TEnemy;
  Soldiers: array[0..MAX_SOLDIERS - 1] of TSoldier;
  Projs: array[0..MAX_PROJ - 1] of TProj;
  Parts: array[0..MAX_PARTICLES - 1] of TParticle;

  Spawns: array[0..MAX_SPAWNS - 1] of TSpawn;
  NSpawns, SpawnPos: Integer;
  WaveTime: Single;

  State: TGameState;
  Paused: Boolean;
  Speed2x: Boolean;
  Gold, Lives, Wave: Integer;
  NextWaveTimer: Single;     // <0: waiting for the player to start the first wave
  WaveSpawning: Boolean;
  NextEnemyId: Integer;
  GameTime: Single;
  Kills: Integer;

  SelPlot: Integer;
  RallyMode: Boolean;
  SpellMode: Integer;
  FireCd, ReinfCd: Single;
  MouseX, MouseY: Single;
  Shake: Single;
  HurtFlash: Single;
  BannerText: string;
  BannerTime: Single;
  StartWaveArg: Integer = 1;
  // map select screen
  MenuNames: array of string;
  MenuMaps: array of TMapDef;
  MenuThumbs: array of PSDL_Texture;
  MenuWaves: array of Integer;
  MenuSel: Integer = 0;
  // front end
  UIButtons: array of TUIButton;
  OptionsOpen: Boolean = False;
  OptFullscreen: Boolean = False;
  OptShake: Boolean = True;
  QuitRequested: Boolean = False;
  LastMusic: string = '#';
  TitleSel: Integer = 0;
  SaveDisabled: Boolean = False;
  JsonFS: TFormatSettings;
  HeroU: THeroUnit;
  HeroSpawnX, HeroSpawnY: Single;
  HeroHitting: Boolean = False;     // set while hero damage is applied (for xp)
  HeroQuietXp: Boolean = False;

  // resolved once per data load
  GeoPlotEmpty, GeoPlotBuilt: Integer;
  TowerFireSnd, TowerHitSnd: array of Integer;
  EnemyDeathSnd: array of Integer;

  DrawList: array[0..MAX_PLOTS + MAX_ENEMIES + MAX_SOLDIERS - 1] of TDrawItem;

{ ======================================================================
  helpers
  ====================================================================== }

function Dist2(x1, y1, x2, y2: Single): Single; inline;
begin
  Result := Sqr(x2 - x1) + Sqr(y2 - y1);
end;

function RandF(a, b: Single): Single;
begin
  Result := a + Random * (b - a);
end;

function Clamp01(v: Single): Single;
begin
  Result := EnsureRange(v, 0.0, 1.0);
end;

function TotalWaves: Integer;
begin
  Result := Length(Waves);
end;

function TStat(kind, level: Integer): TTowerLevel;
begin
  Result := TowerDefs[kind].Levels[EnsureRange(level - 1, 0, High(TowerDefs[kind].Levels))];
end;

function MaxLevel(kind: Integer): Integer;
begin
  Result := Length(TowerDefs[kind].Levels);
end;

function IsBarracks(p: Integer): Boolean;
begin
  Result := (Plots[p].Kind >= 0) and (TowerDefs[Plots[p].Kind].Behavior = TB_BARRACKS);
end;

function MakeState: TAnimState;
begin
  Result := DefaultAnimState;
  Result.Time := GameTime;
end;

{ ======================================================================
  paths
  ====================================================================== }

procedure NearestPathPoint(x, y: Single; out nx, ny, dist: Single);
begin
  mapcore.NearestPathPoint(Paths, x, y, nx, ny, dist);
end;

function PathDist(x, y: Single): Single;
var
  nx, ny: Single;
begin
  NearestPathPoint(x, y, nx, ny, Result);
end;

procedure InitWorld;
var
  i: Integer;
  dx_, dy_: Single;
begin
  BuildAllPaths(Map, Paths);
  NPlots := Min(Length(Map.PlotX), MAX_PLOTS);
  for i := 0 to NPlots - 1 do
  begin
    FillChar(Plots[i], SizeOf(Plots[i]), 0);
    Plots[i].X := Map.PlotX[i];
    Plots[i].Y := Map.PlotY[i];
    Plots[i].Kind := -1;
  end;
  GeoPlotEmpty := Geo.Find('plot.empty');
  GeoPlotBuilt := Geo.Find('plot.built');
  SetLength(TowerFireSnd, Length(TowerDefs));
  SetLength(TowerHitSnd, Length(TowerDefs));
  for i := 0 to High(TowerDefs) do
  begin
    TowerFireSnd[i] := SoundByName(TowerDefs[i].FireSound);
    TowerHitSnd[i] := SoundByName(TowerDefs[i].HitSound);
  end;
  SetLength(EnemyDeathSnd, Length(EnemyDefs));
  for i := 0 to High(EnemyDefs) do
    EnemyDeathSnd[i] := SoundByName(EnemyDefs[i].DeathSound);
  Hero.Slam.SoundIdx := SoundByName(Hero.Slam.Sound);
  Hero.Hammer.SoundIdx := SoundByName(Hero.Hammer.Sound);
  if (Map.HeroX <> 0) or (Map.HeroY <> 0) then
  begin
    HeroSpawnX := Map.HeroX;
    HeroSpawnY := Map.HeroY;
  end
  else if Length(Paths) > 0 then
  begin
    // default: on the first road, three quarters of the way to the gate
    PathPos(Paths[0], Paths[0].Len * 0.72, HeroSpawnX, HeroSpawnY, dx_, dy_);
  end;
end;

{ ======================================================================
  background (static parts of the map rendered once into a texture)
  ====================================================================== }

procedure SortDecorByY;
var
  i, j: Integer;
  t: TMapDecor;
begin
  for i := 1 to High(Map.Decor) do
  begin
    t := Map.Decor[i];
    j := i - 1;
    while (j >= 0) and (Map.Decor[j].Y > t.Y) do
    begin
      Map.Decor[j + 1] := Map.Decor[j];
      Dec(j);
    end;
    Map.Decor[j + 1] := t;
  end;
end;

procedure RenderBackground;
var
  i: Integer;
  st: TAnimState;
begin
  if BgTex <> nil then SDL_DestroyTexture(BgTex);
  BgTex := SDL_CreateTexture(Renderer, SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_TARGET, SCR_W, SCR_H);
  SDL_SetRenderTarget(Renderer, BgTex);
  SDL_SetRenderDrawBlendMode(Renderer, SDL_BLENDMODE_BLEND);
  SDL_SetRenderDrawColor(Renderer, 0, 0, 0, 255);
  SDL_RenderClear(Renderer);
  DrawMapBase(Map, Paths);
  st := DefaultAnimState;
  for i := 0 to High(Map.Decor) do
    DrawGeoIdx(Geo, Map.Decor[i].GeoIdx, Map.Decor[i].X, Map.Decor[i].Y, Map.Decor[i].S, st, dmStatic);
  if Map.Fortress then DrawFortress(SCR_W, SCR_H);
  DrawVignette(SCR_W, SCR_H);
  SDL_SetRenderTarget(Renderer, nil);
end;

{ ======================================================================
  particles
  ====================================================================== }

function NewParticle: Integer;
var
  i: Integer;
begin
  for i := 0 to MAX_PARTICLES - 1 do
    if not Parts[i].Active then
    begin
      FillChar(Parts[i], SizeOf(Parts[i]), 0);
      Parts[i].Active := True;
      Exit(i);
    end;
  Result := -1;
end;

procedure Emit(kind: Integer; x, y, vx, vy, life, size: Single; const c: TRGBA; grav: Single = 0);
var
  i: Integer;
begin
  i := NewParticle;
  if i < 0 then Exit;
  Parts[i].Kind := kind;
  Parts[i].X := x; Parts[i].Y := y;
  Parts[i].VX := vx; Parts[i].VY := vy;
  Parts[i].Life := life; Parts[i].MaxLife := life;
  Parts[i].Size := size;
  Parts[i].Col := c;
  Parts[i].Grav := grav;
  Parts[i].Rot := RandF(0, 2 * Pi);
end;

procedure FloatText(x, y: Single; const s: string; const c: TRGBA);
var
  i: Integer;
begin
  i := NewParticle;
  if i < 0 then Exit;
  Parts[i].Kind := PT_TEXT;
  Parts[i].X := x; Parts[i].Y := y;
  Parts[i].VY := -38;
  Parts[i].Life := 1.1; Parts[i].MaxLife := 1.1;
  Parts[i].Col := c;
  Parts[i].Txt := s;
end;

procedure Burst(x, y: Single; n: Integer; const c: TRGBA; speed, life, size: Single; grav: Single = 0);
var
  i: Integer;
  a, v: Single;
begin
  for i := 1 to n do
  begin
    a := RandF(0, 2 * Pi);
    v := RandF(0.3, 1) * speed;
    Emit(PT_DOT, x, y, Cos(a) * v, Sin(a) * v * 0.7 - speed * 0.3, life * RandF(0.6, 1.2),
      size * RandF(0.6, 1.3), c, grav);
  end;
end;

procedure Explosion(x, y, radius: Single);
var
  i: Integer;
  a, v: Single;
begin
  Emit(PT_FLASH, x, y, 0, 0, 0.18, radius * 1.1, RGBA(255, 230, 150));
  Emit(PT_RING, x, y, 0, 0, 0.35, radius, RGBA(255, 200, 120));
  for i := 1 to 18 do
  begin
    a := RandF(0, 2 * Pi);
    v := RandF(60, 220);
    Emit(PT_SPARK, x, y, Cos(a) * v, Sin(a) * v * 0.6 - 60, RandF(0.3, 0.6), RandF(2, 4),
      RGBA(255, Random(120) + 120, 40), 300);
  end;
  for i := 1 to 9 do
    Emit(PT_SMOKE, x + RandF(-radius, radius) * 0.4, y + RandF(-radius, radius) * 0.3,
      RandF(-20, 20), RandF(-40, -15), RandF(0.7, 1.3), RandF(10, 18), RGBA(70, 60, 55, 170));
  Emit(PT_DOT, x, y + 2, 0, 0, 2.5, radius * 0.45, RGBA(40, 24, 14, 110));
  Shake := Max(Shake, 4);
end;

procedure UpdateParticles(dt: Single);
var
  i: Integer;
begin
  for i := 0 to MAX_PARTICLES - 1 do
    if Parts[i].Active then
    begin
      Parts[i].Life := Parts[i].Life - dt;
      if Parts[i].Life <= 0 then
      begin
        Parts[i].Active := False;
        Continue;
      end;
      Parts[i].X := Parts[i].X + Parts[i].VX * dt;
      Parts[i].Y := Parts[i].Y + Parts[i].VY * dt;
      Parts[i].VY := Parts[i].VY + Parts[i].Grav * dt;
      if Parts[i].Kind = PT_SMOKE then
      begin
        Parts[i].VX := Parts[i].VX * (1 - dt);
        Parts[i].Size := Parts[i].Size + 10 * dt;
      end
      else if Parts[i].Kind = PT_TEXT then
        Parts[i].VY := Parts[i].VY * (1 - 1.5 * dt);
    end;
end;

procedure DrawParticles(textPass: Boolean);
var
  i: Integer;
  f: Single;
  p: TParticle;
begin
  for i := 0 to MAX_PARTICLES - 1 do
  begin
    if not Parts[i].Active then Continue;
    p := Parts[i];
    if textPass <> (p.Kind = PT_TEXT) then Continue;
    f := p.Life / p.MaxLife;
    case p.Kind of
      PT_DOT:
        FillCircle(p.X, p.Y, p.Size * (0.4 + 0.6 * f), WithAlpha(p.Col, Round(p.Col.a * Min(1, f * 2))));
      PT_SMOKE:
        FillCircle(p.X, p.Y, p.Size, WithAlpha(p.Col, Round(p.Col.a * f)));
      PT_SPARK:
        begin
          SetBlendAdd(True);
          ThickLine(p.X, p.Y, p.X - p.VX * 0.03, p.Y - p.VY * 0.03, p.Size, WithAlpha(p.Col, Round(255 * f)));
          SetBlendAdd(False);
        end;
      PT_RING:
        Ring(p.X, p.Y, p.Size * (1.1 - f), p.Size * (1.1 - f) * 0.62, 5 * f + 1, WithAlpha(p.Col, Round(220 * f)));
      PT_FLASH:
        begin
          SetBlendAdd(True);
          FillEllipseGrad(p.X, p.Y, p.Size, p.Size * 0.65, WithAlpha(p.Col, Round(255 * f)), RGBA(0, 0, 0, 0));
          SetBlendAdd(False);
        end;
      PT_ARROW:
        ThickLine(p.X, p.Y, p.X + Cos(p.Rot) * 9, p.Y + Sin(p.Rot) * 9, 1.6,
          WithAlpha(p.Col, Round(255 * Min(1, f * 3))));
      PT_TEXT:
        DrawText(p.X, p.Y, p.Txt, WithAlpha(p.Col, Round(255 * Min(1, f * 2.5))), fnSmall, ALIGN_CENTER);
    end;
  end;
end;

{ ======================================================================
  enemies
  ====================================================================== }

function EnemyValid(i, id: Integer): Boolean; inline;
begin
  Result := (i >= 0) and (i < MAX_ENEMIES) and Enemies[i].Active and (Enemies[i].Id = id);
end;

procedure EnemyHitPos(const e: TEnemy; out x, y: Single);
begin
  x := e.X;
  y := e.Y - EnemyDefs[e.Kind].HitY;
end;

procedure UpdateEnemyPos(var e: TEnemy);
var
  px, py, dx, dy: Single;
begin
  PathPos(Paths[e.PathIdx], e.Dist, px, py, dx, dy);
  e.X := px - dy * e.Offset;
  e.Y := py + dx * e.Offset;
end;

procedure SpawnEnemy(ekind, epath: Integer);
var
  i: Integer;
  scale: Single;
  def: TEnemyDef;
begin
  if (ekind < 0) or (ekind > High(EnemyDefs)) then Exit;
  epath := EnsureRange(epath, 0, High(Paths));
  def := EnemyDefs[ekind];
  for i := 0 to MAX_ENEMIES - 1 do
    if not Enemies[i].Active then
    begin
      FillChar(Enemies[i], SizeOf(Enemies[i]), 0);
      scale := 1 + Rules.HpGrowth * (Wave - 1) + Rules.HpGrowthQuad * Sqr(Wave - 1);
      Enemies[i].Active := True;
      Enemies[i].Id := NextEnemyId;
      Enemies[i].Kind := ekind;
      Enemies[i].PathIdx := epath;
      Enemies[i].Dist := -RandF(10, 30);
      if def.Flying then Enemies[i].Offset := RandF(-20, 20)
      else Enemies[i].Offset := RandF(-13, 13);
      Enemies[i].MaxHp := def.Hp * scale;
      Enemies[i].Hp := Enemies[i].MaxHp;
      Enemies[i].Speed := def.Speed * RandF(0.92, 1.08);
      Enemies[i].Armor := def.Armor;
      Enemies[i].Dmg := def.Dmg * (1 + Rules.DmgGrowth * Wave);
      Enemies[i].Flying := def.Flying;
      Enemies[i].Blocker := -1;
      Enemies[i].Facing := 1;
      Enemies[i].Anim := RandF(0, 10);
      UpdateEnemyPos(Enemies[i]);
      Inc(NextEnemyId);
      Exit;
    end;
end;

procedure ReleaseBlockedBy(soldier: Integer);
var
  i: Integer;
begin
  for i := 0 to MAX_ENEMIES - 1 do
    if Enemies[i].Active and (Enemies[i].Blocker = soldier) then
      Enemies[i].Blocker := -1;
end;

procedure HeroKillXp(const e: TEnemy; gold: Integer); forward;

procedure KillEnemy(i: Integer);
var
  e: TEnemy;
  def: TEnemyDef;
  hx, hy: Single;
  reward: Integer;
begin
  e := Enemies[i];
  def := EnemyDefs[e.Kind];
  Enemies[i].Active := False;
  Inc(Kills);
  reward := def.Gold;
  Inc(Gold, reward);
  EnemyHitPos(e, hx, hy);
  FloatText(hx, hy - 18, '+' + IntToStr(reward), RGBA(255, 215, 60));
  PlaySoundIdx(EnemyDeathSnd[e.Kind], 0.9, 0.12);
  PlaySound(sndCoin, 0.7, 0.05);
  Burst(hx, hy, 10, def.DeathColor, 90, 0.5, 3, 300);
  Emit(PT_SMOKE, hx, hy, 0, -20, 0.6, 10, RGBA(200, 190, 180, 120));
  if def.ExplodeOnDeath then
  begin
    Explosion(e.X, e.Y - 10, 60);
    Shake := 8;
  end;
  HeroKillXp(e, def.Gold);
end;

procedure DamageEnemy(i: Integer; amount: Single; magic: Boolean);
begin
  if not Enemies[i].Active then Exit;
  if not magic then amount := amount * (1 - Enemies[i].Armor);
  Enemies[i].Hp := Enemies[i].Hp - amount;
  Enemies[i].Flash := 0.12;
  if Enemies[i].Hp <= 0 then KillEnemy(i);
end;

procedure SplashDamage(x, y, radius, amount: Single; hitAir: Boolean);
var
  i: Integer;
begin
  for i := 0 to MAX_ENEMIES - 1 do
    if Enemies[i].Active and (hitAir or not Enemies[i].Flying) then
      if Dist2(x, y, Enemies[i].X, Enemies[i].Y) <= Sqr(radius + EnemyDefs[Enemies[i].Kind].Radius) then
        DamageEnemy(i, amount, False);
end;

procedure SoldierHurt(s: Integer; amount: Single); forward;
function BlockerAlive(b: Integer): Boolean; forward;
function BlockerX(b: Integer): Single; forward;
procedure BlockerHurt(b: Integer; amount: Single); forward;
procedure HeroGainXp(xp: Integer); forward;

procedure UpdateEnemies(dt: Single);
var
  i, b: Integer;
  oldX: Single;
begin
  for i := 0 to MAX_ENEMIES - 1 do
  begin
    if not Enemies[i].Active then Continue;
    Enemies[i].Anim := Enemies[i].Anim + dt;
    if Enemies[i].Flash > 0 then Enemies[i].Flash := Enemies[i].Flash - dt;
    if Enemies[i].StunT > 0 then
    begin
      Enemies[i].StunT := Enemies[i].StunT - dt;
      Continue;
    end;
    b := Enemies[i].Blocker;
    if (b >= 0) and not BlockerAlive(b) then
    begin
      Enemies[i].Blocker := -1;
      b := -1;
    end;
    if b >= 0 then
    begin
      if BlockerX(b) < Enemies[i].X then Enemies[i].Facing := -1 else Enemies[i].Facing := 1;
      Enemies[i].AtkCd := Enemies[i].AtkCd - dt;
      if Enemies[i].AtkCd <= 0 then
      begin
        Enemies[i].AtkCd := 1.0;
        PlaySound(sndEnemyHit, 0.7, 0.15);
        BlockerHurt(b, Enemies[i].Dmg);
      end;
      Continue;
    end;
    oldX := Enemies[i].X;
    Enemies[i].Dist := Enemies[i].Dist + Enemies[i].Speed * dt;
    UpdateEnemyPos(Enemies[i]);
    if Enemies[i].X > oldX + 0.01 then Enemies[i].Facing := 1
    else if Enemies[i].X < oldX - 0.01 then Enemies[i].Facing := -1;
    if Enemies[i].Dist >= Paths[Enemies[i].PathIdx].Len then
    begin
      Enemies[i].Active := False;
      Dec(Lives, EnemyDefs[Enemies[i].Kind].LivesCost);
      HurtFlash := 0.5;
      Shake := Max(Shake, 3);
      PlaySound(sndLeak, 1.0, 0.03);
      if Lives <= 0 then
      begin
        Lives := 0;
        State := gsLost;
      end;
    end;
  end;
end;

{ ======================================================================
  soldiers
  ====================================================================== }

procedure SoldierHurt(s: Integer; amount: Single);
begin
  Soldiers[s].Hp := Soldiers[s].Hp - amount;
  Burst(Soldiers[s].X, Soldiers[s].Y - 12, 3, RGBA(170, 20, 20), 50, 0.4, 2, 250);
  if Soldiers[s].Hp <= 0 then
  begin
    Soldiers[s].Alive := False;
    Soldiers[s].Respawn := SoldierRules.Respawn;
    Soldiers[s].Target := -1;
    PlaySound(sndSoldierDie, 0.9, 0.1);
    Emit(PT_SMOKE, Soldiers[s].X, Soldiers[s].Y - 10, 0, -20, 0.7, 10, RGBA(200, 190, 180, 140));
    if Soldiers[s].Owner < 0 then Soldiers[s].Active := False;   // militia does not come back
    ReleaseBlockedBy(s);
  end;
end;

procedure SoldierGuardPos(s: Integer; out gx, gy: Single);
const
  FX: array[0..2] of Single = (-15, 15, 0);
  FY: array[0..2] of Single = (-8, -8, 10);
var
  o, sl: Integer;
  a: Single;
begin
  o := Soldiers[s].Owner;
  if o < 0 then
  begin
    gx := Soldiers[s].GuardX;
    gy := Soldiers[s].GuardY;
    Exit;
  end;
  sl := Soldiers[s].Slot;
  if sl <= 2 then
  begin
    gx := Plots[o].RallyX + FX[sl];
    gy := Plots[o].RallyY + FY[sl];
  end
  else
  begin
    a := sl * 2.1;
    gx := Plots[o].RallyX + Cos(a) * 20;
    gy := Plots[o].RallyY + Sin(a) * 12;
  end;
end;

procedure SetBarracksStats(p: Integer);
var
  s: Integer;
  st: TTowerLevel;
begin
  st := TStat(Plots[p].Kind, Plots[p].Level);
  for s := 0 to MAX_SOLDIERS - 1 do
    if Soldiers[s].Active and (Soldiers[s].Owner = p) then
    begin
      Soldiers[s].MaxHp := st.SoldierHp;
      Soldiers[s].Dmg := st.Damage;
      if Soldiers[s].Alive then Soldiers[s].Hp := st.SoldierHp;
    end;
end;

function AddSoldier(aOwner, aSlot: Integer; ax, ay, aHp, aDmg, aLife: Single): Integer;
var
  s: Integer;
begin
  for s := 0 to MAX_SOLDIERS - 1 do
    if not Soldiers[s].Active then
    begin
      FillChar(Soldiers[s], SizeOf(Soldiers[s]), 0);
      Soldiers[s].Active := True;
      Soldiers[s].Alive := True;
      Soldiers[s].Owner := aOwner;
      Soldiers[s].Slot := aSlot;
      Soldiers[s].X := ax;
      Soldiers[s].Y := ay;
      Soldiers[s].GuardX := ax;
      Soldiers[s].GuardY := ay;
      Soldiers[s].Hp := aHp;
      Soldiers[s].MaxHp := aHp;
      Soldiers[s].Dmg := aDmg;
      Soldiers[s].Target := -1;
      Soldiers[s].Facing := 1;
      Soldiers[s].Life := aLife;
      Soldiers[s].MaxLife := aLife;
      Exit(s);
    end;
  Result := -1;
end;

procedure UpdateSoldiers(dt: Single);
var
  s, i, best, t: Integer;
  gx, gy, tx, ty, d, bd, dx, dy, side: Single;
  bestFree: Boolean;
begin
  for s := 0 to MAX_SOLDIERS - 1 do
  begin
    if not Soldiers[s].Active then Continue;
    if Soldiers[s].Swing > 0 then Soldiers[s].Swing := Soldiers[s].Swing - dt;
    Soldiers[s].Moving := False;
    if not Soldiers[s].Alive then
    begin
      Soldiers[s].Respawn := Soldiers[s].Respawn - dt;
      if Soldiers[s].Respawn <= 0 then
      begin
        Soldiers[s].Alive := True;
        Soldiers[s].Hp := Soldiers[s].MaxHp;
        Soldiers[s].X := Plots[Soldiers[s].Owner].X;
        Soldiers[s].Y := Plots[Soldiers[s].Owner].Y + 6;
        PlaySound(sndSoldierSpawn, 0.6, 0.1);
      end;
      Continue;
    end;
    if Soldiers[s].Owner < 0 then
    begin
      Soldiers[s].Life := Soldiers[s].Life - dt;
      if Soldiers[s].Life <= 0 then
      begin
        Soldiers[s].Active := False;
        Emit(PT_SMOKE, Soldiers[s].X, Soldiers[s].Y - 10, 0, -20, 0.7, 10, RGBA(220, 210, 200, 140));
        ReleaseBlockedBy(s);
        Continue;
      end;
    end;
    SoldierGuardPos(s, gx, gy);

    // drop invalid / escaped targets
    t := Soldiers[s].Target;
    if t >= 0 then
      if (not EnemyValid(t, Soldiers[s].TargetId)) or Enemies[t].Flying or
        (Dist2(gx, gy, Enemies[t].X, Enemies[t].Y) > Sqr(SoldierRules.Leash)) then
      begin
        if Enemies[t].Blocker = s then Enemies[t].Blocker := -1;
        Soldiers[s].Target := -1;
      end;

    // pick a target: prefer enemies nobody is blocking yet
    if Soldiers[s].Target < 0 then
    begin
      best := -1;
      bd := 1e12;
      bestFree := False;
      for i := 0 to MAX_ENEMIES - 1 do
        if Enemies[i].Active and not Enemies[i].Flying and (Enemies[i].Dist > 0) then
        begin
          d := Dist2(gx, gy, Enemies[i].X, Enemies[i].Y);
          if d > Sqr(SoldierRules.Engage) then Continue;
          if (Enemies[i].Blocker < 0) and not bestFree then
          begin
            bestFree := True;
            bd := d;
            best := i;
          end
          else if ((Enemies[i].Blocker < 0) = bestFree) and (d < bd) then
          begin
            bd := d;
            best := i;
          end;
        end;
      if best >= 0 then
      begin
        Soldiers[s].Target := best;
        Soldiers[s].TargetId := Enemies[best].Id;
      end;
    end;

    t := Soldiers[s].Target;
    if t >= 0 then
    begin
      // stand beside the enemy, further out for big ones
      side := 8 + EnemyDefs[Enemies[t].Kind].Radius;
      if Soldiers[s].X < Enemies[t].X then tx := Enemies[t].X - side else tx := Enemies[t].X + side;
      ty := Enemies[t].Y;
    end
    else
    begin
      tx := gx;
      ty := gy;
    end;

    dx := tx - Soldiers[s].X;
    dy := ty - Soldiers[s].Y;
    d := Sqrt(dx * dx + dy * dy);
    if d > 2 then
    begin
      Soldiers[s].X := Soldiers[s].X + dx / d * Min(d, SoldierRules.Walk * dt);
      Soldiers[s].Y := Soldiers[s].Y + dy / d * Min(d, SoldierRules.Walk * dt);
      Soldiers[s].Anim := Soldiers[s].Anim + dt;
      Soldiers[s].Moving := True;
      if dx > 0.5 then Soldiers[s].Facing := 1 else if dx < -0.5 then Soldiers[s].Facing := -1;
    end;

    if t >= 0 then
    begin
      if Enemies[t].X > Soldiers[s].X then Soldiers[s].Facing := 1 else Soldiers[s].Facing := -1;
      if d < 8 then
      begin
        if Enemies[t].Blocker < 0 then Enemies[t].Blocker := s;
        Soldiers[s].AtkCd := Soldiers[s].AtkCd - dt;
        if Soldiers[s].AtkCd <= 0 then
        begin
          Soldiers[s].AtkCd := SoldierRules.AttackRate;
          Soldiers[s].Swing := 0.25;
          PlaySword;
          DamageEnemy(t, Soldiers[s].Dmg, False);
        end;
      end;
    end
    else if Soldiers[s].Hp < Soldiers[s].MaxHp then
      Soldiers[s].Hp := Min(Soldiers[s].MaxHp, Soldiers[s].Hp + Soldiers[s].MaxHp * SoldierRules.RegenFrac * dt);
  end;
end;

{ ======================================================================
  hero
  ====================================================================== }

function NewProj: Integer; forward;

function HeroActive: Boolean;
begin
  Result := Hero.Enabled and (Length(Hero.Levels) > 0);
end;

function HeroLvl: THeroLevel;
begin
  Result := Hero.Levels[EnsureRange(HeroU.Level - 1, 0, High(Hero.Levels))];
end;

function AbilityDamage(const a: THeroAbility): Single;
begin
  Result := a.Damage + (HeroU.Level - 1) * a.DamagePerLevel;
end;

procedure ResetHero;
begin
  FillChar(HeroU, SizeOf(HeroU), 0);
  HeroU.Level := 1;
  HeroU.Target := -1;
  HeroU.Facing := 1;
  HeroU.Alive := HeroActive;
  HeroU.X := HeroSpawnX;
  HeroU.Y := HeroSpawnY;
  if HeroActive then
  begin
    HeroU.MaxHp := HeroLvl.Hp;
    HeroU.Hp := HeroU.MaxHp;
  end;
end;

function BlockerAlive(b: Integer): Boolean;
begin
  if b = HERO_BLOCK then Result := HeroU.Alive
  else Result := (b >= 0) and (b < MAX_SOLDIERS) and Soldiers[b].Active and Soldiers[b].Alive;
end;

function BlockerX(b: Integer): Single;
begin
  if b = HERO_BLOCK then Result := HeroU.X else Result := Soldiers[b].X;
end;

procedure HeroReleaseTarget;
var
  t: Integer;
begin
  t := HeroU.Target;
  if (t >= 0) and (t < MAX_ENEMIES) and (Enemies[t].Blocker = HERO_BLOCK) then Enemies[t].Blocker := -1;
  HeroU.Target := -1;
end;

procedure HeroHurt(amount: Single);
begin
  if not HeroU.Alive then Exit;
  HeroU.Hp := HeroU.Hp - amount * (1 - HeroLvl.Armor);
  Burst(HeroU.X, HeroU.Y - 16, 3, RGBA(170, 20, 20), 50, 0.4, 2, 250);
  if HeroU.Hp > 0 then Exit;
  HeroU.Alive := False;
  HeroU.Selected := False;
  HeroU.Ordered := False;
  HeroU.Respawn := Hero.Respawn;
  HeroU.Target := -1;
  ReleaseBlockedBy(HERO_BLOCK);
  PlaySound(sndHeroDie, 1.0, 0.03);
  Emit(PT_SMOKE, HeroU.X, HeroU.Y - 14, 0, -20, 1.0, 16, RGBA(200, 190, 180, 160));
  FloatText(HeroU.X, HeroU.Y - 50, Hero.Name + ' has fallen!', RGBA(255, 120, 100));
end;

procedure BlockerHurt(b: Integer; amount: Single);
begin
  if b = HERO_BLOCK then HeroHurt(amount) else SoldierHurt(b, amount);
end;

procedure HeroGainXp(xp: Integer);
begin
  if not HeroActive or (xp <= 0) then Exit;
  Inc(HeroU.Xp, xp);
  while (HeroU.Level < Length(Hero.Levels)) and (HeroU.Xp >= Hero.Levels[HeroU.Level].Xp) do
  begin
    Inc(HeroU.Level);
    HeroU.MaxHp := HeroLvl.Hp;
    if HeroU.Alive then HeroU.Hp := HeroU.MaxHp;
    if not HeroQuietXp then
    begin
      HeroU.LevelFlash := 1.5;
      FloatText(HeroU.X, HeroU.Y - 60, Format('%s reached level %d!', [Hero.Name, HeroU.Level]), RGBA(255, 230, 120));
      PlaySound(sndHeroLevel, 1.0, 0);
      Burst(HeroU.X, HeroU.Y - 20, 30, RGBA(255, 220, 110), 140, 0.9, 3, 120);
    end;
  end;
end;

// xp for every kill: full when the hero (or his hammer / slam) landed the blow, half when nearby
procedure HeroKillXp(const e: TEnemy; gold: Integer);
begin
  if not HeroActive or not HeroU.Alive then Exit;
  if HeroHitting then HeroGainXp(Round(gold * Hero.XpPerGold))
  else if Dist2(e.X, e.Y, HeroU.X, HeroU.Y) < Sqr(220) then HeroGainXp(Round(gold * Hero.XpPerGold * 0.5));
end;

procedure HeroStrike(i: Integer; amount: Single; magic: Boolean);
begin
  HeroHitting := True;
  DamageEnemy(i, amount, magic);
  HeroHitting := False;
end;

procedure SelectHero(on: Boolean);
begin
  if not HeroActive or not HeroU.Alive then on := False;
  HeroU.Selected := on;
  if on then
  begin
    SelPlot := -1;
    RallyMode := False;
    SpellMode := SP_NONE;
    PlaySound(sndClick, 1.0, 0.05);
  end;
end;

procedure HeroOrder(x, y: Single);
begin
  HeroU.TX := EnsureRange(x, 20, SCR_W - 20);
  HeroU.TY := EnsureRange(y, 40, SCR_H - 20);
  HeroU.Ordered := True;
  HeroReleaseTarget;
  Emit(PT_RING, HeroU.TX, HeroU.TY, 0, 0, 0.45, 26, RGBA(120, 255, 140));
  PlaySound(sndRallyHorn, 0.35, 0.1);
end;

procedure CastSlam;
var
  i: Integer;
  r, dmg: Single;
begin
  if not HeroActive or not HeroU.Alive or (State <> gsPlaying) or Paused then Exit;
  if HeroU.SlamCd > 0 then
  begin
    FloatText(HeroU.X, HeroU.Y - 54, Format('%s: %ds', [Hero.Slam.Name, Ceil(HeroU.SlamCd)]), RGBA(200, 200, 200));
    Exit;
  end;
  r := Hero.Slam.Radius;
  dmg := AbilityDamage(Hero.Slam);
  for i := 0 to MAX_ENEMIES - 1 do
    if Enemies[i].Active and not Enemies[i].Flying and
      (Sqr(Enemies[i].X - HeroU.X) + Sqr((Enemies[i].Y - HeroU.Y) / 0.72) <= Sqr(r)) then
    begin
      HeroStrike(i, dmg, False);
      if Enemies[i].Active then Enemies[i].StunT := Max(Enemies[i].StunT, Hero.Slam.Stun);
    end;
  Emit(PT_FLASH, HeroU.X, HeroU.Y, 0, 0, 0.2, r, RGBA(255, 230, 170));
  Emit(PT_RING, HeroU.X, HeroU.Y, 0, 0, 0.45, r * 1.1, RGBA(255, 220, 150));
  Emit(PT_RING, HeroU.X, HeroU.Y, 0, 0, 0.3, r * 0.6, RGBA(255, 240, 200));
  for i := 1 to 26 do
    Emit(PT_SMOKE, HeroU.X + RandF(-r, r) * 0.7, HeroU.Y + RandF(-r, r) * 0.45, RandF(-30, 30), RandF(-50, -10),
      RandF(0.5, 1.0), RandF(6, 12), RGBA(150, 110, 70, 170));
  Burst(HeroU.X, HeroU.Y, 16, RGBA(120, 90, 60), 160, 0.6, 3, 400);
  Shake := Max(Shake, 7);
  PlaySoundIdx(Hero.Slam.SoundIdx, 1.0, 0.05);
  HeroU.Swing := 0.25;
  HeroU.SlamCd := Hero.Slam.Cooldown;
end;

procedure CastHammer;
var
  i, t, j: Integer;
  best, d: Single;
begin
  if not HeroActive or not HeroU.Alive or (State <> gsPlaying) or Paused then Exit;
  if HeroU.HammerCd > 0 then
  begin
    FloatText(HeroU.X, HeroU.Y - 54, Format('%s: %ds', [Hero.Hammer.Name, Ceil(HeroU.HammerCd)]), RGBA(200, 200, 200));
    Exit;
  end;
  // toughest enemy in range (flyers too)
  t := -1;
  best := 0;
  for i := 0 to MAX_ENEMIES - 1 do
    if Enemies[i].Active and (Enemies[i].Dist > 0) and
      (Dist2(HeroU.X, HeroU.Y, Enemies[i].X, Enemies[i].Y) <= Sqr(Hero.Hammer.Radius)) and (Enemies[i].Hp > best) then
    begin
      best := Enemies[i].Hp;
      t := i;
    end;
  if t < 0 then
  begin
    FloatText(HeroU.X, HeroU.Y - 54, 'No target in range', RGBA(200, 200, 200));
    Exit;
  end;
  j := NewProj;
  if j < 0 then Exit;
  Projs[j].Kind := PK_HAMMER;
  Projs[j].Geo := Hero.Hammer.GeoIdx;
  Projs[j].FromHero := True;
  Projs[j].Target := t;
  Projs[j].TargetId := Enemies[t].Id;
  Projs[j].SX := HeroU.X;
  Projs[j].SY := HeroU.Y - 22;
  Projs[j].X := Projs[j].SX; Projs[j].Y := Projs[j].SY;
  Projs[j].PX := Projs[j].SX; Projs[j].PY := Projs[j].SY;
  EnemyHitPos(Enemies[t], Projs[j].TX, Projs[j].TY);
  d := Sqrt(Dist2(Projs[j].SX, Projs[j].SY, Projs[j].TX, Projs[j].TY));
  Projs[j].Dur := Max(0.2, d / 420);
  Projs[j].ArcH := d * 0.12;
  Projs[j].Dmg := AbilityDamage(Hero.Hammer);
  Projs[j].Splash := Hero.Hammer.Splash;
  if Enemies[t].X < HeroU.X then HeroU.Facing := -1 else HeroU.Facing := 1;
  HeroU.Swing := 0.25;
  PlaySoundIdx(Hero.Hammer.SoundIdx, 1.0, 0.05);
  HeroU.HammerCd := Hero.Hammer.Cooldown;
end;

procedure UpdateHero(dt: Single);
var
  i, best, t: Integer;
  dx, dy, d, bd, tx, ty, side: Single;
  bestFree: Boolean;
begin
  if not HeroActive then Exit;
  if HeroU.SlamCd > 0 then HeroU.SlamCd := Max(0, HeroU.SlamCd - dt);
  if HeroU.HammerCd > 0 then HeroU.HammerCd := Max(0, HeroU.HammerCd - dt);
  if HeroU.LevelFlash > 0 then HeroU.LevelFlash := HeroU.LevelFlash - dt;
  if HeroU.Swing > 0 then HeroU.Swing := HeroU.Swing - dt;
  HeroU.Moving := False;
  if not HeroU.Alive then
  begin
    HeroU.Respawn := HeroU.Respawn - dt;
    if HeroU.Respawn <= 0 then
    begin
      HeroU.Alive := True;
      HeroU.MaxHp := HeroLvl.Hp;
      HeroU.Hp := HeroU.MaxHp;
      HeroU.X := HeroSpawnX;
      HeroU.Y := HeroSpawnY;
      HeroU.Target := -1;
      PlaySound(sndSoldierSpawn, 1.0, 0);
      Burst(HeroU.X, HeroU.Y - 20, 20, RGBA(255, 240, 200), 100, 0.7, 3);
    end;
    Exit;
  end;

  // walking to a move order: ignores enemies on the way
  if HeroU.Ordered then
  begin
    dx := HeroU.TX - HeroU.X;
    dy := HeroU.TY - HeroU.Y;
    d := Sqrt(dx * dx + dy * dy);
    if d <= Hero.Speed * dt then
    begin
      HeroU.X := HeroU.TX;
      HeroU.Y := HeroU.TY;
      HeroU.Ordered := False;
    end
    else
    begin
      HeroU.X := HeroU.X + dx / d * Hero.Speed * dt;
      HeroU.Y := HeroU.Y + dy / d * Hero.Speed * dt;
      HeroU.Moving := True;
      HeroU.Anim := HeroU.Anim + dt;
      if dx > 0.5 then HeroU.Facing := 1 else if dx < -0.5 then HeroU.Facing := -1;
    end;
    Exit;
  end;

  // keep or drop the current opponent
  t := HeroU.Target;
  if t >= 0 then
    if not EnemyValid(t, HeroU.TargetId) or Enemies[t].Flying or
      (Dist2(HeroU.X, HeroU.Y, Enemies[t].X, Enemies[t].Y) > Sqr(Hero.Engage * 1.6)) then
      HeroReleaseTarget;

  // pick a new opponent near where he stands (prefers enemies nobody blocks)
  if HeroU.Target < 0 then
  begin
    best := -1;
    bd := 1e12;
    bestFree := False;
    for i := 0 to MAX_ENEMIES - 1 do
      if Enemies[i].Active and not Enemies[i].Flying and (Enemies[i].Dist > 0) then
      begin
        d := Dist2(HeroU.X, HeroU.Y, Enemies[i].X, Enemies[i].Y);
        if d > Sqr(Hero.Engage) then Continue;
        if (Enemies[i].Blocker < 0) and not bestFree then
        begin
          bestFree := True;
          bd := d;
          best := i;
        end
        else if ((Enemies[i].Blocker < 0) = bestFree) and (d < bd) then
        begin
          bd := d;
          best := i;
        end;
      end;
    if best >= 0 then
    begin
      HeroU.Target := best;
      HeroU.TargetId := Enemies[best].Id;
    end;
  end;

  t := HeroU.Target;
  if t < 0 then
  begin
    HeroU.Hp := Min(HeroU.MaxHp, HeroU.Hp + HeroU.MaxHp * Hero.Regen * dt);
    Exit;
  end;
  side := 10 + EnemyDefs[Enemies[t].Kind].Radius;
  if HeroU.X < Enemies[t].X then tx := Enemies[t].X - side else tx := Enemies[t].X + side;
  ty := Enemies[t].Y;
  dx := tx - HeroU.X;
  dy := ty - HeroU.Y;
  d := Sqrt(dx * dx + dy * dy);
  if d > 2 then
  begin
    HeroU.X := HeroU.X + dx / d * Min(d, Hero.Speed * dt);
    HeroU.Y := HeroU.Y + dy / d * Min(d, Hero.Speed * dt);
    HeroU.Moving := True;
    HeroU.Anim := HeroU.Anim + dt;
  end;
  if Enemies[t].X > HeroU.X then HeroU.Facing := 1 else HeroU.Facing := -1;
  if d < 8 then
  begin
    if Enemies[t].Blocker < 0 then Enemies[t].Blocker := HERO_BLOCK;
    HeroU.AtkCd := HeroU.AtkCd - dt;
    if HeroU.AtkCd <= 0 then
    begin
      HeroU.AtkCd := HeroLvl.Rate;
      HeroU.Swing := 0.25;
      PlaySword;
      HeroStrike(t, HeroLvl.Damage, False);
    end;
  end;
end;

{ ======================================================================
  towers & projectiles
  ====================================================================== }

function NewProj: Integer;
var
  i: Integer;
begin
  for i := 0 to MAX_PROJ - 1 do
    if not Projs[i].Active then
    begin
      FillChar(Projs[i], SizeOf(Projs[i]), 0);
      Projs[i].Active := True;
      Projs[i].Target := -1;
      Projs[i].HitSnd := -1;
      Projs[i].FromHero := False;
      Exit(i);
    end;
  Result := -1;
end;

// the enemy closest to the exit that is in range
function FindTarget(x, y, range: Single; hitAir: Boolean): Integer;
var
  i: Integer;
  best, rem: Single;
begin
  Result := -1;
  best := 1e12;
  for i := 0 to MAX_ENEMIES - 1 do
    if Enemies[i].Active and (Enemies[i].Dist > 0) and (hitAir or not Enemies[i].Flying) then
      if Dist2(x, y, Enemies[i].X, Enemies[i].Y) <= range * range then
      begin
        rem := Paths[Enemies[i].PathIdx].Len - Enemies[i].Dist;
        if rem < best then
        begin
          best := rem;
          Result := i;
        end;
      end;
end;

procedure UpdateTowers(dt: Single);
var
  p, t, j, tk: Integer;
  st: TTowerLevel;
  def: TTowerDef;
  mx, my, hx, hy, d, lx, ly, ldx, ldy, dd: Single;
begin
  for p := 0 to NPlots - 1 do
  begin
    tk := Plots[p].Kind;
    if tk < 0 then Continue;
    Plots[p].SinceFire := Plots[p].SinceFire + dt;
    def := TowerDefs[tk];
    if def.Behavior = TB_BARRACKS then Continue;
    st := TStat(tk, Plots[p].Level);
    if Plots[p].Cooldown > 0 then Plots[p].Cooldown := Plots[p].Cooldown - dt;
    t := FindTarget(Plots[p].X, Plots[p].Y, st.Range, def.HitsAir);
    if t < 0 then Continue;
    Plots[p].Aim := ArcTan2(Enemies[t].Y - Plots[p].Y, Enemies[t].X - Plots[p].X);
    if Plots[p].Cooldown > 0 then Continue;
    Plots[p].Cooldown := st.Rate;
    Plots[p].SinceFire := 0;
    mx := Plots[p].X;
    my := Plots[p].Y - def.MuzzleY;
    j := NewProj;
    if j < 0 then Continue;
    EnemyHitPos(Enemies[t], hx, hy);
    d := Sqrt(Dist2(mx, my, hx, hy));
    Projs[j].SX := mx; Projs[j].SY := my;
    Projs[j].X := mx; Projs[j].Y := my;
    Projs[j].PX := mx; Projs[j].PY := my;
    Projs[j].TX := hx; Projs[j].TY := hy;
    Projs[j].Target := t;
    Projs[j].TargetId := Enemies[t].Id;
    Projs[j].Dmg := st.Damage;
    Projs[j].Geo := def.ProjGeoIdx;
    Projs[j].Magic := def.Magic;
    Projs[j].HitsAir := def.HitsAir;
    Projs[j].HitSnd := TowerHitSnd[tk];
    PlaySoundIdx(TowerFireSnd[tk], 0.8, 0.1);
    case def.Behavior of
      TB_ARROW:
        begin
          Projs[j].Kind := PK_ARROW;
          Projs[j].Dur := Max(0.18, d / Max(1, def.ProjSpeed));
          Projs[j].ArcH := d * def.ProjArc;
          Projs[j].Dmg := st.Damage * RandF(0.8, 1.2);
        end;
      TB_BOLT:
        begin
          Projs[j].Kind := PK_BOLT;
          Projs[j].Dur := Max(0.15, d / Max(1, def.ProjSpeed));
          Projs[j].ArcH := d * def.ProjArc;
        end;
      TB_BOMB:
        begin
          Projs[j].Kind := PK_BOMB;
          Projs[j].Dur := def.ProjTime;
          Projs[j].ArcH := def.ProjArc;
          Projs[j].Splash := st.Splash;
          Projs[j].Target := -1;   // shells are not homing: lead the target instead
          dd := Enemies[t].Dist;
          if Enemies[t].Blocker < 0 then dd := dd + Enemies[t].Speed * Projs[j].Dur;
          PathPos(Paths[Enemies[t].PathIdx], Min(dd, Paths[Enemies[t].PathIdx].Len), lx, ly, ldx, ldy);
          Projs[j].TX := lx - ldy * Enemies[t].Offset;
          Projs[j].TY := ly + ldx * Enemies[t].Offset;
          Emit(PT_SMOKE, mx, my, RandF(-10, 10), -30, 0.6, 8, RGBA(90, 85, 80, 160));
        end;
    end;
  end;
end;

procedure UpdateProjectiles(dt: Single);
var
  i, k: Integer;
  f, hx, hy: Single;
  p: ^TProj;
begin
  for i := 0 to MAX_PROJ - 1 do
  begin
    p := @Projs[i];
    if not p^.Active then Continue;
    p^.T := p^.T + dt;
    if p^.T < 0 then Continue;   // delayed (meteor shower)
    if (p^.Kind = PK_METEOR) and (p^.T - dt < 0) then PlaySound(sndMeteorFall, 0.8, 0.1);
    if (p^.Target >= 0) and EnemyValid(p^.Target, p^.TargetId) then
    begin
      EnemyHitPos(Enemies[p^.Target], hx, hy);
      p^.TX := hx;
      p^.TY := hy;
    end;
    f := Clamp01(p^.T / p^.Dur);
    p^.PX := p^.X;
    p^.PY := p^.Y;
    p^.X := p^.SX + (p^.TX - p^.SX) * f;
    p^.Y := p^.SY + (p^.TY - p^.SY) * f - p^.ArcH * 4 * f * (1 - f);
    case p^.Kind of
      PK_BOLT: Emit(PT_DOT, p^.X, p^.Y, RandF(-15, 15), RandF(-15, 15), 0.3, 3, RGBA(200, 120, 255, 200));
      PK_METEOR:
        begin
          Emit(PT_SMOKE, p^.X, p^.Y, RandF(-10, 10), RandF(-10, 10), 0.5, 7, RGBA(80, 60, 50, 150));
          Emit(PT_SPARK, p^.X, p^.Y, RandF(-40, 40), RandF(-80, 0), 0.3, 3, RGBA(255, 160, 40), 0);
        end;
      PK_BOMB:
        if Random(3) = 0 then Emit(PT_SMOKE, p^.X, p^.Y, 0, 0, 0.4, 4, RGBA(120, 110, 100, 120));
    end;
    if f < 1 then Continue;
    p^.Active := False;
    case p^.Kind of
      PK_ARROW, PK_BOLT:
        if EnemyValid(p^.Target, p^.TargetId) then
        begin
          PlaySoundIdx(p^.HitSnd, 0.6, 0.15);
          DamageEnemy(p^.Target, p^.Dmg, p^.Magic);
          if p^.Kind = PK_BOLT then Burst(p^.X, p^.Y, 8, RGBA(210, 140, 255), 90, 0.35, 3)
          else Burst(p^.X, p^.Y, 2, RGBA(150, 20, 20), 40, 0.3, 2, 200);
        end
        else if p^.Kind = PK_ARROW then
        begin
          // missed: the arrow sticks in the ground for a moment
          k := NewParticle;
          if k >= 0 then
          begin
            Parts[k].Kind := PT_ARROW;
            Parts[k].X := p^.X; Parts[k].Y := p^.Y;
            Parts[k].Life := 1.2; Parts[k].MaxLife := 1.2;
            Parts[k].Col := RGBA(90, 60, 30);
            Parts[k].Rot := ArcTan2(p^.Y - p^.PY, p^.X - p^.PX) + Pi;
          end;
        end;
      PK_HAMMER:
        begin
          PlaySound(sndEnemyHit, 1.0, 0.05);
          PlaySound(sndSword2, 0.7, 0.05);
          Burst(p^.X, p^.Y, 14, RGBA(140, 210, 255), 120, 0.4, 3);
          Emit(PT_RING, p^.X, p^.Y + 10, 0, 0, 0.3, p^.Splash + 10, RGBA(140, 210, 255));
          HeroHitting := True;
          if EnemyValid(p^.Target, p^.TargetId) then DamageEnemy(p^.Target, p^.Dmg, False);
          SplashDamage(p^.X, p^.Y + 10, p^.Splash, p^.Dmg * 0.4, True);
          HeroHitting := False;
          Shake := Max(Shake, 3);
        end;
      PK_BOMB, PK_METEOR:
        begin
          PlaySoundIdx(p^.HitSnd, 1.0, 0.12);
          Explosion(p^.TX, p^.TY, p^.Splash);
          SplashDamage(p^.TX, p^.TY, p^.Splash, p^.Dmg, p^.Kind = PK_METEOR);
        end;
    end;
  end;
end;

{ ======================================================================
  waves
  ====================================================================== }

procedure SortSpawns;
var
  i, j: Integer;
  t: TSpawn;
begin
  for i := 1 to NSpawns - 1 do
  begin
    t := Spawns[i];
    j := i - 1;
    while (j >= 0) and (Spawns[j].T > t.T) do
    begin
      Spawns[j + 1] := Spawns[j];
      Dec(j);
    end;
    Spawns[j + 1] := t;
  end;
end;

procedure BuildWave(w: Integer);
var
  g, i: Integer;
  grp: TWaveGroup;
begin
  NSpawns := 0;
  SpawnPos := 0;
  WaveTime := 0;
  if (w < 1) or (w > TotalWaves) then Exit;
  for g := 0 to High(Waves[w - 1].Groups) do
  begin
    grp := Waves[w - 1].Groups[g];
    for i := 0 to grp.Count - 1 do
      if NSpawns < MAX_SPAWNS then
      begin
        Spawns[NSpawns].T := grp.Start + i * grp.Interval;
        Spawns[NSpawns].Kind := grp.Enemy;
        Spawns[NSpawns].Path := grp.Path;
        Inc(NSpawns);
      end;
  end;
  SortSpawns;
end;

procedure SaveCheckpoint; forward;

procedure StartNextWave;
var
  bonus: Integer;
begin
  if (State <> gsPlaying) or WaveSpawning or (Wave >= TotalWaves) then Exit;
  if NextWaveTimer > 0 then
  begin
    bonus := Round(NextWaveTimer * Rules.EarlyBonusPerSec);
    if bonus > 0 then
    begin
      Inc(Gold, bonus);
      FloatText(640, 120, 'Early call bonus +' + IntToStr(bonus), RGBA(255, 215, 60));
    end;
    FireCd := Max(0, FireCd - NextWaveTimer * Rules.EarlyCooldownCut);
    ReinfCd := Max(0, ReinfCd - NextWaveTimer * Rules.EarlyCooldownCut);
  end;
  SaveCheckpoint;
  Inc(Wave);
  BuildWave(Wave);
  WaveSpawning := True;
  NextWaveTimer := 0;
  BannerText := 'Wave ' + IntToStr(Wave);
  if Wave = TotalWaves then BannerText := 'Final Wave!';
  BannerTime := 2.2;
  PlaySound(sndHorn, 1.0, 0);
end;

function AnyEnemyAlive: Boolean;
var
  i: Integer;
begin
  for i := 0 to MAX_ENEMIES - 1 do
    if Enemies[i].Active then Exit(True);
  Result := False;
end;

// does the next wave come through entrance p? (decides which skulls are shown)
function NextWaveUsesPath(p: Integer): Boolean;
var
  g: Integer;
begin
  Result := False;
  if Wave >= TotalWaves then Exit;
  for g := 0 to High(Waves[Wave].Groups) do
    if Waves[Wave].Groups[g].Path = p then Exit(True);
end;

procedure UpdateWaves(dt: Single);
begin
  if WaveSpawning then
  begin
    WaveTime := WaveTime + dt;
    while (SpawnPos < NSpawns) and (Spawns[SpawnPos].T <= WaveTime) do
    begin
      SpawnEnemy(Spawns[SpawnPos].Kind, Spawns[SpawnPos].Path);
      Inc(SpawnPos);
    end;
    if SpawnPos >= NSpawns then
    begin
      WaveSpawning := False;
      if Wave < TotalWaves then NextWaveTimer := Rules.WaveGap;
    end;
  end
  else if NextWaveTimer > 0 then
  begin
    NextWaveTimer := NextWaveTimer - dt;
    if NextWaveTimer <= 0 then
    begin
      NextWaveTimer := 0;
      StartNextWave;
    end;
  end;
  if (Wave >= TotalWaves) and not WaveSpawning and not AnyEnemyAlive and (State = gsPlaying) then
    State := gsWon;
end;

{ ======================================================================
  building
  ====================================================================== }

procedure RemoveBarracksSoldiers(p: Integer);
var
  s: Integer;
begin
  for s := 0 to MAX_SOLDIERS - 1 do
    if Soldiers[s].Active and (Soldiers[s].Owner = p) then
    begin
      Soldiers[s].Active := False;
      ReleaseBlockedBy(s);
    end;
end;

procedure BuildTower(p, kind: Integer);
var
  cost, s: Integer;
  st: TTowerLevel;
  dummy: Single;
begin
  st := TStat(kind, 1);
  cost := st.Cost;
  if (Plots[p].Kind >= 0) or (Gold < cost) then Exit;
  Dec(Gold, cost);
  Plots[p].Kind := kind;
  Plots[p].Level := 1;
  Plots[p].Cooldown := 0.3;
  Plots[p].Aim := Pi / 2;
  Plots[p].SinceFire := 99;
  Plots[p].Spent := cost;
  if TowerDefs[kind].Behavior = TB_BARRACKS then
  begin
    NearestPathPoint(Plots[p].X, Plots[p].Y, Plots[p].RallyX, Plots[p].RallyY, dummy);
    for s := 0 to TowerDefs[kind].Soldiers - 1 do
      AddSoldier(p, s, Plots[p].X + (s - 1) * 10, Plots[p].Y + 6, st.SoldierHp, st.Damage, 0);
  end;
  PlaySound(sndBuild, 0.9, 0.05);
  Emit(PT_SMOKE, Plots[p].X - 20, Plots[p].Y, -20, -20, 0.8, 16, RGBA(200, 180, 150, 170));
  Emit(PT_SMOKE, Plots[p].X + 20, Plots[p].Y, 20, -20, 0.8, 16, RGBA(200, 180, 150, 170));
  Emit(PT_SMOKE, Plots[p].X, Plots[p].Y - 20, 0, -30, 0.8, 18, RGBA(200, 180, 150, 170));
end;

procedure UpgradeTower(p: Integer);
var
  cost: Integer;
begin
  if (Plots[p].Kind < 0) or (Plots[p].Level >= MaxLevel(Plots[p].Kind)) then Exit;
  cost := TStat(Plots[p].Kind, Plots[p].Level + 1).Cost;
  if Gold < cost then Exit;
  Dec(Gold, cost);
  Inc(Plots[p].Spent, cost);
  Inc(Plots[p].Level);
  Burst(Plots[p].X, Plots[p].Y - 30, 20, RGBA(255, 230, 120), 120, 0.7, 3, 150);
  PlaySound(sndUpgrade, 0.9, 0);
  if IsBarracks(p) then SetBarracksStats(p);
end;

function SellValue(p: Integer): Integer;
begin
  Result := Round(Plots[p].Spent * Rules.SellRatio);
end;

procedure SellTower(p: Integer);
var
  refund: Integer;
begin
  if Plots[p].Kind < 0 then Exit;
  refund := SellValue(p);
  Inc(Gold, refund);
  FloatText(Plots[p].X, Plots[p].Y - 50, '+' + IntToStr(refund), RGBA(255, 215, 60));
  PlaySound(sndSell, 0.9, 0.03);
  if IsBarracks(p) then RemoveBarracksSoldiers(p);
  Plots[p].Kind := -1;
  Plots[p].Level := 0;
  Emit(PT_SMOKE, Plots[p].X, Plots[p].Y - 10, 0, -30, 0.9, 22, RGBA(200, 180, 150, 170));
end;

{ ======================================================================
  spells
  ====================================================================== }

function FireDamage: Single;
begin
  Result := FireSpell.DmgBase + Wave * FireSpell.DmgPerWave;
end;

procedure CastFire(cx, cy: Single);
var
  i, j: Integer;
begin
  for i := 0 to FireSpell.Meteors - 1 do
  begin
    j := NewProj;
    if j < 0 then Break;
    Projs[j].Kind := PK_METEOR;
    Projs[j].Geo := FireSpell.GeoIdx;
    Projs[j].HitSnd := Ord(sndExplosion);
    Projs[j].TX := cx + RandF(-FireSpell.SpreadX, FireSpell.SpreadX);
    Projs[j].TY := cy + RandF(-FireSpell.SpreadY, FireSpell.SpreadY);
    Projs[j].SX := Projs[j].TX + 260;
    Projs[j].SY := Projs[j].TY - 760;
    Projs[j].X := Projs[j].SX; Projs[j].Y := Projs[j].SY;
    Projs[j].PX := Projs[j].SX; Projs[j].PY := Projs[j].SY;
    Projs[j].T := -i * FireSpell.Delay;
    Projs[j].Dur := FireSpell.FallTime;
    Projs[j].Dmg := FireDamage;
    Projs[j].Splash := FireSpell.Splash;
  end;
  FireCd := FireSpell.Cooldown;
  SpellMode := SP_NONE;
  PlaySound(sndMeteorCast, 1.0, 0.05);
end;

procedure CastReinforce(x, y: Single);
var
  i: Integer;
  hp, dmg: Single;
begin
  hp := Reinf.HpBase + Wave * Reinf.HpPerWave;
  dmg := Reinf.DmgBase + Wave * Reinf.DmgPerWave;
  for i := 0 to Reinf.Count - 1 do
    AddSoldier(-1, i, x + (i - (Reinf.Count - 1) / 2) * 24, y + (i mod 2) * 4, hp, dmg, Reinf.Lifetime);
  Emit(PT_RING, x, y, 0, 0, 0.4, 40, RGBA(255, 255, 220));
  Burst(x, y - 10, 14, RGBA(255, 250, 200), 80, 0.6, 3);
  ReinfCd := Reinf.Cooldown;
  SpellMode := SP_NONE;
  PlaySound(sndRallyHorn, 0.9, 0.03);
  PlaySound(sndSoldierSpawn, 0.8, 0.05);
end;

{ ======================================================================
  reset / data loading
  ====================================================================== }

// --wave n: skip ahead; give the gold the skipped waves would have paid out
procedure ApplyStartWave;
var
  w, g: Integer;
begin
  if (StartWaveArg <= 1) or (TotalWaves = 0) then Exit;
  Wave := Min(StartWaveArg, TotalWaves) - 1;
  for w := 0 to Wave - 1 do
    for g := 0 to High(Waves[w].Groups) do
      Inc(Gold, Waves[w].Groups[g].Count * EnemyDefs[Waves[w].Groups[g].Enemy].Gold);
  // the hero would have earned roughly a third of the kills' xp by now
  HeroQuietXp := True;
  HeroGainXp(Round((Gold - Rules.StartGold) * Hero.XpPerGold * 0.35));
  HeroQuietXp := False;
  BannerText := Format('Play test: starting at wave %d', [Wave + 1]);
end;

procedure ResetGame;
var
  i: Integer;
begin
  FillChar(Enemies, SizeOf(Enemies), 0);
  FillChar(Soldiers, SizeOf(Soldiers), 0);
  FillChar(Projs, SizeOf(Projs), 0);
  for i := 0 to MAX_PARTICLES - 1 do Parts[i].Active := False;
  for i := 0 to NPlots - 1 do
  begin
    Plots[i].Kind := -1;
    Plots[i].Level := 0;
  end;
  Randomize;
  State := gsPlaying;
  Paused := False;
  Gold := Rules.StartGold;
  Lives := Rules.StartLives;
  Wave := 0;
  NextWaveTimer := -1;
  WaveSpawning := False;
  NSpawns := 0;
  NextEnemyId := 1;
  Kills := 0;
  SelPlot := -1;
  RallyMode := False;
  SpellMode := SP_NONE;
  FireCd := 0;
  ReinfCd := 0;
  Shake := 0;
  HurtFlash := 0;
  BannerText := 'Defend the ' + Map.Name + '!';
  BannerTime := 3;
  ResetHero;
  ApplyStartWave;
end;

function LoadAll(out err: string): Boolean;
begin
  Result := LoadGameData(ExtractFilePath(ParamStr(0)) + 'data', MapName, err);
  if not Result then Exit;
  InitWorld;
  SortDecorByY;
  RenderBackground;
end;

{ ======================================================================
  drawing: world
  ====================================================================== }

procedure DrawHpBar(x, y, w, frac: Single);
begin
  if frac >= 0.999 then Exit;
  FillRect(x - w / 2 - 1, y - 1, w + 2, 5, RGBA(20, 10, 5, 220));
  FillRect(x - w / 2, y, w, 3, RGBA(150, 20, 20));
  FillRect(x - w / 2, y, w * Clamp01(frac), 3, RGBA(90, 220, 60));
end;

procedure DrawPlot(p: Integer);
var
  hover: Boolean;
  st: TAnimState;
  k: Integer;
begin
  hover := (Dist2(MouseX, MouseY, Plots[p].X, Plots[p].Y) < Sqr(36)) and (SpellMode = SP_NONE) and not RallyMode;
  st := MakeState;
  st.Seed := p;
  k := Plots[p].Kind;
  if k < 0 then
  begin
    DrawGeoIdx(Geo, GeoPlotEmpty, Plots[p].X, Plots[p].Y, 1, st);
    if hover or (SelPlot = p) then Ring(Plots[p].X, Plots[p].Y, 38, 23, 3, RGBA(255, 240, 180, 200));
    Exit;
  end;
  DrawGeoIdx(Geo, GeoPlotBuilt, Plots[p].X, Plots[p].Y, 1, st);
  if hover or (SelPlot = p) then Ring(Plots[p].X, Plots[p].Y + 2, 38, 22, 3, RGBA(255, 240, 180, 200));
  st.Level := Plots[p].Level;
  st.Aim := Plots[p].Aim;
  st.SinceFire := Plots[p].SinceFire;
  DrawGeoIdx(Geo, TowerDefs[k].GeoIdx, Plots[p].X, Plots[p].Y, 1, st);
  for k := 2 to Plots[p].Level do
    FillCircle(Plots[p].X + (k - 2) * 12 - (Plots[p].Level - 2) * 6, Plots[p].Y + 14, 3, RGBA(255, 210, 60));
end;

procedure DrawEnemy(i: Integer);
var
  e: TEnemy;
  def: TEnemyDef;
  st: TAnimState;
  k: Integer;
begin
  e := Enemies[i];
  def := EnemyDefs[e.Kind];
  st := MakeState;
  st.Walk := e.Anim;
  st.Moving := (e.Blocker < 0) and (e.StunT <= 0);
  st.Facing := e.Facing;
  st.Seed := e.Id mod 97;
  DrawGeoIdx(Geo, def.GeoIdx, e.X, e.Y, 1, st);
  if e.Flash > 0 then
  begin
    SetBlendAdd(True);
    FillEllipse(e.X, e.Y - def.HitY, def.Radius, def.Radius * 1.1, RGBA(255, 255, 255, 120));
    SetBlendAdd(False);
  end;
  DrawHpBar(e.X, e.Y - def.BarY, def.BarW, e.Hp / e.MaxHp);
  if e.StunT > 0 then
    for k := 0 to 2 do
      FillCircle(e.X + Cos(GameTime * 6 + k * 2.09) * 10, e.Y - def.BarY + 8 + Sin(GameTime * 6 + k * 2.09) * 3, 2.4,
        RGBA(255, 240, 120));
end;

procedure DrawSoldier(s: Integer);
var
  st: TAnimState;
  g: Integer;
  frac: Single;
begin
  st := MakeState;
  st.Walk := Soldiers[s].Anim;
  st.Moving := Soldiers[s].Moving;
  st.Facing := Soldiers[s].Facing;
  st.Swing := Soldiers[s].Swing;
  st.Seed := s;
  if Soldiers[s].Owner >= 0 then g := SoldierRules.GeoIdx else g := Reinf.GeoIdx;
  DrawGeoIdx(Geo, g, Soldiers[s].X, Soldiers[s].Y, 1, st);
  frac := Soldiers[s].Hp / Soldiers[s].MaxHp;
  if (Soldiers[s].Owner < 0) and (Soldiers[s].MaxLife > 0) and (Soldiers[s].Life < Soldiers[s].MaxLife - 0.1) then
    frac := Min(frac, Soldiers[s].Life / Soldiers[s].MaxLife);
  DrawHpBar(Soldiers[s].X, Soldiers[s].Y - 34, 16, frac);
end;

procedure DrawProjectiles;
var
  i: Integer;
  f, gx, gy, r: Single;
  st: TAnimState;
begin
  st := MakeState;
  for i := 0 to MAX_PROJ - 1 do
  begin
    if not Projs[i].Active or (Projs[i].T < 0) then Continue;
    f := Clamp01(Projs[i].T / Projs[i].Dur);
    st.Aim := ArcTan2(Projs[i].Y - Projs[i].PY, Projs[i].X - Projs[i].PX);
    st.Seed := i;
    if Projs[i].Kind = PK_BOMB then
    begin
      gx := Projs[i].SX + (Projs[i].TX - Projs[i].SX) * f;
      gy := Projs[i].SY + (Projs[i].TY - Projs[i].SY) * f;
      FillEllipse(gx, gy, 6, 2.5, RGBA(0, 0, 0, 70));
    end
    else if Projs[i].Kind = PK_METEOR then
    begin
      r := 10 + 30 * f;
      FillEllipse(Projs[i].TX, Projs[i].TY, r, r * 0.5, RGBA(0, 0, 0, Round(90 * f)));
    end;
    DrawGeoIdx(Geo, Projs[i].Geo, Projs[i].X, Projs[i].Y, 1, st);
  end;
end;

procedure DrawAnimatedDecor;
var
  i: Integer;
  st: TAnimState;
begin
  st := MakeState;
  for i := 0 to High(Map.Decor) do
  begin
    st.Seed := i * 1.7;
    DrawGeoIdx(Geo, Map.Decor[i].GeoIdx, Map.Decor[i].X, Map.Decor[i].Y, Map.Decor[i].S, st, dmDynamic);
  end;
end;

procedure SortDrawList(n: Integer);
var
  i, j: Integer;
  t: TDrawItem;
begin
  for i := 1 to n - 1 do
  begin
    t := DrawList[i];
    j := i - 1;
    while (j >= 0) and (DrawList[j].Y > t.Y) do
    begin
      DrawList[j + 1] := DrawList[j];
      Dec(j);
    end;
    DrawList[j + 1] := t;
  end;
end;

procedure DrawHero;
var
  st: TAnimState;
  x, y, a: Single;
begin
  if not HeroU.Alive then
  begin
    // gravestone with the respawn countdown
    x := HeroSpawnX;
    y := HeroSpawnY;
    FillEllipse(x, y + 1, 12, 4, RGBA(0, 0, 0, 80));
    RoundRect(x - 9, y - 24, 18, 25, 7, RGBA(120, 116, 112));
    RoundRect(x - 7, y - 22, 14, 21, 6, RGBA(150, 146, 140));
    FillRect(x - 1, y - 19, 2, 10, RGBA(90, 86, 82));
    FillRect(x - 4, y - 16, 8, 2, RGBA(90, 86, 82));
    DrawText(x, y - 46, IntToStr(Ceil(HeroU.Respawn)), RGBA(255, 230, 180), fnMedium, ALIGN_CENTER);
    Exit;
  end;
  x := HeroU.X;
  y := HeroU.Y;
  if HeroU.Selected then
  begin
    a := 0.5 + 0.5 * Sin(GameTime * 6);
    Ring(x, y, 20, 8, 2.5, RGBA(120, 255, 140, Round(150 + 100 * a)));
    Ring(x, y, Hero.Engage, Hero.Engage * 0.72, 1.5, RGBA(120, 255, 140, 70));
  end;
  if HeroU.Ordered then
  begin
    Ring(HeroU.TX, HeroU.TY, 12, 6, 2, RGBA(120, 255, 140, 160));
    ThickLine(HeroU.TX, HeroU.TY, HeroU.TX, HeroU.TY - 18, 2, RGBA(200, 180, 140));
    FillTri(HeroU.TX, HeroU.TY - 18, HeroU.TX, HeroU.TY - 10, HeroU.TX + 10, HeroU.TY - 14, RGBA(120, 255, 140));
  end;
  st := MakeState;
  st.Walk := HeroU.Anim;
  st.Moving := HeroU.Moving;
  st.Facing := HeroU.Facing;
  st.Swing := HeroU.Swing;
  st.Level := HeroU.Level;
  DrawGeoIdx(Geo, Hero.GeoIdx, x, y, 1, st);
  if HeroU.LevelFlash > 0 then
  begin
    SetBlendAdd(True);
    FillEllipseGrad(x, y - 18, 34, 40, RGBA(255, 220, 120, Round(160 * Clamp01(HeroU.LevelFlash))), RGBA(0, 0, 0, 0));
    SetBlendAdd(False);
  end;
  DrawHpBar(x, y - 52, 28, HeroU.Hp / Max(1, HeroU.MaxHp));
  FillCircle(x + 19, y - 50, 7, RGBA(40, 26, 14));
  FillCircle(x + 19, y - 50, 6, RGBA(220, 180, 70));
  DrawText(x + 19, y - 58, IntToStr(HeroU.Level), RGBA(60, 30, 10), fnSmall, ALIGN_CENTER, False);
end;

procedure DrawWorld;
var
  i, n: Integer;
  dst: TSDL_FRect;

  procedure AddItem(y: Single; kind, idx: Integer);
  begin
    DrawList[n].Y := y;
    DrawList[n].Kind := kind;
    DrawList[n].Idx := idx;
    Inc(n);
  end;

begin
  dst.x := OfsX; dst.y := OfsY; dst.w := SCR_W; dst.h := SCR_H;
  SDL_RenderTexture(Renderer, BgTex, nil, @dst);
  DrawAnimatedDecor;
  n := 0;
  for i := 0 to NPlots - 1 do AddItem(Plots[i].Y, 0, i);
  for i := 0 to MAX_ENEMIES - 1 do
    if Enemies[i].Active and not Enemies[i].Flying then AddItem(Enemies[i].Y, 1, i);
  for i := 0 to MAX_SOLDIERS - 1 do
    if Soldiers[i].Active and Soldiers[i].Alive then AddItem(Soldiers[i].Y, 2, i);
  if HeroActive then
    if HeroU.Alive then AddItem(HeroU.Y, 3, 0) else AddItem(HeroSpawnY, 3, 0);
  SortDrawList(n);
  for i := 0 to n - 1 do
    case DrawList[i].Kind of
      0: DrawPlot(DrawList[i].Idx);
      1: DrawEnemy(DrawList[i].Idx);
      2: DrawSoldier(DrawList[i].Idx);
      3: DrawHero;
    end;
  // flyers always above ground units
  for i := 0 to MAX_ENEMIES - 1 do
    if Enemies[i].Active and Enemies[i].Flying then DrawEnemy(i);
  DrawProjectiles;
  DrawParticles(False);
end;

{ ======================================================================
  UI
  ====================================================================== }

const
  BTN_R = 24;
  MENU_R = 70;
  SPELL_X1 = 60;
  SPELL_X2 = 140;
  SPELL_Y = 664;
  SPELL_R = 32;
  HERO_X = 232;
  HAB1_X = 306;
  HAB2_X = 370;
  HAB_R = 26;
  MUTE_X = 1135;
  SPEED_X = 1190;
  PAUSE_X = 1245;
  TOPBTN_Y = 36;

// build-menu button positions: towers are spread around a ring
procedure MenuPos(i: Integer; cx, cy: Single; out bx, by: Single);
var
  a: Single;
begin
  a := DegToRad(-135 + i * 360 / Max(1, Length(TowerDefs)));
  bx := cx + Cos(a) * MENU_R;
  by := cy + Sin(a) * MENU_R;
end;

function SkullVisible: Boolean;
begin
  Result := (State = gsPlaying) and not WaveSpawning and (Wave < TotalWaves) and (NextWaveTimer <> 0);
end;

procedure DrawCoin(x, y, r: Single);
begin
  FillCircle(x, y + 1, r, RGBA(150, 100, 20));
  FillCircle(x, y, r, RGBA(250, 200, 50));
  FillCircle(x - r * 0.25, y - r * 0.25, r * 0.45, RGBA(255, 240, 150));
end;

procedure DrawHeart(x, y, r: Single);
begin
  FillCircle(x - r * 0.5, y - r * 0.2, r * 0.6, RGBA(220, 40, 50));
  FillCircle(x + r * 0.5, y - r * 0.2, r * 0.6, RGBA(220, 40, 50));
  FillTri(x - r * 1.08, y, x + r * 1.08, y, x, y + r * 1.1, RGBA(220, 40, 50));
  FillCircle(x - r * 0.55, y - r * 0.35, r * 0.2, RGBA(255, 180, 180));
end;

procedure DrawSkullIcon(x, y, r: Single; const c: TRGBA);
begin
  FillCircle(x, y - r * 0.15, r * 0.75, c);
  FillRect(x - r * 0.4, y + r * 0.3, r * 0.8, r * 0.4, c);
  FillCircle(x - r * 0.3, y - r * 0.15, r * 0.22, RGBA(30, 20, 20));
  FillCircle(x + r * 0.3, y - r * 0.15, r * 0.22, RGBA(30, 20, 20));
  FillTri(x, y + r * 0.05, x - r * 0.1, y + r * 0.25, x + r * 0.1, y + r * 0.25, RGBA(30, 20, 20));
end;

procedure Panel(x, y, w, h: Single);
begin
  RoundRect(x + 2, y + 3, w, h, 10, RGBA(0, 0, 0, 90));
  RoundRect(x, y, w, h, 10, RGBA(70, 46, 28, 235));
  RoundRect(x + 3, y + 3, w - 6, h - 6, 8, RGBA(42, 28, 18, 235));
end;

procedure RoundButton(x, y, r: Single; hover, enabled: Boolean);
var
  base: TRGBA;
begin
  if enabled then base := RGBA(92, 64, 40) else base := RGBA(70, 62, 56);
  if hover and enabled then base := Shade(base, 1.3);
  FillCircle(x + 1, y + 3, r + 2, RGBA(0, 0, 0, 100));
  FillCircle(x, y, r + 2, RGBA(40, 26, 14));
  FillEllipseGrad(x, y, r, r, Shade(base, 1.25), Shade(base, 0.8));
  Ring(x, y, r, r, 2.5, RGBA(200, 160, 80));
end;

procedure PriceTag(x, y: Single; cost: Integer; afford: Boolean);
var
  s: string;
  w: Single;
  c: TRGBA;
begin
  s := IntToStr(cost);
  w := TextWidth(s, fnSmall) + 22;
  RoundRect(x - w / 2, y - 9, w, 18, 8, RGBA(30, 20, 12, 230));
  DrawCoin(x - w / 2 + 9, y, 5);
  if afford then c := RGBA(255, 220, 90) else c := RGBA(160, 140, 130);
  DrawText(x - w / 2 + 17, y - 9, s, c, fnSmall, ALIGN_LEFT, False);
end;

procedure DrawRangeCircle(x, y, r: Single; const c: TRGBA);
begin
  FillEllipse(x, y, r, r * 0.72, WithAlpha(c, 40));
  Ring(x, y, r, r * 0.72, 2, WithAlpha(c, 170));
end;

procedure Tooltip(x, y: Single; const title, line1, line2: string);
var
  w, h: Single;
begin
  w := Max(TextWidth(title, fnMedium), Max(TextWidth(line1), TextWidth(line2))) + 24;
  h := 30 + 18 * (Ord(line1 <> '') + Ord(line2 <> ''));
  x := EnsureRange(x - w / 2, 6, SCR_W - w - 6);
  y := EnsureRange(y, 6, SCR_H - h - 6);
  Panel(x, y, w, h);
  DrawText(x + 12, y + 5, title, RGBA(255, 225, 140), fnMedium);
  if line1 <> '' then DrawText(x + 12, y + 30, line1, RGBA(235, 225, 210));
  if line2 <> '' then DrawText(x + 12, y + 48, line2, RGBA(180, 220, 160));
end;

function StatLine(kind, lvl: Integer): string;
var
  st: TTowerLevel;
begin
  st := TStat(kind, lvl);
  case TowerDefs[kind].Behavior of
    TB_BARRACKS:
      Result := Format('Soldiers: %d   HP %d   Dmg %d', [TowerDefs[kind].Soldiers, Round(st.SoldierHp), Round(st.Damage)]);
    TB_BOMB:
      Result := Format('Dmg %d (area %d)   Range %d   Every %.1fs', [Round(st.Damage), Round(st.Splash), Round(st.Range), st.Rate]);
  else
    Result := Format('Dmg %d   Range %d   Every %.2fs', [Round(st.Damage), Round(st.Range), st.Rate]);
  end;
end;

procedure DrawUpgradeIcon(x, y: Single);
begin
  FillTri(x - 10, y + 2, x + 10, y + 2, x, y - 11, RGBA(120, 230, 90));
  FillRect(x - 4, y + 1, 8, 9, RGBA(120, 230, 90));
end;

procedure DrawSellIcon(x, y: Single);
begin
  DrawCoin(x, y, 11);
  DrawText(x, y - 10, '$', RGBA(150, 100, 20), fnSmall, ALIGN_CENTER, False);
end;

procedure DrawFlagIcon(x, y: Single);
begin
  ThickLine(x - 6, y + 11, x - 6, y - 11, 2.5, RGBA(200, 180, 140));
  FillTri(x - 5, y - 11, x - 5, y - 1, x + 10, y - 6, RGBA(60, 110, 220));
end;

procedure DrawSelectionMenu;
var
  i, cost, k, lvl: Integer;
  bx, by, cx, cy, px, py: Single;
  hover, afford: Boolean;
  st: TAnimState;
begin
  if SelPlot < 0 then Exit;
  px := Plots[SelPlot].X;
  py := Plots[SelPlot].Y;
  cx := px;
  cy := py - 20;
  k := Plots[SelPlot].Kind;
  st := MakeState;
  if k < 0 then
  begin
    Ring(cx, cy, MENU_R, MENU_R, 3, RGBA(240, 210, 140, 150));
    for i := 0 to High(TowerDefs) do
    begin
      MenuPos(i, cx, cy, bx, by);
      hover := Dist2(MouseX, MouseY, bx, by) < Sqr(BTN_R);
      cost := TStat(i, 1).Cost;
      afford := Gold >= cost;
      if hover then DrawRangeCircle(px, py, TStat(i, 1).Range, RGBA(255, 255, 255));
      RoundButton(bx, by, BTN_R, hover, afford);
      st.Aim := -Pi / 4;
      DrawGeoIdx(Geo, TowerDefs[i].GeoIdx, bx, by + 14, 0.42, st);
      PriceTag(bx, by + BTN_R + 4, cost, afford);
    end;
    for i := 0 to High(TowerDefs) do
    begin
      MenuPos(i, cx, cy, bx, by);
      if Dist2(MouseX, MouseY, bx, by) < Sqr(BTN_R) then
        Tooltip(cx, cy + 100, TowerDefs[i].Name, TowerDefs[i].Desc, StatLine(i, 1));
    end;
    Exit;
  end;

  lvl := Plots[SelPlot].Level;
  DrawRangeCircle(px, py, TStat(k, lvl).Range, RGBA(255, 255, 255));
  if IsBarracks(SelPlot) then
  begin
    FillCircle(Plots[SelPlot].RallyX, Plots[SelPlot].RallyY, 5, RGBA(80, 140, 255));
    Ring(Plots[SelPlot].RallyX, Plots[SelPlot].RallyY, 14, 9, 2, RGBA(80, 140, 255, 200));
  end;
  if lvl < MaxLevel(k) then
  begin
    bx := cx; by := cy - 58;
    cost := TStat(k, lvl + 1).Cost;
    hover := Dist2(MouseX, MouseY, bx, by) < Sqr(BTN_R);
    if hover then DrawRangeCircle(px, py, TStat(k, lvl + 1).Range, RGBA(120, 255, 120));
    RoundButton(bx, by, BTN_R, hover, Gold >= cost);
    DrawUpgradeIcon(bx, by);
    PriceTag(bx, by - BTN_R - 6, cost, Gold >= cost);
  end;
  bx := cx; by := cy + 64;
  hover := Dist2(MouseX, MouseY, bx, by) < Sqr(BTN_R);
  RoundButton(bx, by, BTN_R, hover, True);
  DrawSellIcon(bx, by);
  PriceTag(bx, by + BTN_R + 6, SellValue(SelPlot), True);
  if IsBarracks(SelPlot) then
  begin
    bx := cx - 62; by := cy + 10;
    hover := Dist2(MouseX, MouseY, bx, by) < Sqr(BTN_R);
    RoundButton(bx, by, BTN_R, hover, True);
    DrawFlagIcon(bx, by);
  end;
  if (lvl < MaxLevel(k)) and (Dist2(MouseX, MouseY, cx, cy - 58) < Sqr(BTN_R)) then
    Tooltip(cx, cy + 110, 'Upgrade to level ' + IntToStr(lvl + 1), StatLine(k, lvl + 1), '')
  else if Dist2(MouseX, MouseY, cx, cy + 64) < Sqr(BTN_R) then
    Tooltip(cx, cy - 150, 'Sell tower', 'Refund: ' + IntToStr(SellValue(SelPlot)) + ' gold', '')
  else if IsBarracks(SelPlot) and (Dist2(MouseX, MouseY, cx - 62, cy + 10) < Sqr(BTN_R)) then
    Tooltip(cx, cy + 110, 'Rally point', 'Click on the road to move your soldiers.', '');
end;

procedure DrawInfoBar;
var
  k: Integer;
begin
  if (SelPlot < 0) or (Plots[SelPlot].Kind < 0) then Exit;
  k := Plots[SelPlot].Kind;
  Panel(440, SCR_H - 58, 400, 50);
  DrawText(640, SCR_H - 55, TowerDefs[k].Name + '  -  Level ' + IntToStr(Plots[SelPlot].Level),
    RGBA(255, 225, 140), fnMedium, ALIGN_CENTER);
  DrawText(640, SCR_H - 31, StatLine(k, Plots[SelPlot].Level), RGBA(225, 215, 200), fnSmall, ALIGN_CENTER);
end;

procedure DrawSpellButton(x, y: Single; spell: Integer; cd, maxCd: Single; const key: string);
var
  hover: Boolean;
  i: Integer;
begin
  hover := Dist2(MouseX, MouseY, x, y) < Sqr(SPELL_R);
  RoundButton(x, y, SPELL_R, hover, True);
  if spell = SP_FIRE then
  begin
    for i := 0 to 2 do
      ThickLine(x + 4 + i * 3, y - 6 - i * 3, x + 16 + i * 2, y - 18 - i * 2, 5 - i, RGBA(255, 150 + i * 30, 40, 200));
    FillCircle(x - 2, y + 4, 11, RGBA(255, 140, 30));
    FillCircle(x - 2, y + 4, 7, RGBA(255, 230, 120));
    FillCircle(x - 4, y + 6, 4, RGBA(140, 60, 30));
  end
  else
  begin
    ThickLine(x - 12, y + 12, x + 12, y - 12, 4, RGBA(220, 225, 235));
    ThickLine(x + 12, y + 12, x - 12, y - 12, 4, RGBA(220, 225, 235));
    ThickLine(x - 14, y + 6, x - 6, y + 14, 4, RGBA(200, 160, 60));
    ThickLine(x + 14, y + 6, x + 6, y + 14, 4, RGBA(200, 160, 60));
  end;
  if cd > 0 then
  begin
    FillPie(x, y, SPELL_R, -Pi / 2, -Pi / 2 + 2 * Pi * (cd / Max(0.01, maxCd)), RGBA(0, 0, 0, 160));
    DrawText(x, y - 10, IntToStr(Ceil(cd)), RGBA(255, 255, 255), fnMedium, ALIGN_CENTER);
  end
  else
    Ring(x, y, SPELL_R + 3, SPELL_R + 3, 2, RGBA(255, 220, 120, Round(120 + 100 * Sin(GameTime * 4))));
  if SpellMode = spell then Ring(x, y, SPELL_R + 6, SPELL_R + 6, 4, RGBA(255, 240, 120));
  RoundRect(x + SPELL_R - 16, y + SPELL_R - 16, 18, 18, 5, RGBA(30, 20, 12, 230));
  DrawText(x + SPELL_R - 7, y + SPELL_R - 16, key, RGBA(255, 230, 160), fnSmall, ALIGN_CENTER, False);
end;

procedure DrawTopButtons;
var
  hover: Boolean;
  s: string;
begin
  hover := Dist2(MouseX, MouseY, MUTE_X, TOPBTN_Y) < Sqr(22);
  RoundButton(MUTE_X, TOPBTN_Y, 22, hover, True);
  FillRect(MUTE_X - 10, TOPBTN_Y - 5, 6, 10, RGBA(255, 230, 160));
  FillQuad(MUTE_X - 5, TOPBTN_Y - 5, MUTE_X + 3, TOPBTN_Y - 12, MUTE_X + 3, TOPBTN_Y + 12, MUTE_X - 5, TOPBTN_Y + 5,
    RGBA(255, 230, 160));
  if SoundMuted then
    ThickLine(MUTE_X - 13, TOPBTN_Y + 13, MUTE_X + 13, TOPBTN_Y - 13, 3, RGBA(230, 60, 50))
  else
  begin
    ThickLine(MUTE_X + 7, TOPBTN_Y - 5, MUTE_X + 9, TOPBTN_Y, 2, RGBA(255, 230, 160));
    ThickLine(MUTE_X + 9, TOPBTN_Y, MUTE_X + 7, TOPBTN_Y + 5, 2, RGBA(255, 230, 160));
  end;
  hover := Dist2(MouseX, MouseY, SPEED_X, TOPBTN_Y) < Sqr(22);
  RoundButton(SPEED_X, TOPBTN_Y, 22, hover, True);
  if Speed2x then s := 'x2' else s := 'x1';
  DrawText(SPEED_X, TOPBTN_Y - 13, s, RGBA(255, 230, 160), fnMedium, ALIGN_CENTER, False);
  hover := Dist2(MouseX, MouseY, PAUSE_X, TOPBTN_Y) < Sqr(22);
  RoundButton(PAUSE_X, TOPBTN_Y, 22, hover, True);
  if Paused then
    FillTri(PAUSE_X - 6, TOPBTN_Y - 10, PAUSE_X - 6, TOPBTN_Y + 10, PAUSE_X + 10, TOPBTN_Y, RGBA(255, 230, 160))
  else
  begin
    FillRect(PAUSE_X - 8, TOPBTN_Y - 9, 6, 18, RGBA(255, 230, 160));
    FillRect(PAUSE_X + 2, TOPBTN_Y - 9, 6, 18, RGBA(255, 230, 160));
  end;
end;

procedure DrawAbilityButton(x: Single; isSlam: Boolean; cd, maxCd: Single; const key: string);
var
  hover, ready: Boolean;
  y: Single;
  st: TAnimState;
  i: Integer;
begin
  y := SPELL_Y;
  hover := Dist2(MouseX, MouseY, x, y) < Sqr(HAB_R);
  ready := HeroU.Alive and (cd <= 0);
  RoundButton(x, y, HAB_R, hover, HeroU.Alive);
  if isSlam then
  begin
    // cracked ground
    FillEllipse(x, y + 7, 15, 5, RGBA(120, 85, 55));
    for i := 0 to 4 do
      ThickLine(x, y + 7, x + Cos(Pi + i * Pi / 4) * 14, y + 7 + Sin(Pi + i * Pi / 4) * 9, 2, RGBA(255, 220, 140));
    FillRect(x - 3, y - 14, 6, 12, RGBA(125, 130, 145));
    FillRect(x - 1, y - 18, 2, 22, RGBA(120, 80, 45));
  end
  else
  begin
    st := MakeState;
    st.Time := 0;
    DrawGeoIdx(Geo, Hero.Hammer.GeoIdx, x, y, 1.3, st);
  end;
  if not HeroU.Alive then
    FillCircle(x, y, HAB_R, RGBA(0, 0, 0, 150))
  else if cd > 0 then
  begin
    FillPie(x, y, HAB_R, -Pi / 2, -Pi / 2 + 2 * Pi * (cd / Max(0.01, maxCd)), RGBA(0, 0, 0, 160));
    DrawText(x, y - 10, IntToStr(Ceil(cd)), RGBA(255, 255, 255), fnMedium, ALIGN_CENTER);
  end
  else if ready then
    Ring(x, y, HAB_R + 3, HAB_R + 3, 2, RGBA(140, 210, 255, Round(120 + 100 * Sin(GameTime * 4))));
  RoundRect(x + HAB_R - 14, y + HAB_R - 14, 16, 16, 5, RGBA(30, 20, 12, 230));
  DrawText(x + HAB_R - 6, y + HAB_R - 14, key, RGBA(255, 230, 160), fnSmall, ALIGN_CENTER, False);
end;

procedure DrawHeroHud;
var
  hover: Boolean;
  st: TAnimState;
  x, y, f: Single;
  nextXp, curXp: Integer;
  clip: TSDL_Rect;
begin
  if not HeroActive then Exit;
  x := HERO_X;
  y := SPELL_Y;
  hover := Dist2(MouseX, MouseY, x, y) < Sqr(SPELL_R);
  RoundButton(x, y, SPELL_R, hover, True);
  if HeroU.Selected then Ring(x, y, SPELL_R + 6, SPELL_R + 6, 4, RGBA(120, 255, 140));
  clip.x := Round(x - SPELL_R + 3);
  clip.y := Round(y - SPELL_R + 3);
  clip.w := Round(SPELL_R * 2 - 6);
  clip.h := clip.w;
  SDL_SetRenderClipRect(Renderer, @clip);
  st := MakeState;
  st.Level := HeroU.Level;
  st.Swing := HeroU.Swing;
  DrawGeoIdx(Geo, Hero.GeoIdx, x - 2, y + 26, 1.25, st);
  SDL_SetRenderClipRect(Renderer, nil);
  if not HeroU.Alive then
  begin
    FillCircle(x, y, SPELL_R, RGBA(0, 0, 0, 160));
    DrawText(x, y - 12, IntToStr(Ceil(HeroU.Respawn)), RGBA(255, 200, 180), fnMedium, ALIGN_CENTER);
  end;
  // hp + xp bars below the portrait
  f := HeroU.Hp / Max(1, HeroU.MaxHp);
  if not HeroU.Alive then f := 0;
  FillRect(x - 30, y + SPELL_R + 4, 60, 6, RGBA(20, 10, 5, 220));
  FillRect(x - 29, y + SPELL_R + 5, 58 * f, 4, RGBA(90, 220, 60));
  curXp := Hero.Levels[HeroU.Level - 1].Xp;
  if HeroU.Level < Length(Hero.Levels) then nextXp := Hero.Levels[HeroU.Level].Xp else nextXp := curXp;
  FillRect(x - 30, y + SPELL_R + 11, 60, 4, RGBA(20, 10, 5, 220));
  if nextXp > curXp then
    FillRect(x - 29, y + SPELL_R + 12, 58 * Clamp01((HeroU.Xp - curXp) / (nextXp - curXp)), 2, RGBA(110, 180, 255))
  else
    FillRect(x - 29, y + SPELL_R + 12, 58, 2, RGBA(255, 210, 80));
  // level badge
  FillCircle(x + 24, y - 24, 11, RGBA(40, 26, 14));
  FillCircle(x + 24, y - 24, 9.5, RGBA(220, 180, 70));
  DrawText(x + 24, y - 33, IntToStr(HeroU.Level), RGBA(60, 30, 10), fnSmall, ALIGN_CENTER, False);
  DrawText(x - 22, y + SPELL_R - 12, 'H', RGBA(255, 230, 160), fnSmall, ALIGN_CENTER, True);

  DrawAbilityButton(HAB1_X, True, HeroU.SlamCd, Hero.Slam.Cooldown, '3');
  DrawAbilityButton(HAB2_X, False, HeroU.HammerCd, Hero.Hammer.Cooldown, '4');

  if hover then
  begin
    if HeroU.Level < Length(Hero.Levels) then
      Tooltip(330, 540, Format('%s - level %d', [Hero.Name, HeroU.Level]),
        Format('HP %d/%d   damage %d   armor %d%%   xp %d/%d', [Round(HeroU.Hp), Round(HeroU.MaxHp),
          Round(HeroLvl.Damage), Round(HeroLvl.Armor * 100), HeroU.Xp, nextXp]),
        'Click (or H), then click on the map to move him')
    else
      Tooltip(330, 540, Format('%s - level %d (max)', [Hero.Name, HeroU.Level]),
        Format('HP %d/%d   damage %d   armor %d%%', [Round(HeroU.Hp), Round(HeroU.MaxHp), Round(HeroLvl.Damage),
          Round(HeroLvl.Armor * 100)]), 'Click (or H), then click on the map to move him');
  end
  else if Dist2(MouseX, MouseY, HAB1_X, SPELL_Y) < Sqr(HAB_R) then
    Tooltip(330, 540, Hero.Slam.Name + '  [3]', Hero.Slam.Desc,
      Format('Damage %d in radius %d, stun %ss   Cooldown %ds', [Round(AbilityDamage(Hero.Slam)),
        Round(Hero.Slam.Radius), FormatFloat('0.#', Hero.Slam.Stun), Round(Hero.Slam.Cooldown)]))
  else if Dist2(MouseX, MouseY, HAB2_X, SPELL_Y) < Sqr(HAB_R) then
    Tooltip(330, 540, Hero.Hammer.Name + '  [4]', Hero.Hammer.Desc,
      Format('Damage %d, range %d   Cooldown %ds', [Round(AbilityDamage(Hero.Hammer)), Round(Hero.Hammer.Radius),
        Round(Hero.Hammer.Cooldown)]));
end;

procedure DrawHud;
var
  i: Integer;
  x, y, r, a, range: Single;
  hover: Boolean;
begin
  Panel(12, 10, 352, 48);
  DrawHeart(38, 33, 11);
  DrawText(56, 21, IntToStr(Lives), RGBA(255, 255, 255), fnMedium);
  DrawCoin(118, 34, 11);
  DrawText(136, 21, IntToStr(Gold), RGBA(255, 220, 90), fnMedium);
  DrawSkullIcon(222, 34, 13, RGBA(230, 220, 200));
  DrawText(240, 21, Format('Wave %d/%d', [Wave, TotalWaves]), RGBA(255, 255, 255), fnMedium);
  DrawTopButtons;

  DrawSpellButton(SPELL_X1, SPELL_Y, SP_FIRE, FireCd, FireSpell.Cooldown, '1');
  DrawSpellButton(SPELL_X2, SPELL_Y, SP_REINF, ReinfCd, Reinf.Cooldown, '2');
  DrawHeroHud;
  if Dist2(MouseX, MouseY, SPELL_X1, SPELL_Y) < Sqr(SPELL_R) then
    Tooltip(150, 540, FireSpell.Name + '  [1]', FireSpell.Desc,
      Format('Damage %d x %d   Cooldown %ds', [Round(FireDamage), FireSpell.Meteors, Round(FireSpell.Cooldown)]))
  else if Dist2(MouseX, MouseY, SPELL_X2, SPELL_Y) < Sqr(SPELL_R) then
    Tooltip(150, 540, Reinf.Name + '  [2]', Reinf.Desc,
      Format('%d militia, %ds   Cooldown %ds', [Reinf.Count, Round(Reinf.Lifetime), Round(Reinf.Cooldown)]));

  // call-wave skulls at the entrances the next wave uses
  if SkullVisible then
    for i := 0 to High(Map.Paths) do
      if NextWaveUsesPath(i) then
      begin
        x := Map.Paths[i].EntranceX;
        y := Map.Paths[i].EntranceY;
        r := 22 + Sin(GameTime * 5) * 2;
        hover := Dist2(MouseX, MouseY, x, y) < Sqr(26);
        FillCircle(x, y, r + 6, RGBA(0, 0, 0, 120));
        FillCircle(x, y, r + 3, RGBA(60, 20, 20, 230));
        if NextWaveTimer > 0 then
        begin
          a := NextWaveTimer / Max(0.01, Rules.WaveGap);
          FillPie(x, y, r + 3, -Pi / 2, -Pi / 2 + 2 * Pi * (1 - a), RGBA(220, 60, 40, 230));
        end;
        FillCircle(x, y, r - 2, RGBA(40, 16, 14));
        if hover then DrawSkullIcon(x, y, r - 4, RGBA(255, 240, 220))
        else DrawSkullIcon(x, y, r - 4, RGBA(230, 210, 190));
        if hover then
        begin
          if NextWaveTimer > 0 then
            Tooltip(x + 120, y + 36, 'Call wave ' + IntToStr(Wave + 1) + ' early',
              Format('Bonus: %d gold', [Round(NextWaveTimer * Rules.EarlyBonusPerSec)]), 'Click or press SPACE')
          else
            Tooltip(x + 120, y + 36, 'Start wave 1', 'Click or press SPACE when ready', '');
        end;
      end;

  // targeting cursors
  if SpellMode = SP_FIRE then
  begin
    Ring(MouseX, MouseY, FireSpell.SpreadX + 15, FireSpell.SpreadY + 10, 3, RGBA(255, 140, 40, 200));
    FillEllipse(MouseX, MouseY, FireSpell.SpreadX + 15, FireSpell.SpreadY + 10, RGBA(255, 120, 30, 40));
  end
  else if SpellMode = SP_REINF then
  begin
    if PathDist(MouseX, MouseY) <= Map.PathHalf + 6 then
      Ring(MouseX, MouseY, 26, 16, 3, RGBA(120, 220, 255, 220))
    else
      Ring(MouseX, MouseY, 26, 16, 3, RGBA(255, 60, 60, 220));
  end
  else if RallyMode and (SelPlot >= 0) then
  begin
    range := TStat(Plots[SelPlot].Kind, Plots[SelPlot].Level).Range;
    DrawRangeCircle(Plots[SelPlot].X, Plots[SelPlot].Y, range, RGBA(120, 180, 255));
    if (Dist2(MouseX, MouseY, Plots[SelPlot].X, Plots[SelPlot].Y) <= Sqr(range)) and
      (PathDist(MouseX, MouseY) <= Map.PathHalf) then
      DrawFlagIcon(MouseX + 6, MouseY - 10)
    else
      Ring(MouseX, MouseY, 12, 8, 3, RGBA(255, 60, 60, 220));
  end;

  DrawSelectionMenu;
  DrawInfoBar;

  if (State = gsPlaying) and (NextWaveTimer > 0) then
    DrawText(24, 62, Format('Next wave in %ds  (click a skull to call it early)', [Ceil(NextWaveTimer)]),
      RGBA(255, 230, 180), fnSmall)
  else if (State = gsPlaying) and (NextWaveTimer < 0) then
    DrawText(640, 96, IfThen(Wave > 0, Format('Wave %d of %d ready - click a skull when you are set!', [Wave + 1,
      Length(Waves)]), 'Build towers on the stone plots, then click a skull to begin!'), RGBA(255, 230, 180),
      fnMedium, ALIGN_CENTER);

  if BannerTime > 0 then
    DrawText(640, 250, BannerText, RGBA(255, 220, 120, Round(255 * Clamp01(BannerTime / 0.5))), fnBig, ALIGN_CENTER);
end;

{ ---------- menu buttons (registered while drawing, hit-tested on the next click) ---------- }

const
  BTN_NEW = 1;
  BTN_CONTINUE = 2;
  BTN_OPTIONS = 3;
  BTN_EXIT = 4;
  BTN_MUSIC_DOWN = 10;
  BTN_MUSIC_UP = 11;
  BTN_SOUND_DOWN = 12;
  BTN_SOUND_UP = 13;
  BTN_FULLSCREEN = 14;
  BTN_SHAKE = 15;
  BTN_MUSIC_BAR = 16;
  BTN_SOUND_BAR = 17;
  BTN_OPT_BACK = 18;
  BTN_RESUME = 30;
  BTN_RESTART = 31;
  BTN_MAPS = 32;
  BTN_TITLE = 33;
  BTN_QUIT = 34;
  BTN_MAPS_BACK = 35;

procedure RegisterButton(x, y, w, h: Single; id: Integer);
var
  n: Integer;
begin
  n := Length(UIButtons);
  SetLength(UIButtons, n + 1);
  UIButtons[n].X := x;
  UIButtons[n].Y := y;
  UIButtons[n].W := w;
  UIButtons[n].H := h;
  UIButtons[n].Id := id;
end;

function UIButtonAt(x, y: Single): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := High(UIButtons) downto 0 do
    if (x >= UIButtons[i].X) and (x < UIButtons[i].X + UIButtons[i].W) and (y >= UIButtons[i].Y) and
      (y < UIButtons[i].Y + UIButtons[i].H) then Exit(UIButtons[i].Id);
end;

// wooden menu button; returns True while hovered
function MenuButton(x, y, w, h: Single; id: Integer; const caption: string; enabled: Boolean = True;
  selected: Boolean = False; const sub: string = ''): Boolean;
var
  hover: Boolean;
  c, border, tc: TRGBA;
begin
  hover := enabled and (MouseX >= x) and (MouseX < x + w) and (MouseY >= y) and (MouseY < y + h);
  Result := hover;
  if enabled then RegisterButton(x, y, w, h, id);
  if hover or selected then border := RGBA(255, 214, 110) else border := RGBA(120, 86, 52);
  if not enabled then border := RGBA(80, 70, 62);
  RoundRect(x + 2, y + 4, w, h, 10, RGBA(0, 0, 0, 110));
  RoundRect(x, y, w, h, 10, border);
  if not enabled then c := RGBA(58, 50, 44)
  else if hover or selected then c := RGBA(118, 80, 48)
  else c := RGBA(86, 58, 34);
  FillRectGrad(x + 3, y + 3, w - 6, h - 6, Shade(c, 1.25), Shade(c, 0.8));
  if enabled then tc := RGBA(255, 236, 200) else tc := RGBA(140, 130, 120);
  if sub = '' then
    DrawText(x + w / 2, y + (h - TextHeight(fnMedium)) / 2 - 1, caption, tc, fnMedium, ALIGN_CENTER)
  else
  begin
    DrawText(x + w / 2, y + 5, caption, tc, fnMedium, ALIGN_CENTER);
    DrawText(x + w / 2, y + h - 21, sub, RGBA(225, 205, 165), fnSmall, ALIGN_CENTER);
  end;
end;

procedure DrawOverlay;
var
  title, sub: string;
  c: TRGBA;
  a: Byte;
  y: Single;
begin
  if HurtFlash > 0 then
  begin
    a := Round(200 * Clamp01(HurtFlash));
    FillRect(0, 0, SCR_W, 18, RGBA(220, 0, 0, a));
    FillRect(0, SCR_H - 18, SCR_W, 18, RGBA(220, 0, 0, a));
    FillRect(0, 0, 18, SCR_H, RGBA(220, 0, 0, a));
    FillRect(SCR_W - 18, 0, 18, SCR_H, RGBA(220, 0, 0, a));
  end;
  if (State = gsPlaying) and not Paused then Exit;
  FillRect(0, 0, SCR_W, SCR_H, RGBA(10, 5, 0, 160));
  if State in [gsWon, gsLost] then
  begin
    if State = gsWon then
    begin
      title := 'Victory!';
      sub := Format('The %s stands. Lives left: %d   Enemies slain: %d', [Map.Name, Lives, Kills]);
      c := RGBA(255, 220, 90);
    end
    else
    begin
      title := 'Defeat';
      sub := Format('The horde broke through on wave %d.   Enemies slain: %d', [Wave, Kills]);
      c := RGBA(255, 90, 70);
    end;
    Panel(370, 200, 540, 330);
    DrawText(640, 222, title, c, fnBig, ALIGN_CENTER);
    DrawText(640, 292, sub, RGBA(240, 230, 210), fnSmall, ALIGN_CENTER);
    MenuButton(520, 330, 240, 46, BTN_RESTART, 'Play again');
    MenuButton(520, 384, 240, 46, BTN_MAPS, 'Choose map');
    MenuButton(520, 438, 240, 46, BTN_TITLE, 'Main menu');
    Exit;
  end;
  // paused
  Panel(430, 120, 420, 480);
  DrawText(640, 136, 'Paused', RGBA(255, 230, 160), fnBig, ALIGN_CENTER);
  y := 210;
  MenuButton(520, y, 240, 46, BTN_RESUME, 'Resume'); y := y + 56;
  MenuButton(520, y, 240, 46, BTN_RESTART, 'Restart map'); y := y + 56;
  MenuButton(520, y, 240, 46, BTN_OPTIONS, 'Options'); y := y + 56;
  MenuButton(520, y, 240, 46, BTN_MAPS, 'Choose map'); y := y + 56;
  MenuButton(520, y, 240, 46, BTN_TITLE, 'Main menu'); y := y + 56;
  MenuButton(520, y, 240, 46, BTN_QUIT, 'Quit game');
  DrawText(640, 572, 'Esc / P resume   R restart   F5 reload data', RGBA(200, 185, 160), fnSmall, ALIGN_CENTER);
end;

{ ======================================================================
  map select screen
  ====================================================================== }

procedure CancelModes; forward;
procedure GoTitle; forward;

procedure FreeMenu;
var
  i: Integer;
begin
  for i := 0 to High(MenuThumbs) do
    if MenuThumbs[i] <> nil then SDL_DestroyTexture(MenuThumbs[i]);
  SetLength(MenuThumbs, 0);
  SetLength(MenuMaps, 0);
  SetLength(MenuNames, 0);
  SetLength(MenuWaves, 0);
end;

// scan data\maps and render a thumbnail of every map (ground, roads, plots, decoration)
procedure BuildMenu;
var
  sr: TSearchRec;
  names: TStringList;
  i, k, n: Integer;
  m: TMapDef;
  ps: TPathArray;
  err: string;
  st: TAnimState;
  w: TWaveArray;
  sl: TStringList;
begin
  FreeMenu;
  names := TStringList.Create;
  try
    if FindFirst(DataDir + 'maps' + PathDelim + '*.json', faAnyFile, sr) = 0 then
    begin
      repeat
        names.Add(ChangeFileExt(sr.Name, ''));
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    names.Sort;
    // keep the first campaign map first
    k := names.IndexOf('brewhold');
    if k > 0 then names.Move(k, 0);
    SDL_SetRenderLogicalPresentation(Renderer, SCR_W, SCR_H, SDL_LOGICAL_PRESENTATION_DISABLED);
    st := DefaultAnimState;
    for i := 0 to names.Count - 1 do
    begin
      m := Default(TMapDef);
      if not LoadMapFile(DataDir + 'maps' + PathDelim + names[i] + '.json', m, err) then Continue;
      n := Length(MenuNames);
      SetLength(MenuNames, n + 1);
      SetLength(MenuMaps, n + 1);
      SetLength(MenuThumbs, n + 1);
      SetLength(MenuWaves, n + 1);
      MenuNames[n] := names[i];
      MenuMaps[n] := m;
      // wave count of that map's waves file
      MenuWaves[n] := 0;
      if m.WavesFile = '' then m.WavesFile := 'waves.json';
      if FileExists(DataDir + m.WavesFile) then
      begin
        sl := TStringList.Create;
        try
          sl.LoadFromFile(DataDir + m.WavesFile);
          w := nil;
          if WavesFromJSONText(sl.Text, w, err) then MenuWaves[n] := Length(w);
        finally
          sl.Free;
        end;
      end;
      ps := nil;
      BuildAllPaths(m, ps);
      MenuThumbs[n] := SDL_CreateTexture(Renderer, SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_TARGET, m.Width, m.Height);
      SDL_SetTextureScaleMode(MenuThumbs[n], SDL_SCALEMODE_LINEAR);
      SDL_SetRenderTarget(Renderer, MenuThumbs[n]);
      SDL_SetRenderDrawColor(Renderer, 0, 0, 0, 255);
      SDL_RenderClear(Renderer);
      DrawMapBase(m, ps);
      for k := 0 to High(m.Decor) do
        DrawGeoIdx(Geo, Geo.Find(m.Decor[k].Geo), m.Decor[k].X, m.Decor[k].Y, m.Decor[k].S, st);
      for k := 0 to High(m.PlotX) do
        DrawGeoIdx(Geo, GeoPlotEmpty, m.PlotX[k], m.PlotY[k], 1, st);
      if m.Fortress then DrawFortress(m.Width, m.Height);
      DrawVignette(m.Width, m.Height);
      SDL_SetRenderTarget(Renderer, nil);
    end;
    SDL_SetRenderLogicalPresentation(Renderer, SCR_W, SCR_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
  finally
    names.Free;
  end;
  MenuSel := EnsureRange(MenuSel, 0, Max(0, High(MenuNames)));
  for i := 0 to High(MenuNames) do
    if MenuNames[i] = MapName then MenuSel := i;
end;

procedure OpenMenu;
begin
  BuildMenu;
  State := gsMenu;
  Paused := False;
  CancelModes;
end;

procedure StartMap(i: Integer);
var
  err: string;
begin
  if (i < 0) or (i > High(MenuNames)) then Exit;
  MapName := MenuNames[i];
  SDL_SetRenderLogicalPresentation(Renderer, SCR_W, SCR_H, SDL_LOGICAL_PRESENTATION_DISABLED);
  if not LoadAll(err) then
  begin
    SDL_SetRenderLogicalPresentation(Renderer, SCR_W, SCR_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Cannot load map', PAnsiChar(err), Window);
    Exit;
  end;
  SDL_SetRenderLogicalPresentation(Renderer, SCR_W, SCR_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
  ResetGame;
  SDL_SetWindowTitle(Window, PAnsiChar('Brewhold Defense - ' + Map.Name));
  PlaySound(sndHorn, 0.8, 0);
end;

// card layout: up to 3 per row, centred
procedure MenuCardRect(i: Integer; out x, y, w, h: Single);
var
  perRow, row, col, inRow: Integer;
begin
  perRow := Min(3, Max(1, Length(MenuNames)));
  if Length(MenuNames) <= 2 then w := 520 else w := 380;
  h := w * 9 / 16 + 96;
  row := i div perRow;
  col := i mod perRow;
  inRow := Min(perRow, Length(MenuNames) - row * perRow);
  x := (SCR_W - inRow * w - (inRow - 1) * 30) / 2 + col * (w + 30);
  y := 190 + row * (h + 24);
end;

procedure DrawMenu;
var
  i, roads: Integer;
  x, y, w, h, th: Single;
  dst: TSDL_FRect;
  hover: Boolean;
  m: TMapDef;
  c: TRGBA;
begin
  // backdrop: the last map, darkened
  if BgTex <> nil then
  begin
    dst.x := 0; dst.y := 0; dst.w := SCR_W; dst.h := SCR_H;
    SDL_RenderTexture(Renderer, BgTex, nil, @dst);
  end;
  FillRect(0, 0, SCR_W, SCR_H, RGBA(14, 8, 4, 205));
  DrawText(640, 48, 'Brewhold Defense', RGBA(255, 215, 110), fnBig, ALIGN_CENTER);
  DrawText(640, 112, 'Choose your battlefield', RGBA(240, 225, 200), fnMedium, ALIGN_CENTER);
  if Length(MenuNames) = 0 then
  begin
    DrawText(640, 300, 'No maps found in data\maps', RGBA(255, 120, 100), fnMedium, ALIGN_CENTER);
    Exit;
  end;
  for i := 0 to High(MenuNames) do
  begin
    MenuCardRect(i, x, y, w, h);
    m := MenuMaps[i];
    hover := (MouseX >= x) and (MouseX < x + w) and (MouseY >= y) and (MouseY < y + h);
    if hover then MenuSel := i;
    if i = MenuSel then c := RGBA(255, 210, 110) else c := RGBA(110, 80, 50);
    RoundRect(x - 4, y - 4, w + 8, h + 8, 12, c);
    RoundRect(x, y, w, h, 10, RGBA(42, 28, 18, 245));
    th := w * 9 / 16;
    dst.x := x + 8; dst.y := y + 8; dst.w := w - 16; dst.h := th - 16;
    if MenuThumbs[i] <> nil then SDL_RenderTexture(Renderer, MenuThumbs[i], nil, @dst);
    if i <> MenuSel then FillRect(dst.x, dst.y, dst.w, dst.h, RGBA(0, 0, 0, 70));
    roads := Length(m.Paths);
    DrawText(x + 14, y + th - 2, m.Name, RGBA(255, 225, 140), fnMedium);
    DrawText(x + w - 14, y + th + 2, Format('%d roads  |  %d plots  |  %d waves', [roads, Length(m.PlotX), MenuWaves[i]]),
      RGBA(210, 200, 185), fnSmall, ALIGN_RIGHT);
    if m.Desc <> '' then DrawText(x + 14, y + th + 30, m.Desc, RGBA(235, 225, 210), fnSmall)
    else DrawText(x + 14, y + th + 30, 'data\maps\' + MenuNames[i] + '.json', RGBA(170, 160, 150), fnSmall);
    DrawText(x + 14, y + th + 52, IntToStr(i + 1), RGBA(255, 215, 110), fnSmall);
  end;
  DrawText(640, SCR_H - 40, 'Click a map (or 1-9 / arrows + Enter) to play     Esc: back', RGBA(220, 205, 180), fnSmall,
    ALIGN_CENTER);
  MenuButton(30, SCR_H - 70, 150, 46, BTN_MAPS_BACK, '< Back');
end;

procedure MenuClick(x, y: Single);
var
  i: Integer;
  cx, cy, w, h: Single;
begin
  for i := 0 to High(MenuNames) do
  begin
    MenuCardRect(i, cx, cy, w, h);
    if (x >= cx) and (x < cx + w) and (y >= cy) and (y < cy + h) then
    begin
      StartMap(i);
      Exit;
    end;
  end;
end;

procedure MenuKey(key: TSDL_Keycode; var running: Boolean);
begin
  case key of
    SDLK_LEFT, SDLK_UP: MenuSel := Max(0, MenuSel - 1);
    SDLK_RIGHT, SDLK_DOWN: MenuSel := Min(High(MenuNames), MenuSel + 1);
    SDLK_RETURN, SDLK_SPACE: StartMap(MenuSel);
    SDLK_ESCAPE: GoTitle;
    SDLK_1..SDLK_9: if Integer(key - SDLK_1) <= High(MenuNames) then StartMap(Integer(key - SDLK_1));
  end;
end;

{ ======================================================================
  front end: options, save / continue, music, title screen
  ====================================================================== }

function OptionsFile: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'options.json';
end;

function SaveFile: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'savegame.json';
end;

procedure ApplyFullscreen;
begin
  SDL_SetWindowFullscreen(Window, OptFullscreen);
end;

procedure SaveOptions;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Add('{');
    sl.Add('  "musicVolume": ' + FormatFloat('0.00', MusicVolume, JsonFS) + ',');
    sl.Add('  "soundVolume": ' + FormatFloat('0.00', MasterVolume, JsonFS) + ',');
    sl.Add('  "fullscreen": ' + BoolToStr(OptFullscreen, 'true', 'false') + ',');
    sl.Add('  "screenShake": ' + BoolToStr(OptShake, 'true', 'false'));
    sl.Add('}');
    try
      sl.SaveToFile(OptionsFile);
    except
    end;
  finally
    sl.Free;
  end;
end;

function ReadJSONFile(const fn: string): TJSONObject;
var
  sl: TStringList;
  d: TJSONData;
begin
  Result := nil;
  if not FileExists(fn) then Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(fn);
      d := GetJSON(sl.Text);
      if d.JSONType = jtObject then Result := TJSONObject(d) else d.Free;
    except
      Result := nil;
    end;
  finally
    sl.Free;
  end;
end;

procedure LoadOptions;
var
  o: TJSONObject;
begin
  o := ReadJSONFile(OptionsFile);
  if o = nil then Exit;
  try
    MusicVolume := EnsureRange(o.Get('musicVolume', Double(MusicVolume)), 0, 1);
    MasterVolume := EnsureRange(o.Get('soundVolume', Double(MasterVolume)), 0, 1);
    OptFullscreen := o.Get('fullscreen', OptFullscreen);
    OptShake := o.Get('screenShake', OptShake);
  finally
    o.Free;
  end;
end;

{ ---------- save game: a checkpoint written when each wave starts ---------- }

procedure SaveCheckpoint;
var
  sl: TStringList;
  p, n: Integer;
  line: string;
begin
  if SaveDisabled then Exit;
  sl := TStringList.Create;
  try
    sl.Add('{');
    sl.Add('  "map": "' + MapName + '", "wave": ' + IntToStr(Wave) + ', "gold": ' + IntToStr(Gold) +
      ', "lives": ' + IntToStr(Lives) + ', "kills": ' + IntToStr(Kills) + ',');
    sl.Add('  "hero": {"level": ' + IntToStr(HeroU.Level) + ', "xp": ' + IntToStr(HeroU.Xp) + '},');
    sl.Add('  "towers": [');
    n := 0;
    for p := 0 to NPlots - 1 do
      if Plots[p].Kind >= 0 then
      begin
        line := Format('    {"plot": %d, "tower": "%s", "level": %d, "spent": %d, "rallyX": %s, "rallyY": %s}',
          [p, TowerDefs[Plots[p].Kind].Id, Plots[p].Level, Plots[p].Spent, FormatFloat('0.#', Plots[p].RallyX, JsonFS),
           FormatFloat('0.#', Plots[p].RallyY, JsonFS)]);
        if n > 0 then sl[sl.Count - 1] := sl[sl.Count - 1] + ',';
        sl.Add(line);
        Inc(n);
      end;
    sl.Add('  ]');
    sl.Add('}');
    try
      sl.SaveToFile(SaveFile);
    except
    end;
  finally
    sl.Free;
  end;
end;

procedure DeleteSave;
begin
  if not SaveDisabled and FileExists(SaveFile) then DeleteFile(SaveFile);
end;

function ReadSaveInfo(out mapFile, mapTitle: string; out waveNo: Integer): Boolean;
var
  o: TJSONObject;
  m: TMapDef;
  err: string;
begin
  Result := False;
  mapFile := '';
  mapTitle := '';
  waveNo := 0;
  o := ReadJSONFile(SaveFile);
  if o = nil then Exit;
  try
    mapFile := o.Get('map', '');
    waveNo := o.Get('wave', 0);
  finally
    o.Free;
  end;
  if (mapFile = '') or not FileExists(DataDir + 'maps' + PathDelim + mapFile + '.json') then Exit;
  m := Default(TMapDef);
  if LoadMapFile(DataDir + 'maps' + PathDelim + mapFile + '.json', m, err) then mapTitle := m.Name
  else mapTitle := mapFile;
  Result := True;
end;

function PlayMap(const name: string): Boolean;
var
  err: string;
begin
  MapName := name;
  SDL_SetRenderLogicalPresentation(Renderer, SCR_W, SCR_H, SDL_LOGICAL_PRESENTATION_DISABLED);
  Result := LoadAll(err);
  SDL_SetRenderLogicalPresentation(Renderer, SCR_W, SCR_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
  if not Result then
  begin
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Cannot load map', PAnsiChar(err), Window);
    Exit;
  end;
  ResetGame;
  SDL_SetWindowTitle(Window, PAnsiChar('Brewhold Defense - ' + Map.Name));
end;

procedure ContinueGame;
var
  o, t, h: TJSONObject;
  a: TJSONArray;
  i, p, k, s: Integer;
  id: string;
  st: TTowerLevel;
begin
  o := ReadJSONFile(SaveFile);
  if o = nil then Exit;
  try
    if not PlayMap(o.Get('map', 'brewhold')) then Exit;
    Wave := EnsureRange(o.Get('wave', 0), 0, Max(0, TotalWaves - 1));
    Gold := o.Get('gold', Gold);
    Lives := o.Get('lives', Lives);
    Kills := o.Get('kills', 0);
    if (o.Find('hero') <> nil) and (o.Find('hero').JSONType = jtObject) and HeroActive then
    begin
      h := TJSONObject(o.Find('hero'));
      HeroU.Level := EnsureRange(h.Get('level', 1), 1, Length(Hero.Levels));
      HeroU.Xp := h.Get('xp', 0);
      HeroU.MaxHp := HeroLvl.Hp;
      HeroU.Hp := HeroU.MaxHp;
    end;
    if (o.Find('towers') <> nil) and (o.Find('towers').JSONType = jtArray) then
    begin
      a := TJSONArray(o.Find('towers'));
      for i := 0 to a.Count - 1 do
      begin
        t := TJSONObject(a.Items[i]);
        p := t.Get('plot', -1);
        id := t.Get('tower', '');
        if (p < 0) or (p >= NPlots) then Continue;
        k := -1;
        for s := 0 to High(TowerDefs) do
          if SameText(TowerDefs[s].Id, id) then k := s;
        if k < 0 then Continue;
        Plots[p].Kind := k;
        Plots[p].Level := EnsureRange(t.Get('level', 1), 1, MaxLevel(k));
        Plots[p].Spent := t.Get('spent', TStat(k, 1).Cost);
        Plots[p].RallyX := t.Get('rallyX', Double(Plots[p].X));
        Plots[p].RallyY := t.Get('rallyY', Double(Plots[p].Y));
        Plots[p].Cooldown := 0.3;
        Plots[p].SinceFire := 99;
        Plots[p].Aim := Pi / 2;
        if TowerDefs[k].Behavior = TB_BARRACKS then
        begin
          st := TStat(k, Plots[p].Level);
          for s := 0 to TowerDefs[k].Soldiers - 1 do
            AddSoldier(p, s, Plots[p].X + (s - 1) * 10, Plots[p].Y + 6, st.SoldierHp, st.Damage, 0);
        end;
      end;
    end;
    NextWaveTimer := -1;
    BannerText := Format('Continuing - wave %d', [Wave + 1]);
    BannerTime := 3;
  finally
    o.Free;
  end;
end;

{ ---------- music for the current screen ---------- }

procedure UpdateMusic;
var
  want: string;
begin
  want := '';
  if State in [gsTitle, gsMenu] then want := DataDir + 'music' + PathDelim + 'title.json'
  else if (State = gsPlaying) and (Map.Music <> '') then want := DataDir + 'music' + PathDelim + Map.Music;
  if want = LastMusic then Exit;
  LastMusic := want;
  if want = '' then MusicStop(1.2) else MusicPlayFile(want);
end;

{ ---------- title screen ---------- }

procedure GoTitle;
begin
  State := gsTitle;
  Paused := False;
  OptionsOpen := False;
  CancelModes;
  TitleSel := 0;
end;

procedure DrawTitle;
var
  dst: TSDL_FRect;
  st: TAnimState;
  y: Single;
  mf, mt: string;
  wv: Integer;
  hasSave: Boolean;
begin
  if BgTex <> nil then
  begin
    dst.x := 0; dst.y := 0; dst.w := SCR_W; dst.h := SCR_H;
    SDL_RenderTexture(Renderer, BgTex, nil, @dst);
    DrawAnimatedDecor;
  end;
  FillRectGrad(0, 0, SCR_W, SCR_H, RGBA(12, 6, 2, 150), RGBA(12, 6, 2, 220));
  // the hero facing a lava brute
  st := MakeState;
  st.Walk := GameTime;
  st.Level := 5;
  st.Swing := Max(0, 0.25 - Frac(GameTime / 1.6) * 0.8);
  DrawGeoIdx(Geo, Hero.GeoIdx, 250, 600, 4.2, st);
  if Length(EnemyDefs) > 0 then
  begin
    st := MakeState;
    st.Walk := GameTime;
    st.Facing := -1;
    DrawGeoIdx(Geo, EnemyDefs[High(EnemyDefs)].GeoIdx, 1030, 610, 3.6, st);
  end;
  DrawText(640, 70, 'Brewhold Defense', RGBA(255, 215, 110), fnBig, ALIGN_CENTER);
  DrawText(640, 132, 'Hold the dwarven halls against the horde', RGBA(240, 225, 200), fnMedium, ALIGN_CENTER);
  hasSave := ReadSaveInfo(mf, mt, wv);
  y := 220;
  MenuButton(510, y, 260, 56, BTN_NEW, 'New Game', True, TitleSel = 0); y := y + 68;
  if hasSave then
    MenuButton(510, y, 260, 64, BTN_CONTINUE, 'Continue', True, TitleSel = 1, Format('%s - wave %d', [mt, wv + 1]))
  else
    MenuButton(510, y, 260, 56, BTN_CONTINUE, 'Continue', False, False);
  y := y + 76;
  MenuButton(510, y, 260, 56, BTN_OPTIONS, 'Options', True, TitleSel = 2); y := y + 68;
  MenuButton(510, y, 260, 56, BTN_EXIT, 'Exit', True, TitleSel = 3);
  DrawText(640, SCR_H - 34, 'Arrows + Enter or click     F11 fullscreen     M mute', RGBA(200, 185, 160), fnSmall,
    ALIGN_CENTER);
end;

{ ---------- options overlay ---------- }

procedure VolumeRow(y: Single; const caption: string; value: Single; idDown, idUp, idBar: Integer);
const
  BX = 600;
  BW = 200;
begin
  DrawText(470, y + 8, caption, RGBA(240, 225, 200), fnMedium);
  MenuButton(BX - 44, y + 4, 36, 34, idDown, '-');
  RoundRect(BX, y + 13, BW, 16, 7, RGBA(30, 20, 12));
  RoundRect(BX, y + 13, Max(14, BW * value), 16, 7, RGBA(230, 180, 80));
  RegisterButton(BX, y + 4, BW, 34, idBar);
  MenuButton(BX + BW + 8, y + 4, 36, 34, idUp, '+');
  DrawText(BX + BW + 56, y + 8, IntToStr(Round(value * 100)) + '%', RGBA(255, 230, 170), fnMedium);
end;

procedure DrawOptions;
var
  y: Single;
begin
  FillRect(0, 0, SCR_W, SCR_H, RGBA(8, 4, 0, 150));
  Panel(440, 150, 450, 420);
  DrawText(665, 166, 'Options', RGBA(255, 230, 160), fnBig, ALIGN_CENTER);
  y := 250;
  VolumeRow(y, 'Music', MusicVolume, BTN_MUSIC_DOWN, BTN_MUSIC_UP, BTN_MUSIC_BAR); y := y + 60;
  VolumeRow(y, 'Sound', MasterVolume, BTN_SOUND_DOWN, BTN_SOUND_UP, BTN_SOUND_BAR); y := y + 70;
  DrawText(470, y + 8, 'Fullscreen', RGBA(240, 225, 200), fnMedium);
  MenuButton(656, y, 120, 40, BTN_FULLSCREEN, IfThen(OptFullscreen, 'On', 'Off'), True, OptFullscreen); y := y + 54;
  DrawText(470, y + 8, 'Screen shake', RGBA(240, 225, 200), fnMedium);
  MenuButton(656, y, 120, 40, BTN_SHAKE, IfThen(OptShake, 'On', 'Off'), True, OptShake);
  MenuButton(545, 500, 240, 48, BTN_OPT_BACK, 'Back');
end;

procedure CloseOptions;
begin
  OptionsOpen := False;
  SaveOptions;
end;

procedure HandleUIButton(id: Integer; x, y: Single);
begin
  PlaySound(sndClick, 1.0, 0.05);
  case id of
    BTN_NEW: OpenMenu;
    BTN_CONTINUE: ContinueGame;
    BTN_OPTIONS: OptionsOpen := True;
    BTN_EXIT, BTN_QUIT: QuitRequested := True;
    BTN_MUSIC_DOWN: MusicVolume := Max(0, Round(MusicVolume * 10 - 1) / 10);
    BTN_MUSIC_UP: MusicVolume := Min(1, Round(MusicVolume * 10 + 1) / 10);
    BTN_SOUND_DOWN: MasterVolume := Max(0, Round(MasterVolume * 10 - 1) / 10);
    BTN_SOUND_UP: MasterVolume := Min(1, Round(MasterVolume * 10 + 1) / 10);
    BTN_MUSIC_BAR: MusicVolume := EnsureRange((x - 600) / 200, 0, 1);
    BTN_SOUND_BAR: MasterVolume := EnsureRange((x - 600) / 200, 0, 1);
    BTN_FULLSCREEN:
      begin
        OptFullscreen := not OptFullscreen;
        ApplyFullscreen;
      end;
    BTN_SHAKE: OptShake := not OptShake;
    BTN_OPT_BACK: CloseOptions;
    BTN_RESUME: Paused := False;
    BTN_RESTART: ResetGame;
    BTN_MAPS, BTN_MAPS_BACK:
      if id = BTN_MAPS then OpenMenu else GoTitle;
    BTN_TITLE: GoTitle;
  end;
  if id in [BTN_SOUND_DOWN, BTN_SOUND_UP, BTN_SOUND_BAR] then PlaySound(sndCoin, 1.0, 0);
end;

procedure TitleKey(key: TSDL_Keycode);
var
  mf, mt: string;
  wv: Integer;
begin
  case key of
    SDLK_UP:
      begin
        TitleSel := (TitleSel + 3) mod 4;
        if (TitleSel = 1) and not ReadSaveInfo(mf, mt, wv) then TitleSel := 0;
      end;
    SDLK_DOWN:
      begin
        TitleSel := (TitleSel + 1) mod 4;
        if (TitleSel = 1) and not ReadSaveInfo(mf, mt, wv) then TitleSel := 2;
      end;
    SDLK_RETURN, SDLK_SPACE:
      case TitleSel of
        0: HandleUIButton(BTN_NEW, 0, 0);
        1: HandleUIButton(BTN_CONTINUE, 0, 0);
        2: HandleUIButton(BTN_OPTIONS, 0, 0);
        3: HandleUIButton(BTN_EXIT, 0, 0);
      end;
    SDLK_ESCAPE: QuitRequested := True;
  end;
end;

procedure OptionsKey(key: TSDL_Keycode);
begin
  case key of
    SDLK_ESCAPE, SDLK_RETURN: CloseOptions;
    SDLK_LEFT: MusicVolume := Max(0, MusicVolume - 0.1);
    SDLK_RIGHT: MusicVolume := Min(1, MusicVolume + 0.1);
  end;
end;

{ ======================================================================
  input
  ====================================================================== }

procedure CancelModes;
begin
  SelPlot := -1;
  RallyMode := False;
  SpellMode := SP_NONE;
  HeroU.Selected := False;
end;

procedure ToggleSpell(sp: Integer);
begin
  if State <> gsPlaying then Exit;
  if (sp = SP_FIRE) and (FireCd > 0) then Exit;
  if (sp = SP_REINF) and (ReinfCd > 0) then Exit;
  SelPlot := -1;
  RallyMode := False;
  HeroU.Selected := False;
  if SpellMode = sp then SpellMode := SP_NONE else SpellMode := sp;
end;

procedure HandleClick(x, y: Single);
var
  i, k: Integer;
  cx, cy, bx, by, range: Single;
begin
  k := UIButtonAt(x, y);
  if k <> 0 then
  begin
    HandleUIButton(k, x, y);
    Exit;
  end;
  if OptionsOpen or (State = gsTitle) then Exit;
  if State = gsMenu then
  begin
    MenuClick(x, y);
    Exit;
  end;
  if Dist2(x, y, MUTE_X, TOPBTN_Y) < Sqr(22) then
  begin
    SoundMuted := not SoundMuted;
    PlaySound(sndClick);
    Exit;
  end;
  if Dist2(x, y, SPEED_X, TOPBTN_Y) < Sqr(22) then
  begin
    Speed2x := not Speed2x;
    Exit;
  end;
  if Dist2(x, y, PAUSE_X, TOPBTN_Y) < Sqr(22) then
  begin
    if State = gsPlaying then Paused := not Paused;
    Exit;
  end;
  if (State <> gsPlaying) or Paused then Exit;

  if Dist2(x, y, SPELL_X1, SPELL_Y) < Sqr(SPELL_R) then
  begin
    ToggleSpell(SP_FIRE);
    Exit;
  end;
  if Dist2(x, y, SPELL_X2, SPELL_Y) < Sqr(SPELL_R) then
  begin
    ToggleSpell(SP_REINF);
    Exit;
  end;
  if HeroActive then
  begin
    if Dist2(x, y, HERO_X, SPELL_Y) < Sqr(SPELL_R) then
    begin
      SelectHero(not HeroU.Selected);
      Exit;
    end;
    if Dist2(x, y, HAB1_X, SPELL_Y) < Sqr(HAB_R) then
    begin
      CastSlam;
      Exit;
    end;
    if Dist2(x, y, HAB2_X, SPELL_Y) < Sqr(HAB_R) then
    begin
      CastHammer;
      Exit;
    end;
  end;
  if SpellMode = SP_FIRE then
  begin
    CastFire(x, y);
    Exit;
  end;
  if SpellMode = SP_REINF then
  begin
    if PathDist(x, y) <= Map.PathHalf + 6 then CastReinforce(x, y);
    Exit;
  end;

  // selected hero: any click on the map is a move order
  if HeroActive and HeroU.Selected and HeroU.Alive then
  begin
    HeroOrder(x, y);
    HeroU.Selected := False;
    Exit;
  end;
  if HeroActive and HeroU.Alive and not RallyMode and (Dist2(x, y, HeroU.X, HeroU.Y - 16) < Sqr(22)) then
  begin
    SelectHero(True);
    Exit;
  end;

  if RallyMode and (SelPlot >= 0) then
  begin
    range := TStat(Plots[SelPlot].Kind, Plots[SelPlot].Level).Range;
    if (Dist2(x, y, Plots[SelPlot].X, Plots[SelPlot].Y) <= range * range) and (PathDist(x, y) <= Map.PathHalf) then
    begin
      Plots[SelPlot].RallyX := x;
      Plots[SelPlot].RallyY := y;
      Emit(PT_RING, x, y, 0, 0, 0.4, 24, RGBA(120, 180, 255));
      PlaySound(sndRallyHorn, 0.5, 0.05);
      for i := 0 to MAX_SOLDIERS - 1 do
        if Soldiers[i].Active and (Soldiers[i].Owner = SelPlot) and (Soldiers[i].Target >= 0) then
        begin
          if Enemies[Soldiers[i].Target].Blocker = i then Enemies[Soldiers[i].Target].Blocker := -1;
          Soldiers[i].Target := -1;
        end;
    end;
    RallyMode := False;
    SelPlot := -1;
    Exit;
  end;

  if SkullVisible then
    for i := 0 to High(Map.Paths) do
      if NextWaveUsesPath(i) and (Dist2(x, y, Map.Paths[i].EntranceX, Map.Paths[i].EntranceY) < Sqr(26)) then
      begin
        StartNextWave;
        Exit;
      end;

  if SelPlot >= 0 then
  begin
    cx := Plots[SelPlot].X;
    cy := Plots[SelPlot].Y - 20;
    k := Plots[SelPlot].Kind;
    if k < 0 then
    begin
      for i := 0 to High(TowerDefs) do
      begin
        MenuPos(i, cx, cy, bx, by);
        if Dist2(x, y, bx, by) < Sqr(BTN_R) then
        begin
          if Gold >= TStat(i, 1).Cost then
          begin
            BuildTower(SelPlot, i);
            SelPlot := -1;
          end;
          Exit;
        end;
      end;
    end
    else
    begin
      if (Plots[SelPlot].Level < MaxLevel(k)) and (Dist2(x, y, cx, cy - 58) < Sqr(BTN_R)) then
      begin
        UpgradeTower(SelPlot);
        Exit;
      end;
      if Dist2(x, y, cx, cy + 64) < Sqr(BTN_R) then
      begin
        SellTower(SelPlot);
        SelPlot := -1;
        Exit;
      end;
      if IsBarracks(SelPlot) and (Dist2(x, y, cx - 62, cy + 10) < Sqr(BTN_R)) then
      begin
        RallyMode := True;
        Exit;
      end;
    end;
  end;

  for i := 0 to NPlots - 1 do
    if Dist2(x, y, Plots[i].X, Plots[i].Y - 14) < Sqr(38) then
    begin
      if SelPlot = i then SelPlot := -1 else SelPlot := i;
      PlaySound(sndClick, 1.0, 0.05);
      Exit;
    end;
  SelPlot := -1;
end;

{ ======================================================================
  main
  ====================================================================== }

procedure SaveScreenshot(const fn: string);
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

procedure SetupDemo;
var
  i: Integer;
  bx, by: Single;
begin
  if StartWaveArg > 1 then Exit;   // --wave: show the real play-test start
  Gold := 5000;
  for i := 0 to NPlots - 1 do
    if i mod 5 <> 4 then
    begin
      BuildTower(i, i mod Length(TowerDefs));
      if i mod 3 = 0 then UpgradeTower(i);
      if i mod 6 = 0 then UpgradeTower(i);
    end;
  Gold := 400;
  Wave := Min(9, TotalWaves - 1);
  StartNextWave;
  for i := 0 to NPlots - 1 do
    if (Plots[i].Kind < 0) and (Plots[i].X > 300) and (Plots[i].X < 1000) and (Plots[i].Y < 550) then
    begin
      SelPlot := i;
      MenuPos(1, Plots[i].X, Plots[i].Y - 20, bx, by);
      MouseX := bx;
      MouseY := by;
      Break;
    end;
end;

var
  Event: TSDL_Event;
  Running: Boolean;
  LastTicks, NowTicks: UInt64;
  Dt: Single;
  Steps, k: Integer;
  ShotFile, Err: string;
  ShotTime: Single;
  PrevState: TGameState;
  HeroTest: Boolean = False;
  MapGiven, ForceMenu, ForceTitle: Boolean;
  ArgK: Integer;

begin
  MapName := 'brewhold';
  MapGiven := False;
  ForceMenu := False;
  ForceTitle := False;
  for k := 1 to ParamCount do
  begin
    if ParamStr(k) = '--menu' then ForceMenu := True;
    if ParamStr(k) = '--title' then ForceTitle := True;
  end;
  for k := 1 to ParamCount - 1 do
  begin
    if ParamStr(k) = '--map' then
    begin
      MapName := ParamStr(k + 1);
      MapGiven := True;
    end;
    if ParamStr(k) = '--wave' then StartWaveArg := StrToIntDef(ParamStr(k + 1), 1);
  end;

  if (ParamCount >= 2) and (ParamStr(1) = '--dumpsfx') then
  begin
    SfxDumpWav(ParamStr(2));
    Halt(0);
  end;

  if not SDL_Init(SDL_INIT_VIDEO) then
  begin
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Tower Defense',
      PAnsiChar('SDL_Init failed: ' + string(SDL_GetError)), nil);
    Halt(1);
  end;
  if not SDL_CreateWindowAndRenderer('Brewhold Defense - SDL3 + Lazarus',
    SCR_W, SCR_H, SDL_WINDOW_RESIZABLE, @Window, @Renderer) then
  begin
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Tower Defense',
      PAnsiChar('Window/renderer failed: ' + string(SDL_GetError)), nil);
    SDL_Quit;
    Halt(1);
  end;
  SDL_SetWindowMinimumSize(Window, 640, 360);
  SDL_SetRenderVSync(Renderer, 1);
  SDL_SetRenderDrawBlendMode(Renderer, SDL_BLENDMODE_BLEND);

  GfxInit(Renderer);
  SfxInit;
  JsonFS := DefaultFormatSettings;
  JsonFS.DecimalSeparator := '.';
  LoadOptions;
  if OptFullscreen then ApplyFullscreen;
  BgTex := nil;
  if not LoadAll(Err) then
  begin
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Tower Defense - data error', PAnsiChar(Err), Window);
    SDL_Quit;
    Halt(1);
  end;
  SDL_SetRenderLogicalPresentation(Renderer, SCR_W, SCR_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
  ResetGame;

  MouseX := -100;
  MouseY := -100;
  SelPlot := -1;
  PrevState := gsPlaying;
  ShotFile := '';
  ShotTime := 20;
  for k := 1 to ParamCount - 1 do
    if ParamStr(k) = '--shot' then
    begin
      ShotFile := ParamStr(k + 1);
      SoundMuted := True;
      if (k + 2 <= ParamCount) and (Copy(ParamStr(k + 2), 1, 2) <> '--') then
        ShotTime := StrToFloatDef(ParamStr(k + 2), 20);
      SaveDisabled := True;
      for ArgK := 1 to ParamCount do
        if ParamStr(ArgK) = '--savetest' then SaveDisabled := False;
      if not (ForceMenu or ForceTitle) then SetupDemo;
    end;
  SaveDisabled := ShotFile <> '';
  for k := 1 to ParamCount do
    if ParamStr(k) = '--savetest' then SaveDisabled := False;   // test hook: allow checkpoints in --shot runs
  if ForceTitle then GoTitle
  else if ForceMenu then OpenMenu
  else if (ShotFile = '') and not MapGiven then GoTitle;
  for k := 1 to ParamCount do
    if ParamStr(k) = '--continue' then ContinueGame;   // test hook / shortcut
  for k := 1 to ParamCount do
  begin
    if ParamStr(k) = '--sound' then SoundMuted := False;
    if ParamStr(k) = '--herotest' then HeroTest := True;
  end;
  if HeroTest then
  begin
    // test hook: start the hero in the enemies' path so he fights
    HeroU.X := 300;
    HeroU.Y := 272;
  end;
  Speed2x := False;
  GameTime := 0;
  LastTicks := SDL_GetTicks;
  Running := True;

  while Running do
  begin
    while SDL_PollEvent(@Event) do
    begin
      SDL_ConvertEventToRenderCoordinates(Renderer, @Event);
      case Event._type of
        SDL_EVENT_QUIT:
          Running := False;
        SDL_EVENT_KEY_DOWN:
          if Event.key.key = SDLK_F11 then
          begin
            OptFullscreen := not OptFullscreen;
            ApplyFullscreen;
            SaveOptions;
          end
          else if OptionsOpen then
            OptionsKey(Event.key.key)
          else if State = gsTitle then
            TitleKey(Event.key.key)
          else if State = gsMenu then
            MenuKey(Event.key.key, Running)
          else if (Event.key.key = SDLK_L) and (Paused or (State <> gsPlaying)) then
            OpenMenu
          else if Event.key.key = SDLK_ESCAPE then
          begin
            if (SelPlot >= 0) or RallyMode or (SpellMode <> SP_NONE) then CancelModes
            else if State = gsPlaying then Paused := not Paused;
          end
          else if Event.key.key = SDLK_P then
          begin
            if State = gsPlaying then Paused := not Paused;
          end
          else if Event.key.key = SDLK_F then
            Speed2x := not Speed2x
          else if Event.key.key = SDLK_M then
            SoundMuted := not SoundMuted
          else if Event.key.key = SDLK_F5 then
          begin
            SDL_SetRenderLogicalPresentation(Renderer, SCR_W, SCR_H, SDL_LOGICAL_PRESENTATION_DISABLED);
            if LoadAll(Err) then
            begin
              ResetGame;
              BannerText := 'Data reloaded';
            end
            else
              SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'Reload failed', PAnsiChar(Err), Window);
            SDL_SetRenderLogicalPresentation(Renderer, SCR_W, SCR_H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
          end
          else if (Event.key.key = SDLK_Q) and (Paused or (State <> gsPlaying)) then
            Running := False
          else if (Event.key.key = SDLK_R) and (Paused or (State <> gsPlaying)) then
            ResetGame
          else if not Paused and (State = gsPlaying) then
          begin
            if Event.key.key = SDLK_SPACE then StartNextWave
            else if Event.key.key = SDLK_1 then ToggleSpell(SP_FIRE)
            else if Event.key.key = SDLK_2 then ToggleSpell(SP_REINF)
            else if Event.key.key = SDLK_H then SelectHero(not HeroU.Selected)
            else if Event.key.key = SDLK_3 then CastSlam
            else if Event.key.key = SDLK_4 then CastHammer;
          end;
        SDL_EVENT_MOUSE_MOTION:
          begin
            MouseX := Event.motion.x;
            MouseY := Event.motion.y;
          end;
        SDL_EVENT_MOUSE_BUTTON_DOWN:
          begin
            MouseX := Event.button.x;
            MouseY := Event.button.y;
            if Event.button.button = SDL_BUTTON_LEFT then HandleClick(Event.button.x, Event.button.y)
            else if Event.button.button = SDL_BUTTON_RIGHT then CancelModes;
          end;
      end;
    end;

    NowTicks := SDL_GetTicks;
    Dt := (NowTicks - LastTicks) / 1000.0;
    LastTicks := NowTicks;
    if Dt > 0.05 then Dt := 0.05;
    if ShotFile <> '' then Dt := 1 / 30;   // deterministic fast-forward

    if (State = gsPlaying) and not Paused then
    begin
      if Speed2x then Steps := 2 else Steps := 1;
      for k := 1 to Steps do
      begin
        GameTime := GameTime + Dt;
        if FireCd > 0 then FireCd := FireCd - Dt;
        if ReinfCd > 0 then ReinfCd := ReinfCd - Dt;
        UpdateWaves(Dt);
        UpdateEnemies(Dt);
        UpdateSoldiers(Dt);
        UpdateHero(Dt);
        UpdateTowers(Dt);
        UpdateProjectiles(Dt);
        UpdateParticles(Dt);
        if State <> gsPlaying then Break;
      end;
    end
    else if State <> gsPlaying then
    begin
      GameTime := GameTime + Dt;
      if State <> gsMenu then UpdateParticles(Dt);
    end;
    SfxUpdate(Dt);
    if State in [gsMenu, gsTitle] then PrevState := State;
    if QuitRequested then Running := False;
    UpdateMusic;
    if (State <> PrevState) and (State in [gsWon, gsLost]) then DeleteSave;
    if (State <> PrevState) and (State = gsWon) then PlaySound(sndVictory, 1.0, 0);
    if (State <> PrevState) and (State = gsLost) then PlaySound(sndDefeat, 1.0, 0);
    PrevState := State;
    if BannerTime > 0 then BannerTime := BannerTime - Dt;
    if HurtFlash > 0 then HurtFlash := HurtFlash - Dt;
    if Shake > 0 then Shake := Max(0, Shake - Dt * 25);

    SDL_SetRenderDrawColor(Renderer, 0, 0, 0, 255);
    SDL_RenderClear(Renderer);
    if not OptShake then Shake := 0;
    SetLength(UIButtons, 0);
    OfsX := RandF(-Shake, Shake);
    OfsY := RandF(-Shake, Shake);
    if State = gsTitle then
      DrawTitle
    else if State = gsMenu then
      DrawMenu
    else
    begin
      DrawWorld;
      OfsX := 0;
      OfsY := 0;
      DrawParticles(True);
      DrawHud;
      DrawOverlay;
    end;
    OfsX := 0;
    OfsY := 0;
    if OptionsOpen then DrawOptions;
    if (ShotFile <> '') and HeroTest and (GameTime >= ShotTime - 0.6) and (HeroU.SlamCd <= 0) then
    begin
      CastSlam;
      CastHammer;
      SelectHero(True);
    end;
    if (ShotFile <> '') and (GameTime >= ShotTime) then
    begin
      SaveScreenshot(ShotFile);
      Running := False;
    end;
    SDL_RenderPresent(Renderer);
  end;

  FreeMenu;
  SfxDone;
  GfxDone;
  Geo.Free;
  SDL_DestroyTexture(BgTex);
  SDL_DestroyRenderer(Renderer);
  SDL_DestroyWindow(Window);
  SDL_Quit;
end.
