#!/bin/bash
# iNavgke standalone firmware build (Makefile `fw` driver).
# Compiles the whole firmware for one board from the cmake source sets, links
# with the board's linker script and LTO, and emits inav_<ver>_<BOARD>.hex.
# Mirrors the CMake build: source sets, feature gates, -Os/-O2 by flash size,
# and release LTO (INTERPROCEDURAL_OPTIMIZATION ON upstream).
#
# Usage: tools/fwbuild.sh <BOARD>          (run from the repo root)
# Artifacts in build/standalone/<BOARD>/: inav_9.1.0_<BOARD>.elf/.hex/.bin/.map
set -e
BOARD="$1"
[ -n "$BOARD" ] || { echo "usage: tools/fwbuild.sh <BOARD>"; exit 1; }
cd "$(dirname "$0")/.."
ROOT="$PWD"
TCBIN="$ROOT/tools/arm-gnu-toolchain-13.2.rel1/bin"
GEN="$ROOT/build/standalone/$BOARD"
D="$GEN/obj/fw"
rm -rf "$D"
mkdir -p "$D"

# settings_generated.{c,h} must exist (settings.c #includes them)
if [ ! -f "$GEN/settings/settings_generated.h" ]; then
  echo "missing settings_generated.h - run 'make BOARD=$BOARD settings' first"
  exit 1
fi

MCU_MACRO=$(grep -m1 -oE 'target_(stm32|at32)[A-Za-z0-9_]+' "$ROOT/src/main/target/$BOARD/CMakeLists.txt")

case "$MCU_MACRO" in
  target_stm32f405xg) FAMILY=F4; DEVFLAGS="-DSTM32F4 -DUSE_STDPERIPH_DRIVER -DSTM32F40_41xxx -DSTM32F405xx"; FLASH=1024; STARTUP=startup_stm32f40xx.s; LD=stm32_flash_f405xg; HSE=8000000 ;;
  target_stm32f411xe) FAMILY=F4; DEVFLAGS="-DSTM32F4 -DUSE_STDPERIPH_DRIVER -DSTM32F411xE"; FLASH=512;  STARTUP=startup_stm32f411xe.s; LD=stm32_flash_f411xe; HSE=8000000 ;;
  target_stm32f427xg) FAMILY=F4; DEVFLAGS="-DSTM32F4 -DUSE_STDPERIPH_DRIVER -DSTM32F427_437xx"; FLASH=1024; STARTUP=startup_stm32f427xx.s; LD=stm32_flash_f427xg; HSE=8000000 ;;
  target_stm32f722xe) FAMILY=F7; DEVFLAGS="-DSTM32F7 -DUSE_HAL_DRIVER -DUSE_FULL_LL_DRIVER -DSTM32F722xx -DSTM32F722XE"; FLASH=512; STARTUP=startup_stm32f722xx.s; LD=stm32_flash_f722xe; HSE=8000000 ;;
  target_stm32f745xg) FAMILY=F7; DEVFLAGS="-DSTM32F7 -DUSE_HAL_DRIVER -DUSE_FULL_LL_DRIVER -DSTM32F745xx -DSTM32F745XG"; FLASH=1024; STARTUP=startup_stm32f745xx.s; LD=stm32_flash_f745xg; HSE=8000000 ;;
  target_stm32f765xg) FAMILY=F7; DEVFLAGS="-DSTM32F7 -DUSE_HAL_DRIVER -DUSE_FULL_LL_DRIVER -DSTM32F765xx -DSTM32F765XG"; FLASH=1024; STARTUP=startup_stm32f765xx.s; LD=stm32_flash_f765xg; HSE=8000000 ;;
  target_stm32f765xi) FAMILY=F7; DEVFLAGS="-DSTM32F7 -DUSE_HAL_DRIVER -DUSE_FULL_LL_DRIVER -DSTM32F765xx -DSTM32F765XI"; FLASH=2048; STARTUP=startup_stm32f765xx.s; LD=stm32_flash_f765xi; HSE=8000000 ;;
  target_stm32h743xi) FAMILY=H7; DEVFLAGS="-DSTM32H7 -DUSE_HAL_DRIVER -DUSE_FULL_LL_DRIVER -DMAX_MPU_REGIONS=16 -DSTM32H743xx -DSTM32H743XI"; FLASH=2048; STARTUP=startup_stm32h743xx.s; LD=stm32_flash_h743xi; HSE=8000000 ;;
  target_stm32h7a3xi) FAMILY=H7; DEVFLAGS="-DSTM32H7 -DUSE_HAL_DRIVER -DUSE_FULL_LL_DRIVER -DMAX_MPU_REGIONS=16 -DSTM32H7A3xx -DSTM32H7A3XI"; FLASH=2048; STARTUP=startup_stm32h7a3xx.s; LD=stm32_flash_h7a3xi; HSE=8000000 ;;
  target_at32f43x_xGT7) FAMILY=AT32; DEVFLAGS="-DAT32F43x -DUSE_STDPERIPH_DRIVER -DAT32F435RGT7"; FLASH=1024; STARTUP=startup_at32f435_437.s; LD=at32_flash_f43xG; HSE=8000000 ;;
  target_at32f43x_xMT7) FAMILY=AT32; DEVFLAGS="-DAT32F43x -DUSE_STDPERIPH_DRIVER -DAT32F437VMT7"; FLASH=4032; STARTUP=startup_at32f435_437.s; LD=at32_flash_f43xM; HSE=8000000 ;;
  *) echo "unknown macro $MCU_MACRO"; exit 1 ;;
esac

case "$FAMILY" in
  F7|H7) CPU="-mthumb -mcpu=cortex-m7 -mfloat-abi=hard -mfpu=fpv5-sp-d16"; FAMDEFS="-D__FPU_PRESENT=1 -DARM_MATH_CM7 -DARM_MATH_MATRIX_CHECK -DARM_MATH_ROUNDING" ;;
  AT32)  CPU="-mthumb -mcpu=cortex-m4 -mfloat-abi=hard -mfpu=fpv4-sp-d16"; FAMDEFS="-D__FPU_PRESENT=1 -DARM_MATH_CM4 -DARM_MATH_MATRIX_CHECK -DARM_MATH_ROUNDING" ;;
  *)     CPU="-mthumb -mcpu=cortex-m4 -march=armv7e-m -mfloat-abi=hard -mfpu=fpv4-sp-d16"; FAMDEFS="-D__FPU_PRESENT=1 -DARM_MATH_CM4 -DARM_MATH_MATRIX_CHECK -DARM_MATH_ROUNDING" ;;
esac

HSE_MHZ=$(grep -oE 'HSE_MHZ [0-9]+' "$ROOT/src/main/target/$BOARD/CMakeLists.txt" | grep -oE '[0-9]+$' | head -1)
[ -n "$HSE_MHZ" ] && HSE=$((HSE_MHZ*1000000))

# -Os for <=512K flash (F411, F722), -O2 otherwise; LTO matches release build.
if [ "$FLASH" -le 512 ]; then OPT="-Os"; else OPT="-O2"; fi

REV=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo standalone)
COMMON_FLAGS="-ggdb3 -DNDEBUG -std=gnu99 -ffunction-sections -fdata-sections -fno-common -fsingle-precision-constant -Wdouble-promotion -flto $OPT -Wall -Wextra -Wstrict-prototypes -Werror=switch $CPU"
DEFS="-D$BOARD -D__FORKNAME__=inav -D__TARGET__=\"$BOARD\" -D__REVISION__=\"$REV\" -DFC_VERSION_MAJOR=9 -DFC_VERSION_MINOR=1 -DFC_VERSION_PATCH_LEVEL=0 -DHSE_VALUE=$HSE -DMCU_FLASH_SIZE=$FLASH -DUNALIGNED_SUPPORT_DISABLE $FAMDEFS $DEVFLAGS"

case "$FAMILY" in
  F7)
    INCS="-I$GEN/settings -I$ROOT/src/main/target/$BOARD -I$ROOT/src/main/target -I$ROOT/lib -I$ROOT/src/main -I$ROOT/lib/main/MAVLink \
      -I$ROOT/lib/main/STM32F7/Drivers/CMSIS/Include -I$ROOT/lib/main/STM32F7/Drivers/CMSIS/Device/ST/STM32F7xx/Include \
      -I$ROOT/lib/main/STM32F7/Drivers/STM32F7xx_HAL_Driver/Inc -I$ROOT/src/main/vcp_hal \
      -I$ROOT/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Core/Inc \
      -I$ROOT/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/CDC/Inc \
      -I$ROOT/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/HID/Inc \
      -I$ROOT/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/CDC_HID/Inc \
      -I$ROOT/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Inc \
      -I$ROOT/lib/main/CMSIS/Core/Include -I$ROOT/lib/main/CMSIS/DSP/Include" ;;
  H7)
    INCS="-I$GEN/settings -I$ROOT/src/main/target/$BOARD -I$ROOT/src/main/target -I$ROOT/lib -I$ROOT/src/main -I$ROOT/lib/main/MAVLink \
      -I$ROOT/lib/main/STM32H7/Drivers/STM32H7xx_HAL_Driver/Inc -I$ROOT/lib/main/STM32H7/Drivers/CMSIS/Device/ST/STM32H7xx/Include \
      -I$ROOT/lib/main/STM32H7/Drivers/CMSIS/Include \
      -I$ROOT/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Core/Inc \
      -I$ROOT/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/CDC/Inc \
      -I$ROOT/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/HID/Inc \
      -I$ROOT/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Inc \
      -I$ROOT/src/main/vcp_hal -I$ROOT/lib/main/CMSIS/Core/Include -I$ROOT/lib/main/CMSIS/DSP/Include" ;;
  AT32)
    INCS="-I$GEN/settings -I$ROOT/src/main/target/$BOARD -I$ROOT/src/main/target -I$ROOT/lib -I$ROOT/src/main -I$ROOT/lib/main/MAVLink \
      -I$ROOT/lib/main/AT32F43x/Drivers/AT32F43x_StdPeriph_Driver/inc -I$ROOT/lib/main/AT32F43x/Drivers/CMSIS \
      -I$ROOT/lib/main/AT32F43x/Drivers/CMSIS/Device/ST/AT32F43x \
      -I$ROOT/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Core/Inc \
      -I$ROOT/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Class/usbd_class/cdc \
      -I$ROOT/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Class/usbd_class/msc \
      -I$ROOT/lib/lib/main/AT32F43x/Drivers/CMSIS/cm4/core_support \
      -I$ROOT/lib/main/CMSIS/Core/Include -I$ROOT/lib/main/CMSIS/DSP/Include" ;;
  *)
    INCS="-I$GEN/settings -I$ROOT/src/main/target/$BOARD -I$ROOT/src/main/target -I$ROOT/lib -I$ROOT/src/main -I$ROOT/lib/main/MAVLink \
      -I$ROOT/lib/main/STM32F4/Drivers/STM32F4xx_StdPeriph_Driver/inc -I$ROOT/lib/main/STM32F4/Drivers/CMSIS/Device/ST/STM32F4xx \
      -I$ROOT/lib/main/STM32F4/Drivers/CMSIS -I$ROOT/src/main/vcpf4 -I$ROOT/lib/main/STM32_USB_OTG_Driver/inc \
      -I$ROOT/lib/main/STM32_USB_Device_Library/Core/inc -I$ROOT/lib/main/STM32_USB_Device_Library/Class/cdc/inc \
      -I$ROOT/lib/main/STM32_USB_Device_Library/Class/hid/inc -I$ROOT/lib/main/STM32_USB_Device_Library/Class/hid_cdc_wrapper/inc \
      -I$ROOT/lib/main/STM32_USB_Device_Library/Class/msc/inc -I$ROOT/lib/main/CMSIS/Core/Include -I$ROOT/lib/main/CMSIS/DSP/Include" ;;
esac

FEATURES=$($TCBIN/arm-none-eabi-gcc -E -dD -D$BOARD "$ROOT/src/main/target/$BOARD/target.h" 2>/dev/null | grep -oE '#define[[:space:]]+(USE_VCP|USE_FLASHFS|USE_SDCARD|USE_SDCARD_SDIO)' | awk '{print $2}' | sort -u | tr '\n' ' ')
echo "BOARD=$BOARD FAMILY=$FAMILY MACRO=$MCU_MACRO HSE=$HSE FLASH=$FLASH LD=$LD STARTUP=$STARTUP"
echo "FEATURES: $FEATURES"

CC() { $TCBIN/arm-none-eabi-gcc "$@"; }
compile() { CC $COMMON_FLAGS $DEFS $INCS -c "$1" -o "$2"; }
objname() { echo "$D/$(echo "$1" | sed 's#^\./##; s#/#__#g').o"; }

# Board c-sources (target dir *.c)
for f in "$ROOT"/src/main/target/$BOARD/*.c; do
  ( compile "$f" "$(objname "$f")" ) &
done

# Common (from src/main/CMakeLists.txt main_sources(COMMON_SRC ...))
python3 - "$ROOT" <<'PYEOF' > "$D/.common.lst"
import re, sys
root = sys.argv[1]
src = open(f"{root}/src/main/CMakeLists.txt").read()
m = re.search(r'main_sources\(COMMON_SRC\s*(.*?)^\)', src, re.M | re.S)
for line in m.group(1).splitlines():
    line = line.strip()
    if not line or line.startswith('#') or not line.endswith('.c'):
        continue
    print(line)
PYEOF
while read f; do
  ( compile "$ROOT/src/main/$f" "$(objname "$ROOT/src/main/$f")" ) &
done < "$D/.common.lst"
wait

# Family sources
case "$FAMILY" in
  F4)
    EXC="can cec crc cryp cryp_aes cryp_des cryp_tdes dbgmcu dsi flash_ramfunc fmpi2c fmc hash hash_md5 hash_sha1 lptim qspi sai spdifrx"
    for f in "$ROOT"/lib/main/STM32F4/Drivers/STM32F4xx_StdPeriph_Driver/src/*.c; do
      b=$(basename "$f" .c); skip=0; for e in $EXC; do [ "$b" = "stm32f4xx_$e" ] && skip=1; done
      [ $skip = 1 ] && continue
      ( compile "$f" "$(objname "$f")" ) &
    done
    wait
    for f in "$ROOT"/src/main/drivers/bus_spi.c "$ROOT"/src/main/drivers/serial_uart.c "$ROOT"/src/main/target/system_stm32f4xx.c \
      "$ROOT"/src/main/config/config_streamer_ram.c "$ROOT"/src/main/config/config_streamer_extflash.c "$ROOT"/src/main/drivers/adc_stm32f4xx.c "$ROOT"/src/main/drivers/bus_i2c_stm32f40x.c \
      "$ROOT"/src/main/drivers/serial_uart_stm32f4xx.c "$ROOT"/src/main/drivers/system_stm32f4xx.c \
      "$ROOT"/src/main/drivers/timer_impl_stdperiph.c "$ROOT"/src/main/drivers/timer_stm32f4xx.c "$ROOT"/src/main/drivers/uart_inverter.c \
      "$ROOT"/src/main/drivers/dma_stm32f4xx.c "$ROOT"/src/main/config/config_streamer_stm32f4.c "$ROOT"/src/main/drivers/sdcard/sdmmc_sdio_f4xx.c; do
      ( compile "$f" "$(objname "$f")" ) &
    done
    wait
    if echo "$FEATURES" | grep -q USE_VCP; then
      for f in "$ROOT"/src/main/vcpf4/stm32f4xx_it.c "$ROOT"/src/main/vcpf4/usb_bsp.c "$ROOT"/src/main/vcpf4/usbd_desc.c "$ROOT"/src/main/vcpf4/usbd_usr.c "$ROOT"/src/main/vcpf4/usbd_cdc_vcp.c \
        "$ROOT"/src/main/drivers/serial_usb_vcp.c "$ROOT"/src/main/drivers/usb_io.c \
        "$ROOT"/lib/main/STM32_USB_OTG_Driver/src/usb_core.c "$ROOT"/lib/main/STM32_USB_OTG_Driver/src/usb_dcd.c "$ROOT"/lib/main/STM32_USB_OTG_Driver/src/usb_dcd_int.c \
        "$ROOT"/lib/main/STM32_USB_Device_Library/Core/src/usbd_core.c "$ROOT"/lib/main/STM32_USB_Device_Library/Core/src/usbd_ioreq.c "$ROOT"/lib/main/STM32_USB_Device_Library/Core/src/usbd_req.c \
        "$ROOT"/lib/main/STM32_USB_Device_Library/Class/cdc/src/usbd_cdc_core.c \
        "$ROOT"/lib/main/STM32_USB_Device_Library/Class/hid/src/usbd_hid_core.c \
        "$ROOT"/lib/main/STM32_USB_Device_Library/Class/hid_cdc_wrapper/src/usbd_hid_cdc_wrapper.c; do
        ( compile "$f" "$(objname "$f")" ) &
      done
      wait
    fi
    ;;
  F7)
    python3 - <<'PYEOF' > "$D/.hal.lst"
import re
src = open("cmake/stm32f7.cmake").read()
m = re.search(r'set\(STM32F7_HAL_SRC(.*?)^\)', src, re.M | re.S)
for line in m.group(1).splitlines():
    line = line.strip().lstrip('#').strip()
    if line.endswith('.c'):
        if not line.startswith('#'):
            print(line)
PYEOF
    while read b; do
      ( compile "$ROOT/lib/main/STM32F7/Drivers/STM32F7xx_HAL_Driver/Src/$b" "$D/hal_$b.o" ) &
    done < "$D/.hal.lst"
    wait
    for f in "$ROOT"/src/main/target/system_stm32f7xx.c "$ROOT"/src/main/config/config_streamer_stm32f7.c "$ROOT"/src/main/config/config_streamer_ram.c \
      "$ROOT"/src/main/config/config_streamer_extflash.c "$ROOT"/src/main/drivers/adc_stm32f7xx.c "$ROOT"/src/main/drivers/bus_i2c_hal.c \
      "$ROOT"/src/main/drivers/dma_stm32f7xx.c "$ROOT"/src/main/drivers/bus_spi_hal_ll.c "$ROOT"/src/main/drivers/timer_impl_hal.c \
      "$ROOT"/src/main/drivers/timer_stm32f7xx.c "$ROOT"/src/main/drivers/system_stm32f7xx.c "$ROOT"/src/main/drivers/serial_uart_stm32f7xx.c \
      "$ROOT"/src/main/drivers/serial_uart_hal.c "$ROOT"/src/main/drivers/sdcard/sdmmc_sdio_hal.c; do
      ( compile "$f" "$(objname "$f")" ) &
    done
    wait
    if echo "$FEATURES" | grep -q USE_VCP; then
      for f in "$ROOT"/src/main/vcp_hal/usbd_desc.c "$ROOT"/src/main/vcp_hal/usbd_conf_stm32f7xx.c "$ROOT"/src/main/vcp_hal/usbd_cdc_interface.c \
        "$ROOT"/src/main/drivers/serial_usb_vcp.c "$ROOT"/src/main/drivers/usb_io.c \
        "$ROOT"/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_core.c \
        "$ROOT"/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_ctlreq.c \
        "$ROOT"/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_ioreq.c \
        "$ROOT"/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/CDC/Src/usbd_cdc.c \
        "$ROOT"/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/HID/Src/usbd_hid.c \
        "$ROOT"/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/CDC_HID/Src/usbd_cdc_hid.c \
        "$ROOT"/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Src/usbd_msc.c \
        "$ROOT"/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Src/usbd_msc_bot.c \
        "$ROOT"/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Src/usbd_msc_data.c \
        "$ROOT"/lib/main/STM32F7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Src/usbd_msc_scsi.c; do
        ( compile "$f" "$(objname "$f")" ) &
      done
      wait
    fi
    ;;
  H7)
    python3 - <<'PYEOF' > "$D/.hal.lst"
import re
src = open("cmake/stm32h7.cmake").read()
m = re.search(r'set\(STM32H7_HAL_SRC(.*?)^\)', src, re.M | re.S)
for line in m.group(1).splitlines():
    line = line.lstrip()
    if line.startswith('#') or not line.endswith('.c'):
        continue
    print(line)
PYEOF
    while read b; do
      ( compile "$ROOT/lib/main/STM32H7/Drivers/STM32H7xx_HAL_Driver/Src/$b" "$D/hal_$b.o" ) &
    done < "$D/.hal.lst"
    wait
    for f in "$ROOT"/src/main/target/system_stm32h7xx.c "$ROOT"/src/main/config/config_streamer_stm32h7.c "$ROOT"/src/main/config/config_streamer_ram.c \
      "$ROOT"/src/main/config/config_streamer_extflash.c "$ROOT"/src/main/drivers/adc_stm32h7xx.c "$ROOT"/src/main/drivers/bus_i2c_hal.c \
      "$ROOT"/src/main/drivers/dma_stm32h7xx.c "$ROOT"/src/main/drivers/bus_spi_hal_ll.c "$ROOT"/src/main/drivers/bus_quadspi.c \
      "$ROOT"/src/main/drivers/bus_quadspi_hal.c "$ROOT"/src/main/drivers/memprot_hal.c "$ROOT"/src/main/drivers/memprot_stm32h7xx.c \
      "$ROOT"/src/main/drivers/timer_impl_hal.c "$ROOT"/src/main/drivers/timer_stm32h7xx.c \
      "$ROOT"/src/main/drivers/system_stm32h7xx.c "$ROOT"/src/main/drivers/serial_uart_stm32h7xx.c "$ROOT"/src/main/drivers/serial_uart_hal.c \
      "$ROOT"/src/main/drivers/sdcard/sdmmc_sdio_hal.c; do
      ( compile "$f" "$(objname "$f")" ) &
    done
    wait
    if echo "$FEATURES" | grep -q USE_VCP; then
      for f in "$ROOT"/src/main/vcp_hal/usbd_desc.c "$ROOT"/src/main/vcp_hal/usbd_conf_stm32h7xx.c "$ROOT"/src/main/vcp_hal/usbd_cdc_interface.c \
        "$ROOT"/src/main/drivers/serial_usb_vcp.c "$ROOT"/src/main/drivers/usb_io.c \
        "$ROOT"/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_core.c \
        "$ROOT"/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_ctlreq.c \
        "$ROOT"/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_ioreq.c \
        "$ROOT"/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/CDC/Src/usbd_cdc.c \
        "$ROOT"/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/HID/Src/usbd_hid.c; do
        ( compile "$f" "$(objname "$f")" ) &
      done
      wait
    fi
    ;;
  AT32)
    EXC="at32f435_437_can.c at32f435_437_dvp.c at32f435_437_xmc.c"
    for f in "$ROOT"/lib/main/AT32F43x/Drivers/AT32F43x_StdPeriph_Driver/src/*.c; do
      b=$(basename "$f"); skip=0; for e in $EXC; do [ "$b" = "$e" ] && skip=1; done
      [ $skip = 1 ] && continue
      ( compile "$f" "$(objname "$f")" ) &
    done
    ( compile "$ROOT/lib/main/AT32F43x/Drivers/CMSIS/Device/ST/AT32F43x/at32f435_437_clock.c" "$(objname "$ROOT/lib/main/AT32F43x/Drivers/CMSIS/Device/ST/AT32F43x/at32f435_437_clock.c")" ) &
    wait
    for f in "$ROOT"/src/main/drivers/bus_spi_at32f43x.c "$ROOT"/src/main/drivers/serial_uart_hal_at32f43x.c "$ROOT"/src/main/target/system_at32f435_437.c \
      "$ROOT"/src/main/config/config_streamer_at32f43x.c "$ROOT"/src/main/config/config_streamer_ram.c "$ROOT"/src/main/config/config_streamer_extflash.c \
      "$ROOT"/src/main/drivers/adc_at32f43x.c "$ROOT"/src/main/drivers/i2c_application.c "$ROOT"/src/main/drivers/bus_i2c_at32f43x.c \
      "$ROOT"/src/main/drivers/serial_uart_at32f43x.c "$ROOT"/src/main/drivers/system_at32f43x.c \
      "$ROOT"/src/main/drivers/timer_impl_stdperiph_at32.c "$ROOT"/src/main/drivers/timer_at32f43x.c "$ROOT"/src/main/drivers/uart_inverter.c \
      "$ROOT"/src/main/drivers/dma_at32f43x.c; do
      ( compile "$f" "$(objname "$f")" ) &
    done
    wait
    if echo "$FEATURES" | grep -q USE_VCP; then
      for f in "$ROOT"/src/main/drivers/serial_usb_vcp_at32f43x.c "$ROOT"/src/main/drivers/usb_io.c \
        "$ROOT"/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Core/Src/usb_core.c \
        "$ROOT"/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Core/Src/usbd_core.c \
        "$ROOT"/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Core/Src/usbd_int.c \
        "$ROOT"/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Core/Src/usbd_sdr.c \
        "$ROOT"/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Class/usbd_class/cdc/cdc_class.c \
        "$ROOT"/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Class/usbd_class/cdc/cdc_desc.c; do
        ( compile "$f" "$(objname "$f")" ) &
      done
      wait
    fi
    ;;
esac

# SDCARD
if echo "$FEATURES" | grep -q USE_SDCARD; then
  for f in "$ROOT"/src/main/drivers/sdcard/sdcard.c "$ROOT"/src/main/drivers/sdcard/sdcard_spi.c "$ROOT"/src/main/drivers/sdcard/sdcard_sdio.c "$ROOT"/src/main/drivers/sdcard/sdcard_standard.c \
    "$ROOT"/src/main/io/asyncfatfs/asyncfatfs.c "$ROOT"/src/main/io/asyncfatfs/fat_standard.c; do
    ( compile "$f" "$(objname "$f")" ) &
  done
fi
# MSC
if echo "$FEATURES" | grep -qE 'USE_FLASHFS|USE_SDCARD'; then
  case "$FAMILY" in
    F4)
      for f in "$ROOT"/src/main/msc/usbd_storage.c "$ROOT"/src/main/drivers/usb_msc_f4xx.c "$ROOT"/src/main/msc/usbd_msc_desc.c \
        "$ROOT"/lib/main/STM32_USB_Device_Library/Class/msc/src/usbd_msc_bot.c "$ROOT"/lib/main/STM32_USB_Device_Library/Class/msc/src/usbd_msc_core.c \
        "$ROOT"/lib/main/STM32_USB_Device_Library/Class/msc/src/usbd_msc_data.c "$ROOT"/lib/main/STM32_USB_Device_Library/Class/msc/src/usbd_msc_scsi.c; do
        ( compile "$f" "$(objname "$f")" ) &
      done
      if echo "$FEATURES" | grep -q USE_FLASHFS; then
        for f in "$ROOT"/src/main/msc/usbd_storage_emfat.c "$ROOT"/src/main/msc/emfat.c "$ROOT"/src/main/msc/emfat_file.c; do
          ( compile "$f" "$(objname "$f")" ) &
        done
      fi
      if echo "$FEATURES" | grep -q USE_SDCARD; then
        compile "$ROOT/src/main/msc/usbd_storage_sd_spi.c" "$(objname "$ROOT/src/main/msc/usbd_storage_sd_spi.c")" &
      fi
      ;;
    F7)
      for f in "$ROOT"/src/main/msc/usbd_storage.c "$ROOT"/src/main/drivers/usb_msc_f7xx.c; do
        ( compile "$f" "$(objname "$f")" ) &
      done
      if echo "$FEATURES" | grep -q USE_FLASHFS; then
        for f in "$ROOT"/src/main/msc/usbd_storage_emfat.c "$ROOT"/src/main/msc/emfat.c "$ROOT"/src/main/msc/emfat_file.c; do
          ( compile "$f" "$(objname "$f")" ) &
        done
      fi
      if echo "$FEATURES" | grep -q USE_SDCARD; then
        compile "$ROOT/src/main/msc/usbd_storage_sd_spi.c" "$(objname "$ROOT/src/main/msc/usbd_storage_sd_spi.c")" &
      fi
      ;;
    H7)
      for f in "$ROOT"/src/main/msc/usbd_storage.c "$ROOT"/src/main/drivers/usb_msc_h7xx.c \
        "$ROOT"/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Src/usbd_msc.c \
        "$ROOT"/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Src/usbd_msc_bot.c \
        "$ROOT"/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Src/usbd_msc_data.c \
        "$ROOT"/lib/main/STM32H7/Middlewares/ST/STM32_USB_Device_Library/Class/MSC/Src/usbd_msc_scsi.c; do
        ( compile "$f" "$(objname "$f")" ) &
      done
      if echo "$FEATURES" | grep -q USE_FLASHFS; then
        for f in "$ROOT"/src/main/msc/usbd_storage_emfat.c "$ROOT"/src/main/msc/emfat.c "$ROOT"/src/main/msc/emfat_file.c; do
          ( compile "$f" "$(objname "$f")" ) &
        done
      fi
      if echo "$FEATURES" | grep -q USE_SDCARD; then
        compile "$ROOT/src/main/msc/usbd_storage_sd_spi.c" "$(objname "$ROOT/src/main/msc/usbd_storage_sd_spi.c")" &
      fi
      ;;
    AT32)
      for f in "$ROOT"/src/main/msc/at32_msc_diskio.c "$ROOT"/src/main/msc/emfat.c "$ROOT"/src/main/msc/emfat_file.c "$ROOT"/src/main/drivers/usb_msc_at32f43x.c \
        "$ROOT"/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Class/usbd_class/msc/msc_desc.c \
        "$ROOT"/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Class/usbd_class/msc/msc_class.c \
        "$ROOT"/lib/main/AT32F43x/Middlewares/AT/AT32_USB_Device_Library/Class/usbd_class/msc/msc_bot_scsi.c; do
        ( compile "$f" "$(objname "$f")" ) &
      done
      ;;
  esac
fi
wait

# CMSIS DSP
for f in BasicMathFunctions/arm_scale_f32.c BasicMathFunctions/arm_sub_f32.c BasicMathFunctions/arm_mult_f32.c BasicMathFunctions/arm_offset_f32.c \
  TransformFunctions/arm_rfft_fast_f32.c TransformFunctions/arm_cfft_f32.c TransformFunctions/arm_rfft_fast_init_f32.c \
  TransformFunctions/arm_cfft_radix8_f32.c TransformFunctions/arm_bitreversal2.S CommonTables/arm_common_tables.c \
  ComplexMathFunctions/arm_cmplx_mag_f32.c StatisticsFunctions/arm_max_f32.c StatisticsFunctions/arm_rms_f32.c \
  StatisticsFunctions/arm_std_f32.c StatisticsFunctions/arm_mean_f32.c; do
  ( compile "$ROOT/lib/main/CMSIS/DSP/Source/$f" "$(objname "$ROOT/lib/main/CMSIS/DSP/Source/$f")" ) &
done
wait

# Startup
compile "$ROOT/src/main/startup/$STARTUP" "$D/startup.o"

N=$(ls "$D" | wc -l)
echo "== $N objects compiled for $BOARD =="

# Link
if [ "$FAMILY" = "AT32" ]; then LINKFLAGS=""; else LINKFLAGS="-nostartfiles"; fi
OBJS=$(ls "$D"/*.o | tr '\n' ' ')
set +e
$TCBIN/arm-none-eabi-gcc $CPU -flto $LINKFLAGS --specs=nano.specs -static -Wl,-gc-sections \
  -Wl,-L$ROOT/src/main/target/link -Wl,--cref -Wl,--no-wchar-size-warning -Wl,--print-memory-usage -Wl,--no-warn-rwx-segments \
  -Wl,-Map,$GEN/inav_9.1.0_$BOARD.map \
  -T$ROOT/src/main/target/link/$LD.ld \
  $OBJS -lm -lc -lnosys -o $GEN/inav_9.1.0_$BOARD.elf 2>&1 | grep -E "undefined reference|error:|FLASH1:|RAM:|collect2" | sort -u
RC=${PIPESTATUS[0]}
set -e
if [ $RC -eq 0 ] && [ -f "$GEN/inav_9.1.0_$BOARD.elf" ]; then
  $TCBIN/arm-none-eabi-objcopy -Oihex --set-start 0x08000000 $GEN/inav_9.1.0_$BOARD.elf $GEN/inav_9.1.0_$BOARD.hex
  $TCBIN/arm-none-eabi-objcopy -Obinary $GEN/inav_9.1.0_$BOARD.elf $GEN/inav_9.1.0_$BOARD.bin
  echo "== $BOARD LINK OK -> inav_9.1.0_$BOARD.hex =="
else
  echo "== $BOARD LINK FAILED =="
  exit 1
fi