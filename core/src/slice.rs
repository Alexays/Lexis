//! What bounds one batch of the background pass.
//!
//! A count of items was only ever a proxy for a duration, and a poor one
//! across queues whose item is an HTTP request, a forward pass through an
//! encoder, or a query. So the unit of interruption is the duration itself: a
//! batch stops at the first item boundary past its deadline, or as soon as
//! something asks it to stand aside.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// How long a batch may hold its thread, and the flag that cuts it shorter.
/// Every queue's loop asks between items, so what one item costs decides how
/// many of them a batch does rather than how long it runs.
pub struct Slice<'a> {
    until: Option<Instant>,
    stop: Option<&'a AtomicBool>,
}

impl<'a> Slice<'a> {
    /// A batch that must be back within `budget`, and sooner if `stop` is set:
    /// the flag is what a viewer pressing play sets, and waiting out the
    /// budget after that is waiting on work nobody asked for.
    pub fn of(budget: Duration, stop: &'a AtomicBool) -> Self {
        Self {
            until: Some(Instant::now() + budget),
            stop: Some(stop),
        }
    }

    /// A batch nothing cuts short, for a caller that asked for this batch and
    /// is waiting on its answer.
    pub fn open() -> Self {
        Self {
            until: None,
            stop: None,
        }
    }

    /// Whether the batch in flight must stop before the next item. Costs an
    /// atomic load and a clock read, which is nothing beside any item on any
    /// of the queues.
    pub fn expired(&self) -> bool {
        self.stop.is_some_and(|stop| stop.load(Ordering::Relaxed))
            || self.until.is_some_and(|until| Instant::now() >= until)
    }
}
