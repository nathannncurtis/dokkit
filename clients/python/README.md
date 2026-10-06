# Dokkit for Python

One file, standard library only. `beat`, `job`, `check`, `capture`, `log`. See `dokkit.py` and `../../spec/library.md`.

## Install

Nothing is published to a registry yet. Install from a clone of the repo:

```
pip install path/to/dokkit/clients/python
```

Once the repository is public, this also works:

```
pip install "git+https://github.com/nathannncurtis/dokkit#subdirectory=clients/python"
```

## Logging

`logging.getLogger().addHandler(dokkit.handler())` sends the standard `logging` module's records through `log`.

## Test

`python -m unittest test_dokkit`
