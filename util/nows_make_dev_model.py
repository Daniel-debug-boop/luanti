#!/usr/bin/env python3
"""Write a development NOWS model file for integration testing.

This is an OFFLINE tool. It is not part of the game, not imported by it, and
nothing in the engine runs it. Its output is a structurally valid .nowsm file
with deterministic placeholder weights, marked trained=0 so the engine refuses
to load it unless nows_allow_untrained is set.

It exists so the loader, the forward pass, the adapter and the fallback paths
can be exercised end to end before anyone has trained a real network. It is not
a prediction of anything.

To ship a real model, train an FNO warm-start network against liquid fields
dumped from the engine and export it with trained=1, using the tensor layout
documented in src/nows/README.md.

Usage:
    util/nows_make_dev_model.py [output.nowsm] [--grid 16]

The defaults (grid 16, 4 channels, 2 modes, 1 layer) are sized so one inference
stays inside the engine's nows_max_inference_us budget on a modest CPU. Larger
settings still load, but the manager will reject them as not worth it and fall
back to the normal solver, which is the correct behaviour.
"""

import argparse
import struct
import sys

MAGIC = b"NOWSMDL\0"
FORMAT_VERSION = 1


def f32_tensor(values):
    """Pack floats as little-endian IEEE-754, like the engine expects."""
    return struct.pack("<%df" % len(values), *values)


def u32(value):
    return struct.pack("<I", value)


def build_tensors(channels, modes, layers, in_channels, out_channels):
    """A structurally complete FNO3D weight set with fixed placeholder values.

    The spectral weights are zero and the pointwise weights are identity, so
    the operator is a smooth, deterministic function of the input. That keeps
    tests independent of floating point details while still running every line
    of the forward pass.
    """
    tensors = []

    lift_w = [0.0] * (channels * in_channels)
    for c in range(channels):
        for k in range(in_channels):
            if k % channels == c:
                lift_w[c * in_channels + k] = 0.25
    tensors.append(("lift_w", lift_w))
    tensors.append(("lift_b", [0.0] * channels))

    spec_len = modes * modes * modes * channels * channels
    for layer in range(layers):
        base = "l%d" % layer
        tensors.append((base + "_spec_re", [0.0] * spec_len))
        tensors.append((base + "_spec_im", [0.0] * spec_len))
        pw_w = [0.0] * (channels * channels)
        for c in range(channels):
            pw_w[c * channels + c] = 1.0
        tensors.append((base + "_pw_w", pw_w))
        tensors.append((base + "_pw_b", [0.0] * channels))

    proj_w = [0.0] * (out_channels * channels)
    for o in range(out_channels):
        proj_w[o * channels] = 0.5
    tensors.append(("proj_w", proj_w))
    tensors.append(("proj_b", [0.0] * out_channels))

    return tensors


def write_model(path, grid, channels, modes, layers, in_channels, out_channels):
    header = "".join([
        "arch=fno3d\n",
        "name=dev-placeholder\n",
        "note=UNTRAINED development placeholder; not a prediction\n",
        "trained=0\n",
        "grid=%d\n" % grid,
        "channels=%d\n" % channels,
        "modes=%d\n" % modes,
        "layers=%d\n" % layers,
        "in_channels=%d\n" % in_channels,
        "out_channels=%d\n" % out_channels,
    ]).encode("utf-8")

    tensors = build_tensors(channels, modes, layers, in_channels, out_channels)

    with open(path, "wb") as fh:
        fh.write(MAGIC)
        fh.write(u32(FORMAT_VERSION))
        fh.write(u32(len(header)))
        fh.write(header)
        fh.write(u32(len(tensors)))
        for name, values in tensors:
            raw = name.encode("utf-8")
            fh.write(u32(len(raw)))
            fh.write(raw)
            fh.write(u32(len(values)))
            fh.write(f32_tensor(values))

    return len(tensors)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
            formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output", nargs="?", default="nows-dev.nowsm",
            help="output file (default: nows-dev.nowsm)")
    parser.add_argument("--grid", type=int, default=16,
            help="cube edge, power of two in [8,32] (default 16)")
    parser.add_argument("--channels", type=int, default=4,
            help="operator width (default 4)")
    parser.add_argument("--modes", type=int, default=2,
            help="retained spectral modes per axis (default 2)")
    parser.add_argument("--layers", type=int, default=1,
            help="number of operator layers (default 1)")
    parser.add_argument("--in-channels", type=int, default=6,
            help="input feature channels; must match the adapter (default 6)")
    parser.add_argument("--out-channels", type=int, default=1,
            help="output channels (default 1)")
    args = parser.parse_args()

    if args.grid < 8 or args.grid > 32 or args.grid & (args.grid - 1):
        parser.error("--grid must be a power of two in [8,32]")
    if args.modes > args.grid // 2 + 1:
        parser.error("--modes must be at most grid/2 + 1")

    count = write_model(args.output, args.grid, args.channels, args.modes,
            args.layers, args.in_channels, args.out_channels)

    print("wrote %s: %d tensors, grid %d, channels %d, modes %d, layers %d"
            % (args.output, count, args.grid, args.channels, args.modes,
               args.layers))
    print("This model is UNTRAINED. The engine will refuse to load it unless")
    print("nows_allow_untrained is enabled, and it predicts nothing useful.")
    return 0


if __name__ == "__main__":
    sys.exit(main())