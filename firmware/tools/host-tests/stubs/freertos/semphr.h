#pragma once

#include "FreeRTOS.h"
#include <functional>
#include <mutex>

struct StaticSemaphore_t {
    std::mutex mutex;
};

typedef StaticSemaphore_t* SemaphoreHandle_t;
inline unsigned acabHostSemaphoreTakeFailures = 0;
inline unsigned acabHostSemaphoreCreateFailures = 0;
inline std::function<void(SemaphoreHandle_t)> acabHostSemaphoreTakeObserver;

inline SemaphoreHandle_t xSemaphoreCreateMutexStatic(StaticSemaphore_t* storage) {
    if (acabHostSemaphoreCreateFailures != 0) {
        acabHostSemaphoreCreateFailures--;
        return nullptr;
    }
    return storage;
}

inline BaseType_t xSemaphoreTake(SemaphoreHandle_t semaphore, TickType_t) {
    if (!semaphore) return pdFALSE;
    if (acabHostSemaphoreTakeFailures != 0) {
        acabHostSemaphoreTakeFailures--;
        return pdFALSE;
    }
    if (acabHostSemaphoreTakeObserver) acabHostSemaphoreTakeObserver(semaphore);
    semaphore->mutex.lock();
    return pdTRUE;
}

inline BaseType_t xSemaphoreGive(SemaphoreHandle_t semaphore) {
    if (!semaphore) return pdFALSE;
    semaphore->mutex.unlock();
    return pdTRUE;
}
