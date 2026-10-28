# Build times

A counter app each, from empty build caches, on the same M3 Ultra
(`sh tools/buildperf.sh` measures it again: mygo's
`examples/counter-native` with Go 1.27.1, nanoui's from `nui start` with
Zig 0.17.0; network fetches aren't timed):

| | mygo | nanoui |
|---|---:|---:|
| cold build | 4.4 s | 6.3 s (a second app, Zig's global cache warm: 4.8 s) |
| rebuild, nothing changed | 0.28 s | 0.12 s |
| rebuild after a one-line edit | 0.55 s | 2.2 s |
| build cache on disk | 182 MB | 97 MB |
| program | 14 MB | 4 MB Debug, 0.7 MB ReleaseFast (11 s), 0.4 MB ReleaseSmall (6.7 s) |

Zig compiles the app and nanoui as one unit, so an edit rebuilds the
whole of it where Go rebuilds one package: that's where mygo is faster.
Cold builds are close, nothing-changed rebuilds faster, and the disk a
project costs is about half.
