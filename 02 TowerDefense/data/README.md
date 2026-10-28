# Brewhold Defense – data files

Everything the game needs lives in this folder as JSON. Edit with any text editor (or **GeoEdit** for
`geometry.json`), then press **F5** in the running game to reload and restart.

| File | Contents |
|---|---|
| `rules.json` | global rules, gold economy, abilities (spells), soldier mechanics |
| `towers.json` | tower types: behaviour, ranges, damage, fire rate, costs per level, projectiles, sounds |
| `enemies.json` | enemy types: health, speed, armor, gold reward, lives cost, death effects |
| `waves.json`, `waves_<map>.json` | which enemies spawn in each wave, on which path, and when (one file per map) |
| `hero.json` | the hero: stats per level (hp, damage, armor, xp), movement, respawn, two abilities |
| `maps/<name>.json` | road paths, entrances, tower plots, decoration, hero spawn, colours, which waves file to use |
| `geometry.json` | vector art (object geometry) for every unit, tower, projectile, plot and decoration |
| `sounds.json` | every sound effect, as synthesiser layers |
| `music/*.json` | songs (tracker patterns + instruments); maps choose theirs with `"music"` |

Editors (all in the project folder, each saves the JSON it owns):

| Program | Edits |
|---|---|
| `geoedit.exe` | `geometry.json` – shapes, animation channels, PNG / sprite-sheet export |
| `mapedit.exe` | `maps/*.json` – roads, entrances, tower plots, decorations, hero spawn, colours, waves file, music |
| `waveedit.exe` | the selected map's waves file – spawn groups, timeline, difficulty chart, live preview |
| `statedit.exe` | `towers.json`, `enemies.json`, `rules.json`, `hero.json` – stats, upgrade levels, sounds, spells, with DPS / time-to-kill / economy analysis; keeps every waves file in step when enemies are renamed or reordered |
| `soundedit.exe` | `sounds.json` (see below) |
| `musicedit.exe` | `music/*.json` (see below) |

Colours are `"#RRGGBB"` or `"#RRGGBBAA"`. Distances are pixels on the 1280×720 map; times are seconds.

## rules.json

```json
"rules": {
  "startGold": 260, "startLives": 20,
  "waveGap": 22,                    // seconds between waves
  "earlyBonusPerSecond": 1.5,       // gold per second remaining when calling a wave early
  "earlyCallCooldownCut": 0.3,      // spell cooldown reduced by this × seconds remaining
  "enemyHpGrowthPerWave": 0.12,     // hp × (1 + g·(wave-1) + q·(wave-1)²)
  "enemyHpGrowthQuadratic": 0.006,
  "enemyDamageGrowthPerWave": 0.05,
  "sellRefundRatio": 0.6            // share of everything spent on a tower returned on sale
}
```

`abilities.rainOfFire`: `cooldown, meteors, damage, damagePerWave, splashRadius, spreadX, spreadY,
delayBetween, fallTime, geometry` (meteor art).
`abilities.reinforcements`: `cooldown, count, hp, hpPerWave, damage, damagePerWave, lifetime, geometry`.
`soldier` (barracks knights): `walkSpeed, engageRange, leashRange, respawnTime, attackInterval,
idleRegenPerSecond, geometry`.

## towers.json

```json
{ "id": "archer", "name": "Archer Tower", "description": "...",
  "behavior": "arrow",            // arrow | bolt | bomb | barracks
  "geometry": "tower.archer", "projectile": "proj.arrow",
  "hitsAir": true, "magic": false,  // magic damage ignores armor
  "muzzleY": 58,                    // projectile spawn height above the plot
  "projectileSpeed": 620,           // arrow / bolt: px per second
  "projectileArc": 0.18,            // arrow/bolt: arc height as fraction of distance; bomb: arc in px
  "flightTime": 1.0,                // bomb: seconds in the air (shells lead their target)
  "soldiers": 3,                    // barracks only
  "fireSound": "arrow", "hitSound": "arrowHit",
  "levels": [ { "range": 155, "damage": 7, "fireInterval": 0.65, "cost": 70,
                "splashRadius": 55,      // bomb
                "soldierHp": 60 }, ... ] }   // barracks
```

Level 1 `cost` is the build price; later levels' `cost` is the upgrade price. Add more entries to
`levels` for more upgrade tiers (geometry shapes can use `minLevel`/`maxLevel`). Towers appear in the
build menu in file order, spread around a ring.

## enemies.json

```json
{ "id": "raider", "name": "Dwarf Raider", "geometry": "enemy.raider",
  "hp": 42, "speed": 36, "armor": 0,      // armor 0..1 = share of physical damage ignored
  "damage": 3,                            // per hit against soldiers (once per second)
  "gold": 5,                              // reward when killed
  "livesCost": 1,                         // lives lost if it reaches the gate
  "radius": 10, "flying": false,          // flyers ignore soldiers and can't be hit by bombs
  "hitY": 10,                             // where projectiles aim, above the feet
  "healthBarY": 38, "healthBarWidth": 22,
  "explodeOnDeath": false, "deathSound": "dieRaider", "deathColor": "#961414" }
```

## waves.json

```json
{ "waves": [ { "groups": [
    { "enemy": "raider", "count": 6, "path": 0, "start": 0, "interval": 1.3 } ] } ] }
```

Each group spawns `count` enemies on `path` (index into the map's `paths`), beginning `start`
seconds into the wave, one every `interval` seconds. The skull markers show the entrances the next
wave will use.

Edit waves with **WaveEdit** (`waveedit.exe [--map <name>]`): a group table per wave, a timeline
with one lane per road (drag spawns to shift a group), a difficulty chart across all waves (effective
HP per enemy type plus gold reward), a live preview of the wave walking the selected map, per-wave
stats, and **F5** to play-test from the selected wave (`towerdefense.exe --wave <n>` starts there
with the gold the earlier waves would have paid).

## maps/brewhold.json

Maps included: **Brewhold** (`brewhold.json`, 2 roads, `waves.json`) and **Frostpeak Pass**
(`frostpeak.json`, 3 roads, `waves_frostpeak.json`). **New Game** on the main menu opens a map select screen that lists
every file in `maps/` (thumbnails are rendered from the data); `--map <name>` skips it, and **L** on the
pause / game-over screen returns to it. To add a map: create it in MapEdit (Save as into `data\maps`),
set its **waves file** property, then build its waves in WaveEdit (M switches map).

```json
{ "name": "Brewhold", "description": "...", "waves": "waves.json", "music": "brewhold.json",
  "backgroundSeed": 99, "roadHalfWidth": 34, "fortress": true, "heroSpawn": [1003, 303],
  "colors": { "ground": "#704A2E", "roadSand": "#D6A86C", ... },
  "paths": [ { "entrance": [34, 330], "points": [[-70, 330], [120, 330], ...] } ],
  "plots": [[965, 355], ...],
  "decor": [ { "geometry": "decor.rock", "x": 512.3, "y": 88.1, "scale": 1.1 } ] }
```

Edit maps visually with **MapEdit** (`mapedit.exe [map.json]`): drag road control points and
entrance skulls, add/move plots (with a road-distance guide and tower-range ghost), place decorations
from a palette of `geometry.json` objects, edit colours, and press **F5** to play-test the map in the
game. A checks panel flags plots overlapping the road or each other, roads that end inside the map,
off-screen entrances, decorations on the road, and objects under the game's HUD.

Paths are smooth Catmull-Rom curves through `points`; start and end them off-screen. Paths that
share their last points merge into one road. Plots are tower build spots (keep them ~70–90 px
from the road). Decorations are drawn back-to-front by `y`; their static shapes are baked into
the background and animated shapes (lava glow, torch flames) are drawn every frame.

## geometry.json (object geometry)

Each object is a list of shapes drawn in order. Origin `(0,0)` is where the object stands on the
ground; `+x` is the facing direction (units are mirrored when walking left); `+y` is down.

| type | fields |
|---|---|
| `circle` | `x y r` |
| `ellipse` | `x y rx ry` (+ `color2` for a radial gradient) |
| `rect` / `rrect` | `x y w h` (top-left) / + `r` corner radius |
| `poly` | `pts: [x1,y1, x2,y2, ...]` (convex) |
| `line` | `pts` (2+ points), `w` width |
| `ring` | `x y rx ry w` |
| `pie` | `x y r a0 a1` (degrees, 0 = right, 90 = down) |
| `image` | `x y w h image` – a bitmap (png/bmp/jpg) relative to this folder |

Common fields: `color`, `name`, `add` (additive glow), `hidden`, `bob` (walk bob amplitude),
`hover` (floating amplitude), `minLevel` / `maxLevel` (tower levels), `fire` (seconds visible after
firing, e.g. muzzle flash), and one animation channel:

| `anim` | effect (`amp`, `freq`, pivot `px py`) |
|---|---|
| `step` | x offset `sin(walk·freq)·amp` while walking (legs) |
| `flap` | rotate `amp°·sin(t·freq)` around pivot (wings) |
| `aim` | rotate to the aim angle around pivot (bows, projectiles) |
| `aimTilt` | tilt ±`amp°` toward the target side (mortar barrel) |
| `swing` | melee sword arc around pivot while attacking |
| `pulse` | scale `1 + amp·sin(t·freq)` around pivot |
| `flicker` | irregular flame scaling around pivot |
| `glow` | alpha oscillation by `amp` |
| `spin` | rotate `amp` degrees per second |

Object names used by code: `plot.empty`, `plot.built`; everything else is referenced by name from
the other JSON files.

### Bitmaps

GeoEdit's **Export PNG** writes `export/<object>.png` (2× scale, transparent) and **Export sheet**
writes an 8-frame walk/attack strip `export/<object>_sheet.png` plus a `.json` with frame size and
the origin position inside each frame. Bitmaps can be used back in geometry through `image` shapes.

## hero.json

```json
{ "enabled": true, "name": "Thane Brokkr", "geometry": "unit.hero",
  "speed": 75, "engageRange": 80, "respawnTime": 16, "regenPerSecond": 0.04,
  "xpPerGold": 3,                 // xp per gold value of a kill (full if the hero hit it, half if nearby)
  "levels": [ { "hp": 320, "damage": 14, "attackInterval": 1.0, "armor": 0.2, "xp": 0 }, ... ],
  "abilities": {
    "slam":   { "name": "Thunder Slam", "cooldown": 14, "radius": 85, "damage": 50, "damagePerLevel": 25,
                "stun": 1.5, "sound": "heroSlam" },
    "hammer": { "name": "Hammer Throw", "cooldown": 10, "range": 260, "damage": 110, "damagePerLevel": 45,
                "splash": 35, "geometry": "proj.hammer", "sound": "hammerThrow" } } }
```

`levels[i].xp` is the total xp needed to reach that level. Set `"enabled": false` (or delete the file)
for a game without a hero. A map can place the hero with `"heroSpawn": [x, y]`; otherwise he starts
72% of the way along road 0. In game: click the hero (or press **H**), then click where he should go;
**3** / **4** cast the abilities.

## Sound names

`arrow arrowHit magic magicHit mortar explosion meteorCast meteorFall horn sword1 sword2 sword3
soldierDie soldierSpawn rallyHorn dieRaider dieGoblin dieBat dieBrute enemyHit build upgrade sell
coin leak click victory defeat heroSlam hammerThrow heroLevel heroDie` (run `towerdefense.exe --dumpsfx <folder>` to hear them as WAVs).

## sounds.json (sound effects)

Every sound effect is synthesised at start-up from layers – nothing is sampled. Edit them with
**SoundEdit** (`soundedit.exe`): pick a sound, change its layers on a draggable timeline, see the
waveform, hear it on every change, export WAVs to `data\export`. The 32 built-in names (padlocked in
the editor) are the ones the game triggers; towers and enemies in StatEdit can also use any extra sound
you add.

```json
{"sounds": [
  {"name": "arrow", "peak": 0.45, "minGap": 0.07, "length": 0.22, "notes": "bow twang + whoosh",
   "layers": [
     {"type": "tone",  "at": 0,    "dur": 0.22, "wave": "triangle", "f0": 180,  "f1": 120, "attack": 0.002, "decay": 0.05, "gain": 1},
     {"type": "noise", "at": 0.01, "dur": 0.22, "f0": 2500, "f1": 900, "attack": 0.01, "decay": 0.06, "gain": 0.9} ]} ]}
```

| Field | Meaning |
|---|---|
| `peak` | loudness after normalising; `minGap` – minimum seconds between two plays (stops machine-gun stacking) |
| `length` | optional fixed length in seconds (default: until the last layer ends) |
| `lowPass` | optional `[startHz, endHz]` filter sweep over the whole sound |
| layer `type` | `tone` (oscillator), `noise` (filtered noise), `metal` (clangy inharmonic partials), `grunt` (voice-like buzz) |
| `at`, `dur` | start time and duration of the layer; `f0` → `f1` pitch (or noise colour) glide |
| `wave` | `sine saw square triangle noise`; `attack`, `decay` envelope; `vibrato`, `bright`, `cutoff`, `fadeOut`, `gain` |

## music/*.json (songs)

Music is a small tracker: **instruments** (synth voices), **channels** (one instrument each),
**patterns** (one line of notes per channel, `patternLength` steps long) and the **order** list that
arranges patterns into the song, which loops. A map picks its song with `"music": "brewhold.json"`;
`title.json` plays on the main menu and the map select screen. Edit songs with **MusicEdit**.

```json
{ "name": "Halls of the Thane", "bpm": 84, "stepsPerBeat": 4, "patternLength": 16, "swing": 0,
  "echo": { "time": 0.36, "feedback": 0.35, "mix": 0.22 },
  "instruments": [ { "name": "bass", "wave": "triangle", "attack": 0.01, "decay": 0.3, "sustain": 0.7,
                     "release": 0.25, "volume": 0.75, "cutoff": 600, "vibrato": 0, "vibRate": 5.5,
                     "pitchDrop": 0, "noise": 0, "detune": 0 } ],
  "channels": [ { "name": "Bass", "instrument": 0, "volume": 1 } ],
  "patterns": [ { "name": "A1", "tracks": [ "D-2 --- --- --- A-2 --- === --- ..." ] } ],
  "order": [0, 1, 2, 3] }
```

Notes are `C-4`, `F#3`, …; `---` = nothing (the previous note keeps ringing), `===` = note off.
`swing` delays every second step; `pitchDrop` slides each note down from N semitones above (kicks,
toms); `noise` mixes in noise (snares, hats); `detune` adds a second voice N cents off (chorus);
`cutoff` is a low-pass in Hz (0 = off). Songs are rendered once in a background thread when needed
and cached, so switching maps never stalls the game.

## Main menu, options and saving

The game starts on the main menu: **New Game** (map select), **Continue**, **Options**, **Exit**.
At the start of every wave the game writes a checkpoint to `savegame.json` next to the exe (map,
wave, gold, lives, towers with their levels, hero level and XP); **Continue** resumes from it
(the save is removed when the map is won or lost). **Options** (also in the pause menu) sets music
and sound volume, fullscreen (**F11**) and screen shake; they are stored in `options.json`.

| Program | Edits |
|---|---|
| `soundedit.exe` | `sounds.json` – every sound effect: layers, timeline, waveform, auto-play, WAV export |
| `musicedit.exe` | `music/*.json` – songs: pattern grid with piano-keyboard note entry, order list, instruments, channels, echo / swing, play song or pattern with live re-render after edits, WAV export |

MusicEdit keys: `Z S X D C V G B H N J M` = C…B in the current octave, `Q 2 W 3 E R 5 T 6 Y 7 U I` =
one octave up, `A` note off, `Del` clear, `[` `]` octave, `-` `=` edit step, arrows / `Tab` move,
`PgUp` `PgDn` pattern, `Space` play pattern, `Enter` play song, `Esc` stop, wheel on a note
transposes (Shift = octave), right-click a channel header mutes it, `Ctrl+C` / `Ctrl+V` copy / paste
a pattern, `Ctrl+S` save, `Ctrl+Z` / `Ctrl+Y` undo / redo.
