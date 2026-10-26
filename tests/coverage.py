#!/usr/bin/env python3
"""Task coverage of the roles: share of tasks and handlers that ran in the tests.

Usage: tests/coverage.py RECORD_FILE [--min PERCENT]

RECORD_FILE holds "file:line" of executed tasks, written by
tests/callback_plugins/task_coverage.py. Tasks inside block/rescue/always count
one by one, the block itself does not. meta tasks (reset_connection, end_role,
...) are left out: Ansible reports them to no callback, so they cannot be measured.
"""

import argparse
import os
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def tasks_in(node, path, out):
    """Collect "path:line" for every task in a YAML task list node."""
    if not isinstance(node, yaml.SequenceNode):
        return
    for item in node.value:
        if not isinstance(item, yaml.MappingNode):
            continue
        keys = {k.value: v for k, v in item.value}
        nested = [keys[k] for k in ("block", "rescue", "always") if k in keys]
        if nested:
            for child in nested:
                tasks_in(child, path, out)
        elif not any(k in keys for k in ("meta", "ansible.builtin.meta")):
            out.add(f"{path}:{item.start_mark.line + 1}")


def all_tasks():
    out = set()
    roles = os.path.join(REPO, "roles")
    for role in sorted(os.listdir(roles)):
        for kind in ("tasks", "handlers"):
            folder = os.path.join(roles, role, kind)
            if not os.path.isdir(folder):
                continue
            for name in sorted(os.listdir(folder)):
                if name.endswith((".yml", ".yaml")):
                    path = os.path.join(folder, name)
                    with open(path, encoding="utf-8") as f:
                        tasks_in(yaml.compose(f), path, out)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("record")
    parser.add_argument("--min", type=float, default=0)
    parser.add_argument("--missing", action="store_true", help="list tasks that never ran")
    args = parser.parse_args()

    total = all_tasks()
    with open(args.record, encoding="utf-8") as f:
        ran = {os.path.realpath(line.rsplit(":", 1)[0]) + ":" + line.strip().rsplit(":", 1)[1] for line in f if ":" in line}
    covered = total & ran

    by_role = {}
    for task in total:
        role = os.path.relpath(task, REPO).split(os.sep)[1]
        hit, count = by_role.get(role, (0, 0))
        by_role[role] = (hit + (task in covered), count + 1)

    print(f"{'role':16} {'tasks':>6} {'ran':>6} {'coverage':>9}")
    for role, (hit, count) in sorted(by_role.items()):
        print(f"{role:16} {count:6} {hit:6} {100 * hit / count:8.1f}%")
    percent = 100 * len(covered) / len(total)
    print(f"{'total':16} {len(total):6} {len(covered):6} {percent:8.1f}%")

    if args.missing:
        for task in sorted(total - covered, key=lambda t: (t.rsplit(":", 1)[0], int(t.rsplit(":", 1)[1]))):
            print("not run:", os.path.relpath(task, REPO))

    if percent < args.min:
        print(f"coverage {percent:.1f}% is below {args.min}%")
        sys.exit(1)


if __name__ == "__main__":
    main()
