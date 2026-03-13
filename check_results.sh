#!/bin/bash
# Quick statistics for batch simulation results

if [[ -z "$1" ]]; then
    echo "Usage: $0 <results_directory>"
    exit 1
fi

results_dir="$1"

if [[ ! -d "$results_dir" ]]; then
    echo "Error: Directory '$results_dir' does not exist"
    exit 1
fi

echo "=========================================="
echo "Batch Simulation Results Statistics"
echo "=========================================="
echo "Results directory: $results_dir"
echo ""

# Count successful CSV files
success_count=$(find "$results_dir" -name "*.csv" ! -name "*_failed.csv" ! -name "*_timeout.csv" | wc -l)
echo "✓ Successful computations: $success_count"

# Count failed CSV files
failed_count=$(find "$results_dir" -name "*_failed.csv" | wc -l)
echo "✗ Failed computations: $failed_count"

# Count timeout files
timeout_count=$(find "$results_dir" -name "timeoutNote" | wc -l)
echo "⏱ Timeout tasks: $timeout_count"

# Count abaqus error files
error_count=$(find "$results_dir" -name "abaqusError" | wc -l)
echo "⚠ Abaqus errors: $error_count"

# Count skip files
skip_count=$(find "$results_dir" -name "skipNote" | wc -l)
echo "⊘ Skipped tasks: $skip_count"

echo ""
echo "=========================================="
echo "Breakdown by Direction"
echo "=========================================="

for dir in x y z; do
    count=$(find "$results_dir" -name "*_${dir}.csv" ! -name "*_failed.csv" | wc -l)
    echo "$dir direction: $count successful"
done

echo ""
echo "=========================================="
echo "Sample Results (first 5)"
echo "=========================================="
find "$results_dir" -name "*.csv" ! -name "*_failed.csv" | head -5 | while read csv; do
    echo ""
    echo "File: $csv"
    head -1 "$csv"
done

echo ""
echo "=========================================="
echo "Failed Tasks Details"
echo "=========================================="
find "$results_dir" -name "*_failed.csv" | head -5 | while read csv; do
    echo ""
    echo "File: $csv"
    head -2 "$csv"
done

echo ""
echo "=========================================="
echo "Total Directories"
echo "=========================================="
total_dirs=$(find "$results_dir" -mindepth 2 -maxdepth 2 -type d | wc -l)
echo "Model directories: $total_dirs"
