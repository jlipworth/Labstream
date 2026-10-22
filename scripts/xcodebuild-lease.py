#!/usr/bin/env python3
"""Serialize cooperating Xcode/GUI lanes; see xcode_lease for the lock implementation."""
import sys
from xcode_lease import main

if __name__ == "__main__":
    sys.exit(main())
