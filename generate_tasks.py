#!/usr/bin/env python
# coding=utf-8
"""
Generate tasks.txt for batch Abaqus simulation
- Scans all .step/.stp files recursively from specified directory
- Creates tasks with x, y, z directions for each model
- Output format: <absolute_path> <direction>
"""

import os
import sys
import argparse

def find_all_step_files(root_dir):
    """Recursively find all .step and .stp files"""
    step_files = []
    
    for dirpath, dirnames, filenames in os.walk(root_dir):
        # Skip hidden directories and common non-essential folders
        dirnames[:] = [d for d in dirnames if not d.startswith('.')]
        
        for filename in filenames:
            if filename.lower().endswith(('.step', '.stp')):
                full_path = os.path.join(dirpath, filename)
                abs_path = os.path.abspath(full_path)
                step_files.append(abs_path)
    
    return sorted(step_files)

def generate_tasks(step_files, directions=('x', 'y', 'z')):
    """Generate task list with directions"""
    tasks = []
    for step_file in step_files:
        for direction in directions:
            tasks.append((step_file, direction))
    return tasks

def main():
    parser = argparse.ArgumentParser(
        description='Generate tasks.txt for batch Abaqus simulation'
    )
    parser.add_argument(
        'root_dir',
        help='Root directory to scan for .step/.stp files'
    )
    parser.add_argument(
        '-o', '--output',
        default='tasks.txt',
        help='Output file path (default: tasks.txt)'
    )
    parser.add_argument(
        '-d', '--directions',
        default='xyz',
        help='Directions to simulate (default: xyz, e.g., xz for x and z only)'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show statistics without writing file'
    )
    
    args = parser.parse_args()
    
    # Validate root directory
    if not os.path.isdir(args.root_dir):
        print("Error: Directory '{}' does not exist".format(args.root_dir))
        sys.exit(1)
    
    # Find all step files
    print("Scanning directory: {}".format(args.root_dir))
    step_files = find_all_step_files(args.root_dir)
    
    if not step_files:
        print("Warning: No .step or .stp files found")
        sys.exit(0)
    
    print("Found {} step files".format(len(step_files)))
    
    # Generate tasks
    directions = [d.lower() for d in args.directions if d.lower() in 'xyz']
    if not directions:
        print("Error: No valid directions (must be x, y, or z)")
        sys.exit(1)
    
    tasks = generate_tasks(step_files, directions)
    total_tasks = len(tasks)
    
    print("Directions: {}".format(', '.join(directions)))
    print("Total tasks: {} ({} models x {} directions)".format(total_tasks, len(step_files), len(directions)))
    
    # Calculate array distribution
    num_arrays = 1000
    tasks_per_array = (total_tasks + num_arrays - 1) // num_arrays
    print("\nRecommended SLURM array configuration:")
    print("  --array=0-{}".format(num_arrays-1))
    print("  Tasks per array: ~{}".format(tasks_per_array))
    
    if args.dry_run:
        print("\n[Dry run] Not writing file")
        print("\nFirst 10 tasks:")
        for i, (path, direction) in enumerate(tasks[:10]):
            print("  {}. {} {}".format(i+1, path, direction))
        return
    
    # Write tasks file
    with open(args.output, 'w') as f:
        for path, direction in tasks:
            f.write("{} {}\n".format(path, direction))
    
    print("\nTasks written to: {}".format(args.output))
    print("File size: {} bytes".format(os.path.getsize(args.output)))
    
    # Show task ID mapping examples
    print("\nTask ID mapping examples:")
    print("  Task 0: {} {}".format(tasks[0][0], tasks[0][1]))
    if len(tasks) > 1:
        mid = len(tasks) // 2
        print("  Task {}: {} {}".format(mid, tasks[mid][0], tasks[mid][1]))
    if len(tasks) > 0:
        print("  Task {}: {} {}".format(total_tasks-1, tasks[-1][0], tasks[-1][1]))

if __name__ == '__main__':
    main()
