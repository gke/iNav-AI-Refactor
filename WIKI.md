# iNav-AI-Refactor — Work to date

> **For interest only. All care and no responsibility.**
> This firmware has **not been flown** (status as of 2026-09-24). It has been
> build-verified on the bench only and is not validated for use in any
> aircraft.

## What this is

iNav-AI-Refactor is a personal, AI-assisted refactoring of **INAV 9.1.0**
flight controller firmware. It applies a strict personal C standard and an
SI-unit discipline to the entire source tree while preserving INAV's
observable behaviour and its **iNavConfigurator interface** (MSP/MSP2 layout,
CLI, settings, Parameter Groups, firmware version) unchanged.

## Work done so far

### 1. Tree-wide coding-standard sweep

The whole tree was brought to a documented personal C standard
(see "The rules" below):

- **Style:** 4-space indent, K&R brace style (opening brace on the same line),
  `//` comments, 80-column lines, functions capped at 100 lines.
- **Braces:** unnecessary braces around single statements removed (~3,800
  sites), classified conservatively so dangling-`else` cases were never
  touched.
- **Header guards:** 18 headers converted to `#pragma once` (vendor files
  excluded).
- **Type naming:** enum/struct/type tags normalised to the `_e` / `_t`
  suffixes (e.g. `BlackboxState` → `blackboxState_e`, `fp_angles` →
  `fp_angles_t`).
- **Memory attributes:** deprecated/empty placement attributes removed;
  `SLOW_RAM` use eliminated.
- **Audits:** Parameter Group version/ID audit (all 54 PGs consistent), and a
  MISRA C:2012 static-analysis pass to locate required-rule violations in
  project code.

Every step was token-neutral and approach-preserving: original code paths,
error handling and licence headers are retained throughout.

### 2. SI-unit mapping nucleus

New module `src/main/mapping/unit_map.{c,h}` is the single place where
legacy wire units and SI internals meet. It owns the conversions for:

| Quantity | Wire / legacy | Internal (SI) |
|----------|---------------|---------------|
| Angle | decidegrees / centidegrees / degrees | radians |
| Length | cm / dm | metres |
| Velocity | cm/s | m/s |
| Time | microseconds | seconds |
| Voltage | centivolts | volts |
| Current | centiamps | amperes |
| Power | centiwatts | watts |
| Temperature | decidegrees C | °C |

The "From" conversions use the exact legacy expression they replace, and the
"To" conversions round to nearest, so wire output stays byte-identical. The
first wired seat is **TIME**: the estimator dT in `imu.c` and the six
`power_limits` µs→s rescales now call through the mapping seat (guarded for
review; the default build is byte-identical).

**GPS note:** coordinates are deliberately *not* routed through this module.
Lat/lon stay `int32` 1e-7 degrees end to end (wire, storage, MSP, PG,
blackbox); internal mission math converts to origin-relative local metres via
exact integer delta subtraction in `geoConvertGeodeticToLocal()`.

### 3. Offline standalone build harness

- Builds entirely offline — no upstream fetch, no network, no Docker.
- Auto-detects an on-box `arm-none-eabi` toolchain (e.g. the xPack toolchain);
  no GCC pinning.
- Generic: accepts any `TARGET=<name>` under `src/main/target`, with MCU
  detection and an all-target sweep.
- Verified clean on **BLUEBERRYF405** (a.k.a. MATEKF405TESD). The locked
  build links at ~99% SRAM by design; stack and ISR data live in CCM, with a
  fixed 2 KB runtime heap — no stack overflow risk, no new static
  allocations. The Ruby settings tooling was reproduced in Python (offline).

### 4. Rules linter

`src/utils/rules_lint.py` is a report-only compliance linter for rules 1–18,
with a `--changed-lines` mode for review of edits. It is advisory: the build
is the arbiter.

## The rules

The personal standard applied throughout the tree:

1. **No `goto`** — exactly one exit per function; `return` only on the last
   line.
2. **No division** operators (`/`, `%`) except inherent math; divide by a
   constant via multiply-by-inverse.
3. **No braces for single statements.**
4. **Prefer `switch`** over deep if-else chains (3+ branches); cyclomatic
   complexity < 10.
5. **No assignments inside `if()`.**
6. **ISRs minimal** — state machines, flags, and queue-feeding only; never
   heavy work from interrupt context.
7. **No `malloc`/`free`**; no pointer arithmetic; casts only to/from `void*`;
   static or pool allocation; zero sensitive memory after use.
8. **Bounds-check all array accesses**, except loops whose bound is ≤ 10 and
   known at compile time.
9. **Preserve all code and error handling** during refactoring; keep
   file-header licence blocks and comments that still hold; delete stale
   ones.
10. **Functions ≤ 100 lines** (60–80 ideal); larger bodies are split into
    static helpers.
11. **Macros/constants `UPPER_CASE`**, everything else snake_case; no leading
    underscores; `#define` for compile-time constants, `const` for typed
    values.
12. **`//` comments preferred** (`/* */` acceptable); comments explain WHY,
    not WHAT.
13. **No typedef for structs/unions/enums** (function pointers and opaque
    types excepted).
14. **No magic numbers** — named constants or enums; only 0, 1, NULL exempt.
15. **Max line length 80 characters.**
16. **K&R brace style** — no newline before `{` after `if`/`else`/`for`/
    `while`/`switch` or a function header.
17. **`FLOAT` for physical quantities** end to end (internal float32 state;
    `FLOAT64`/double where applicable); integers only for genuinely
    raw/quantised data — GPS 1e-7, ADC/PWM counts, enums, channel indices.
18. **MISRA C:2012** for new and edited code: no recursion, no dynamic
    allocation, explicit boolean types, `default` in every `switch`, fixed
    explicit loop bounds.

**Naming details:** enum constants are lowerCamelCase with a lowercase `e`
prefix (`eClassExplicit`); `params.c` parameter names start with lowercase
`p`; code adapted from external projects carries attribution comments.
**Fork deltas:** `//` comments used across the codebase (licence headers, and
`/* */` straddled by code on the same line, kept as-is); rule 3 applies to
control-flow braces while every function closing brace is tagged
(`} // function_name`). Because wire formats are frozen, legacy integer units
survive only behind the mapping module's boundary, so rule 17's "internal
floats" never touch the wire.

## Status and next steps

- All work above is build-verified; the mapping seats are compile-verified
  (flag-on and flag-off), and the default build is byte-identical to stock.
- **Not flown.** Flight/bench testing has not begun and is not planned as a
  formal achievement of this repository — treat the tree as a study artifact.