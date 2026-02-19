#ifndef KEVENT_SHIM_H
#define KEVENT_SHIM_H

#include <sys/event.h>
#include <sys/time.h>

/// Unambiguous wrapper for kevent() syscall (Swift 6 resolves kevent to the struct).
int kevent_wrapper(int kq,
                   const struct kevent *changelist, int nchanges,
                   struct kevent *eventlist, int nevents,
                   const struct timespec *timeout);

#endif
