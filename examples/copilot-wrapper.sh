#!/usr/bin/env bash
# Example for TMAXER_AGENT_CMD. tmaxer passes its own flags (--model, --plugin-dir, -i, ...)
# to this script. Add what your setup needs, then run Copilot CLI with every argument.
exec copilot "$@"
