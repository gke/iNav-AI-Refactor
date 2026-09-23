# iNav-AI-Refactor

A personal, AI-assisted refactoring project based on **INAV 9.1.0** flight
controller firmware.

This repository is a laboratory exercise: it applies a strict personal C
coding standard and SI-unit discipline to the whole INAV source tree while
keeping INAV's observable behaviour, protocols, and configuration contracts
unchanged.

## Status: NOT FLOWN

**This firmware has not, as of 2026-09-24, ever been flown.** It has been
build-verified on the bench only. It has not been flight-tested, bench-tested
with motors or servos, or validated for any real-world use.

## For interest only — all care and no responsibility

This project is published **for interest only**. It is provided **all care
and no responsibility** and with **no warranty of any kind**. Use it entirely
at your own risk. Nothing here should be regarded as suitable for use in an
actual aircraft.

## What this version of INAV is

- A wholesale refactor of the INAV source tree to a documented personal
  standard (see the wiki for full details), including a tree-wide style
  sweep, header-guard and naming normalisation, brace simplification, and a
  MISRA C:2012-aligned audit.
- An **SI-unit mapping nucleus** (`src/main/mapping/unit_map.*`) — a single
  module that owns every legacy-wire ⇄ SI conversion (angle, length,
  velocity, time, voltage, current, power, temperature), so subsystems hold
  SI floats while all wire and persistence formats stay byte-identical.
- An **offline, standalone build harness** that auto-detects an on-box
  `arm-none-eabi` toolchain and supports any target under `src/main/target`,
  verified on BLUEBERRYF405.
- A **report-only rules linter** (`src/utils/rules_lint.py`) that tallies
  compliance against the personal rules 1–18.
- A deliberately conservative approach: every refactor preserves original
  code and observable behaviour, and changes are compile-verified before they
  are accepted.

## iNavConfigurator compatibility

This project is based on **INAV 9.1.0**, and the interface with
**iNavConfigurator** is preserved intact: MSP/MSP2 packet layouts, CLI
commands, `settings.yaml` names and lookup tables, Parameter Group layouts
and IDs, and the firmware/semver string that the Configurator gates on are
all unchanged. Legacy wire units (decidegrees, centidegrees, etc.) are
converted to SI only at the boundary, by the unit-mapping module, so the
Configurator behaves exactly as it does with stock INAV.

## Repository layout

Binaries are **not** included. This repository carries source, build scripts,
tools, and documentation only.

| Path | Purpose |
|------|---------|
| `src/main/` | Source tree, including `mapping/` unit-mapping nucleus |
| `src/utils/rules_lint.py` | Report-only rules linter (rules 1–18) |
| `AGENT.md` | Project rules and guidance for AI agents |
| `wiki/` → see project wiki | Single-page "Work to date" |

## Licence and credits

Based on [INAV](https://github.com/iNavFlight/inav), whose licence and
copyright headers are preserved throughout. INAV is GNU GPL v3, and so is
this project.

See also: [INAV documentation and wiki](https://github.com/iNavFlight/inav/wiki).