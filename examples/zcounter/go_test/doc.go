// Package zctest is the consumer-side end-to-end test for the Go bindings
// zbridge generates from examples/zcounter/src/c_api.zig.
//
// It deliberately lives in its own module (with a replace directive pointing at
// ../bindings/go) so it exercises the generated module exactly the way a real
// downstream user would: through the public import path, with no access to
// zbridge's internals.
//
// There is no non-test code here beyond this file; every generated identifier
// this module depends on is named in exactly one place, surface_test.go.
package zctest
