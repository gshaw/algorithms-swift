# Algorithms implementation template

A GitHub template for an implementation of the test data on
[algorithms.gshaw.ca](https://algorithms.gshaw.ca). It has the contract wired up and no
language: pick one, replace `evaluate` and the check does the rest.
[algorithms-swift](https://github.com/gshaw/algorithms-swift) is a worked example.

## Start

1. **Use this template** on GitHub, then clone the new repo.
2. Add your toolchain to `mise.toml` and run `mise install`.
3. Replace the `evaluate` task. It reads one case per line on standard input and writes
   one result per line, in any order:

   ```text
   in:  {"algorithm":"wmm","id":"noaa-table-1","operation":"field","input":{"latitudeInDegrees":80,…}}
   out: {"id":"noaa-table-1","output":{"magneticDeclinationInDegrees":1.28,…}}
   out: {"id":"invalid-after-2030","error":"outOfRange"}
   out: {"id":"utm-1","error":"notImplemented"}
   ```

   Answer `notImplemented` for an algorithm you haven't written yet. Keep build output
   off standard output.
4. `mise run test` runs the checker over the current test data, prints every case and
   writes `conformance.json`.
5. Push. The Conformance workflow runs the check on every push and weekly, and commits
   `conformance.json`.
6. To be listed on the site, open a pull request on
   [gshaw/algorithms](https://github.com/gshaw/algorithms) adding your repo to
   `_data/implementations.yml`.

The full contract, field naming and comparison rules are on the
[test data format](https://algorithms.gshaw.ca/format/) page. Out of the box,
`evaluate` answers `notImplemented` to everything, so every algorithm shows as
incomplete.
