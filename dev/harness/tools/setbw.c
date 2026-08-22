/* setbw <window-id-hex-or-dec> <border-width>
 * Sets a client window's own border width via XSetWindowBorderWidth.
 * For a managed top-level this is redirected to the WM as a
 * ConfigureRequest with a border-width field -- exactly the path
 * scenarios S12 exercises. Built on demand by lib/common.sh.
 */
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s <win> <bw>\n", argv[0]); return 2; }
    Display *d = XOpenDisplay(NULL);
    if (!d) { perror("XOpenDisplay"); return 1; }
    Window w = (Window)strtoul(argv[1], NULL, 0);
    unsigned int bw = (unsigned int)atoi(argv[2]);
    XSetWindowBorderWidth(d, w, bw);
    XSync(d, False);
    XCloseDisplay(d);
    return 0;
}
