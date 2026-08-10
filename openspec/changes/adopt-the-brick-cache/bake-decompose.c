// Where does ClaySpace's bake time actually go?
//
// The app: clay_document_save -> (worker) clay_document_load ->
// clay_eval_points(doc, nil, ...) over a ~192^3 grid, CPU backend, tape
// compiled for the WHOLE document with no cull region.
//
// This times each part against a document shaped like the measured session
// (a ball plus N stroke items), and compares clay_eval_points against
// clay_eval_grid with a cull region — the culling the ABI says is "where the
// brick cache's measured win lives".
#include "clay.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static clay_document *build(int strokes) {
    clay_document *doc = clay_document_create();
    clay_layer_id layer = 0;
    clay_add_sdf_layer(doc, "L", &layer);
    float r = 0.5f;
    clay_item *ball = clay_item_create(CLAY_PRIM_SPHERE, &r, 1);
    clay_item_set_op(ball, CLAY_OP_ADD);
    clay_node_id n = 0;
    clay_layer_add_item(doc, layer, ball, &n);
    clay_item_destroy(ball);

    for (int s = 0; s < strokes; ++s) {
        clay_item *st = clay_item_create(CLAY_PRIM_STROKE, NULL, 0);
        for (int k = -8; k < 8; ++k) {
            float p[3] = { 0.015f * k, 0.5f + 0.002f * s, 0.01f * s };
            clay_item_add_stroke_point(st, p, 0.06f);
        }
        clay_item_set_op(st, CLAY_OP_RELIEF);
        clay_item_set_blend(st, CLAY_BLEND_QUADRATIC, 0.02f);
        clay_item_set_rounding(st, 0.05f);
        clay_node_id sn = 0;
        clay_layer_add_item(doc, layer, st, &sn);
        clay_item_destroy(st);
    }
    return doc;
}

int main(int argc, char **argv) {
    int strokes = argc > 1 ? atoi(argv[1]) : 24;
    int N = argc > 2 ? atoi(argv[2]) : 64; // grid per axis
    int M,m,p; clay_version(&M,&m,&p);
    printf("ClayCore %d.%d.%d | %d stroke items | %d^3 grid\n", M, m, p, strokes, N);

    clay_document *doc = build(strokes);

    const char *path = "/tmp/clayspace-bake-probe.clayspace";
    double t0 = now_ms();
    if (clay_document_save(doc, path) != CLAY_OK) { printf("save failed: %s\n", clay_last_error()); return 1; }
    double t_save = now_ms() - t0;

    t0 = now_ms();
    clay_document *loaded = NULL;
    if (clay_document_load(path, &loaded) != CLAY_OK) { printf("load failed: %s\n", clay_last_error()); return 1; }
    double t_load = now_ms() - t0;

    size_t total = (size_t)N * N * N;
    float *pts = malloc(total * 3 * sizeof(float));
    float *out = malloc(total * sizeof(float));
    float lo = -1.0f, hi = 1.5f, span = hi - lo;
    size_t i = 0;
    for (int z = 0; z < N; ++z)
      for (int y = 0; y < N; ++y)
        for (int x = 0; x < N; ++x) {
            pts[i*3+0] = lo + span * (x + 0.5f) / N;
            pts[i*3+1] = lo + span * (y + 0.5f) / N;
            pts[i*3+2] = lo + span * (z + 0.5f) / N;
            i++;
        }

    t0 = now_ms();
    if (clay_eval_points(loaded, NULL, pts, total, out, NULL) != CLAY_OK) {
        printf("eval_points failed: %s\n", clay_last_error()); return 1;
    }
    double t_points = now_ms() - t0;

    clay_grid_query q;
    memset(&q, 0, sizeof q);
    q.struct_size = (uint32_t)sizeof q;
    q.origin[0] = q.origin[1] = q.origin[2] = lo + span * 0.5f / N;
    q.spacing = span / N;
    q.dims[0] = q.dims[1] = q.dims[2] = N;

    t0 = now_ms();
    if (clay_eval_grid(loaded, NULL, &q, NULL, NULL, out, NULL, total) != CLAY_OK) {
        printf("eval_grid(uncalled) failed: %s\n", clay_last_error()); return 1;
    }
    double t_grid = now_ms() - t0;

    // The same grid, with the cull region the app never supplies.
    float rmin[3] = { lo, lo, lo }, rmax[3] = { hi, hi, hi };
    t0 = now_ms();
    if (clay_eval_grid(loaded, NULL, &q, rmin, rmax, out, NULL, total) != CLAY_OK) {
        printf("eval_grid(culled) failed: %s\n", clay_last_error()); return 1;
    }
    double t_grid_cull = now_ms() - t0;

    // A SMALL region, which is what a brush edit actually dirties: the same
    // spacing over a fifth of the span. This is where culling should tell.
    int S = N / 5; if (S < 4) S = 4;
    clay_grid_query qs = q;
    qs.dims[0] = qs.dims[1] = qs.dims[2] = S;
    qs.origin[0] = qs.origin[1] = qs.origin[2] = 0.0f;
    size_t stotal = (size_t)S * S * S;
    float sr_min[3] = { 0.0f, 0.0f, 0.0f };
    float sr_max[3] = { S * q.spacing, S * q.spacing, S * q.spacing };

    t0 = now_ms();
    clay_eval_grid(loaded, NULL, &qs, NULL, NULL, out, NULL, stotal);
    double t_small_nocull = now_ms() - t0;
    t0 = now_ms();
    clay_eval_grid(loaded, NULL, &qs, sr_min, sr_max, out, NULL, stotal);
    double t_small_cull = now_ms() - t0;

    printf("  save                     %8.1f ms\n", t_save);
    printf("  load                     %8.1f ms   <- per bake, never measured before\n", t_load);
    printf("  eval_points (app today)  %8.1f ms\n", t_points);
    printf("  eval_grid  (no cull)     %8.1f ms\n", t_grid);
    printf("  eval_grid  (culled)      %8.1f ms\n", t_grid_cull);
    printf("  small region, no cull    %8.1f ms  (%d^3)\n", t_small_nocull, S);
    printf("  small region, culled     %8.1f ms  (%d^3)\n", t_small_cull, S);

    free(pts); free(out);
    clay_document_destroy(loaded);
    clay_document_destroy(doc);
    return 0;
}
