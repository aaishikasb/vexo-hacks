#!/usr/bin/env python3
"""Assert motion from real rendered screenshots, never from a copied view model.

Capture two settled Session frames at least three seconds apart from the same
launch. Supply pixel boxes from those screenshots, excluding system chrome.
The title box contains the rotating headline; content covers the controls below
it, which must not move as words change. Requires the host's Pillow installation.
Use --reduced for frames captured with the actual OS Reduce Motion preference.
"""
import argparse
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("first")
parser.add_argument("second")
parser.add_argument("--wave-box", nargs=4, type=int, required=True, metavar=("X0", "Y0", "X1", "Y1"))
parser.add_argument("--title-box", nargs=4, type=int, required=True, metavar=("X0", "Y0", "X1", "Y1"))
parser.add_argument("--content-box", nargs=4, type=int, required=True, metavar=("X0", "Y0", "X1", "Y1"))
parser.add_argument("--reduced", action="store_true")
parser.add_argument("--wave-color", choices=["blue", "red"], default="blue",
                    help="Expected waveform accent in the captured build")
args = parser.parse_args()
first = Image.open(args.first).convert("RGB")
second = Image.open(args.second).convert("RGB")
assert first.size == second.size, "Frame sizes differ"

def pixels(image, box):
    assert 0 <= box[0] < box[2] <= image.width and 0 <= box[1] < box[3] <= image.height, "Invalid screenshot region"
    return list(image.crop(tuple(box)).getdata())

def changed(box):
    return sum(max(abs(a - b) for a, b in zip(left, right)) > 10
               for left, right in zip(pixels(first, box), pixels(second, box)))

def wave(color):
    red, green, blue = color
    if args.wave_color == "red":
        return red > green + 35 and red > blue + 10 and red > 80
    return blue > red + 35 and blue > green + 10 and blue > 80

visible = sum(wave(pixel) for pixel in pixels(first, args.wave_box))
wave_changes = changed(args.wave_box)
title_changes = changed(args.title_box)
content_changes = changed(args.content_box)
print(f"Visible waveform: {visible} pixels")
print(f"Changed waveform/title/content pixels: {wave_changes}/{title_changes}/{content_changes}")
assert visible > 1000, "Waveform is missing or barely visible"
assert content_changes < 20, "Controls below the headline moved or changed between settled frames"
if args.reduced:
    assert wave_changes < 20, "Waveform moves with Reduce Motion enabled"
    assert title_changes < 20, "Headline changes with Reduce Motion enabled"
else:
    assert wave_changes > 1000, "Active waveform did not move"
    assert title_changes > 100, "Rotating headline did not change"
print("PASS: visible motion and stable layout" if not args.reduced else "PASS: visible static wave and stable headline/layout")
