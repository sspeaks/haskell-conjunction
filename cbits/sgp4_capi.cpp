#include "sgp4_capi.h"
#include "SGP4.h"

#include <cstddef>
#include <cstdio>
#include <cstring>
#include <new>

static inline elsetrec *to_rec(sgp4c_satrec_t *satrec)
{
    return reinterpret_cast<elsetrec *>(satrec);
}

static inline const elsetrec *to_rec(const sgp4c_satrec_t *satrec)
{
    return reinterpret_cast<const elsetrec *>(satrec);
}

static bool to_gravconst(int whichconst, gravconsttype *out)
{
    if (out == nullptr)
        return false;

    switch (whichconst)
    {
    case SGP4C_WGS72OLD:
        *out = wgs72old;
        return true;
    case SGP4C_WGS72:
        *out = wgs72;
        return true;
    case SGP4C_WGS84:
        *out = wgs84;
        return true;
    default:
        return false;
    }
}

static bool valid_opsmode(char opsmode)
{
    return opsmode == 'a' || opsmode == 'i';
}

static bool copy_tle_line(char dest[130], const char *src)
{
    if (src == nullptr)
        return false;

    std::memset(dest, 0, 130);

    std::size_t len = 0;
    while (len < 130 && src[len] != '\0')
        ++len;

    if (len < 69 || len >= 130)
        return false;

    std::memcpy(dest, src, len);
    return true;
}

static void normalize_tle_lines(char line1[130], char line2[130])
{
    for (int j = 10; j <= 15; ++j)
        if (line1[j] == ' ')
            line1[j] = '_';

    if (line1[44] != ' ')
        line1[43] = line1[44];
    line1[44] = '.';
    if (line1[7] == ' ')
        line1[7] = 'U';
    if (line1[9] == ' ')
        line1[9] = '.';
    for (int j = 45; j <= 49; ++j)
        if (line1[j] == ' ')
            line1[j] = '0';
    if (line1[51] == ' ')
        line1[51] = '0';
    if (line1[53] != ' ')
        line1[52] = line1[53];
    line1[53] = '.';
    line2[25] = '.';
    for (int j = 26; j <= 32; ++j)
        if (line2[j] == ' ')
            line2[j] = '0';
    if (line1[62] == ' ')
        line1[62] = '0';
    if (line1[68] == ' ')
        line1[68] = '0';
}

static bool validate_tle_scan(const char line1[130], const char line2[130])
{
    char scan_line1[130];
    char scan_line2[130];
    std::memcpy(scan_line1, line1, 130);
    std::memcpy(scan_line2, line2, 130);
    normalize_tle_lines(scan_line1, scan_line2);

    int cardnumb1 = 0;
    int cardnumb2 = 0;
    char satnum1[6] = {0};
    char satnum2[6] = {0};
    char classification = 0;
    char intldesg[11] = {0};
    int epochyr = 0;
    double epochdays = 0.0;
    double ndot = 0.0;
    double nddot = 0.0;
    int nexp = 0;
    double bstar = 0.0;
    int ibexp = 0;
    int ephtype = 0;
    long elnum = 0;
    double inclo = 0.0;
    double nodeo = 0.0;
    double ecco = 0.0;
    double argpo = 0.0;
    double mo = 0.0;
    double no_kozai = 0.0;
    long revnum = 0;

    int line1_count = std::sscanf(
        scan_line1,
        "%2d %5s %1c %10s %2d %12lf %11lf %7lf %2d %7lf %2d %2d %6ld ",
        &cardnumb1,
        satnum1,
        &classification,
        intldesg,
        &epochyr,
        &epochdays,
        &ndot,
        &nddot,
        &nexp,
        &bstar,
        &ibexp,
        &ephtype,
        &elnum);

    const char *line2_format =
        scan_line2[52] == ' '
            ? "%2d %5s %9lf %9lf %8lf %9lf %9lf %10lf %6ld "
            : "%2d %5s %9lf %9lf %8lf %9lf %9lf %11lf %6ld ";

    int line2_count = std::sscanf(
        scan_line2,
        line2_format,
        &cardnumb2,
        satnum2,
        &inclo,
        &nodeo,
        &ecco,
        &argpo,
        &mo,
        &no_kozai,
        &revnum);

    return line1_count == 13 &&
           line2_count == 9 &&
           cardnumb1 == 1 &&
           cardnumb2 == 2 &&
           std::strncmp(satnum1, satnum2, 5) == 0;
}

extern "C" {

sgp4c_satrec_t *sgp4c_satrec_alloc(void)
{
    elsetrec *satrec = new (std::nothrow) elsetrec();
    if (satrec == nullptr)
        return nullptr;

    std::memset(satrec, 0, sizeof(elsetrec));
    return reinterpret_cast<sgp4c_satrec_t *>(satrec);
}

void sgp4c_satrec_free(sgp4c_satrec_t *satrec)
{
    delete to_rec(satrec);
}

int sgp4c_twoline2rv(
    sgp4c_satrec_t *satrec,
    const char *line1,
    const char *line2,
    char opsmode,
    int whichconst,
    double *out_startmfe,
    double *out_stopmfe,
    double *out_deltamin)
{
    if (satrec == nullptr || !valid_opsmode(opsmode))
        return SGP4C_ERR_BADARG;

    gravconsttype gravity;
    if (!to_gravconst(whichconst, &gravity))
        return SGP4C_ERR_BADARG;

    char local_line1[130];
    char local_line2[130];
    if (!copy_tle_line(local_line1, line1) || !copy_tle_line(local_line2, line2))
        return SGP4C_ERR_BADARG;
    if (!validate_tle_scan(local_line1, local_line2))
        return SGP4C_ERR_BADARG;

    double startmfe = 0.0;
    double stopmfe = 0.0;
    double deltamin = 0.0;
    elsetrec *record = to_rec(satrec);

    SGP4Funcs::twoline2rv(
        local_line1,
        local_line2,
        'c',
        'm',
        opsmode,
        gravity,
        startmfe,
        stopmfe,
        deltamin,
        *record);

    if (out_startmfe != nullptr)
        *out_startmfe = startmfe;
    if (out_stopmfe != nullptr)
        *out_stopmfe = stopmfe;
    if (out_deltamin != nullptr)
        *out_deltamin = deltamin;

    return record->error;
}

int sgp4c_propagate(
    sgp4c_satrec_t *satrec,
    double tsince,
    double r_km[3],
    double v_kms[3])
{
    if (satrec == nullptr || r_km == nullptr || v_kms == nullptr)
        return SGP4C_ERR_BADARG;

    elsetrec *record = to_rec(satrec);
    SGP4Funcs::sgp4(*record, tsince, r_km, v_kms);
    return record->error;
}

int sgp4c_propagate_state(
    sgp4c_satrec_t *satrec,
    double tsince,
    double state[6])
{
    if (state == nullptr)
        return SGP4C_ERR_BADARG;

    return sgp4c_propagate(satrec, tsince, state, state + 3);
}

int sgp4c_propagate_many(
    sgp4c_satrec_t *satrec,
    const double *tsince,
    std::size_t count,
    double *r_km,
    double *v_kms,
    int *errors)
{
    if (satrec == nullptr)
        return SGP4C_ERR_BADARG;
    if (count > 0 && (tsince == nullptr || r_km == nullptr || v_kms == nullptr || errors == nullptr))
        return SGP4C_ERR_BADARG;

    elsetrec *record = to_rec(satrec);
    int first_error = SGP4C_OK;
    for (std::size_t i = 0; i < count; ++i)
    {
        double *r = r_km + (i * 3);
        double *v = v_kms + (i * 3);
        SGP4Funcs::sgp4(*record, tsince[i], r, v);
        const int code = record->error;
        errors[i] = code;
        if (first_error == SGP4C_OK && code != SGP4C_OK)
            first_error = code;
    }

    return first_error;
}

int sgp4c_satrec_error(const sgp4c_satrec_t *satrec)
{
    if (satrec == nullptr)
        return SGP4C_ERR_BADARG;

    return to_rec(satrec)->error;
}

void sgp4c_satrec_epoch_jd(const sgp4c_satrec_t *satrec, double *jd, double *jd_frac)
{
    if (satrec == nullptr)
        return;

    const elsetrec *record = to_rec(satrec);
    if (jd != nullptr)
        *jd = record->jdsatepoch;
    if (jd_frac != nullptr)
        *jd_frac = record->jdsatepochF;
}

void sgp4c_satrec_satnum(const sgp4c_satrec_t *satrec, char out[6])
{
    if (satrec == nullptr || out == nullptr)
        return;

    std::memcpy(out, to_rec(satrec)->satnum, 6);
}

}
