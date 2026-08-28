#pragma once

#include "FreeRTOS.h"
#include <stddef.h>
#include <stdint.h>
#include <deque>
#include <vector>

// A REAL FIFO, not a black hole.
//
// THIS USED TO DISCARD EVERY PAYLOAD and answer xQueueReceive with pdFALSE forever, which made
// the whole QUEUED half of alerts.cpp unobservable on the host: alertsSignal(), alertsConnected(),
// alertsBeepTest() and alertsPowerOnAck() only enqueue, so they produced nothing a test could
// look at. Proven by mutation against the old stub: deleting the per-type ALERT_COALESCE_MS guard
// AND disabling the first-catch reveal both left test_alerts.cpp at 12/12 PASS. A coalesce window
// that never opens is an alert storm on a board somebody is carrying somewhere they need it quiet,
// which is the failure this product least wants to ship green.
//
// Same shape as the Preferences stub next door, and for the same reason: the harness has to be
// able to SEE the thing under test, or the suite reports on something else.
struct AcabHostQueue {
    size_t itemSize = 0;
    size_t capacity = 0;
    std::deque<std::vector<uint8_t>> items;
};
typedef AcabHostQueue* QueueHandle_t;

inline QueueHandle_t xQueueCreate(UBaseType_t length, UBaseType_t itemSize) {
    // One queue per call, at a STABLE address: std::deque never relocates the elements it already
    // holds, so a handle taken from an earlier alertsInit() stays valid after a later one.
    static std::deque<AcabHostQueue> pool;
    pool.emplace_back();
    pool.back().itemSize = (size_t)itemSize;
    pool.back().capacity = (size_t)length;
    return &pool.back();
}

inline BaseType_t xQueueSend(QueueHandle_t queue, const void* item, TickType_t) {
    if (!queue || !item || queue->itemSize == 0) return pdFALSE;
    // Full means DROPPED, never blocked. alerts.cpp passes a 0-tick timeout on purpose ("drop if
    // the queue is full, never block"), because the callers are the BLE/WiFi sink paths.
    if (queue->items.size() >= queue->capacity) return pdFALSE;
    const uint8_t* p = static_cast<const uint8_t*>(item);
    queue->items.emplace_back(p, p + queue->itemSize);
    return pdTRUE;
}

// pdFALSE on an empty queue models the TIMEOUT expiring, which is the branch alertTask uses for
// its idle LED heartbeat. Nothing here blocks: no host test drives a queue from more than one
// thread, and the caller owns the clock (see Arduino.h's settable millis()), so a real wait would
// just hang the suite with nothing left to advance it.
//
// "No host test drives a queue from more than one thread" is the precise claim, NOT that the
// suites are single-threaded: test_det_log.cpp spawns std::thread (run.sh gives that one suite
// -pthread). It touches no queue, and this deque carries no mutex, so a future threaded suite
// that DOES enqueue has to add one here first.
inline BaseType_t xQueueReceive(QueueHandle_t queue, void* out, TickType_t) {
    if (!queue || !out || queue->items.empty()) return pdFALSE;
    const std::vector<uint8_t>& front = queue->items.front();
    uint8_t* dst = static_cast<uint8_t*>(out);
    for (size_t i = 0; i < front.size(); i++) dst[i] = front[i];
    queue->items.pop_front();
    return pdTRUE;
}

// Test-side view. Use xQueueReceive to consume; this is for "and nothing else was queued".
inline size_t acabHostQueueDepth(QueueHandle_t queue) {
    return queue ? queue->items.size() : 0;
}
