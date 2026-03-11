#!/bin/bash


ps -u `whoami` -o pid,cmd | grep 'linux_a64/code/bin/standard' | grep "$1" | grep -v grep
exit 0
