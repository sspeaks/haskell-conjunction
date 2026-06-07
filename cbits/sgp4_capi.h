#ifndef SGP4_CAPI_H
#define SGP4_CAPI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SGP4C_WGS72OLD 0
#define SGP4C_WGS72 1
#define SGP4C_WGS84 2

#define SGP4C_OK 0
#define SGP4C_ERR_ECC 1
#define SGP4C_ERR_MOTION 2
#define SGP4C_ERR_PERT 3
#define SGP4C_ERR_SEMILATUS 4
#define SGP4C_ERR_SUBORBITAL 5
#define SGP4C_ERR_DECAYED 6
#define SGP4C_ERR_ALLOC (-1)
#define SGP4C_ERR_BADARG (-2)

typedef struct sgp4c_satrec_s sgp4c_satrec_t;

sgp4c_satrec_t *sgp4c_satrec_alloc(void);
void sgp4c_satrec_free(sgp4c_satrec_t *satrec);

int sgp4c_twoline2rv(
    sgp4c_satrec_t *satrec,
    const char *line1,
    const char *line2,
    char opsmode,
    int whichconst,
    double *out_startmfe,
    double *out_stopmfe,
    double *out_deltamin);

int sgp4c_propagate(
    sgp4c_satrec_t *satrec,
    double tsince,
    double r_km[3],
    double v_kms[3]);

int sgp4c_propagate_state(
    sgp4c_satrec_t *satrec,
    double tsince,
    double state[6]);

int sgp4c_propagate_many(
    sgp4c_satrec_t *satrec,
    const double *tsince,
    size_t count,
    double *r_km,
    double *v_kms,
    int *errors);

int sgp4c_satrec_error(const sgp4c_satrec_t *satrec);
void sgp4c_satrec_epoch_jd(const sgp4c_satrec_t *satrec, double *jd, double *jd_frac);
void sgp4c_satrec_satnum(const sgp4c_satrec_t *satrec, char out[6]);

#ifdef __cplusplus
}
#endif

#endif
