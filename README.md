# BookChains

## Description
This is a mastodon bot to post "chains" of books.

The chains start with a seed entry, then find following books via
various connections with the previous book.

Running at https://botsin.space/@BookChains

## Requirements

At least:

* Perl
* Mastodon::Client (patched with the included patch, if you want alt text and improved focus)
* IO::All
* IO::All::LWP
* Data::Dump
