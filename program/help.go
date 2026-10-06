package main

import (
	"fmt"
	"os"
)

type topic struct{ group, name, synopsis, short, more string }

var topics = []topic{
	{"In an app's repo", "init", "dokkit init",
		"Asks what the app is and writes dokkit.toml.",
		"Asks a few questions and writes a dokkit.toml in this folder: what the app is,\nand how to tell it is healthy. Nothing is sent."},
	{"In an app's repo", "check", "dokkit check [dokkit.toml]",
		"Runs every check once and prints what would be sent.",
		"Validates the file, runs each of its checks once on this machine and prints\nexactly what would be sent. Needs no server and sends nothing."},
	{"In an app's repo", "apply", "dokkit apply [dokkit.toml]",
		"Sends the file to the server.",
		"Declares the file to the server, for use from CI or anywhere dokkit watch does\nnot read the folder. Sending the same file twice changes nothing."},
	{"Jobs", "run", "dokkit run [--service <slug>] --job <name> -- <command> [arguments]",
		"Runs a command and reports how it went.",
		"Runs the command and reports its start, finish, exit code, duration and last\nlines of output. Exits with the command's own exit code. A job declared in a\ndokkit.toml is found by name; --service says which service when it is not."},
	{"Jobs", "ping", "dokkit ping [--service <slug>] <name> [start|ok|fail]",
		"Reports a job that cannot be wrapped.",
		"Reports one event for a job: start, ok (the default) or fail."},
	{"This machine", "enrol", "dokkit enrol <address> <token> [sha256:<certificate fingerprint>]",
		"Joins this machine to a server.",
		"Trades a one-time token for this machine's key and saves it. Given a\nfingerprint, it trusts the certificate with that fingerprint and no other."},
	{"This machine", "status", "dokkit status",
		"What this machine watches and when it last reported.",
		"Shows the files dokkit watch reads, when the spool was last emptied, how much\nis waiting, and the process number of a watch left running."},
	{"This machine", "doctor", "dokkit doctor",
		"Checks the server can be reached and the clock is right.",
		"Says whether the server answers, whether its certificate matches the one\nsaved at enrol, and whether this machine's clock agrees with the server's."},
	{"Finding things", "scan", "dokkit scan [--no-services] [--no-ports] [--no-tasks] [--no-containers] [--no-sites] [--no-disks] [--no-declarations]",
		"Looks over this machine and writes a proposal file.",
		"Lists what is on the machine that could be watched and writes it to a proposal\nfile. Sends nothing. Each --no- flag leaves one kind of thing out."},
	{"Finding things", "propose", "dokkit propose",
		"Sends the proposal file to be accepted.",
		"Sends what a scan wrote. Nothing in it is watched until a person accepts it\nin the interface."},
	{"Staying running", "watch", "dokkit watch [--background]",
		"Watches this machine, as an ordinary program.",
		"Reads dokkit.toml files from the folders in DOKKIT_FOLDERS or in the saved\nconfiguration, and from the folders directly inside them. Runs their checks,\nsends the log files they name, and says the machine is alive once a minute.\nNo administrator, no service. --background leaves it running with no window."},
	{"Staying running", "startup", "dokkit startup on|off",
		"Starts dokkit watch each time you sign in.",
		"On Windows, adds dokkit watch --background to your own startup programs, or\ntakes it out. No administrator."},
	{"Staying running", "service", "dokkit service install|uninstall|update|start|stop",
		"Runs it as a service. Needs an administrator once.",
		"Installs dokkit as a service that starts with the machine, so it keeps\nwatching with nobody signed in and may restart the services its\nconfiguration names."},
	{"Tasks", "task", "dokkit task list",
		"The tasks on this machine and whether each is accepted.",
		"Says of each task whether it is accepted, not accepted yet, or changed since\nit was accepted, and which account tasks run as."},
	{"Tasks", "task", "dokkit task run <name>",
		"Runs a task here to try it.",
		"Runs the task on this machine now. The server can only ask for a task a\nperson accepted, pinned to the exact command accepted."},
}

const settings = `Reads DOKKIT_URL (the server's address) and DOKKIT_KEY (an app key),
or the address and machine key that dokkit enrol saved.
dokkit help <command> says more about one.`

func help(args []string) int {
	if len(args) == 0 {
		fmt.Println("dokkit " + version)
		group := ""
		for _, t := range topics {
			if t.group != group {
				group = t.group
				fmt.Println("\n" + group)
			}
			fmt.Printf("  %s\n      %s\n", t.synopsis, t.short)
		}
		fmt.Println("\n" + settings)
		return 0
	}
	found := false
	for _, t := range topics {
		if t.name == args[0] {
			if found {
				fmt.Println()
			}
			found = true
			fmt.Printf("%s\n\n%s\n", t.synopsis, t.more)
		}
	}
	if !found {
		fmt.Fprintf(os.Stderr, "dokkit: no command named %q. dokkit help lists them.\n", args[0])
		return 2
	}
	return 0
}
