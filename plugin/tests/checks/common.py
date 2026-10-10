"""Result of one step of run.py."""

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


class Result:
    def __init__(self, status, detail="", output=""):
        self.status, self.detail, self.output = status, detail, output
        self.seconds = 0.0
