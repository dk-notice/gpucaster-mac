// Fractal perturbations on the surface of a dodecahedron.  Slow, but spectacular.
//
// param: zoom = 3.0 (1.0 to 6.0)
// param: iterations = 10 (1 to 14)
// param: twist = 0.3 (0.0 to 1.0)
// param: scale = 2.3 (1.5 to 3.0)
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    ws *= zoom;
    int iters = int(iterations);
    for (int loop = 0; loop < iters; loop++) {
        // To which face center on the dodecahedron are we closest?
        int i1 = 0;
        float closest_distance1 = 9999;
        for (int i = 0; i < 12; i++) {
            float dist = length(dodec[i] - ws);
            if (dist < closest_distance1) {
                closest_distance1 = dist;
                i1 = i;
            }
        }
        float3 nearest_dodec_face_center = dodec[i1];

        // To which vertex on the dodecahedron (or face center on the icosahedron) are we closest?
        int i2 = 0;
        float closest_distance2 = 9999;
        for (int i = 0; i < 20; i++) {
            float dist = length(icosa[i] - ws);
            if (dist < closest_distance2 && i != i2) {
                closest_distance2 = dist;
                i2 = i;
            }
        }
        float3 nearest_dodec_vertex = icosa[i2];

        float proj1 = dot(dodec[i1], ws);
        if (proj1 < 1 && loop == iters - 1) {
            ret.density = 1;
        }

        float3 pivot = nearest_dodec_face_center;
        float3 axis0 = normalize(nearest_dodec_face_center);
        float3 axis1 = normalize(nearest_dodec_face_center - nearest_dodec_vertex);
        float3 axis2 = cross(axis0, axis1);
        ws = RotatePointAboutAxis(axis2, pivot, ws, seed_snorm[0].y * 0.5);

        float st = length(ws - axis0 * dot(ws, axis0)) * twist;
        ws = RotatePointAboutAxis(axis0, nearest_dodec_face_center, ws, st);

        ws = (ws - nearest_dodec_vertex) * scale + nearest_dodec_vertex;

        // Avoid +INF's causing issues at high # of iters.
        if (length(ws) > 10) {
            ws = normalize(ws) * 10;
        }
    }

    ret.density = (length(ws) < 1.0) ? 1 : -1;

    return ret;
}
