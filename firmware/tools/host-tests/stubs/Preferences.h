#pragma once
// Arduino Preferences stub for the host tests.
//
// THIS USED TO DISCARD EVERY WRITE and return the caller's default from getBool, which meant the
// suite could not observe persistence at all: a toggle that never reached NVS and a toggle that
// round-tripped correctly produced byte-identical passing runs. That is exactly the property
// desert_detect.cpp and det_log.cpp now depend on (a deployed board must keep its mode across the
// brownout resets a week in the field guarantees), so the one thing worth testing was the one
// thing the harness was blind to.
//
// It now stores values in a process-local map keyed by namespace + key. Each host test is built
// and run as its OWN binary (see run.sh), so there is no cross-test leakage to worry about.
//
// THERE IS NO simulateReboot(), and there cannot be a useful one here. A reboot means dropping the
// detector's in-RAM flag while the store survives, but that flag is a file-static in
// <detector>_detect.cpp and nothing in this header can reach it. So the tests model a power cycle
// the other way round: seed the store directly, then call the module's own *_RestoreEnabled(),
// which is exactly what setup() does after a reset. See the persistence block at the end of
// test_desert.cpp for the pattern.
//
// wipeAll() is the separate case: factory reset, or a board that has never booted. It is what
// MAKES "nothing saved" true, and it has to be called explicitly - four test files were asserting
// the default branch by accident until this stub started storing anything.
#include <map>
#include <string>
#include <cstdint>
#include <vector>

struct Preferences {
    // ---- process-local backing store, shared by every Preferences instance ----
    static std::map<std::string, bool>& boolStore() {
        static std::map<std::string, bool> m; return m;
    }
    static std::map<std::string, uint32_t>& uintStore() {
        static std::map<std::string, uint32_t> m; return m;
    }
    static std::map<std::string, std::vector<uint8_t>>& blobStore() {
        static std::map<std::string, std::vector<uint8_t>> m; return m;
    }
    /// Wipe everything: models a factory reset or a board that has never booted.
    static void wipeAll() { boolStore().clear(); uintStore().clear(); blobStore().clear(); }

    std::string ns;
    std::string k(const char* key) const { return ns + "/" + (key ? key : ""); }

    // Return types MATCH the real arduino-esp32 API (bool begin, size_t put*), not void: ota_update.cpp
    // branches on them (`if (!p.begin(...))`, `p.putUChar(...) == sizeof(...)`), and a void-returning
    // stub made any host test that pulls it in fail to compile. Success is unconditional here; the
    // store is a map and cannot fail the way NVS can.
    bool begin(const char* name, bool = false) { ns = name ? name : ""; return true; }
    void end() {}

    bool getBool(const char* key, bool dflt) {
        auto it = boolStore().find(k(key));
        return it == boolStore().end() ? dflt : it->second;
    }
    size_t putBool(const char* key, bool v) { boolStore()[k(key)] = v; return sizeof(v); }

    uint32_t getUInt(const char* key, uint32_t dflt = 0) {
        auto it = uintStore().find(k(key));
        return it == uintStore().end() ? dflt : it->second;
    }
    size_t putUInt(const char* key, uint32_t v) { uintStore()[k(key)] = v; return sizeof(v); }

    uint8_t getUChar(const char* key, uint8_t dflt = 0) {
        auto it = uintStore().find(k(key));
        return it == uintStore().end() ? dflt : (uint8_t)it->second;
    }
    size_t putUChar(const char* key, uint8_t v) { uintStore()[k(key)] = v; return sizeof(v); }

    size_t getBytesLength(const char* key) {
        auto it = blobStore().find(k(key));
        return it == blobStore().end() ? 0 : it->second.size();
    }
    size_t getBytes(const char* key, void* out, size_t len) {
        auto it = blobStore().find(k(key));
        if (it == blobStore().end()) return 0;
        size_t n = it->second.size() < len ? it->second.size() : len;
        for (size_t i = 0; i < n; i++) ((uint8_t*)out)[i] = it->second[i];
        return n;
    }
    size_t putBytes(const char* key, const void* in, size_t len) {
        const uint8_t* p = (const uint8_t*)in;
        blobStore()[k(key)] = std::vector<uint8_t>(p, p + len);
        return len;
    }
    void remove(const char* key) {
        boolStore().erase(k(key)); uintStore().erase(k(key)); blobStore().erase(k(key));
    }
};
