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

#include <stdlib.h>
#include <limits.h>

#include "mapping/unit_map.h"

#include "common/maths.h"

// Angle

float unitAngleFromDegrees(int32_t degrees) {
    return (float)degrees * (float)RAD;
} // unitAngleFromDegrees

float unitAngleFromDecidegrees(int32_t decidegrees) {
    return ((float)decidegrees / 10.0f) * (float)RAD;
} // unitAngleFromDecidegrees

float unitAngleFromCentidegrees(int32_t centidegrees) {
    return ((float)centidegrees * 0.01f) * (float)RAD;
} // unitAngleFromCentidegrees

float unitAngleToDegrees(float radians) {
    return radians / (float)RAD;
} // unitAngleToDegrees

float unitAngleToDecidegrees(float radians) {
    return (radians * 10.0f) / (float)RAD;
} // unitAngleToDecidegrees

float unitAngleToCentidegrees(float radians) {
    return (radians * 100.0f) / (float)RAD;
} // unitAngleToCentidegrees

// Length

float unitLengthFromCentimetres(int32_t centimetres) {
    return (float)centimetres * 0.01f;
} // unitLengthFromCentimetres

float unitLengthFromDecimetres(int32_t decimetres) {
    return (float)decimetres * 0.1f;
} // unitLengthFromDecimetres

float unitLengthToCentimetres(float metres) {
    return lroundf(metres * 100.0f);
} // unitLengthToCentimetres

float unitLengthToDecimetres(float metres) {
    return lroundf(metres * 10.0f);
} // unitLengthToDecimetres

// Velocity

float unitVelocityFromCmPerSecond(int32_t centimetresPerSecond) {
    return (float)centimetresPerSecond * 0.01f;
} // unitVelocityFromCmPerSecond

float unitVelocityToCmPerSecond(float metresPerSecond) {
    return lroundf(metresPerSecond * 100.0f);
} // unitVelocityToCmPerSecond

// Voltage

float unitVoltageFromCentivolts(int32_t centivolts) {
    return (float)centivolts * 0.01f;
} // unitVoltageFromCentivolts

int32_t unitVoltageToCentivolts(float volts) {
    return lroundf(volts * 100.0f);
} // unitVoltageToCentivolts

// Current

float unitCurrentFromCentiamps(int32_t centiamps) {
    return (float)centiamps / 100.0f;
} // unitCurrentFromCentiamps

int16_t unitCurrentToCentiamps(float amperes) {
    return (int16_t)constrain(lroundf(amperes * 100.0f), INT16_MIN, INT16_MAX);
} // unitCurrentToCentiamps

// Power

float unitPowerFromCentiwatts(int32_t centiwatts) {
    return (float)centiwatts * 0.01f;
} // unitPowerFromCentiwatts

int32_t unitPowerToCentiwatts(float watts) {
    return lroundf(watts * 100.0f);
} // unitPowerToCentiwatts

// Temperature

float unitTemperatureFromDecidegreesC(int32_t decidegreesC) {
    return (float)decidegreesC * 0.1f;
} // unitTemperatureFromDecidegreesC

int16_t unitTemperatureToDecidegreesC(float degreesC) {
    return (int16_t)constrain(lroundf(degreesC * 10.0f), INT16_MIN, INT16_MAX);
} // unitTemperatureToDecidegreesC

// Geo position (internal only; the GPS wire format is never touched)

float unitLatLonFromDegreesE7(int32_t degreesE7) {
    return ((float)degreesE7 * 0.0000001f) * (float)RAD;
} // unitLatLonFromDegreesE7

int32_t unitLatLonToDegreesE7(float radians) {
    return lroundf((radians / (float)RAD) * 10000000.0f);
} // unitLatLonToDegreesE7

// --- Time: wire microseconds <-> seconds (SI) ---

float unitTimeFromMicroseconds(int32_t microseconds) {
    return (float)microseconds * 1e-6f;
} // unitTimeFromMicroseconds

int32_t unitTimeToMicroseconds(float seconds) {
    return lroundf(seconds * 1000000.0f);
} // unitTimeToMicroseconds

// Time

float unitTimeFromMicroseconds(int32_t microseconds) {
    return (float)microseconds * 1e-6f;
} // unitTimeFromMicroseconds

int32_t unitTimeToMicroseconds(float seconds) {
    return lroundf(seconds * 1000000.0f);
} // unitTimeToMicroseconds
