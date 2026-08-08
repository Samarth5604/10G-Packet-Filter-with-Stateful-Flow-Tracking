#!/usr/bin/env bash
# Local opam switch (4.14.x). Safe to combine with either of the others,
# but keep it out of .bashrc so the switch stays per-project.
eval "$(opam env --switch=. --set-switch)"
