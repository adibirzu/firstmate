#!/usr/bin/env python3
import argparse
from pathlib import Path


def require(version, condition, message):
    if not condition:
        raise AssertionError(f'{version}: {message}')


def read_text(version, path):
    try:
        return Path(path).read_text()
    except OSError as error:
        raise AssertionError(f'{version}: {error}') from error


parser=argparse.ArgumentParser()
parser.add_argument('--version', required=True)
actions=parser.add_mutually_exclusive_group(required=True)
actions.add_argument('--fail')
actions.add_argument('--read')
args=parser.parse_args()
if args.fail is not None:
    require(args.version, False, args.fail)
else:
    read_text(args.version, args.read)
