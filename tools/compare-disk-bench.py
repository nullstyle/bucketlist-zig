"""Verify identical disk benchmark histories before reporting median costs."""
import argparse
import json
import pathlib
import statistics


def require(condition, message):
    if not condition:
        raise ValueError(message)


def expected_phases(config):
    phases = [("open", "genesis", 0, 0)]
    advance = 0
    for workload in ("load", "update", "noop", "delete", "insert"):
        count = config["records"] if workload == "load" else config["records"] // 4
        for offset in range(0, count, config["batch_rows"]):
            operations = min(config["batch_rows"], count - offset)
            phases.append(("stage", workload, advance, operations))
            advance += 1
            phases.extend((phase, workload, advance, operations) for phase in ("prepare", "commit", "cleanup"))
    samples = config["read_samples_per_phase"]
    phases.extend([
        ("get", "verify_formula", advance, samples),
        ("close", "before_reopen", advance, 0),
        ("reopen", "authenticated_warm_cache", advance, 0),
        ("get_reopened", "verify_formula", advance, samples),
        ("collect", "current_root", advance, 0),
        ("get_after_collect", "verify_formula", advance, samples),
        ("close", "final", advance, 0),
    ])
    return phases


def read(path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line]
    configs = [row for row in rows if row.get("phase") == "configuration"]
    require(len(configs) == 1, f"{path}: expected one configuration")
    config = configs[0]
    require(config["format"] == "bucketlist-disk-bench-v1", "unsupported format")
    require(config["trials"] > 0 and config["batch_rows"] > 0, "invalid workload")
    require(config["records"] % 4 == 0 and config["records"] * config["value_bytes"] == config["mib"] * 1024**2, "invalid record count")
    proofs = {}
    summaries = {}
    for row in rows:
        if row.get("phase") == "commit":
            key = (row["trial"], row["merge_workers"], row["advance"])
            require(key not in proofs, f"{path}: duplicate advance {key}")
            proofs[key] = (row["digest"], row["reference_manifest_hash"])
        elif row.get("phase") == "summary":
            key = (row["trial"], row["merge_workers"])
            require(key not in summaries, f"{path}: duplicate summary {key}")
            require(row["live_allocation_bytes"] == 0, f"{path}: live allocations at close")
            require(row["logical_bytes"] == config["mib"] * 1024**2, f"{path}: wrong live size")
            require(row["records"] == config["records"], f"{path}: wrong live record count")
            if key[1] == 2:
                require(row["all_advance_digests_and_references_match"], f"{path}: worker comparison failed")
            summaries[key] = row
    batch = config["batch_rows"]
    count = config["records"]
    advances = (count + batch - 1) // batch + 4 * ((count // 4 + batch - 1) // batch)
    expected_summaries = {(trial, worker) for trial in range(config["trials"]) for worker in (1, 2)}
    require(set(summaries) == expected_summaries, f"{path}: incomplete summaries")
    expected_proofs = {(*key, advance) for key in expected_summaries for advance in range(1, advances + 1)}
    require(set(proofs) == expected_proofs, f"{path}: incomplete advance history")
    for trial in range(config["trials"]):
        for advance in range(1, advances + 1):
            require(proofs[trial, 1, advance] == proofs[trial, 2, advance], f"{path}: worker reference mismatch")
    for key, summary in summaries.items():
        phases = [row for row in rows if "measurement" in row and (row["trial"], row["merge_workers"]) == key]
        actual = [tuple(r[k] for k in ("phase", "workload", "advance", "operations")) for r in phases]
        require(actual == expected_phases(config), f"{path}: incomplete phase history {key}")
        measurements = [row["measurement"] for row in phases]
        require(summary["advance"] == advances and (summary["digest"], summary["reference_manifest_hash"]) == proofs[*key, advances], f"{path}: summary identity mismatch")
        require(summary["measured_elapsed_ns"] == sum(m["elapsed_ns"] for m in measurements), f"{path}: elapsed total mismatch")
        require(summary["positional_read_bytes"] == sum(m["positional_read_bytes"] for m in measurements), f"{path}: read total mismatch")
        require(summary["peak_allocation_bytes"] == max(m["peak_allocation_bytes"] for m in measurements), f"{path}: allocation peak mismatch")
    provenance = [row for row in rows if row.get("phase") == "provenance"]
    require(len(provenance) == 1, f"{path}: expected one provenance record; use tools/disk-bench.sh")
    modes = {"Debug": "debug", "ReleaseSafe": "safe", "ReleaseFast": "fast", "ReleaseSmall": "small"}
    require(modes.get(provenance[0]["optimize"]) == config["optimize"], f"{path}: optimization provenance mismatch")
    return rows, config, proofs, summaries, provenance[0]


def compare(before_path, after_path):
    before, before_config, before_proofs, before_summaries, before_source = read(before_path)
    after, after_config, after_proofs, after_summaries, after_source = read(after_path)
    for key in ("format", "zig", "optimize", "cpu", "os", "mib", "records", "value_bytes", "batch_rows", "read_samples_per_phase", "trials"):
        require(before_config[key] == after_config[key], f"configuration mismatch: {key}")
    require(before_source["benchmark_sha256"] == after_source["benchmark_sha256"], "benchmark source mismatch")
    require(before_proofs == after_proofs, "committed database digest or manifest reference mismatch")
    def trace(rows):
        return [tuple(r[k] for k in ("trial", "merge_workers", "phase", "workload", "advance", "operations")) for r in rows if "measurement" in r]
    require(trace(before) == trace(after), "measurement phase history mismatch")
    result = {"compared_advances": len(before_proofs), "identical_commitments_and_references": True, "workers": []}
    for worker in (1, 2):
        old = [r for (_, w), r in before_summaries.items() if w == worker]
        new = [r for (_, w), r in after_summaries.items() if w == worker]
        item = {"merge_workers": worker}
        for field in ("measured_elapsed_ns", "positional_read_bytes"):
            a = statistics.median(r[field] for r in old)
            b = statistics.median(r[field] for r in new)
            item[field] = {"before_median": a, "after_median": b, "before_over_after": a / b if b else None}
        item["peak_allocation_bytes"] = {"before_max": max(r["peak_allocation_bytes"] for r in old), "after_max": max(r["peak_allocation_bytes"] for r in new)}
        item["phase_elapsed_ns"] = {}
        phases = sorted({row["phase"] for row in before if "measurement" in row})
        for phase in phases:
            values = []
            for rows in (before, after):
                totals = [sum(r["measurement"]["elapsed_ns"] for r in rows if r["phase"] == phase and r["trial"] == trial and r["merge_workers"] == worker) for trial in range(before_config["trials"])]
                values.append(statistics.median(totals))
            item["phase_elapsed_ns"][phase] = {"before_median": values[0], "after_median": values[1]}
        result["workers"].append(item)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=pathlib.Path)
    parser.add_argument("after", type=pathlib.Path)
    args = parser.parse_args()
    try:
        print(json.dumps(compare(args.before, args.after), indent=2))
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"[disk-bench] {error}\n")
