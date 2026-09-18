package zctest

// This file is the ONLY place that names an identifier from the generated
// package. Every test calls these adapters, so if the Go generator's spelling
// changes, this one file changes and the tests do not.
//
// The names below were read back from bindings/go/zcounter_gen.go after
// `zig build port`, and match what src/gen/names.zig produces:
//
//	lib_name = "zcounter" and every export is named "zcounter_*", so
//	names.stripPrefix drops the "zcounter_" prefix and names.toPascal is
//	applied to what is left:
//
//	zcounter_new      -> New       func() (*Counter, error)    (ctor, D7)
//	zcounter_destroy  -> Close     (*Counter).Close() error    (dtor, D7)
//	zcounter_add      -> Add       func(a, b int32) int32
//	zcounter_feed     -> Feed      (*Counter).Feed([]byte) uint64
//	zcounter_feed_str -> FeedStr   (*Counter).FeedStr(string) uint64
//	zcounter_digest   -> Digest    (*Counter).Digest([]byte) uintptr
//	zcounter_total    -> Total     (*Counter).Total() (bool, uint64)
//	opaque Counter    -> type Counter struct{ h uintptr }
//
// Naming the exports "<libname>_*" is what makes this read well: the prefix is
// stripped, so the Go API is Feed/Digest/Total rather than ZcCounterFeed. The
// validator warns when an export does not start with the library name.
//
// Two shapes worth naming explicitly, because they are the ones a regeneration
// is most likely to move:
//
//   - Total returns the DECLARED return value first and the out-param second:
//     (bool, uint64). total() below flips that into the Go-idiomatic
//     (value, ok) so the tests read naturally.
//   - usize comes back as uintptr even in the idiomatic layer. digest() casts
//     to int, which compiles whether that stays uintptr or becomes int/uint64.
//
// The import alias means the generated package's own name does not matter here.
import zc "example.com/zcounter/bindings/go"

// counter is the generated handle type.
type counter = zc.Counter

func newCounter() (*counter, error) { return zc.New() }

func closeCounter(c *counter) { _ = c.Close() }

func add(a, b int32) int32 { return zc.Add(a, b) }

func feed(c *counter, data []byte) uint64 { return c.Feed(data) }

func feedStr(c *counter, text string) uint64 { return c.FeedStr(text) }

// digest writes into out and returns the number of bytes written.
func digest(c *counter, out []byte) int { return int(c.Digest(out)) }

// total returns (value, ok); the generated order is (ok, value).
func total(c *counter) (uint64, bool) {
	ok, value := c.Total()
	return value, ok
}
