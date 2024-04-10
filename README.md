# KVcache

KVcache is a simple reimplementation of redis, supporting a small subset of commands. 

The end goal is to become a more performant version of redis, with support for most features.

### Building

This project is written in zig, so running the following commands should be sufficient...

```bash
$ zig build
```

### Installation

I **highly** discourage doing this, since KVcache is a very beta piece of software
However, for the adventurous souls here, this is for you:

```bash
$ DESTDIR=/ zig build install
```