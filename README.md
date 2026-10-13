# NavMesh Transient Fix (CS:S v34)

**English** · [Русский](#русский)

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
- Happens only after a **map change away from a map whose `.nav` has TRANSIENT areas**. That includes a
  `changelevel` to the *same* map, e.g. a single-map server on `de_dust2_unlimited` reloading it every
  `mp_timelimit`. A freshly started server stays stable until its first map change.
- Nothing useful is printed before the crash. The last console lines are ordinary game output.

## Crash signatures

Gathered from one production server (CS:S v34, Ubuntu 24.04, glibc 2.39, SourceMod 1.11.0.6522, 15 bots, SourceTV on,
de_dust2_unlimited + cs_havana in rotation): 46 crashes between 2026-07-20 and 2026-10-04, plus one 100% CPU hang.
No crash of this kind after the fix (one unrelated bot crash on 2026-10-10, see "Not this bug").

### Console / `srcds_run` output

| Message | Count | Notes |
|---------|------:|-------|
| `Segmentation fault (core dumped)` | 29 | |
| `Aborted (core dumped)` | 17 | glibc heap check fired |
| `SV_PackEntity: SnagChangeFrameList returned null` | 20 | engine notices a `PackedEntity` whose change-frame list was clobbered |
| `corrupted double-linked list` | 12 | glibc, followed by `Aborted` |
| `free(): invalid pointer` | 2 | |
| `free(): invalid next size (normal)` | 1 | |
| `double free or corruption (out)` / `(!prev)` | 1 / 1 | |
| `malloc(): smallbin double linked list corrupted` | 1 | |

### Backtraces (cores, `gdb bt`)

**A. SIGSEGV in snapshot cleanup through SourceTV.** The most common one. The vtable pointer of `CChangeFrameList`
had its low byte overwritten with `0x01`, so the virtual call jumps to garbage:

```
#0  ?? ()
#1  PackedEntity::~PackedEntity()                    engine_i686.so
#2  CUtlLinkedList<PackedEntity, int>::Free(int)     engine_i686.so
#3  CFrameSnapshot::ReleaseReference()               engine_i686.so
#4  CClientFrame::~CClientFrame()                    engine_i686.so
#5  CHLTVFrame::~CHLTVFrame()                        engine_i686.so
#6  CClientFrameManager::DeleteClientFrames(int)     engine_i686.so
#7  CHLTVServer::UpdateTick()                        engine_i686.so
#8  CHLTVServer::RunFrame()                          engine_i686.so
#9  _Host_RunFrame(float)                            engine_i686.so
```

**B. SIGABRT in `free()` from the same snapshot path:**

```
#3  abort                                            libc.so.6
#9  free                                             libc.so.6
#10 CUtlMemory<int>::Purge()                         engine_i686.so
#11 CChangeFrameList::~CChangeFrameList()            engine_i686.so
#12 PackedEntity::~PackedEntity()                    engine_i686.so
#13 CUtlLinkedList<PackedEntity, int>::Free(int)     engine_i686.so
```

**C. SIGABRT in `free()` while the nav mesh is destroyed on map change.** The heap was already corrupted when the old
areas were freed:

```
#3  abort                                            libc.so.6
#8  free                                             libc.so.6
#9  operator delete(void*)                           server_i486.so
#10 CUtlLinkedList<SpotEncounter*, int>::PurgeAndDeleteElements()   server_i486.so
#11 CNavArea::~CNavArea()                            server_i486.so
#12 CNavMesh::DestroyNavigationMesh(bool)            server_i486.so
#13 CNavMesh::Reset()                                server_i486.so
```

**D. The actual writer**, caught by a hardware watchpoint on the corrupted byte (5 of 5 hits). It is never visible in
a crash backtrace, because the crash happens later in whatever code owns the memory now:

```
#0  CNavArea::UpdateBlocked()                        server_i486.so   <- mov %bl,0x30(%ebp)  (m_isBlocked = true)
#1  CCSBotManager::StartFrame()                      server_i486.so
#2  CCSGameRules::EndGameFrame()                     server_i486.so
#3  CServerGameDLL::GameFrame(bool)                  server_i486.so
#4  __SourceHook_FHCls_IServerGameDLLGameFramefalse::Func(bool)   sourcemod.2.ep1.so
#5  SV_Frame(bool)                                   engine_i686.so
```

Other victims found with the quarantine allocator: `CChangeFrameList` tick arrays, KeyValues copies of game events,
`server_i486.so` objects and vphysics allocations. In every case one byte was set to `0x01` in a block freed ~2.5 min
earlier.

### Binaries this was verified on

| File | md5 |
|------|-----|
| `cstrike/bin/server_i486.so` (15160815 bytes) | `8349c21323a4e63e1b169dc06e1d7036` |
| `bin/engine_i686.so` | `5d5325f88d7f202ad97b6294f050677c` |
| `bin/dedicated_i686.so` | `afe97b94b5805a984efb1c77cd3a3c06` |

`server_i486.so` sha256: `1fde488de2e4227f446534327c35de3c180515bab2f7c03b4ab676f8ee0664a9`

### Reports that fit the same pattern

The same server was discussed on hlmod.net: "Причины падения сервера" (2017) and "Краш v34" (2020). At that time it ran
a single map, `de_dust2_unlimited`, with bots (`bot_quota 11`) and `mp_timelimit 60–300`. It crashed every 3–12 hours
and up to 10 times a day. The cause was blamed in turn on:
- KAC, SMAC, SourceBans, ProcessCmds, Metamod and SourceMod versions;
- SourceTV, Stripper, entity removal code, the hosting provider.

None of these changed anything. Messages reported there, all consistent with a corrupted glibc heap
(not individually verified against this bug):

- `SV_PackEntity: SnagChangeFrameList returned null` (same as above);
- `terminate called after throwing an instance of 'std::bad_alloc'` with `operator new[]` ←
  `sp::CompilerBase::CompilerBase` (`sourcepawn.jit.x86.so`), i.e. a plugin JIT allocation failing;
- `Can't load lump 8, allocation of N bytes failed!!!` on map load;
- `[SM] Plugin encountered error 28: Out of memory` from a plugin with a normal heap.

Accelerator crash reports on v34 add nothing useful: it has no symbols for this build, and the "null pointer" seen
there is the victim frame. Clients sometimes saw `Couldn't dispatch user message` / `Server connection timed out`
right as the server went down.

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

A rotation that only contains maps with 0 TRANSIENT areas is not affected. One TRANSIENT area is enough: on a
single-map `de_dust2_unlimited` server every timelimit `changelevel` leaves one more stale pointer behind.

To count TRANSIENT areas in a `.nav` file (v9, the CS:S v34 format), check bit `0x100` of each area's attribute word.
Alternatively, load the map with this plugin and run `sm_navfix_status`.

## Not this bug

`CCSBot::IsVisible()` ← `AttackState::OnUpdate()` SIGSEGV with a destroyed player object (vtable pointer 0),
right after bots were kicked. For example, `Kicking client "…" for killing too many hostages` with
`mp_hostagepenalty > 0`, or bots removed by `bot_quota` / `bot_auto_vacate`. This is a separate v34 bot issue:
a bot keeps attacking a target that was just removed. This plugin does not fix it. Mitigations: `mp_hostagepenalty 0`,
and remove bots only while they are dead.

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

Restart the server after installing. A process that already changed maps can still hold stale pointers in memory,
so only a fresh process is guaranteed clean.

## Build

`tools/build-release.sh` compiles with the bundled `tools/compilers/sm1.4.2-linux/spcomp` (32-bit; needs `lib32stdc++6`,
`lib32z1`) and writes `dist/navmesh_transient_fix-<version>.zip`. The version comes from the tag `vX.Y.Z`, else from
the last commit subject, else `PLUGIN_VERSION`. GitHub Actions (`.github/workflows/release.yml`) runs it on every
`v*` tag and attaches the zip to a GitHub Release; manual runs (`workflow_dispatch`) only upload an artifact.

## Limitations

- Only map changes are covered. Reloading the nav mesh mid-map with `nav_load`, `nav_generate` or `nav_analyze`
  rebuilds areas without a map end and has the same problem. These are developer commands that a normal server
  does not use.
- Offsets are for the v34 linux binary. Verify them with `sm_navfix_status` on another build:
  it must show `(ok)` and `size` equal to the map's TRANSIENT area count.

---

## Русский

[English](#navmesh-transient-fix-css-v34) · **Русский**

Плагин SourceMod, исправляющий use-after-free (запись в уже освобождённую память кучи) в **серверном бинарнике
CS:S v34 (движок Source 2006 / EP1)**. Из-за этой ошибки серверы с ботами падают или зависают в случайный момент,
обычно через несколько часов после смены карты.

### Симптомы

- Случайные `SIGSEGV`/`SIGABRT` на сервере с ботами, примерно раз в сутки, без постоянного стека. Жертвы в дампах:
  - `PackedEntity::~PackedEntity` / `CChangeFrameList` (снапшоты, SourceTV `CHLTVServer::UpdateTick`);
  - glibc `corrupted double-linked list`;
  - копии KeyValues игровых событий, объекты vphysics.
- Иногда вместо падения сервер зависает на 100% CPU.
- Общая черта: байт `0x01` записан в байт 0 маленького (≤32 Б) блока кучи, который уже был освобождён.
  Это `bool = true`, записанный через висячий указатель.
- Происходит только после **смены карты, у которой в `.nav` есть TRANSIENT-зоны**. Смена на *ту же самую* карту тоже
  считается: например, сервер на одной `de_dust2_unlimited`, которая перезагружается по `mp_timelimit`.
  Свежезапущенный сервер стабилен до первой смены карты.
- Перед падением в консоли ничего полезного нет, последние строки — обычный вывод игры.

### Сигнатуры падений

Собрано на одном боевом сервере (CS:S v34, Ubuntu 24.04, glibc 2.39, SourceMod 1.11.0.6522, 15 ботов, SourceTV включён,
в ротации de_dust2_unlimited и cs_havana): 46 падений с 2026-07-20 по 2026-10-04 и одно зависание на 100% CPU.
После исправления падений этого типа не было. Одно падение 2026-10-10 — другой баг ботов, см. «Это не тот баг».

#### Вывод консоли / `srcds_run`

| Сообщение | Сколько раз | Примечание |
|-----------|------:|------------|
| `Segmentation fault (core dumped)` | 29 | |
| `Aborted (core dumped)` | 17 | сработала проверка кучи glibc |
| `SV_PackEntity: SnagChangeFrameList returned null` | 20 | движок заметил `PackedEntity` с испорченным списком изменений |
| `corrupted double-linked list` | 12 | glibc, затем `Aborted` |
| `free(): invalid pointer` | 2 | |
| `free(): invalid next size (normal)` | 1 | |
| `double free or corruption (out)` / `(!prev)` | 1 / 1 | |
| `malloc(): smallbin double linked list corrupted` | 1 | |

#### Стеки (дампы, `gdb bt`)

Полные стеки приведены в английской части, раздел [Backtraces](#backtraces-cores-gdb-bt):

- **A.** SIGSEGV в `PackedEntity::~PackedEntity` ← `CFrameSnapshot::ReleaseReference` ← `CHLTVFrame::~CHLTVFrame` ←
  `CHLTVServer::UpdateTick`. Самый частый. У `CChangeFrameList` младший байт указателя на таблицу виртуальных функций
  заменён на `0x01`, и виртуальный вызов уходит в мусор.
- **B.** SIGABRT в `free()` ← `CUtlMemory<int>::Purge` ← `CChangeFrameList::~CChangeFrameList` ←
  `PackedEntity::~PackedEntity`. Тот же путь снапшотов.
- **C.** SIGABRT в `free()` ← `CNavArea::~CNavArea` ← `CNavMesh::DestroyNavigationMesh` ← `CNavMesh::Reset`.
  Падение прямо на смене карты, при удалении зон навигации, когда куча уже испорчена.
- **D.** Настоящий виновник, пойман аппаратной точкой останова на испорченном байте (5 срабатываний из 5):
  `CNavArea::UpdateBlocked()` (`mov %bl,0x30(%ebp)` = `m_isBlocked = true`) ← `CCSBotManager::StartFrame()` ←
  `CCSGameRules::EndGameFrame()` ← `CServerGameDLL::GameFrame()`. В стеках падений его не видно: падение происходит
  позже, в коде, которому эта память принадлежит теперь.

Другие жертвы, найденные ловушкой-аллокатором с карантином:
- массивы тиков `CChangeFrameList`;
- копии KeyValues игровых событий;
- объекты `server_i486.so` и выделения vphysics.

Везде один байт становился `0x01` в блоке, освобождённом примерно за 2,5 минуты до этого.

#### Бинарники, на которых это проверено

| Файл | md5 |
|------|-----|
| `cstrike/bin/server_i486.so` (15160815 байт) | `8349c21323a4e63e1b169dc06e1d7036` |
| `bin/engine_i686.so` | `5d5325f88d7f202ad97b6294f050677c` |
| `bin/dedicated_i686.so` | `afe97b94b5805a984efb1c77cd3a3c06` |

sha256 `server_i486.so`: `1fde488de2e4227f446534327c35de3c180515bab2f7c03b4ab676f8ee0664a9`

#### Похожие случаи

Этот же сервер обсуждался на hlmod.net в темах «Причины падения сервера» (2017) и «Краш v34» (2020). Тогда на нём
была одна карта `de_dust2_unlimited`, боты (`bot_quota 11`) и `mp_timelimit` от 60 до 300. Сервер падал раз в 3–12 часов,
бывало до 10 раз в сутки. Причину по очереди искали:
- в KAC, SMAC, SourceBans, ProcessCmds, Metamod, версиях SourceMod;
- в SourceTV, Stripper, коде удаления entity, хостинге.

Ничего из этого не помогло. Сообщения из тех тем согласуются с испорченной кучей glibc, но по отдельности с этим
багом не сверены:

- `SV_PackEntity: SnagChangeFrameList returned null` (то же, что выше);
- `terminate called after throwing an instance of 'std::bad_alloc'` с `operator new[]` ←
  `sp::CompilerBase::CompilerBase` (`sourcepawn.jit.x86.so`), то есть JIT плагина не смог выделить память;
- `Can't load lump 8, allocation of N bytes failed!!!` при загрузке карты;
- `[SM] Plugin encountered error 28: Out of memory` у плагина с нормальной кучей.

Отчёты Accelerator на v34 бесполезны: символов для этой сборки у него нет, а «обращение по нулевому указателю»
в них — это кадр жертвы. У клиентов в момент падения иногда было
`Couldn't dispatch user message` / `Server connection timed out`.

### Причина

`CNavMesh` хранит отдельный список зон навигации с флагом `NAV_MESH_TRANSIENT` (бит атрибутов `0x100`). Это зоны,
которые могут динамически перекрываться: двери, разрушаемые объекты, блокировка маршрутов Valve на cs_havana.

```cpp
CUtlVector<CNavArea *> m_transientAreas;   // v34 linux: TheNavMesh + 0x510
```

- **Заполнение:** `CNavMesh::AddNavArea()` добавляет каждую TRANSIENT-зону при загрузке `.nav`.
- **Использование:** `CCSBotManager::StartFrame()` периодически проходит по списку (запись наблюдалась раз в ~2,5–3 мин)
  и вызывает `CNavArea::UpdateBlocked()` для каждой зоны. Та записывает результат в `CNavArea::m_isBlocked`
  (`mov %bl,0x30(%ebp)`).
- **Нет очистки:** в v34 `CNavMesh::DestroyNavigationMesh()` удаляет все объекты `CNavArea`, но **не очищает**
  `m_transientAreas`. В Source SDK 2013 там есть `m_transientAreas.RemoveAll()`
  (`src/game/server/nav_mesh.cpp`, `DestroyNavigationMesh`), то есть Valve позже это исправила.

После смены карты в списке остаются указатели на освобождённые зоны прошлой карты, а новые записи добавляются следом.
Менеджер ботов продолжает писать `m_isBlocked` в память, которую glibc уже отдала кому-то другому. Тот объект, что
там теперь лежит, получает один байт `1`. Это может быть указатель на таблицу виртуальных функций, указатель в списке
свободных блоков malloc, элемент массива и т.д. Поэтому место падения выглядит случайным и всё время меняется.

Без исправления список только растёт: `cs_havana` (15) → `de_dust2_unlimited` (+1 = 16) → `de_dust2` (те же 16, все битые).

#### Как нашли

1. В дампах за разными местами падений стояла одна картина: `0x01` в освобождённом маленьком блоке.
2. Ловушка-аллокатор (`LD_PRELOAD`) держала освобождённые блоки до 64 Б в карантине, заполненными `0xA5`, и проверяла их
   при выходе из карантина. Она периодически сообщала `UAF-WRITE` (один байт стал `0x01`) по одному и тому же адресу
   внутри процесса, всегда примерно через одно окно карантина (~150 с) после освобождения.
3. Аппаратная точка останова (gdb) на этом адресе 5 раз из 5 поймала запись:
   `CNavArea::UpdateBlocked()` ← `CCSBotManager::StartFrame()` на освобождённой `CNavArea`.
4. Поиск по живой памяти нашёл висячий указатель в `TheNavMesh + 0x510`, то есть в `m_transientAreas`.
   По дизассемблеру `server_i486.so` этот вектор трогают только конструктор/деструктор, `AddNavArea`,
   `RemoveNavArea`, `CommandNavToggleAttribute` и `CCSBotManager::StartFrame`. `DestroyNavigationMesh` его не трогает.
5. Подтверждение:
   - снятие бита `0x100` в затронутых `.nav`: 4 дня 20 часов без падений и 0 срабатываний ловушки
     (до этого ~1 падение в сутки);
   - затем этот плагин с оригинальными `.nav`: тот же результат.

### Исправление

На `OnMapEnd` плагин ставит `m_transientAreas.m_Size = 0`. Для вектора указателей это ровно `CUtlVector::RemoveAll()`:
деструкторы не вызываются, буфер остаётся и переиспользуется. Загрузка навигации следующей карты заново заполняет
список через `AddNavArea()`, поэтому динамическая блокировка на картах вроде cs_havana продолжает работать.
Править `.nav` не нужно.

Перед записью плагин проверяет, что поля похожи на `CUtlVector`: `0 <= size <= allocationCount`, и указатель на память
не нулевой при `size > 0`. Если это не так (не тот бинарник или смещения), он только пишет ошибку в лог.

В логе на каждой смене карты с TRANSIENT-зонами:

```
[navmesh_transient_fix.smx] Cleared 15 transient nav area(s) on map end
```

`sm_navfix_status` (консоль сервера) показывает текущее состояние:

```
[navfix] TheNavMesh=0x93caa60 transient list mem=0xa710da0 alloc=16 size=15 (ok)
```

### Затронутые карты

Любая карта, в `.nav` которой есть хотя бы одна зона с атрибутом `0x100` (TRANSIENT), если на сервере есть боты.
Цикл `CCSBotManager` работает только при ботах. Примеры с одного сервера:

| Карта | TRANSIENT-зон |
|-------|---------------|
| `cs_havana` (Valve) | 15 |
| `de_dust2_unlimited` (кастомный nav) | 1 |
| de_dust2, de_inferno, cs_italy, cs_office, de_nuke, de_train, de_aztec, cs_assault, cs_militia, de_cbble | 0 |

Ротация только из карт без TRANSIENT-зон не затронута. Хватает одной зоны: на сервере с одной `de_dust2_unlimited`
каждый `changelevel` по таймлимиту оставляет ещё один битый указатель.

Чтобы посчитать TRANSIENT-зоны в `.nav` (формат v9, как в CS:S v34), проверьте бит `0x100` в слове атрибутов каждой зоны.
Другой способ: загрузить карту с этим плагином и выполнить `sm_navfix_status`.

### Это не тот баг

SIGSEGV в `CCSBot::IsVisible()` ← `AttackState::OnUpdate()` на уничтоженном игроке (указатель на таблицу виртуальных
функций равен 0), сразу после кика ботов. Например, `Kicking client "…" for killing too many hostages` при
`mp_hostagepenalty > 0`, или боты, убранные через `bot_quota` / `bot_auto_vacate`. Это отдельная проблема ботов v34:
бот продолжает атаковать цель, которую только что удалили. Этот плагин её не исправляет. Что помогает:
`mp_hostagepenalty 0` и удаление ботов только когда они мертвы.

### Требования / совместимость

- CS:S **v34** (до OrangeBox, движок EP1), **Linux** `server_i486.so`. На других версиях движка плагин не загрузится.
- SourceMod **1.4+**. Написан на старом синтаксисе и собран один раз `spcomp` 1.4.2, один и тот же `.smx` работает
  на 1.4 … 1.13. Эта сборка проверена на 1.13.0.7394, прототип на новом синтаксисе работал на 1.11.0.6522.
- Без расширений: только gamedata и `LoadFromAddress`/`StoreToAddress`.
- Windows не поддерживается: там нет экспортированного символа `TheNavMesh`, нужны сигнатура и свои смещения.

### Установка

Скачайте zip из [Releases](../../releases) и распакуйте в папку игры (`cstrike/`):

```
addons/sourcemod/plugins/navmesh_transient_fix.smx
addons/sourcemod/gamedata/navmesh_transient_fix.games.txt
```

После установки перезапустите сервер. Процесс, который уже менял карты, может держать битые указатели в памяти,
чистым гарантированно будет только новый процесс.

### Сборка

`tools/build-release.sh` собирает плагин входящим в репозиторий `tools/compilers/sm1.4.2-linux/spcomp`
(32-битный, нужны `lib32stdc++6` и `lib32z1`) и кладёт `dist/navmesh_transient_fix-<версия>.zip`. Версия берётся
из тега `vX.Y.Z`; если тега нет — из заголовка последнего коммита; если и там нет — из `PLUGIN_VERSION`.
GitHub Actions (`.github/workflows/release.yml`) запускает сборку на каждый тег `v*` и прикладывает zip к GitHub Release.
Ручной запуск (`workflow_dispatch`) только выкладывает артефакт.

### Ограничения

- Покрыта только смена карты. Перезагрузка навигации посреди карты (`nav_load`, `nav_generate`, `nav_analyze`)
  пересоздаёт зоны без конца карты и даёт ту же проблему. Это команды для разработки, на обычном сервере
  они не используются.
- Смещения подобраны под linux-бинарник v34. На другой сборке проверьте их через `sm_navfix_status`: должно быть
  `(ok)`, а `size` равен числу TRANSIENT-зон на карте.
