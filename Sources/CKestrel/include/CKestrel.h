#ifndef CKESTREL_H
#define CKESTREL_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <sys/types.h>

// ---- IOReport (private, exported by libIOReport) ----
typedef struct IOReportSubscription *IOReportSubscriptionRef;
CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
void IOReportMergeChannels(CFDictionaryRef a, CFDictionaryRef b, CFTypeRef nilArg);
IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef desired, CFMutableDictionaryRef *subbed, uint64_t channelID, CFTypeRef b);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef subbed, CFTypeRef a);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef a);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef ch);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef ch);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef ch);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef ch);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef ch, int32_t idx);
int32_t IOReportStateGetCount(CFDictionaryRef ch);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef ch, int32_t idx);
int64_t IOReportStateGetResidency(CFDictionaryRef ch, int32_t idx);

// ---- responsibility (resolved at runtime) ----
pid_t k_responsible_pid(pid_t pid);

// ---- SMC ----
typedef struct {
    char key[5];
    char type[5];
    uint32_t size;
    uint8_t bytes[32];
} KSMCValue;

int ksmc_open(void);
void ksmc_close(void);
int ksmc_read(const char *key, KSMCValue *out);
int ksmc_write(const char *key, const uint8_t *bytes, uint32_t size);
int ksmc_key_count(uint32_t *count);
int ksmc_key_at(uint32_t index, char out[5]);
double ksmc_decode(const KSMCValue *v, int *ok);

#endif
