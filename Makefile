# iNavgke standalone offline build harness.
#
# Standalone builds for the GKE unit-mapping work: compiles the mapping
# nucleus and every TIME-seat consumer as individual TUs, OFF (original
# bytes) and ON (-DGKE_UNIT_SEAT_TIME), without CMake, Ruby, or the network.
# Mirrors the shape of the sibling UAVXArmQ Makefile (local arm-none-eabi
# toolchain, per-board recipe, offline).
#
# Locked target is BLUEBERRYF405 (AGENT.md). The F4 recipe below is the
# exact include/define set the CMake build used for it. F7/H7/AT32 tables are
# best-effort so any board can be TU-verified; the real gate stays the
# locked F4 target.
#
# Usage (from the repo root):
#   make                 build nucleus + TU-verify every seat consumer (OFF & ON)
#   make nu              compile the mapping nucleus unit_map.o
#   make settings        (re)generate settings_generated.{c,h} via the Python port
#   make tu              TU-verify every seat consumer, OFF and ON
#   make tu BOARD=X      choose another target (default BLUEBERRYF405)
#   make td              disassembly differential seat-OFF vs seat-ON (informational)
#   make flagscheck      echo the active CC / FAMILY / DEFS / INCS
#   make clean           remove build/standalone artifacts
#   make help

SHELL := /bin/bash

#-------------------------------------------------------------
# Board (locked default) and repo layout
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
# MCU family detection from the board target.h
#-------------------------------------------------------------
ifneq ($(shell grep -c 'STM32H7' $(TARGET_DIR)/target.h 2>/dev/null),0)
  FAMILY := H7
else ifneq ($(shell grep -c 'STM32F7' $(TARGET_DIR)/target.h 2>/dev/null),0)
  FAMILY := F7
else ifneq ($(shell grep -c 'AT32' $(TARGET_DIR)/target.h 2>/dev/null),0)
  FAMILY := AT32
else
  FAMILY := F4
endif

# Per-family board defines pulled from target.h where small, explicit elsewhere.
T_DEVICE := $(shell grep -oE 'STM32F4[0-9]+xx|STM32F7[0-9]+xx|STM32H7[0-9]+xx|AT32F43[0-9]' $(TARGET_DIR)/target.h 2>/dev/null | sort -u | head -1)
T_HSE    := $(shell grep -oE 'HSE_VALUE[[:space:]]+[0-9]+' $(TARGET_DIR)/target.h 2>/dev/null | grep -oE '[0-9]+$$' | head -1)
DEVICE   ?= $(if $(T_DEVICE),$(T_DEVICE),STM32F405xx)
HSE_VALUE ?= $(if $(T_HSE),$(T_HSE),8000000)
MCU_FLASH_SIZE ?= 1024

#-------------------------------------------------------------
# Compiler flags
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
  FAMILY_DEFS := -D__FPU_PRESENT=1 -DSTM32F4 -DSTM32F40_41xxx -DARM_MATH_CM4 -DARM_MATH_MATRIX_CHECK -DARM_MATH_ROUNDING
  FAMILY_CPU  := -mthumb -mcpu=cortex-m4 -march=armv7e-m -mfloat-abi=hard -mfpu=fpv4-sp-d16
endif

COMMON_FLAGS := -ggdb3 -DNDEBUG -std=gnu99 -ffunction-sections -fdata-sections \
	-fno-common -fsingle-precision-constant -Wdouble-promotion -O2 -Wall -Wextra \
	-Wstrict-prototypes -Werror=switch $(FAMILY_CPU)

DEFS := -D$(BOARD) -D__FORKNAME__=inav -D__TARGET__="$(BOARD)" -D__REVISION__="$(REV)" \
	-DFC_VERSION_MAJOR=9 -DFC_VERSION_MINOR=1 -DFC_VERSION_PATCH_LEVEL=0 \
	-DHSE_VALUE=$(HSE_VALUE) -DMCU_FLASH_SIZE=$(MCU_FLASH_SIZE) -D$(DEVICE) \
	-DUNALIGNED_SUPPORT_DISABLE -DUSE_USB_MSC $(FAMILY_DEFS) $(T_EXTRA_DEFS)
# Feature gates (USE_ADC, USE_GPS, USE_POWER_LIMITS, ...) come from the
# headers (target.h / common.h) exactly as in the CMake build; do not -D them.

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
.PHONY: all nu settings tu td flagscheck clean help

all: nu tu
	@echo "== iNavgke standalone OK: nucleus + $(words $(TU_SRC)) seat consumer TU(s), OFF & ON =="

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
	@echo "FAMILY   : $(FAMILY)  DEVICE=$(DEVICE)  HSE_VALUE=$(HSE_VALUE)"
	@echo "DEFS     : $(DEFS)"
	@echo "INCS     : $(INCS)"
	@echo "SEAT_TUs : $(TU_SRC)"

clean:
	@rm -rf $(GEN_DIR)
	@echo "== removed $(GEN_DIR) =="

help:
	@echo "iNavgke standalone build harness (GKE unit-mapping seats)"
	@echo "  make            nucleus + seat TU verification (OFF & ON)"
	@echo "  make nu         compile mapping nucleus"
	@echo "  make settings   regenerate settings_generated via Python port"
	@echo "  make tu         TU-verify all seat consumers"
	@echo "  make td         seat-OFF vs seat-ON disassembly differential"
	@echo "  make flagscheck echo active CC/FAMILY/DEFS/INCS"
	@echo "  make BOARD=X    choose a board (default BLUEBERRYF405)"
	@echo "  make clean      remove build/standalone/$(BOARD)"

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