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
		"Shows the files dokkit watch reads, when it last sent, and how many reports are\nwaiting. It says a watch is running only while that watch has written down in the\nlast three minutes, and then gives its process number."},
	{"This machine", "doctor", "dokkit doctor",
		"A rough check of the server and the clock.",
		"Says whether the server answers and knows this key, whether this machine's clock\nis within 30 seconds of the server's, and whether reports are waiting. A\ncertificate that is not the one saved at enrol shows as the server not answering."},
	{"Finding things", "scan", "dokkit scan [--no-services] [--no-ports] [--no-tasks] [--no-containers] [--no-sites] [--no-disks] [--no-declarations]",
		"Looks over this machine and writes a proposal file.",
		"Lists what is on the machine that could be watched and writes it to\ndokkit-proposal.json in this folder. Sends nothing. Each --no- flag leaves one kind of thing out."},
	{"Finding things", "propose", "dokkit propose",
		"Sends the proposal file to be accepted.",
		"Sends dokkit-proposal.json, which a scan wrote. Nothing in it is watched until a person accepts it\nin the interface."},
	{"Staying running", "watch", "dokkit watch [--background]",
		"Watches this machine, as an ordinary program.",
		"Reads dokkit.toml files from the folders in DOKKIT_FOLDERS or in the saved\nconfiguration, and from the folders directly inside them. Runs their checks,\nsends the log files they name, runs the tasks a person accepted, and says the\nmachine is alive once a minute. No administrator, no service. --background\nleaves it running after this window closes."},
	{"Staying running", "startup", "dokkit startup on|off",
		"Starts dokkit watch each time you sign in. Windows only.",
		"Works on Windows only so far. Adds dokkit watch --background to your own startup\nprograms, or takes it out. No administrator. Elsewhere, use dokkit service, or\nadd dokkit watch --background to your desktop's startup programs."},
	{"Staying running", "service", "dokkit service install|uninstall|update|start|stop",
		"Runs it as a service, on Windows or Linux. Needs an administrator or root.",
		"Works on Windows and on Linux with systemd; not on macOS yet. Installs dokkit\nas a service that starts with the machine, so it keeps watching with nobody\nsigned in. On Windows it runs as the system account. On Linux it runs as a\nuser named dokkit, which is made if useradd is there. It may restart only the\nservices or units that this machine's own configuration names. On Linux\nthat needs dokkit to run as root or systemd to allow it. Needs an administrator\nprompt on Windows and root on Linux."},
	{"Tasks", "task", "dokkit task list",
		"The tasks on this machine and whether each is accepted.",
		"Lists the tasks in this folder and in the folders this machine reads. When the\nserver answers, says of each whether it is accepted, not accepted yet, or changed\nsince it was accepted. Says which account you are running as."},
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
