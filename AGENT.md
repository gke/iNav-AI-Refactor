# AGENT.md - Guide for AI Agents Working with INAV

---

## iNavgke fork — project rules (these override anything below that conflicts)

**Goal.** Tidy iNav to a strict personal C standard and keep it flyable. Do not
diverge from iNav's observable behaviour or protocols.

### iNav Configurator compatibility is a release gate

Never change:

- MSP/MSP2 packet layout, field order, offsets, scaling, or command IDs — USB,
serial, and MSP-over-telemetry alike.
- `src/main/fc/settings.yaml` setting names, types, or lookup tables.
- Parameter Group struct layouts, field types, or PG IDs/versions (unless a
version bump is deliberately intended).
- Target IDs / `__TARGET__` names, or the `src/main/target/<TARGET>` contract.
- The firmware version/semver string (currently `9.1.0`) that the Configurator
gates on.
- CLI command names and observable behaviour.

Do not rename or reinterpret legacy wire units (decidegrees, centidegrees, etc.) —
convert at the boundary only.

### Build stays standalone and generic

- **Fully offline:** never fetch from the iNav upstream repo, the network, or
Docker at build time.
- **No GCC pinning:** use the local user-space `arm-none-eabi` toolchain (xPack
at `~/toolchain/xpack-arm-none-eabi-gcc-15.2.1-1.1`) and auto-detect it.
- **Target flexibility:** the build must accept any `TARGET=<name>` under
`src/main/target`, like upstream `./build.sh <TARGET>` — never hardcode a board.
- **No Ruby dependency:** `src/utils/settings.rb`, `compiler.rb` and
`build_stamp.rb` are to be reproduced in Python (offline).

### Refactor rules (the personal standard)

Pure classic C (C99/C11).

Control flow:
1. No `goto`. Exactly one exit per function — `return` only on the last line;
   no early returns.
2. No division operators (`/` or `%`) anywhere except inherent math that can't
   be avoided (e.g. overshoot %). Divide by a constant/literal → multiply by its
   inverse instead (`x / 100.0f` → `x * 0.01f`).
3. No braces for single statements. Minimal, readable expressions.
4. `switch()` over deep if-else chains (3+ branches). Encapsulate repetitive
   code. Cyclomatic complexity < 10.
5. No assignments inside `if()`.
6. ISRs minimal — simple state machines / flag-setting / queue-feeding only;
   never KF/trig/nav/flash from interrupt context.

Memory:
7. No malloc/free. No pointer arithmetic (except the ≤10-loop exemption in 8).
   No casting between pointer types except to/from `void*`. Static allocation or
   pool allocators. Zero sensitive memory after use.
8. Bounds checking on ALL array accesses EXCEPT when loop bound ≤10 AND known
   at compile time:
   `if (index < SIZE) { access; } else { handle_error(); }`

Refactoring:
9. Preserve ALL code (and error handling) during refactoring. Keep comments
   that still reflect the code; delete stale ones. NEVER remove the main
   file-header comment block (nor copyright/licence headers).
10. Functions max 100 lines absolute (60–80 ideal); exceeding requires
    refactoring into static helpers.

Style:
11. Macros/constants UPPER_CASE. Everything else matches existing conventions;
    default snake_case. No leading underscores. `#define` for compile-time
    constants; `const` for type safety; enum constants valid as switch labels.
12. `//` comments preferred; `/* */` acceptable. Comments explain WHY, not WHAT.
13. No typedef for structs (except function pointers / opaque types).
14. No magic numbers — named constants or enums; only 0, 1, NULL exempt.
15. Max line length: 80 characters.
16. **No newline before `{` after `if`/`else`/`for`/`while`/`do`/`switch` or function headers** — K&R style: opening brace stays on the same line as the control statement or function signature.
    ```c
    // Correct
    if (condition) {
        doSomething();
    } else {
        doOther();
    }
    
    for (int i = 0; i < n; i++) {
        process(i);
    }
    
    while (running) {
        loop();
    }
    
    do {
        init();
    } while (!ready);
    
    switch (value) {
        case A: handleA(); break;
    }
    
    void functionName(void) {
        // body
    } // functionName
    
    // Incorrect
    if (condition)
    {
        doSomething();
    }
    
    while (running)
    {
        loop();
    }
    
    switch (value)
    {
        case A: handleA(); break;
    }
    ```

Types:
16. `real32` for physical quantities end-to-end (FC struct fields, wire
    packets, GCS models, .af config); integers only for genuinely raw/quantised
    data (GPS 1e7, ADC/PWM counts, enums, channel indices).

Naming specifics:
- param names in params.c start with lowercase `p`.
- enum constants are lowerCamelCase with a lowercase `e` prefix
  (eClassExplicit); enum type names stay PascalCase (ParamClass).
- Code adapted from an external project must carry an attribution comment:
  `// Based originally on work by <author/source>.`
  `// Adapted <date> by <who>.`

Fork deltas (documented decisions):
- `//` only: user directed `//` over `/* */` across the codebase; file-leading
  licence headers and `/* */` straddled by code on the same line
  (`a; /* why */ b;`) stay as-is. Tighter than item 12.
- Rule 3 applies to control-flow braces; function closing braces get tagged:
  `} // function_name`.
- `real32` internals apply per the unit-mapping note above — the wire/persistence
  defs are frozen, so item 16's "wire packets" stay in legacy int units until
  converted at the boundary by the mapping module.

### Verification

There is no C compiler in the current sandbox. Treat grep/structural checks as
provisional and build-verify before flying.

### Unit mapping architecture (decision note)

Wire definitions are frozen — MSP packet layout/values, `settings.yaml` names,
types and lookup tables, PG field meanings, blackbox field decoding, CLI output
and the GPS wire format are configuration-protocol contracts and are **never
changed**. Legacy/non-SI units appear in exactly one place: a single mapping
module (`src/main/mapping/`) that converts between wire/legacy units and the
SI internals used everywhere else:

- angle ↔ wire int16° / decidegree / centidegree, internal radians
- length ↔ cm / decimeter, internal metres
- velocity ↔ cm/s, internal m/s
- voltage ↔ centivolt/decivolt, internal volts
- current ↔ centiampere, internal amperes
- temperature ↔ decidegreeC, internal °C
- lat/lon ↔ int32 1e-7°, internal radians

Rules:
- Internal state uses SI floats (radians, metres, m/s, V, A, °C). No subsystem
  does its own unit arithmetic.
- Every boundary codec (MSP read/write, CLI print/parse, OSD element, blackbox
  field, telemetry) calls through the mapping module — it is the *only* place
  legacy units live.
- Any change must keep byte-identical wire output; verify against the existing
  build and, where possible, a byte-compare harness.
- Done one subsystem at a time, starting with battery (pilot); the internal
  unit choice can later change with a single-layer edit.

Config scaling ("ConfigRaw"):
- Config values arrive from the Configurator/settings as wire ints (PID gains,
  rate limits, angles, centi-units). They are stored that way (PG layout is
  frozen) but must NOT be re-scaled at every real-time use site
  (`rates[axis] * 10.0f`, `pid[PID_LEVEL].P * FP_PID_LEVEL_P_MULTIPLIER` in
  the PID loop is exactly what this forbids).
- Every scaled quantity has ONE bidirectional scaling routine
  (config → ConfigRaw, ConfigRaw → config) and is materialised into `float`
  runtime state ("ConfigRaw") by a single remap call at ingress: profile load,
  setting change, or MSP write.
- Real-time code reads only the pre-scaled float state; inline `int * multiplier`
  at use sites is banned. Where a scaled value feeds multiple consumers, expose
  it as a field (pidState: kP/kI/kD/kFF/kCD/kT/rateLimit/kLevelP) or a named
  accessor that reads the materialised value.

### RAM headroom on the locked target (decision note)

Build scope is locked to **BLUEBERRYF405** (a.k.a. MATEKF405TESD, STM32F405).
After removing the FASTRAM/FAST_CODE placement attributes, the link sits at
**130,032 / 131,072 B SRAM = 99.21%**, i.e. only ~1 KB spare. This is safe and
deliberately accepted:

- stack/isr are in CCM (64 KB, ~6 KB used) — no stack overflow risk
- iNav's runtime heap is the fixed 2,048 B `dynHeap`
  (`src/main/common/memory.c`) — nothing carves into the spare SRAM

Consequence: there is **no room for any new static allocation** on this target.
Before adding any array/buffer (or raising an existing size) to the locked
build, verify it links and check the RAM line in the link summary. If more RAM
is ever needed, prefer (in order): trimming `WS2811_LED_STRIP_LENGTH` (default
128) in `src/main/drivers/light_ws2811strip.h`, then `MAX_DMA_TIMERS` (default 8)
in `src/main/drivers/pwm_output.c`, before considering linker-placed CCM
relocation of a non-DMA structure.

---

## Project Overview

**INAV** is a navigation-capable flight controller firmware for multirotor, fixed-wing, and other RC vehicles. It is a community-driven project written primarily in C (C99/C11 standard) with support for STM32 F4, F7, H7, and AT32 microcontrollers.

### Key Characteristics
- **Type**: Embedded firmware for flight controllers
- **Language**: C (C99/C11), with some C++ for unit tests
- **Build System**: CMake (version 3.13+)
- **License**: GNU GPL v3
- **Version**: 9.0.1 (as of this writing)
- **Codebase History**: Evolved from Cleanflight/Baseflight

## Architecture and Structure

### Core Components

The INAV codebase is organized into the following major subsystems:

1. **Flight Control (`fc/`)**: Core flight controller logic, initialization, MSP protocol handling
2. **Sensors (`sensors/`)**: Gyro, accelerometer, compass, barometer, GPS, rangefinder, pitot tube
3. **Flight (`flight/`)**: PID controllers, mixers, altitude hold, position hold, navigation
4. **Navigation (`navigation/`)**: Waypoint missions, RTH (Return to Home), position hold
5. **Drivers (`drivers/`)**: Hardware abstraction layer for MCU peripherals (SPI, I2C, UART, timers, etc.)
6. **IO (`io/`)**: Serial communication, OSD, LED strips, telemetry
7. **RX (`rx/`)**: Radio receiver protocols (CRSF, SBUS, IBUS, etc.)
8. **Scheduler (`scheduler/`)**: Real-time task scheduling
9. **Configuration (`config/`)**: Parameter groups, EEPROM storage, settings management
10. **MSP (`msp/`)**: MultiWii Serial Protocol implementation
11. **Telemetry (`telemetry/`)**: SmartPort, FPort, MAVLink, LTM, CRSF telemetry
12. **Blackbox (`blackbox/`)**: Flight data recorder
13. **Programming (`programming/`)**: Logic conditions and global functions for in-flight programming

### Directory Structure

```
/src/main/              - Main source code
├── build/            - Build configuration and macros
├── common/           - Common utilities (math, filters, utils)
├── config/           - Configuration system (parameter groups)
├── drivers/          - Hardware drivers (MCU-specific)
├── fc/               - Flight controller core
├── flight/           - Flight control algorithms
├── io/               - Input/output (serial, OSD, LED)
├── msp/              - MSP protocol
├── navigation/       - Navigation and autopilot
├── rx/               - Radio receiver protocols
├── sensors/          - Sensor drivers and processing
├── scheduler/        - Task scheduler
├── telemetry/        - Telemetry protocols
└── target/           - Board-specific configurations

/docs/                  - Documentation
└── development/      - Developer documentation

/cmake/                 - CMake build scripts
/lib/                   - External libraries
/tools/                 - Build and utility tools
```

## Coding Conventions

### Naming Conventions

1. **Types**: Use `_t` suffix for typedef'd types: `gyroConfig_t`, `pidController_t`
2. **Enums**: Use `_e` suffix for enum types: `portMode_e`, `cfTaskPriority_e`
3. **Functions**: Use camelCase with verb-phrase names: `gyroInit()`, `deleteAllPages()`
4. **Variables**: Use camelCase nouns, avoid noise words like "data" or "info"
5. **Booleans**: Question format: `isOkToArm()`, `canNavigate()`
6. **Constants**: Upper case with underscores: `MAX_GYRO_COUNT`
7. **Macros**: Upper case with underscores: `DMA_RAM`, `STATIC_UNIT_TESTED`

### Code Style

- **Indentation**: 4 spaces (no tabs)
- **Braces**: K&R style (opening brace on same line, except for functions)
- **Line Length**: Keep reasonable (typically under 120 characters)
- **Comments**: Explain WHY, not WHAT. Document variables at declaration, not at extern usage
- **Header Guards**: Use `#pragma once` (modern convention used throughout codebase)

### Memory Attributes

INAV uses special memory attributes for performance-critical code on resource-constrained MCUs:

```c
DMA_RAM                     // DMA-accessible RAM (STM32H7, AT32F43x)
SLOW_RAM                    // Slower external RAM - deprecated, do not use
```

`DMA_RAM`/`SLOW_RAM` are the only memory-placement attributes kept. The former
`FASTRAM`/`EXTENDED_FASTRAM`/`STATIC_FASTRAM`/`FAST_CODE`/`NOINLINE` attributes
were removed: they were linker-placement hints (CCM on F4, DTCM/ITCM on F7/H7)
that compiled to empty attributes on most targets, added churn, and did not
second-guess the toolchain for correctness.

### Test Visibility Macros

```c
STATIC_UNIT_TESTED         // static in production, visible in unit tests
STATIC_INLINE_UNIT_TESTED  // static inline in production, visible in tests
INLINE_UNIT_TESTED         // inline in production, visible in tests
UNIT_TESTED                // Always visible (no storage class)
```

## Build System

### CMake Build Process

INAV uses CMake with custom target definition functions:

1. **Target Definition**: Each board has a `target.h` and optionally `CMakeLists.txt`
2. **Hardware Function**: `target_stm32f405xg(NAME optional_params)`
3. **Build Directory**: Always use out-of-source builds in `/build` directory

### Building a Target

```bash
# From workspace root
cd build
cmake ..
make MATEKF722SE     # Build specific target
make                 # Build all targets
```

### Target Configuration

Targets are defined in `/src/main/target/TARGETNAME/`:
- `target.h`: Hardware pin definitions, feature enables, MCU configuration
- `target.c`: Board-specific initialization code
- `CMakeLists.txt`: Build configuration (optional)

Example target definition:
```c
#define TARGET_BOARD_IDENTIFIER "MF7S"
#define LED0 PA14
#define BEEPER PC13
#define USE_SPI
#define USE_SPI_DEVICE_1
#define SPI1_SCK_PIN PA5
```

### Conditional Compilation

Feature flags control code inclusion:
```c
#ifdef USE_GPS
// GPS code
#endif

#if defined(STM32F4)
// F4-specific code
#elif defined(STM32F7)
// F7-specific code
#endif
```

## Key Concepts

### Parameter Groups (PG)

INAV uses a sophisticated configuration system called "Parameter Groups" for persistent storage:

```c
// Define a configuration structure
typedef struct {
    uint8_t gyro_lpf_hz;
    uint16_t gyro_kalman_q;
    // ...
} gyroConfig_t;

// Register with reset template
PG_REGISTER_WITH_RESET_TEMPLATE(gyroConfig_t, gyroConfig, PG_GYRO_CONFIG, 12);

// Define default values
PG_RESET_TEMPLATE(gyroConfig_t, gyroConfig,
.gyro_lpf_hz = 60,
.gyro_kalman_q = 200,
// ...
);

// Access in code
gyroConfig()->gyro_lpf_hz
```

**Key Functions:**
- `PG_REGISTER_WITH_RESET_TEMPLATE()`: Register with static defaults
- `PG_REGISTER_WITH_RESET_FN()`: Register with function-based initialization
- `PG_REGISTER_ARRAY()`: For arrays of configuration items
- Parameter group IDs are in `config/parameter_group_ids.h`

### Scheduler

INAV uses a priority-based cooperative task scheduler:

```c
typedef enum {
    TASK_PRIORITY_IDLE = 0,
    TASK_PRIORITY_LOW = 1,
    TASK_PRIORITY_MEDIUM = 3,
    TASK_PRIORITY_HIGH = 5,
    TASK_PRIORITY_REALTIME = 18,
} cfTaskPriority_e;
```

Tasks are defined in `fc/fc_tasks.c` with priority and desired execution period.

### Sensors and Calibration

Sensors use a common pattern:
1. **Detection**: Auto-detect hardware at boot (`gyroDetect()`, `baroDetect()`)
2. **Initialization**: Configure sensor parameters
3. **Calibration**: Zero-offset calibration (gyro, accelerometer)
4. **Data Processing**: Apply calibration, alignment, and filtering

### Flight Control Loop

The main control loop follows this pattern:
1. **Gyro Task** (highest priority): Read gyro, apply filters
2. **PID Task**: Calculate PID corrections
3. **RX Task**: Process radio input
4. **Other Tasks**: Sensors, telemetry, OSD, etc. (lower priority)

### MSP Protocol

MultiWii Serial Protocol is used for configuration and telemetry:
- Request/response model
- Message types defined in `msp/msp_protocol.h`
- Handlers in `fc/fc_msp.c`

## Common Patterns

### Hardware Abstraction

INAV abstracts hardware through resource allocation:

```c
// IO pins
IO_t pin = IOGetByTag(IO_TAG(PA5));
IOInit(pin, OWNER_SPI, RESOURCE_SPI_SCK, 1);

// Timers
const timerHardware_t *timer = timerGetByTag(IO_TAG(PA8), TIM_USE_ANY);

// DMA
dmaIdentifier_e dma = dmaGetIdentifier(DMA1_Stream0);
```

### Error Handling

INAV uses several approaches:
1. **Return codes**: Boolean success/failure or error enums
2. **Diagnostics**: `sensors/diagnostics.c` for sensor health
3. **Status indicators**: Beeper codes, LED patterns for user feedback
4. **Logging**: CLI-based logging system

### Filter Chains

Sensor data typically goes through multiple filtering stages:

```c
// Low-pass filters
gyroLpfApplyFn = lowpassFilterGetApplyFn(filterType);
gyroLpfApplyFn(&gyroLpfState[axis], sample);

// Notch filters (for dynamic filtering)
for (int i = 0; i < dynamicNotchCount; i++) {
    sample = biquadFilterApply(&notchFilter[i], sample);
}
```

### Board Alignment

All sensors go through board alignment transforms to correct for mounting orientation:

```c
// Apply board alignment rotation matrix
applySensorAlignment(gyroData, gyroData, gyroAlign);
```

### SITL (Software In The Loop)

INAV can be compiled for host system simulation:
```bash
cmake -DSITL=ON ..
make
```

## Development Workflow

### Branching Strategy

- **`maintenance-X.x`**: Current version development (e.g., `maintenance-9.x`)
- **`maintenance-Y.x`**: Next major version (e.g., `maintenance-10.x`)
- **`master`**: Tracks current version, receives merges from maintenance branches

### Pull Request Guidelines

1. **Target Branch**:
- Bug fixes and backward-compatible features → current maintenance branch
- Breaking changes → next major version maintenance branch
- **Never** target `master` directly

2. **Keep PRs Focused**: One feature/fix per PR

3. **Code Quality**:
- Follow existing code style
- Add unit tests where possible
- Update documentation in `/docs`
- Test on real hardware when possible

4. **Commit Messages**: Clear, descriptive messages

### Important Files to Check

Before making changes, review:
- `docs/development/Development.md` - Development principles
- `docs/development/Contributing.md` - Contribution guidelines
- Target-specific files in `/src/main/target/`

## Important Files and Directories

### Configuration Files

- `platform.h`: Platform-specific includes and defines
- `target.h`: Board-specific hardware configuration
- `config/parameter_group.h`: Parameter group system
- `config/parameter_group_ids.h`: PG ID definitions
- `fc/settings.yaml`: CLI settings definitions

### Core Flight Control

- `fc/fc_core.c`: Main flight control loop
- `fc/fc_init.c`: System initialization
- `fc/fc_tasks.c`: Task scheduler configuration
- `flight/pid.c`: PID controller implementation
- `flight/mixer.c`: Motor mixing

### Key Headers

- `build/build_config.h`: Build-time configuration macros
- `common/axis.h`: Axis definitions (X, Y, Z, ROLL, PITCH, YAW)
- `common/maths.h`: Math utilities and constants
- `common/filter.h`: Digital filter implementations
- `drivers/accgyro/accgyro.h`: Gyro/accelerometer interface

## AI Agent Guidelines

### When Adding Features

1. **Understand the Module**: Read related files in the same directory
2. **Check for Similar Code**: Search for similar features to maintain consistency
3. **Follow Parameter Group Pattern**: New settings should use PG system
4. **Add to Scheduler**: New periodic tasks go in `fc/fc_tasks.c`
5. **Update Documentation**: Add/update files in `/docs`
6. **Consider Target Support**: Use `#ifdef USE_FEATURE` for optional features
7. **Generate CLI setting docs**: Remember to inform user to run `python src/utils/update_cli_docs.py`
8. **Follow conding standard**: Follow MISRA C rules
9. **Increase Paremeterer Group Version**: When changing PG structure, increase version corresponding in `PG_REGISTER`, `PG_REGISTER_WITH_RESET_FN`, `PG_REGISTER_WITH_RESET_TEMPLATE`, `PG_REGISTER_ARRAY` or `PG_REGISTER_ARRAY_WITH_RESET_FN`

### When Fixing Bugs

1. **Review Recent Changes**: Check git history for related modifications
2. **Test Signal Path**: For sensor issues, trace from hardware through filters to consumer
3. **Consider All Platforms**: STM32F4, F7, H7, and AT32 may behave differently
4. **Check Memory Usage**: Embedded system has limited RAM/flash

### When Refactoring

1. **Maintain API Compatibility**: Unless targeting next major version
2. **Preserve Unit Tests**: Update tests to match refactored code
3. **Update Documentation**: Keep docs synchronized with code changes
4. **Consider Performance**: Profile on target hardware, not just host compilation
5. **Check All Callers**: Use grep/search to find all usage sites

### Common Pitfalls to Avoid

1. **Don't Ignore DMA RAM**: `DMA_RAM`/`SLOW_RAM` placement still matters on STM32H7 and AT32F43x; buffers used by DMA-capable peripherals must stay in DMA-capable SRAM
2. **Don't Break Parameter Groups**: Changing PG structure requires version bump
3. **Don't Assume Hardware**: Always check feature flags (`#ifdef USE_GPS`)
4. **Don't Break MSP**: Changes to MSP protocol affect configurator compatibility
5. **Don't Commit Wrong Branch**: Target maintenance branch, not master
6. **Don't Skip Documentation**: Code without docs increases support burden
7. **Don't Hardcode Values**: Use parameter groups for configurable values

### Searching the Codebase

**Find definitions:**
```bash
grep -r "typedef.*_t" src/main/  # Find all type definitions
grep -r "PG_REGISTER" src/main/  # Find parameter groups
grep -r "TASK_" src/main/        # Find scheduled tasks
```

**Find usage:**
```bash
grep -r "functionName" src/main/
grep -r "USE_GPS" src/main/target/  # Feature support by target
```

**Find similar code:**
- Look in the same directory first
- Check for similar sensor/peripheral implementations
- Review git history: `git log --all --oneline --grep="keyword"`

### Understanding Control Flow

1. **Startup**: `main.c` → `fc_init.c:init()` → `fc_tasks.c:tasksInit()`
2. **Main Loop**: `scheduler.c:scheduler()` executes tasks by priority
3. **Critical Path**: Gyro → PID → Mixer → Motors (highest priority)
4. **Configuration**: CLI/MSP → Parameter Groups → EEPROM

### Cross-Platform Considerations

Different MCU families have different characteristics:

- **STM32F4**: Most common, 84-168 MHz, FPU, no cache
- **STM32F7**: Faster, 216 MHz, FPU, I/D cache, requires cache management
- **STM32H7**: Fastest, 480 MHz, more RAM, complex memory architecture (DTCM, SRAM)
- **AT32F43x**: Chinese MCU, STM32F4-compatible, different peripherals

Always test on target or use `#if defined()` guards for MCU-specific code.

## Quick Reference

### File Naming Patterns

- `*_config.h`: Configuration structures (usually with PG)
- `*_impl.h`: Implementation headers (MCU-specific)
- `*_hal.h`: Hardware abstraction layer
- `accgyro_*.c`: Gyro/accelerometer drivers
- `bus_*.c`: Communication bus drivers (SPI, I2C)

### Common Abbreviations

- **FC**: Flight Controller
- **PG**: Parameter Group
- **MSP**: MultiWii Serial Protocol
- **CLI**: Command Line Interface
- **OSD**: On-Screen Display
- **RTH**: Return to Home
- **PID**: Proportional-Integral-Derivative (controller)
- **IMU**: Inertial Measurement Unit (gyro + accel)
- **AHRS**: Attitude and Heading Reference System
- **ESC**: Electronic Speed Controller
- **SITL**: Software In The Loop
- **HITL**: Hardware In The Loop

## Resources

- **Main Repository**: https://github.com/iNavFlight/inav
- **Configurator**: https://github.com/iNavFlight/inav-configurator
- **Discord**: https://discord.gg/peg2hhbYwN
- **Documentation**: https://github.com/iNavFlight/inav/wiki
- **Release Notes**: https://github.com/iNavFlight/inav/releases

## Version Information

This document is accurate for INAV 9.0.1. As the project evolves, some details may change. Always refer to the latest documentation and code for authoritative information.

---

**Remember**: INAV flies aircraft that people build and fly. Code quality, safety, and reliability are paramount. When in doubt, ask the community or maintainers for guidance.

