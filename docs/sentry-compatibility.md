# Sentry's SDKs and Dokkit

Dokkit has its own client library and its own error format, and that is what its documentation leads with.

Dokkit also accepts reports from Sentry's open-source SDKs. Those SDKs are MIT-licensed and well made, and accepting what they send means an app in a language Dokkit has no library for can still report errors. Thank you to the Sentry team for building and maintaining them in the open.

Dokkit is not affiliated with Sentry.

## How this project behaves about it

1. Dokkit's own library comes first in every document. Compatibility is a section, not the pitch.
2. The wording is always a plain description: "Dokkit also accepts reports from Sentry's open-source SDKs." It is never a headline, and Dokkit is never described as an alternative to, a replacement for, or cheaper than anything.
3. No code from Sentry's server is in this repo.
4. No text or schema from Sentry's documentation is copied into this repo. The intake is written from the published protocol, and Dokkit's documents are written fresh.
5. No Sentry account is used in developing or testing this. Testing is against the open-source SDKs only.
6. Where Dokkit's interface is recognisably another product's design, that part is changed before this repo is public.

## What is accepted

Error events only. Everything else the SDKs can send is read and dropped.
