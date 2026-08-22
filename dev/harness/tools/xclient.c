/* xclient [--name NAME] [--class CLASS] [--w W] [--h H] [--fixed] [--noinput]
 *
 * Minimal deterministic X client for hana's smoke-test harness.
 * - Creates one top-level window, maps it, and serves events until killed
 *   or deleted via WM_DELETE_WINDOW.
 * - Advertises WM_HINTS(input=True) + WM_TAKE_FOCUS by default, so the WM
 *   focuses it (unlike xeyes, which is a no-input client).
 * - Default size hints are unconstrained (layouts may fill freely).
 *   --fixed pins min=max=w,h (exercises hint-clamping paths).
 * - --noinput reproduces xeyes-style Input=False clients.
 * Built on demand by run-scenario.sh; needs only libX11.
 */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *name = "A";
    const char *class_name = "XClient";
    int w = 400, h = 300, noinput = 0, fixed = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "--class") && i + 1 < argc) class_name = argv[++i];
        else if (!strcmp(argv[i], "--w") && i + 1 < argc) w = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--h") && i + 1 < argc) h = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fixed")) fixed = 1;
        else if (!strcmp(argv[i], "--noinput")) noinput = 1;
        else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 2; }
    }

    Display *d = XOpenDisplay(NULL);
    if (!d) { perror("XOpenDisplay"); return 1; }
    int screen = DefaultScreen(d);
    Window root = RootWindow(d, screen);

    XSetWindowAttributes attr = { .background_pixel = WhitePixel(d, screen) };
    Window win = XCreateSimpleWindow(d, root, 10, 10, (unsigned)w, (unsigned)h, 0,
                                     BlackPixel(d, screen), attr.background_pixel);

    XStoreName(d, win, name);
    XClassHint ch = { .res_name = (char *)class_name, .res_class = (char *)class_name };
    XSetClassHint(d, win, &ch);

    XWMHints hints;
    memset(&hints, 0, sizeof(hints));
    hints.flags = InputHint;
    hints.input = noinput ? False : True;
    XSetWMHints(d, win, &hints);

    /* WM_NORMAL_HINTS: unconstrained by default; --fixed pins min=max */
    XSizeHints sh;
    memset(&sh, 0, sizeof(sh));
    if (fixed) {
        sh.flags = PSize | PMinSize | PMaxSize;
        sh.width = sh.min_width = sh.max_width = w;
        sh.height = sh.min_height = sh.max_height = h;
        XSetWMNormalHints(d, win, &sh);
    } else {
        sh.flags = PSize;
        sh.width = w;
        sh.height = h;
        XSetWMNormalHints(d, win, &sh);
    }

    /* WM_PROTOCOLS: WM_DELETE_WINDOW + WM_TAKE_FOCUS */
    Atom protocols[2];
    int nproto = 0;
    protocols[nproto++] = XInternAtom(d, "WM_DELETE_WINDOW", False);
    protocols[nproto++] = XInternAtom(d, "WM_TAKE_FOCUS", False);
    XSetWMProtocols(d, win, protocols, nproto);

    XSelectInput(d, win, ExposureMask | KeyPressMask | ButtonPressMask);
    XMapWindow(d, win);
    XFlush(d);

    for (;;) {
        XEvent ev;
        XNextEvent(d, &ev);
        if (ev.type == ClientMessage) {
            Atom msg = (Atom)ev.xclient.data.l[0];
            if (msg == XInternAtom(d, "WM_DELETE_WINDOW", False)) break;
        }
    }
    XDestroyWindow(d, win);
    XCloseDisplay(d);
    return 0;
}
