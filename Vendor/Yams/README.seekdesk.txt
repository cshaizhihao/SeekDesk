Yams 6.2.2 — https://github.com/jpsim/Yams/tree/6.2.2
MIT licensed; includes libyaml. See LICENSE and libyaml-LICENSE.txt.
Official source archive SHA-256:
c2b257913e3c9942e5d6c13632da2c317679381b9b4887ccc3e4f1ad28591548

Sources are unmodified. The package manifest omits upstream tests, which are
not included in this vendored source distribution, and exposes CYaml so
SeekDesk can validate input depth before recursive YAML composition. SeekDesk imports only
subscription node data, never remote rules, scripts, or executable config.
