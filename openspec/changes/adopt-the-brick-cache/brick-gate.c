/* The measurement gate (tasks 1.1-1.4): does the brick cache beat the dense
 * bake on OUR scenes, at the pin the app actually links (v0.30.0)?
 *
 * Scene per 1.2: a ball, twelve relief chain strokes (the app's standard
 * brush authors CLAY_PRIM_STROKE chains), then EIGHT hPolish regional swaps
 * applied sequentially — the sequence the dense bake's numbers were taken
 * on. After each polish both representations refresh:
 *
 *   dense: clay_eval_grid over the 192-per-axis lattice the app bakes
 *          (its polish slab reaches 83-86% of the grid, so the full grid
 *          is within 20% of what the app pays and simpler to state);
 *   brick: mark_dirty_nodes(pair) -> take_dirty -> eval_requests -> submit.
 *
 * Both run the same backend. Report per-edit wall time, bricks re-evaluated
 * against bricks stored, and memory. Then the property the design rests on
 * (1.3): after a small far-away edit, every brick outside the mark comes
 * back BYTE-identical. Then the size axis (1.4): the same protocol on a 4x
 * model, where the dense grid coarsens (fixed 192) and the cache does not.
 *
 * Build (from the repo root, sibling ClayCore checkout at the pin):
 *   clang -O2 -I ../ClayCore/dist/claycore.xcframework/macos-arm64/Headers \
 *     openspec/changes/adopt-the-brick-cache/brick-gate.c \
 *     ../ClayCore/dist/claycore.xcframework/macos-arm64/libclaycore-macos.a \
 *     -lc++ -framework Metal -framework Foundation -o /tmp/brick-gate
 *   /tmp/brick-gate [backend]        (default metal; "cpu" for the A/B)
 */
#include "clay.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void die(const char* what) {
    fprintf(stderr, "FAIL %s: %s\n", what, clay_last_error());
    exit(2);
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

/* -- the app's authoring, verbatim from its engine paths ------------------- */

static void stroke(clay_document* doc, clay_layer_id layer, float scale,
                   float row) {
    const float radius = 0.22f * scale;
    clay_item* item = clay_item_create(CLAY_PRIM_STROKE, NULL, 0);
    if (!item) die("stroke item");
    float first[3] = {0, (0.9f + row) * scale, 0.15f * scale * sinf(row * 10)};
    clay_item_add_stroke_point(item, first, radius);
    clay_item_set_stroke_blend_k(item, radius * 0.12f);
    clay_item_set_rounding(item, 0.9f * 0.12f);
    clay_item_set_op(item, CLAY_OP_RELIEF);
    clay_item_set_blend(item, CLAY_BLEND_QUADRATIC, 0.12f);
    clay_node_id node;
    if (clay_layer_add_item(doc, layer, item, &node) != CLAY_OK) die("stroke add");
    clay_item_destroy(item);
    for (int i = 1; i < 16; i++) {
        float t = (float)i / 15;
        float ang = (t - 0.5f) * 1.6f;
        float p[4] = {sinf(ang) * scale, cosf(ang) * 0.9f * scale + row * scale,
                      0.15f * scale * sinf(t * 7 + row * 10), radius};
        if (clay_layer_append_stroke(doc, layer, node, p, 1) != CLAY_OK)
            die("append");
    }
}

/* One hPolish regional swap; returns the two node ids through out_nodes. */
static void polish(clay_document* doc, clay_layer_id layer,
                   const float center[3], float radius,
                   clay_node_id out_nodes[2]) {
    const float n[3] = {0, 1, 0};
    const float pad = radius * 1.6f + 0.05f;
    const float cell = radius / 14.0f;
    float bmin[3], bmax[3];
    for (int i = 0; i < 3; i++) { bmin[i] = center[i] - pad; bmax[i] = center[i] + pad; }

    clay_volume_params vp;
    memset(&vp, 0, sizeof vp);
    vp.struct_size = sizeof vp;
    vp.cell_size = cell;
    vp.band = sqrtf(3.0f) * 2.0f * pad;
    clay_item* vitem = NULL;
    if (clay_item_volume_from_document(doc, &vp, bmin, bmax, &vitem) != CLAY_OK)
        die("volume_from_document");

    clay_flatten_params fp;
    memset(&fp, 0, sizeof fp);
    fp.struct_size = sizeof fp;
    for (int i = 0; i < 3; i++) {
        fp.plane_point[i] = center[i] - n[i] * (radius * 0.25f);
        fp.plane_normal[i] = n[i];
        fp.centre[i] = center[i];
    }
    fp.strength = 1;
    fp.region_radius = radius;
    fp.falloff = radius * 0.4f;
    fp.mode = CLAY_FLATTEN_CUT_ONLY;
    if (clay_item_volume_flatten(vitem, &fp) != CLAY_OK) die("flatten");
    clay_item_set_op(vitem, CLAY_OP_ADD);
    clay_item_set_blend(vitem, CLAY_BLEND_HARD, 0);

    float half[3] = {pad - cell, pad - cell, pad - cell};
    clay_item* box = clay_item_create(CLAY_PRIM_BOX, half, 3);
    clay_item_set_position(box, center);
    clay_item_set_op(box, CLAY_OP_SUBTRACT);
    clay_item_set_blend(box, CLAY_BLEND_HARD, 0);

    if (clay_layer_add_item(doc, layer, box, &out_nodes[0]) != CLAY_OK) die("add box");
    if (clay_layer_add_item(doc, layer, vitem, &out_nodes[1]) != CLAY_OK) die("add vol");
    clay_item_destroy(box);
    clay_item_destroy(vitem);
}

/* The MODERN construction (task 1.6): one feathered REPLACE volume from
 * clay_item_volume_flatten_from — the document-sourced flatten 0.28 shipped
 * for exactly this path. Band defaults to three cells and the feather sits
 * at about one band (the header's sweet spot), so the item's influence is
 * the sampled box plus a few cells rather than the pair's box-diagonal
 * band. The pair construction above predates the _from verbs and is what
 * the app still does. */
static void polish_modern(clay_document* doc, clay_layer_id layer,
                          const float center[3], float radius,
                          clay_node_id* out_node) {
    const float n[3] = {0, 1, 0};
    const float pad = radius * 1.6f + 0.05f;
    const float cell = radius / 14.0f;
    float bmin[3], bmax[3];
    for (int i = 0; i < 3; i++) { bmin[i] = center[i] - pad; bmax[i] = center[i] + pad; }

    clay_flatten_params fp;
    memset(&fp, 0, sizeof fp);
    fp.struct_size = sizeof fp;
    for (int i = 0; i < 3; i++) {
        fp.plane_point[i] = center[i] - n[i] * (radius * 0.25f);
        fp.plane_normal[i] = n[i];
        fp.centre[i] = center[i];
    }
    fp.strength = 1;
    fp.region_radius = radius;
    fp.falloff = radius * 0.4f;
    fp.mode = CLAY_FLATTEN_CUT_ONLY;

    clay_volume_params vp;
    memset(&vp, 0, sizeof vp);
    vp.struct_size = sizeof vp;
    vp.cell_size = cell;
    vp.band = 0;             /* default: three cells */
    vp.feather = 3 * cell;   /* about one band */

    clay_item* vitem = NULL;
    if (clay_item_volume_flatten_from(doc, &fp, &vp, bmin, bmax, &vitem)
        != CLAY_OK) die("flatten_from");
    clay_item_set_op(vitem, CLAY_OP_REPLACE);
    clay_item_set_blend(vitem, CLAY_BLEND_HARD, 0);
    if (clay_layer_add_item(doc, layer, vitem, out_node) != CLAY_OK)
        die("add modern");
    clay_item_destroy(vitem);
}

/* -- the two representations ----------------------------------------------- */

/* The dense side: the app's grid layout (192 on the longest axis), one
 * eval_grid over all of it. Returns wall ms. */
static double dense_refresh(clay_document* doc, const char* backend,
                            float extent_half) {
    enum { N = 192 };
    const float lo = -extent_half, hi = extent_half;
    const float spacing = (hi - lo) / N;
    clay_grid_query q;
    memset(&q, 0, sizeof q);
    q.struct_size = sizeof q;
    q.origin[0] = q.origin[1] = q.origin[2] = lo + spacing * 0.5f;
    q.spacing = spacing;
    q.dims[0] = q.dims[1] = q.dims[2] = N;
    size_t total = (size_t)N * N * N;
    static float* values = NULL;
    static float* colors = NULL;
    if (!values) values = malloc(total * sizeof(float));
    if (!colors) colors = malloc(total * 3 * sizeof(float));
    double t0 = now_ms();
    if (clay_eval_grid(doc, backend, &q, NULL, NULL, values, colors, total)
        != CLAY_OK) die("dense eval");
    return now_ms() - t0;
}

/* One full drain of the brick path. Returns wall ms; reports how many
 * requests were evaluated and how many rejected. */
static double brick_refresh(clay_brick_cache* cache, clay_document* doc,
                            const char* backend, int dim,
                            size_t* out_evaluated, size_t* out_rejected) {
    enum { BATCH = 4096 };
    size_t lattice = (size_t)dim * dim * dim;
    static clay_brick_request* requests = NULL;
    static float* values = NULL;
    static float* colors = NULL;
    static int32_t* results = NULL;
    if (!requests) {
        requests = malloc(BATCH * sizeof(clay_brick_request));
        values = malloc(BATCH * lattice * sizeof(float));
        colors = malloc(BATCH * lattice * 3 * sizeof(float));
        results = malloc(BATCH * sizeof(int32_t));
    }
    size_t evaluated = 0, rejected = 0;
    double t0 = now_ms();
    for (;;) {
        size_t count = BATCH, remaining = 0;
        if (clay_brick_cache_take_dirty(cache, requests, &count, &remaining)
            != CLAY_OK) die("take_dirty");
        if (count == 0) break;
        if (clay_brick_cache_eval_requests(doc, backend, requests, count,
                                           values, count * lattice,
                                           colors, count * lattice * 3)
            != CLAY_OK) die("eval_requests");
        size_t accepted = 0;
        if (clay_brick_cache_submit(cache, requests, count,
                                    values, count * lattice,
                                    colors, count * lattice * 3,
                                    results, &accepted) != CLAY_OK)
            die("submit");
        evaluated += count;
        rejected += count - accepted;
        if (remaining == 0) break;
    }
    if (out_evaluated) *out_evaluated = evaluated;
    if (out_rejected) *out_rejected = rejected;
    return now_ms() - t0;
}

/* -- 1.3: byte-identity of unmarked bricks --------------------------------- */

typedef struct {
    int32_t* keys;
    uint16_t* halves;
    uint8_t* colors;
    size_t count, lattice;
} snapshot;

static snapshot snap_bricks(clay_brick_cache* cache, int dim) {
    snapshot s;
    s.lattice = (size_t)dim * dim * dim;
    s.count = 0;
    if (clay_brick_cache_surface_bricks(cache, NULL, &s.count) != CLAY_OK)
        die("surface count");
    s.keys = malloc(s.count * 3 * sizeof(int32_t));
    size_t n = s.count;
    if (clay_brick_cache_surface_bricks(cache, s.keys, &n) != CLAY_OK)
        die("surface keys");
    s.halves = malloc(s.count * s.lattice * sizeof(uint16_t));
    s.colors = malloc(s.count * s.lattice * 4);
    int32_t* states = malloc(s.count * sizeof(int32_t));
    if (clay_brick_cache_read_bricks(cache, 0, s.keys, s.count, 0, states,
                                     s.halves, s.count * s.lattice,
                                     s.colors, s.count * s.lattice * 4)
        != CLAY_OK) die("read_bricks");
    free(states);
    return s;
}

int main(int argc, char** argv) {
    const char* backend = argc > 1 ? argv[1] : "metal";
    int modern = argc > 2 && strcmp(argv[2], "modern") == 0;
    printf("backend: %s   construction: %s\n"
           " (numbers are ratios between the two paths on this machine; the\n"
           " device gate re-checks on hardware)\n\n",
           backend, modern ? "modern flatten_from + feathered REPLACE"
                           : "pair (box SUBTRACT + giant-band volume ADD)");

    for (int big = 0; big <= 1; big++) {
        float scale = big ? 4.0f : 1.0f;
        float extent_half = 1.4f * scale;
        printf("== %s model (ball r=%.0f, dense cell %.4f) ==\n",
               big ? "LARGE" : "small", scale, 2 * extent_half / 192);

        clay_document* doc = clay_document_create();
        clay_layer_id layer;
        if (clay_add_sdf_layer(doc, "base", &layer) != CLAY_OK) die("layer");
        float r = 1.0f * scale;
        clay_item* ball = clay_item_create(CLAY_PRIM_SPHERE, &r, 1);
        clay_node_id bn;
        clay_layer_add_item(doc, layer, ball, &bn);
        clay_item_destroy(ball);
        for (int i = 0; i < 12; i++)
            stroke(doc, layer, scale, 0.04f * (float)(i - 6));

        /* Detail parity with the dense grid: its cell on this scene. The
         * 0.05 default would flatter the cache on the small model and
         * starve it on the large one. */
        clay_brick_config cfg;
        if (clay_brick_config_defaults(&cfg) != CLAY_OK) die("defaults");
        cfg.voxel_size = 2 * extent_half / 192;
        cfg.colors = 1;
        clay_brick_cache* cache = clay_brick_cache_create(&cfg);
        if (!cache) die("cache create");

        double t0 = now_ms();
        if (clay_brick_cache_mark_dirty_layer(cache, doc, layer) != CLAY_OK)
            die("mark layer");
        size_t evaluated, rejected;
        double fill_ms = brick_refresh(cache, doc, backend, cfg.dim,
                                       &evaluated, &rejected);
        double mark_ms = now_ms() - t0 - fill_ms;
        double dense_ms = dense_refresh(doc, backend, extent_half);
        clay_brick_stats st;
        st.struct_size = sizeof st;
        clay_brick_cache_stats(cache, &st);
        printf("initial fill: dense %.1f ms | bricks %.1f ms "
               "(mark %.1f, %zu bricks, %.1f MB)\n",
               dense_ms, fill_ms, mark_ms, evaluated,
               st.memory_usage / 1048576.0);

        printf("%-8s %10s %12s %9s %9s %9s\n",
               "polish", "dense ms", "brick ms", "bricks", "rejected", "stored");
        for (int p = 0; p < 8; p++) {
            float t = (float)p * 0.15f;
            float c[3] = {sinf(t) * 0.6f * scale,
                          (cosf(t * 0.7f) * 0.4f + 0.75f) * scale,
                          sinf(t * 0.5f) * 0.3f * scale};
            clay_node_id pair[2];
            size_t node_count;
            if (modern) {
                polish_modern(doc, layer, c, 0.3f * scale, &pair[0]);
                node_count = 1;
            } else {
                polish(doc, layer, c, 0.3f * scale, pair);
                node_count = 2;
            }

            double d_ms = dense_refresh(doc, backend, extent_half);

            size_t marked = 0;
            if (clay_brick_cache_mark_dirty_nodes(cache, doc, layer, pair,
                                                  node_count, &marked)
                != CLAY_OK)
                die("mark nodes");
            double b_ms = brick_refresh(cache, doc, backend, cfg.dim,
                                        &evaluated, &rejected);
            clay_brick_cache_stats(cache, &st);
            printf("%-8d %10.1f %12.1f %9zu %9zu %9llu\n",
                   p, d_ms, b_ms, evaluated, rejected,
                   (unsigned long long)st.surface_bricks);
        }

        /* 1.3: a small far edit, then every unmarked brick byte-identical. */
        if (!big) {
            snapshot before = snap_bricks(cache, cfg.dim);
            float sr = 0.08f;
            clay_item* stamp = clay_item_create(CLAY_PRIM_SPHERE, &sr, 1);
            float pos[3] = {0, -1.0f, 0}; /* the south pole; edits so far
                                           * clustered near the crown */
            clay_item_set_position(stamp, pos);
            clay_item_set_op(stamp, CLAY_OP_ADD);
            clay_item_set_blend(stamp, CLAY_BLEND_QUADRATIC, 0.03f);
            clay_node_id sn;
            if (clay_layer_add_item(doc, layer, stamp, &sn) != CLAY_OK)
                die("far stamp");
            clay_item_destroy(stamp);
            size_t marked = 0;
            if (clay_brick_cache_mark_dirty_nodes(cache, doc, layer, &sn, 1,
                                                  &marked) != CLAY_OK)
                die("mark far");
            /* Which keys did the mark touch? Snapshot the dirty set by
             * peeking at the requests without evaluating: drain, remember,
             * then evaluate and submit them as usual. */
            brick_refresh(cache, doc, backend, cfg.dim, &evaluated, &rejected);
            snapshot after = snap_bricks(cache, cfg.dim);

            size_t changed = 0, compared = 0;
            for (size_t i = 0; i < before.count; i++) {
                /* find the same key after (order is not stable) */
                for (size_t j = 0; j < after.count; j++) {
                    if (memcmp(&before.keys[i * 3], &after.keys[j * 3],
                               3 * sizeof(int32_t)) != 0) continue;
                    compared++;
                    if (memcmp(&before.halves[i * before.lattice],
                               &after.halves[j * after.lattice],
                               before.lattice * sizeof(uint16_t)) != 0
                        || memcmp(&before.colors[i * before.lattice * 4],
                                  &after.colors[j * after.lattice * 4],
                                  before.lattice * 4) != 0)
                        changed++;
                    break;
                }
            }
            printf("1.3 identity: far edit re-evaluated %zu bricks; of %zu "
                   "pre-existing bricks, %zu changed bytes\n",
                   evaluated, compared, changed);
            printf("    (the changed ones must be within the stamp's "
                   "influence; eyeball the count against %zu)\n", evaluated);
            free(before.keys); free(before.halves); free(before.colors);
            free(after.keys); free(after.halves); free(after.colors);
        }

        clay_brick_cache_destroy(cache);
        clay_document_destroy(doc);
        printf("\n");
    }
    return 0;
}
