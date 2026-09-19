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

#include <stdbool.h>
#include <stdint.h>
#include <math.h>

#include "platform.h"

#include "build/build_config.h"
#include "build/debug.h"

#include "common/axis.h"
#include "common/filter.h"
#include "common/maths.h"

#include "sensors/sensors.h"
#include "sensors/acceleration.h"
#include "sensors/boardalignment.h"

#include "flight/pid.h"
#include "flight/imu.h"

#include "fc/config.h"
#include "fc/runtime_config.h"

#include "navigation/navigation.h"
#include "navigation/navigation_private.h"
#include "navigation/navigation_gps_math.h"

#include "navigation/navigation_declination_gen.c"

// ============================================================================
// Float64 GPS Math Implementation
// ============================================================================

// Magnetic declination lookup table helper (uses float for table, but double for computation)
static double get_lookup_table_val_d(unsigned lat_index, unsigned lon_index) {
    return (double)declination_table[lat_index][lon_index];
} // get_lookup_table_val_d

// Calculate magnetic declination using double precision
double geoCalculateMagDeclinationDouble(const gpsLocationDouble_t * llh) {
    double result = 0.0;
    const double lat = llh->lat;
    const double lon = llh->lon;

    if (lat >= -90.0 && lat <= 90.0 && lon >= -180.0 && lon <= 180.0) {
        // round down to nearest sampling resolution
        int min_lat = (int)(lat * (1.0 / SAMPLING_RES)) * SAMPLING_RES;
        int min_lon = (int)(lon * (1.0 / SAMPLING_RES)) * SAMPLING_RES;

        // for the rare case of hitting the bounds exactly
        if (lat <= SAMPLING_MIN_LAT) min_lat = SAMPLING_MIN_LAT;
        if (lat >= SAMPLING_MAX_LAT) min_lat = (int)(lat * (1.0 / SAMPLING_RES)) * SAMPLING_RES - SAMPLING_RES;
        if (lon <= SAMPLING_MIN_LON) min_lon = SAMPLING_MIN_LON;
        if (lon >= SAMPLING_MAX_LON) min_lon = (int)(lon * (1.0 / SAMPLING_RES)) * SAMPLING_RES - SAMPLING_RES;

        // find index of nearest low sampling point
        const unsigned min_lat_index = (-(SAMPLING_MIN_LAT) + min_lat) / SAMPLING_RES;
        const unsigned min_lon_index = (-(SAMPLING_MIN_LON) + min_lon) / SAMPLING_RES;

        const double declination_sw = get_lookup_table_val_d(min_lat_index, min_lon_index);
        const double declination_se = get_lookup_table_val_d(min_lat_index, min_lon_index + 1);
        const double declination_ne = get_lookup_table_val_d(min_lat_index + 1, min_lon_index + 1);
        const double declination_nw = get_lookup_table_val_d(min_lat_index + 1, min_lon_index);

        // perform bilinear interpolation on the four grid corners
        const double lon_frac = (lon - min_lon) * (1.0 / SAMPLING_RES);
        const double lat_frac = (lat - min_lat) * (1.0 / SAMPLING_RES);

        const double declination_min = lon_frac * (declination_se - declination_sw) + declination_sw;
        const double declination_max = lon_frac * (declination_ne - declination_nw) + declination_nw;

        result = lat_frac * (declination_max - declination_min) + declination_min;
    }

    return result;
} // geoCalculateMagDeclinationDouble

// Set GPS origin using double precision
void geoSetOriginDouble(gpsOriginDouble_t * origin, const gpsLocationDouble_t * llh, geoOriginResetMode_e resetMode) {
    if (resetMode == GEO_ORIGIN_SET) {
        origin->valid = true;
        origin->lat = llh->lat;
        origin->lon = llh->lon;
        origin->alt = llh->alt;
        origin->scale = cos(fabs(origin->lat) * DEG2RAD_D);
        if (origin->scale < 0.01) origin->scale = 0.01;
        else if (origin->scale > 1.0) origin->scale = 1.0;
    }
    else if (origin->valid && (resetMode == GEO_ORIGIN_RESET_ALTITUDE)) origin->alt = llh->alt;
} // geoSetOriginDouble

// Convert geodetic to local (NEU) using double precision
bool geoConvertGeodeticToLocalDouble(fpVector3_t * pos, const gpsOriginDouble_t * origin, const gpsLocationDouble_t * llh, geoAltitudeConversionMode_e altConv) {
    bool result = false;

    if (origin->valid) {
        pos->x = (llh->lat - origin->lat) * DISTANCE_BETWEEN_TWO_LONGITUDE_POINTS_AT_EQUATOR_D;
        pos->y = (llh->lon - origin->lon) * (DISTANCE_BETWEEN_TWO_LONGITUDE_POINTS_AT_EQUATOR_D * origin->scale);

        // If flag GEO_ALT_RELATIVE, than llh altitude is already relative to origin
        if (altConv == GEO_ALT_RELATIVE) pos->z = (float)llh->alt;

        result = true;
    } else {
        pos->x = 0.0f;
        pos->y = 0.0f;
        pos->z = 0.0f;
    }

    return result;
} // geoConvertGeodeticToLocalDouble

// Convert local (NEU) to geodetic using double precision
bool geoConvertLocalToGeodeticDouble(gpsLocationDouble_t * llh, const gpsOriginDouble_t * origin, const fpVector3_t * pos) {
    double scaleLonDown;

    if (origin->valid) {
        llh->lat = origin->lat;
        llh->lon = origin->lon;
        llh->alt = origin->alt;
        scaleLonDown = origin->scale;
    }
    else {
        llh->lat = 0.0;
        llh->lon = 0.0;
        llh->alt = 0.0;
        scaleLonDown = 1.0;
    }

    llh->lat += pos->x / DISTANCE_BETWEEN_TWO_LONGITUDE_POINTS_AT_EQUATOR_D;
    llh->lon += pos->y / (DISTANCE_BETWEEN_TWO_LONGITUDE_POINTS_AT_EQUATOR_D * scaleLonDown);
    llh->alt += pos->z;

    return origin->valid;
} // geoConvertLocalToGeodeticDouble

// Calculate distance between two geodetic points (Haversine formula, double precision)
double geoDistanceDouble(const gpsLocationDouble_t * a, const gpsLocationDouble_t * b) {
    const double lat1 = a->lat * DEG2RAD_D;
    const double lat2 = b->lat * DEG2RAD_D;
    const double dLat = (b->lat - a->lat) * DEG2RAD_D;
    const double dLon = (b->lon - a->lon) * DEG2RAD_D;

    const double sin_dLat2 = sin(dLat2 * 0.5);
    const double sin_dLon2 = sin(dLon2 * 0.5);

    const double a_hav = sin_dLat2 * sin_dLat2 + cos(lat1) * cos(lat2) * sin_dLon2 * sin_dLon2;
    const double c = 2.0 * atan2(sqrt(a_hav), sqrt(1.0 - a_hav));

    // Earth radius in meters (WGS84 mean radius)
    const double R = 6371000.0;

    return R * c;
} // geoDistanceDouble

// Calculate bearing from point A to point B (double precision)
double geoBearingDouble(const gpsLocationDouble_t * a, const gpsLocationDouble_t * b) {
    const double lat1 = a->lat * DEG2RAD_D;
    const double lat2 = b->lat * DEG2RAD_D;
    const double dLon = (b->lon - a->lon) * DEG2RAD_D;

    const double y = sin(dLon) * cos(lat2);
    const double x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);

    double bearing = atan2(y, x) * RAD2DEG_D;

    if (bearing < 0.0) bearing += 360.0;

    return bearing;
} // geoBearingDouble
