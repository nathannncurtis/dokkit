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
		"Runs the checks it can once and prints what would be sent.",
		"Checks the file's schema, service id and each check's fields. Runs the http, tcp,\nprocess, windows-service, systemd and expiry checks that can run here, once, and\nprints exactly what would be sent. Checks the app reports itself are listed as\nnot run. A check aimed at another host does make its request. Needs no server and\nsends nothing to it. A slow answer shows as slow, not as a failure."},
	{"In an app's repo", "apply", "dokkit apply [dokkit.toml]",
		"Sends the file to the server.",
		"Declares the file to the server, for a file dokkit watch does not read. It needs\nthis machine's key from dokkit enrol; the server refuses an app key. Sending the\nsame file twice changes nothing."},
	{"Jobs", "run", "dokkit run [--service <slug>] --job <name> -- <command> [arguments]",
		"Runs a command and reports how it went.",
		"Runs the command and reports its start, finish, exit code, duration and last\nlines of output. Exits with the command's own exit code. With this machine's key,\na job declared in a dokkit.toml in the folders of the saved configuration is\nfound by name, and --service says which service when it is not. With an app key,\n--service is ignored."},
	{"Jobs", "ping", "dokkit ping [--service <slug>] <name> [start|ok|fail]",
		"Reports a job that cannot be wrapped.",
		"Reports one event for a job: start, ok (the default) or fail."},
	{"This machine", "enrol", "dokkit enrol <address> <token> [sha256:<certificate fingerprint>]",
		"Joins this machine to a server.",
		"Trades a one-time token for this machine's key and saves it. Given a\nfingerprint, it trusts the certificate with that fingerprint and no other."},
	{"This machine", "status", "dokkit status",
		"What this machine watches and when it last reported.",
		"Shows the files dokkit watch reads, when it last sent, and how many reports are\nwaiting, and any folder it cannot read. It says a watch is running only while that\nwatch has written down in the last three minutes, and then gives its process\nnumber. On Linux it shows the installed service when root, or the dokkit group, can read its\nfiles; the service's status itself can be read only with sudo."},
	{"This machine", "doctor", "dokkit doctor",
		"A rough check of the server and the clock.",
		"Says whether the server answers and knows this key, whether this machine's clock\nis within 30 seconds of the server's (a slow answer counts as clock difference,\nup to 10 seconds), and whether reports are waiting. A certificate that is not the\none saved at enrol shows as the server not answering."},
	{"Finding things", "scan", "dokkit scan [--no-services] [--no-ports] [--no-tasks] [--no-containers] [--no-sites] [--no-disks] [--no-declarations]",
		"Looks over this machine and writes a proposal file.",
		"Lists what is on the machine that could be watched and writes it to\ndokkit-proposal.json in this folder. Sends nothing. Each --no- flag leaves one kind of thing out."},
	{"Finding things", "propose", "dokkit propose",
		"Sends the proposal file to be accepted.",
		"Sends dokkit-proposal.json, which a scan wrote. Nothing in it is watched until a\nperson accepts it in the interface, or a token allowed to act accepts it through\nthe API."},
	{"Staying running", "watch", "dokkit watch [--background]",
		"Watches this machine, as an ordinary program.",
		"Reads dokkit.toml files from the folders in DOKKIT_FOLDERS or in the saved\nconfiguration, and from the folders directly inside them. Runs their checks,\nsends the log files they name, runs the tasks a person accepted, and says the\nmachine is alive once a minute. No administrator, no service. --background\nleaves it running after this window closes. Run like this, it never restarts a\nservice or unit; only the installed service does."},
	{"Staying running", "folder", "dokkit folder add|remove <path>",
		"Sets which folders dokkit watch reads dokkit.toml files from.",
		"Adds a folder to the list dokkit watch reads dokkit.toml files from, or takes one\nout. It reads the dokkit.toml in the folder and in the folders directly inside it.\nThe path is made absolute, and for add the folder must exist. Adding one twice\nchanges nothing. A running watch picks up the change within a minute, with no\nrestart. When the service is installed this changes the service's list, which\nneeds an administrator, or root on Linux, and it prints the exact line to run.\nOtherwise it changes your own list. On Linux, it warns when the dokkit user cannot\nread the folder."},
	{"Staying running", "folder", "dokkit folder list",
		"Shows those folders.",
		"Lists the folders dokkit watch reads dokkit.toml files from: the installed service's\nwhen there is one, otherwise your own, and any it cannot read."},
	{"Staying running", "startup", "dokkit startup on|off",
		"Starts dokkit watch each time you sign in. Windows only.",
		"Works on Windows only so far. Adds dokkit watch --background to your own startup\nprograms, or takes it out. No administrator. On Linux, use dokkit service, or add\ndokkit watch --background to your desktop's startup programs. On macOS, add it to\na launchd job."},
	{"Staying running", "service", "dokkit service install|uninstall|update|start|stop",
		"Runs it as a service, on Windows or Linux. Needs an administrator or root.",
		"Works on Windows and on Linux with systemd; not on macOS yet. Installs dokkit\nas a service that starts with the machine, so it keeps watching with nobody\nsigned in. On Windows it runs as the system account. On Linux it runs as a\nuser named dokkit, which is made if useradd is there, and it reads only the\nfolders that user can read. It may restart only the services or units that this\nmachine's own configuration names. On Linux that needs dokkit to run as root or\nsystemd to allow it. Needs an administrator prompt on Windows and root on Linux.\nOn Linux, run through sudo, it uses the enrolment of the account that ran sudo, and\nroot's own when that account has none, and says which file it used. update puts this\ncopy in place of the installed one and restarts the service. uninstall leaves the\nmachine enrolled on the server."},
	{"Tasks", "task", "dokkit task list",
		"The tasks on this machine and whether each is accepted.",
		"Lists the tasks in this folder and in the folders this machine reads. When the\nserver answers, says of each whether it is accepted, not accepted yet, or changed\nsince it was accepted. When it lists any tasks, says which account you are\nrunning as."},
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
