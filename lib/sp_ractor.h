/* sp_ractor.h -- minimal pthread-backed Ractor runtime (RFC, Milestone 1).
 *
 * A Ractor is "a block body run on its own pthread, with deep-copy message
 * passing instead of shared state." Spinel's runtime is a pile of file-scope
 * statics; making the per-execution-unit mutable ones __thread (see sp_gc.h,
 * sp_fiber.h, sp_runtime.h) gives every Ractor a private GC heap, root stack,
 * string heap, and exception landing pads -- so Ractors collect independently
 * with no global GC lock. The only genuinely shared, lock-guarded state is the
 * per-Ractor mailbox/outgoing queues defined here.
 *
 * Milestone 1 deep-copies only immediate (non-heap) values across the
 * boundary: Integer / Float / true / false / nil travel by value through the
 * queues. Any heap-backed value (String, Array, Hash, object, Symbol) raises
 * Ractor::Error -- the serialization codec for those is a later milestone.
 */
#ifndef SP_RACTOR_H
#define SP_RACTOR_H

#include "sp_gc.h"   /* sp_RbVal + tag constants */

typedef struct sp_Ractor sp_Ractor;

/* The Ractor running on the calling pthread; NULL on the main thread.
   Read by Ractor.receive / Ractor.yield as the implicit receiver. */
extern __thread sp_Ractor *sp_ractor_current;

/* Public API, reached by name from the generated translation unit. */
sp_Ractor *sp_Ractor_new(void (*body)(sp_Ractor *)); /* Ractor.new { ... } */
void       sp_Ractor_send(sp_Ractor *r, sp_RbVal v); /* r.send(v) / r << v */
sp_RbVal   sp_Ractor_receive(void);                  /* Ractor.receive     */
void       sp_Ractor_yield(sp_RbVal v);              /* Ractor.yield(v)    */
sp_RbVal   sp_Ractor_take(sp_Ractor *r);             /* r.take             */

#endif
