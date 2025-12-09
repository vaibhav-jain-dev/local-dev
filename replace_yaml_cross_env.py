#!/usr/bin/env python3
import sys, argparse, re, yaml, os

def replace_in_text(base_file, target_file, old_prefix, new_prefix, show_only):
    with open(target_file, "r") as f:
        lines = f.readlines()

    changes = []
    new_lines = []
    for line in lines:
        if "orangehealth.dev" in line and f"{old_prefix}-" in line:
            new_line = line.replace(f"{old_prefix}-", f"{new_prefix}-")
            if new_line != line:
                changes.append((line.strip(), new_line.strip()))
                line = new_line
        new_lines.append(line)

    if changes:
        for old, new in changes:
            print(f"old: {old}\nnew: {new}\n")
        if not show_only:
            with open(target_file, "w") as f:
                f.writelines(new_lines)
    else:
        print("ℹ️ No changes detected.")

def replace_in_yaml(base_file, target_file, old_prefix, new_prefix, show_only):
    with open(target_file, "r") as f:
        data = yaml.safe_load(f)

    def traverse(node):
        if isinstance(node, dict):
            for k, v in node.items():
                node[k] = traverse(v)
        elif isinstance(node, list):
            return [traverse(v) for v in node]
        elif isinstance(node, str):
            if "orangehealth.dev" in node and f"{old_prefix}-" in node:
                new_val = node.replace(f"{old_prefix}-", f"{new_prefix}-")
                if new_val != node:
                    print(f"old: {node}\nnew: {new_val}\n")
                return new_val
        return node

    updated = traverse(data)

    if not show_only:
        with open(target_file, "w") as f:
            yaml.dump(updated, f, default_flow_style=False)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("base_file")
    parser.add_argument("target_file")
    parser.add_argument("old_prefix")
    parser.add_argument("new_prefix")
    parser.add_argument("--show", action="store_true")
    args = parser.parse_args()

    ext = os.path.splitext(args.base_file)[1].lower()
    if ext in (".yaml", ".yml"):
        replace_in_yaml(args.base_file, args.target_file, args.old_prefix, args.new_prefix, args.show)
    else:
        replace_in_text(args.base_file, args.target_file, args.old_prefix, args.new_prefix, args.show)

if __name__ == "__main__":
    main()

