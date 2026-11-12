// Row tuples read straight off SQLite are clearer spelled out than named.
#![allow(clippy::type_complexity)]

pub mod api;
pub mod embed;
pub mod ffi;
pub mod index;
pub mod metadata;
pub mod naming;
pub mod plex;
pub mod slice;
pub mod source;

/// Drops the calling thread to the utility QoS class, so the scheduler and the
/// I/O throttle serve playback and the interface first. Never the background
/// class: these threads take the index mutex the interface waits on, and that
/// class throttles the disk writes made while holding it.
pub(crate) fn lower_thread_qos() {
    // only the calling thread changes; a failure leaves it where it was
    #[cfg(target_vendor = "apple")]
    let _ = unsafe { libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_UTILITY, 0) };
}

uniffi::setup_scaffolding!();
