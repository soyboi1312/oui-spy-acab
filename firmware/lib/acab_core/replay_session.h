#pragma once

#include <stdint.h>

// BLE-layer replay envelope state.
//
// det_log's drainGeneration protects the flash cursor, but it cannot protect the transport
// bookkeeping that lives above it: begin/end and the number accepted by NimBLE. A new {sync} or a
// disconnect must invalidate all work a loop-task burst captured from the prior session, including
// a completion that resumes after the invalidation. Every mutator therefore presents the token it
// captured before doing work and becomes a no-op when that token is stale.
//
// This type is deliberately unaware of FreeRTOS. The BLE service serializes every call with its
// replay mutex, and holds that mutex across the final token check, notify queue operation, det_log
// commit, and matching state update. Keeping the state machine pure makes the invalidation races
// deterministic in the host suite instead of trying to reproduce a scheduler-sized window.
class AcabReplaySession {
public:
    uint64_t start() {
        advanceGeneration();
        active_ = true;
        beginSent_ = false;
        endPending_ = false;
        sent_ = 0;
        return generation_;
    }

    void invalidate() {
        advanceGeneration();
        active_ = false;
        beginSent_ = false;
        endPending_ = false;
        sent_ = 0;
    }

    uint64_t token() const { return generation_; }
    uint32_t sent() const { return sent_; }
    bool active() const { return active_; }
    bool beginSent() const { return beginSent_; }
    bool endPending() const { return endPending_; }

    bool mayQueueBegin(uint64_t token) const {
        return matches(token) && !beginSent_ && !endPending_;
    }

    bool noteBeginQueued(uint64_t token) {
        if (!mayQueueBegin(token)) return false;
        beginSent_ = true;
        return true;
    }

    bool mayQueueRecord(uint64_t token) const {
        return matches(token) && beginSent_ && !endPending_;
    }

    bool noteRecordCommitted(uint64_t token) {
        if (!mayQueueRecord(token)) return false;
        sent_++;
        return true;
    }

    bool noteEndPending(uint64_t token) {
        if (!matches(token) || !beginSent_ || endPending_) return false;
        endPending_ = true;
        return true;
    }

    bool mayQueueEnd(uint64_t token) const {
        return matches(token) && beginSent_ && endPending_;
    }

    bool noteEndQueued(uint64_t token) {
        if (!mayQueueEnd(token)) return false;
        endPending_ = false;
        active_ = false;
        return true;
    }

private:
    bool matches(uint64_t token) const {
        return active_ && token != 0 && token == generation_;
    }

    void advanceGeneration() {
        generation_++;
        if (generation_ == 0) generation_ = 1; // zero is never an issued capability
    }

    uint64_t generation_ = 0;
    uint32_t sent_ = 0;
    bool active_ = false;
    bool beginSent_ = false;
    bool endPending_ = false;
};
