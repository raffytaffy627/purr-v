#!/bin/sh
# run the whole purr-V test suite (Linux/Mac) :3
cd "$(dirname "$0")" && python3 tools/run_tests.py "$@"
