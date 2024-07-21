# Hello RubyConf Chicago 2024!

WIP - this is a polyglot codebase (with one main language currently, Ruby)

We will add the other languages later. For now the focus is automating and
proving the problem can be solved in pure Ruby (with some native extensions).

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
