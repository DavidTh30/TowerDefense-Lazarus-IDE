unit gamedata;

{ Game definitions loaded from JSON files in the data folder:
    rules.json      global rules, spells (abilities), soldier mechanics
    towers.json     tower types, levels, ranges, costs, projectiles
    enemies.json    enemy types, stats, gold rewards, death effects
    waves.json      wave composition
    maps/<name>.json  road paths, tower plots, decoration, colours
    geometry.json   vector art for every object (see geometry.pas) }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, StrUtils, fpjson, jsonparser, gfx, geometry;

const
  // tower behaviours
  TB_ARROW = 0;
  TB_BOLT = 1;
  TB_BOMB = 2;
  TB_BARRACKS = 3;

type
  TTowerLevel = record
    Range, Damage, Rate, Splash, SoldierHp: Single;
    Cost: Integer;      // build cost for level 1, upgrade cost for higher levels
  end;

  TTowerDef = record
    Id, Name, Desc, Geometry, Projectile: string;
    Behavior: Integer;
    HitsAir, Magic: Boolean;
    MuzzleY, ProjSpeed, ProjArc, ProjTime: Single;
    FireSound, HitSound: string;
    Soldiers: Integer;
    Levels: array of TTowerLevel;
    GeoIdx, ProjGeoIdx: Integer;         // resolved at load time
  end;

  TEnemyDef = record
    Id, Name, Desc, Geometry: string;
    Hp, Speed, Armor, Dmg: Single;
    Gold, LivesCost: Integer;
    Radius, HitY, BarY, BarW: Single;
    Flying, ExplodeOnDeath: Boolean;
    DeathSound: string;
    DeathColor: TRGBA;
    GeoIdx: Integer;
  end;

  TRules = record
    StartGold, StartLives: Integer;
    WaveGap, EarlyBonusPerSec, EarlyCooldownCut: Single;
    HpGrowth, HpGrowthQuad, DmgGrowth, SellRatio: Single;
  end;

  TFireSpell = record
    Name, Desc, Geometry: string;
    Cooldown: Single;
    Meteors: Integer;
    DmgBase, DmgPerWave, Splash, SpreadX, SpreadY, Delay, FallTime: Single;
    GeoIdx: Integer;
  end;

  TReinfSpell = record
    Name, Desc, Geometry: string;
    Cooldown: Single;
    Count: Integer;
    HpBase, HpPerWave, DmgBase, DmgPerWave, Lifetime: Single;
    GeoIdx: Integer;
  end;

  TSoldierRules = record
    Geometry: string;
    Walk, Engage, Leash, Respawn, AttackRate, RegenFrac: Single;
    GeoIdx: Integer;
  end;

  THeroLevel = record
    Hp, Damage, Rate, Armor: Single;
    Xp: Integer;                 // total xp needed to reach this level
  end;

  THeroAbility = record
    Name, Desc, Sound, Geometry: string;
    Cooldown, Radius, Damage, DamagePerLevel, Stun, Splash: Single;
    SoundIdx, GeoIdx: Integer;
  end;

  THeroDef = record
    Enabled: Boolean;
    Name, Desc, Geometry: string;
    Speed, Engage, Respawn, Regen, XpPerGold: Single;
    Levels: array of THeroLevel;
    Slam, Hammer: THeroAbility;   // Slam.Radius = area, Hammer.Radius = throw range
    GeoIdx: Integer;
  end;

  TWaveGroup = record
    Enemy, Count, Path: Integer;
    Start, Interval: Single;
  end;

  TWaveDef = record
    Groups: array of TWaveGroup;
  end;
  TWaveArray = array of TWaveDef;

  TMapPath = record
    EntranceX, EntranceY: Single;
    Ctrl: array of Single;          // x,y pairs (Catmull-Rom control points)
  end;

  TMapDecor = record
    Geo: string;
    X, Y, S: Single;
    GeoIdx: Integer;
  end;

  TMapDef = record
    Name, Desc: string;
    WavesFile: string;               // waves for this map (default waves.json)
    Music: string;                   // song in data\music (empty = silence)
    Width, Height, Seed: Integer;
    Ground, GroundDark, GroundLight, RoadBorder, RoadEdge, RoadSand, RoadLight: TRGBA;
    PathHalf: Single;
    Fortress: Boolean;
    HeroX, HeroY: Single;            // hero spawn; 0,0 = automatic
    Paths: array of TMapPath;
    PlotX, PlotY: array of Single;
    Decor: array of TMapDecor;
  end;

var
  DataDir: string;
  Rules: TRules;
  FireSpell: TFireSpell;
  Reinf: TReinfSpell;
  SoldierRules: TSoldierRules;
  TowerDefs: array of TTowerDef;
  EnemyDefs: array of TEnemyDef;
  Waves: TWaveArray;
  Map: TMapDef;
  Hero: THeroDef;
  Geo: TGeoLib;

function LoadGameData(const dir, mapName: string; out err: string): Boolean;
function FindEnemyDef(const id: string): Integer;

// maps (also used by MapEdit)
function LoadMapFile(const fn: string; var m: TMapDef; out err: string): Boolean;
function SaveMapFile(const fn: string; const m: TMapDef): Boolean;
function MapToJSON(const m: TMapDef): string;
function MapFromJSONText(const txt: string; var m: TMapDef; out err: string): Boolean;
function NewMapDef(const name: string): TMapDef;

// waves (also used by WaveEdit)
function WavesToJSON(const w: TWaveArray): string;
function WavesFromJSONText(const txt: string; var w: TWaveArray; out err: string): Boolean;
function SaveWavesFile(const fn: string; const w: TWaveArray): Boolean;

// towers / enemies / rules (also used by StatEdit)
function TowersToJSON: string;
function EnemiesToJSON: string;
function RulesToJSON: string;
function TowersFromJSONText(const txt: string; out err: string): Boolean;
function EnemiesFromJSONText(const txt: string; out err: string): Boolean;
function RulesFromJSONText(const txt: string; out err: string): Boolean;
function SaveTextFile(const fn, txt: string): Boolean;
function BehaviorName(b: Integer): string;

// hero (also used by StatEdit)
function HeroToJSON: string;
function HeroFromJSONText(const txt: string; out err: string): Boolean;

implementation

function LoadJSONFile(const fn: string; out err: string): TJSONObject;
var
  sl: TStringList;
  d: TJSONData;
begin
  Result := nil;
  if not FileExists(fn) then
  begin
    err := 'Missing data file: ' + fn;
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
  if d.JSONType <> jtObject then
  begin
    d.Free;
    err := 'Top level of ' + ExtractFileName(fn) + ' must be an object';
    Exit;
  end;
  Result := TJSONObject(d);
end;

function Obj(o: TJSONObject; const key: string): TJSONObject;
var
  d: TJSONData;
begin
  Result := nil;
  if o = nil then Exit;
  d := o.Find(key);
  if (d <> nil) and (d.JSONType = jtObject) then Result := TJSONObject(d);
end;

function Arr(o: TJSONObject; const key: string): TJSONArray;
var
  d: TJSONData;
begin
  Result := nil;
  if o = nil then Exit;
  d := o.Find(key);
  if (d <> nil) and (d.JSONType = jtArray) then Result := TJSONArray(d);
end;

function F(o: TJSONObject; const key: string; def: Single = 0): Single;
var
  d: TJSONData;
begin
  Result := def;
  if o = nil then Exit;
  d := o.Find(key);
  if (d <> nil) and (d.JSONType = jtNumber) then Result := d.AsFloat;
end;

function I(o: TJSONObject; const key: string; def: Integer = 0): Integer;
begin
  Result := Round(F(o, key, def));
end;

function S(o: TJSONObject; const key: string; const def: string = ''): string;
var
  d: TJSONData;
begin
  Result := def;
  if o = nil then Exit;
  d := o.Find(key);
  if (d <> nil) and (d.JSONType = jtString) then Result := d.AsString;
end;

function B(o: TJSONObject; const key: string; def: Boolean = False): Boolean;
var
  d: TJSONData;
begin
  Result := def;
  if o = nil then Exit;
  d := o.Find(key);
  if (d <> nil) and (d.JSONType = jtBoolean) then Result := d.AsBoolean;
end;

function C(o: TJSONObject; const key: string; const def: TRGBA): TRGBA;
begin
  Result := ParseColor(S(o, key, ''), def);
end;

function FindEnemyDef(const id: string): Integer;
var
  k: Integer;
begin
  for k := 0 to High(EnemyDefs) do
    if SameText(EnemyDefs[k].Id, id) then Exit(k);
  Result := -1;
end;

function GeoIndex(const name, what: string; var err: string): Integer;
begin
  Result := Geo.Find(name);
  if (Result < 0) and (name <> '') and (err = '') then
    err := 'Geometry object "' + name + '" (used by ' + what + ') not found in geometry.json';
end;

function ParseRules(root: TJSONObject; out err: string): Boolean;
var
  o: TJSONObject;
begin
  Result := False;
  err := '';
  begin
    o := Obj(root, 'rules');
    Rules.StartGold := I(o, 'startGold', 260);
    Rules.StartLives := I(o, 'startLives', 20);
    Rules.WaveGap := F(o, 'waveGap', 22);
    Rules.EarlyBonusPerSec := F(o, 'earlyBonusPerSecond', 1.5);
    Rules.EarlyCooldownCut := F(o, 'earlyCallCooldownCut', 0.3);
    Rules.HpGrowth := F(o, 'enemyHpGrowthPerWave', 0.12);
    Rules.HpGrowthQuad := F(o, 'enemyHpGrowthQuadratic', 0.006);
    Rules.DmgGrowth := F(o, 'enemyDamageGrowthPerWave', 0.05);
    Rules.SellRatio := F(o, 'sellRefundRatio', 0.6);

    o := Obj(Obj(root, 'abilities'), 'rainOfFire');
    FireSpell.Name := S(o, 'name', 'Rain of Fire');
    FireSpell.Desc := S(o, 'description');
    FireSpell.Geometry := S(o, 'geometry', 'proj.meteor');
    FireSpell.Cooldown := F(o, 'cooldown', 45);
    FireSpell.Meteors := I(o, 'meteors', 6);
    FireSpell.DmgBase := F(o, 'damage', 40);
    FireSpell.DmgPerWave := F(o, 'damagePerWave', 6);
    FireSpell.Splash := F(o, 'splashRadius', 52);
    FireSpell.SpreadX := F(o, 'spreadX', 55);
    FireSpell.SpreadY := F(o, 'spreadY', 35);
    FireSpell.Delay := F(o, 'delayBetween', 0.16);
    FireSpell.FallTime := F(o, 'fallTime', 0.65);

    o := Obj(Obj(root, 'abilities'), 'reinforcements');
    Reinf.Name := S(o, 'name', 'Reinforcements');
    Reinf.Desc := S(o, 'description');
    Reinf.Geometry := S(o, 'geometry', 'unit.militia');
    Reinf.Cooldown := F(o, 'cooldown', 18);
    Reinf.Count := I(o, 'count', 2);
    Reinf.HpBase := F(o, 'hp', 70);
    Reinf.HpPerWave := F(o, 'hpPerWave', 6);
    Reinf.DmgBase := F(o, 'damage', 6);
    Reinf.DmgPerWave := F(o, 'damagePerWave', 0.5);
    Reinf.Lifetime := F(o, 'lifetime', 25);

    o := Obj(root, 'soldier');
    SoldierRules.Geometry := S(o, 'geometry', 'unit.knight');
    SoldierRules.Walk := F(o, 'walkSpeed', 85);
    SoldierRules.Engage := F(o, 'engageRange', 75);
    SoldierRules.Leash := F(o, 'leashRange', 120);
    SoldierRules.Respawn := F(o, 'respawnTime', 10);
    SoldierRules.AttackRate := F(o, 'attackInterval', 0.9);
    SoldierRules.RegenFrac := F(o, 'idleRegenPerSecond', 0.06);
    Result := True;
  end;
end;

function LoadRules(const fn: string; out err: string): Boolean;
var
  root: TJSONObject;
begin
  Result := False;
  root := LoadJSONFile(fn, err);
  if root = nil then Exit;
  try
    Result := ParseRules(root, err);
  finally
    root.Free;
  end;
end;

function BehaviorFromStr(const s: string): Integer;
begin
  if SameText(s, 'bolt') then Result := TB_BOLT
  else if SameText(s, 'bomb') then Result := TB_BOMB
  else if SameText(s, 'barracks') then Result := TB_BARRACKS
  else Result := TB_ARROW;
end;

function ParseTowers(root: TJSONObject; out err: string): Boolean;
var
  o, lv: TJSONObject;
  a, la: TJSONArray;
  k, j: Integer;
begin
  Result := False;
  err := '';
  begin
    a := Arr(root, 'towers');
    if (a = nil) or (a.Count = 0) then
    begin
      err := 'towers.json: "towers" array missing or empty';
      Exit;
    end;
    SetLength(TowerDefs, a.Count);
    for k := 0 to a.Count - 1 do
    begin
      o := TJSONObject(a.Items[k]);
      with TowerDefs[k] do
      begin
        Id := S(o, 'id');
        Name := S(o, 'name', Id);
        Desc := S(o, 'description');
        Geometry := S(o, 'geometry');
        Projectile := S(o, 'projectile');
        Behavior := BehaviorFromStr(S(o, 'behavior', 'arrow'));
        HitsAir := B(o, 'hitsAir', True);
        Magic := B(o, 'magic', False);
        MuzzleY := F(o, 'muzzleY', 50);
        ProjSpeed := F(o, 'projectileSpeed', 600);
        ProjArc := F(o, 'projectileArc', 0);
        ProjTime := F(o, 'flightTime', 1);
        FireSound := S(o, 'fireSound');
        HitSound := S(o, 'hitSound');
        Soldiers := I(o, 'soldiers', 3);
        la := Arr(o, 'levels');
        if (la = nil) or (la.Count = 0) then
        begin
          err := 'towers.json: tower "' + Id + '" has no levels';
          Exit;
        end;
        SetLength(Levels, la.Count);
        for j := 0 to la.Count - 1 do
        begin
          lv := TJSONObject(la.Items[j]);
          Levels[j].Range := F(lv, 'range', 150);
          Levels[j].Damage := F(lv, 'damage', 10);
          Levels[j].Rate := F(lv, 'fireInterval', 1);
          Levels[j].Splash := F(lv, 'splashRadius', 0);
          Levels[j].SoldierHp := F(lv, 'soldierHp', 50);
          Levels[j].Cost := I(lv, 'cost', 100);
        end;
      end;
    end;
    Result := True;
  end;
end;

function LoadTowers(const fn: string; out err: string): Boolean;
var
  root: TJSONObject;
begin
  Result := False;
  root := LoadJSONFile(fn, err);
  if root = nil then Exit;
  try
    Result := ParseTowers(root, err);
  finally
    root.Free;
  end;
end;

function ParseEnemies(root: TJSONObject; out err: string): Boolean;
var
  o: TJSONObject;
  a: TJSONArray;
  k: Integer;
begin
  Result := False;
  err := '';
  begin
    a := Arr(root, 'enemies');
    if (a = nil) or (a.Count = 0) then
    begin
      err := 'enemies.json: "enemies" array missing or empty';
      Exit;
    end;
    SetLength(EnemyDefs, a.Count);
    for k := 0 to a.Count - 1 do
    begin
      o := TJSONObject(a.Items[k]);
      with EnemyDefs[k] do
      begin
        Id := S(o, 'id');
        Name := S(o, 'name', Id);
        Desc := S(o, 'description');
        Geometry := S(o, 'geometry');
        Hp := F(o, 'hp', 40);
        Speed := F(o, 'speed', 35);
        Armor := F(o, 'armor', 0);
        Dmg := F(o, 'damage', 3);
        Gold := I(o, 'gold', 5);
        LivesCost := I(o, 'livesCost', 1);
        Radius := F(o, 'radius', 10);
        Flying := B(o, 'flying', False);
        HitY := F(o, 'hitY', Radius);
        BarY := F(o, 'healthBarY', 38);
        BarW := F(o, 'healthBarWidth', 22);
        ExplodeOnDeath := B(o, 'explodeOnDeath', False);
        DeathSound := S(o, 'deathSound');
        DeathColor := C(o, 'deathColor', RGBA(150, 20, 20));
      end;
    end;
    Result := True;
  end;
end;

function LoadEnemies(const fn: string; out err: string): Boolean;
var
  root: TJSONObject;
begin
  Result := False;
  root := LoadJSONFile(fn, err);
  if root = nil then Exit;
  try
    Result := ParseEnemies(root, err);
  finally
    root.Free;
  end;
end;

function ParseWaves(root: TJSONObject; var w: TWaveArray; out err: string): Boolean;
var
  o, g: TJSONObject;
  a, ga: TJSONArray;
  k, j: Integer;
begin
  Result := False;
  err := '';
  a := Arr(root, 'waves');
  if (a = nil) or (a.Count = 0) then
  begin
    err := 'waves.json: "waves" array missing or empty';
    Exit;
  end;
  SetLength(w, a.Count);
  for k := 0 to a.Count - 1 do
  begin
    o := TJSONObject(a.Items[k]);
    ga := Arr(o, 'groups');
    if ga = nil then
    begin
      SetLength(w[k].Groups, 0);
      Continue;
    end;
    SetLength(w[k].Groups, ga.Count);
    for j := 0 to ga.Count - 1 do
    begin
      g := TJSONObject(ga.Items[j]);
      w[k].Groups[j].Enemy := FindEnemyDef(S(g, 'enemy'));
      if w[k].Groups[j].Enemy < 0 then
      begin
        err := Format('waves.json: wave %d uses unknown enemy "%s"', [k + 1, S(g, 'enemy')]);
        Exit;
      end;
      w[k].Groups[j].Count := I(g, 'count', 1);
      w[k].Groups[j].Path := I(g, 'path', 0);
      w[k].Groups[j].Start := F(g, 'start', 0);
      w[k].Groups[j].Interval := F(g, 'interval', 1);
    end;
  end;
  Result := True;
end;

function LoadWaves(const fn: string; out err: string): Boolean;
var
  root: TJSONObject;
begin
  Result := False;
  root := LoadJSONFile(fn, err);
  if root = nil then Exit;
  try
    Result := ParseWaves(root, Waves, err);
  finally
    root.Free;
  end;
end;

function WavesFromJSONText(const txt: string; var w: TWaveArray; out err: string): Boolean;
var
  d: TJSONData;
begin
  Result := False;
  err := '';
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
    if d.JSONType = jtObject then Result := ParseWaves(TJSONObject(d), w, err)
    else err := 'not a JSON object';
  finally
    d.Free;
  end;
end;

function WavesToJSON(const w: TWaveArray): string;
var
  sb: TStringList;
  k, j: Integer;
  line, id: string;
begin
  sb := TStringList.Create;
  try
    sb.Add('{"waves": [');
    for k := 0 to High(w) do
    begin
      sb.Add('  {"groups": [');
      for j := 0 to High(w[k].Groups) do
      begin
        if (w[k].Groups[j].Enemy >= 0) and (w[k].Groups[j].Enemy <= High(EnemyDefs)) then
          id := EnemyDefs[w[k].Groups[j].Enemy].Id
        else
          id := '?';
        line := Format('    {"enemy": "%s", "count": %d, "path": %d, "start": %s, "interval": %s}',
          [id, w[k].Groups[j].Count, w[k].Groups[j].Path, FmtNum(w[k].Groups[j].Start),
           FmtNum(w[k].Groups[j].Interval)]);
        if j < High(w[k].Groups) then line := line + ',';
        sb.Add(line);
      end;
      line := '  ]}';
      if k < High(w) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add(']}');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

function SaveWavesFile(const fn: string; const w: TWaveArray): Boolean;
var
  sl: TStringList;
begin
  Result := False;
  sl := TStringList.Create;
  try
    sl.Text := WavesToJSON(w);
    try
      sl.SaveToFile(fn);
      Result := True;
    except
      Result := False;
    end;
  finally
    sl.Free;
  end;
end;

function ParseMap(root: TJSONObject; var m: TMapDef; const src: string; out err: string): Boolean;
var
  o, col: TJSONObject;
  a, pa, pt: TJSONArray;
  k, j: Integer;
begin
  Result := False;
  err := '';
  m.Name := S(root, 'name', 'Map');
  m.Desc := S(root, 'description');
  m.WavesFile := S(root, 'waves', 'waves.json');
  m.Music := S(root, 'music', '');
  m.Width := I(root, 'width', 1280);
  m.Height := I(root, 'height', 720);
  m.Seed := I(root, 'backgroundSeed', 99);
  m.PathHalf := F(root, 'roadHalfWidth', 34);
  m.Fortress := B(root, 'fortress', True);
  m.HeroX := 0;
  m.HeroY := 0;
  pt := Arr(root, 'heroSpawn');
  if (pt <> nil) and (pt.Count >= 2) then
  begin
    m.HeroX := pt.Items[0].AsFloat;
    m.HeroY := pt.Items[1].AsFloat;
  end;
  col := Obj(root, 'colors');
  m.Ground := C(col, 'ground', RGBA(112, 74, 46));
  m.GroundDark := C(col, 'groundDark', RGBA(90, 56, 34, 40));
  m.GroundLight := C(col, 'groundLight', RGBA(140, 96, 60, 30));
  m.RoadBorder := C(col, 'roadBorder', RGBA(70, 44, 26));
  m.RoadEdge := C(col, 'roadEdge', RGBA(150, 108, 66));
  m.RoadSand := C(col, 'roadSand', RGBA(214, 168, 108));
  m.RoadLight := C(col, 'roadLight', RGBA(226, 186, 128, 90));

  a := Arr(root, 'paths');
  if (a = nil) or (a.Count = 0) then
  begin
    err := src + ': "paths" missing';
    Exit;
  end;
  SetLength(m.Paths, a.Count);
  for k := 0 to a.Count - 1 do
  begin
    o := TJSONObject(a.Items[k]);
    pt := Arr(o, 'entrance');
    m.Paths[k].EntranceX := 0;
    m.Paths[k].EntranceY := 0;
    if (pt <> nil) and (pt.Count >= 2) then
    begin
      m.Paths[k].EntranceX := pt.Items[0].AsFloat;
      m.Paths[k].EntranceY := pt.Items[1].AsFloat;
    end;
    pa := Arr(o, 'points');
    if (pa = nil) or (pa.Count < 2) then
    begin
      err := Format('%s: path %d needs at least 2 points', [src, k]);
      Exit;
    end;
    SetLength(m.Paths[k].Ctrl, pa.Count * 2);
    for j := 0 to pa.Count - 1 do
    begin
      pt := TJSONArray(pa.Items[j]);
      m.Paths[k].Ctrl[j * 2] := pt.Items[0].AsFloat;
      m.Paths[k].Ctrl[j * 2 + 1] := pt.Items[1].AsFloat;
    end;
  end;

  a := Arr(root, 'plots');
  if a = nil then k := 0 else k := a.Count;
  SetLength(m.PlotX, k);
  SetLength(m.PlotY, k);
  for k := 0 to High(m.PlotX) do
  begin
    pt := TJSONArray(a.Items[k]);
    m.PlotX[k] := pt.Items[0].AsFloat;
    m.PlotY[k] := pt.Items[1].AsFloat;
  end;

  a := Arr(root, 'decor');
  if a = nil then k := 0 else k := a.Count;
  SetLength(m.Decor, k);
  for k := 0 to High(m.Decor) do
  begin
    o := TJSONObject(a.Items[k]);
    m.Decor[k].Geo := S(o, 'geometry');
    m.Decor[k].X := F(o, 'x');
    m.Decor[k].Y := F(o, 'y');
    m.Decor[k].S := F(o, 'scale', 1);
    m.Decor[k].GeoIdx := -1;
  end;
  Result := True;
end;

function LoadMapFile(const fn: string; var m: TMapDef; out err: string): Boolean;
var
  root: TJSONObject;
begin
  Result := False;
  root := LoadJSONFile(fn, err);
  if root = nil then Exit;
  try
    Result := ParseMap(root, m, ExtractFileName(fn), err);
  finally
    root.Free;
  end;
end;

function MapFromJSONText(const txt: string; var m: TMapDef; out err: string): Boolean;
var
  d: TJSONData;
begin
  Result := False;
  err := '';
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
    if d.JSONType = jtObject then Result := ParseMap(TJSONObject(d), m, 'map', err)
    else err := 'not a JSON object';
  finally
    d.Free;
  end;
end;

function QStr(const t: string): string;
begin
  Result := '"' + StringToJSONString(t) + '"';
end;

function MapToJSON(const m: TMapDef): string;
var
  sb: TStringList;
  k, j: Integer;
  line: string;
begin
  sb := TStringList.Create;
  try
    sb.Add('{');
    sb.Add('  "name": ' + QStr(m.Name) + ',');
    if m.Desc <> '' then sb.Add('  "description": ' + QStr(m.Desc) + ',');
    if (m.WavesFile <> '') and not SameText(m.WavesFile, 'waves.json') then
      sb.Add('  "waves": ' + QStr(m.WavesFile) + ',');
    if m.Music <> '' then sb.Add('  "music": ' + QStr(m.Music) + ',');
    sb.Add('  "width": ' + IntToStr(m.Width) + ',');
    sb.Add('  "height": ' + IntToStr(m.Height) + ',');
    sb.Add('  "backgroundSeed": ' + IntToStr(m.Seed) + ',');
    sb.Add('  "roadHalfWidth": ' + FmtNum(m.PathHalf) + ',');
    sb.Add('  "fortress": ' + BoolToStr(m.Fortress, 'true', 'false') + ',');
    if (m.HeroX <> 0) or (m.HeroY <> 0) then
      sb.Add('  "heroSpawn": [' + FmtNum(m.HeroX) + ', ' + FmtNum(m.HeroY) + '],');
    sb.Add('  "colors": {');
    sb.Add('    "ground": ' + QStr(ColorToStr(m.Ground)) + ', "groundDark": ' + QStr(ColorToStr(m.GroundDark)) +
      ', "groundLight": ' + QStr(ColorToStr(m.GroundLight)) + ',');
    sb.Add('    "roadBorder": ' + QStr(ColorToStr(m.RoadBorder)) + ', "roadEdge": ' + QStr(ColorToStr(m.RoadEdge)) +
      ', "roadSand": ' + QStr(ColorToStr(m.RoadSand)) + ', "roadLight": ' + QStr(ColorToStr(m.RoadLight)));
    sb.Add('  },');
    sb.Add('  "paths": [');
    for k := 0 to High(m.Paths) do
    begin
      line := '    {"entrance": [' + FmtNum(m.Paths[k].EntranceX) + ', ' + FmtNum(m.Paths[k].EntranceY) +
        '], "points": [';
      for j := 0 to Length(m.Paths[k].Ctrl) div 2 - 1 do
      begin
        if j > 0 then line := line + ', ';
        line := line + '[' + FmtNum(m.Paths[k].Ctrl[j * 2]) + ', ' + FmtNum(m.Paths[k].Ctrl[j * 2 + 1]) + ']';
      end;
      line := line + ']}';
      if k < High(m.Paths) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add('  ],');
    sb.Add('  "plots": [');
    for k := 0 to High(m.PlotX) do
    begin
      line := '    [' + FmtNum(m.PlotX[k]) + ', ' + FmtNum(m.PlotY[k]) + ']';
      if k < High(m.PlotX) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add('  ],');
    sb.Add('  "decor": [');
    for k := 0 to High(m.Decor) do
    begin
      line := '    {"geometry": ' + QStr(m.Decor[k].Geo) + ', "x": ' + FmtNum(m.Decor[k].X) + ', "y": ' +
        FmtNum(m.Decor[k].Y) + ', "scale": ' + FmtNum(m.Decor[k].S) + '}';
      if k < High(m.Decor) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add('  ]');
    sb.Add('}');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

function SaveMapFile(const fn: string; const m: TMapDef): Boolean;
var
  sl: TStringList;
begin
  Result := False;
  sl := TStringList.Create;
  try
    sl.Text := MapToJSON(m);
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

function NewMapDef(const name: string): TMapDef;
begin
  Result := Default(TMapDef);
  Result.Name := name;
  Result.WavesFile := 'waves.json';
  Result.Width := 1280;
  Result.Height := 720;
  Result.Seed := 1 + Random(999);
  Result.PathHalf := 34;
  Result.Fortress := True;
  Result.Ground := RGBA(112, 74, 46);
  Result.GroundDark := RGBA(90, 56, 34, 40);
  Result.GroundLight := RGBA(140, 96, 60, 30);
  Result.RoadBorder := RGBA(70, 44, 26);
  Result.RoadEdge := RGBA(150, 108, 66);
  Result.RoadSand := RGBA(214, 168, 108);
  Result.RoadLight := RGBA(226, 186, 128, 90);
  SetLength(Result.Paths, 1);
  Result.Paths[0].EntranceX := 34;
  Result.Paths[0].EntranceY := 360;
  SetLength(Result.Paths[0].Ctrl, 10);
  Result.Paths[0].Ctrl[0] := -70;  Result.Paths[0].Ctrl[1] := 360;
  Result.Paths[0].Ctrl[2] := 300;  Result.Paths[0].Ctrl[3] := 360;
  Result.Paths[0].Ctrl[4] := 640;  Result.Paths[0].Ctrl[5] := 300;
  Result.Paths[0].Ctrl[6] := 980;  Result.Paths[0].Ctrl[7] := 360;
  Result.Paths[0].Ctrl[8] := 1350; Result.Paths[0].Ctrl[9] := 356;
end;

function BehaviorName(b: Integer): string;
begin
  case b of
    TB_BOLT: Result := 'bolt';
    TB_BOMB: Result := 'bomb';
    TB_BARRACKS: Result := 'barracks';
  else
    Result := 'arrow';
  end;
end;

function JB2(v: Boolean): string;
begin
  if v then Result := 'true' else Result := 'false';
end;

function TowersToJSON: string;
var
  sb: TStringList;
  k, j: Integer;
  t: TTowerDef;
  line: string;
begin
  sb := TStringList.Create;
  try
    sb.Add('{"towers": [');
    for k := 0 to High(TowerDefs) do
    begin
      t := TowerDefs[k];
      sb.Add('  {"id": ' + QStr(t.Id) + ', "name": ' + QStr(t.Name) + ', "description": ' + QStr(t.Desc) + ',');
      sb.Add('   "behavior": ' + QStr(BehaviorName(t.Behavior)) + ', "geometry": ' + QStr(t.Geometry) +
        ', "projectile": ' + QStr(t.Projectile) + ',');
      sb.Add('   "hitsAir": ' + JB2(t.HitsAir) + ', "magic": ' + JB2(t.Magic) + ', "muzzleY": ' + FmtNum(t.MuzzleY) +
        ', "projectileSpeed": ' + FmtNum(t.ProjSpeed) + ', "projectileArc": ' + FmtNum(t.ProjArc) +
        ', "flightTime": ' + FmtNum(t.ProjTime) + ', "soldiers": ' + IntToStr(t.Soldiers) + ',');
      sb.Add('   "fireSound": ' + QStr(t.FireSound) + ', "hitSound": ' + QStr(t.HitSound) + ',');
      sb.Add('   "levels": [');
      for j := 0 to High(t.Levels) do
      begin
        line := Format('     {"range": %s, "damage": %s, "fireInterval": %s, "splashRadius": %s, "soldierHp": %s, "cost": %d}',
          [FmtNum(t.Levels[j].Range), FmtNum(t.Levels[j].Damage), FmtNum(t.Levels[j].Rate),
           FmtNum(t.Levels[j].Splash), FmtNum(t.Levels[j].SoldierHp), t.Levels[j].Cost]);
        if j < High(t.Levels) then line := line + ',';
        sb.Add(line);
      end;
      line := '   ]}';
      if k < High(TowerDefs) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add(']}');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

function EnemiesToJSON: string;
var
  sb: TStringList;
  k: Integer;
  e: TEnemyDef;
  line: string;
begin
  sb := TStringList.Create;
  try
    sb.Add('{"enemies": [');
    for k := 0 to High(EnemyDefs) do
    begin
      e := EnemyDefs[k];
      sb.Add('  {"id": ' + QStr(e.Id) + ', "name": ' + QStr(e.Name) + ', "description": ' + QStr(e.Desc) +
        ', "geometry": ' + QStr(e.Geometry) + ',');
      sb.Add(Format('   "hp": %s, "speed": %s, "armor": %s, "damage": %s, "gold": %d, "livesCost": %d,',
        [FmtNum(e.Hp), FmtNum(e.Speed), FmtNum(e.Armor), FmtNum(e.Dmg), e.Gold, e.LivesCost]));
      sb.Add(Format('   "radius": %s, "flying": %s, "hitY": %s, "healthBarY": %s, "healthBarWidth": %s,',
        [FmtNum(e.Radius), JB2(e.Flying), FmtNum(e.HitY), FmtNum(e.BarY), FmtNum(e.BarW)]));
      line := '   "explodeOnDeath": ' + JB2(e.ExplodeOnDeath) + ', "deathSound": ' + QStr(e.DeathSound) +
        ', "deathColor": ' + QStr(ColorToStr(e.DeathColor)) + '}';
      if k < High(EnemyDefs) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add(']}');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

function RulesToJSON: string;
var
  sb: TStringList;
begin
  sb := TStringList.Create;
  try
    sb.Add('{');
    sb.Add('  "rules": {');
    sb.Add(Format('    "startGold": %d, "startLives": %d, "waveGap": %s,', [Rules.StartGold, Rules.StartLives,
      FmtNum(Rules.WaveGap)]));
    sb.Add(Format('    "earlyBonusPerSecond": %s, "earlyCallCooldownCut": %s,', [FmtNum(Rules.EarlyBonusPerSec),
      FmtNum(Rules.EarlyCooldownCut)]));
    sb.Add(Format('    "enemyHpGrowthPerWave": %s, "enemyHpGrowthQuadratic": %s,', [FmtNum(Rules.HpGrowth),
      FmtNum(Rules.HpGrowthQuad)]));
    sb.Add(Format('    "enemyDamageGrowthPerWave": %s, "sellRefundRatio": %s', [FmtNum(Rules.DmgGrowth),
      FmtNum(Rules.SellRatio)]));
    sb.Add('  },');
    sb.Add('  "abilities": {');
    sb.Add('    "rainOfFire": {"name": ' + QStr(FireSpell.Name) + ', "description": ' + QStr(FireSpell.Desc) +
      ', "geometry": ' + QStr(FireSpell.Geometry) + ',');
    sb.Add(Format('      "cooldown": %s, "meteors": %d, "damage": %s, "damagePerWave": %s, "splashRadius": %s,',
      [FmtNum(FireSpell.Cooldown), FireSpell.Meteors, FmtNum(FireSpell.DmgBase), FmtNum(FireSpell.DmgPerWave),
       FmtNum(FireSpell.Splash)]));
    sb.Add(Format('      "spreadX": %s, "spreadY": %s, "delayBetween": %s, "fallTime": %s},',
      [FmtNum(FireSpell.SpreadX), FmtNum(FireSpell.SpreadY), FmtNum(FireSpell.Delay), FmtNum(FireSpell.FallTime)]));
    sb.Add('    "reinforcements": {"name": ' + QStr(Reinf.Name) + ', "description": ' + QStr(Reinf.Desc) +
      ', "geometry": ' + QStr(Reinf.Geometry) + ',');
    sb.Add(Format('      "cooldown": %s, "count": %d, "hp": %s, "hpPerWave": %s, "damage": %s, "damagePerWave": %s,' +
      ' "lifetime": %s}', [FmtNum(Reinf.Cooldown), Reinf.Count, FmtNum(Reinf.HpBase), FmtNum(Reinf.HpPerWave),
       FmtNum(Reinf.DmgBase), FmtNum(Reinf.DmgPerWave), FmtNum(Reinf.Lifetime)]));
    sb.Add('  },');
    sb.Add('  "soldier": {"geometry": ' + QStr(SoldierRules.Geometry) + Format(', "walkSpeed": %s, "engageRange": %s,' +
      ' "leashRange": %s, "respawnTime": %s, "attackInterval": %s, "idleRegenPerSecond": %s}',
      [FmtNum(SoldierRules.Walk), FmtNum(SoldierRules.Engage), FmtNum(SoldierRules.Leash),
       FmtNum(SoldierRules.Respawn), FmtNum(SoldierRules.AttackRate), FmtNum(SoldierRules.RegenFrac)]));
    sb.Add('}');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

type
  TParseFunc = function(root: TJSONObject; out err: string): Boolean;

function ParseText(const txt: string; fn: TParseFunc; out err: string): Boolean;
var
  d: TJSONData;
begin
  Result := False;
  err := '';
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
    if d.JSONType = jtObject then Result := fn(TJSONObject(d), err)
    else err := 'not a JSON object';
  finally
    d.Free;
  end;
end;

function TowersFromJSONText(const txt: string; out err: string): Boolean;
begin
  Result := ParseText(txt, @ParseTowers, err);
end;

function EnemiesFromJSONText(const txt: string; out err: string): Boolean;
begin
  Result := ParseText(txt, @ParseEnemies, err);
end;

function RulesFromJSONText(const txt: string; out err: string): Boolean;
begin
  Result := ParseText(txt, @ParseRules, err);
end;

function SaveTextFile(const fn, txt: string): Boolean;
var
  sl: TStringList;
begin
  Result := False;
  sl := TStringList.Create;
  try
    sl.Text := txt;
    try
      sl.SaveToFile(fn);
      Result := True;
    except
      Result := False;
    end;
  finally
    sl.Free;
  end;
end;


function ParseAbility(o: TJSONObject; const defName: string): THeroAbility;
begin
  Result.Name := S(o, 'name', defName);
  Result.Desc := S(o, 'description');
  Result.Sound := S(o, 'sound');
  Result.Geometry := S(o, 'geometry');
  Result.Cooldown := F(o, 'cooldown', 10);
  Result.Radius := F(o, 'radius', F(o, 'range', 100));
  Result.Damage := F(o, 'damage', 50);
  Result.DamagePerLevel := F(o, 'damagePerLevel', 0);
  Result.Stun := F(o, 'stun', 0);
  Result.Splash := F(o, 'splash', 0);
  Result.SoundIdx := -1;
  Result.GeoIdx := -1;
end;

function ParseHero(root: TJSONObject; out err: string): Boolean;
var
  la: TJSONArray;
  lv, ab: TJSONObject;
  j: Integer;
begin
  Result := False;
  err := '';
  Hero.Enabled := B(root, 'enabled', True);
  Hero.Name := S(root, 'name', 'Hero');
  Hero.Desc := S(root, 'description');
  Hero.Geometry := S(root, 'geometry', 'unit.hero');
  Hero.Speed := F(root, 'speed', 70);
  Hero.Engage := F(root, 'engageRange', 80);
  Hero.Respawn := F(root, 'respawnTime', 15);
  Hero.Regen := F(root, 'regenPerSecond', 0.03);
  Hero.XpPerGold := F(root, 'xpPerGold', 3);
  la := Arr(root, 'levels');
  if (la = nil) or (la.Count = 0) then
  begin
    err := 'hero.json: "levels" missing';
    Exit;
  end;
  SetLength(Hero.Levels, la.Count);
  for j := 0 to la.Count - 1 do
  begin
    lv := TJSONObject(la.Items[j]);
    Hero.Levels[j].Hp := F(lv, 'hp', 300);
    Hero.Levels[j].Damage := F(lv, 'damage', 15);
    Hero.Levels[j].Rate := F(lv, 'attackInterval', 1);
    Hero.Levels[j].Armor := F(lv, 'armor', 0);
    Hero.Levels[j].Xp := I(lv, 'xp', j * 150);
  end;
  ab := Obj(root, 'abilities');
  Hero.Slam := ParseAbility(Obj(ab, 'slam'), 'Thunder Slam');
  Hero.Hammer := ParseAbility(Obj(ab, 'hammer'), 'Hammer Throw');
  Result := True;
end;

function LoadHero(const fn: string; out err: string): Boolean;
var
  root: TJSONObject;
begin
  Result := False;
  if not FileExists(fn) then
  begin
    // the hero is optional: no file = no hero
    Hero := Default(THeroDef);
    Hero.Enabled := False;
    err := '';
    Exit(True);
  end;
  root := LoadJSONFile(fn, err);
  if root = nil then Exit;
  try
    Result := ParseHero(root, err);
  finally
    root.Free;
  end;
end;

function HeroFromJSONText(const txt: string; out err: string): Boolean;
begin
  Result := ParseText(txt, @ParseHero, err);
end;

function HeroToJSON: string;
var
  sb: TStringList;
  j: Integer;
  line: string;

  function Ab(const key: string; const a: THeroAbility; isHammer, last: Boolean): string;
  begin
    Result := '    "' + key + '": {"name": ' + QStr(a.Name) + ', "description": ' + QStr(a.Desc) + ',' + LineEnding +
      Format('      "cooldown": %s, "%s": %s, "damage": %s, "damagePerLevel": %s, ',
        [FmtNum(a.Cooldown), IfThen(isHammer, 'range', 'radius'), FmtNum(a.Radius), FmtNum(a.Damage),
         FmtNum(a.DamagePerLevel)]);
    if isHammer then
      Result := Result + '"splash": ' + FmtNum(a.Splash) + ', "geometry": ' + QStr(a.Geometry) + ', '
    else
      Result := Result + '"stun": ' + FmtNum(a.Stun) + ', ';
    Result := Result + '"sound": ' + QStr(a.Sound) + '}';
    if not last then Result := Result + ',';
  end;

begin
  sb := TStringList.Create;
  try
    sb.Add('{');
    sb.Add('  "enabled": ' + JB2(Hero.Enabled) + ',');
    sb.Add('  "name": ' + QStr(Hero.Name) + ', "description": ' + QStr(Hero.Desc) + ',');
    sb.Add('  "geometry": ' + QStr(Hero.Geometry) + ',');
    sb.Add(Format('  "speed": %s, "engageRange": %s, "respawnTime": %s, "regenPerSecond": %s, "xpPerGold": %s,',
      [FmtNum(Hero.Speed), FmtNum(Hero.Engage), FmtNum(Hero.Respawn), FmtNum(Hero.Regen), FmtNum(Hero.XpPerGold)]));
    sb.Add('  "levels": [');
    for j := 0 to High(Hero.Levels) do
    begin
      line := Format('    {"hp": %s, "damage": %s, "attackInterval": %s, "armor": %s, "xp": %d}',
        [FmtNum(Hero.Levels[j].Hp), FmtNum(Hero.Levels[j].Damage), FmtNum(Hero.Levels[j].Rate),
         FmtNum(Hero.Levels[j].Armor), Hero.Levels[j].Xp]);
      if j < High(Hero.Levels) then line := line + ',';
      sb.Add(line);
    end;
    sb.Add('  ],');
    sb.Add('  "abilities": {');
    sb.Add(Ab('slam', Hero.Slam, False, False));
    sb.Add(Ab('hammer', Hero.Hammer, True, True));
    sb.Add('  }');
    sb.Add('}');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

function LoadGameData(const dir, mapName: string; out err: string): Boolean;
var
  k: Integer;
begin
  Result := False;
  err := '';
  DataDir := IncludeTrailingPathDelimiter(dir);
  if Geo = nil then Geo := TGeoLib.Create;
  if not Geo.LoadFromFile(DataDir + 'geometry.json', err) then Exit;
  if not LoadRules(DataDir + 'rules.json', err) then Exit;
  if not LoadTowers(DataDir + 'towers.json', err) then Exit;
  if not LoadEnemies(DataDir + 'enemies.json', err) then Exit;
  if not LoadMapFile(DataDir + 'maps' + PathDelim + mapName + '.json', Map, err) then Exit;
  if Map.WavesFile = '' then Map.WavesFile := 'waves.json';
  if not LoadWaves(DataDir + Map.WavesFile, err) then Exit;
  if not LoadHero(DataDir + 'hero.json', err) then Exit;

  // resolve geometry names once, so drawing is just an index lookup
  for k := 0 to High(TowerDefs) do
  begin
    TowerDefs[k].GeoIdx := GeoIndex(TowerDefs[k].Geometry, 'tower ' + TowerDefs[k].Id, err);
    TowerDefs[k].ProjGeoIdx := GeoIndex(TowerDefs[k].Projectile, 'tower ' + TowerDefs[k].Id, err);
  end;
  for k := 0 to High(EnemyDefs) do
    EnemyDefs[k].GeoIdx := GeoIndex(EnemyDefs[k].Geometry, 'enemy ' + EnemyDefs[k].Id, err);
  FireSpell.GeoIdx := GeoIndex(FireSpell.Geometry, 'rainOfFire', err);
  Reinf.GeoIdx := GeoIndex(Reinf.Geometry, 'reinforcements', err);
  SoldierRules.GeoIdx := GeoIndex(SoldierRules.Geometry, 'soldier', err);
  if Hero.Enabled then
  begin
    Hero.GeoIdx := GeoIndex(Hero.Geometry, 'hero', err);
    Hero.Hammer.GeoIdx := GeoIndex(Hero.Hammer.Geometry, 'hero hammer', err);
  end;
  for k := 0 to High(Map.Decor) do
    Map.Decor[k].GeoIdx := GeoIndex(Map.Decor[k].Geo, 'map decor', err);
  Result := err = '';
end;

end.
