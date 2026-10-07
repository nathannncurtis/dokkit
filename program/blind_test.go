package main

import (
	"errors"
	"testing"
)

func TestScProblem(t *testing.T) {
	if err := scProblem(1060); err == nil || err.Error() != "no such service" {
		t.Fatalf("1060: %v", err)
	}
	if !errors.As(scProblem(5), new(cannotTell)) {
		t.Fatal("5 is not being allowed to ask, not a stopped service")
	}
	if errors.As(scProblem(1), new(cannotTell)) {
		t.Fatal("any other code is a failure")
	}
}
