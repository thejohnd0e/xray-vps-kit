#!/usr/bin/env bash
assert_eq yes yes 'assert before failed pipeline'
bash -c 'exit 19' | cat
assert_eq yes yes 'unreachable'
