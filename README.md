<div align="center">

# hana【花】
A simple, light, and performant X11 window manager. 🪷

![](https://raw.githubusercontent.com/akai-hana/assets/main/flower-banner.png)

<sub>*\<i WILL replace this with a WM screenshot when i get it to a point where im happy with it\>*</sub>

</div>

---

# Installation
<sup>_this project isn't even a 10th of the way finished, but in here I'll write an installation guide, once the time comes_</sup>

<details>

<summary>sketch</summary>
in here ill write down some stuff i want to include on installation, to not forget meanwhile.

---

Compiling optimized release:
```sh
zig build -Doptimize=ReleaseFast
```

Compiling without optimizing (doesn't remove debug symbols, useful only for development)
```sh
zig build -Doptimize=ReleaseFast
```
</details>

---

# About 花

## Why hana?

I **_love_** window managers.

They bring simplicity and quality of life to a graphical desktop experience. They are the foundation where one stands and does everything that one does inside a computer, be it leisure or work, pleasure or productivity, creation or consumption. They are also the walls that will surround a person, and that this person will look at while they're spending, and will spend, a highly-varied sized chunk of their lives, depending on the person.

All of this might sound overly personal or dramatic, but that's just how I feel about window managers.

Now... *Why make one from scratch?* I mean, it's not like there aren't any window managers available to download and use right now, so then _why?_

---

## Priorities

My main priorities in a WM are the following, in order from most to least:

### 1. Performance
Both computationally fast _and_ light in resources. 

### 2. Simplicity
Sometimes simplicity, less files, lower LoC, so on so forth, can lead to verbosity.

I don't want a WM that's the humanly smallest size possible, sacrificing different things in the way to that end. I want one that achieves all the things it should, WHILE being as lean as possible, BUT if going up a couple LoC ensures a higher performance, more modular architecture, ease of expansion later on, etc etc, then it IS acceptable to go up those couple LoC.

All in all, what I wanted was a WM with which a non-coder could easily interact with (given an unavoidable bit of effort; but for this bit of effort to be as small as possible).

### 3. Aesthetics

In here enters code readability, proper commenting, modularity, ease of expansion if one desired such, so on so forth.

---

## Envisioning

I've tried plenty of window managers: i3wm, openbox, awesomewm, herbsluftwm, riverwm, xmonad... But one stood out the most to me: dwm.

Let me be clear. There's nothing _wrong_ about dwm. It's a perfectly good and fine WM, and I actually agree with its philosophy quite a bit. But for the sake of an idealistic, purposeless perfectionism, I started comparing dwm to an imaginary WM, wondering: What if there was a window manager that managed to be...

+ More **performant** than dwm?
  - XCB (asynchronous) instead of Xlib (synchronous)
  
+ **Simpler** than dwm?
  - Clearer file naming and structuring
    > Nearly all the code in one file (`dwm.c`)? What does `drw.c` do? Why are there two config files (`config.h` / `config.mk`), each one having three different types (`config.<.h/.def.h/.def.h.orig>` / `config<.mk/.mk.orig/.mk.rej`)? What's so transient about `transient.c`? 
  - Config hot-reloading
    > Runtime config instead of recompiling at every minor change (without sacrificing performance on a dynamically interpreted language)
  - Simpler code in general
    > For this purpose, I ended up choosing Zig as the language instead of C. Initially I had no issues with C, but Zig caught my attention in that it produces simpler, safer code than the equivalent in C. It can even directly import the C header file without any API bindings, isn't that super cool?! 

+ **_Less ugly_** than dwm?
  > One might find dwm's ugliness beautiful, but in that case, I imagine a different kind of beauty that involves:

  - Program code in the config file?
    > Why is there code in a config file? Why are data types exposed in here? A config file should just be that, a series of definitions, that conform the main program's configuration. The user shouldn't be faced with, or have to deal with code they might not understand, or not even want to do so, and just go inside the config file to tweak the program to their needs and preferences.
  - Patches directly affect source code?
    > Let me be clear: It is fine if the user wants to tweak the source code, but the absolute very core and foundation of the WM should be isolated within a directory, in a file or set of files, and other less important sections of the WM in the same manner, so that, if the user wants to *expand* onto it, they can just, write their own file, containing their code, and just, *drop it* inside a folder, and simply reload the WM to start enjoying the changes.

At first, I just wanted to better understand dwm and how its different components worked together, but after some time doing so, I just thought, _why_ does it have to be _this_ way and not _that_ other way?

This pettiness quickly became desire, _and thus **hana** came to be._

## Disclaimer

I _know_ performance is basically negligible. I _know_ Qtile, programmed in Python, a dynamically interpreted language, is a thing.

But it's just...

Just...

Just, imagine the "perfect" WM... _But then, well, there's no perfect WM, so that's subjective..._ So then, **YOU** imagine **YOUR** perfect WM according to **YOUR** priorities... That's hana for me.

## Status rn

This is a **very early release**. hana currently does the bare minimum: it shows windows on the display. _That's it._

But it works! After so much time investigating and trying things only to be met with errors for weeks, _something_ finally works! And I'll be working on it... Although slowly. I want to make sure everything in the level I'm standing on right now is the best it can possibly be, before going up a level and building on top of something that I might look back on and recognize as bad, as "this could've been _that_ other way instead...". 

## What Works Right Now

✅ Windows appear on screen  
✅ Configurable borders (width + color)  
✅ XCB async event handling  
✅ Modular architecture  
✅ TOML configuration  
✅ Keyboard and mouse input capture (logged only)

## Roadmap (things to-do):

💡 Window tiling/layouts  
💡 Keybindings (no shortcuts yet)  
💡 Window focus  
💡 Moving/resizing windows  
💡 Workspaces  
💡 Status bar  
💡 Move config to a more coherent dir  
💡 Move Zig's binary output to a UNIX-compatible bin dir (yet to figure out)  FINITIONS #

... Pretty much everything else.

---
FINITIONS #

<div align="center">

made with ❤️ by akai

</div>
