/* setgeom <win> <x> <y> <w> <h> [bw]
 *
 * Sends ONE ConfigureRequest carrying a mixed value mask
 * (X|Y|Width|Height[|BorderWidth]) — exercises the WM's mixed-mask
 * routing (ND-14 / S4F7b) rather than the BW-only fast path.
 * Built on demand by run-scenario.sh; needs only libX11.
 */
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 6 && argc != 7) {
        fprintf(stderr, "usage: %s <win> <x> <y> <w> <h> [bw]\n", argv[0]);
        return 2;
    }
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "setgeom: cannot open display\n"); return 1; }
    Window w = (Window)strtoul(argv[1], NULL, 0);
    XWindowChanges ch;
    ch.x = atoi(argv[2]);
    ch.y = atoi(argv[3]);
    ch.width = atoi(argv[4]);
    ch.height = atoi(argv[5]);
    unsigned long mask = CWX | CWY | CWWidth | CWHeight;
    if (argc == 7) {
        ch.border_width = (unsigned int)atoi(argv[6]);
        mask |= CWBorderWidth;
    }
    XConfigureWindow(dpy, w, mask, &ch);
    XSync(dpy, False);
    XCloseDisplay(dpy);
    return 0;
}
