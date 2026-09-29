# miniaudio (vendored, NOT compiled)

- **Upstream:** https://github.com/mackron/miniaudio
- **Version:** v0.11.25
- **Licence:** public domain *or* MIT-0 — dual licensed, pick either. The full
  licence text is at the end of `miniaudio.h`. David Reid (mackron).
- **File:** `miniaudio.h`, the single-header amalgamation, **unmodified**.

## Read this before assuming the game uses it

**It does not. Nothing in this repository calls miniaudio.** The file is
vendored so the option is on disk and unambiguously licensed, not because the
game is currently silent-because-of-miniaudio.

## Why it is not compiled in

miniaudio is a C library. GDScript cannot call C. To use miniaudio from a
Godot project you need one of:

1. **A GDExtension** that wraps it (needs `godot-cpp`, i.e. a C++ toolchain
   and a long first build), or
2. **A custom engine build** that adds it as a `modules/` entry.

Neither is available in the prebuilt binaries this project runs on. That is a
hard engine limitation, not a configuration mistake.

## It is already inside the engine, unused

Godot's own `AudioDriver` *is* miniaudio — `drivers/mminiaudio.h` in the Godot
source. So the binary you run already links miniaudio for its audio output. It
is simply not exposed to scripting. You get Godot's audio features
(`AudioStreamPlayer`, `AudioStreamWAV`, `AudioStreamGenerator`, 3D positional
audio, buses and reverb) through the scripting API instead.

## How to actually turn this on

If a native build is ever wanted:

```
godot-cpp checkout (match the engine version)
one .cpp that includes miniaudio.h with MA_NO_RUNTIME_LINKING omitted
godot-cpp's SConstruct, or a custom modules/miniaudio/ + scons platform=linux
expose ma_device_create / ma_engine_* as Godot classes
```

Until then, any audio in this project must be built on Godot's own classes.
