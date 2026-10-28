unit sfx;

{ Audio playback for SDL3: sound effects and music.

  Sound effects are defined as synth recipes in data\sounds.json (see synth.pas, edited with SoundEdit),
  rendered to PCM once at load and played through a pool of SDL audio streams bound to one device.
  Each play gets a small random pitch / volume variation so repeated sounds don't feel robotic.
  The game refers to built-in sounds through TSound (sndArrow -> "arrow"); data files refer to sounds
  by name, so new sounds can be added in SoundEdit and assigned to towers / enemies in StatEdit.

  Music is a looping PCM buffer (rendered by music.pas from data\music\*.json) streamed on its own
  SDL audio stream with its own volume and short fades. }

{$mode objfpc}{$H+}

interface

uses
  SDL3, SysUtils, Classes, Math, TypInfo, synth, music;

type
  TSound = (
    sndArrow, sndArrowHit, sndMagic, sndMagicHit, sndMortar, sndExplosion,
    sndMeteorCast, sndMeteorFall, sndHorn, sndSword1, sndSword2, sndSword3,
    sndSoldierDie, sndSoldierSpawn, sndRallyHorn,
    sndDieRaider, sndDieGoblin, sndDieBat, sndDieBrute, sndEnemyHit,
    sndBuild, sndUpgrade, sndSell, sndCoin, sndLeak, sndClick,
    sndVictory, sndDefeat,
    sndHeroSlam, sndHammerThrow, sndHeroLevel, sndHeroDie);

var
  SoundMuted: Boolean = False;
  MasterVolume: Single = 0.8;     // sound effects volume
  MusicVolume: Single = 0.6;
  SoundDefs: TSoundArray;          // as loaded from sounds.json

procedure SfxInit;
procedure SfxDone;
function SfxLoadSounds(const fn: string; out err: string): Boolean;   // (re)load + render sounds.json
procedure SfxUpdate(dt: Single);       // throttle timers, music streaming and fades
procedure PlaySound(s: TSound; vol: Single = 1.0; pitchVar: Single = 0.08);
procedure PlaySword;                    // random clash variant
function SoundByName(const name: string): Integer;   // index into SoundDefs, -1 if unknown
function SoundCount: Integer;
function SoundNameOf(i: Integer): string;
function SoundIsBuiltin(const name: string): Boolean;  // used directly by game code (can't be removed)
procedure PlaySoundIdx(idx: Integer; vol: Single = 1.0; pitchVar: Single = 0.08);
procedure PlayBuffer(const b: TBuf; vol: Single = 1.0);   // editors: preview any rendered buffer
procedure StopAllSounds;
procedure SfxDumpWav(const dir: string); // debug: write every sound as 16-bit WAV

// music
procedure MusicPlayBuffer(const b: TBuf; loop: Boolean = True; startSeconds: Single = 0);
function MusicPlayFile(const fn: string): Boolean;    // render (cached by file name) and play, looping
procedure MusicStop(fadeSeconds: Single = 0.6);
function MusicPlaying: Boolean;
function MusicPosition: Single;                       // seconds into the current buffer
function MusicCurrentFile: string;

implementation

const
  VOICES = 24;
  CHUNK = RATE div 4;          // music is streamed in quarter-second chunks

type
  // renders a song off the main thread; SfxUpdate picks up the result
  TMusicRender = class(TThread)
  public
    FileName: string;
    Output: TBuf;
    Success: Boolean;
  protected
    procedure Execute; override;
  end;

  TVoice = record
    Stream: PSDL_AudioStream;
    Started: Double;
  end;

var
  Device: TSDL_AudioDeviceID;
  Ok: Boolean;
  Bufs: array of TBuf;
  Cooldown: array of Single;
  EnumIdx: array[TSound] of Integer;
  Voice: array[0..VOICES - 1] of TVoice;
  Clock: Double;
  // music
  MStream: PSDL_AudioStream;
  MBuf: TBuf;
  MLoop, MActive: Boolean;
  MFed: Int64;                 // samples handed to the stream so far
  MFade, MFadeSpeed: Single;   // current fade gain (0..1) and direction (per second)
  MFile: string;
  MCacheName: string;
  MCache: TBuf;
  MRender: TMusicRender;       // pending background render (nil = none)
  MWanted: string;             // file that should start when its render is done

function BuiltinName(s: TSound): string;
var
  n: string;
begin
  n := Copy(GetEnumName(TypeInfo(TSound), Ord(s)), 4, 60);
  Result := LowerCase(Copy(n, 1, 1)) + Copy(n, 2, 60);
end;

function SoundIsBuiltin(const name: string): Boolean;
var
  s: TSound;
begin
  for s := Low(TSound) to High(TSound) do
    if SameText(BuiltinName(s), name) then Exit(True);
  Result := False;
end;

function SoundCount: Integer;
begin
  Result := Length(SoundDefs);
end;

function SoundNameOf(i: Integer): string;
begin
  if (i >= 0) and (i <= High(SoundDefs)) then Result := SoundDefs[i].Name else Result := '';
end;

function SoundByName(const name: string): Integer;
var
  i: Integer;
  n: string;
begin
  Result := -1;
  if name = '' then Exit;
  n := name;
  if SameText(Copy(n, 1, 3), 'snd') and (Length(n) > 3) then n := LowerCase(n[4]) + Copy(n, 5, 60);
  for i := 0 to High(SoundDefs) do
    if SameText(SoundDefs[i].Name, n) then Exit(i);
end;

function SfxLoadSounds(const fn: string; out err: string): Boolean;
var
  defs: TSoundArray;
  i: Integer;
  s: TSound;
begin
  Result := LoadSoundsFile(fn, defs, err);
  if not Result then Exit;
  SoundDefs := defs;
  SetLength(Bufs, Length(defs));
  SetLength(Cooldown, Length(defs));
  for i := 0 to High(defs) do
  begin
    Bufs[i] := RenderSound(defs[i]);
    Cooldown[i] := 0;
  end;
  for s := Low(TSound) to High(TSound) do EnumIdx[s] := SoundByName(BuiltinName(s));
end;

procedure SfxInit;
var
  spec: TSDL_AudioSpec;
  i: Integer;
  err: string;
  s: TSound;
begin
  Ok := False;
  for s := Low(TSound) to High(TSound) do EnumIdx[s] := -1;
  SfxLoadSounds(ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'sounds.json', err);
  if not SDL_InitSubSystem(SDL_INIT_AUDIO) then Exit;
  spec.format := SDL_AUDIO_F32;
  spec.channels := 1;
  spec.freq := RATE;
  Device := SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, @spec);
  if Device = 0 then Exit;
  for i := 0 to VOICES - 1 do
  begin
    Voice[i].Stream := SDL_CreateAudioStream(@spec, nil);
    Voice[i].Started := -1;
    if Voice[i].Stream <> nil then SDL_BindAudioStream(Device, Voice[i].Stream);
  end;
  MStream := SDL_CreateAudioStream(@spec, nil);
  if MStream <> nil then SDL_BindAudioStream(Device, MStream);
  MActive := False;
  MFade := 1;
  MFadeSpeed := 0;
  Clock := 0;
  Ok := True;
end;

procedure SfxDone;
var
  i: Integer;
begin
  if MRender <> nil then
  begin
    MRender.WaitFor;
    MRender.Free;
    MRender := nil;
  end;
  if not Ok then Exit;
  for i := 0 to VOICES - 1 do
    if Voice[i].Stream <> nil then SDL_DestroyAudioStream(Voice[i].Stream);
  if MStream <> nil then SDL_DestroyAudioStream(MStream);
  SDL_CloseAudioDevice(Device);
  Ok := False;
end;

{ ---------- music ---------- }

procedure FeedMusic;
var
  queued, n, pos: Integer;
  piece: TBuf;
  i: Integer;
begin
  if (MStream = nil) or not MActive or (Length(MBuf) = 0) then Exit;
  queued := SDL_GetAudioStreamQueued(MStream) div SizeOf(Single);
  while queued < CHUNK * 2 do
  begin
    pos := MFed mod Length(MBuf);
    if (not MLoop) and (MFed >= Length(MBuf)) then Exit;
    n := Min(CHUNK, Length(MBuf) - pos);
    SetLength(piece, n);
    for i := 0 to n - 1 do piece[i] := MBuf[pos + i];
    SDL_PutAudioStreamData(MStream, @piece[0], n * SizeOf(Single));
    Inc(MFed, n);
    Inc(queued, n);
  end;
end;

procedure ApplyMusicGain;
var
  g: Single;
begin
  if MStream = nil then Exit;
  g := MusicVolume * MFade;
  if SoundMuted then g := 0;
  SDL_SetAudioStreamGain(MStream, EnsureRange(g, 0, 2));
end;

procedure MusicPlayBuffer(const b: TBuf; loop: Boolean; startSeconds: Single);
begin
  if not Ok or (MStream = nil) then Exit;
  SDL_ClearAudioStream(MStream);
  MBuf := b;
  MLoop := loop;
  MFed := 0;
  if Length(b) > 0 then MFed := Round(startSeconds * RATE) mod Length(b);
  MActive := Length(MBuf) > 0;
  MFade := 0;            // short fade-in
  MFadeSpeed := 3;
  MFile := '';
  ApplyMusicGain;
  FeedMusic;
end;

procedure TMusicRender.Execute;
var
  s: TSong;
  err: string;
begin
  Success := LoadSong(FileName, s, err);
  if Success then Output := RenderSong(s, -1, -1, -1, True);
end;

function MusicPlayFile(const fn: string): Boolean;
begin
  Result := False;
  if not Ok or not FileExists(fn) then Exit;
  if MActive and SameText(MFile, fn) and (MFadeSpeed >= 0) then Exit(True);   // already playing
  if SameText(MCacheName, fn) then
  begin
    MusicPlayBuffer(MCache, True);
    MFile := fn;
    MWanted := '';
    Exit(True);
  end;
  // fade out whatever plays now and render the new song in the background
  MusicStop(0.5);
  MWanted := fn;
  if MRender = nil then
  begin
    MRender := TMusicRender.Create(True);
    MRender.FileName := fn;
    MRender.Start;
  end;
  Result := True;
end;

procedure CheckRender;
var
  r: TMusicRender;
begin
  if (MRender = nil) or not MRender.Finished then Exit;
  r := MRender;
  MRender := nil;
  r.WaitFor;
  if r.Success then
  begin
    MCache := r.Output;
    MCacheName := r.FileName;
  end;
  r.Free;
  if MWanted <> '' then
  begin
    if SameText(MWanted, MCacheName) then
    begin
      MusicPlayBuffer(MCache, True);
      MFile := MCacheName;
      MWanted := '';
    end
    else
      MusicPlayFile(MWanted);      // a different song was requested meanwhile
  end;
end;

procedure MusicStop(fadeSeconds: Single);
begin
  if fadeSeconds <= 0 then MWanted := '';
  if not MActive then Exit;
  if fadeSeconds <= 0 then
  begin
    MActive := False;
    if MStream <> nil then SDL_ClearAudioStream(MStream);
    MFile := '';
  end
  else
    MFadeSpeed := -1 / fadeSeconds;
end;

function MusicPlaying: Boolean;
begin
  Result := MActive;
end;

function MusicPosition: Single;
var
  queued: Integer;
begin
  Result := 0;
  if not MActive or (MStream = nil) or (Length(MBuf) = 0) then Exit;
  queued := SDL_GetAudioStreamQueued(MStream) div SizeOf(Single);
  Result := ((MFed - queued) mod Length(MBuf)) / RATE;
  if Result < 0 then Result := 0;
end;

function MusicCurrentFile: string;
begin
  Result := MFile;
end;

{ ---------- effects ---------- }

procedure SfxUpdate(dt: Single);
var
  i: Integer;
begin
  Clock := Clock + dt;
  CheckRender;
  for i := 0 to High(Cooldown) do
    if Cooldown[i] > 0 then Cooldown[i] := Cooldown[i] - dt;
  if MActive then
  begin
    if MFadeSpeed <> 0 then
    begin
      MFade := MFade + MFadeSpeed * dt;
      if MFade >= 1 then
      begin
        MFade := 1;
        MFadeSpeed := 0;
      end
      else if MFade <= 0 then
      begin
        MFade := 0;
        MActive := False;
        MFile := '';
        if MStream <> nil then SDL_ClearAudioStream(MStream);
      end;
    end;
    ApplyMusicGain;
    FeedMusic;
  end;
end;

function GrabVoice: Integer;
var
  i: Integer;
  oldest: Double;
begin
  Result := -1;
  oldest := 1e18;
  for i := 0 to VOICES - 1 do
  begin
    if Voice[i].Stream = nil then Continue;
    if SDL_GetAudioStreamQueued(Voice[i].Stream) = 0 then Exit(i);
    if Voice[i].Started < oldest then
    begin
      oldest := Voice[i].Started;
      Result := i;
    end;
  end;
end;

procedure PlayRaw(const b: TBuf; vol, pitchVar: Single);
var
  v: Integer;
begin
  if not Ok or (Length(b) = 0) then Exit;
  v := GrabVoice;
  if v < 0 then Exit;
  SDL_ClearAudioStream(Voice[v].Stream);
  SDL_SetAudioStreamGain(Voice[v].Stream, EnsureRange(vol, 0, 2));
  SDL_SetAudioStreamFrequencyRatio(Voice[v].Stream, 1 + (Random * 2 - 1) * pitchVar);
  SDL_PutAudioStreamData(Voice[v].Stream, @b[0], Length(b) * SizeOf(Single));
  Voice[v].Started := Clock;
end;

procedure PlaySoundIdx(idx: Integer; vol: Single; pitchVar: Single);
begin
  if not Ok or SoundMuted or (idx < 0) or (idx > High(Bufs)) then Exit;
  if Cooldown[idx] > 0 then Exit;
  Cooldown[idx] := SoundDefs[idx].MinGap;
  PlayRaw(Bufs[idx], vol * MasterVolume * (1 - Random * 0.15), pitchVar);
end;

procedure PlaySound(s: TSound; vol: Single; pitchVar: Single);
begin
  PlaySoundIdx(EnumIdx[s], vol, pitchVar);
end;

procedure PlayBuffer(const b: TBuf; vol: Single);
begin
  PlayRaw(b, vol * MasterVolume, 0);
end;

procedure StopAllSounds;
var
  i: Integer;
begin
  for i := 0 to VOICES - 1 do
    if Voice[i].Stream <> nil then SDL_ClearAudioStream(Voice[i].Stream);
end;

procedure PlaySword;
begin
  PlaySound(TSound(Ord(sndSword1) + Random(3)), 1.0, 0.06);
end;

procedure SfxDumpWav(const dir: string);
var
  i: Integer;
  err: string;
begin
  if Length(SoundDefs) = 0 then
    SfxLoadSounds(ExtractFilePath(ParamStr(0)) + 'data' + PathDelim + 'sounds.json', err);
  for i := 0 to High(SoundDefs) do
    SaveWav(IncludeTrailingPathDelimiter(dir) + 'snd' + UpperCase(Copy(SoundDefs[i].Name, 1, 1)) +
      Copy(SoundDefs[i].Name, 2, 60) + '.wav', Bufs[i]);
end;

end.
