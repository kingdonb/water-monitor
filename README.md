# Hello RubyConf Chicago 2024!
WIP - this is a polyglot codebase (with one main language currently, Ruby)

## Project Overview

This project aims to create a service that acts as an intermediary between end-users and a slower back-end service. The back-end service aggregates data from various sources and produces JSON on-demand, which typically takes several seconds to load. Since this data doesn't change frequently, our service will:

1. Pull the data once a day
2. Push updates to clients only as often as they request them or once a day, whichever is less frequent

This approach significantly reduces load times for end-users while maintaining reasonably up-to-date information.

In development, you can see the live service here (and test its performance):

[water.teamhephy.info](https://water.teamhephy.info/data)

This dev service is hosted on a Cable modem, on my home network, and its backend cache is on the other side of a (slow-ish) Wi-Fi link.

### Development Phases

1. **Ruby Proof-of-Concept**: Initially, we're implementing this as a single-class proof-of-concept in pure Ruby with native extensions (gems, some parts written in C).

2. **Modular WebAssembly Implementation**: We'll then break down the system into smaller, simpler parts. These will be implemented as WebAssembly modules, offering benefits such as:
   - Easier presentation and verification of correctness
   - Sandboxing for improved security
   - Type-checking (where supported by the implementation language)

The goal is to present this project and its evolution at RubyConf Chicago 2024, demonstrating the transition from a monolithic Ruby application to a modular, polyglot WebAssembly-based system.

## Navigate Codebase

* `ruby/` - our app is in here for now
* `Dockerfile` - it just contains the Ruby app for now
* `.github/workflows` - runs tests and pushes Docker images from the `main` branch

Soon we'll probably add:
* `web` - maybe Python?
* `cron` - probably in Rust
* `redis` - probably in Rust
* `spin.toml` - stitching things together

This will change everything, and if we are to build any of these parts in Ruby
then we will definitely need to simplify them so they do not invoke native C
extensions (or... we might find a way to pack the C extensions up with the Ruby
interpreter, I'm not going to go there, as much as I would like to see it done)
