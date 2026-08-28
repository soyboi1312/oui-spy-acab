#include "link_action_lease.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <thread>

static int failures = 0;
static void check(const char* name, bool pass) {
    std::printf("  %-76s %s\n", name, pass ? "PASS" : "FAIL");
    if (!pass) failures++;
}

struct BlockingAction {
    std::mutex mutex;
    std::condition_variable cv;
    bool entered = false;
    bool release = false;
    std::atomic<int> calls{0};
};

static bool allow(void*) { return true; }
static bool deny(void*) { return false; }
static void countAction(void* raw) {
    static_cast<std::atomic<int>*>(raw)->fetch_add(1);
}
static void blockAction(void* raw) {
    auto* state = static_cast<BlockingAction*>(raw);
    state->calls.fetch_add(1);
    std::unique_lock<std::mutex> lock(state->mutex);
    state->entered = true;
    state->cv.notify_all();
    state->cv.wait(lock, [&] { return state->release; });
}

int main() {
    std::printf("\n=== deferred link-action lease ===\n");

    AcabLinkActionLease lease;
    check("static lease initializes", lease.initialize());
    check("current-link DFU request arms", lease.arm(AcabLinkActionSlot::nrfDfu));

    BlockingAction blocked;
    std::atomic<bool> boundaryFinished{false};
    std::atomic<unsigned> boundaryTakeAttempts{0};
    std::thread actionThread([&] {
        lease.run(AcabLinkActionSlot::nrfDfu, allow, blockAction, &blocked);
    });
    bool actionEntered = false;
    {
        std::unique_lock<std::mutex> lock(blocked.mutex);
        actionEntered = blocked.cv.wait_for(
            lock, std::chrono::seconds(2), [&] { return blocked.entered; });
    }
    check("authorized action reaches its callback within the host-test deadline", actionEntered);

    // Install the observer only after the action owns the lease. It fires immediately before the
    // boundary's mutex.lock(), giving the test a deterministic proof that advance has attempted
    // the exact interleaving rather than relying on a sleep/scheduler guess. Both waits are bounded
    // so a broken callback/mutex fails CI instead of hanging the suite indefinitely.
    std::mutex attemptMutex;
    std::condition_variable attemptCv;
    bool boundaryAttempted = false;
    std::thread boundaryThread;
    if (actionEntered) {
        acabHostSemaphoreTakeObserver = [&](SemaphoreHandle_t) {
            boundaryTakeAttempts.fetch_add(1);
            attemptCv.notify_all();
        };
        boundaryThread = std::thread([&] {
            lease.advance();
            boundaryFinished.store(true);
        });
        std::unique_lock<std::mutex> lock(attemptMutex);
        boundaryAttempted = attemptCv.wait_for(lock, std::chrono::seconds(2), [&] {
            return boundaryTakeAttempts.load() != 0;
        });
    }
    check("disconnect boundary reaches the occupied lease within the test deadline",
          boundaryAttempted);
    check("disconnect boundary cannot publish while authorized action callback owns lease",
          boundaryAttempted && !boundaryFinished.load() && blocked.calls.load() == 1);
    {
        std::lock_guard<std::mutex> lock(blocked.mutex);
        blocked.release = true;
    }
    blocked.cv.notify_all();
    actionThread.join();
    if (boundaryThread.joinable()) boundaryThread.join();
    acabHostSemaphoreTakeObserver = nullptr;
    check("boundary completes after physical action releases its lease", boundaryFinished.load());

    std::atomic<int> calls{0};
    check("request stamped before a completed boundary is rejected afterward",
          lease.arm(AcabLinkActionSlot::powerOff) && lease.advance() &&
          lease.run(AcabLinkActionSlot::powerOff, allow, countAction, &calls) ==
              AcabLinkActionResult::none && calls.load() == 0);
    check("current token still executes one callback exactly once",
          lease.arm(AcabLinkActionSlot::powerOff) &&
          lease.run(AcabLinkActionSlot::powerOff, allow, countAction, &calls) ==
              AcabLinkActionResult::executed && calls.load() == 1 &&
          lease.run(AcabLinkActionSlot::powerOff, allow, countAction, &calls) ==
              AcabLinkActionResult::none);
    check("policy denial consumes request without invoking physical action",
          lease.arm(AcabLinkActionSlot::nrfDfu) &&
          lease.run(AcabLinkActionSlot::nrfDfu, deny, countAction, &calls) ==
              AcabLinkActionResult::rejected && calls.load() == 1);

    AcabLinkActionLease unavailable;
    acabHostSemaphoreCreateFailures = 1;
    check("static-mutex creation failure is fail-closed",
          !unavailable.initialize() &&
          !unavailable.arm(AcabLinkActionSlot::powerOff) &&
          unavailable.run(AcabLinkActionSlot::powerOff, allow, countAction, &calls) ==
              AcabLinkActionResult::unavailable && calls.load() == 1);

    std::printf("\n%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
