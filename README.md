# NavMesh Transient Fix (CS:S v34)

SourceMod plugin that fixes a heap use-after-free in the **CS:S v34 (Source 2006 / EP1) server binary**.
The bug makes servers with bots crash or hang at random, usually a few hours after a map change.

## Symptoms

- Random `SIGSEGV`/`SIGABRT` on a server with bots, roughly once a day, with no stable backtrace. Victims seen in cores:
  - `PackedEntity::~PackedEntity` / `CChangeFrameList` (snapshots, SourceTV `CHLTVServer::UpdateTick`);
  - glibc `corrupted double-linked list`;
  - KeyValues copies of game events, vphysics objects.
- Sometimes a hang at 100% CPU instead of a crash.
- The common signature: byte `0x01` written into byte 0 of a small (≤32 B) heap block that was already freed.
  The value is a `bool = true` written through a stale pointer.
- Happens only after the server **changes from a map whose `.nav` has TRANSIENT areas**. Plain restarts on such a map
  stay stable until the first map change.

## Root cause

`CNavMesh` keeps a separate list of nav areas flagged `NAV_MESH_TRANSIENT` (attribute bit `0x100`).
These are areas that can be dynamically blocked (doors, breakables, Valve's route blocking on cs_havana):

```cpp
CUtlVector<CNavArea *> m_transientAreas;   // v34 linux: TheNavMesh + 0x510
```

- **Filled:** `CNavMesh::AddNavArea()` appends every TRANSIENT area while the `.nav` file loads.
- **Used:** `CCSBotManager::StartFrame()` walks the list periodically (writes observed every ~2.5–3 min) and calls
  `CNavArea::UpdateBlocked()` on each entry. That function writes the result into `CNavArea::m_isBlocked`
  (`mov %bl,0x30(%ebp)`).
- **Not cleared:** in the v34 binary `CNavMesh::DestroyNavigationMesh()` deletes all `CNavArea` objects but does
  **not** clear `m_transientAreas`. Source SDK 2013 has `m_transientAreas.RemoveAll()` there
  (`src/game/server/nav_mesh.cpp`, `DestroyNavigationMesh`), so Valve fixed it later.

After a map change the list still holds pointers to the freed areas of the previous map, and new entries are appended
after them. The bot manager keeps writing `m_isBlocked` into memory that glibc has already handed to someone else.
Whatever object lives there now gets one byte set to `1`. That object is a vtable pointer, a malloc free-list pointer,
an array element and so on, which is why the crash site looks random and moves around.

Without the fix the list only grows: `cs_havana` (15) → `de_dust2_unlimited` (+1 = 16) → `de_dust2` (still 16, all stale).

### How it was found

1. Cores showed the same corruption pattern (`0x01` into a freed small chunk) behind different crash sites.
2. An `LD_PRELOAD` quarantine allocator held freed ≤64 B blocks filled with `0xA5` and verified them on eviction.
   It reported `UAF-WRITE` (one byte changed to `0x01`) periodically at a fixed address per process,
   always about one quarantine window (~150 s) after the block was freed.
3. A hardware watchpoint (gdb) on that address caught the writer 5/5 times:
   `CNavArea::UpdateBlocked()` ← `CCSBotManager::StartFrame()` on a freed `CNavArea`.
4. A live memory scan found the stale pointer inside `TheNavMesh + 0x510`, i.e. `m_transientAreas`.
   A disassembly of `server_i486.so` showed that only the ctor/dtor, `AddNavArea`, `RemoveNavArea`,
   `CommandNavToggleAttribute` and `CCSBotManager::StartFrame` touch that vector. `DestroyNavigationMesh` does not.
5. Confirmation:
   - Clearing bit `0x100` in the affected `.nav` files: 4d20h uptime, 0 crashes, 0 UAF hits (before: ~1 crash/day).
   - Then this plugin with the original `.nav` files: same result.

## The fix

On `OnMapEnd` the plugin sets `m_transientAreas.m_Size = 0`. For a vector of pointers this is exactly
`CUtlVector::RemoveAll()`: no destructors run, and the buffer stays allocated and is reused. The next map's nav load
refills the list through `AddNavArea()`, so dynamic blocking on maps like cs_havana keeps working. The fix does not
require editing `.nav` files.

Before writing anything the plugin checks that the fields look like a `CUtlVector`:
`0 <= size <= allocationCount`, and the memory pointer is non-null when `size > 0`.
If they don't (wrong binary or offsets), it only logs an error.

Log on every map change that had transient areas:

```
[navmesh_transient_fix.smx] Cleared 15 transient nav area(s) on map end
```

`sm_navfix_status` (server console) prints the live state:

```
[navfix] TheNavMesh=0x93caa60 transient list mem=0xa710da0 alloc=16 size=15 (ok)
```

## Affected maps

Any map whose `.nav` has at least one area with attribute `0x100` (TRANSIENT), as long as bots are on the server.
The `CCSBotManager` frame loop only runs with bots. Examples from one server:

| Map | TRANSIENT areas |
|-----|-----------------|
| `cs_havana` (Valve) | 15 |
| `de_dust2_unlimited` (custom nav) | 1 |
| de_dust2, de_inferno, cs_italy, cs_office, de_nuke, de_train, de_aztec, cs_assault, cs_militia, de_cbble | 0 |

A rotation that only contains maps with 0 TRANSIENT areas is not affected.

## Requirements / compatibility

- CS:S **v34** (pre-OrangeBox, EP1 engine), **Linux** `server_i486.so`. The plugin refuses to load on other engine versions.
- SourceMod **1.4+**. Written in old syntax and built once with `spcomp` 1.4.2; the same `.smx` runs on 1.4 … 1.13
  (tested with that build on 1.13.0.7394; the new-syntax prototype ran on 1.11.0.6522).
- No extensions: plain gamedata + `LoadFromAddress`/`StoreToAddress`.
- Windows is not supported: there is no exported `TheNavMesh` symbol, so it would need a signature and offsets.

## Install

Download the zip from [Releases](../../releases) and unpack it into the game dir (`cstrike/`):

```
addons/sourcemod/plugins/navmesh_transient_fix.smx
addons/sourcemod/gamedata/navmesh_transient_fix.games.txt
```

## Build

`tools/build-release.sh` compiles with the bundled `tools/compilers/sm1.4.2-linux/spcomp` (32-bit; needs `lib32stdc++6`,
`lib32z1`) and writes `dist/navmesh_transient_fix-<version>.zip`. The version comes from the tag `vX.Y.Z`, else from
the last commit subject, else `PLUGIN_VERSION`. GitHub Actions (`.github/workflows/release.yml`) runs it on every
`v*` tag and attaches the zip to a GitHub Release; manual runs (`workflow_dispatch`) only upload an artifact.

Restart the server after installing. A process that already changed maps can still hold stale pointers in memory,
so only a fresh process is guaranteed clean.

## Limitations

- Only map changes are covered. Reloading the nav mesh mid-map with `nav_load`, `nav_generate` or `nav_analyze`
  rebuilds areas without a map end and has the same problem. These are developer commands that a normal server
  does not use.
- Offsets are for the v34 linux binary. Verify them with `sm_navfix_status` on another build:
  it must show `(ok)` and `size` equal to the map's TRANSIENT area count.
