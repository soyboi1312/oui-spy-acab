#pragma once

#include "FreeRTOS.h"
#include <mutex>

struct StaticSemaphore_t {
    std::mutex mutex;
};

typedef StaticSemaphore_t* SemaphoreHandle_t;

inline SemaphoreHandle_t xSemaphoreCreateMutexStatic(StaticSemaphore_t* storage) {
    return storage;
}

inline BaseType_t xSemaphoreTake(SemaphoreHandle_t semaphore, TickType_t) {
    if (!semaphore) return pdFALSE;
    semaphore->mutex.lock();
    return pdTRUE;
}

inline BaseType_t xSemaphoreGive(SemaphoreHandle_t semaphore) {
    if (!semaphore) return pdFALSE;
    semaphore->mutex.unlock();
    return pdTRUE;
}
