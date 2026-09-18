"""The ONLY place that names an identifier from the generated Python package.

Every assertion in ``test_zcounter.py`` goes through the adapters below, so when
the Python generator's spelling changes, this one file changes and the tests do
not.

The names were read back from ``bindings/python/zcounter/_gen.py`` after
``zig build port``, and match what ``src/gen/names.zig`` produces::

    lib_name = "zcounter" and every export is named "zcounter_*", so
    names.stripPrefix drops the "zcounter_" prefix and names.toSnake leaves
    the already-snake_case remainder alone:

    zcounter_new      -> Counter.new()                classmethod ctor (D7)
    zcounter_destroy  -> Counter.close()              dtor (D7)
    zcounter_add      -> zcounter.add(a, b)           module level
    zcounter_feed     -> Counter.feed(data)           -> int
    zcounter_feed_str -> Counter.feed_str(text)       -> int
    zcounter_digest   -> Counter.digest(out: bytearray) -> int
    zcounter_total    -> Counter.total()              -> (ok, value)
    opaque Counter    -> class Counter

Naming the exports ``<libname>_*`` is what makes this read well: the prefix is
stripped, so the Python API is ``feed``/``digest``/``total`` rather than
``zc_counter_feed``. The validator warns when an export does not start with the
library name.

Shapes worth naming explicitly, because they are what a regeneration is most
likely to move:

* ``digest`` takes a **caller-allocated** ``bytearray`` and returns the number
  of bytes written, mirroring Go. ``digest()`` below allocates it and returns
  ``(data, n)`` so the tests can assert on both.
* ``total`` returns the DECLARED return value first and the out-param second:
  ``(ok, value)``. ``total()`` flips it to ``(value, ok)``.
* The raw ``ctypes.c_void_p`` lives on ``Counter._handle`` (``__slots__``), and
  ``raw_handle()`` unwraps ``.value`` from it for the §8.2 truncation test.
"""

import sys
from pathlib import Path

#: Where ``zig build port`` writes the generated Python package.
BINDINGS_DIR = Path(__file__).resolve().parents[1] / "bindings" / "python"

#: Import name of the generated package: Context.pythonPackage(), which
#: defaults to lib_name.
PACKAGE = "zcounter"

if str(BINDINGS_DIR) not in sys.path:
    sys.path.insert(0, str(BINDINGS_DIR))

zc = None
SKIP_REASON = ""

if not BINDINGS_DIR.is_dir():
    # The bindings have not been generated yet. Skip loudly rather than fail, so
    # a fresh checkout reports "run zig build port" instead of a stack trace.
    SKIP_REASON = (
        f"generated Python bindings not found at {BINDINGS_DIR}; "
        "run `zig build port` in examples/zcounter first"
    )
else:
    # The directory exists, so an import failure is a real failure: let it raise.
    zc = __import__(PACKAGE)

LOADED = zc is not None


# --------------------------------------------------------------------------
# Adapters. Nothing outside this file touches `zc`.
# --------------------------------------------------------------------------


def counter_class():
    """The generated class for the ``Counter`` opaque."""
    return zc.Counter


def error_class():
    """The exception the generated layer raises on a failed call."""
    return zc.ZcounterError


def new_counter():
    """Construct a counter. Usable as a context manager (§8.3)."""
    return zc.Counter.new()


def close(counter):
    """Release a counter. Must be idempotent (D7, §8.3)."""
    counter.close()


def add(a, b):
    """``zcounter_add``."""
    return zc.add(a, b)


def feed(counter, data):
    """``zcounter_feed``; returns the new byte total."""
    return counter.feed(data)


def feed_str(counter, text):
    """``zcounter_feed_str``; returns the new byte total."""
    return counter.feed_str(text)


def digest(counter, out_len):
    """``zcounter_digest``; returns ``(data, n_written)``.

    The generated method writes into a caller-allocated ``bytearray``, so the
    buffer is allocated here and handed back alongside the count.
    """
    out = bytearray(out_len)
    written = counter.digest(out)
    return bytes(out), written


def total(counter):
    """``zcounter_total``; returns ``(value, ok)`` from the generated
    ``(ok, value)``."""
    ok, value = counter.total()
    return value, ok


def raw_handle(counter):
    """The underlying ``c_void_p`` value, for the §8.2 truncation test."""
    handle = counter._handle
    if handle is None:
        return None
    # A ctypes c_void_p keeps the address in `.value`.
    return getattr(handle, "value", handle)
