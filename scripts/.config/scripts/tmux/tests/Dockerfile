# Sandboxed runner for wb.sh's *.test.sh suite. Several of these tests
# `source` wb.sh directly (to call its internal functions), and wb.sh's own
# top-level scope has already caused one real incident (2026-07-10: a
# variable-name collision on CODE_DIR turned a test's own `rm -rf
# "$scratch_dir"` into `rm -rf ~/code`). Running the suite in a container
# with no real ~/code to hit contains any repeat of that class of bug to a
# throwaway filesystem, regardless of what future test code does.
#
# Build:  docker build -t wb-tests -f scripts/.config/scripts/tmux/tests/Dockerfile .
# Run one test:
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests \
#     bash scripts/.config/scripts/tmux/tests/wb-new.test.sh
# Run the whole suite:
#   docker run --rm -v "$(pwd)":/repo:ro -w /repo wb-tests

FROM ubuntu:24.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       bash git tmux gawk coreutils grep sed ca-certificates bsdextrautils \
    && rm -rf /var/lib/apt/lists/*

# HOME has no code/ dir at all in the image — even a fresh CODE_DIR-shaped
# bug can't reach real data, since there is none to reach.
ENV HOME=/home/tester
RUN useradd -ms /bin/bash tester
USER tester
WORKDIR /repo

# Mount the repo read-only (-v ...:/repo:ro) so nothing the tests do, even a
# runaway rm -rf, can touch the host checkout either. Tests write their own
# fixtures under /tmp inside the container, which is always writable.
CMD ["bash", "-c", "set -e; fail=0; for t in scripts/.config/scripts/tmux/tests/*.test.sh; do echo \"=== $t ===\"; bash \"$t\" || fail=1; done; exit $fail"]
