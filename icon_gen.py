#!/usr/bin/env python3
"""Compatibility entry point for the shared Usage app icon generator."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
subprocess.run(["swift", "scripts/icon_gen.swift"], cwd=ROOT, check=True)
