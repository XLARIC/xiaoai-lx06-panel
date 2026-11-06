#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Firmware-specific, ordinary C ABI calls to exported JsonCpp member methods.
 * Json::Value is 24 bytes in the inspected ARM firmware. A larger aligned
 * buffer is used; no object fields or firmware memory offsets are modified.
 * Its assignment operator takes a nontrivial value indirectly and swaps it.
 */
typedef union { max_align_t align; unsigned char bytes[256]; } json_storage;
struct location { double latitude, longitude; char time_zone[128]; };
struct json_api {
    void *(*index)(void *, const char *);
    void (*type_ctor)(void *, int);
    void (*double_ctor)(void *, double);
    void (*string_ctor)(void *, const char *);
    void *(*assign)(void *, void *);
    void (*destroy)(void *);
    double (*as_double)(const void *);
    const char *(*as_string)(const void *);
    int (*is_object)(const void *);
};

static int json_api_load(struct json_api *api) {
#define RESOLVE(field, name) *(void **)(&api->field) = dlsym(RTLD_DEFAULT, name)
    RESOLVE(index, "_ZN4Json5ValueixEPKc");
    RESOLVE(type_ctor, "_ZN4Json5ValueC1ENS_9ValueTypeE");
    RESOLVE(double_ctor, "_ZN4Json5ValueC1Ed");
    RESOLVE(string_ctor, "_ZN4Json5ValueC1EPKc");
    RESOLVE(assign, "_ZN4Json5ValueaSES0_");
    RESOLVE(destroy, "_ZN4Json5ValueD1Ev");
    RESOLVE(as_double, "_ZNK4Json5Value8asDoubleEv");
    RESOLVE(as_string, "_ZNK4Json5Value9asCStringEv");
    RESOLVE(is_object, "_ZNK4Json5Value8isObjectEv");
#undef RESOLVE
    return api->index && api->type_ctor && api->double_ctor && api->string_ctor &&
           api->assign && api->destroy && api->as_double && api->as_string && api->is_object;
}

static int zone_valid(const char *zone) {
    if (!*zone || zone[0] == '/' || strstr(zone, "..")) return 0;
    for (const unsigned char *p = (const unsigned char *)zone; *p; ++p)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || strchr("/_+-", *p))) return 0;
    return 1;
}

static int parse_number(const char *value, double *out, double low, double high) {
    char *end = NULL;
    errno = 0;
    *out = strtod(value, &end);
    return !errno && end != value && !*end && isfinite(*out) && *out >= low && *out <= high;
}

static int location_load(struct location *location) {
    const char *path = getenv("XIAOAI_LOCATION_CONFIG");
    if (!path || !*path) path = "/data/location/location.conf";
    FILE *file = fopen(path, "r");
    if (!file) return 0;
    char line[256];
    unsigned valid = 0;
    memset(location, 0, sizeof(*location));
    while (fgets(line, sizeof(line), file)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!strncmp(line, "latitude=", 9)) {
            if (!parse_number(line + 9, &location->latitude, -90, 90)) { valid = 0; break; }
            valid |= 1;
        } else if (!strncmp(line, "longitude=", 10)) {
            if (!parse_number(line + 10, &location->longitude, -180, 180)) { valid = 0; break; }
            valid |= 2;
        } else if (!strncmp(line, "time_zone=", 10)) {
            if (strlen(line + 10) >= sizeof(location->time_zone) || !zone_valid(line + 10)) {
                valid = 0; break;
            }
            strcpy(location->time_zone, line + 10);
            valid |= 4;
        }
    }
    fclose(file);
    return valid == 7;
}

static void set_double(const struct json_api *api, void *object, const char *key, double value) {
    json_storage temporary;
    api->double_ctor(&temporary, value);
    api->assign(api->index(object, key), &temporary);
    api->destroy(&temporary);
}

static void set_string(const struct json_api *api, void *object, const char *key, const char *value) {
    json_storage temporary;
    api->string_ctor(&temporary, value);
    api->assign(api->index(object, key), &temporary);
    api->destroy(&temporary);
}

static void apply_location(const struct json_api *api, void *object, const struct location *location) {
    set_double(api, object, "latitude", location->latitude);
    set_double(api, object, "longitude", location->longitude);
    set_string(api, object, "time_zone", location->time_zone);
}

static void record_applied(const char *phase) {
    FILE *file = fopen("/tmp/native-location.applied", "w");
    if (file) { fprintf(file, "%s\n", phase); fclose(file); }
}

int client_info_to_json(const void *self, void *out)
    __asm__("_ZNK4aivs8Settings10ClientInfo6toJsonERN4Json5ValueE");
int client_info_to_json(const void *self, void *out) {
    int (*original)(const void *, void *) = dlsym(RTLD_NEXT,
        "_ZNK4aivs8Settings10ClientInfo6toJsonERN4Json5ValueE");
    if (!original) return 0;
    int result = original(self, out);
    struct location location;
    struct json_api api;
    if (result && location_load(&location) && json_api_load(&api) && api.is_object(out)) {
        apply_location(&api, out, &location);
        record_applied("ClientInfo");
    }
    return result;
}

int global_config_to_json(const void *self, void *out)
    __asm__("_ZNK4aivs8Settings12GlobalConfig6toJsonERN4Json5ValueE");
int global_config_to_json(const void *self, void *out) {
    int (*original)(const void *, void *) = dlsym(RTLD_NEXT,
        "_ZNK4aivs8Settings12GlobalConfig6toJsonERN4Json5ValueE");
    if (!original) return 0;
    int result = original(self, out);
    struct location location;
    struct json_api api;
    if (result && location_load(&location) && json_api_load(&api) && api.is_object(out)) {
        apply_location(&api, api.index(out, "client_info"), &location);
        record_applied("GlobalConfig");
    }
    return result;
}

#ifdef LOCATION_PROBE
int main(void) {
    void *sdk = dlopen("libaivs_sdk.so", RTLD_NOW | RTLD_GLOBAL);
    if (!sdk) { fprintf(stderr, "SDK load: %s\n", dlerror()); return 1; }
    struct json_api api;
    struct location location;
    if (!json_api_load(&api) || !location_load(&location)) {
        fprintf(stderr, "Required ABI or valid location config unavailable\n"); return 2;
    }
    for (int i = 0; i < 1000; ++i) {
        json_storage object;
        api.type_ctor(&object, 7);
        set_string(&api, &object, "unchanged", "preserved");
        apply_location(&api, &object, &location);
        apply_location(&api, &object, &location);
        if (api.as_double(api.index(&object, "latitude")) != location.latitude ||
            api.as_double(api.index(&object, "longitude")) != location.longitude ||
            strcmp(api.as_string(api.index(&object, "time_zone")), location.time_zone) ||
            strcmp(api.as_string(api.index(&object, "unchanged")), "preserved")) return 3;
        api.destroy(&object);
    }
    puts("1000 JsonCpp construction/assignment/destruction checks passed; unrelated field preserved");
    dlclose(sdk);
    return 0;
}
#endif
