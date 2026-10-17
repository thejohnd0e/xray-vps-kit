#!/usr/bin/env bash
assert_eq yes yes 'assert before crash'
bash -c 'exit 23'
assert_eq yes yes 'unreachable'
