# Dokkit for Java

One file, no packages, Java 11 or later. `beat`, `job`, `check`, `capture`, `log`. Kotlin and Scala use it as it is.

## Install

Nothing is published to a registry yet. Build and install the jar into the local Maven repository, then depend on `dokkit:dokkit:0.1.0`:

```
mvn install
```

## Logging

`java.util.logging.Logger.getLogger("").addHandler(Dokkit.handler())` sends `java.util.logging` records through `log`.

## Test

`javac -d out Dokkit.java Test.java && java -cp out Test`
