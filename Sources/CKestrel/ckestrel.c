#include "CKestrel.h"
#include <string.h>
#include <pthread.h>
#include <dlfcn.h>
#include <mach/mach.h>

pid_t k_responsible_pid(pid_t pid) {
    static pid_t (*fn)(pid_t) = NULL;
    static int resolved = 0;
    if (!resolved) {
        fn = (pid_t (*)(pid_t))dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        resolved = 1;
    }
    if (!fn) return pid;
    pid_t r = fn(pid);
    return r > 0 ? r : pid;
}

typedef struct { unsigned char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

static io_connect_t g_conn = 0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t str4(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) | ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}
static void tostr4(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0;
}
static kern_return_t smc_call(SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    return IOConnectCallStructMethod(g_conn, 2, in, sizeof(SMCParam), out, &outSize);
}

int ksmc_open(void) {
    pthread_mutex_lock(&g_lock);
    if (g_conn) { pthread_mutex_unlock(&g_lock); return 0; }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) { pthread_mutex_unlock(&g_lock); return -1; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) g_conn = 0;
    pthread_mutex_unlock(&g_lock);
    return kr == KERN_SUCCESS ? 0 : -1;
}

void ksmc_close(void) {
    pthread_mutex_lock(&g_lock);
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
    pthread_mutex_unlock(&g_lock);
}

static int key_info(uint32_t key, SMCKeyInfo *info) {
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key; in.data8 = 9;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *info = out.keyInfo;
    return 0;
}

int ksmc_read(const char *k, KSMCValue *v) {
    if (ksmc_open() != 0) return -1;
    pthread_mutex_lock(&g_lock);
    uint32_t key = str4(k);
    SMCKeyInfo info;
    if (key_info(key, &info) != 0) { pthread_mutex_unlock(&g_lock); return -1; }
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key; in.keyInfo.dataSize = info.dataSize; in.data8 = 5;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) { pthread_mutex_unlock(&g_lock); return -1; }
    memset(v, 0, sizeof *v);
    memcpy(v->key, k, 4);
    tostr4(info.dataType, v->type);
    v->size = info.dataSize > 32 ? 32 : info.dataSize;
    memcpy(v->bytes, out.bytes, v->size);
    pthread_mutex_unlock(&g_lock);
    return 0;
}

int ksmc_write(const char *k, const uint8_t *bytes, uint32_t size) {
    if (ksmc_open() != 0) return -1;
    pthread_mutex_lock(&g_lock);
    uint32_t key = str4(k);
    SMCKeyInfo info;
    if (key_info(key, &info) != 0) { pthread_mutex_unlock(&g_lock); return -1; }
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key; in.data8 = 6; in.keyInfo.dataSize = info.dataSize;
    uint32_t n = size < info.dataSize ? size : info.dataSize;
    if (n > 32) n = 32;
    memcpy(in.bytes, bytes, n);
    kern_return_t kr = smc_call(&in, &out);
    pthread_mutex_unlock(&g_lock);
    return (kr == KERN_SUCCESS && out.result == 0) ? 0 : -1;
}

int ksmc_key_count(uint32_t *count) {
    KSMCValue v;
    if (ksmc_read("#KEY", &v) != 0) return -1;
    *count = ((uint32_t)v.bytes[0] << 24) | ((uint32_t)v.bytes[1] << 16) | ((uint32_t)v.bytes[2] << 8) | v.bytes[3];
    return 0;
}

int ksmc_key_at(uint32_t index, char out4[5]) {
    if (ksmc_open() != 0) return -1;
    pthread_mutex_lock(&g_lock);
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.data8 = 8; in.data32 = index;
    kern_return_t kr = smc_call(&in, &out);
    pthread_mutex_unlock(&g_lock);
    if (kr != KERN_SUCCESS || out.result != 0) return -1;
    tostr4(out.key, out4);
    return 0;
}

double ksmc_decode(const KSMCValue *v, int *ok) {
    *ok = 1;
    const uint8_t *b = v->bytes;
    if (strncmp(v->type, "flt ", 4) == 0 && v->size >= 4) { float f; memcpy(&f, b, 4); return f; }
    if (strncmp(v->type, "ui8 ", 4) == 0) return b[0];
    if (strncmp(v->type, "si8 ", 4) == 0) return (int8_t)b[0];
    if (strncmp(v->type, "ui16", 4) == 0) return (double)(((uint16_t)b[0] << 8) | b[1]);
    if (strncmp(v->type, "si16", 4) == 0) return (double)(int16_t)(((uint16_t)b[0] << 8) | b[1]);
    if (strncmp(v->type, "ui32", 4) == 0) return (double)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]);
    if (strncmp(v->type, "sp78", 4) == 0) return (double)(int16_t)(((uint16_t)b[0] << 8) | b[1]) / 256.0;
    if (strncmp(v->type, "fpe2", 4) == 0) return (double)(((uint16_t)b[0] << 8) | b[1]) / 4.0;
    if (strncmp(v->type, "fp88", 4) == 0) return (double)(((uint16_t)b[0] << 8) | b[1]) / 256.0;
    if (strncmp(v->type, "ioft", 4) == 0 && v->size >= 8) { uint64_t x; memcpy(&x, b, 8); return (double)x / 65536.0; }
    *ok = 0;
    return 0;
}
