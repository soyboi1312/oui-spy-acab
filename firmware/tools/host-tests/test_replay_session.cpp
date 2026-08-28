/*
 * Deterministic regression for BLE replay-envelope invalidation.
 *
 * The production service runs the pure state below under a mutex. These tests force the precise
 * interleavings that used to depend on a sub-millisecond scheduling window: a new {sync} or
 * disconnect after a burst captured its state but before it queues begin/record/end, and after an
 * accepted record but before its BLE-layer count update. A stale operation may do nothing to the
 * replacement envelope; in particular it may neither queue data before begin nor offset end.n.
 */
#include "replay_session.h"

#include <cstdio>

static int failures = 0;

static void check(const char* what, bool pass) {
    std::printf("  %-72s %s\n", what, pass ? "PASS" : "FAIL");
    if (!pass) failures++;
}

int main() {
    std::printf("\n=== BLE replay transport/session race regression ===\n");

    AcabReplaySession s;
    const uint64_t a = s.start();
    check("a fresh session is active and begins with a clean envelope",
          a != 0 && s.active() && !s.beginSent() && !s.endPending() && s.sent() == 0);

    // New sync after the loop captured A, before A's begin reached the prequeue boundary.
    const uint64_t b = s.start();
    check("new sync changes the transport capability", b != a && b != 0);
    check("stale begin completion cannot mark the replacement envelope open",
          !s.noteBeginQueued(a) && !s.beginSent());
    check("replacement begin opens only its own envelope",
          s.mayQueueBegin(b) && s.noteBeginQueued(b) && s.beginSent());

    // New sync after A/B peeked a row, but before its final prequeue check.
    const uint64_t c = s.start();
    check("a replacement envelope never admits data before begin",
          !s.mayQueueRecord(c) && s.sent() == 0);
    check("a prequeue token from the prior session is rejected",
          !s.mayQueueRecord(b) && s.sent() == 0);
    check("current data becomes queueable only after current begin",
          s.noteBeginQueued(c) && s.mayQueueRecord(c));

    // The old bug also had a postcommit window: det_log commit(A) could finish, a new sync reset
    // gHistSent, and then A's `gHistSent++` landed in the new envelope. Force exactly that order.
    const uint64_t d = s.start();
    check("session D opens", s.noteBeginQueued(d));
    const uint64_t e = s.start();
    check("postcommit callback from D cannot increment E's count",
          !s.noteRecordCommitted(d) && s.sent() == 0);
    check("E still requires begin after rejecting D's completion",
          !s.mayQueueRecord(e) && !s.beginSent());
    check("E counts only its own committed record",
          s.noteBeginQueued(e) && s.noteRecordCommitted(e) && s.sent() == 1);

    // A stale no-more-records result used to set gHistEndPending in the replacement drain. That
    // emitted end before begin and, for a short burst, could prevent begin from ever being sent.
    const uint64_t f = s.start();
    check("session F opens", s.noteBeginQueued(f));
    const uint64_t g = s.start();
    check("stale completion cannot arm end on a replacement session",
          !s.noteEndPending(f) && !s.endPending());
    check("replacement cannot end before its own begin",
          !s.noteEndPending(g) && !s.mayQueueEnd(g));
    check("replacement closes begin -> record -> end in order",
          s.noteBeginQueued(g) && s.noteRecordCommitted(g) &&
          s.noteEndPending(g) && s.mayQueueEnd(g) && s.noteEndQueued(g) &&
          !s.active() && s.sent() == 1);

    const uint64_t g2 = s.start();
    check("stale-end setup reaches a pending close",
          s.noteBeginQueued(g2) && s.noteEndPending(g2) && s.mayQueueEnd(g2));
    const uint64_t g3 = s.start();
    check("accepted old end completion cannot close a newly-started envelope",
          s.noteBeginQueued(g3) && !s.noteEndQueued(g2) && s.active() && s.beginSent());

    // Disconnect is an invalidation, not a pause. Nothing captured by the old link may mutate the
    // next authenticated session, even when a connection handle is quickly reused.
    const uint64_t h = s.start();
    check("session H opens", s.noteBeginQueued(h));
    s.invalidate();
    check("disconnect closes and clears the complete transport envelope",
          !s.active() && !s.beginSent() && !s.endPending() && s.sent() == 0);
    check("all stale H boundaries reject after disconnect",
          !s.mayQueueBegin(h) && !s.mayQueueRecord(h) &&
          !s.noteRecordCommitted(h) && !s.noteEndPending(h));
    const uint64_t i = s.start();
    check("new link starts with a capability distinct from the disconnected link",
          i != h && !s.beginSent() && s.sent() == 0);

    // clearlog, a key install/rotation, and buffer disable all use this same invalidation before
    // touching det_log. Model an active, partially-sent envelope and prove no tail callback can
    // resurrect it after the destructive/key-lifecycle boundary.
    check("destructive-reset setup opens I", s.noteBeginQueued(i));
    check("destructive-reset setup counts one committed row",
          s.noteRecordCommitted(i) && s.sent() == 1);
    s.invalidate();
    check("clear/key/disable invalidation discards partial count and envelope flags",
          !s.active() && s.sent() == 0 && !s.beginSent() && !s.endPending());
    check("partial pre-clear burst cannot publish a late end or count update",
          !s.noteRecordCommitted(i) && !s.noteEndPending(i) && !s.mayQueueEnd(i));
    const uint64_t j = s.start();
    check("post-clear sync must establish a new begin before data",
          j != i && !s.mayQueueRecord(j) && s.noteBeginQueued(j) && s.mayQueueRecord(j));

    std::printf("\n%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
