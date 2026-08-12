module github.com/raucheacho/konet/conformance/go

go 1.23

// The harness must test the SDK in this tree, not a published version of it.
replace github.com/raucheacho/konet/sdk/go => ../../sdk/go

require github.com/raucheacho/konet/sdk/go v0.0.0

require github.com/coder/websocket v1.8.15 // indirect
