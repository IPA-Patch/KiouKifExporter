#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>

// ===========================================================================
// kiou_il2cpp.h — read-only il2cpp object helpers shared across KIOU tweaks.
//
// Every tweak that pokes at il2cpp objects (KiouEditor, KiouUSIProxy, ...)
// needs the same pointer-validation + struct-field readers. Sharing them as
// `static inline` keeps the call sites in each translation unit inlined and
// avoids any linker plumbing — each .m that imports this header gets its own
// private copy.
//
// Object layout assumptions (verified against KIOU 1.0.1 build 11):
//
//   RepeatedField<T> : +0x10 array ptr, +0x18 count
//   il2cpp array     : element[0] at arrayPtr + 0x20, refs 8-byte spaced
//   il2cpp string    : +0x10 length (UTF-16 code units), +0x14 char[]
//
// DELIBERATELY READ-ONLY: writeU8 / writeI32 live in each tweak's own
// Internal.h, not here. This makes it physically impossible for an
// observation-only tweak (KiouUSIProxy) to accidentally mutate il2cpp memory
// just by including the shared header — if you need to write, opt in
// explicitly per-tweak.
// ===========================================================================

static inline BOOL ptrLooksValid(const void *p) {
    uintptr_t v = (uintptr_t)p;
    if (v == 0) return NO;
    if (v < 0x1000) return NO;
    if (v >= 0x0001000000000000ULL) return NO;
    return YES;
}

static inline int32_t readI32(const void *base, uintptr_t off) {
    if (!ptrLooksValid(base)) return 0;
    return *(const int32_t *)((const uint8_t *)base + off);
}

static inline uint8_t readU8(const void *base, uintptr_t off) {
    if (!ptrLooksValid(base)) return 0;
    return *(const uint8_t *)((const uint8_t *)base + off);
}

static inline void *readPtr(const void *base, uintptr_t off) {
    if (!ptrLooksValid(base)) return NULL;
    void *p = *(void *const *)((const uint8_t *)base + off);
    return ptrLooksValid(p) ? p : NULL;
}

static inline BOOL readRepeatedField(const void *obj, uintptr_t fieldOff,
                                     void **outArrayPtr, int32_t *outCount) {
    *outArrayPtr = NULL;
    *outCount = 0;
    void *rf = readPtr(obj, fieldOff);
    if (!rf) return NO;
    void *arr = readPtr(rf, 0x10);
    int32_t count = readI32(rf, 0x18);
    if (count < 0 || count > 100000) return NO;
    if (count > 0 && !arr) return NO;
    *outArrayPtr = arr;
    *outCount = count;
    return YES;
}

static inline void *readArrayElem(const void *arrayPtr, int32_t index) {
    if (!ptrLooksValid(arrayPtr)) return NULL;
    if (index < 0) return NULL;
    return readPtr(arrayPtr, 0x20 + (uintptr_t)index * 8);
}

static inline NSString *il2cppStringToNSString(const void *s) {
    if (!ptrLooksValid(s)) return nil;
    int32_t len = *(const int32_t *)((const uint8_t *)s + 0x10);
    if (len < 0 || len > 0x10000) return nil;
    const unichar *chars = (const unichar *)((const uint8_t *)s + 0x14);
    return [NSString stringWithCharacters:chars length:(NSUInteger)len];
}
