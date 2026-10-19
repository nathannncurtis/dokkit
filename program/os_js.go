package main

import (
	"errors"
	"os/exec"
)

func lockFile(string) (func(), error) { return nil, errors.New("no files in a browser") }

func detach(*exec.Cmd) {}
