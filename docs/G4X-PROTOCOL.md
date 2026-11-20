# Link G4X USB protocol — reverse-engineering notes

> **Confirmed on a real ECU (2026-11-19):** Link G4X Xtreme Plug-in family, Link ID 23000,
> firmware 6.31.2, bootcode 6.28.1, cable FTDI FT232H 0403:7069. Read-only traffic only.
>
> - Framing, CRC-16/XMODEM, address `0x5B`, 4 687 500 baud: **confirmed**.
> - Error reply = command **`0x19`**, payload u16 error code. The broadcast identify
>   (`0x0A` on `0x7D`) is answered from `0x5B` with error `0x0020` — not used on G4X.
>   `0x3B` → error `0x1D`, `0x3D` → error `0x1A` (no comms board).
> - `0x0B` capabilities: u16 at +0x12 = max DataId (5001); byte +0xB = 10 → 1016-byte packets.
> - `0x16`/`0x18` version: bytes 8.. = major (u8), minor (u16), build (u16) → 6.31.2 / 6.28.1.
> - **`0x2B` read**: request payload `[DataId u16][arg u16]` + zeros (56 bytes); reply payload
>   `[00 00][type u16][value 4 bytes BE]`. Type 1 = float scalar, 5 = float table cell,
>   2 = integer option. **Values are already in display units.** For tables `arg` = cell
>   index (row-major); for scalars `arg` = `0xFFFF`.
> - A whole tune (2 940 settings, ~19 000 values) reads in 38 s and matched the
>   tune file saved from PCLink exactly except 3 runtime values.
>
> Sections below are the original static-analysis notes; where they disagree, the box above wins.

Source: static analysis of **PCLink 7.8.2** (`PCLink.exe`, 32-bit C++Builder), class
`TECUProtocolG4x` and its FTDI transport. **Nothing here has been checked against a
real ECU yet** — see the first-connection checklist at the end.

## Transport

| Item | Value | Where |
|---|---|---|
| USB | FTDI, VID `0x0403`, PID `0x7068`–`0x706F` (custom) | `linkbus.inf` |
| Driver API | D2XX (`ftd2xx.dll`), imported by ordinal | import table |
| Framing | 8 data bits, no parity, 1 stop (`FT_SetDataCharacteristics(8,0,0)`) | `0x44F9F8` |
| Baud | **4 687 500** for FT232H (chip type 8), **1 171 875** for FT-X (type 9) | `0x44FC62`–`0x44FC91` |
| Timeouts | write 300 ms; read set per command (125 ms … 30 s) | `0x44FA14` |
| Before each command | `FT_Purge(RX|TX)`, then a mutex (`WaitForSingleObject`) | `0x426200` |

On macOS Apple's FTDI driver won't claim the custom PIDs, so OpenLink Tuner talks to the
cable through **libftdi** (`(OpenLink Tuner bundles libftdi; for your own tools: brew install libftdi)`).

## Frames

Request (`TECUProtocolG4x::SendCommand`, `0x426200`):

```
5A | addr | cmd_hi cmd_lo | len_hi len_lo | payload… | crc_hi crc_lo
```

- `len` = payload length **+ 2** (includes the CRC), big-endian.
- `addr` = **`0x5B`** normally; **`0x7D`** is the broadcast address used during discovery.
- CRC = **CRC-16/XMODEM** (poly `0x1021`, init `0x0000`, MSB-first, no final XOR) over
  every byte before it (`0x47D754`). Check value: `"123456789"` → `0x31C3`.

Response (`0x426598`):

```
addr | 5A (or 01) | cmd_hi cmd_lo | len_hi len_lo | payload… | crc_hi crc_lo
```

PCLink reads 6 header bytes, checks the address and the `5A`/`01` byte, reads `len`
more bytes, and requires the CRC over header + body to come out **0**. While waiting it
keeps reading; packets whose command is `0x2B`, `0x2A` or `0x0F` are handed to the
parameter dispatcher (`0x424FF0`) — so the ECU may push parameter data unsolicited.

Response payload values are big-endian (`u8`/`u16`/`u32` helpers at `0x425D18`–`0x425D38`).

Example — connect/identify on the broadcast address: `5A 7D 00 0A 00 02 2D E9`.

## Connect sequence (`0x425B9C`)

1. Set address to `0x7D` (broadcast).
2. Send `0x000A` (or `0x0007`) with no payload.
3. Read until a response echoing the same command arrives.
4. Set address back to `0x5B` for all further traffic.

## Commands found

Read-only (the only ones OpenLink Tuner will send):

| Cmd | Meaning (inferred) | Payload | Response |
|---|---|---|---|
| `0x07` | discovery (broadcast) | — | identify data |
| `0x0A` | identify / connect (broadcast) | — | identify data |
| `0x0B` | capabilities | — | u16 fields at +2,+4,+6,+8,+0x12; byte at +0xB → max packet = `(1<<n)−8` |
| `0x16` `0x18` `0x3B` `0x3D` | firmware / bootcode / other / comms versions | — | u32 + 3 bytes |
| `0x2B` | **read parameter by DataId** | 56 bytes: DataId (u16), arg (u16), zeros | parameter record |

**Blocked in OpenLink Tuner** (never sent):

| Cmd | What it does |
|---|---|
| `0x14` | **write memory/flash** — 32-bit address, 32-bit word count, ≤1 KB data, 30 s timeout |
| `0x2A` | **write parameter values** — DataId, `FF FF`, array of values |
| `0x20` | likely "store to flash" (1.5 s timeout, no payload) |
| `0x21` | likely reset (followed by a 500 ms pause) |
| `0x22` / `0x12` | mode switches (one followed by a 2 s wait — bootloader-like) |
| `0x1E` `0x23` `0x24` | set values (32-bit, bool, four u16) |
| `0x2E` | paged **file transfer** with a filename — ECU log download |
| `0x33`–`0x35` | in the firmware-update code |
| others (`0x03`, `0x04`, `0x0D`, `0x10`, `0x11`, `0x15`, `0x1A`, `0x1B`, `0x1F`, `0x27`, `0x2F`, `0x32`, `0x36`, `0x38`, …) | not yet identified |

## Reading a whole setting

PCLink's read loop (`0x425C40`) sends `0x2B` with payload `[DataId][FF FF]` — `0xFFFF`
means "all values". The dispatcher places each returned record's values at its start
index, so large tables may come back as several records. OpenLink Tuner's reader does the
same (`LinkECU.readAll`) and uses it to read a complete tune.

Number scaling isn't in `ECU.cfgr`; it's in each tune's `<D…>` elements (`Multi`,
`Offset`, stored as float32). For 21 settings it varies between tunes (bundled list
`Templates/variable-scale.json`) — those are flagged CHECK SCALING when read as integers.

## Parameter record (responses to `0x2B`; also `0x2A`, `0x0F`)

Read by the dispatcher at `0x424FF0`:

| Offset | Field |
|---|---|
| +2 | data type (u16) |
| +4 | DataId (u16) — the same IDs as in tune files and `ECU.cfgr` (e.g. 1000 = Engine Speed) |
| +6 | start index (s16; −1 → 0) |
| +8 | count (u16) |
| +10 (inferred) | values, 4 bytes each, big-endian |

Type codes: `1`, `5` → IEEE float32; `2`, `3`, `8`, `9` → int32; `4`, `7` → blob/string.
Integer values are probably in ECU wire units — multiply by the tune's `Multi` and add
`Offset` (the attributes on each `<D…>` element in a `.pclx`).

## Writing — static analysis only (NOT enabled, never sent)

Everything below comes from reading PCLink's code. **No write has ever been sent to an ECU**;
OpenLink still refuses `0x2A`, `0x20`, `0x21` and `0x14` in two places.

| What | Command | Payload | Where in PCLink |
|---|---|---|---|
| Write one setting / table cell | `0x2A` | 56 bytes: `[DataId u16][cell index u16, 0xFFFF for scalars][value 4 bytes BE]` — float32 bits for float settings, int32 for options (PCLink converts by type at `0x425479`) | builder `0x427A14` |
| Write a text setting | `0x2A` | `[DataId][FF FF][UTF-16 chars + 00 00]` (count×2+2 bytes) | builder `0x427A80` |
| Store to permanent memory | `0x20` | none, 1.5 s timeout | `0x427D38`, wrapped at `0x425B08` |
| Reset/restart ECU | `0x21` | none, 1 s timeout, then 500 ms pause | `0x427D04` |
| Memory/flash block write | `0x14` | 32-bit address, word count, ≤1 KB | **firmware updater only** (`FWUpdater\G4XProgramFirmware.cpp`) — never needed for tunes |

The single-value write is the mirror image of the read that's confirmed on a real G4X: same
56-byte payload with the value added. Writing Fuel Table2 cell 22 = 25.5 would be
`… 09 3F 00 16 41 CC 00 00 …`, and `41 CC 00 00` is exactly what the ECU returned when that
cell was read.

PCLink's sequence for an edit is: write the value (`0x2A`), then later **Store** (`0x20`)
to make it permanent. Until stored, a written value most likely lives only in the ECU's RAM
and is lost at the next power cycle — which makes "write, read back, power cycle" a natural
safe first test.

### What static analysis can't settle

- **Which address.** PCLink sends parameter reads, writes and store through the address
  `0x7D` and switches back to `0x5B` afterwards (`0x425503`, `0x425B0C`) — on a newer path it
  picks when a version number is ≥ 1012 (`0x431794`). A real G4X (fw 6.31.2) answered our reads
  on `0x5B` with a simpler reply format, and answered an identify sent to `0x7D` with an error.
  So it isn't certain whether writes for this ECU go to `0x5B` or `0x7D`, or what the reply
  to a write looks like.
- **Store semantics** (does `0x20` need anything first; how long it takes on a big tune).

Both are answered by recording real PCLink writing one harmless setting (see below), so
nothing is guessed on a car.

### Safe path to enabling writes

1. **Capture.** Run PCLink in a Windows VM with the Link cable passed through and record the
   USB traffic (Wireshark + USBPcap) while changing one harmless setting (e.g. a dash/
   display value) and pressing Store. Compare with the table above.
2. **One value, RAM only.** Engine off. Write that one setting, read it back, write the old
   value back, read again. No store.
3. **Store.** Confirm `0x20` persists across an ignition cycle.
4. **Only then**, in the app: off by default; engine must read 0 RPM; full tune backup read
   first; a preview of every change; only changed values sent; every value read back and
   compared; any mismatch stops and offers the backup; `0x14` (firmware) permanently blocked.

## Other

- An 8-byte XOR obfuscation routine exists at `0x47D790` (key at `0x8FBA44`); not yet
  seen on the wire.

---

## Trying OpenLink on a Link ECU that hasn't been tested yet

1. Power the ECU (ignition on, engine **off**) and plug the Link USB cable into the Mac.
2. Open OpenLink Tuner. If it doesn't know your ECU model yet, open any tune file from that
   ECU once (File → Open) or use **ECU → Import ECU Layouts from PCLink Installer…**.
3. **ECU → Read Tune from ECU.** Check the ECU model (Link ID) it reports and compare a
   few tables (fuel, ignition) with what PCLink shows.
4. Open **Live**, choose **Link USB**, and check RPM against your dash at idle.
5. Whatever happens, please open a GitHub issue with your ECU model, firmware version and
   the newest log from `~/Library/Logs/OpenLink Tuner/usb-*.log` (every frame sent and
   received is in it). Note: the ECU's version reply includes the name of the PC that last
   programmed it — remove that line if you'd rather not share it.
6. Writing to the ECU stays off until it has been verified against real PCLink traffic.
