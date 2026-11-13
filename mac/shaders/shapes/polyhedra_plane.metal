// An infinite plane of dodecahedra and icosahedra.
//
// See eval_common.metal for what a shape file can use.

EvalResult Eval(float3 ws) {
    EvalResult ret;
    ret.density = 0;                       // positive = solid, negative or zero = air
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    float  size = 0.2;
    float3 icosa_center = float3(0.25, -0.5, 0.25);
    float3 dodec_center = float3(-0.25, -0.5, -0.25);
    icosa_center.xz += floor(ws.xz) + 0.5;
    dodec_center.xz += floor(ws.xz) + 0.5;

    int i1 = 0;
    float closest_distance1 = 9999;
    float3 ws_dodec = (ws - dodec_center) / size;
    for (int i = 0; i < 12; i++) {
        float dist = length(dodec[i] - ws_dodec);
        if (dist < closest_distance1) {
            closest_distance1 = dist;
            i1 = i;
        }
    }

    int i2 = 0;
    float closest_distance2 = 9999;
    float3 ws_icosa = (ws - icosa_center) / size;
    for (int i = 0; i < 20; i++) {
        float dist = length(icosa[i] - ws_icosa);
        if (dist < closest_distance2 && i != i2) {
            closest_distance2 = dist;
            i2 = i;
        }
    }

    float proj1 = dot(dodec[i1], ws_dodec);
    float proj2 = dot(icosa[i2], ws_icosa);
    ret.density = (proj1 < 1 || proj2 < 1) ? 1 : -1;

    return ret;
}
