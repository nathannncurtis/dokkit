//go:build !darwin

package main

import "errors"

func sendMessages(to, text string) error { return errors.New(notMacSaid) }
