# Vendored: Mozilla Readability

`Readability.js` is Mozilla's standalone Readability library — the extraction
engine behind Firefox Reader View — fetched from
https://github.com/mozilla/readability (`main`, 2026-09-05).

Licensed under the **Apache License 2.0**, © Arc90 Inc and contributors. The
full licence text ships with the upstream project; the copyright header at the
top of `Readability.js` is preserved verbatim and must stay there.

It is vendored rather than fetched at runtime because article extraction has to
work with no network beyond the article request itself, and because a script
downloaded at runtime and evaluated in a web view is a different security
proposition entirely.
