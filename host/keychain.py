"""Write Keychain secrets without putting them in argv.

`security add-generic-password -w <secret>` publishes the secret in the process
table for the life of the call — any process on the machine can `ps` it. That
matters here because the thing being written is a refreshed Claude OAuth token.

Reading is fine via security(1): `find-generic-password -w` returns the secret
on stdout, not on the command line. Only the write path needs this.

Uses the Security framework through ctypes (stdlib) rather than the deprecated
SecKeychain* C API. Stdlib only.
"""

from __future__ import annotations

import ctypes
import ctypes.util

_CF_PATH = ctypes.util.find_library("CoreFoundation")
_SEC_PATH = ctypes.util.find_library("Security")

ERR_SEC_SUCCESS = 0
ERR_SEC_ITEM_NOT_FOUND = -25300
_CF_STRING_ENCODING_UTF8 = 0x08000100


class KeychainError(OSError):
    """A Security.framework call returned a non-zero OSStatus."""


def _load():
    """Return (CoreFoundation, Security) with argtypes set, or raise."""
    if not _CF_PATH or not _SEC_PATH:
        raise KeychainError("CoreFoundation/Security not available")
    cf = ctypes.CDLL(_CF_PATH, use_errno=True)
    sec = ctypes.CDLL(_SEC_PATH, use_errno=True)

    cf.CFStringCreateWithBytes.restype = ctypes.c_void_p
    cf.CFStringCreateWithBytes.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long,
        ctypes.c_uint32, ctypes.c_bool,
    ]
    cf.CFDataCreate.restype = ctypes.c_void_p
    cf.CFDataCreate.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long,
    ]
    cf.CFDictionaryCreate.restype = ctypes.c_void_p
    cf.CFDictionaryCreate.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_void_p), ctypes.c_long,
        ctypes.c_void_p, ctypes.c_void_p,
    ]
    cf.CFRelease.restype = None
    cf.CFRelease.argtypes = [ctypes.c_void_p]

    sec.SecItemAdd.restype = ctypes.c_int32
    sec.SecItemAdd.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    sec.SecItemUpdate.restype = ctypes.c_int32
    sec.SecItemUpdate.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    return cf, sec


def _const(lib, name):
    """Read an exported CFStringRef global (kSecClass, kSecAttrService, …)."""
    return ctypes.c_void_p.in_dll(lib, name).value


def _cfstr(cf, value):
    raw = value.encode("utf-8")
    ref = cf.CFStringCreateWithBytes(
        None, raw, len(raw), _CF_STRING_ENCODING_UTF8, False)
    if not ref:
        raise KeychainError("could not encode keychain attribute")
    return ref


def _cfdata(cf, raw):
    ref = cf.CFDataCreate(None, raw, len(raw))
    if not ref:
        raise KeychainError("could not encode secret")
    return ref


def _cfdict(cf, pairs):
    count = len(pairs)
    keys = (ctypes.c_void_p * count)(*[k for k, _ in pairs])
    values = (ctypes.c_void_p * count)(*[v for _, v in pairs])
    ref = cf.CFDictionaryCreate(
        None, keys, values, count,
        _const(cf, "kCFTypeDictionaryKeyCallBacks"),
        _const(cf, "kCFTypeDictionaryValueCallBacks"),
    )
    if not ref:
        raise KeychainError("could not build query")
    return ref


def set_generic_password(service, account, secret):
    """Create or replace a generic password item. Raises KeychainError."""
    cf, sec = _load()
    owned = []

    def track(ref):
        owned.append(ref)
        return ref

    try:
        query = _cfdict(cf, [
            (_const(sec, "kSecClass"),
             _const(sec, "kSecClassGenericPassword")),
            (_const(sec, "kSecAttrService"), track(_cfstr(cf, service))),
            (_const(sec, "kSecAttrAccount"), track(_cfstr(cf, account))),
        ])
        owned.append(query)
        data = track(_cfdata(cf, secret.encode("utf-8")))
        changes = _cfdict(cf, [(_const(sec, "kSecValueData"), data)])
        owned.append(changes)

        status = sec.SecItemUpdate(query, changes)
        if status == ERR_SEC_ITEM_NOT_FOUND:
            attributes = _cfdict(cf, [
                (_const(sec, "kSecClass"),
                 _const(sec, "kSecClassGenericPassword")),
                (_const(sec, "kSecAttrService"), track(_cfstr(cf, service))),
                (_const(sec, "kSecAttrAccount"), track(_cfstr(cf, account))),
                (_const(sec, "kSecValueData"), data),
            ])
            owned.append(attributes)
            status = sec.SecItemAdd(attributes, None)
        if status != ERR_SEC_SUCCESS:
            raise KeychainError(f"Keychain write failed (OSStatus {status})")
    finally:
        for ref in owned:
            if ref:
                cf.CFRelease(ref)
