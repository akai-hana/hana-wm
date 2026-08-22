/* ewmhfs <win> <add|remove|toggle> — send a _NET_WM_STATE ClientMessage
 * (ICCCM/EWMH fullscreen request) so harness scenarios exercise the WM's
 * client-message path exactly like a real client would.
 *
 * Usage (from scenarios via the ewmh_fs() helper): the window id is decimal.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s <win> <add|remove|toggle>\n", argv[0]); return 2; }
    Window win = (Window)strtoul(argv[1], NULL, 0);
    long action;
    if (!strcmp(argv[2], "add")) action = 1;        /* _NET_WM_STATE_ADD */
    else if (!strcmp(argv[2], "remove")) action = 0; /* _NET_WM_STATE_REMOVE */
    else if (!strcmp(argv[2], "toggle")) action = 2; /* _NET_WM_STATE_TOGGLE */
    else { fprintf(stderr, "bad action\n"); return 2; }

    Display *d = XOpenDisplay(NULL);
    if (!d) { perror("XOpenDisplay"); return 1; }
    Atom wm_state = XInternAtom(d, "_NET_WM_STATE", False);
    Atom fs = XInternAtom(d, "_NET_WM_STATE_FULLSCREEN", False);
    XClientMessageEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = ClientMessage;
    ev.window = win;
    ev.message_type = wm_state;
    ev.format = 32;
    ev.data.l[0] = action;
    ev.data.l[1] = (long)fs;
    ev.data.l[2] = 0;
    ev.data.l[3] = 1; /* source: application */
    ev.data.l[4] = 0;
    Window root = DefaultRootWindow(d);
    XSendEvent(d, root, False,
               SubstructureRedirectMask | SubstructureNotifyMask, (XEvent *)&ev);
    XFlush(d);
    XCloseDisplay(d);
    return 0;
}
