# Dokkit for Java

One file, no dependencies, Java 11 or later, in the package `dev.dokkit`. `beat`, `job`, `check`, `capture`, `log`. Kotlin and Scala use it as it is.

## Install

Nothing is published to a registry yet. From a clone of the repo, build and install the jar into the local Maven repository, then depend on `dev.dokkit:dokkit:0.1.0`:

```
mvn install
```

In code: `import dev.dokkit.Dokkit;`

## Logging

`java.util.logging.Logger.getLogger("").addHandler(Dokkit.handler())` sends `java.util.logging` records through `log`.

## Test

`javac -d out src/main/java/dev/dokkit/Dokkit.java src/test/java/dev/dokkit/Test.java && java -cp out dev.dokkit.Test`
