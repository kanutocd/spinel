/* sp_ractor.c -- minimal pthread-backed Ractor runtime. See sp_ractor.h.
 * sp_raise_cls / sp_fiber_thread_init / sp_gc_thread_teardown live elsewhere
 * (the generated TU and the other libspinel_rt units) and are reached by
 * name, the same way sp_fiber.c reaches sp_gc_alloc. */
#include "sp_ractor.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* ---- Reached by name ---- */
void sp_raise_cls(const char *cls, const char *msg);
void sp_fiber_thread_init(void);
void sp_gc_thread_teardown(void);

/* A blocking single-ended FIFO of boxed values guarded by a mutex+condvar.
   Each Ractor has two: `inbox` (messages sent to it; drained by
   Ractor.receive) and `outbox` (values it yields; drained by r.take). */
typedef struct {
  pthread_mutex_t mtx;
  pthread_cond_t  cv;
  sp_RbVal       *buf;
  int             head, tail, len, cap;
  int             closed;
} sp_RactorQueue;

struct sp_Ractor {
  pthread_t       thread;
  void          (*body)(sp_Ractor *);
  sp_RactorQueue  inbox;
  sp_RactorQueue  outbox;
};

__thread sp_Ractor *sp_ractor_current = NULL;

static void sp_rq_init(sp_RactorQueue *q) {
  pthread_mutex_init(&q->mtx, NULL);
  pthread_cond_init(&q->cv, NULL);
  q->cap = 8;
  q->buf = (sp_RbVal *)malloc(sizeof(sp_RbVal) * q->cap);
  q->head = q->tail = q->len = 0;
  q->closed = 0;
}

static void sp_rq_destroy(sp_RactorQueue *q) {
  free(q->buf); q->buf = NULL;
  pthread_mutex_destroy(&q->mtx);
  pthread_cond_destroy(&q->cv);
}

static void sp_rq_push(sp_RactorQueue *q, sp_RbVal v) {
  pthread_mutex_lock(&q->mtx);
  if (q->len == q->cap) {
    int ncap = q->cap * 2;
    sp_RbVal *nb = (sp_RbVal *)malloc(sizeof(sp_RbVal) * ncap);
    for (int i = 0; i < q->len; i++) nb[i] = q->buf[(q->head + i) % q->cap];
    free(q->buf); q->buf = nb; q->cap = ncap; q->head = 0; q->tail = q->len;
  }
  q->buf[q->tail] = v;
  q->tail = (q->tail + 1) % q->cap;
  q->len++;
  pthread_cond_signal(&q->cv);
  pthread_mutex_unlock(&q->mtx);
}

/* Block until a value is available. Returns 1 with *out set, or 0 if the
   queue was closed and drained (no more values will ever arrive). */
static int sp_rq_pop(sp_RactorQueue *q, sp_RbVal *out) {
  pthread_mutex_lock(&q->mtx);
  while (q->len == 0 && !q->closed) pthread_cond_wait(&q->cv, &q->mtx);
  if (q->len == 0) { pthread_mutex_unlock(&q->mtx); return 0; }
  *out = q->buf[q->head];
  q->head = (q->head + 1) % q->cap;
  q->len--;
  pthread_mutex_unlock(&q->mtx);
  return 1;
}

static void sp_rq_close(sp_RactorQueue *q) {
  pthread_mutex_lock(&q->mtx);
  q->closed = 1;
  pthread_cond_broadcast(&q->cv);
  pthread_mutex_unlock(&q->mtx);
}

/* Milestone-1 boundary codec: only immediate (heap-free) values are
   shareable, so a deep copy is a plain struct copy and the value is safe to
   sit in a queue across the heap boundary. Heap-backed values (String tag,
   object/array/hash via OBJ, Symbol whose id is a per-thread table index)
   need the serialize/re-intern codec of a later milestone -- reject them now
   with a clear error rather than smuggling a dangling cross-heap pointer. */
static int sp_ractor_shareable(sp_RbVal v) {
  return v.tag == SP_TAG_INT || v.tag == SP_TAG_FLT ||
         v.tag == SP_TAG_BOOL || v.tag == SP_TAG_NIL;
}
static sp_RbVal sp_ractor_copy(sp_RbVal v) {
  if (!sp_ractor_shareable(v))
    sp_raise_cls("Ractor::Error",
                 "Milestone-1 Ractor can only pass immediate values "
                 "(Integer/Float/true/false/nil) across the boundary");
  return v; /* immediate: no heap reference to copy */
}

/* Entry trampoline for a Ractor pthread: establish this thread's Ractor and
   fiber identity, run the body, then close the outbox (so a waiting r.take
   unblocks) and reclaim the thread's private GC heaps. */
static void *sp_ractor_trampoline(void *arg) {
  sp_Ractor *r = (sp_Ractor *)arg;
  sp_ractor_current = r;
  sp_fiber_thread_init();
  r->body(r);                 /* body installs its own top-level rescue pad */
  sp_rq_close(&r->outbox);
  sp_gc_thread_teardown();
  return NULL;
}

sp_Ractor *sp_Ractor_new(void (*body)(sp_Ractor *)) {
  sp_Ractor *r = (sp_Ractor *)calloc(1, sizeof(sp_Ractor));
  if (!r) sp_raise_cls("Ractor::Error", "failed to allocate Ractor");
  r->body = body;
  sp_rq_init(&r->inbox);
  sp_rq_init(&r->outbox);
  if (pthread_create(&r->thread, NULL, sp_ractor_trampoline, r) != 0)
    sp_raise_cls("Ractor::Error", "failed to spawn Ractor thread");
  pthread_detach(r->thread);
  return r;
}

void sp_Ractor_send(sp_Ractor *r, sp_RbVal v) {
  sp_rq_push(&r->inbox, sp_ractor_copy(v));
}

sp_RbVal sp_Ractor_receive(void) {
  sp_Ractor *r = sp_ractor_current;
  if (!r) sp_raise_cls("Ractor::Error", "Ractor.receive called outside a Ractor");
  sp_RbVal v;
  if (!sp_rq_pop(&r->inbox, &v))
    sp_raise_cls("Ractor::Error", "Ractor mailbox closed");
  return v;
}

void sp_Ractor_yield(sp_RbVal v) {
  sp_Ractor *r = sp_ractor_current;
  if (!r) sp_raise_cls("Ractor::Error", "Ractor.yield called outside a Ractor");
  sp_rq_push(&r->outbox, sp_ractor_copy(v));
}

sp_RbVal sp_Ractor_take(sp_Ractor *r) {
  sp_RbVal v;
  if (!sp_rq_pop(&r->outbox, &v))
    sp_raise_cls("Ractor::Error", "Ractor terminated without yielding a value");
  /* The taker owns the value now; for immediates the copy is a no-op, but
     keep the symmetry so the codec has a single choke point. */
  return sp_ractor_copy(v);
}

/* Unused today but keeps -Wunused-function quiet about sp_rq_destroy and
   documents the queue teardown path for when Ractor structs become
   reclaimable (they are intentionally leaked in Milestone 1; see RFC). */
void sp_ractor_free(sp_Ractor *r) {
  sp_rq_destroy(&r->inbox);
  sp_rq_destroy(&r->outbox);
  free(r);
}
