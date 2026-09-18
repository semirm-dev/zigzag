module example.com/zcounter/go_test

go 1.23

require example.com/zcounter/bindings/go v0.0.0

require github.com/ebitengine/purego v0.9.0 // indirect

replace example.com/zcounter/bindings/go => ../bindings/go
