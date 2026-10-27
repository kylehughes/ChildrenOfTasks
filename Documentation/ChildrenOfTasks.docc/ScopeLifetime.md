# Scope lifetime and result publication

Understand which value owns execution and which values only observe its outcome.

## Borrowed spawning authority

`withChildren` creates a native `TaskGroup<Void>` and lends a noncopyable `Children` value to its body. Private, non-Sendable storage holds a scoped group copy. Only the creating task uses it, and the original group is not separately mutated while that authority is active.

The borrowing boundary matters: an `inout` capability could allow two nested scopes to swap their group storage. Noncopyability alone would not prevent that exchange. Keep helpers borrowing the same capability in the same task. A child can open a fresh scope of its own.

## One terminal outcome

Each child captures its operation's typed outcome in `Result<Value, Failure>` and publishes it through an actor. The actor moves once from pending readers to a resolved outcome. Registration and publication are serialized, so a reader either joins the pending continuation list or receives the stored result.

A handle retains only its result cell, not the spawning authority. Copying it shares that cell. A reference-valued result is an ordinary shared reference, not an immutable snapshot of the referenced object's later state.

Publication establishes that the operation has returned or thrown. The wrapping group task can still be finishing publication when a reader resumes. Scope exit supplies the stronger guarantee that all producer tasks have been joined.

## Body outcome and cleanup

The body also materializes its outcome in a typed `Result`. On ordinary body completion, the scope requests cancellation and lets the native group join every child before returning or throwing that original outcome. An ignored child error cannot replace the body's result or error.

Starting work is unconditional, including after cancellation. Skipping a canceled start would leave no lawful outcome for a nonthrowing handle. Operations receive native cancellation state and choose how to respond; a success after cancellation remains a success.

A canceled reader keeps its continuation until publication. Dropping a handle does not cancel its producer. The scope has no timeout or cancellation shield. A body or child that does not finish can prevent return indefinitely; fatal termination and unsafe client misuse are outside ordinary cleanup guarantees.

## Bounded use

The implementation allocates group storage per scope and a result actor per child in addition to native task storage. Waiting readers require continuations. Completed outcomes remain alive while their handles do, and ordinary task-group completion bookkeeping can accumulate until scope exit.

Use finite scopes for application operations. There is no scheduler, backpressure mechanism, per-child cancellation, or priority-donation contract for unrelated readers. For homogeneous completion-order processing, a native task group exposes the appropriate interface directly.
