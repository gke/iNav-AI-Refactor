# iNavgke standalone offline build harness.
#
# Standalone builds for the GKE unit-mapping work: compiles the mapping
# nucleus and every TIME-seat consumer as individual TUs, OFF (original
# bytes) and ON (-DGKE_UNIT_SEAT_TIME), without CMake, Ruby, or the network.
# Mirrors the shape of the sibling UAVXArmQ Makefile (local arm-none-eabi
# toolchain, per-board recipe, offline).
#
# Default `make` (and `make boards`) sweeps EVERY target that has both a
# target.h and a CMakeLists.txt (the same set the CMake build picks up via
# `add_subdirectory(target)`), EXCEPT SITL (host/native build, cannot be
# TU-verified with an ARM toolchain) and dormant dirs such as RADIX that
# upstream itself does not build.  `make BOARD=X` verifies a single board.
#
# The MCU family/device/flash-size table below mirrors the define sets the
# CMake side derives from each board's CMakeLists.txt macro
# (target_stm32f405xg / target_stm32f722xe / ...).  Do not re-derive family
# from target.h - the MCU lives in the CMakeLists macro, not the header.
#
# Usage (from the repo root):
#   make                 build all targets: nucleus + TU-verify seats OFF&ON
#   make boards          same as `make`
#   make nu              compile the mapping nucleus unit_map.o (default board)
#   make settings        (re)generate settings_generated.{c,h} via the Python port
#   make tu              TU-verify every seat consumer, OFF and ON (default board)
#   make fw / hex        build the full board firmware inav_9.1.0_<BOARD>.hex
#                        (mirrors the CMake release build via src/utils/fwbuild.sh)
#   make BOARD=X         verify a single board (all of the above with BOARD=X)
#   make td              disassembly differential seat-OFF vs seat-ON (informational)
#   make flagscheck      echo the active CC / FAMILY / DEFS / INCS
#   make clean           remove build/standalone artifacts
#   make help

SHELL := /bin/bash

#-------------------------------------------------------------
# Board (default) and repo layout
#-------------------------------------------------------------
BOARD     ?= BLUEBERRYF405
SRC_DIR   := src/main
TARGET_DIR := $(SRC_DIR)/target/$(BOARD)
GEN_DIR   := build/standalone/$(BOARD)
OBJ_DIR   := $(GEN_DIR)/obj
SETTINGS_BIN := $(GEN_DIR)/settings
SETTINGS_STAMP := $(SETTINGS_BIN).stamp
SETTINGS_H := $(SETTINGS_BIN)/settings_generated.h
SETTINGS_C := $(SETTINGS_BIN)/settings_generated.c
TOOLS_PY  := src/utils/settings.py
BUILD_LOG := $(GEN_DIR)/build.log
FWBUILD   := src/utils/fwbuild.sh
FW_ELF    := $(GEN_DIR)/inav_9.1.0_$(BOARD).elf
FW_HEX    := $(GEN_DIR)/inav_9.1.0_$(BOARD).hex

ALL_BOARDS := $(sort $(foreach d,$(wildcard $(SRC_DIR)/target/*/),\
  $(if $(wildcard $(d)target.h),$(if $(wildcard $(d)CMakeLists.txt),$(patsubst $(SRC_DIR)/target/%/,%,$(d)),),)))
# SITL is a host/native build (uses sys/socket.h and a host toolchain); it is
# not TU-verifiable with arm-none-eabi here.
ALL_BOARDS := $(filter-out SITL,$(ALL_BOARDS))

ifeq ($(wildcard $(TARGET_DIR)/target.h),)
$(error Board '$(BOARD)' not found: no $(TARGET_DIR)/target.h)
endif

REV := $(shell git rev-parse --short HEAD 2>/dev/null || echo standalone)

#-------------------------------------------------------------
# Toolchain auto-detect (offline; no GCC pinning)
#-------------------------------------------------------------
TCBIN_ONTREE := tools/arm-gnu-toolchain-13.2.rel1/bin
TCBIN_XPACK  := $(HOME)/toolchain/xpack-arm-none-eabi-gcc-15.2.1-1.1/bin
TCBIN_PATH   := $(shell command -v arm-none-eabi-gcc 2>/dev/null | xargs dirname 2>/dev/null)

ifneq ($(wildcard $(TCBIN_ONTREE)/arm-none-eabi-gcc),)
  TCBIN := $(TCBIN_ONTREE)
else ifneq ($(wildcard $(TCBIN_XPACK)/arm-none-eabi-gcc),)
  TCBIN := $(TCBIN_XPACK)
else ifneq ($(strip $(TCBIN_PATH)),)
  TCBIN := $(TCBIN_PATH)
else
  $(error No arm-none-eabi-gcc found. Install one in tools/arm-gnu-toolchain-13.2.rel1, ~/toolchain/xpack-arm-none-eabi-gcc-15.2.1-1.1, or PATH)
endif

CC  := $(TCBIN)/arm-none-eabi-gcc
CXX := $(TCBIN)/arm-none-eabi-g++
OD  := $(TCBIN)/arm-none-eabi-objdump

#-------------------------------------------------------------
# MCU family / device / flash from the board's CMakeLists macro.
# Table rows:  macro:FAMILY:FLAGS-PIPE-JOINED:flash_KiB
# The -D flags are pipe-joined so each row is exactly 4 colon fields.
#-------------------------------------------------------------
MCU_MACRO := $(shell grep -m1 -oE 'target_(stm32|at32)[A-Za-z0-9_]+' $(TARGET_DIR)/CMakeLists.txt 2>/dev/null)

MCU_TABLE := \
  target_stm32f405xg:F4:-DSTM32F4|-DUSE_STDPERIPH_DRIVER|-DSTM32F40_41xxx|-DSTM32F405xx:1024 \
  target_stm32f411xe:F4:-DSTM32F4|-DUSE_STDPERIPH_DRIVER|-DSTM32F411xE:512 \
  target_stm32f427xg:F4:-DSTM32F4|-DUSE_STDPERIPH_DRIVER|-DSTM32F427_437xx:1024 \
  target_stm32f722xe:F7:-DSTM32F7|-DUSE_HAL_DRIVER|-DUSE_FULL_LL_DRIVER|-DSTM32F722xx|-DSTM32F722XE:512 \
  target_stm32f745xg:F7:-DSTM32F7|-DUSE_HAL_DRIVER|-DUSE_FULL_LL_DRIVER|-DSTM32F745xx|-DSTM32F745XG:1024 \
  target_stm32f765xg:F7:-DSTM32F7|-DUSE_HAL_DRIVER|-DUSE_FULL_LL_DRIVER|-DSTM32F765xx|-DSTM32F765XG:1024 \
  target_stm32f765xi:F7:-DSTM32F7|-DUSE_HAL_DRIVER|-DUSE_FULL_LL_DRIVER|-DSTM32F765xx|-DSTM32F765XI:2048 \
  target_stm32h743xi:H7:-DSTM32H7|-DUSE_HAL_DRIVER|-DUSE_FULL_LL_DRIVER|-DSTM32H743xx|-DSTM32H743XI:2048 \
  target_stm32h7a3xi:H7:-DSTM32H7|-DUSE_HAL_DRIVER|-DUSE_FULL_LL_DRIVER|-DSTM32H7A3xx|-DSTM32H7A3XI:2048 \
  target_at32f43x_xGT7:AT32:-DAT32F43x|-DUSE_STDPERIPH_DRIVER|-DAT32F435RGT7:1024 \
  target_at32f43x_xMT7:AT32:-DAT32F43x|-DUSE_STDPERIPH_DRIVER|-DAT32F437VMT7:4032

MCU_ROW := $(foreach row,$(MCU_TABLE),$(if $(findstring $(MCU_MACRO):,$(row):),$(strip $(row))))
ifeq ($(strip $(MCU_ROW)),)
  MCU_ROW := target_unknown:F4:-DSTM32F4|-DUSE_STDPERIPH_DRIVER|-DSTM32F40_41xxx|-DSTM32F405xx:1024
endif

FAMILY       := $(word 2,$(subst :, ,$(MCU_ROW)))
DEVICE_FLAGS := $(subst |, ,$(word 3,$(subst :, ,$(MCU_ROW))))
MCU_FLASH_SIZE := $(word 4,$(subst :, ,$(MCU_ROW)))

T_HSE := $(shell grep -oE 'HSE_VALUE[[:space:]]+[0-9]+' $(TARGET_DIR)/target.h 2>/dev/null | grep -oE '[0-9]+$$' | head -1)
HSE_VALUE ?= $(if $(T_HSE),$(T_HSE),8000000)

# Feature gates for the firmware build (MSC = FLASHFS or SDCARD).  These mirror
# get_stm32_target_features in cmake/stm32.cmake; only these feed the build-time
# defines.  All other gates (USE_ADC, USE_GPS, ...) come from the headers.
T_TARGET_H := $(TARGET_DIR)/target.h
MSC_FEATURE := $(if $(or $(shell grep -c 'define[[:space:]]\+USE_FLASHFS' $(T_TARGET_H) 2>/dev/null),$(shell grep -c 'define[[:space:]]\+USE_SDCARD' $(T_TARGET_H) 2>/dev/null)),1,0)

#-------------------------------------------------------------
# Compiler flags.
# COMMON (family base) per-FAMILY cpu/flags below; device-specific defines in
# DEVICE_FLAGS (from the CMakeLists macro table above).  Do NOT re-add device
# defines here - the CMake build never does.
#-------------------------------------------------------------
ifeq ($(FAMILY),F7)
  FAMILY_DEFS := -D__FPU_PRESENT=1 -DSTM32F7 -DARM_MATH_CM7 -DARM_MATH_MATRIX_CHECK -DARM_MATH_ROUNDING
  FAMILY_CPU  := -mthumb -mcpu=cortex-m7 -mfloat-abi=hard -mfpu=fpv5-sp-d16
else ifeq ($(FAMILY),H7)
  FAMILY_DEFS := -D__FPU_PRESENT=1 -DSTM32H7 -DARM_MATH_CM7 -DARM_MATH_MATRIX_CHECK -DARM_MATH_ROUNDING
  FAMILY_CPU  := -mthumb -mcpu=cortex-m7 -mfloat-abi=hard -mfpu=fpv5-sp-d16
else ifeq ($(FAMILY),AT32)
  FAMILY_DEFS := -D__FPU_PRESENT=1 -DAT32F43x -DARM_MATH_CM4 -DARM_MATH_MATRIX_CHECK -DARM_MATH_ROUNDING
  FAMILY_CPU  := -mthumb -mcpu=cortex-m4 -mfloat-abi=hard -mfpu=fpv4-sp-d16
else
  FAMILY_DEFS := -D__FPU_PRESENT=1 -DSTM32F4 -DARM_MATH_CM4 -DARM_MATH_MATRIX_CHECK -DARM_MATH_ROUNDING
  FAMILY_CPU  := -mthumb -mcpu=cortex-m4 -march=armv7e-m -mfloat-abi=hard -mfpu=fpv4-sp-d16
endif

COMMON_FLAGS := -ggdb3 -DNDEBUG -std=gnu99 -ffunction-sections -fdata-sections \
	-fno-common -fsingle-precision-constant -Wdouble-promotion -O2 -Wall -Wextra \
	-Wstrict-prototypes -Werror=switch $(FAMILY_CPU)

DEFS := -D$(BOARD) -D__FORKNAME__=inav -D__TARGET__="$(BOARD)" -D__REVISION__="$(REV)" \
	-DFC_VERSION_MAJOR=9 -DFC_VERSION_MINOR=1 -DFC_VERSION_PATCH_LEVEL=0 \
	-DHSE_VALUE=$(HSE_VALUE) -DMCU_FLASH_SIZE=$(MCU_FLASH_SIZE) \
	-DUNALIGNED_SUPPORT_DISABLE $(if $(MSC_FEATURE),-DUSE_USB_MSC,) \
	$(FAMILY_DEFS) $(DEVICE_FLAGS) $(T_EXTRA_DEFS)
# Feature gates (USE_ADC, USE_GPS, USE_POWER_LIMITS, ...) come from the
# headers (target.h / common.h) exactly as in the CMake build; do not -D them.
# USE_USB_MSC is only defined when the board has FLASHFS or SDCARD (MSC), as
# target_at_stm32 / target_at32 do via the features list.

#-------------------------------------------------------------
# Include sets (relative to repo root). Prepend the generated-settings dir
# so a fresh standalone settings_generated.h wins over any stale build dir.
#-------------------------------------------------------------
INCS := -I$(SETTINGS_BIN)

ifeq ($(FAMILY),F7)
  INCS += -I$(TARGET_DIR) \
	-Ilib/main/STM32F7/Drivers/CMSIS/Include \
	-Ilib/main/STM32F7/Drivers/CMSIS/Device/ST/STM32F7xx/Include \
	-Ilib/main/STM32F7/Drivers/STM32F7xx_HAL_Driver/Inc \
	-Isrc/main/vcpf7 -Isrc/main/vcp_hal \
	-Ilib/main/CMSIS/Core/Include -Ilib/main/CMSIS/DSP/Include
else ifeq ($(FAMILY),H7)
  INCS += -I$(TARGET_DIR) \
	-Ilib/main/STM32H7/Drivers/STM32H7xx_HAL_Driver/Inc \
	-Ilib/main/STM32H7/Drivers/CMSIS/Device/ST/STM32H7xx/Include \
	-Ilib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Core/Inc \
	-Ilib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/CDC/Inc \
	-Ilib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/HID/Inc \
	-Ilib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Inc \
	-Isrc/main/vcp_hal \
	-Ilib/main/CMSIS/Core/Include -Ilib/main/CMSIS/DSP/Include
else ifeq ($(FAMILY),AT32)
  INCS += -I$(TARGET_DIR) \
	-Ilib/main/AT32F43x/Drivers/AT32F43x_StdPeriph_Driver/inc \
	-Ilib/main/AT32F43x/Drivers/CMSIS \
	-Ilib/main/AT32F43x/Drivers/CMSIS/Device/ST/AT32F43x \
	-Ilib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Core/Inc \
	-Ilib/lib/main/AT32F43x/Drivers/CMSIS/cm4/core_support \
	-Ilib/main/CMSIS/Core/Include -Ilib/main/CMSIS/DSP/Include
else
  INCS += -I$(TARGET_DIR) \
	-Ilib/main/STM32F4/Drivers/STM32F4xx_StdPeriph_Driver/inc \
	-Ilib/main/STM32F4/Drivers/CMSIS/Device/ST/STM32F4xx \
	-Ilib/main/STM32F4/Drivers/CMSIS \
	-Isrc/main/vcpf4 \
	-Ilib/main/STM32_USB_OTG_Driver/inc \
	-Ilib/main/STM32_USB_Device_Library/Core/inc \
	-Ilib/main/STM32_USB_Device_Library/Class/cdc/inc \
	-Ilib/main/STM32_USB_Device_Library/Class/hid/inc \
	-Ilib/main/STM32_USB_Device_Library/Class/hid_cdc_wrapper/inc \
	-Ilib/main/STM32_USB_Device_Library/Class/msc/inc \
	-Ilib/main/CMSIS/Core/Include -Ilib/main/CMSIS/DSP/Include
endif
  INCS += -Isrc/main/target -Ilib -Isrc/main -Ilib/main/MAVLink

#-------------------------------------------------------------
# Seat consumer discovery: every TU that includes the mapping shim.
#-------------------------------------------------------------
TU_SRC := $(shell grep -rl 'mapping/unit_map.h' $(SRC_DIR) --include=*.c | grep -v '/mapping/unit_map.c')
TU_OFF := $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.off.o,$(TU_SRC))
TU_ON  := $(patsubst $(SRC_DIR)/%.c,$(OBJ_DIR)/%.on.o,$(TU_SRC))
NUCLEUS_O := $(OBJ_DIR)/mapping/unit_map.o

#-------------------------------------------------------------
# Targets
#-------------------------------------------------------------
.PHONY: all boards nu settings tu td flagscheck fw hex clean help

all: boards

boards:
	@ok=0; fail=0; failed=""; \
	for b in $(ALL_BOARDS); do \
	  printf '== BOARD %-20s ' "$$b"; \
	  if $(MAKE) BOARD=$$b nu tu >/tmp/opencode/board-$$b.log 2>&1; then \
	    ok=$$((ok+1)); echo "OK"; \
	  else \
	    fail=$$((fail+1)); failed="$$failed $$b"; echo "FAIL (see /tmp/opencode/board-$$b.log)"; \
	  fi; \
	done; \
	echo "== all-target sweep: $$ok OK, $$fail failed =="; \
	if [ $$fail -gt 0 ]; then echo "FAILED:$$failed"; exit 1; fi

nu: $(NUCLEUS_O)
	@echo "== nucleus: $(NUCLEUS_O) ($(shell wc -c < $(NUCLEUS_O) 2>/dev/null) bytes) =="

settings: $(SETTINGS_STAMP)
	@echo "== settings: $(SETTINGS_H) =="

tu: $(TU_OFF) $(TU_ON)
	@printf '== seats verified OFF & ON: '; printf '%s ' $(TU_SRC); echo

td: tu
	@fail=0; for o in $(TU_OFF); do n="$${o%.off.o}.on.o"; \
	  if cmp -s <($(OD) -d "$$o") <($(OD) -d "$$n"); then \
	    echo "IDENTICAL   : $$o"; \
	  else \
	    echo "DIFFERS     : $$o"; fail=1; \
	  fi; \
	done; \
	if [ $$fail -eq 0 ]; then echo "== seat-OFF and seat-ON disassembly identical for all TUs =="; \
	else echo "== seat-OFF/ON disassembly differs (expected: unitTimeFromMicroseconds call vs inline math). Inspect with make td > log"; fi

flagscheck:
	@echo "CC       : $(CC)"
	@echo "BOARD    : $(BOARD)  FAMILY=$(FAMILY)  MCU_FLASH_SIZE=$(MCU_FLASH_SIZE)  HSE_VALUE=$(HSE_VALUE)"
	@echo "MCU_ROW  : $(MCU_ROW)"
	@echo "DEFS     : $(DEFS)"
	@echo "INCS     : $(INCS)"
	@echo "SEAT_TUs : $(TU_SRC)"
	@echo "ALL_BOARDS ($(words $(ALL_BOARDS))): $(ALL_BOARDS)"

fw: hex

hex: settings
	@$(FWBUILD) $(BOARD)

clean:
	@rm -rf build/standalone
	@echo "== removed build/standalone =="

help:
	@echo "iNavgke standalone build harness (GKE unit-mapping seats)"
	@echo "  make            sweep ALL targets: nucleus + seat TU verification (OFF & ON)"
	@echo "  make boards     same as make"
	@echo "  make nu         compile mapping nucleus (default board)"
	@echo "  make settings   regenerate settings_generated via Python port"
	@echo "  make tu         TU-verify all seat consumers (default board)"
	@echo "  make td         seat-OFF vs seat-ON disassembly differential"
	@echo "  make fw / hex   build the real firmware inav_9.1.0_$(BOARD).hex (default board)"
	@echo "  make flagscheck echo active CC/FAMILY/DEFS/INCS + all-board list"
	@echo "  make BOARD=X    verify a single board (default BLUEBERRYF405)"
	@echo "  make clean      remove build/standalone"
	@echo "Sweep excludes SITL (host build) and any dir with no CMakeLists.txt."

#-------------------------------------------------------------
# Rules
#-------------------------------------------------------------
$(SETTINGS_STAMP): $(TOOLS_PY) $(SRC_DIR)/fc/settings.yaml
	@mkdir -p $(SETTINGS_BIN)
	@PATH="$(TCBIN):$$PATH" CFLAGS="$(DEFS) $(INCS)" \
	  python3 $(TOOLS_PY) $(SRC_DIR) $(SRC_DIR)/fc/settings.yaml -o $(SETTINGS_BIN)
	@touch $@

$(SETTINGS_H): $(SETTINGS_STAMP)
	@test -f $(SETTINGS_H)

$(SETTINGS_C): $(SETTINGS_STAMP)
	@test -f $(SETTINGS_C)

$(NUCLEUS_O): $(SRC_DIR)/mapping/unit_map.c $(SRC_DIR)/mapping/unit_map.h
	@mkdir -p $(dir $@)
	$(CC) $(COMMON_FLAGS) $(DEFS) -Isrc/main -c $< -o $@

$(OBJ_DIR)/%.off.o: $(SRC_DIR)/%.c $(SETTINGS_H)
	@mkdir -p $(dir $@)
	$(CC) $(COMMON_FLAGS) $(DEFS) $(INCS) -c $< -o $@

$(OBJ_DIR)/%.on.o: $(SRC_DIR)/%.c $(SETTINGS_H)
	@mkdir -p $(dir $@)
	$(CC) $(COMMON_FLAGS) $(DEFS) $(INCS) -DGKE_UNIT_SEAT_TIME -c $< -o $@