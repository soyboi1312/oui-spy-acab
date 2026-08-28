#pragma once

// Link-owned deferred actions run on the board loop task, while connect/disconnect boundaries run
// on NimBLE's host task. A token comparison followed by a returned bool is not enough: the host
// can advance to phone B after the comparison and before loop() performs phone A's physical action.
// This small lease holds one mutex across check + callback, and the boundary advances its token
// under the same mutex. It is header-only so the exact concurrency primitive is host-testable.

#include <atomic>
#include <stdint.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

enum class AcabLinkActionSlot : uint8_t {
    nrfDfu,
    powerOff,
};

enum class AcabLinkActionResult : uint8_t {
    none,
    rejected,
    executed,
    unavailable,
};

class AcabLinkActionLease {
public:
    using Predicate = bool (*)(void*);
    using Action = void (*)(void*);

    // Call once during BLE initialization, before a Config callback can arm an action. Static
    // allocation avoids heap exhaustion turning session serialization into a best-effort feature.
    // A null return is still handled fail-closed by every method below.
    bool initialize() {
        if (!mutex_) mutex_ = xSemaphoreCreateMutexStatic(&mutexStorage_);
        const bool ready = mutex_ != nullptr;
        valid_.store(ready, std::memory_order_release);
        return ready;
    }

    // Stamp a request with the current nonzero physical-link token. The host callback uses this
    // rather than storing the token itself, so creation/lock failure cannot publish an executable
    // request. A boundary and an arm cannot pass one another inside the lease.
    bool arm(AcabLinkActionSlot slot) {
        if (!lock()) {
            request(slot).store(0, std::memory_order_release);
            return false;
        }
        const uint32_t token = token_.load(std::memory_order_acquire);
        const bool armed = valid_.load(std::memory_order_acquire) && token != 0;
        request(slot).store(armed ? token : 0, std::memory_order_release);
        unlock();
        return armed;
    }

    // Consume and, if still authorized for this exact link, execute a request WITHOUT releasing
    // the lease between the final check and the action. `predicate` is also evaluated under the
    // lease (DFU rechecks secure-link + physical-window policy there). The callback must not call
    // advance() recursively. A power-off callback intentionally never returns; the board enters
    // deep sleep, so there is no later owner boundary to unblock.
    AcabLinkActionResult run(AcabLinkActionSlot slot,
                             Predicate predicate,
                             Action action,
                             void* context) {
        if (!action || !lock()) {
            request(slot).store(0, std::memory_order_release);
            return AcabLinkActionResult::unavailable;
        }
        const uint32_t requested = request(slot).exchange(0, std::memory_order_acq_rel);
        if (requested == 0) {
            unlock();
            return AcabLinkActionResult::none;
        }
        const bool authorized = valid_.load(std::memory_order_acquire) &&
                                requested == token_.load(std::memory_order_acquire) &&
                                (!predicate || predicate(context));
        if (!authorized) {
            unlock();
            return AcabLinkActionResult::rejected;
        }
        action(context);
        unlock();
        return AcabLinkActionResult::executed;
    }

    // Invalidate both latches and publish the next link token as one leased boundary. A loop action
    // that already passed authorization completes before this returns; one that has not cannot pass
    // until it observes the new token. If static mutex creation somehow failed, actions cannot run;
    // still clear/advance the atomics so recovery never mistakes an old request for a new one.
    bool advance() {
        if (!lock()) {
            valid_.store(false, std::memory_order_release);
            clearRequests();
            bumpToken();
            return false;
        }
        valid_.store(false, std::memory_order_release);
        clearRequests();
        bumpToken();
        valid_.store(true, std::memory_order_release);
        unlock();
        return true;
    }

private:
    std::atomic<uint32_t>& request(AcabLinkActionSlot slot) {
        return slot == AcabLinkActionSlot::nrfDfu ? nrfDfuRequest_ : powerOffRequest_;
    }

    bool lock() {
        if (!mutex_ || xSemaphoreTake(mutex_, portMAX_DELAY) != pdTRUE) {
            valid_.store(false, std::memory_order_release);
            return false;
        }
        return true;
    }

    void unlock() { xSemaphoreGive(mutex_); }

    void clearRequests() {
        nrfDfuRequest_.store(0, std::memory_order_release);
        powerOffRequest_.store(0, std::memory_order_release);
    }

    void bumpToken() {
        const uint32_t next = token_.fetch_add(1, std::memory_order_acq_rel) + 1;
        if (next == 0) token_.store(1, std::memory_order_release);
    }

    StaticSemaphore_t mutexStorage_{};
    SemaphoreHandle_t mutex_ = nullptr;
    std::atomic<bool> valid_{false};
    std::atomic<uint32_t> token_{1};
    std::atomic<uint32_t> nrfDfuRequest_{0};
    std::atomic<uint32_t> powerOffRequest_{0};
};
