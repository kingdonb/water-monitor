# Hello RubyConf Chicago 2024!
WIP - this is a polyglot codebase (with one main language currently, Ruby)

## Project Overview

This project aims to create a service that acts as an intermediary between end-users and a slower back-end service. The back-end service aggregates data from various sources and produces JSON on-demand, which typically takes several seconds to load. Since this data doesn't change frequently, our service will:

1. Pull the data once a day
2. Push updates to clients only as often as they request them or once a day, whichever is less frequent

This approach significantly reduces load times for end-users while maintaining reasonably up-to-date information.

## Ruby Application Details

### Key Features

1. **Efficient Caching**: The application pulls data once a day from the USGS water services API and caches it, reducing the load on the backend service.
2. **Compression**: Cached data is compressed to optimize storage and transfer.
3. **Conditional Responses**: Supports ETag and Last-Modified headers for efficient client-side caching.
4. **GZIP Support**: Serves compressed responses to clients that accept GZIP encoding.
5. **Redis Integration**: Uses Redis for distributed caching and inter-process communication.
6. **Background Processing**: Employs separate threads for cache updates and listening to update requests.
7. **Configurable Logging**: Includes a custom logging module with configurable log levels.
8. **Health Check Endpoint**: Provides a basic health check endpoint for monitoring.

### How It Works

1. The application initializes by setting up Redis connections and starting background threads for cache management.
2. When a client requests data:
   - If the cache is ready, it serves the cached data.
   - If the cache is updating, it returns a 202 status code asking the client to try again later.
3. The cache is updated either:
   - Automatically once a day by the cron thread.
   - On-demand when triggered by a client request if the cache is stale.
4. The application uses a locking mechanism to ensure only one instance updates the cache at a time.
5. Cached data is stored in both compressed and uncompressed formats to serve clients efficiently based on their capabilities.

### Testing Goals

Our testing strategy aims to ensure the reliability, performance, and correctness of the application. Key testing goals include:

1. Verifying the correct functioning of the caching mechanism, including updates and serving cached data.
2. Ensuring proper handling of concurrent requests and cache updates.
3. Testing the application's behavior under various Redis states (connected, disconnected, reconnecting).
4. Validating the correct implementation of HTTP caching headers and conditional responses.
5. Assessing the performance of the application under load.
6. Verifying the correct functioning of the logging system across all threads.
7. Testing the health check endpoint for accuracy in reflecting the application's state.

### Known Issues and Future Improvements

While the application is functional, there are several areas identified for improvement:

<!--
1. ~~Enhance logging functionality to work consistently across all threads.~~
1. ~~Ensure that health checks can pass prior to when a first request is received~~
1. ~~Improve health checks to provide more detailed information about the application's state.~~
1. ~~Refine error handling, particularly for Redis connection issues.~~
1. ~~Implement more granular health check endpoints to distinguish between different types of failures.~~
1. ~~Improve the resilience of Redis subscriptions to handle disconnections and reconnections gracefully.~~
-->

1. The cron thread has a handle `cron_interval` which is never set (except in tests)
1. The experimental 15 (2) minute wait publishes a message `please_update15_now` which is never received
1. (Based on the two issues above) clients should usually never see a 202 response
1. Clients should be able to retrieve the data 5 seconds later, if the response is 202
1. We should be tracking errors (202 is not an error unless ... see above)

These improvements will be addressed in future updates to enhance the reliability and maintainability of the application.

## Development Environment

In development, you can see the live service here (and test its performance):

[water.teamhephy.info](https://water.teamhephy.info/data)

This dev service is hosted on a Cable modem, on my home network, and its backend cache is on the other side of a (slow-ish) Wi-Fi link.

## Development Phases

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
