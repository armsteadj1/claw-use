#include <sys/event.h>
#include <sys/time.h>

// Swift 6 cannot disambiguate the kevent() syscall from the kevent struct.
// This C shim provides an unambiguous wrapper.
int kevent_wrapper(int kq,
                   const struct kevent *changelist, int nchanges,
                   struct kevent *eventlist, int nevents,
                   const struct timespec *timeout) {
    return kevent(kq, changelist, nchanges, eventlist, nevents, timeout);
}
