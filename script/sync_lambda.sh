#!/bin/bash
set -e
git fetch origin
git checkout main
git reset --hard origin/main
