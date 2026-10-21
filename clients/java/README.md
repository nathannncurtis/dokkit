# Dokkit for Java

One file, no dependencies, Java 11 or later, in the package `dev.dokkit`. `beat`, `job`, `check`, `metric`, `capture`, `log`, `stats`. Kotlin and Scala use it as it is.

## Install

Nothing is published to a registry yet. From a clone of the repo, build and install the jar into the local Maven repository, then depend on `dev.dokkit:dokkit:0.1.0`:

```
mvn install
```

In code: `import dev.dokkit.Dokkit;`

## Logging

`java.util.logging.Logger.getLogger("").addHandler(Dokkit.handler())` sends `java.util.logging` records through `log`. It leaves out records from the JDK HTTP client and from this library, and drops its own when the queue is half full, so turning on the client's request logging cannot make it feed on its own sending.

## Behavior

- `start(version)` sends the version once as a deploy line; `start(version, url, key, false)` (`announceVersion`) turns that off. The server records a deploy only when the version changes.
- A line over 64 KB is cut: `msg` is shortened and ends with ` [cut]`. Lines with no `msg` that are too big are dropped and counted.
- An error report the server did not answer for (network error, timeout, 5xx, 429) is kept for the next pass; a 4xx is dropped and counted. Error reports and log batches never hold each other up.
- Report bodies are gzipped.
- Stack frames carry the class name and method, not a file path, so no folder on the machine is sent.
- When `DOKKIT_ENV` is set and is not `production`, it goes on every line.

## Test

`javac -d out src/main/java/dev/dokkit/Dokkit.java src/test/java/dev/dokkit/Test.java && java -cp out dev.dokkit.Test`
