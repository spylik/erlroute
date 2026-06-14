# erlroute

## Code style

**No over-commenting.** Code is the source of truth for logic. Comments rot — implementations drift, comments stay. A comment that describes *what* the code does is noise; well-named functions and variables already do that. Only write a comment when the *why* is non-obvious: a hidden invariant, a specific bug worked around, a non-local constraint. When in doubt, delete the comment and make the code clearer instead.
