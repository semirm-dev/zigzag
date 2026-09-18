package zctest

import (
	"bytes"
	"encoding/hex"
	"math"
	"strings"
	"testing"
)

// FNV-1a-64("foobar"), big-endian. The same constant is asserted by the Zig
// unit tests in src/c_api.zig and by py_test, so a mismatch localises the bug
// to one side of the boundary.
const foobarDigest = "85944171f73967e8"

func mustNew(t *testing.T) *counter {
	t.Helper()
	c, err := newCounter()
	if err != nil {
		t.Fatalf("constructing a counter: %v", err)
	}
	if c == nil {
		t.Fatal("constructor returned a nil counter with a nil error")
	}
	return c
}

func TestAddWraps(t *testing.T) {
	if got := add(2, 3); got != 5 {
		t.Errorf("add(2, 3) = %d, want 5", got)
	}
	if got := add(-7, 7); got != 0 {
		t.Errorf("add(-7, 7) = %d, want 0", got)
	}
	// zcounter_add uses +%, so this wraps rather than trapping.
	if got := add(math.MaxInt32, 1); got != math.MinInt32 {
		t.Errorf("add(MaxInt32, 1) = %d, want %d", got, int32(math.MinInt32))
	}
	if got := add(math.MinInt32, -1); got != math.MaxInt32 {
		t.Errorf("add(MinInt32, -1) = %d, want %d", got, int32(math.MaxInt32))
	}
}

func TestHappyPath(t *testing.T) {
	c := mustNew(t)
	defer closeCounter(c)

	if got, ok := total(c); !ok || got != 0 {
		t.Fatalf("total on a fresh counter = (%d, %v), want (0, true)", got, ok)
	}

	if got := feed(c, []byte("foobar")); got != 6 {
		t.Errorf("feed(\"foobar\") = %d, want 6", got)
	}

	out := make([]byte, 8)
	if n := digest(c, out); n != 8 {
		t.Fatalf("digest into an 8-byte buffer wrote %d bytes, want 8", n)
	}
	if got := hex.EncodeToString(out); got != foobarDigest {
		t.Errorf("digest = %s, want %s", got, foobarDigest)
	}

	// zcounter_feed_str takes a NUL-terminated string; the terminator is not
	// counted, so the total advances by len(" baz") == 4.
	if got := feedStr(c, " baz"); got != 10 {
		t.Errorf("feedStr(\" baz\") = %d, want 10", got)
	}
	if got, ok := total(c); !ok || got != 10 {
		t.Errorf("total = (%d, %v), want (10, true)", got, ok)
	}

	after := make([]byte, 8)
	if n := digest(c, after); n != 8 {
		t.Fatalf("second digest wrote %d bytes, want 8", n)
	}
	if bytes.Equal(out, after) {
		t.Error("digest did not change after feeding more bytes")
	}
}

// The documented contract of zcounter_digest: it writes min(out_len, 8) bytes
// and returns exactly how many it wrote. A short buffer is truncated, never
// overrun, and a zero-length buffer is written not at all.
func TestDigestRespectsBufferLength(t *testing.T) {
	c := mustNew(t)
	defer closeCounter(c)
	feed(c, []byte("foobar"))

	full, err := hex.DecodeString(foobarDigest)
	if err != nil {
		t.Fatal(err)
	}

	for _, size := range []int{0, 1, 3, 7, 8, 16} {
		out := make([]byte, size)
		for i := range out {
			out[i] = 0xAA
		}
		n := digest(c, out)
		want := size
		if want > 8 {
			want = 8
		}
		if n != want {
			t.Errorf("digest into a %d-byte buffer wrote %d bytes, want %d", size, n, want)
		}
		if !bytes.Equal(out[:n], full[:n]) {
			t.Errorf("digest into a %d-byte buffer = %x, want %x", size, out[:n], full[:n])
		}
		for i := n; i < size; i++ {
			if out[i] != 0xAA {
				t.Errorf("digest into a %d-byte buffer overran into index %d", size, i)
				break
			}
		}
	}
}

// A zero-length Go slice has a nil or dangling data pointer, so the generated
// code has to substitute a valid pointer (the unsafe.SliceData guard from
// plan §4) before handing it to Zig. If it does not, this test crashes the
// process rather than failing.
func TestEmptySliceInput(t *testing.T) {
	c := mustNew(t)
	defer closeCounter(c)

	if got := feed(c, []byte("abc")); got != 3 {
		t.Fatalf("feed(\"abc\") = %d, want 3", got)
	}
	before := make([]byte, 8)
	if n := digest(c, before); n != 8 {
		t.Fatalf("digest wrote %d bytes, want 8", n)
	}

	cases := []struct {
		name string
		data []byte
	}{
		{"nil", nil},
		{"empty literal", []byte{}},
		{"empty make", make([]byte, 0)},
		{"zero-length reslice", []byte("abc")[:0]},
		{"empty from a large cap", make([]byte, 0, 64)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := feed(c, tc.data); got != 3 {
				t.Errorf("feeding an empty slice changed the total: got %d, want 3", got)
			}
			if got, ok := total(c); !ok || got != 3 {
				t.Errorf("total = (%d, %v), want (3, true)", got, ok)
			}
			after := make([]byte, 8)
			if n := digest(c, after); n != 8 {
				t.Fatalf("digest wrote %d bytes, want 8", n)
			}
			if !bytes.Equal(before, after) {
				t.Errorf("feeding an empty slice changed the digest: %x -> %x", before, after)
			}
		})
	}

	// The same guard applies to the output buffer of a bytes_out pair.
	if n := digest(c, []byte{}); n != 0 {
		t.Errorf("digest into an empty slice wrote %d bytes, want 0", n)
	}
	if n := digest(c, nil); n != 0 {
		t.Errorf("digest into a nil slice wrote %d bytes, want 0", n)
	}
}

func TestEmptyStringInput(t *testing.T) {
	c := mustNew(t)
	defer closeCounter(c)

	if got := feedStr(c, "abc"); got != 3 {
		t.Fatalf("feedStr(\"abc\") = %d, want 3", got)
	}
	if got := feedStr(c, ""); got != 3 {
		t.Errorf("feedStr(\"\") changed the total: got %d, want 3", got)
	}
	// A string containing an interior NUL stops at the NUL on the C side: the
	// binding passes a [*:0]const u8, so only "ab" is counted.
	if got := feedStr(c, "ab\x00cd"); got != 5 {
		t.Errorf("feedStr with an interior NUL = %d, want 5", got)
	}
}

// Close() must be idempotent: the generated wrapper zeroes its handle, and
// zcounter_destroy itself ignores a handle that is no longer live, so neither
// layer can double-free.
func TestCloseIsIdempotent(t *testing.T) {
	c := mustNew(t)

	closeCounter(c)
	closeCounter(c)
	closeCounter(c)

	// Calling through a closed handle must panic in the binding rather than
	// hand a zero handle to a Zig parameter typed `*Counter`, which is a
	// non-optional pointer the library is entitled to dereference.
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("total on a closed counter did not panic")
		}
		if msg, ok := r.(string); !ok || !strings.Contains(msg, "used after Close") {
			t.Fatalf("panicked with %v, want a 'used after Close' message", r)
		}
	}()
	_, _ = total(c)
}

// Closing many counters in a loop reuses pool slots; a double free or a stale
// slot would show up here as a corrupted digest rather than a crash.
func TestHandlesAreIndependent(t *testing.T) {
	const n = 8
	counters := make([]*counter, 0, n)
	defer func() {
		for _, c := range counters {
			closeCounter(c)
		}
	}()

	for i := 0; i < n; i++ {
		c := mustNew(t)
		counters = append(counters, c)
		for j := 0; j <= i; j++ {
			feed(c, []byte("x"))
		}
	}
	for i, c := range counters {
		want := uint64(i + 1)
		if got, ok := total(c); !ok || got != want {
			t.Errorf("counter %d: total = (%d, %v), want (%d, true)", i, got, ok, want)
		}
	}
}

func TestReuseAfterClose(t *testing.T) {
	first := mustNew(t)
	feed(first, []byte("foobar"))
	closeCounter(first)

	second := mustNew(t)
	defer closeCounter(second)

	// A reused pool slot must come back zeroed.
	if got, ok := total(second); !ok || got != 0 {
		t.Fatalf("a freshly allocated counter has total (%d, %v), want (0, true)", got, ok)
	}
	feed(second, []byte("foobar"))
	out := make([]byte, 8)
	if n := digest(second, out); n != 8 {
		t.Fatalf("digest wrote %d bytes, want 8", n)
	}
	if got := hex.EncodeToString(out); got != foobarDigest {
		t.Errorf("digest after slot reuse = %s, want %s", got, foobarDigest)
	}
}
