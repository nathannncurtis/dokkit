//go:build !windows

package main

func winServiceFacts(string) (string, string) { return "", "" }
func processPath(uint32) string               { return "" }
func parentPids() map[uint32]uint32           { return nil }
