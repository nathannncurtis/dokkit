package main

import (
	"os"
	"os/exec"
	"testing"
)

func TestASignatureIsReadOnlyFromAFileWindowsTrusts(t *testing.T) {
	// PowerShell 7 is signed inside the file, the way a dokkit release is.
	signed, err := exec.LookPath("pwsh.exe")
	if err != nil {
		t.Skip("no signed program to read")
	}
	who, err := signer(signed)
	if err != nil || who != "Microsoft Corporation" {
		t.Fatalf("signer of %s: %q %v", signed, who, err)
	}
	// This test program is not signed, so it can neither be trusted nor update itself.
	self, _ := os.Executable()
	if who, err := signer(self); err == nil {
		t.Fatalf("an unsigned file was given a signer: %q", who)
	}
	if said := signedBy(self); said != "not signed" {
		t.Fatal(said)
	}
}
