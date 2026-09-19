/*
 * This file is part of INAV.
 *
 * INAV is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * INAV is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with INAV.  If not, see <http://www.gnu.org/licenses/>.
 */

//
// Unit mapping between wire/legacy units and SI internals.
//
// Wire definitions (MSP, settings.yaml, PG layout, blackbox, CLI, GPS wire
// format) are frozen project contracts and are never redefined here.  This
// module is the SINGLE place that owns the non-SI <-> SI arithmetic, so that
// subsystems can hold SI floats and boundaries can convert with one call.
//
// Rounding contract (important for byte-identical wire output):
// - "From" conversions (legacy -> SI) use the exact legacy expression they
// replace (same operations, same constants, same precision).  When wiring a
// call site, confirm the site previously used that identical expression.
// - "To" conversions (SI -> legacy) use nearest rounding (lroundf).
// - Round-trip identity to(from(x)) == x holds exactly below the float32
// exactness bound; above it the round trip is bounded by +/-1 count:
//   absolute ints are exact only for |x| < 2^24, and the double rounding of
//   any single-precision conversion (division or multiply-by-inverse) drifts
//   +/-1 count beyond |x| ~ 2^23 for 1e-2/1e-1 scaled quantities.  Every
//   real wire range (int16 centiunits, m up to ~+/-84 km, 1e-7 deg e7 up to
//   +/-180 deg) is covered: e7 beyond |1.8e9| loses up to ~0.8 m of
//   representational resolution because int32 itself exceeds float32 mantissa
//   granularity there -- that is inherent, the GPS datagram keeps int32 and is
//   never routed through this module.
// - The GPS wire format stays untouched; the e7 radians helpers exist only
// for internal use and MUST NOT be used to rewrite the GPS datagram.
//

#pragma once

#include <stdint.h>
#include <math.h>

// --- Angle: wire radians / decidegrees / centidegrees <-> radians (SI) ---

float unitAngleFromDegrees(int32_t degrees);
float unitAngleFromDecidegrees(int32_t decidegrees);
float unitAngleFromCentidegrees(int32_t centidegrees);

float unitAngleToDegrees(float radians);
float unitAngleToDecidegrees(float radians);
float unitAngleToCentidegrees(float radians);

// --- Length: wire metres / metres <-> metres (SI) ---

float unitLengthFromCentimetres(int32_t centimetres);
float unitLengthFromDecimetres(int32_t decimetres);

float unitLengthToCentimetres(float metres);
float unitLengthToDecimetres(float metres);

// --- Velocity: wire m/s <-> m/s (SI) ---

float unitVelocityFromCmPerSecond(int32_t centimetresPerSecond);
float unitVelocityToCmPerSecond(float metresPerSecond);

// --- Time: wire microseconds <-> seconds (SI) ---

float unitTimeFromMicros(int32_t micros);
int32_t unitTimeToMicros(float seconds);

// --- Voltage: wire volts <-> volts (SI) ---

float unitVoltageFromCentivolts(int32_t centivolts);
int32_t unitVoltageToCentivolts(float volts);

// --- Current: wire amperes <-> amperes (SI) ---

float unitCurrentFromCentiamps(int32_t centiamps);
int16_t unitCurrentToCentiamps(float amperes);

// --- Power: wire centiwatts <-> watts (SI) ---

float unitPowerFromCentiwatts(int32_t centiwatts);
int32_t unitPowerToCentiwatts(float watts);

// --- Temperature: wire decidegrees C <-> radians C (SI) ---

float unitTemperatureFromDecidegreesC(int32_t decidegreesC);
int16_t unitTemperatureToDecidegreesC(float degreesC);

// --- Geo position: 1e-7 radians wire ints <-> radians (SI, internal) ---

float unitLatLonFromDegreesE7(int32_t degreesE7);
int32_t unitLatLonToDegreesE7(float radians);
