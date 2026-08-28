#pragma once

#include "FreeRTOS.h"
#include <stdint.h>

typedef void* TaskHandle_t;
typedef void (*TaskFunction_t)(void*);

inline TickType_t acabHostTaskDelayTicks = 0;
inline uint32_t acabHostTaskSuspendCalls = 0;

inline void acabHostResetTaskSpies() {
    acabHostTaskDelayTicks = 0;
    acabHostTaskSuspendCalls = 0;
}

inline BaseType_t xTaskCreatePinnedToCore(TaskFunction_t, const char*, uint32_t, void*,
                                         UBaseType_t, TaskHandle_t* handle, BaseType_t) {
    if (handle) *handle = reinterpret_cast<TaskHandle_t>(1);
    return pdTRUE;
}

inline void vTaskDelay(TickType_t ticks) {
    acabHostTaskDelayTicks += ticks;
}

inline void vTaskSuspend(TaskHandle_t) {
    acabHostTaskSuspendCalls++;
}
