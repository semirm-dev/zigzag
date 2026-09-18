"""Consumer-side end-to-end test for the generated Python bindings.

Run it with plain unittest (pytest is deliberately not a dependency)::

    cd examples/zcounter/py_test && python3 -m unittest discover -v

Every generated name this file depends on lives in ``_surface.py``.
"""

import sys
import unittest
from pathlib import Path

# Make the generated package importable before _surface pulls it in. This is the
# only path manipulation in the suite: no conftest, no installed package.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bindings" / "python"))

import _surface as s  # noqa: E402 - must come after the sys.path insertion

#: FNV-1a-64("foobar"), big-endian. Asserted identically by src/c_api.zig's unit
#: tests and by go_test, so a mismatch localises the bug to one side.
FOOBAR_DIGEST = bytes.fromhex("85944171f73967e8")

MAX_INT32 = 2**31 - 1
MIN_INT32 = -(2**31)


@unittest.skipUnless(s.LOADED, s.SKIP_REASON or "bindings not generated")
class ZCounterTestCase(unittest.TestCase):
    """Base class: every subclass is skipped as one unit when the bindings are
    missing, and gets a counter that is always released."""

    def make(self):
        counter = s.new_counter()
        self.assertIsNotNone(counter, "counter_new returned None")
        self.addCleanup(s.close, counter)
        return counter


class TestAdd(ZCounterTestCase):
    def test_add(self):
        self.assertEqual(s.add(2, 3), 5)
        self.assertEqual(s.add(-7, 7), 0)

    def test_add_wraps(self):
        # zcounter_add uses +%, so this wraps instead of trapping.
        self.assertEqual(s.add(MAX_INT32, 1), MIN_INT32)
        self.assertEqual(s.add(MIN_INT32, -1), MAX_INT32)


class TestHappyPath(ZCounterTestCase):
    def test_feed_digest_total(self):
        counter = self.make()

        value, ok = s.total(counter)
        self.assertTrue(ok, "total on a fresh counter reported failure")
        self.assertEqual(value, 0)

        self.assertEqual(s.feed(counter, b"foobar"), 6)

        data, n = s.digest(counter, 8)
        self.assertEqual(n, 8)
        self.assertEqual(data[:n], FOOBAR_DIGEST)

        # The NUL terminator is not counted, so the total advances by 4.
        self.assertEqual(s.feed_str(counter, " baz"), 10)

        value, ok = s.total(counter)
        self.assertTrue(ok)
        self.assertEqual(value, 10)

        after, n = s.digest(counter, 8)
        self.assertEqual(n, 8)
        self.assertNotEqual(after[:n], FOOBAR_DIGEST)

    def test_bytearray_and_memoryview_are_accepted(self):
        # §8.3: bytes / bytearray / memoryview all work for a buffer-in param.
        for payload in (b"foobar", bytearray(b"foobar"), memoryview(b"foobar")):
            with self.subTest(kind=type(payload).__name__):
                counter = self.make()
                self.assertEqual(s.feed(counter, payload), 6)
                data, n = s.digest(counter, 8)
                self.assertEqual(data[:n], FOOBAR_DIGEST)

    def test_digest_respects_buffer_length(self):
        """zcounter_digest writes min(out_len, 8) bytes and returns that count."""
        counter = self.make()
        s.feed(counter, b"foobar")

        for out_len in (0, 1, 3, 7, 8, 16):
            with self.subTest(out_len=out_len):
                data, n = s.digest(counter, out_len)
                self.assertEqual(n, min(out_len, 8))
                self.assertEqual(data[:n], FOOBAR_DIGEST[:n])


class TestEmptyInput(ZCounterTestCase):
    def test_empty_bytes_leaves_the_counter_untouched(self):
        """An empty bytes()/bytearray() has no usable data pointer; the binding
        must still pass a valid one rather than NULL-deref in Zig."""
        counter = self.make()
        self.assertEqual(s.feed(counter, b"abc"), 3)
        before, _ = s.digest(counter, 8)

        for payload in (b"", bytearray(), bytearray(b""), memoryview(b"")):
            with self.subTest(kind=type(payload).__name__):
                self.assertEqual(s.feed(counter, payload), 3)
                value, ok = s.total(counter)
                self.assertTrue(ok)
                self.assertEqual(value, 3)
                after, _ = s.digest(counter, 8)
                self.assertEqual(after, before)

    def test_empty_string(self):
        counter = self.make()
        self.assertEqual(s.feed_str(counter, "abc"), 3)
        self.assertEqual(s.feed_str(counter, ""), 3)

    def test_zero_length_output_buffer(self):
        counter = self.make()
        s.feed(counter, b"foobar")
        data, n = s.digest(counter, 0)
        self.assertEqual(n, 0)
        self.assertEqual(data, b"")


class TestLifecycle(ZCounterTestCase):
    def test_close_is_idempotent(self):
        """close() zeroes the wrapper's handle and zcounter_destroy ignores a
        handle that is no longer live, so neither layer can double-free."""
        counter = s.new_counter()
        s.close(counter)
        s.close(counter)
        s.close(counter)

    def test_use_after_close_raises(self):
        """A closed wrapper drops its pointer, so a later call fails cleanly in
        Python instead of reaching the native library with a stale handle."""
        counter = s.new_counter()
        s.close(counter)
        with self.assertRaises(s.error_class()):
            s.feed(counter, b"abc")
        with self.assertRaises(s.error_class()):
            s.total(counter)

    def test_context_manager(self):
        """§8.3: __enter__ returns the counter, __exit__ closes it."""
        with s.new_counter() as counter:
            self.assertIsNotNone(counter)
            self.assertEqual(s.feed(counter, b"foobar"), 6)
            data, n = s.digest(counter, 8)
            self.assertEqual(data[:n], FOOBAR_DIGEST)

        # Closing again after the block must not raise or double-free.
        s.close(counter)

    def test_slot_reuse_starts_clean(self):
        first = s.new_counter()
        s.feed(first, b"foobar")
        s.close(first)

        second = self.make()
        value, ok = s.total(second)
        self.assertTrue(ok)
        self.assertEqual(value, 0, "a reused pool slot came back dirty")

    def test_handles_are_independent(self):
        counters = [self.make() for _ in range(8)]
        for i, counter in enumerate(counters):
            s.feed(counter, b"x" * (i + 1))
        for i, counter in enumerate(counters):
            value, ok = s.total(counter)
            self.assertTrue(ok)
            self.assertEqual(value, i + 1)


class TestHandlePointerWidth(ZCounterTestCase):
    """IMPLEMENTATION.md §8.2: a function returning a handle MUST set
    ``restype = c_void_p``. ctypes defaults to ``c_int``, which truncates a
    64-bit pointer (and usually turns it negative)."""

    def test_handle_is_not_truncated(self):
        counter = self.make()
        handle = s.raw_handle(counter)

        self.assertIsNotNone(handle, "the handle came back as None")
        self.assertIsInstance(handle, int)
        self.assertGreater(handle, 0, "handle is non-positive: restype truncated it")
        self.assertLess(handle, 2**64)

        if sys.maxsize > 2**32:
            # A c_int restype would have discarded the top half of the address.
            self.assertEqual(handle & 0xFFFFFFFFFFFFFFFF, handle)

    def test_handle_round_trips(self):
        """The strongest truncation check: a mangled pointer would not resolve
        back to a live pool slot, so these calls would report failure."""
        counter = self.make()
        handle_before = s.raw_handle(counter)

        self.assertEqual(s.feed(counter, b"foobar"), 6)

        # Allocate more counters in between; the first must be unaffected.
        others = [self.make() for _ in range(4)]
        for other in others:
            self.assertNotEqual(s.raw_handle(other), handle_before)

        self.assertEqual(s.raw_handle(counter), handle_before)
        value, ok = s.total(counter)
        self.assertTrue(ok, "the handle no longer resolves: it was truncated")
        self.assertEqual(value, 6)


if __name__ == "__main__":
    unittest.main()
