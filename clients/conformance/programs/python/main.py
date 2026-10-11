import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "python"))
import dokkit

tag = sys.argv[1]


class ConformanceError(Exception):
    pass


dokkit.start(version="9.9.9")
dokkit.beat("conf-beat", 60)
with dokkit.job("conf-job"):
    pass
dokkit.check("conf-check", "ok", 1)
dokkit.metric("conf.metric", 5, "n")
dokkit.log("info", "conformance " + tag, {"tag": tag, "n": 1})
try:
    raise ConformanceError("x")
except ConformanceError as e:
    dokkit.capture(e)
dokkit.flush()
