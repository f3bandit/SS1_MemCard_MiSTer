# SS1 Memory Card Tool (MiSTer core)

Backs up a PlayStation memory card plugged into the SuperStation One's **front port 1** to a
file, checks a card against a file and, when SS1 Tool asks for it, writes a file back to the card.

It's made to be launched by [SS1 Tool](https://github.com/f3bandit/ss1_tool), which creates the
files, starts the core and reads the result. It also works on its own from MiSTer's menu.

## Using it on its own

1. Copy `SS1_MemCard_<date>.rbf` to `/media/fat/_Utility/`.
2. Put a 128 KB card file in `/media/fat/games/SS1_MemCard/` (a blank one works; it gets overwritten).
   That's the folder the core's **Card file** menu opens.
3. Load **SS1_MemCard** from the core list, put a card in front port 1, then open the menu and
   choose **Card file**. The backup starts as soon as the file is mounted.

Menu options:

| Option | What it does |
|---|---|
| Card file | The file the card is backed up to, or checked against (128 KB: .mcd, .mcr or .sav) |
| Job file (SS1 Tool) | Used by SS1 Tool; nothing to choose here when using the core on its own |
| Back up card to file | Reads the whole card and saves it to the file |
| Check card against file | Reads the card and shows which sectors differ from the file |
| Back up when file mounted | Starts a backup as soon as a card file is chosen (default On) |
| Card speed | Normal (250 kHz, like a PlayStation) or Slow (125 kHz, for cards that struggle) |
| If sectors fail | Don't save (default), or save anyway with the failed sectors |

The menu button and Launch Console Mode work as in any other core. Reset clears the screen.

## Writing to a card

Only SS1 Tool can start a write (job 3); the menu has no write option. SS1 Tool first backs the
card up, builds the new image from that backup (for example with a save added), then asks for
the write. The core compares every sector with the file and writes only those that differ, then
reads each one back: it's marked blue on the map once it matches. A sector that won't take the
write is tried 6 times and then marked red; SS1 Tool still has the backup from just before.

## The screen

A 32 x 32 map shows all 1024 sectors of the card as they're read: green read fine, yellow
needed a retry, red failed, purple differs from the file. Every sector is tried up to 6 times.
Nothing is written to the file unless every sector was read (or "Save anyway" is on).

## How SS1 Tool drives it

SS1 Tool writes an MGL file that loads the core and mounts two files: the card file (drive 0)
and a job file (drive 1). The job file asks for the job and gets the report back:

| Offset | Request (SS1 Tool) | Report (core) |
|---|---|---|
| 0 | `SMCQ` | `SMCP` while the job runs (every 0.25 s), `SMCR` when it's finished |
| 4 | | version |
| 5 | job: 1 backup, 2 check, 3 write the file to the card | job |
| 6 | | result: 1 OK, 2 OK with retries, 3 sectors failed, 4 no card, 5 differs, 6 file not 128 KB, 7 file read only, 8 saved with failed sectors, 9 card written |
| 7 | | card: 0 none, 1 formatted, 2 not formatted |
| 8 | id (4 bytes) | same id |
| 12 | | sectors OK, retried, failed, different, total retries, done (16-bit each) |
| 24 | | slow speed used |
| 25 | | phase: 2 loading the file, 3 reading the card, 4 saving the file |
| 26 | | sector being read (16-bit) |
| 28 | | sectors written (16-bit) |
| 512 | | one byte per sector: 1 OK, 2 retried, 3 failed, 4 different, 5 written and checked |

The job file is 1536 bytes.

## Building

GitHub Actions builds the core with Quartus 17.0.2 Lite on every push (see
`.github/workflows/build.yml`) after the simulation passes. To simulate locally (Icarus Verilog):

```
sh sim/run.sh
```

## License

GPL-3.0-or-later. `sys/` is MiSTer's standard framework (GPL-2.0-or-later), used by every MiSTer core.
