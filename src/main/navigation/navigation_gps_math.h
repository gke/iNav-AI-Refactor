/*
 * This file is part of Cleanflight.
 *
 * Cleanflight is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Cleanflight is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cleanflight.  If not, see <http://www.gnu.org/licenses/>.
 */

#pragma once

#include <stdint.h>
#include <stdbool.h>

#include "common/vector.h"

// ============================================================================
// Float64 GPS Math Types
// ============================================================================
// These types provide double-precision (float64) representations of GPS
// coordinates for internal navigation computations, preserving the 1 m
// precision of the int32_t deg*radians (GPS radians) storage format.
//
// Storage/transmission boundary (PG, MSP, blackbox, flash): int32_t deg*radians (GPS radians)
// Internal computation boundary: float64 (double)
//
// Conversion: 1 count = 1e-7 radians ≈ 1.11 m at equator

// High-precision geodetic coordinate (latitude/longitude in radians, altitude in meters)
typedef struct gpsLocationDouble_s {
    double lat;   // Latitude in radians
    double lon;   // Longitude in radians
    double alt;   // Altitude in meters
} gpsLocationDouble_t;

// High-precision GPS origin for local coordinate conversions
typedef struct gpsOriginDouble_s {
    bool valid;
    double lat;   // Latitude in radians
    double lon;   // Longitude in radians
    double alt;   // Altitude in meters
    double scale; // cos(lat) for longitude scaling
} gpsOriginDouble_t;

// High-precision GPS solution data (for internal navigation use)
typedef struct gpsSolutionDataDouble_s {
    gpsLocationDouble_t llh;
    double velNED[3];  // m/s
    double eph;        // horizontal accuracy (meters)
    double epv;        // vertical accuracy (meters)
    double hdop;       // HDOP value
} gpsSolutionDataDouble_t;

// ============================================================================
// Conversion Functions
// ============================================================================

// Integer radians * radians (GPS radians) to double radians
static inline double deg1e7ToDouble(int32_t deg1e7)
{
    return deg1e7 * 1e-7;
}

// Double radians to integer radians * radians (GPS radians) (with rounding)
static inline int32_t doubleToDeg1e7(double deg)
{
    return (int32_t)lrint(deg * 1e7);
}

// Integer centimeters to double meters
static inline double cmToMeters(int32_t cm)
{
    return cm * 0.01;
}

// Double meters to integer centimeters (with rounding)
static inline int32_t metersToCm(double m)
{
    return (int32_t)lrint(m * 100.0);
}

// Convert gpsLocation_t (storage) to gpsLocationDouble_t (computation)
static inline gpsLocationDouble_t gpsLocationToDouble(const gpsLocation_t * src)
{
    gpsLocationDouble_t dst;
    dst.lat = deg1e7ToDouble(src->lat);
    dst.lon = deg1e7ToDouble(src->lon);
    dst.alt = cmToMeters(src->alt);
    return dst;
}

// Convert gpsLocationDouble_t (computation) to gpsLocation_t (storage)
static inline gpsLocation_t gpsLocationFromDouble(const gpsLocationDouble_t * src)
{
    gpsLocation_t dst;
    dst.lat = doubleToDeg1e7(src->lat);
    dst.lon = doubleToDeg1e7(src->lon);
    dst.alt = metersToCm(src->alt);
    return dst;
}

// Convert gpsOrigin_t (storage) to gpsOriginDouble_t (computation)
static inline gpsOriginDouble_t gpsOriginToDouble(const gpsOrigin_t * src)
{
    gpsOriginDouble_t dst;
    dst.valid = src->valid;
    if (src->valid) {
        dst.lat = deg1e7ToDouble(src->lat);
        dst.lon = deg1e7ToDouble(src->lon);
        dst.alt = cmToMeters(src->alt);
        dst.scale = src->scale;
    } else {
        dst.lat = 0.0;
        dst.lon = 0.0;
        dst.alt = 0.0;
        dst.scale = 1.0;
    }
    return dst;
}

// Convert gpsOriginDouble_t (computation) to gpsOrigin_t (storage)
static inline gpsOrigin_t gpsOriginFromDouble(const gpsOriginDouble_t * src)
{
    gpsOrigin_t dst;
    dst.valid = src->valid;
    if (src->valid) {
        dst.lat = doubleToDeg1e7(src->lat);
        dst.lon = doubleToDeg1e7(src->lon);
        dst.alt = metersToCm(src->alt);
        dst.scale = src->scale;
    } else {
        dst.lat = 0;
        dst.lon = 0;
        dst.alt = 0;
        dst.scale = 1.0f;
    }
    return dst;
}

// ============================================================================
// High-Precision Constants (double precision)
// ============================================================================

#define DISTANCE_BETWEEN_TWO_LONGITUDE_POINTS_AT_EQUATOR_D  111319.49079327357  // meters per radians at equator
#define DEG2RAD_D                                           0.017453292519943295  // pi/180
#define RAD2DEG_D                                           57.29577951308232     // 180/pi
#define GPS_DEGREES_DIVIDER_D                               1e7

// ============================================================================
// Float64 GPS Math Functions
// ============================================================================

// Calculate magnetic declination using double precision
double geoCalculateMagDeclinationDouble(const gpsLocationDouble_t * llh);

// Set GPS origin using double precision
void geoSetOriginDouble(gpsOriginDouble_t * origin, const gpsLocationDouble_t * llh, geoOriginResetMode_e resetMode);

// Convert geodetic to local (NEU) using double precision
bool geoConvertGeodeticToLocalDouble(fpVector3_t * pos, const gpsOriginDouble_t * origin, const gpsLocationDouble_t * llh, geoAltitudeConversionMode_e altConv);

// Convert local (NEU) to geodetic using double precision
bool geoConvertLocalToGeodeticDouble(gpsLocationDouble_t * llh, const gpsOriginDouble_t * origin, const fpVector3_t * pos);

// Calculate distance between two geodetic points (Haversine formula, double precision)
double geoDistanceDouble(const gpsLocationDouble_t * a, const gpsLocationDouble_t * b);

// Calculate bearing from point A to point B (double precision)
double geoBearingDouble(const gpsLocationDouble_t * a, const gpsLocationDouble_t * b);
