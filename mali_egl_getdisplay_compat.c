/* SPDX-License-Identifier: MIT */

#define _GNU_SOURCE

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

typedef void *EGLDisplay;
typedef void *EGLNativeDisplayType;
typedef int32_t EGLenum;
typedef int32_t EGLint;
typedef void (*EGLProc)(void);

typedef EGLProc (*EglGetProcAddressFn)(const char *name);
typedef EGLDisplay (*EglGetDisplayFn)(EGLNativeDisplayType native_display);
typedef EGLDisplay (*EglGetPlatformDisplayExtFn)(
    EGLenum platform,
    void *native_display,
    const EGLint *attributes);

#define EGL_PLATFORM_GBM_KHR ((EGLenum)0x31D7)
#define EGL_NO_DISPLAY ((EGLDisplay)0)

EGLDisplay eglGetDisplay(EGLNativeDisplayType native_display)
{
    static EglGetDisplayFn real_get_display;
    static EglGetPlatformDisplayExtFn get_platform_display;
    static int resolved;
    static int logged;

    if (!resolved) {
        EglGetProcAddressFn get_proc_address;

        real_get_display =
            (EglGetDisplayFn)dlsym(RTLD_NEXT, "eglGetDisplay");
        get_proc_address =
            (EglGetProcAddressFn)dlsym(RTLD_NEXT, "eglGetProcAddress");
        if (get_proc_address) {
            get_platform_display = (EglGetPlatformDisplayExtFn)
                get_proc_address("eglGetPlatformDisplayEXT");
        }
        resolved = 1;
    }

    if (native_display && get_platform_display) {
        EGLDisplay display = get_platform_display(
            EGL_PLATFORM_GBM_KHR, native_display, NULL);
        if (display != EGL_NO_DISPLAY) {
            if (!logged) {
                logged = 1;
                fputs("mali-egl-compat: eglGetDisplay redirected to "
                      "eglGetPlatformDisplayEXT(GBM)\n",
                      stderr);
            }
            return display;
        }
    }

    return real_get_display ? real_get_display(native_display) : EGL_NO_DISPLAY;
}
