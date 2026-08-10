// Minimal reproduction: clay_item_volume_from_document does not reproduce
// CLAY_OP_RELIEF geometry.
//
// Builds the same document twice, differing only in the op of the second
// item, samples the region with clay_item_volume_from_document, and compares
// the sampled volume's field against the field it was sampled from.
//
//   cc -I bindings/c relief_repro.c dist/claycore.xcframework/macos-arm64/libclaycore-macos.a -lc++ -o relief_repro
#include "clay.h"
#include <stdio.h>
#include <math.h>
#include <string.h>

#define N 7

static void fail(const char *what) {
    printf("  ! %s: %s\n", what, clay_last_error());
}

// Builds a ball plus a second item at the same place with the given op, then
// reports how far the volume sampled from that document departs from the
// document itself, at points along the shared surface.
static float probe_op(int op, const char *label) {
    clay_document *doc = clay_document_create();
    if (!doc) { fail("document_create"); return -1; }
    clay_layer_id layer = 0;
    if (clay_add_sdf_layer(doc, "L", &layer) != CLAY_OK) { fail("add_sdf_layer"); return -1; }

    // A ball to sculpt on.
    float ball_r = 0.5f;
    clay_item *ball = clay_item_create(CLAY_PRIM_SPHERE, &ball_r, 1);
    clay_item_set_op(ball, CLAY_OP_ADD);
    clay_node_id n0 = 0;
    if (clay_layer_add_item(doc, layer, ball, &n0) != CLAY_OK) { fail("add ball"); return -1; }
    clay_item_destroy(ball);

    // ONE CLAY_PRIM_STROKE item carrying 16 points out of line — exactly what
    // the app's chain brushes build, and the only primitive so far whose
    // geometry does not live in the flat descriptor.
    float pos[3] = { 0.0f, ball_r, 0.0f };
    clay_item *stroke = clay_item_create(CLAY_PRIM_STROKE, NULL, 0);
    if (!stroke) { fail("create stroke"); return -1; }
    for (int k = -8; k < 8; ++k) {
        float sp[3] = { 0.015f * (float)k, ball_r, 0.0f };
        clay_item_add_stroke_point(stroke, sp, 0.06f);
    }
    clay_item_set_op(stroke, op);
    clay_item_set_blend(stroke, CLAY_BLEND_QUADRATIC, 0.02f);
    clay_item_set_rounding(stroke, 0.05f);
    clay_node_id n1 = 0;
    if (clay_layer_add_item(doc, layer, stroke, &n1) != CLAY_OK) { fail("add stroke"); return -1; }
    clay_item_destroy(stroke);

    // Sample the region around the lump, exactly as a host doing a regional
    // edit would.
    clay_volume_params vp;
    memset(&vp, 0, sizeof vp);
    vp.struct_size = (uint32_t)sizeof vp;
    vp.cell_size = 0.011f;
    float pad = 0.26f;
    float bmin[3] = { pos[0] - pad, pos[1] - pad, pos[2] - pad };
    float bmax[3] = { pos[0] + pad, pos[1] + pad, pos[2] + pad };
    vp.band = 2.0f * pad * 1.732f;
    clay_item *vol = NULL;
    if (clay_item_volume_from_document(doc, &vp, bmin, bmax, &vol) != CLAY_OK || !vol) {
        fail("volume_from_document"); return -1;
    }

    // THE SWAP, as ClaySpace performs it: hard-subtract a box slightly inside
    // the sampled region, then hard-add the sampled volume back. The identity
    // "(a - box) union v IS v inside the box" is what it relies on.
    //
    // Note what is NOT done: the original items stay in the document. For a
    // union op that is harmless — re-adding a volume that already contains
    // them changes nothing. A region op that DISPLACES the accumulated field
    // is a different matter, because it re-applies to whatever is beneath it
    // AFTER the swap, which is no longer what was sampled.
    float half = pad - vp.cell_size;
    float box_ext[3] = { half, half, half };
    clay_item *boxit = clay_item_create(CLAY_PRIM_BOX, box_ext, 3);
    clay_item_set_position(boxit, pos);
    clay_item_set_op(boxit, CLAY_OP_SUBTRACT);
    clay_item_set_blend(boxit, CLAY_BLEND_HARD, 0.0f);
    clay_node_id nbox = 0;
    if (clay_layer_add_item(doc, layer, boxit, &nbox) != CLAY_OK) { fail("add box"); return -1; }
    clay_item_destroy(boxit);

    clay_item *volcopy = NULL;
    if (clay_item_volume_from_document(doc, &vp, bmin, bmax, &volcopy) == CLAY_OK) {
        clay_item_destroy(volcopy); // only to keep the call shapes symmetric
    }
    clay_item_set_op(vol, CLAY_OP_ADD);
    clay_item_set_blend(vol, CLAY_BLEND_HARD, 0.0f);
    clay_node_id nvol = 0;
    if (clay_layer_add_item(doc, layer, vol, &nvol) != CLAY_OK) { fail("add vol to doc"); return -1; }

    // Put the sampled volume in a document of its own so its field can be
    // evaluated at the same points.
    clay_document *sampled = clay_document_create();
    clay_layer_id slayer = 0;
    clay_add_sdf_layer(sampled, "S", &slayer);
    clay_node_id n2 = 0;
    if (clay_layer_add_item(sampled, slayer, vol, &n2) != CLAY_OK) { fail("add volume"); return -1; }
    clay_item_destroy(vol);

    // Probe a line across the lump, just above the ball's surface.
    float pts[N * 3];
    for (int i = 0; i < N; ++i) {
        float t = -0.12f + 0.04f * (float)i;
        pts[i * 3 + 0] = t;
        pts[i * 3 + 1] = ball_r + 0.02f;
        pts[i * 3 + 2] = 0.0f;
    }
    float d_doc[N], d_vol[N];
    // `doc` now carries the swap, so this is the AFTER field.
    if (clay_eval_points(doc, NULL, pts, N, d_vol, NULL) != CLAY_OK) { fail("eval doc"); return -1; }
    // Rebuild the pristine document to get the BEFORE field.
    {
        clay_document *pristine = clay_document_create();
        clay_layer_id pl = 0;
        clay_add_sdf_layer(pristine, "P", &pl);
        clay_item *b2 = clay_item_create(CLAY_PRIM_SPHERE, &ball_r, 1);
        clay_item_set_op(b2, CLAY_OP_ADD);
        clay_node_id q0 = 0;
        clay_layer_add_item(pristine, pl, b2, &q0);
        clay_item_destroy(b2);
        clay_item *s2 = clay_item_create(CLAY_PRIM_STROKE, NULL, 0);
        for (int k = -8; k < 8; ++k) {
            float sp[3] = { 0.015f * (float)k, ball_r, 0.0f };
            clay_item_add_stroke_point(s2, sp, 0.06f);
        }
        clay_item_set_op(s2, op);
        clay_item_set_blend(s2, CLAY_BLEND_QUADRATIC, 0.02f);
        clay_item_set_rounding(s2, 0.05f);
        clay_node_id q1 = 0;
        clay_layer_add_item(pristine, pl, s2, &q1);
        clay_item_destroy(s2);
        if (clay_eval_points(pristine, NULL, pts, N, d_doc, NULL) != CLAY_OK) { fail("eval pristine"); return -1; }
        clay_document_destroy(pristine);
    }

    float worst = 0.0f;
    printf("  %-22s before:", label);
    for (int i = 0; i < N; ++i) printf(" %+.4f", d_doc[i]);
    printf("\n  %-22s after :", "");
    for (int i = 0; i < N; ++i) printf(" %+.4f", d_vol[i]);
    printf("\n");
    for (int i = 0; i < N; ++i) {
        float e = fabsf(d_doc[i] - d_vol[i]);
        if (e > worst) worst = e;
    }
    printf("  %-22s worst |before - after| = %.4f%s\n\n", "", worst,
           worst > 0.02f ? "   <-- THE SWAP CHANGED THE SURFACE" : "");

    clay_document_destroy(sampled);
    clay_document_destroy(doc);
    return worst;
}

int main(void) {
    printf("regional swap fidelity over a CLAY_PRIM_STROKE (16 pts), by op\n");
    int mj = 0, mn = 0, pt = 0;
    clay_version(&mj, &mn, &pt);
    printf("version: %d.%d.%d\n\n", mj, mn, pt);
    probe_op(CLAY_OP_ADD,      "CLAY_OP_ADD");
    probe_op(CLAY_OP_SUBTRACT, "CLAY_OP_SUBTRACT");
    probe_op(CLAY_OP_INCISE,   "CLAY_OP_INCISE");
    probe_op(CLAY_OP_RELIEF,   "CLAY_OP_RELIEF");
    return 0;
}
