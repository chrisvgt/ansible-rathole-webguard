"""Records every task and handler that ran (not skipped) for tests/coverage.py."""

import os

from ansible.plugins.callback import CallbackBase

DOCUMENTATION = """
name: task_coverage
type: aggregate
short_description: record executed tasks for the test coverage report
description:
  - Appends "file:line" of every task that ran to the file in TASK_COVERAGE_FILE.
"""


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "task_coverage"
    CALLBACK_NEEDS_ENABLED = True

    def _record(self, task):
        target = os.environ.get("TASK_COVERAGE_FILE")
        path = task.get_path() if task else None
        if target and path:
            with open(target, "a", encoding="utf-8") as f:
                f.write(path + "\n")

    def v2_runner_on_ok(self, result):
        self._record(result._task)

    def v2_runner_on_failed(self, result, ignore_errors=False):
        self._record(result._task)

    def v2_runner_on_unreachable(self, result):
        self._record(result._task)

    # include_tasks / include_role do not report a runner result
    def v2_playbook_on_include(self, included_file):
        self._record(included_file._task)
