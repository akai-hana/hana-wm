/* barshot.c -- P1-21 golden-pixel capture for the hana harness.
 *
 * Finds the bar (the root child carrying _NET_WM_WINDOW_TYPE_DOCK), reads its
 * pixels, and prints a NORMALIZED cell-ink grid: the window split into
 * 4x4 cells, each cell one hex digit = how many pixels in it differ from the
 * majority (bar background) colour.
 *
 * The harness pins a private font for hana (FONTCONFIG_FILE written per run)
 * with antialiasing and hinting off, so glyph pixels are exact and the grid
 * is byte-stable across machines. Nothing volatile appears in the output: no
 * window ids, no clock text, no timing -- that is what makes it diffable as a
 * golden artifact (run-scenario.sh compares $out/bar.norm against
 * golden/<sc>/bar.norm).
 *
 * Usage:  barshot            (DISPLAY picked up from the environment)
 * Exit:   0 ok (grid on stdout)   1 display/property error
 *         2 no bar window         3 bar exists but nothing is painted yet
 */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CELL 4
#define MAXCOLORS 64

static unsigned long majority_color(XImage *im, int *ok) {
	struct { unsigned long px; unsigned long n; } tab[MAXCOLORS];
	int ntab = 0;
	int i, j;
	char *data = im->data;
	int bpp = (im->bits_per_pixel + 7) / 8;

	for (i = 0; i < im->height; i++) {
		char *row = data + (long)i * im->bytes_per_line;
		for (j = 0; j < im->width; j++) {
			unsigned long px = 0;
			memcpy(&px, row + (long)j * bpp, bpp);
			int k;
			for (k = 0; k < ntab; k++)
				if (tab[k].px == px) { tab[k].n++; break; }
			if (k < ntab) continue;
			if (ntab == MAXCOLORS) { *ok = 0; return 0; }
			tab[ntab].px = px;
			tab[ntab].n = 1;
			ntab++;
		}
	}
	*ok = 1;
	{
		int best = 0;
		for (i = 1; i < ntab; i++)
			if (tab[i].n > tab[best].n) best = i;
		return tab[best].px;
	}
}

static unsigned long decode_rgb(XImage *im, unsigned long px) {
	unsigned long rm = im->red_mask, gm = im->green_mask, bm = im->blue_mask;
	int rs = 0, gs = 0, bs = 0;
	int rbits = 0, gbits = 0, bbits = 0;
	unsigned long r, g, b;
	while (rm && !(rm & 1)) { rm >>= 1; rs++; }
	while (gm && !(gm & 1)) { gm >>= 1; gs++; }
	while (bm && !(bm & 1)) { bm >>= 1; bs++; }
	r = (px >> rs) & ((1UL << 24) - 1);
	g = (px >> gs) & ((1UL << 24) - 1);
	b = (px >> bs) & ((1UL << 24) - 1);
	for (rm = im->red_mask >> rs; rm & 1; rm >>= 1) rbits++;
	for (gm = im->green_mask >> gs; gm & 1; gm >>= 1) gbits++;
	for (bm = im->blue_mask >> bs; bm & 1; bm >>= 1) bbits++;
	/* Byte-aligned masks (X TrueColor on every server the harness uses):
	 * shift the kept field down and scale its width to 8 bits. */
	if (rbits > 8) r >>= (rbits - 8);
	if (gbits > 8) g >>= (gbits - 8);
	if (bbits > 8) b >>= (bbits - 8);
	return ((r & 0xff) << 16) | ((g & 0xff) << 8) | (b & 0xff);
}

int main(void) {
	Display *dpy;
	Window root_ret, parent;
	Window *children = NULL;
	unsigned int nchildren = 0, ci;
	Atom type_dock;
	XImage *im;
	unsigned long bg;
	int bgok = 0, painted = 0;
	int cols, rows, cx, cy;
	Window bar = 0;
	int W = 0, H = 0;

	dpy = XOpenDisplay(NULL);
	if (!dpy) {
		fprintf(stderr, "barshot: cannot open display\n");
		return 1;
	}
	if (!XQueryTree(dpy, DefaultRootWindow(dpy), &root_ret, &parent,
			&children, &nchildren)) {
		fprintf(stderr, "barshot: XQueryTree failed\n");
		return 1;
	}
	type_dock = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", False);
	for (ci = 0; ci < nchildren; ci++) {
		Atom actual_type;
		int actual_format;
		unsigned long nitems, bytes_after;
		unsigned char *prop = NULL;
		if (XGetWindowProperty(dpy, children[ci],
				XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False), 0, 1, False,
				XA_ATOM, &actual_type, &actual_format, &nitems, &bytes_after,
				&prop) != Success)
			continue;
		if (prop && nitems >= 1 && actual_format == 32 &&
		    *(Atom *)prop == type_dock) {
			bar = children[ci];
		}
		if (prop) XFree(prop);
		if (bar) break;
	}
	if (children) XFree(children);
	if (!bar) {
		fprintf(stderr, "barshot: no _NET_WM_WINDOW_TYPE_DOCK window\n");
		return 2;
	}

	{
		XWindowAttributes wa;
		if (!XGetWindowAttributes(dpy, bar, &wa)) {
			fprintf(stderr, "barshot: XGetWindowAttributes failed\n");
			return 1;
		}
		if (wa.map_state != IsViewable) {
			fprintf(stderr, "barshot: bar is not viewable yet\n");
			return 3;
		}
		W = wa.width;
		H = wa.height;
	}
	if (W <= 0 || H <= 0) {
		fprintf(stderr, "barshot: degenerate bar %dx%d\n", W, H);
		return 1;
	}

	im = XGetImage(dpy, bar, 0, 0, W, H, AllPlanes, ZPixmap);
	if (!im) {
		fprintf(stderr, "barshot: XGetImage failed\n");
		return 1;
	}
	bg = majority_color(im, &bgok);
	if (!bgok) {
		fprintf(stderr, "barshot: too many distinct colours\n");
		return 1;
	}

	cols = (W + CELL - 1) / CELL;
	rows = (H + CELL - 1) / CELL;
	printf("bar %dx%d cell %d bg %06lx\n", W, H, CELL, decode_rgb(im, bg));
	for (cy = 0; cy < rows; cy++) {
		for (cx = 0; cx < cols; cx++) {
			int n = 0, px, py;
			for (py = 0; py < CELL && cy * CELL + py < H; py++) {
				char *row = im->data +
					(long)(cy * CELL + py) * im->bytes_per_line;
				for (px = 0; px < CELL && cx * CELL + px < W; px++) {
					unsigned long v = 0;
					int bpp = (im->bits_per_pixel + 7) / 8;
					memcpy(&v, row + (long)(cx * CELL + px) * bpp, bpp);
					if (v != bg) n++;
				}
			}
			if (n) painted = 1;
			putchar("0123456789abcdef"[n > 15 ? 15 : n]);
		}
		putchar('\n');
	}
	XDestroyImage(im);
	XCloseDisplay(dpy);
	if (!painted) {
		fprintf(stderr, "barshot: bar window is blank (not painted yet)\n");
		return 3;
	}
	return 0;
}
