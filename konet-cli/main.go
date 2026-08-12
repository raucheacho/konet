package main

import "github.com/raucheacho/konet/konet-cli/cmd"

// version is stamped at build time by GoReleaser:
//
//	ldflags: -X main.version={{.Version}}
//
// The linker can only set a variable that exists in package main, so this
// declaration is what makes the flag effective; the value is handed to cmd,
// which reports it.
var version = "dev"

func main() {
	cmd.SetVersion(version)
	cmd.Execute()
}
